import Foundation

// MARK: - Agent-Prompt: reine Logik (ohne Oberfläche, ohne KI) – alles testbar über --selftest-agent-prompt
//
//   APTrigger.match("Prompt: bau mir …")          → Auslöser erkannt, Rest = Diktat für den Prompt (Auslöser weg)
//   APDetector.detect(text:duration:bundleID:title:) → Punktzahl + Gründe: sieht das wie ein langer Auftrag an einen Agenten aus?
//   APRules.structure(_:context:)                  → Rückfall ohne Claude: Sätze in Ziel/Kontext/Aufgabe/… sortieren
//   APGist.of(_:)                                  → Kurzzeile für die Karte („Ziel … · 5 Anforderungen“)

enum APText {
    static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    static func regex(_ p: String) -> NSRegularExpression {
        if let r = QuickPolish.cachedRegex(p) { return r }
        return try! NSRegularExpression(pattern: "(?!)")
    }

    static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func count(_ re: NSRegularExpression, _ s: String) -> Int {
        re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first, f.isLowercase else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    /// Sprache des Diktats (nur DE/EN) – für Überschriften und die Anweisung an Claude
    static func isEnglish(_ s: String) -> Bool {
        let t = s.lowercased()
        // Kurze, eindeutige Wörter zählen (NLLanguageRecognizer kippt bei Denglisch zu oft Richtung Englisch)
        let de = count(regex(#"\b(und|der|die|das|ich|nicht|bitte|ist|mit|auf|für|dass|wir|soll|auch|mal|noch|den|dem|ein|eine|einen)\b"#), t)
        let en = count(regex(#"\b(and|the|is|i|not|please|with|for|that|we|should|also|this|to|of|a|an|it|you)\b"#), t)
        if de + en < 3 { return LanguageGuard.guessDeEn(s) == "en" }
        return en > de * 2
    }
}

// MARK: - Auslöser („Prompt: …“, „Ich mache jetzt einen Prompt …“, „… mach daraus einen Prompt“)

enum APTrigger {
    struct Match: Equatable {
        /// Diktat ohne Auslöser (erster Buchstabe groß)
        let body: String
        /// Was als Auslöser erkannt wurde (fürs Protokoll/Tests)
        let phrase: String
        let atEnd: Bool
    }

    /// „Prompt“ inkl. typischer Verhörer von Parakeet/Whisper („Promt“, „Brompt“, „Prompf“ …)
    static let p = #"(?:prompts?|promts?|prompd|prompt[ea]|brompts?|bromts?|prompf|promp|pomt|prompt's)"#
    /// „Agent“ inkl. Verhörer („Agenten“, „Eigent“, „Agend“, „Ägent“)
    static let agent = #"(?:agent(?:en|s)?|agend|eigent|ägent|aged)"#
    /// Wen der Prompt anspricht
    static let who = #"(?:(?:den|die|das|meinen|meine|unseren|my|the)\s+)?(?:\#(agent)|claude(?:\s+code)?|cloud(?:\s+code)?|codex|ki|chat\s*gpt|cursor)"#
    /// Füllwörter vor dem Auslöser
    static let lead = #"^(?:(?:okay|ok|also|so|gut|ja|äh|ähm|hm|und|well|alright|right|hey|jetzt|genau|nun)[\s,.:!…-]+){0,3}"#
    static let sep = #"(?:\s*[:,.;!?…–—-]+\s*|\s+|$)"#

    /// Starke Auslöser am Anfang (lösen immer aus)
    static let strongStart: [String] = [
        // Ich mache jetzt (mal) einen (neuen) (Agent-)Prompt / ich diktier dir einen Prompt
        #"ich\s+(?:mach(?:e)?|schreib(?:e)?|bau(?:e)?|diktier(?:e)?|sprech(?:e)?)\s+(?:dir\s+|euch\s+)?(?:jetzt\s+)?(?:mal\s+)?(?:schnell\s+)?(?:einen|ein|nen|'nen|n)\s+(?:neuen\s+|kurzen\s+|langen\s+)?(?:\#(agent)[\s-]*)?\#(p)(?:\s+(?:für|an)\s+\#(who))?"#,
        // Jetzt kommt ein Prompt
        #"(?:jetzt\s+)?(?:kommt|folgt)\s+(?:jetzt\s+)?(?:ein(?:en)?|der|mein)\s+(?:neuer\s+)?(?:\#(agent)[\s-]*)?\#(p)(?:\s+(?:für|an)\s+\#(who))?"#,
        // Agent-Prompt / Agenten Prompt (für Claude)
        #"\#(agent)[\s-]*\#(p)(?:\s+(?:für|an|for)\s+\#(who))?"#,
        // Prompt für den Agenten / Prompt an Claude Code
        #"\#(p)\s+(?:für|an|for|to)\s+\#(who)"#,
        // Mach (mir) daraus einen Prompt / Mach mir einen Prompt
        #"(?:mach|mache|bau|baue|schreib|schreibe)\s+(?:mir\s+|uns\s+)?(?:bitte\s+)?(?:daraus\s+|draus\s+|hieraus\s+|davon\s+)?(?:bitte\s+)?(?:einen|ein|nen)\s+(?:guten\s+|starken\s+)?(?:\#(agent)[\s-]*)?\#(p)(?:\s+(?:daraus|draus))?"#,
        // Neuer Prompt / Prompt-Modus
        #"(?:neuer|neuen|new)\s+(?:\#(agent)[\s-]*)?\#(p)"#,
        #"\#(p)[\s-]*(?:modus|mode)"#,
        // I'm (going to) make a prompt / let me write a prompt / here's a prompt
        #"(?:i'?m|i\s+am)\s+(?:going\s+to\s+|gonna\s+|about\s+to\s+)?(?:make|making|write|writing|do|doing|dictate|dictating|build|building)\s+(?:a|an|the)\s+(?:new\s+|quick\s+)?(?:agent\s+)?\#(p)(?:\s+(?:for|to)\s+\#(who))?"#,
        #"(?:let\s+me|let's|lets)\s+(?:make|write|do|dictate|build)\s+(?:a|an)\s+(?:new\s+|quick\s+)?(?:agent\s+)?\#(p)(?:\s+(?:for|to)\s+\#(who))?"#,
        #"(?:make|turn)\s+(?:this|that|it)\s+(?:into\s+)?(?:a|an)\s+(?:agent\s+)?\#(p)"#,
        #"here'?s\s+(?:a|an|the)\s+(?:new\s+)?(?:agent\s+)?\#(p)"#,
    ]

    /// Auslöser am Ende („…, mach daraus einen Prompt.“)
    static let strongEnd: [String] = [
        #"(?:und\s+)?(?:bitte\s+)?(?:mach|mache|bau|baue)\s+(?:mir\s+|uns\s+)?(?:bitte\s+)?(?:daraus|draus|davon|hieraus)\s+(?:bitte\s+)?(?:einen|ein|nen)\s+(?:guten\s+|starken\s+|sauberen\s+)?(?:\#(agent)[\s-]*)?\#(p)(?:\s+(?:für|an)\s+\#(who))?(?:\s+bitte)?"#,
        #"(?:and\s+)?(?:please\s+)?(?:make|turn)\s+(?:this|that|it)\s+into\s+(?:a|an)\s+(?:good\s+|strong\s+|clean\s+)?(?:agent\s+)?\#(p)(?:\s+(?:for|to)\s+\#(who))?(?:\s+please)?"#,
        #"(?:das\s+)?(?:bitte\s+)?als\s+(?:\#(agent)[\s-]*)?\#(p)(?:\s+(?:für|an)\s+\#(who))?(?:\s+bitte)?"#,
    ]

    /// Nach einem nackten „Prompt“ am Anfang: diese Wörter heißen „über Prompts reden“, nicht „Prompt-Modus“
    static let bareBlock: Set<String> = ["ist", "war", "hat", "wird", "wurde", "sind", "waren", "engineering", "injection", "injections",
                                         "design", "library", "bibliothek", "vorlage", "vorlagen", "template", "templates", "is", "was",
                                         "has", "will", "are", "were", "der", "die", "das", "des", "caching", "cache", "länge", "fenster",
                                         "window", "tuning", "optimierung", "technik", "techniken", "beispiele", "examples", "ly"]

    static func match(_ text: String) -> Match? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let ns = t as NSString
        let full = NSRange(location: 0, length: ns.length)
        let leadRe = APText.regex("(?i)" + lead)
        let leadLen = leadRe.firstMatch(in: t, range: full)?.range.length ?? 0

        // 1) Starke Auslöser am Anfang
        for pat in strongStart {
            let re = APText.regex("(?i)^(?:" + pat + ")" + sep)
            let rest = ns.substring(from: leadLen)
            if let m = APText.firstMatch(re, rest), m.range.location == 0 {
                let phrase = (rest as NSString).substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                let body = (rest as NSString).substring(from: m.range.length)
                if let r = finish(body, phrase: phrase, atEnd: false) { return r }
            }
        }
        // 2) Starke Auslöser am Ende
        for pat in strongEnd {
            let re = APText.regex("(?i)(?:^|[\\s,.;:!?–—-]+)(?:" + pat + ")\\s*[.!…]*\\s*$")
            if let m = APText.firstMatch(re, t) {
                let body = ns.substring(to: m.range.location)
                let phrase = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if let r = finish(body, phrase: phrase, atEnd: true) { return r }
            }
        }
        // 3) Nacktes „Prompt“ am Anfang: nur mit Satzzeichen danach („Prompt: …“, „Promt, …“) oder mit echtem Auftrag dahinter
        let rest = ns.substring(from: leadLen)
        let bare = APText.regex("(?i)^(" + p + ")\\b\\s*([:,.;!–—-]*)\\s*")
        if let m = APText.firstMatch(bare, rest) {
            let r = rest as NSString
            let punct = m.range(at: 2).length > 0 ? r.substring(with: m.range(at: 2)) : ""
            let body = r.substring(from: m.range.length)
            let next = body.split(whereSeparator: { $0.isWhitespace || ",.;:!?".contains($0) }).first.map { String($0).lowercased() } ?? ""
            let phrase = r.substring(with: m.range(at: 1))
            if !punct.isEmpty && !punct.allSatisfy({ $0 == "-" }) {
                if let res = finish(body, phrase: phrase, atEnd: false, minWords: 3) { return res }
            } else if !bareBlock.contains(next), APText.words(body) >= 6 {
                if let res = finish(body, phrase: phrase, atEnd: false, minWords: 6) { return res }
            }
        }
        return nil
    }

    private static func finish(_ body: String, phrase: String, atEnd: Bool, minWords: Int = 3) -> Match? {
        var b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        b = b.replacingOccurrences(of: #"^[\s,.;:!?…–—-]+"#, with: "", options: .regularExpression)
        b = b.replacingOccurrences(of: #"[\s,;:–—-]+$"#, with: "", options: .regularExpression)
        guard APText.words(b) >= minWords else { return nil }
        if atEnd, let last = b.last, !".!?".contains(last) { b += "." }
        return Match(body: APText.capitalizedFirst(b), phrase: phrase, atEnd: atEnd)
    }
}

// MARK: - Automatisch erkennen: langer Auftrag an einen Agenten?

struct APDetection: Equatable {
    let score: Int
    let offer: Bool
    let reasons: [String]
    let words: Int
    let imperative: [String]
    let technical: [String]
    let agentApp: Bool
    let chatty: [String]

    /// Kurzform für die Karte: „142 Wörter · Auftrag für Claude Code“
    var cardLine: String {
        var parts = ["\(words) Wörter"]
        if agentApp { parts.append("klingt nach einem Auftrag für deinen Agenten") }
        else if !technical.isEmpty { parts.append("klingt nach einem Auftrag (\(technical.prefix(2).joined(separator: ", ")))") }
        else { parts.append("klingt nach einem Auftrag") }
        return parts.joined(separator: " · ")
    }
}

enum APDetector {
    /// Ab so vielen Punkten wird die Karte angeboten (zusätzlich zu den harten Bedingungen unten)
    static let threshold = 6

    static let imperativeRe = APText.regex(#"(?i)\b(bau|baue|bauen|baust|fix|fixe|fixen|fixt|implementier(?:e|en|st)?|prüf(?:e|en|st)?|pruef(?:e|en)?|check(?:e|en|st)?|teste|testen|recherchier(?:e|en)?|erstell(?:e|en)?|ergänz(?:e|en)?|änder(?:e|n)|entfern(?:e|en)?|lösch(?:e|en)?|refactor(?:e|n)?|refaktorier(?:e|en)?|analysier(?:e|en)?|debug(?:ge|gen)?|untersuch(?:e|en)?|migrier(?:e|en)?|installier(?:e|en)?|deploy(?:e|en)?|richte|stell\s+sicher|sorg(?:e)?\s+dafür|achte\s+darauf|schau\s+(?:dir\s+)?(?:mal\s+)?|guck\s+(?:dir\s+)?|lies|räum|ersetz(?:e|en)?|verschieb(?:e|en)?|benenn(?:e)?|füg(?:e)?|pass\s+(?:\w+\s+){0,3}an|build|implement|add|remove|delete|refactor|verify|investigate|research|rename|migrate|ensure|make\s+sure|look\s+into|figure\s+out|update|create|write|fix|summari[sz]e|propose|compare|evaluate|look\s+at|fass\s+(?:\w+\s+){0,4}zusammen|vergleich(?:e|en)?|schlag\s+(?:\w+\s+){0,3}vor|bewerte|dokumentier(?:e|en)?)\b"#)
    static let modalRe = APText.regex(#"(?i)\b(bitte|soll(?:st|en|te)?|musst|müssen|muss|brauche|brauchen|ich\s+will|ich\s+möchte|wir\s+wollen|please|should|must|need\s+to|needs\s+to|i\s+want|i\s+need\s+you\s+to|kannst\s+du)\b"#)
    static let techRe = APText.regex(#"(?i)\b(agent(?:en)?|claude(?:\s+code)?|codex|datei(?:en)?|funktion(?:en)?|repo(?:sitory)?|tests?|commit(?:s)?|branch(?:es)?|pull\s+request|api|endpoint|bug(?:s)?|fehlermeldung|build|deploy(?:ment)?|komponente(?:n)?|component(?:s)?|server|datenbank|database|code|swift|swiftui|typescript|javascript|python|react|next\.?js|npm|pnpm|git|github|skript|script|logs?|cli|terminal|backend|frontend|modul|module|klasse|class|methode|method|variable|parameter|json|sql|schema|migration|release|diff|pipeline|worker|config|konfiguration|feature|endpoint|query|queries|cache|hook|useeffect|state|refactoring|stack\s*trace|exception|crash|dependenc(?:y|ies)|library|package|framework|xcode|vs\s*code|cursor|linter|compiler|typ(?:en)?fehler|pr|ios|ipados|macos|core\s+data|design\s*doc|crdts?|open\s+source|offline\s+sync|ui\s*tests?|unit\s*tests?)\b"#)
    /// Dateien, Pfade, gesprochene Endungen, camelCase/snake_case, --Schalter (camelCase bewusst OHNE (?i) – sonst passt jedes Wort)
    static let fileRe = APText.regex(#"((?i:\b[\w-]+\.(?:swift|ts|tsx|js|jsx|py|md|json|sh|yml|yaml|css|html|go|rs|kt|java|rb|sql|toml|plist)\b)|(?i:\b(?:punkt|dot)\s+(?:swift|ts|tsx|js|py|json|md|sh|yaml|css|html)\b)|(?:^|\s)/[\w.-]+/[\w./-]+|(?i:\bslash\s+\w+)|\b[a-z]+[A-Z][A-Za-z]+\b|\b[A-Za-z]+_[A-Za-z_]+\b|(?:^|\s)--[a-z][\w-]+)"#)
    static let chattyRe = APText.regex(#"(?i)(^\s*(hallo|hi|hey|servus|moin|hallöchen|guten\s+morgen|guten\s+abend|liebe[rs]?|dear|hello|yo)\b|\b(liebe\s+grüße|viele\s+grüße|lg|bis\s+später|bis\s+dann|bis\s+morgen|hab\s+dich\s+lieb|kuss|küsschen|cheers|best\s+regards|kind\s+regards|love\s+you|miss\s+you|danke\s+dir|dankeschön|haha|hahaha|lol|mama|papa|schatz|omi|opa|geburtstag|urlaub|wochenende|abendessen)\b)"#)
    static let narrativeRe = APText.regex(#"(?i)\b(ich\s+war|wir\s+waren|gestern|heute\s+morgen|letzte\s+woche|ich\s+hab\s+gestern|i\s+was|we\s+were|yesterday|last\s+week)\b"#)

    /// Browser-Fenster mit Claude/ChatGPT im Titel zählen wie eine Agenten-App
    static func isAgentTarget(bundleID: String, title: String) -> Bool {
        if AppCategory.of(bundleID: bundleID) == .ai { return true }
        let t = title.lowercased()
        return ["claude", "chatgpt", "codex", "cursor", "gemini", "copilot"].contains { t.contains($0) }
    }

    static func detect(text: String, duration: Double, bundleID: String, title: String = "") -> APDetection {
        let words = APText.words(text)
        let lower = text.lowercased()
        func uniq(_ xs: [String]) -> [String] {
            var seen = Set<String>(); var out: [String] = []
            for x in xs { let k = x.lowercased().trimmingCharacters(in: .whitespaces); if seen.insert(k).inserted { out.append(k) } }
            return out
        }
        let imp = uniq(APText.matches(imperativeRe, text)) + uniq(APText.matches(modalRe, text)).map { "(\($0))" }
        let impHits = uniq(APText.matches(imperativeRe, text)).count
        let modalHits = min(2, uniq(APText.matches(modalRe, text)).count)
        let tech = uniq(APText.matches(techRe, text) + APText.matches(fileRe, text).map { $0.trimmingCharacters(in: .whitespaces) })
        let chatty = uniq(APText.matches(chattyRe, lower))
        let narrative = min(2, APText.count(narrativeRe, lower))
        let agentApp = isAgentTarget(bundleID: bundleID, title: title)
        let category = AppCategory.of(bundleID: bundleID)
        let personalApp = category == .personal || category == .email

        var lenPts = words >= 120 ? 3 : words >= 60 ? 2 : words >= 40 ? 1 : 0
        if words >= 25 { lenPts += duration >= 45 ? 2 : duration >= 25 ? 1 : 0 }
        lenPts = min(4, lenPts)
        var score = lenPts + min(4, impHits) + modalHits + min(4, tech.count) + (agentApp ? 3 : 0)
        score -= 2 * min(2, chatty.count) + narrative + (personalApp ? 3 : 0)

        let long = words >= 60 || (duration >= 25 && words >= 35)
        let signals = impHits + modalHits + tech.count
        var offer = long && score >= threshold
        if offer, !agentApp {
            // Ohne Agenten-App: echter Auftrag nötig (Verb + Technik oder viele Verben)
            offer = (impHits >= 1 && tech.count >= 2) || (impHits >= 2 && tech.count >= 1) || (impHits + modalHits >= 3 && tech.count >= 1)
        } else if offer, agentApp {
            offer = signals >= 1
        }
        if chatty.count >= 2 || (personalApp && !chatty.isEmpty) { offer = false }

        var reasons: [String] = ["\(words) Wörter"]
        if duration >= 1 { reasons.append(String(format: "%.0f s", duration)) }
        if !imp.isEmpty { reasons.append("Auftrag: " + imp.prefix(4).joined(separator: ", ")) }
        if !tech.isEmpty { reasons.append("Technik: " + tech.prefix(4).joined(separator: ", ")) }
        if agentApp { reasons.append("Ziel-App: Agent/Terminal") }
        if personalApp { reasons.append("Ziel-App: Nachricht/E-Mail") }
        if !chatty.isEmpty { reasons.append("Plaudern: " + chatty.prefix(3).joined(separator: ", ")) }
        if narrative > 0 { reasons.append("Erzählung") }
        if !long { reasons.append("zu kurz") }
        return APDetection(score: score, offer: offer, reasons: reasons, words: words, imperative: imp, technical: tech,
                           agentApp: agentApp, chatty: chatty)
    }
}

// MARK: - Kurzzeile + Aufbau eines fertigen Prompts

struct APGist: Equatable {
    var goal: String
    var tasks: Int
    var criteria: Int
    var rules: Int
    var open: Int

    var line: String {
        var s = goal.isEmpty ? "" : goal
        var parts: [String] = []
        if tasks > 0 { parts.append(tasks == 1 ? "1 Anforderung" : "\(tasks) Anforderungen") }
        if rules > 0 { parts.append(rules == 1 ? "1 Regel" : "\(rules) Regeln") }
        if open > 0 { parts.append(open == 1 ? "1 offener Punkt" : "\(open) offene Punkte") }
        if !parts.isEmpty { s += (s.isEmpty ? "" : " · ") + parts.joined(separator: " · ") }
        return s
    }

    static func of(_ prompt: String) -> APGist {
        var g = APGist(goal: "", tasks: 0, criteria: 0, rules: 0, open: 0)
        var section = ""
        for raw in prompt.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if g.goal.isEmpty, let m = APText.firstMatch(APText.regex(#"^\*{0,2}(?:Ziel|Goal)\s*:\s*\*{0,2}\s*(.+)$"#), l),
               let r = Range(m.range(at: 1), in: l) {
                g.goal = String(l[r]).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if l.hasPrefix("#") {
                let h = l.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                if h.hasPrefix("aufgabe") || h.hasPrefix("anforderung") || h.hasPrefix("task") || h.hasPrefix("requirement") || h.hasPrefix("schritte") || h.hasPrefix("steps") { section = "task" }
                else if h.hasPrefix("akzeptanz") || h.hasPrefix("acceptance") || h.hasPrefix("wie prüf") || h.hasPrefix("how to verify") { section = "crit" }
                else if h.hasPrefix("regel") || h.hasPrefix("rules") || h.hasPrefix("nicht tun") || h.hasPrefix("constraints") { section = "rules" }
                else if h.hasPrefix("offen") || h.hasPrefix("open") { section = "open" }
                else { section = "" }
                continue
            }
            let item = l.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) != nil
            guard item else { continue }
            switch section {
            case "task": g.tasks += 1
            case "crit": g.criteria += 1
            case "rules": g.rules += 1
            case "open": g.open += 1
            default: break
            }
        }
        if g.goal.isEmpty {
            // Kein „Ziel:“ – erste Zeile mit Inhalt
            g.goal = prompt.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*- ")) }
                .first { !$0.isEmpty } ?? ""
        }
        if g.goal.count > 110 { g.goal = String(g.goal.prefix(108)).trimmingCharacters(in: .whitespaces) + "…" }
        return g
    }
}

// MARK: - Konkrete Details (Zahlen, Dateien, Namen) – für die Prüfung „nichts verloren“

enum APDetails {
    static let numberRe = APText.regex(#"\b\d+(?:[.,]\d+)*\b"#)
    static let fileRe = APText.regex(#"\b[\w-]+\.(?:swift|ts|tsx|js|jsx|py|md|json|sh|yml|yaml|css|html|go|rs|kt|java|rb|sql|toml|plist)\b"#)
    static let nameRe = APText.regex(#"(?<![.!?]\s)(?<!^)\b\p{Lu}[\p{Ll}]+(?:[A-Z][a-z]+)*\b"#)

    /// Zahlen und Dateinamen, die in `source` stehen – `in:` liefert, welche davon im Ergebnis fehlen
    static func hardDetails(_ s: String) -> [String] {
        var out = APText.matches(numberRe, s) + APText.matches(fileRe, s)
        out = out.filter { !$0.isEmpty }
        return Array(Set(out)).sorted()
    }

    static func missing(from source: String, in result: String) -> [String] {
        let r = result.lowercased()
        return hardDetails(source).filter { !r.contains($0.lowercased()) }
    }
}

// MARK: - Rückfall ohne Claude: Regel-Strukturierer

struct APContext: Equatable {
    var appName = ""
    var bundleID = ""
    var windowTitle = ""
    /// Markierter Text (nur per Bedienungshilfen gelesen, nie über die Zwischenablage)
    var selection = ""

    /// Fenstertitel nur bei Entwickler-/Agenten-Apps und Browsern mit Agent im Titel mitschicken (Datenschutz: keine Mail-Betreffs)
    var includesTitle: Bool { !windowTitle.isEmpty && APDetector.isAgentTarget(bundleID: bundleID, title: windowTitle) }

    var isEmpty: Bool { appName.isEmpty && !includesTitle && selection.isEmpty }

    /// Block für Claude (<kontext>)
    func block() -> String {
        var lines: [String] = []
        if !appName.isEmpty { lines.append("App: \(appName)") }
        if includesTitle { lines.append("Fenstertitel: \(windowTitle)") }
        if !selection.isEmpty {
            lines.append("Markierter Text (nur verwenden, wenn er zum Auftrag gehört):")
            lines.append(String(selection.prefix(4000)))
        }
        return lines.joined(separator: "\n")
    }
}

enum APRules {
    /// Satzanfänge ohne Inhalt („Okay also“, „Ach ja und“)
    static let discourse = APText.regex(#"(?i)^(?:(?:okay|ok|also|ja|und|so|genau|naja|ach\s+ja|äh|ähm|hm|well|so\s+yeah|alright|right|und\s+dann|dann|außerdem|übrigens|also\s+quasi|quasi|sozusagen|irgendwie|halt|eben)[\s,.:!…-]+)+"#)
    /// Vorrede ohne Auftrag („ich mache jetzt mal“, „pass auf“, „hör zu“)
    static let preamble = APText.regex(#"(?i)^(?:ich\s+mach(?:e)?\s+(?:jetzt\s+)?mal|pass\s+auf|hör\s+zu|also\s+pass\s+auf|so\s+pass\s+auf|okay\s+listen|listen|here\s+we\s+go|los\s+geht'?s)\b[\s,.:!…-]*"#)
    static let fillerWords = APText.regex(#"(?i)\s*\b(?:quasi|sozusagen|irgendwie|halt|eigentlich\s+so|so\s+ein\s+bisschen|like|you\s+know|kind\s+of|sort\s+of)\b(?=[\s,.])"#)

    static let openRe = APText.regex(#"(?i)(\?\s*$|\bich\s+weiß\s+(?:noch\s+)?nicht\s*(?:genau|so\s+recht)?[\s,]+(?:ob|wie|wann|welche|was|wo)\b|\bweiß\s+nicht\s*(?:genau)?[\s,]+ob\b|\bbin\s+mir\s+(?:noch\s+)?nicht\s+sicher\b|\bkeine\s+ahnung\b|\bunklar\b|\bnot\s+sure\b|\bi\s+don'?t\s+know\s+(?:if|whether|how|which)\b|\bunsure\b|\bmaybe\s+we\b|\bvielleicht\s+sollten\b|\bmüssen\s+wir\s+noch\s+(?:klären|entscheiden)\b)"#)
    static let ruleRe = APText.regex(#"(?i)\b(nicht|kein|keine|keinen|keinesfalls|nie|niemals|ohne|auf\s+keinen\s+fall|don'?t|do\s+not|never|without|avoid|vermeide|nichts)\b"#)
    static let acceptRe = APText.regex(#"(?i)((?:tests?|build|linter|ci)\b.{0,60}\b(grün|green|laufen|durchlaufen|bestehen|pass(?:en|t)?|fehlerfrei)|\b(?:am\s+ende|danach|zum\s+schluss)\b.{0,40}\b(soll|muss|müssen|sollen)\b|\bfertig\s+ist\s+es,?\s+wenn\b|\bakzeptanz|\bdone\s+when\b|\bmust\s+pass\b|\bshould\s+pass\b|\bis\s+done\s+if\b)"#)
    static let contextRe = APText.regex(#"(?i)^(es\s+geht\s+um|das\s+ist|das\s+sind|gerade|aktuell|momentan|im\s+moment|ich\s+glaube|ich\s+denke|das\s+liegt|das\s+problem|der\s+fehler|wir\s+haben|es\s+gibt|die\s+[\wäöüß-]+\s+(?:ist|sind|hat|haben)|der\s+[\wäöüß-]+\s+(?:ist|hat)|das\s+[\wäöüß-]+\s+(?:ist|hat)|it'?s|this\s+is|currently|right\s+now|the\s+problem|there\s+is|there\s+are|we\s+have|i\s+think)\b"#)

    struct Sections {
        var goal = ""
        var context: [String] = []
        var tasks: [String] = []
        var criteria: [String] = []
        var rules: [String] = []
        var open: [String] = []
    }

    /// Diktat aufräumen (Selbstkorrekturen, Wiederholungen, Fehlstarts, Füllwörter) – ohne Inhalt zu verlieren
    static func clean(_ s: String) -> String {
        var t = s
        t = resolveCorrections(t)
        t = QuickPolish.collapseRepeats(t).0
        t = QuickPolish.dropFalseStarts(t).0
        t = fillerWords.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return TextCleaner.tidy(t)
    }

    /// Wörter, die beim Auflösen einer Selbstkorrektur wegfallen dürfen (die Korrektur-Marke selbst)
    static let markerWords: Set<String> = ["nein", "warte", "sorry", "doch", "lieber", "ich", "meine", "meinte", "eher", "besser", "also",
                                           "streich", "das", "no", "wait", "mean", "meant", "actually", "rather", "scratch", "that", "oder"]

    /// Selbstkorrektur mit QuickPolish auflösen – aber nur, wenn dabei höchstens ein Inhaltswort (der korrigierte Wert)
    /// verschwindet. Sonst bleibt alles stehen und die Korrektur wird sichtbar angehängt („– korrigiert: …“), damit kein
    /// Detail verloren geht.
    static func resolveCorrections(_ s: String) -> String {
        let (r, n) = QuickPolish.resolveCorrections(s)
        guard n > 0 else { return s }
        func bag(_ x: String) -> [String: Int] {
            var d: [String: Int] = [:]
            for w in x.split(whereSeparator: { $0.isWhitespace }) {
                let b = QuickPolish.bare(String(w)).lowercased()
                guard !b.isEmpty, !markerWords.contains(b), b.count >= 3 || b.contains(where: \.isNumber) else { continue }
                d[b, default: 0] += 1
            }
            return d
        }
        let before = bag(s), after = bag(r)
        let lost = before.reduce(0) { $0 + max(0, $1.value - (after[$1.key] ?? 0)) }
        if lost <= 1 { return r }
        let t = QuickPolish.tokens(s)
        guard let mk = QuickPolish.findMarker(t) else { return s }
        let a = QuickPolish.join(Array(t[..<mk.lo])).trimmingCharacters(in: CharacterSet(charactersIn: ",;:–— "))
        var b = QuickPolish.join(Array(t[mk.hi...])).trimmingCharacters(in: .whitespaces)
        b = b.replacingOccurrences(of: #"^(?i)(lieber|doch|eher|besser|rather|actually|instead)\s+"#, with: "", options: .regularExpression)
        let en = APText.isEnglish(s)
        return a + (en ? " – correction: " : " – korrigiert: ") + b
    }

    static func sentences(_ s: String) -> [String] {
        // Satzenden + „Ach ja“/„Und bitte“/„Außerdem“ als neue Gedanken
        var t = s.replacingOccurrences(of: #"\s*\n+\s*"#, with: ". ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i),?\s+(ach\s+ja|außerdem|übrigens|und\s+noch\s+was|by\s+the\s+way|oh\s+and|also,)\s+"#, with: ". $1 ", options: .regularExpression)
        var out: [String] = []
        var cur = ""
        let chars = Array(t)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            if ".!?".contains(ch) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                // Keine Trennung in 1.7.16, 3.5, z.B., index.ts
                if ch == ".", !next.isWhitespace { continue }
                out.append(cur); cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out.map { s in
            var x = s.trimmingCharacters(in: .whitespacesAndNewlines)
            for _ in 0..<2 {
                x = discourse.stringByReplacingMatches(in: x, range: NSRange(x.startIndex..., in: x), withTemplate: "")
                x = preamble.stringByReplacingMatches(in: x, range: NSRange(x.startIndex..., in: x), withTemplate: "")
            }
            return APText.capitalizedFirst(x.trimmingCharacters(in: .whitespaces))
        }.filter { APText.words($0) >= 2 || $0.rangeOfCharacter(from: .decimalDigits) != nil }
    }

    static func classify(_ sentences: [String]) -> Sections {
        var s = Sections()
        for x in sentences {
            let isOpen = APText.firstMatch(openRe, x) != nil
            let imperative = APText.firstMatch(APDetector.imperativeRe, x) != nil || APText.firstMatch(APDetector.modalRe, x) != nil
            if isOpen { s.open.append(x.hasSuffix("?") ? x : x.replacingOccurrences(of: #"[.!]+$"#, with: "", options: .regularExpression) + "?"); continue }
            if APText.firstMatch(acceptRe, x) != nil { s.criteria.append(x); continue }
            let negStart = x.range(of: #"^(?i)(nicht|kein|keine|keinen|nie|niemals|bitte\s+nicht|bitte\s+kein\w*|don'?t|do\s+not|never|avoid|vermeide)\b"#, options: .regularExpression) != nil
            if APText.firstMatch(ruleRe, x) != nil && (imperative || negStart || x.lowercased().contains("fass")) { s.rules.append(x); continue }
            if !imperative && (APText.firstMatch(contextRe, x) != nil || s.tasks.isEmpty && s.context.count < 3 && !x.hasSuffix("!")) {
                s.context.append(x); continue
            }
            s.tasks.append(x)
        }
        // Alles war „Kontext“? Dann sind die Sätze der Auftrag
        if s.tasks.isEmpty, !s.context.isEmpty { s.tasks = s.context; s.context = [] }
        s.goal = goal(from: s.tasks.first ?? s.criteria.first ?? s.open.first ?? "")
        return s
    }

    /// Ziel-Satz: erster Auftrag, auf eine Zeile gekürzt (am ersten Komma nach 6 Wörtern)
    static func goal(from s: String) -> String {
        var g = s.replacingOccurrences(of: #"(?i)^(bitte|please)\s+"#, with: "", options: .regularExpression)
        let w = g.split(separator: " ")
        if w.count > 16 {
            var acc: [Substring] = []
            for x in w { acc.append(x); if acc.count >= 6, x.hasSuffix(",") || acc.count >= 16 { break } }
            g = acc.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ", ")) + " …"
        }
        return APText.capitalizedFirst(g)
    }

    static func structure(_ transcript: String, context: APContext? = nil) -> String {
        let en = APText.isEnglish(transcript)
        let sec = classify(sentences(clean(transcript)))
        let H = en ? (goal: "Goal", ctx: "Context", task: "Task", crit: "Acceptance criteria", rules: "Rules", open: "Open questions")
                   : (goal: "Ziel", ctx: "Kontext", task: "Aufgabe", crit: "Akzeptanzkriterien", rules: "Regeln", open: "Offene Punkte")
        var out = "**\(H.goal):** \(sec.goal.isEmpty ? (en ? "See task" : "Siehe Aufgabe") : sec.goal)\n"
        var ctx = sec.context.map { "- \($0)" }
        if let c = context {
            if c.includesTitle { ctx.append(en ? "- Window: \(c.windowTitle) (\(c.appName))" : "- Fenster: \(c.windowTitle) (\(c.appName))") }
            if !c.selection.isEmpty, c.selection.count <= 600 { ctx.append((en ? "- Selected text: " : "- Markierter Text: ") + "„\(c.selection.replacingOccurrences(of: "\n", with: " "))“") }
        }
        if !ctx.isEmpty { out += "\n## \(H.ctx)\n" + ctx.joined(separator: "\n") + "\n" }
        let tasks = sec.tasks.isEmpty ? [transcript.trimmingCharacters(in: .whitespacesAndNewlines)] : sec.tasks
        out += "\n## \(H.task)\n" + tasks.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n"
        let crit = sec.criteria.isEmpty ? [en ? "All items under “\(H.task)” are done." : "Alle Punkte unter „\(H.task)“ sind umgesetzt."] : sec.criteria
        out += "\n## \(H.crit)\n" + crit.map { "- \($0)" }.joined(separator: "\n") + "\n"
        if !sec.rules.isEmpty { out += "\n## \(H.rules)\n" + sec.rules.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !sec.open.isEmpty { out += "\n## \(H.open)\n" + sec.open.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
