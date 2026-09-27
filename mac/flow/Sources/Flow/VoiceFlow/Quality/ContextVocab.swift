import AppKit
import Foundation
import NaturalLanguage

/// Welche Art App gerade vorne ist – entscheidet, welche Wörter vom Bildschirm zählen (Code nur im Editor/Terminal).
enum ContextAppKind: String, Sendable {
    case editor, terminal, mail, chat, browser, notes, other

    static func of(bundleID: String) -> ContextAppKind {
        let b = bundleID.lowercased()
        if ["com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.google.antigravity",
            "com.apple.dt.xcode", "com.jetbrains", "com.sublimetext", "dev.zed.zed", "com.panic.nova"].contains(where: { b.hasPrefix($0) }) { return .editor }
        if ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp", "net.kovidgoyal.kitty",
            "io.alacritty"].contains(where: { b.hasPrefix($0) }) { return .terminal }
        if ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "it.bloop.airmail"].contains(where: { b.hasPrefix($0) }) { return .mail }
        if ["com.tinyspeck.slackmacgap", "net.whatsapp", "desktop.whatsapp", "com.apple.mobilesms", "ru.keepcoder.telegram",
            "org.telegram", "com.hnc.discord", "org.whispersystems.signal", "com.microsoft.teams"].contains(where: { b.hasPrefix($0) }) { return .chat }
        if ["com.google.chrome", "com.apple.safari", "company.thebrowser", "org.mozilla.firefox", "com.brave.browser",
            "com.microsoft.edgemac", "com.operasoftware", "com.vivaldi"].contains(where: { b.hasPrefix($0) }) { return .browser }
        if ["com.apple.notes", "com.apple.iwork.pages", "com.microsoft.word", "notion.id", "md.obsidian", "com.apple.textedit",
            "net.shinyfrog.bear", "com.ulyssesapp"].contains(where: { b.hasPrefix($0) }) { return .notes }
        return .other
    }

    /// Code-Bezeichner zählen voll nur hier (sonst ist „camelCase“ auf einer Webseite meist Zufall)
    var codeFriendly: Bool { self == .editor || self == .terminal }
}

/// Ein Begriff vom Bildschirm, der im Diktat vorkommen könnte.
struct ContextTerm: Sendable, Equatable {
    enum Kind: String, Sendable { case person, organization, place, name, rare, code, handle, email }
    let text: String
    let kind: Kind
    /// höher = wichtiger (Seltenheit + Nähe zum Cursor + Häufigkeit)
    let score: Double
    /// kein echtes Wort (Rechtschreibprüfung DE+EN kennt es nicht) – nur solche lösen die Whisper-Prüfung aus
    let unknownWord: Bool
}

/// Rohtext eines Fensters in Stücken: das fokussierte Feld (mit Cursor), der Fenstertitel und der Rest.
struct ContextText: Sendable {
    var focused: String = ""
    /// Cursor-Position im fokussierten Text (Zeichen, UTF-16); nil = unbekannt
    var cursor: Int? = nil
    var title: String = ""
    /// Übrige sichtbare Texte in Baum-Reihenfolge, mit Abstand (Knoten) zum fokussierten Element
    var others: [(text: String, distance: Int)] = []
    var appKind: ContextAppKind = .other

    var isEmpty: Bool { focused.isEmpty && title.isEmpty && others.isEmpty }
    var charCount: Int { focused.count + title.count + others.reduce(0) { $0 + $1.text.count } }
}

/// Holt aus Bildschirmtext die Begriffe, die Spracherkennung typischerweise verhört: Namen, seltene Wörter,
/// Code-Bezeichner, E-Mail-Adressen und @-Handles. Rein rechnend (kein AX, kein Speichern) – testbar.
enum ContextVocab {
    static var maxTerms = 30

    /// Wochentage/Monate/Grüße sind groß geschrieben und „Namen“ für NLTagger, aber nie ein Problem für die Erkennung
    private static let common: Set<String> = [
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "januar", "februar", "märz", "april", "mai", "juni", "juli", "august",
        "september", "oktober", "november", "dezember", "january", "february", "march", "may", "june", "july", "october",
        "december", "hallo", "hello", "hey", "danke", "thanks", "viele", "grüße", "liebe", "lieber", "beste", "best", "regards",
        "herr", "herrn", "frau", "dear", "hi", "moin", "servus", "ok", "okay", "gmail", "google", "apple", "icloud", "com", "www", "http",
        "https", "html", "true", "false", "null", "nil", "self", "this", "return", "func", "let", "var", "const", "import",
        "the", "and", "und", "der", "die", "das",
    ]
    /// Nach diesen Wörtern steht meist ein Name („Hallo Anneliese“, „Herrn Okonkwo“, „Dear Rafael“)
    private static let nameCues: Set<String> = ["hallo", "hi", "hey", "liebe", "lieber", "dear", "herr", "herrn", "frau", "dr",
        "prof", "mr", "mrs", "ms", "moin", "servus"]
    /// Kopfzeilen („Von: Anneliese Okonkwo“, „To: …“) – nur mit Doppelpunkt ein Namens-Hinweis
    private static let headerCues: Set<String> = ["von", "an", "from", "to", "cc", "bcc", "kopie"]

    struct Token { let text: String; let start: Int; let afterCue: Bool; let sentenceStart: Bool }

    /// Hauptfunktion. `isRealWord` wird für eine Liste von Wörtern auf einmal gefragt (Rechtschreibprüfung).
    static func extract(_ ctx: ContextText, isUnknown: ([String]) -> Set<String> = SpellBatch.unknown) -> [ContextTerm] {
        struct Acc { var display: String; var kind: ContextTerm.Kind; var base: Double; var count: Int; var prox: Double; var unknown: Bool }
        var acc: [String: Acc] = [:]
        func add(_ raw: String, _ kind: ContextTerm.Kind, base: Double, prox: Double, unknown: Bool = false) {
            let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}<>«»„“”‘’`*|"))
            guard t.count >= 3, t.count <= 48 else { return }
            let k = t.lowercased()
            if common.contains(k) { return }
            if var a = acc[k] {
                a.count += 1; a.prox = max(a.prox, prox); a.unknown = a.unknown || unknown
                if base > a.base { a.base = base; a.kind = kind; a.display = t }
                acc[k] = a
            } else {
                acc[k] = Acc(display: t, kind: kind, base: base, count: 1, prox: prox, unknown: unknown)
            }
        }

        // Quellen mit Nähe-Wert: fokussiertes Feld (je Wort nach Abstand zum Cursor), Titel, Rest (nach Baum-Abstand)
        var chunks: [(text: String, prox: (Int) -> Double)] = []
        if !ctx.focused.isEmpty {
            let f = ctx.focused as NSString
            // Große Felder (ganzer Editor-Inhalt) auf ±4000 Zeichen um den Cursor beschränken
            var lo = 0, hi = f.length
            // Audit 27.09.2026: Cursor auf das Feld begrenzen – lag er hinter dem (gekürzten) Text, wurde die Länge
            // negativ → NSRangeException → Absturz der ganzen App.
            let cursor = ctx.cursor.map { min(max(0, $0), f.length) }
            if let c = cursor, f.length > 8000 { lo = max(0, c - 4000); hi = min(f.length, c + 4000) }
            else if f.length > 8000 { lo = f.length - 8000 }
            hi = max(lo, hi)
            let win = f.rangeOfComposedCharacterSequences(for: NSRange(location: lo, length: hi - lo))
            let text = f.substring(with: win)
            let cur = cursor.map { $0 - win.location }
            chunks.append((text, { pos in
                guard let cur else { return 1.0 }
                return 1.0 + 1.0 / (1.0 + Double(abs(pos - cur)) / 300.0)
            }))
        }
        if !ctx.title.isEmpty { chunks.append((ctx.title, { _ in 0.9 })) }
        // Viele kleine Texte (Web-Seiten, Terminal-Zeilen) nach Abstand zum Cursor-Feld bündeln – sonst kostet
        // jedes Stückchen eigene Regex-/Tagger-Läufe (gemessen: VS Code 14 700 Zeichen in 1 500 Stücken 400 ms → gebündelt ~40 ms)
        let buckets: [(limit: Int, prox: Double)] = [(8, 0.75), (30, 0.6), (80, 0.45), (200, 0.3), (Int.max, 0.2)]
        var grouped = [String](repeating: "", count: buckets.count)
        for o in ctx.others.prefix(3000) {
            let k = buckets.firstIndex { o.distance < $0.limit } ?? buckets.count - 1
            grouped[k] += (grouped[k].isEmpty ? "" : "\n") + o.text
        }
        for (k, g) in grouped.enumerated() where !g.isEmpty {
            let pr = buckets[k].prox
            chunks.append((g, { _ in pr }))
        }
        var budget = 30_000
        var candidates: [(tok: Token, prox: Double)] = []
        var nlText = ""
        var nlProx: [(range: NSRange, prox: Double)] = []
        for (text, proxFn) in chunks {
            guard budget > 0 else { break }
            let t = text.count > budget ? String(text.prefix(budget)) : text
            budget -= t.count
            // E-Mail-Adressen und @-Handles zuerst (und aus dem Text nehmen, damit sie nicht zerlegt werden)
            var rest = t as NSString
            for m in emailRE.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)).reversed() {
                let email = rest.substring(with: m.range)
                add(email, .email, base: 1.4, prox: proxFn(m.range.location))
                // Namensteile der Adresse („anneliese.okonkwo@…“) sind gute Namens-Hinweise
                let local = email.split(separator: "@").first.map(String.init) ?? ""
                for part in local.split(whereSeparator: { ".-_".contains($0) }) where part.count >= 3 && part.allSatisfy(\.isLetter) {
                    add(part.prefix(1).uppercased() + part.dropFirst(), .name, base: 1.6, prox: proxFn(m.range.location))
                }
                rest = rest.replacingCharacters(in: m.range, with: String(repeating: " ", count: m.range.length)) as NSString
            }
            for m in handleRE.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                add(rest.substring(with: m.range(at: 1)), .handle, base: 2.2, prox: proxFn(m.range.location))
            }
            let s = rest as String
            for tok in tokens(s) {
                candidates.append((tok, proxFn(tok.start)))
            }
            let r = NSRange(location: (nlText as NSString).length, length: (s as NSString).length)
            nlProx.append((r, proxFn(0)))
            nlText += s + "\n"
        }

        let tA = Date()
        // Code-Bezeichner und Dateinamen
        var plain: [(Token, Double)] = []
        for (tok, prox) in candidates {
            let w = tok.text
            if let kind = codeKind(w) {
                let base = ctx.appKind.codeFriendly ? 3.0 : (kind == 2 ? 1.2 : 1.6)
                add(w, .code, base: base, prox: prox, unknown: true)
                continue
            }
            plain.append((tok, prox))
        }

        // Seltene Wörter: Rechtschreibprüfung DE+EN (in einem Rutsch), nur Buchstaben-Wörter ≥ 4
        let letterWords = Set(plain.map { $0.0.text }.filter { $0.count >= 4 && $0.count <= 30 && $0.allSatisfy { $0.isLetter || $0 == "-" } })
        let tB = Date()
        let unknown = isUnknown(Array(letterWords))
        let tC = Date()
        for (tok, prox) in plain {
            let w = tok.text
            guard w.count >= 3 else { continue }
            let cap = w.first?.isUppercase ?? false
            if unknown.contains(w) {
                if cap { add(w, .name, base: tok.sentenceStart ? 2.6 : 3.0, prox: prox, unknown: true) }
                else if w.count >= 5 { add(w, .rare, base: ctx.appKind.codeFriendly ? 2.4 : 1.8, prox: prox, unknown: true) }
            } else if cap, tok.afterCue, w.count >= 3, w.allSatisfy(\.isLetter) {
                // echtes Wort, aber an Namens-Stelle („Hallo Anneliese“)
                add(w, .name, base: 2.0, prox: prox)
            }
        }

        // NLTagger: Personen/Firmen/Orte (auch echte Wörter wie „Anneliese“), nur groß geschriebene
        // Im Editor/Terminal nicht (Code verwirrt den Tagger: 10 000 Zeichen kosteten 350 ms) – dort reichen Rechtschreibung + Code-Muster.
        // Sonst höchstens 8 000 Zeichen (die nächsten am Cursor stehen vorne) und Sprache fest vorgeben.
        if !ctx.appKind.codeFriendly, !nlText.isEmpty {
            if (nlText as NSString).length > 8000 { nlText = (nlText as NSString).substring(to: 8000) }
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = nlText
            let rec = NLLanguageRecognizer()
            rec.languageConstraints = [.german, .english]
            rec.processString(String(nlText.prefix(2000)))
            if let lang = rec.dominantLanguage { tagger.setLanguage(lang, range: nlText.startIndex..<nlText.endIndex) }
            let ns = nlText as NSString
            tagger.enumerateTags(in: nlText.startIndex..<nlText.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
                guard let tag, tag == .personalName || tag == .organizationName || tag == .placeName else { return true }
                let span = String(nlText[r])
                let loc = NSRange(r, in: nlText).location
                // Stück finden (binäre Suche, die Stücke liegen hintereinander)
                var lo = 0, hi = nlProx.count - 1
                while lo < hi { let mid = (lo + hi + 1) / 2; if nlProx[mid].range.location <= loc { lo = mid } else { hi = mid - 1 } }
                let prox = nlProx.isEmpty ? 0.5 : nlProx[lo].prox
                let kind: ContextTerm.Kind = tag == .personalName ? .person : (tag == .organizationName ? .organization : .place)
                let parts = span.split(separator: " ").map(String.init).filter { !nameCues.contains($0.lowercased()) && !headerCues.contains($0.lowercased()) && !common.contains($0.lowercased()) }
                for p in parts where p.first?.isUppercase == true && p.count >= 3 {
                    let unk = unknown.contains(p)
                    add(p, kind, base: unk ? 3.0 : 1.5, prox: prox, unknown: unk)
                }
                if parts.count >= 2 { add(parts.joined(separator: " "), kind, base: 1.4, prox: prox) }
                _ = ns
                return true
            }
        }

        if ProcessInfo.processInfo.environment["VF_PROFILE"] != nil {
            print(String(format: "  profil: zerlegen+code %.0f ms, rechtschreibung %.0f ms (%d Wörter), tagger %.0f ms, %d Zeichen", tB.timeIntervalSince(tA) * 1000,
                         tC.timeIntervalSince(tB) * 1000, letterWords.count, Date().timeIntervalSince(tC) * 1000, (nlText as NSString).length))
        }
        let scored = acc.values.map { a -> ContextTerm in
            let s = a.base + a.prox + 0.35 * log2(Double(a.count))
            return ContextTerm(text: a.display, kind: a.kind, score: s, unknownWord: a.unknown)
        }
        return Array(scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }.prefix(maxTerms))
    }

    // MARK: Zerlegen

    private static let emailRE = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}")
    private static let handleRE = try! NSRegularExpression(pattern: "(?<![\\w@])@([A-Za-z][A-Za-z0-9._-]{2,30})")
    private static let wordRE = try! NSRegularExpression(pattern: "[\\p{L}_][\\p{L}\\p{N}_]*(?:[.\\-][\\p{L}\\p{N}_]+)*")

    /// Wörter mit Position; merkt sich Satzanfang und ob davor ein Namens-Hinweis stand
    static func tokens(_ s: String) -> [Token] {
        let ns = s as NSString
        var out: [Token] = []
        var prevLower = ""
        var lastEnd = 0
        for m in wordRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            let gap = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            let sentenceStart = out.isEmpty || gap.contains(where: { ".!?\n:•·|>".contains($0) })
            let cue = (nameCues.contains(prevLower) && !gap.contains("\n"))
                || (headerCues.contains(prevLower) && gap.trimmingCharacters(in: .whitespaces) == ":")
            out.append(Token(text: w, start: m.range.location, afterCue: cue, sentenceStart: sentenceStart))
            prevLower = w.lowercased()
            lastEnd = m.range.location + m.range.length
            if out.count > 6000 { break }
        }
        return out
    }

    /// 0 = kein Code; 1 = camelCase/PascalCase mit Buckeln oder snake_case; 2 = Dateiname („main.swift“)
    static func codeKind(_ w: String) -> Int? {
        guard w.count >= 4, w.count <= 48 else { return nil }
        let letters = w.filter(\.isLetter)
        guard letters.count >= 3 else { return nil }
        if w.contains("_"), w.split(separator: "_").filter({ !$0.isEmpty }).count >= 2, w.first != "_" || w.count > 5 {
            return 1
        }
        if let dot = w.lastIndex(of: "."), w.distance(from: dot, to: w.endIndex) <= 6 {
            let ext = String(w[w.index(after: dot)...]).lowercased()
            if fileExtensions.contains(ext), w.distance(from: w.startIndex, to: dot) >= 2 { return 2 }
            return nil
        }
        if w.contains(".") { return nil }
        // Großbuchstabe nach Kleinbuchstabe im Wort („fetchUserProfile“, „ClipVault“, „iPhone“ nicht: nur 1 Buckel am Anfang)
        let chars = Array(w)
        var humps = 0
        for i in 1..<chars.count where chars[i].isUppercase && chars[i - 1].isLowercase { humps += 1 }
        if humps >= 2 || (humps == 1 && chars[0].isLowercase && chars.count >= 7 && !w.hasPrefix("i") && !w.hasPrefix("e")) { return 1 }
        if humps == 1, chars[0].isUppercase, chars.count >= 6 { return 1 }   // PascalCase: „UserStore“, „ClipVault“
        return nil
    }

    private static let fileExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "yml", "yaml", "toml",
        "rs", "go", "java", "kt", "rb", "php", "c", "h", "cpp", "hpp", "m", "mm", "sh", "css", "scss", "html", "sql", "txt", "csv", "env", "plist", "xml"]

    /// Teile eines Bezeichners („fetchUserProfile“ → fetch user profile; „get_user_by_id“ → get user by id)
    static func identifierParts(_ w: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        let chars = Array(w)
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "-" || c == "." { if !cur.isEmpty { parts.append(cur) }; cur = ""; continue }
            if c.isUppercase, !cur.isEmpty, i > 0, chars[i - 1].isLowercase || (i + 1 < chars.count && chars[i + 1].isLowercase && chars[i - 1].isUppercase) {
                parts.append(cur); cur = ""
            }
            cur.append(c)
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.map { $0.lowercased() }
    }
}

/// Rechtschreibprüfung für viele Wörter auf einmal: EIN Aufruf je Sprache über den ganzen Wortblock
/// (gemessen: 400 Wörter ~13 ms statt ~95 ms einzeln). Läuft auf jedem Thread (kein Main-Thread-Sprung).
enum SpellBatch {
    static func unknown(_ words: [String]) -> Set<String> {
        guard !words.isEmpty else { return [] }
        // Wörter mit Großbuchstaben im Inneren überspringt die Prüfung → nie „bekannt“
        var result = Set(words.filter { $0.dropFirst().contains(where: \.isUppercase) })
        let rest = words.filter { !result.contains($0) }
        guard !rest.isEmpty else { return result }
        var unknownIn: [String: Int] = [:]
        let sc = NSSpellChecker.shared
        for lang in ["de", "en"] {
            // Vorsatz „und“: das erste Wort eines Textes gilt sonst als Satzanfang („siobhan“ wäre dann richtig)
            let joined = "und " + rest.joined(separator: " ")
            let ns = joined as NSString
            let orth = NSOrthography(dominantScript: "Latn", languageMap: ["Latn": [lang]])
            let r = sc.check(joined, range: NSRange(location: 0, length: ns.length), types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                             options: [.orthography: orth], inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
            for m in r where m.resultType == .spelling && m.range.location >= 4 { unknownIn[ns.substring(with: m.range), default: 0] += 1 }
        }
        for (w, n) in unknownIn where n >= 2 { result.insert(w) }
        return result
    }
}
