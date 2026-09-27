import Foundation
import NaturalLanguage

// MARK: - „Flow lernt mit“: reine Auswertung eines Textes (keine Zustände, keine Dateien, threadsicher)
//
// Alles lokal: Apple NaturalLanguage (Sprache, Namen, Grundform, Wortart) + NSDataDetector (Termine).

enum SmartAnalyzer {

    struct DateHit: Equatable {
        var date: Date
        /// Titelvorschlag (Satz ohne die Zeitangabe, gekürzt)
        var title: String
        var matched: String
        var meetingWord: Bool
    }

    struct Features {
        var language: String?
        var wordCount = 0
        /// Ganze Satzteile (zwischen Satzzeichen, 3–14 Wörter, ohne Ziffern): normierter Schlüssel + Schreibweise
        var phrases: [(key: String, form: String)] = []
        var terms: [(form: String, kind: SmartTermKind)] = []
        var signOff: (key: String, form: String)?
        var greeting: (key: String, form: String)?
        var formal = 0
        var casual = 0
        var dates: [DateHit] = []
        /// MinHash-Fingerabdruck, nur bei langen Diktaten (≥ 25 Wörter)
        var print: [UInt32]?
    }

    static let longWords = 25

    // MARK: Hauptfunktion

    static func analyze(_ text: String, myName: String = "", known: Set<String> = [], now: Date = Date(),
                        category: AppCategory = .other) -> Features {
        var f = Features()
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return f }

        let rec = NLLanguageRecognizer()
        rec.languageConstraints = [.german, .english]
        rec.processString(s)
        let lang = rec.dominantLanguage
        f.language = lang?.rawValue

        // Wörter mit Satzgrenzen, Namen, Grundform, Wortart – ein Durchlauf
        let tagger = NLTagger(tagSchemes: [.nameType, .lemma, .lexicalClass])
        tagger.string = s
        if let lang { tagger.setLanguage(lang, range: s.startIndex..<s.endIndex) }
        struct Tok { let range: Range<String.Index>; let word: String; let sentenceStart: Bool; let breakBefore: Bool; let clauseBreak: Bool }
        var toks: [Tok] = []
        var prevEnd = s.startIndex
        let myParts = Set(myName.lowercased().split(separator: " ").map(String.init))
        var seenTerms = Set<String>()
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, r in
            let between = s[prevEnd..<r.lowerBound]
            let isFirst = toks.isEmpty
            let sentenceBreak = between.contains { ".!?\n;:".contains($0) }
            let start = isFirst || sentenceBreak
            let w = String(s[r])
            let clauseBreak = sentenceBreak || between.contains { ",–—()\"„“".contains($0) }
            toks.append(Tok(range: r, word: w, sentenceStart: start, breakBefore: sentenceBreak, clauseBreak: clauseBreak))
            prevEnd = r.upperBound

            // Namen/Begriffe
            if isTermShaped(w), !myParts.contains(w.lowercased()), !known.contains(w.lowercased()),
               !termStopwords.contains(w.lowercased()), !seenTerms.contains(w.lowercased()) {
                let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
                let lex = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass).0
                let unknown = lemma == nil && (lex == nil || lex == .noun || lex == .otherWord)
                let mixed = w.dropFirst().contains { $0.isUppercase }        // „KiTaNet“, „ClipVault“
                var kind: SmartTermKind?
                switch tag {
                case .personalName?: kind = .person
                case .placeName?: kind = .place
                case .organizationName?: kind = .org
                default: break
                }
                let nameLike = kind != nil && (lemma == nil || lemma?.lowercased() == w.lowercased())
                if unknown || mixed || nameLike {
                    // Satzanfang: nur, wenn das Wort unbekannt ist (sonst ist „Liebe“/„Hey“ ein normales Wort)
                    if !start || unknown || mixed {
                        f.terms.append((w, kind ?? .term))
                        seenTerms.insert(w.lowercased())
                    }
                }
            }
            return true
        }
        f.wordCount = toks.count

        // Formulierungen: ganze Satzteile (zwischen Satzzeichen), 3–14 Wörter, ohne Ziffern/Links
        var seenKeys = Set<String>()
        var clauseStart = 0
        func flushClause(_ end: Int) {
            defer { clauseStart = end }
            guard end > clauseStart else { return }
            let part = toks[clauseStart..<end]
            guard (3...14).contains(part.count) else { return }
            let words = part.map { $0.word.lowercased() }
            if words.contains(where: { $0.contains { $0.isNumber } || $0.contains("@") || $0.contains("/") }) { return }
            guard words.contains(where: { !phraseStopwords.contains($0) }) else { return }
            let key = words.joined(separator: " ")
            guard key.count >= 8, !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            f.phrases.append((key, String(s[part.first!.range.lowerBound..<part.last!.range.upperBound])))
        }
        for i in toks.indices where i > 0 && toks[i].clauseBreak { flushClause(i) }
        flushClause(toks.count)

        f.signOff = signOff(in: s)
        f.greeting = greeting(in: s)
        (f.formal, f.casual) = register(toks.map { ($0.word, $0.sentenceStart) }, text: s)
        f.dates = dates(in: s, now: now, category: category)
        if toks.count >= longWords {
            f.print = minHash(toks.map { $0.word.lowercased() })
        }
        return f
    }

    // MARK: Begriffe

    static func isTermShaped(_ w: String) -> Bool {
        guard w.count >= 3, w.count <= 32, let first = w.first, first.isUppercase else { return false }
        return w.allSatisfy { $0.isLetter || $0 == "-" }
    }

    /// Häufige Großwörter, die keine Namen sind (NaturalLanguage hält sie manchmal dafür)
    static let termStopwords: Set<String> = [
        "liebe", "lieber", "hey", "hallo", "hi", "moin", "servus", "sie", "ihr", "ihre", "ihnen", "ihren", "ihrer", "mit", "und",
        "grüße", "grüßen", "gruß", "dank", "danke", "okay", "ok", "bitte", "sehr", "geehrte", "geehrter", "frau", "herr", "herrn",
        "the", "and", "thanks", "best", "dear", "cheers", "hello", "regards", "kind", "love", "god", "gott", "jesus", "herr",
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag", "heute", "morgen", "gestern",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
        "januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember",
        "ich", "wir", "du", "er", "es", "das", "der", "die", "ein", "eine", "also", "aber", "ja", "nein", "genau", "vielleicht",
        "sprecher", "teilnehmer", "meeting", "punkt", "aufgabe", "aufgaben", "frage", "fragen", "kurzfassung", "kernpunkte",
        "entscheidungen", "zusammenfassung", "offene", "titel",
    ]

    static let phraseStopwords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "aber", "ich", "du", "er",
        "sie", "es", "wir", "ihr", "mich", "dich", "mir", "dir", "uns", "euch", "ist", "bin", "bist", "sind", "war", "hab", "habe",
        "hat", "haben", "zu", "zum", "zur", "in", "im", "an", "am", "auf", "für", "mit", "von", "vom", "bei", "nach", "aus", "so",
        "auch", "noch", "mal", "ja", "nein", "nicht", "dass", "wie", "was", "wenn", "dann", "da", "hier", "jetzt", "schon", "nur",
        "the", "a", "an", "and", "or", "but", "i", "you", "we", "it", "is", "are", "was", "to", "of", "in", "on", "for", "with",
        "that", "this", "be", "have", "has", "so", "just", "not", "do", "can", "my", "your", "me",
    ]

    // MARK: Grüße & Abschiede

    /// Längste zuerst (damit „mit freundlichen grüßen“ vor „grüßen“ gewinnt)
    static let closings: [String] = [
        "mit freundlichen grüßen", "mit freundlichen grüssen", "herzliche grüße", "liebe grüße", "viele grüße", "beste grüße",
        "schöne grüße", "freundliche grüße", "liebe grüsse", "viele grüsse", "beste grüsse", "herzliche grüsse", "gottes segen",
        "sei gesegnet", "seid gesegnet", "bis später", "bis bald", "bis dann", "bis morgen", "danke dir", "danke euch", "tschüss",
        "grüße", "gruß", "ciao", "lg", "vg", "bg", "segen",
        "best regards", "kind regards", "all the best", "warm regards", "god bless", "talk soon", "see you", "thank you",
        "blessings", "sincerely", "regards", "cheers", "thanks", "best", "love", "warmly",
    ]

    static func signOff(in s: String) -> (key: String, form: String)? {
        let lower = s.lowercased()
        // nur das Ende betrachten
        let tailStart = lower.index(lower.endIndex, offsetBy: -min(lower.count, 70))
        var best: Range<String.Index>?
        for c in closings {
            var searchEnd = lower.endIndex
            while let r = lower.range(of: c, options: .backwards, range: tailStart..<searchEnd) {
                searchEnd = r.lowerBound
                // Wortgrenze vorne und hinten
                let beforeOK = r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter
                let afterOK = r.upperBound == lower.endIndex || !lower[r.upperBound].isLetter
                guard beforeOK, afterOK else { continue }
                // davor ein Satz-/Zeilenende (oder Textanfang)
                let before = lower[lower.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                guard before.isEmpty || ".!?\n,;:".contains(before.last!) else { continue }
                // dahinter höchstens 3 Wörter (Name)
                let rest = lower[r.upperBound...].components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                guard rest.count <= 3 else { continue }
                if best == nil || r.lowerBound < best!.lowerBound { best = r }
                break
            }
        }
        guard let r = best else { return nil }
        // gleiche Stelle im Original (gleiche Länge, weil lowercased hier keine Längen ändert – sonst Abbruch)
        guard lower.count == s.count else { return nil }
        let offset = lower.distance(from: lower.startIndex, to: r.lowerBound)
        let start = s.index(s.startIndex, offsetBy: offset)
        var form = String(s[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = form.last, ".!".contains(last) { form.removeLast() }
        form = form.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        guard form.count >= 2, form.count <= 48 else { return nil }
        let key = form.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return (key, form)
    }

    static let openers: [String] = [
        "sehr geehrte damen und herren", "sehr geehrter", "sehr geehrte", "guten morgen", "guten tag", "guten abend",
        "good morning", "hallo zusammen", "hallo", "hi", "hey", "moin", "servus", "liebe", "lieber", "hello", "dear", "yo", "na",
    ]

    static func greeting(in s: String) -> (key: String, form: String)? {
        let lower = s.lowercased()
        for o in openers where lower.hasPrefix(o) {
            let end = lower.index(lower.startIndex, offsetBy: o.count)
            if end < lower.endIndex, lower[end].isLetter { continue }
            let form = String(s.prefix(o.count))
            return (o, form)
        }
        return nil
    }

    // MARK: Register (Sie/du)

    static func register(_ words: [(String, Bool)], text: String) -> (formal: Int, casual: Int) {
        var formal = 0, casual = 0
        let formalCaps: Set<String> = ["Sie", "Ihnen", "Ihr", "Ihre", "Ihrer", "Ihren", "Ihrem"]
        let casualWords: Set<String> = ["du", "dich", "dir", "dein", "deine", "deinen", "deinem", "deiner", "euch", "euer", "eure",
                                        "hey", "lg", "haha", "hahaha", "cool", "digga", "bro", "alter", "krass", "yo", "gerne"]
        for (w, start) in words {
            if !start, formalCaps.contains(w) { formal += 1 }
            if casualWords.contains(w.lowercased()), !(formalCaps.contains(w) && !start) { casual += 1 }
        }
        let l = text.lowercased()
        for m in ["sehr geehrte", "mit freundlichen grüßen", "mit freundlichen grüssen", "dear ", "kind regards", "sincerely", "best regards"] where l.contains(m) { formal += 2 }
        return (formal, casual)
    }

    // MARK: Termine

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let detectorLock = NSLock()
    /// Nur Angaben MIT Uhrzeit sind Termine („heute“ allein ist keiner)
    private static let timeRegex = try! NSRegularExpression(
        pattern: "(\\d{1,2}([:.]\\d{2})?\\s*(uhr|h\\b|am\\b|pm\\b|a\\.m\\.|p\\.m\\.))|(\\b\\d{1,2}:\\d{2}\\b)|(\\bhalb\\s+\\w+)|(\\bmittags?\\b)|(\\bnoon\\b)",
        options: [.caseInsensitive])
    static let meetingWords: [String] = [
        "termin", "treffen", "treff", "meeting", "call", "telefonat", "telefonieren", "anrufen", "anruf", "besprechung", "zoom",
        "teams", "facetime", "gespräch", "essen", "mittagessen", "abendessen", "frühstück", "kaffee", "arzt", "zahnarzt", "probe",
        "gottesdienst", "lobpreis", "training", "sync", "meet", "lunch", "dinner", "appointment", "interview", "camp", "sitzung",
    ]

    static func dates(in s: String, now: Date, category: AppCategory) -> [DateHit] {
        guard let det = detector else { return [] }
        detectorLock.lock()
        let matches = det.matches(in: s, range: NSRange(s.startIndex..., in: s))
        detectorLock.unlock()
        var out: [DateHit] = []
        for m in matches {
            guard let d = m.date, let r = Range(m.range, in: s) else { continue }
            var matched = String(s[r])
            let ns = matched as NSString
            guard timeRegex.firstMatch(in: matched, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            guard d > now.addingTimeInterval(10 * 60), d < now.addingTimeInterval(60 * 86400) else { continue }
            // Satz um die Fundstelle
            let sentence = sentenceAround(r, in: s)
            let lowerSentence = sentence.lowercased()
            let meeting = meetingWords.contains { lowerSentence.contains($0) }
            // Präposition direkt davor gehört zur Zeitangabe („am Freitag um 14 Uhr“)
            for prep in ["am ", "um ", "ab ", "bis ", "nächsten ", "kommenden ", "on ", "at ", "next ", "this "] {
                if sentence.range(of: prep + matched, options: .caseInsensitive) != nil { matched = prep + matched; break }
            }
            var words = sentence.replacingOccurrences(of: matched, with: " ", options: .caseInsensitive)
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            // Füllwörter vorne weg („Lass uns …“, „Wir können …“)
            let lead: Set<String> = ["lass", "lasst", "uns", "wir", "können", "könnten", "sollen", "wollen", "ich", "würde", "sehen",
                                     "let's", "lets", "we", "can", "could", "should", "ja", "also", "und", "dann", "am", "um", "bis"]
            while let first = words.first, lead.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) { words.removeFirst() }
            var title = words.prefix(7).joined(separator: " ")
            title = title.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            if title.count > 50 { title = String(title.prefix(49)) + "…" }
            if let first = title.first { title = first.uppercased() + title.dropFirst() }
            if title.isEmpty { title = "Termin" }
            out.append(DateHit(date: d, title: title, matched: matched, meetingWord: meeting))
        }
        return out
    }

    private static func sentenceAround(_ r: Range<String.Index>, in s: String) -> String {
        var a = r.lowerBound, b = r.upperBound
        while a > s.startIndex {
            let p = s.index(before: a)
            if ".!?\n".contains(s[p]) { break }
            a = p
        }
        while b < s.endIndex, !".!?\n".contains(s[b]) { b = s.index(after: b) }
        return String(s[a..<b]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Fingerabdruck (MinHash über 3-Wort-Schindeln) – vergleicht lange Diktate ohne Text zu speichern

    static let sigSize = 32

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    static func minHash(_ words: [String]) -> [UInt32] {
        guard words.count >= 3 else { return [] }
        var sig = [UInt32](repeating: .max, count: sigSize)
        for i in 0...(words.count - 3) {
            let base = fnv(words[i] + " " + words[i + 1] + " " + words[i + 2])
            for k in 0..<sigSize {
                var x = base ^ (UInt64(k + 1) &* 0x9E3779B97F4A7C15)
                x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
                let v = UInt32(truncatingIfNeeded: x)
                if v < sig[k] { sig[k] = v }
            }
        }
        return sig
    }

    static func similarity(_ a: [UInt32], _ b: [UInt32]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return Double(zip(a, b).filter { $0 == $1 }.count) / Double(a.count)
    }

    /// Kurzer, stabiler Schlüssel für einmalige Formulierungen (statt Text)
    static func seedKey(_ key: String) -> String { String(fnv(key) & 0xFFFF_FFFF_FFFF, radix: 36) }

    // MARK: Snippet-Auslöser

    /// „Liebe Grüße, <Name>“ → ["lg", "Liebe", "Liebe Grüße"] – kurze, sprechbare Auslöser (ohne den eigenen Namen)
    static func triggerOptions(for text: String, existing: Set<String>, myName: String = "") -> [String] {
        let me = Set(myName.lowercased().split(separator: " ").map(String.init))
        let all = text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        // eigener Name gehört nicht ins Kürzel („Liebe Grüße, <Name>“ → „lg“)
        let words = all.filter { !me.contains($0.lowercased()) }.isEmpty ? all : all.filter { !me.contains($0.lowercased()) }
        var out: [String] = []
        func add(_ t: String) {
            let k = t.pgKey
            guard k.count >= 2, !existing.contains(k), !out.contains(where: { $0.pgKey == k }) else { return }
            out.append(t)
        }
        let initials = words.prefix(4).compactMap { $0.first.map { String($0).lowercased() } }.joined()
        if initials.count >= 2 { add(initials) }
        if let first = words.first(where: { $0.count >= 4 }) { add(first) }
        if words.count >= 2 { add(words.prefix(2).joined(separator: " ")) }
        if out.isEmpty { add("snippet " + (words.first ?? "text").lowercased()) }
        return Array(out.prefix(3))
    }

    // MARK: Meetings (nur Zusammenfassung + Sprechernamen)

    struct MeetingFeatures {
        var people: [String] = []
        var topics: [String] = []
        var tasks: [SmartTask] = []
        var myTasks: [SmartTask] = []
    }

    static func analyzeMeeting(title: String, summary: String, speakerNames: [String], myName: String) -> MeetingFeatures {
        var f = MeetingFeatures()
        let me = myName.lowercased().split(separator: " ").first.map(String.init) ?? ""
        // Personen: benannte Sprecher + Namen in der Zusammenfassung
        var people: [String] = []
        func addPerson(_ p: String) {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.lowercased() != me, !t.lowercased().hasPrefix("sprecher"), !termStopwords.contains(t.lowercased()),
                  !people.contains(where: { $0.lowercased() == t.lowercased() }) else { return }
            people.append(t)
        }
        speakerNames.forEach(addPerson)
        let plain = summary.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "")
        let tagger = NLTagger(tagSchemes: [.nameType, .lemma, .lexicalClass])
        tagger.string = plain
        var nouns: [String: Int] = [:]
        var nounForm: [String: String] = [:]
        tagger.enumerateTags(in: plain.startIndex..<plain.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            let w = String(plain[r])
            if tag == .personalName, w.first?.isUppercase == true, !w.contains(":") { addPerson(w) }
            return true
        }
        let topicStop: Set<String> = ["kurzfassung", "kernpunkt", "kernpunkte", "entscheidung", "entscheidungen", "aufgabe", "aufgaben",
                                      "frage", "fragen", "meeting", "punkt", "sprecher", "teilnehmer", "titel", "zusammenfassung", "ende",
                                      "tag", "woche", "heute", "morgen", "zeit", "ja", "nein", "sache", "thema"]
        tagger.enumerateTags(in: plain.startIndex..<plain.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            guard tag == .noun else { return true }
            let w = String(plain[r])
            guard w.count >= 4, w.first?.isUppercase == true, !w.contains(where: { $0.isNumber }) else { return true }
            let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? w
            let k = lemma.lowercased()
            guard !topicStop.contains(k), !people.contains(where: { $0.lowercased() == k || $0.lowercased() == w.lowercased() }),
                  k != me, w.lowercased() != me else { return true }
            nouns[k, default: 0] += 1
            if nounForm[k] == nil { nounForm[k] = lemma.first!.isUppercase ? lemma : w }
            return true
        }
        // Titelwörter zählen doppelt
        for w in title.components(separatedBy: CharacterSet.letters.inverted) where w.count >= 4 && w.first?.isUppercase == true {
            let k = w.lowercased()
            guard !topicStop.contains(k) else { continue }
            nouns[k, default: 0] += 2
            if nounForm[k] == nil { nounForm[k] = w }
        }
        f.people = people
        f.topics = nouns.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).compactMap { nounForm[$0.key] }

        // Aufgaben: Punkte unter „Aufgaben“ / „Action Items“ / „Tasks“
        var inTasks = false
        for raw in summary.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let bare = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if bare.hasPrefix("aufgaben") || bare.hasPrefix("action items") || bare.hasPrefix("tasks") || bare.hasPrefix("to-dos") || bare.hasPrefix("todos") {
                inTasks = true; continue
            }
            if line.hasPrefix("**") || line.hasPrefix("#") { if inTasks { inTasks = false }; continue }
            guard inTasks, raw.hasPrefix("- ") || raw.hasPrefix("* ") || raw.hasPrefix("• ") else { continue }   // nur oberste Ebene
            var item = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard item.count >= 4 else { continue }
            var owner: String?
            if let c = item.firstIndex(of: ":") {
                let o = item[..<c].trimmingCharacters(in: .whitespaces)
                if o.split(separator: " ").count <= 3, o.count <= 30 {
                    owner = o
                    item = item[item.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let due = dates(in: item, now: Date().addingTimeInterval(-3600), category: .other).first?.date
                ?? dayOnlyDate(in: item)
            if let first = item.first { item = first.uppercased() + item.dropFirst() }
            if item.count > 120 { item = String(item.prefix(119)) + "…" }
            let t = SmartTask(title: item, owner: owner, due: due)
            f.tasks.append(t)
            let o = owner?.lowercased() ?? ""
            if o.isEmpty || o == me || o.hasPrefix(me + " ") || ["ich", "me", "i", "alle", "wir"].contains(o) { f.myTasks.append(t) }
        }
        return f
    }

    /// Fälligkeit ohne Uhrzeit („bis Freitag“) → Datum 9:00
    static func dayOnlyDate(in s: String) -> Date? {
        guard let det = detector else { return nil }
        detectorLock.lock()
        let m = det.matches(in: s, range: NSRange(s.startIndex..., in: s)).first
        detectorLock.unlock()
        guard let d = m?.date, d > Date().addingTimeInterval(-86400), d < Date().addingTimeInterval(90 * 86400) else { return nil }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d)
    }
}
