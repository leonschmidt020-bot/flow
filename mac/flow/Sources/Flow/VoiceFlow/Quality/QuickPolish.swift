import Foundation
import NaturalLanguage

/// Feinschliff nach Regeln (ohne KI, < 5 ms): Selbstkorrekturen, Fehlstarts, Wiederholungen, Aufzählungen, Schlusszeichen.
/// Grundsatz: lieber nichts ändern als falsch ändern – jede Regel greift nur bei eindeutigem Muster.
/// Läuft immer bei „Schnell“ und ist der Rückfall, wenn Apple Intelligence fehlt oder zu langsam ist.
enum QuickPolish {
    struct Report: Sendable { var corrections = 0, repeats = 0, falseStarts = 0, lists = 0, punctuation = 0, terms = 0, listHints = 0
        var changed: Bool { corrections + repeats + falseStarts + lists + punctuation + terms + listHints > 0 }
    }

    /// `app` = Bundle-ID der Ziel-App (nil = aus dem Bildschirm-Kontext bzw. App beim Fn-Druck) – bestimmt die Listen-Form
    static func apply(_ input: String, snapshot: ScreenContext.Snapshot? = nil, app: String? = nil) -> (text: String, report: Report) {
        var r = Report()
        var s = input
        var n = 0
        (s, n) = resolveCorrections(s); r.corrections = n
        (s, n) = collapseRepeats(s); r.repeats = n
        (s, n) = dropFalseStarts(s); r.falseStarts = n
        // Listen: „erstens …“ (formatLists) + automatisch erkannte (SmartLists), Sprach-Hinweis „als Liste“/„keine Liste“
        let lp = SmartLists.pass(s, target: SmartLists.target(bundleID: app ?? SmartLists.currentBundle(snapshot)))
        s = lp.text; r.lists = lp.lists; r.listHints = lp.hintUsed ? 1 : 0
        let before = s
        s = ContextBoost.fixTerms(s, snapshot: snapshot)
        if s != before { r.terms = 1 }
        (s, n) = finalPunctuation(s); r.punctuation = n
        if r.changed { s = TextCleaner.tidy(s) }
        return (r.changed ? s : input, r)
    }

    /// Braucht der Text überhaupt KI? (Selbstkorrektur, Aufzählung, Fehlstart, lange ohne Satzzeichen)
    static func needsAI(_ s: String) -> Bool {
        if findMarker(tokens(s)) != nil || TextCleaner.hasSelfCorrection(s) { return true }
        if listMarkers(s).count >= 2 { return true }
        if collapseRepeats(s).1 > 0 || dropFalseStarts(s).1 > 0 { return true }
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        if words >= 10, !s.dropLast().contains(where: { ",.;:!?".contains($0) }) { return true }
        return false
    }

    // MARK: Wörter

    struct Tok { var text: String; var bare: String { QuickPolish.bare(text) }; var lower: String { bare.lowercased() } }

    static func bare(_ w: String) -> String { w.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?…–—-\"'„“”»«()")) }
    static func tokens(_ s: String) -> [Tok] { s.split(separator: " ", omittingEmptySubsequences: true).map { Tok(text: String($0)) } }
    static func join(_ t: [Tok]) -> String { t.map(\.text).joined(separator: " ") }
    private static func endsClause(_ t: Tok) -> Bool { t.text.last.map { ",;:.!?…–—".contains($0) } ?? false }
    private static func endsSentence(_ t: Tok) -> Bool { t.text.last.map { ".!?".contains($0) } ?? false }

    // MARK: Selbstkorrekturen

    enum MarkerKind { case replace, deletePrevious }
    struct Marker { let words: [String]; let kind: MarkerKind; let needsCommaBefore: Bool }

    static let markers: [Marker] = {
        func m(_ s: String, _ k: MarkerKind = .replace, comma: Bool = false) -> Marker { Marker(words: s.split(separator: " ").map(String.init), kind: k, needsCommaBefore: comma) }
        return [
            m("nein warte"), m("nee warte"), m("nein moment"), m("moment nein"), m("warte nein"), m("äh nein"), m("ähm nein"),
            m("oder nein"), m("nein sorry"), m("nein ich meine"), m("nein ich meinte"), m("ich meinte"), m("korrektur"),
            m("oder besser gesagt"), m("besser gesagt"), m("oder besser", comma: true), m("ich meine", comma: true), m("sorry", comma: true),
            m("no wait"), m("wait no"), m("no sorry"), m("sorry i mean"), m("no i mean"), m("i meant"), m("actually make that"),
            m("actually no"), m("no actually"), m("or rather"), m("make that", comma: true), m("i mean", comma: true), m("correction", comma: true),
            m("streich das", .deletePrevious), m("vergiss das", .deletePrevious), m("lösch das", .deletePrevious),
            m("scratch that", .deletePrevious), m("forget that", .deletePrevious), m("delete that", .deletePrevious),
        ].sorted { $0.words.count > $1.words.count }
    }()

    /// Erste Korrektur-Stelle: (Start, Ende exkl., Art). Nie am Textanfang, braucht Satzzeichen davor oder danach.
    static func findMarker(_ t: [Tok], from: Int = 1) -> (lo: Int, hi: Int, kind: MarkerKind)? {
        guard t.count >= 3 else { return nil }
        var i = max(1, from)
        while i < t.count {
            for mk in markers where i + mk.words.count <= t.count {
                guard (0..<mk.words.count).allSatisfy({ t[i + $0].lower == mk.words[$0] }) else { continue }
                // Innerhalb des Markers darf nur ein Komma stehen („nein, warte,“), kein Satzende mitten drin
                if (0..<(mk.words.count - 1)).contains(where: { endsSentence(t[i + $0]) }) { continue }
                // „Er sagte: Ich meine …“ ist keine Korrektur – bei den weichen Markern zählt nur ein echtes Komma davor
                let before = mk.needsCommaBefore ? t[i - 1].text.hasSuffix(",") : endsClause(t[i - 1])
                let after = endsClause(t[i + mk.words.count - 1]) || i + mk.words.count == t.count
                if mk.needsCommaBefore ? !before : !(before || after) { continue }
                if mk.kind == .deletePrevious, !after { continue }      // „Vergiss das nicht“ ist keine Korrektur
                // „He said, I mean what I say“ / „Er sagte, ich meine …“ – wörtliche Rede
                if mk.needsCommaBefore, speechVerbs.contains(t[i - 1].lower) { continue }
                return (i, i + mk.words.count, mk.kind)
            }
            i += 1
        }
        return nil
    }

    private static let speechVerbs: Set<String> = ["said", "says", "say", "asked", "told", "sagte", "sagt", "meinte", "fragte", "schrieb", "rief"]
    /// Abtrennbare Verbteile am Satzende („bring … mit“, „ich bin … da“) – bleiben stehen, wenn B sie nicht selbst hat
    private static let particles: Set<String> = ["da", "mit", "an", "auf", "ab", "zu", "vor", "hin", "her", "los", "weg", "zurück", "vorbei", "ein", "aus"]

    private static let softLead: Set<String> = ["lieber", "doch", "eher", "besser", "also", "eigentlich", "rather", "actually", "better", "instead", "maybe", "vielleicht"]

    static func resolveCorrections(_ input: String) -> (String, Int) {
        var t = tokens(input)
        var done = 0
        var from = 1
        for _ in 0..<4 {
            guard let mk = findMarker(t, from: from) else { break }
            var a = Array(t[..<mk.lo])
            let b = Array(t[mk.hi...])
            // „… am Donnerstag. Nein, warte, am Freitag.“ – A endet mit Satzende: dieser Satz ist gemeint
            let afterSentence = a.last.map(endsSentence) ?? false
            if afterSentence, var l = a.last {
                l.text = String(l.text.dropLast()); a[a.count - 1] = l
            }
            // Anfang des letzten Satzes in A
            let sentStart = (a.lastIndex(where: endsSentence).map { $0 + 1 }) ?? 0
            if mk.kind == .deletePrevious {
                // „Ich komme um acht. Streich das. Ich komme um neun.“ → der Satz vor dem Marker fliegt raus
                var kept = Array(a[..<sentStart])
                if b.isEmpty, var last = kept.last, !endsSentence(last) { last.text += "."; kept[kept.count - 1] = last }
                t = kept + b
                done += 1; from = max(1, kept.count); continue
            }
            guard !b.isEmpty, sentStart < a.count else { from = mk.hi; continue }
            // Nach Satzende ohne passenden Anker: B ersetzt den ganzen vorigen Satz („Ruf Anna an. Nein warte, schreib ihr.“)
            guard let cut = replaceStart(a: a, sentStart: sentStart, b: b, byClass: !(afterSentence && b.count >= 3))
                    ?? (afterSentence && b.count >= 3 ? sentStart : nil) else {
                from = mk.hi; continue
            }
            var head = Array(a[..<cut])
            // Satzzeichen am Ende des Kopfes (Komma vor dem ersetzten Teil) weg, Satzende behalten
            if var last = head.last, !endsSentence(last) {
                last.text = last.text.trimmingCharacters(in: CharacterSet(charactersIn: ",;:–—"))
                head[head.count - 1] = last
            }
            var tail = b
            // „Bring bitte Cola mit, nein sorry, Wasser.“ → „Bring bitte Wasser mit.“
            if cut > sentStart, cut < a.count - 1, let lastA = a.last, particles.contains(lastA.lower), !b.contains(where: { $0.lower == lastA.lower }),
               var end = tail.last {
                let punct = String(end.text.reversed().prefix { ".!?,;".contains($0) }.reversed())
                end.text = String(end.text.dropLast(punct.count)); tail[tail.count - 1] = end
                tail.append(Tok(text: lastA.bare + punct))
            }
            if var first = tail.first, let c = first.text.first {
                if cut == sentStart {
                    // B beginnt jetzt den Satz → groß
                    first.text = String(c).uppercased() + first.text.dropFirst()
                } else if c.isUppercase, !NameBoosterLike.properLike(first.bare), a[cut].bare.first?.isLowercase == true {
                    // Groß nur wegen „Nein, warte. Am Freitag“ → wie das ersetzte Wort („am“, „drei“) klein
                    first.text = String(c).lowercased() + first.text.dropFirst()
                }
                tail[0] = first
            }
            t = head + tail
            done += 1
            from = max(1, head.count)
        }
        return done > 0 ? (join(t), done) : (input, 0)
    }

    /// Ab welchem Wort in A ersetzt B? Anker (gleiches Wort), rechtsbündig gleiches Ende, oder gleiche Wortart; nil = unsicher.
    static func replaceStart(a: [Tok], sentStart: Int, b: [Tok], byClass: Bool = true) -> Int? {
        let range = sentStart..<a.count
        guard !range.isEmpty else { return nil }
        // 1) Anker: B beginnt mit einem Wort aus A („am Donnerstag … am Freitag“)
        for (k, bw) in b.prefix(2).enumerated() {
            if k == 1 && !softLead.contains(b[0].lower) { break }
            if let i = range.reversed().first(where: { a[$0].lower == bw.lower && !bw.lower.isEmpty }) { return i }
        }
        // 1b) Rechtsbündig: B endet wie A („next week … this week“, „fünf Stühle … sechs Stühle“)
        var bHead: [Tok] = []
        for x in b { bHead.append(x); if endsSentence(x) { break } }
        if bHead.count >= 2, bHead.count <= 4, let lastB = bHead.last?.lower,
           let j = range.reversed().first(where: { a[$0].lower == lastB }), j >= a.count - 2 {
            let c = j - (bHead.count - 1)
            if c >= sentStart { return c }
        }
        // 2) Gleiche Wortart am Ende von A („Donnerstag … Freitag“, „drei … vier“)
        guard byClass else { return nil }
        let whole = join(a) + " " + join(b)
        let classes = lexicalClasses(whole)
        let aClasses = Array(classes.prefix(a.count))
        let bClass = classes.count > a.count ? classes[a.count] : nil
        guard let bc = bClass.flatMap(group) else { return nil }
        // nur die letzten 4 Wörter von A kommen in Frage (eine Korrektur betrifft das eben Gesagte)
        let lo = max(sentStart, a.count - 4)
        return (lo..<a.count).reversed().first(where: { aClasses.indices.contains($0) && group(aClasses[$0]) == bc })
    }

    private static func group(_ c: NLTag) -> String? {
        switch c {
        case .noun, .personalName, .placeName, .organizationName: return "nomen"
        case .number: return "zahl"
        case .verb: return "verb"
        case .adjective: return "adj"
        case .adverb: return "adv"
        case .preposition: return "präp"
        case .determiner: return "art"
        case .pronoun: return "pron"
        default: return nil
        }
    }

    /// Wortart je Leerzeichen-Token (NLTagger im ganzen Satz, damit der Zusammenhang zählt)
    static func lexicalClasses(_ s: String) -> [NLTag] {
        let toks = s.split(separator: " ", omittingEmptySubsequences: true)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        var out: [NLTag] = []
        var idx = s.startIndex
        for tk in toks {
            guard let r = s.range(of: tk, range: idx..<s.endIndex) else { out.append(.otherWord); continue }
            idx = r.upperBound
            var tag: NLTag = .otherWord
            tagger.enumerateTags(in: r, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { t, _ in
                if let t { tag = t }; return false
            }
            let b = QuickPolish.bare(String(tk)).lowercased()
            if timeWords.contains(b) { tag = .adverb }
            // Zahlwörter sicher als Zahl
            if numberWords.contains(b) || (!b.isEmpty && b.allSatisfy(\.isNumber)) { tag = .number }
            out.append(tag)
        }
        return out
    }

    static let timeWords: Set<String> = ["heute", "morgen", "übermorgen", "gestern", "vorgestern", "jetzt", "später", "gleich", "bald", "nachher",
        "today", "tomorrow", "yesterday", "tonight", "later", "now", "soon"]

    static let numberWords: Set<String> = ["null", "eins", "ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "elf", "zwölf", "zwanzig", "dreißig", "vierzig", "fünfzig", "hundert", "tausend", "zero", "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand"]

    // MARK: Wiederholungen & Fehlstarts

    /// „wir sollten, wir sollten das machen“ → „wir sollten das machen“ (2–4 Wörter direkt wiederholt)
    static func collapseRepeats(_ input: String) -> (String, Int) {
        var t = tokens(input)
        var n = 0
        var changed = true
        while changed {
            changed = false
            outer: for len in stride(from: 4, through: 2, by: -1) where t.count >= 2 * len {
                for i in 0...(t.count - 2 * len) {
                    let a = t[i..<(i + len)].map(\.lower), b = t[(i + len)..<(i + 2 * len)].map(\.lower)
                    guard a == b, a.contains(where: { $0.count >= 2 }) else { continue }
                    // Satzende zwischen den beiden Hälften? Dann sind es zwei Sätze (bewusste Wiederholung)
                    if endsSentence(t[i + len - 1]) { continue }
                    var keep = Array(t[(i + len)...])
                    if i == 0 || endsSentence(t[i - 1]), var f = keep.first, let c = f.text.first, t[i].text.first?.isUppercase == true {
                        f.text = String(c).uppercased() + f.text.dropFirst(); keep[0] = f
                    }
                    t = Array(t[..<i]) + keep
                    n += 1; changed = true
                    break outer
                }
            }
        }
        return n > 0 ? (join(t), n) : (input, 0)
    }

    /// „Ich hab, ich habe gestern …“ → „Ich habe gestern …“: kurzer Anlauf (≤ 4 Wörter, endet mit Komma/Strich),
    /// danach derselbe Anfang noch einmal, länger. „Ich kam, ich sah, ich siegte“ bleibt (Wörter verschieden).
    static func dropFalseStarts(_ input: String) -> (String, Int) {
        var t = tokens(input)
        var n = 0
        var i = 0
        while i < t.count {
            let atStart = i == 0 || endsSentence(t[i - 1])
            guard atStart else { i += 1; continue }
            var removed = false
            for len in 1...4 where i + len < t.count {
                let frag = Array(t[i..<(i + len)])
                guard let last = frag.last, endsClause(last), !endsSentence(last) else { continue }
                if frag.dropLast().contains(where: endsClause) { break }
                let rest = Array(t[(i + len)...])
                guard rest.count > len, rest[0].lower == frag[0].lower else { continue }
                guard (1..<len).allSatisfy({ similarWord(frag[$0].lower, rest[$0].lower) }) else { continue }
                var keep = rest
                if var f = keep.first, let c = f.text.first, frag[0].text.first?.isUppercase == true {
                    f.text = String(c).uppercased() + f.text.dropFirst(); keep[0] = f
                }
                t = Array(t[..<i]) + keep
                n += 1; removed = true
                break
            }
            if !removed { i += 1 }
        }
        return n > 0 ? (join(t), n) : (input, 0)
    }

    private static func similarWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 2, b.hasPrefix(a) { return true }        // abgebrochen: „ha“ → „habe“
        if b.count >= 2, a.hasPrefix(b) { return true }
        return a.count >= 3 && b.count >= 3 && VocabTrigger.levenshtein(Array(a), Array(b)) <= 1
    }

    // MARK: Aufzählungen

    private struct ListFamily { let id: String; let words: [[String]]; let firstAnywhere: Bool }
    private static let families: [ListFamily] = [
        ListFamily(id: "ens", words: [["erstens"], ["zweitens"], ["drittens"], ["viertens"], ["fünftens"], ["sechstens"], ["siebtens"]], firstAnywhere: true),
        ListFamily(id: "punkt", words: [["punkt eins", "punkt 1"], ["punkt zwei", "punkt 2"], ["punkt drei", "punkt 3"], ["punkt vier", "punkt 4"], ["punkt fünf", "punkt 5"], ["punkt sechs", "punkt 6"]], firstAnywhere: true),
        ListFamily(id: "nummer", words: [["nummer eins", "nummer 1"], ["nummer zwei", "nummer 2"], ["nummer drei", "nummer 3"], ["nummer vier", "nummer 4"], ["nummer fünf", "nummer 5"]], firstAnywhere: true),
        ListFamily(id: "als", words: [["als erstes"], ["als zweites"], ["als drittes"], ["als viertes"], ["als fünftes"]], firstAnywhere: false),
        ListFamily(id: "platz", words: [["auf platz eins", "auf platz 1", "platz eins", "platz 1"], ["auf platz zwei", "auf platz 2", "platz zwei", "platz 2"], ["auf platz drei", "auf platz 3", "platz drei", "platz 3"], ["auf platz vier", "auf platz 4", "platz vier", "platz 4"], ["auf platz fünf", "auf platz 5", "platz fünf", "platz 5"]], firstAnywhere: true),
        ListFamily(id: "lly", words: [["firstly"], ["secondly"], ["thirdly"], ["fourthly"], ["fifthly"]], firstAnywhere: true),
        ListFamily(id: "ly", words: [["first"], ["second"], ["third"], ["fourth"], ["fifth"], ["sixth"]], firstAnywhere: false),
        ListFamily(id: "number", words: [["number one", "number 1"], ["number two", "number 2"], ["number three", "number 3"], ["number four", "number 4"], ["number five", "number 5"]], firstAnywhere: true),
        ListFamily(id: "point", words: [["point one", "point 1"], ["point two", "point 2"], ["point three", "point 3"], ["point four", "point 4"]], firstAnywhere: true),
    ]

    /// Fundstellen (Bereich des Markers) in Reihenfolge 1, 2, 3 … – nur an Satz-/Teilsatzgrenzen
    /// (eindeutige erste Marker wie „erstens“, „firstly“, „Punkt eins“ auch mitten im Satz)
    static func listMarkers(_ s: String) -> [NSRange] {
        let ns = s as NSString
        var best: [NSRange] = []
        let boundary = "(?:^|(?<=[,.;:!?])\\s*|\\s(?:und|and|dann|then|sowie)\\s+)"
        for fam in families {
            var found: [NSRange] = []
            var from = 0
            for alts in fam.words {
                let alt = alts.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
                let lead = found.isEmpty && fam.firstAnywhere ? "(?:^|(?<=[\\s,.;:!?]))" : boundary
                let pat = "(?i)\(lead)(\(alt))(?![\\p{L}\\p{N}])[,:.]?"
                guard let re = cachedRegex(pat) else { break }
                guard let m = re.firstMatch(in: s, range: NSRange(location: from, length: ns.length - from)) else { break }
                found.append(m.range(at: 1))
                from = m.range.location + m.range.length
            }
            if found.count >= 2, found.count > best.count { best = found }
        }
        return best.count >= 2 ? best : []
    }

    /// Kompilierte Muster merken – listMarkers läuft je Diktat mehrfach (Regeln, needsAI, Wächter); neu kompilieren kostete ~1,5 ms
    private static let regexLock = NSLock()
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock(); defer { regexLock.unlock() }
        if let r = regexCache[pattern] { return r }
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = r
        return r
    }

    static func formatLists(_ input: String) -> (String, Int) {
        let ms = listMarkers(input)
        guard ms.count >= 2 else { return (input, 0) }
        let ns = input as NSString
        func markerEnd(_ r: NSRange) -> Int {
            var e = r.location + r.length
            while e < ns.length, ",:.".contains(ns.substring(with: NSRange(location: e, length: 1))) { e += 1 }
            return e
        }
        var items: [String] = []
        for (k, r) in ms.enumerated() {
            let start = markerEnd(r)
            let end = k + 1 < ms.count ? ms[k + 1].location : ns.length
            items.append(ns.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
        // Letzter Punkt endet beim ersten Satzende – danach kommt wieder normaler Text
        var tail = ""
        if var last = items.last {
            if let re = try? NSRegularExpression(pattern: "[.!?](\\s+)(?=\\p{Lu})"),
               let m = re.firstMatch(in: last, range: NSRange(location: 0, length: (last as NSString).length)) {
                let lns = last as NSString
                tail = lns.substring(from: m.range.location + 1).trimmingCharacters(in: .whitespaces)
                last = lns.substring(to: m.range.location + 1)
            }
            items[items.count - 1] = last
        }
        func clean(_ s: String) -> String {
            var x = s.trimmingCharacters(in: .whitespacesAndNewlines)
            x = x.replacingOccurrences(of: "(?i)[,;]?\\s+(und|and|dann|then|sowie)[,.;]?$", with: "", options: .regularExpression)
            x = x.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.\n"))
            // „Platz eins ist Inception“ → „Inception“
            x = x.replacingOccurrences(of: "(?i)^(ist|is|sind|are)\\s+", with: "", options: .regularExpression)
            if let c = x.first { x = String(c).uppercased() + x.dropFirst() }
            return x
        }
        let cleaned = items.map(clean)
        guard cleaned.allSatisfy({ !$0.isEmpty && $0.split(separator: " ").count <= 30 }) else { return (input, 0) }
        var intro = ns.substring(to: ms[0].location).trimmingCharacters(in: .whitespacesAndNewlines)
        intro = intro.replacingOccurrences(of: "(?i)[,;]?\\s*(und|and)$", with: "", options: .regularExpression)
        intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        if !intro.isEmpty, let l = intro.last, !":?!".contains(l) { intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ":" }
        var out = (intro.isEmpty ? "" : intro + "\n") + cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !tail.isEmpty { out += "\n\n" + tail }
        return (out, 1)
    }

    // MARK: Satzzeichen

    private static let questionStarts: Set<String> = ["wer", "was", "wann", "wo", "wie", "warum", "wieso", "weshalb", "welche", "welcher",
        "welches", "kannst", "könntest", "hast", "bist", "willst", "möchtest", "sollen", "sollten", "soll", "können", "kann", "hat", "ist",
        "gibt", "habt", "seid", "what", "when", "where", "who", "why", "how", "which", "can", "could", "would", "should", "do", "does",
        "did", "is", "are", "was", "were", "have", "has", "will", "shall"]

    /// Fehlendes Schlusszeichen ergänzen (nicht bei Listen/Code, nicht bei 1–2 Wörtern)
    static func finalPunctuation(_ s: String) -> (String, Int) {
        let lastLine = s.components(separatedBy: "\n").last ?? s
        guard let last = lastLine.last, last.isLetter || last.isNumber else { return (s, 0) }
        if lastLine.range(of: "^(\\d+\\.|[-•]|- \\[ \\])\\s", options: .regularExpression) != nil { return (s, 0) }
        guard lastLine.split(separator: " ").count >= 3 else { return (s, 0) }
        if s.contains("`") || s.contains("{") || s.contains("()") { return (s, 0) }
        let sentence = lastLine.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? lastLine
        let first = sentence.split(separator: " ").first.map { bare(String($0)).lowercased() } ?? ""
        return (s + (questionStarts.contains(first) ? "?" : "."), 1)
    }
}

/// Kleine Hilfe: sieht ein Wort nach Eigenname/Bezeichner aus (Großbuchstabe im Inneren)?
enum NameBoosterLike {
    static func properLike(_ w: String) -> Bool { w.dropFirst().contains(where: \.isUppercase) }
}
