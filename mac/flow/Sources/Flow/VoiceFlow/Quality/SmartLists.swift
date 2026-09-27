import Foundation
import NaturalLanguage

/// Intelligente Listen (wie Flow), rein nach Regeln – < 5 ms, ohne KI:
///   • Aufzählung ≥ 3 gleichartiger Dinge nach Auslöser/Kopfwort („mitnehmen/kaufen/brauchen/einpacken“, „Themen/Agenda“, „need/buy/pack“) → Stichpunkte
///   • Reihenfolge („zuerst … dann … danach … zum Schluss“, „first … then … finally“), „Top 3“ → nummeriert
///   • Aufgaben („ich muss noch X machen, Y anrufen und Z schreiben“, „To-dos:“) → Checkliste (`- [ ]` nur in Markdown-Apps)
///   • mehrere Sätze, die alle mit einer Aufforderung beginnen („Kauf Brot. Ruf Oma an. Schick die Rechnung.“) → Stichpunkte
/// Grundsatz wie im restlichen Feinschliff: lieber keine Liste als eine falsche. Jede Liste muss die Wortprobe bestehen
/// (kein Wort dazu außer der Überschrift, keins weg außer Artikel/Bindewörter/Ordnungswörter/Hinweis) – sonst bleibt der Text.
/// Sprach-Hinweis am Ende: „als Liste“ / „nummeriert“ / „als Checkliste“ erzwingt, „keine Liste“ verhindert (wird entfernt).
enum SmartLists {
    enum Kind: String, Sendable { case bullets, numbered, checklist }
    enum Hint: Equatable, Sendable { case none, force(Kind?), suppress }
    /// Wie die Ziel-App Listen darstellt
    enum Target: String, Sendable, CaseIterable {
        case markdown   // Obsidian, Bear, Notion, Editoren: „- “, „1.“, „- [ ] “
        case plain      // Apple Notizen, Browser, Sonstiges: „- “, „1.“, Checkliste als „- “
        case mail       // Mail, Pages, Word, TextEdit: „• “, „1.“ (kein Markdown)
        case chat       // WhatsApp, iMessage, Slack …: „• “, erst ab 4 Punkten (oder auf Wunsch)
        case terminal   // Terminal, Claude Code, KI-Apps: schlichte „- “
    }

    // MARK: Ziel-App

    /// Bundle der App im Vordergrund beim Fn-Druck (ScreenContext.begin) – für Tests überschreibbar
    nonisolated(unsafe) static var bundleOverride: String?

    static func currentBundle(_ snap: ScreenContext.Snapshot?) -> String {
        if let b = bundleOverride { return b }
        if let b = snap?.bundleID, !b.isEmpty { return b }
        return ScreenContext.lastFrontBundle
    }

    static func target(bundleID: String) -> Target {
        let b = bundleID.lowercased()
        let md = ["md.obsidian", "net.shinyfrog.bear", "notion.id", "com.ulyssesapp", "abnerworks.typora", "pro.writer.mac",
                  "com.logseq", "com.lukilabs.lukiapp", "com.agiletortoise.drafts"]
        if md.contains(where: { b.hasPrefix($0) }) { return .markdown }
        let rich = ["com.apple.iwork.pages", "com.microsoft.word", "com.apple.textedit", "com.apple.iwork.keynote", "com.microsoft.powerpoint"]
        if rich.contains(where: { b.hasPrefix($0) }) { return .mail }
        if ["com.anthropic.claudefordesktop", "com.openai.chat"].contains(where: { b.hasPrefix($0) }) { return .terminal }
        switch ContextAppKind.of(bundleID: b) {
        case .editor: return .markdown
        case .terminal: return .terminal
        case .mail: return .mail
        case .chat: return .chat
        default: return .plain
        }
    }

    static func marker(_ kind: Kind, _ i: Int, _ t: Target) -> String {
        let dot = t == .mail || t == .chat
        switch kind {
        case .numbered: return "\(i + 1). "
        case .bullets: return dot ? "• " : "- "
        case .checklist: return t == .markdown ? "- [ ] " : (dot ? "• " : "- ")
        }
    }

    // MARK: Hinweis am Ende („als Liste“, „keine Liste“)

    struct Prepared: Sendable { var text: String; var hint: Hint; var separated: Bool }

    private static let hintPhrases: [(String, Hint)] = {
        let raw: [(String, Hint)] = [
            ("als checkliste", .force(.checklist)), ("als to-do-liste", .force(.checklist)), ("als todo-liste", .force(.checklist)),
            ("als todo liste", .force(.checklist)), ("als to-do liste", .force(.checklist)), ("als aufgabenliste", .force(.checklist)),
            ("als to-dos", .force(.checklist)), ("als todos", .force(.checklist)), ("as a checklist", .force(.checklist)),
            ("as checklist", .force(.checklist)), ("as a to-do list", .force(.checklist)), ("as a todo list", .force(.checklist)),
            ("als nummerierte liste", .force(.numbered)), ("als nummerierte aufzählung", .force(.numbered)), ("durchnummeriert", .force(.numbered)),
            ("nummeriert", .force(.numbered)), ("mit nummern", .force(.numbered)), ("as a numbered list", .force(.numbered)),
            ("numbered list", .force(.numbered)), ("numbered", .force(.numbered)),
            ("nicht als liste", .suppress), ("keine liste", .suppress), ("ohne liste", .suppress), ("als fließtext", .suppress),
            ("als ganzer satz", .suppress), ("als satz", .suppress), ("keine aufzählung", .suppress), ("not as a list", .suppress),
            ("no list", .suppress), ("no bullets", .suppress), ("as a sentence", .suppress), ("as prose", .suppress),
            ("als stichpunktliste", .force(nil)), ("als stichpunkte", .force(nil)), ("in stichpunkten", .force(nil)),
            ("als aufzählung", .force(nil)), ("als liste", .force(nil)), ("as a bulleted list", .force(nil)), ("as bullet points", .force(nil)),
            ("in bullet points", .force(nil)), ("as bullets", .force(nil)), ("as a list", .force(nil)), ("as list", .force(nil)),
        ]
        return raw.sorted { $0.0.count > $1.0.count }
    }()

    static func stripHint(_ input: String) -> Prepared {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while let c = s.last, ".!?".contains(c) { s.removeLast() }
        func dropWord(_ w: String) -> Bool {
            guard let r = s.range(of: w, options: [.caseInsensitive, .backwards, .anchored]), r.lowerBound > s.startIndex,
                  s[s.index(before: r.lowerBound)].isWhitespace || ",.".contains(s[s.index(before: r.lowerBound)]) else { return false }
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces); return true
        }
        _ = dropWord("bitte") || dropWord("please")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        for (p, h) in hintPhrases {
            guard let r = s.range(of: p, options: [.caseInsensitive, .backwards, .anchored]) else { continue }
            var rest = String(s[..<r.lowerBound])
            // ganzes Wort („Hauptliste“ ≠ „liste“)
            if let c = rest.last, c.isLetter || c.isNumber { continue }
            rest = rest.trimmingCharacters(in: .whitespaces)
            for w in ["bitte", "please", "und", "and"] {
                if rest.lowercased().hasSuffix(" " + w) || rest.lowercased().hasSuffix("," + w) || rest.lowercased() == w {
                    rest = String(rest.dropLast(w.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            let sep = rest.last.map { ",.;:!?–—-".contains($0) } ?? false
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,;–—-"))
            guard rest.split(separator: " ").count >= 2 else { return Prepared(text: input, hint: .none, separated: false) }
            return Prepared(text: rest, hint: h, separated: sep)
        }
        return Prepared(text: input, hint: .none, separated: false)
    }

    // MARK: Einstieg (aus QuickPolish.apply)

    struct PassResult: Sendable { var text: String; var lists: Int; var hintUsed: Bool }

    /// Hinweis + erkannte Aufzählungen („erstens …“ in QuickPolish.formatLists) + automatische Listen.
    /// `auto == false` (Feinschliff „Aus“): nur was per Hinweis verlangt wurde.
    static func pass(_ s: String, target: Target, auto: Bool = true) -> PassResult {
        let prep = stripHint(s)
        if prep.hint != .none {
            if prep.hint == .suppress {
                // Nur als Hinweis werten, wenn es überhaupt eine Liste zu verhindern gibt
                let wouldList = stage(prep.text, hint: .none, target: .markdown).1 > 0
                let commas = prep.text.filter { $0 == "," }.count
                if wouldList || (prep.separated && commas >= 1) { return PassResult(text: prep.text, lists: 0, hintUsed: true) }
            } else {
                let (t, n) = stage(prep.text, hint: prep.hint, target: target)
                if n > 0 { return PassResult(text: t, lists: n, hintUsed: true) }
            }
        }
        guard auto else { return PassResult(text: s, lists: 0, hintUsed: false) }
        let (t, n) = stage(s, hint: .none, target: target)
        return PassResult(text: t, lists: n, hintUsed: false)
    }

    private static func stage(_ s: String, hint: Hint, target: Target) -> (String, Int) {
        if hint == .suppress { return (s, 0) }
        let (t, n) = QuickPolish.formatLists(s)
        if n > 0 { return (t, n) }
        return format(s, hint: hint, target: target)
    }

    /// Nur die automatische Erkennung (ohne „erstens …“)
    static func format(_ input: String, hint: Hint = .none, target: Target) -> (String, Int) {
        var isForced = false
        var forcedKind: Kind?
        if case .force(let k) = hint { isForced = true; forcedKind = k }
        if hint == .suppress { return (input, 0) }
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("\n"), !looksLikeCode(s) else { return (input, 0) }
        // Schnell-Ausstieg: ohne Komma/„und“-Kette, Reihenfolge-Wort oder mehrere Sätze gibt es nichts zu tun
        let lower = s.lowercased()
        let sentences = s.filter { ".!?".contains($0) }.count
        let commas = s.filter { $0 == "," }.count
        let seq = seqHints.contains { lower.contains($0) }
        if !isForced, commas < 1, !seq, sentences < 3, !lower.contains(":") { return (input, 0) }
        let lang = language(s)
        let t = tag(s, lang: lang)
        guard t.count >= 3 else { return (input, 0) }
        let minItems = isForced ? 2 : (target == .chat ? 4 : 3)
        let ctx = Ctx(t: t, lang: lang, minItems: minItems, forced: isForced)
        var block = sequence(ctx) ?? imperativeRun(ctx)
        if block == nil {
            for (a, b) in ctx.sentences { if let bl = enumeration(ctx, a, b) { block = bl; break } }
        }
        if block == nil, isForced { block = generic(ctx) }
        guard var bl = block else { return (input, 0) }
        if let k = forcedKind { bl.kind = k }
        let out = render(bl, ctx, target)
        guard safe(input: s, output: out, drops: bl.drops, adds: bl.adds) else { return (input, 0) }
        // Weitere Liste im Rest („… Danach packe ich ein: …“) – nur automatisch
        if !isForced, bl.end < t.count {
            let restIn = join(t, bl.end..<t.count)
            let (rest, n) = format(restIn, target: target)
            if n > 0 {
                let head = out.hasSuffix(restIn) ? String(out.dropLast(restIn.count)) : nil
                if let head { return (head + rest, 1 + n) }
            }
        }
        return (out, 1)
    }

    // MARK: Wörter

    struct T {
        let text: String
        let bare: String
        let lower: String
        let tag: NLTag?
        let lemma: String
        var comma: Bool { text.hasSuffix(",") || text.hasSuffix(";") }
        var colon: Bool { text.hasSuffix(":") }
        var endsSentence: Bool {
            guard let c = text.last, ".!?".contains(c) else { return false }
            if c == "." {
                if SmartLists.abbreviations.contains(lower) || (bare.count == 1 && bare.first?.isLetter == true) { return false }
                if !bare.isEmpty, bare.count <= 2, bare.allSatisfy(\.isNumber) { return false }       // „am 3. Oktober“
            }
            return true
        }
        var capitalized: Bool { bare.first?.isUppercase == true }
    }

    struct Ctx {
        let t: [T]
        let lang: NLLanguage
        let minItems: Int
        let forced: Bool
        let sentences: [(Int, Int)]
        var de: Bool { lang == .german }
        init(t: [T], lang: NLLanguage, minItems: Int, forced: Bool) {
            self.t = t; self.lang = lang; self.minItems = minItems; self.forced = forced
            var out: [(Int, Int)] = []
            var a = 0
            for (i, w) in t.enumerated() where w.endsSentence || i == t.count - 1 { out.append((a, i + 1)); a = i + 1 }
            sentences = out
        }
        func sentence(of i: Int) -> (Int, Int) { sentences.first { $0.0 <= i && i < $0.1 } ?? (0, t.count) }
    }

    struct Block {
        var start: Int, end: Int
        var heading: String?
        var items: [String]
        var kind: Kind
        var drops: Set<String> = []
        var adds: Set<String> = []
    }

    static let abbreviations: Set<String> = ["z", "b", "bzw", "usw", "etc", "ca", "dr", "nr", "st", "mr", "mrs", "ms", "vs", "inkl", "evtl", "ggf", "bspw", "prof"]

    static func bare(_ w: String) -> String { w.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?…–—\"'„“”»«()")) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static let recognizer = NLLanguageRecognizer()
    nonisolated(unsafe) private static var taggers: [String: NLTagger] = [:]

    /// Wortart + Grundform je Leerzeichen-Wort, Sprache fest (DE/EN) – Tagger je Sprache wiederverwendet
    static func tag(_ s: String, lang: NLLanguage) -> [T] {
        let raw = s.split(separator: " ", omittingEmptySubsequences: true)
        lock.lock(); defer { lock.unlock() }
        let tg: NLTagger
        if let x = taggers[lang.rawValue] { tg = x } else { tg = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma]); taggers[lang.rawValue] = tg }
        tg.string = s
        let all = s.startIndex..<s.endIndex
        tg.setLanguage(lang, range: all)
        // Ein Durchlauf je Schema (Einzelabfragen je Wort sind ~10× teurer)
        var tags: [String.Index: NLTag] = [:]
        var lemmas: [String.Index: String] = [:]
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        tg.enumerateTags(in: all, unit: .word, scheme: .nameTypeOrLexicalClass, options: opts) { t, r in
            if let t, tags[r.lowerBound] == nil { tags[r.lowerBound] = t }; return true
        }
        tg.enumerateTags(in: all, unit: .word, scheme: .lemma, options: opts) { t, r in
            if let t, !t.rawValue.isEmpty, lemmas[r.lowerBound] == nil { lemmas[r.lowerBound] = t.rawValue.lowercased() }; return true
        }
        var out: [T] = []
        out.reserveCapacity(raw.count)
        for r in raw {
            let text = String(r)
            let b = bare(text)
            let lower = b.lowercased()
            var tag: NLTag?
            var lemma = lower
            if let first = r.firstIndex(where: { $0.isLetter || $0.isNumber }) {
                tag = tags[first]
                if let l = lemmas[first] { lemma = l }
            }
            out.append(T(text: text, bare: b, lower: lower, tag: tag, lemma: lemma))
        }
        return out
    }

    /// Tagger laden (erster Aufruf je Sprache ~60 ms) – beim Fn-Druck im Hintergrund
    static func prewarm() {
        _ = tag("Ich brauche Milch, Brot und Eier.", lang: .german)
        _ = tag("I need eggs, milk and bread.", lang: .english)
    }

    private static let deCommon: Set<String> = ["ich", "und", "der", "die", "das", "ist", "nicht", "noch", "ein", "eine", "einen", "mit", "für", "auf",
        "wir", "du", "zu", "den", "dem", "muss", "will", "brauche", "dann", "zuerst", "danach", "auch", "mal", "bitte", "oder", "sind", "gehe", "morgen", "heute"]
    private static let enCommon: Set<String> = ["i", "and", "the", "is", "not", "a", "an", "to", "for", "with", "we", "you", "need", "then", "first",
        "also", "please", "or", "are", "of", "my", "our", "have", "buy", "some", "get", "tomorrow", "today"]

    static func language(_ s: String) -> NLLanguage {
        var d = 0, e = 0
        for w in s.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let x = String(w)
            if deCommon.contains(x) { d += 1 }
            if enCommon.contains(x) { e += 1 }
        }
        if d != e { return d > e ? .german : .english }
        if s.contains(where: { "äöüß".contains($0) }) { return .german }
        lock.lock(); defer { lock.unlock() }
        recognizer.reset()
        recognizer.languageConstraints = [.german, .english]
        recognizer.processString(s)
        return recognizer.dominantLanguage == .english ? .english : .german
    }

    private static func looksLikeCode(_ s: String) -> Bool {
        s.contains("`") || s.contains("{") || s.contains("()") || s.contains("=>") || s.contains("==")
    }

    static func join(_ t: [T], _ r: Range<Int>) -> String { t[r].map(\.text).joined(separator: " ") }

    // MARK: Wortlisten

    static let seqHints = ["zuerst", "als erstes", "erstmal", "erst mal", "zunächst", "first", "to start", "to begin"]

    private static let seqStart: [[String]] = [["zuerst"], ["als", "erstes"], ["erstmal"], ["erst", "mal"], ["zunächst"], ["zu", "beginn"],
        ["am", "anfang"], ["first"], ["first", "of", "all"], ["firstly"], ["to", "start"], ["to", "begin"], ["start", "by"]]
    private static let seqMid: [[String]] = [["dann"], ["danach"], ["anschließend"], ["als", "nächstes"], ["daraufhin"], ["im", "anschluss"],
        ["then"], ["after", "that"], ["next"], ["afterwards"], ["after", "this"]]
    private static let seqEnd: [[String]] = [["zum", "schluss"], ["zuletzt"], ["schließlich"], ["am", "ende"], ["abschließend"], ["am", "schluss"],
        ["zu", "guter", "letzt"], ["finally"], ["lastly"], ["at", "the", "end"], ["last"], ["in", "the", "end"]]

    private static let conj: Set<String> = ["und", "and", "sowie", "plus", "&"]
    private static let orConj: Set<String> = ["oder", "or"]
    private static let copula: Set<String> = ["sind", "ist", "lauten", "umfassen", "wären", "are", "is", "include", "includes", "were"]
    private static let subjectPronouns: Set<String> = ["ich", "du", "er", "wir", "ihr", "man", "i", "we", "he", "she", "they"]
    private static let invPronouns: Set<String> = ["du", "wir", "ihr", "ich", "man", "er", "sie", "es"]
    private static let possessives: Set<String> = ["mein", "meine", "meinen", "meinem", "meiner", "dein", "deine", "deinen", "sein", "seine", "seinen",
        "unser", "unsere", "unseren", "euer", "eure", "ihre", "ihren", "my", "your", "our", "his", "her", "their"]
    private static let stripArticles: Set<String> = ["ein", "eine", "einen", "einem", "einer", "der", "die", "das", "den", "dem", "a", "an", "the", "some"]
    private static let measure: Set<String> = ["paar", "bisschen", "packung", "flasche", "flaschen", "tüte", "dose", "dosen", "glas", "kiste", "kasten", "liter",
        "kilo", "gramm", "stück", "pack", "beutel", "becher", "bund", "netz", "pair", "bottle", "bottles", "bag", "pack", "box", "can", "jar", "bunch",
        "couple", "loaf", "dozen", "liter", "litre", "pound", "pounds", "kg", "g"]
    private static let negations: Set<String> = ["kein", "keine", "keinen", "keinem", "nicht", "no", "not", "never", "nie"]
    private static let abstract: Set<String> = ["zeit", "ruhe", "geduld", "liebe", "kraft", "hoffnung", "mut", "glück", "hilfe", "unterstützung", "frieden",
        "freude", "energie", "schlaf", "pause", "laune", "humor", "spaß", "motivation", "vertrauen", "glauben", "glaube", "gnade", "segen", "weisheit",
        "verständnis", "respekt", "stille", "ehrlichkeit", "fun", "faith", "trust", "grace", "wisdom", "joy", "hope", "strength", "attitude", "mood", "humour",
        "humor", "honesty", "kindness", "focus", "fokus", "zuversicht", "demut", "dankbarkeit", "gratitude", "break", "nap", "urlaub", "time", "patience", "love", "help", "support", "peace", "rest", "energy", "courage", "sleep", "luck", "space"]
    private static let people: Set<String> = ["freunde", "freundin", "freund", "familie", "nachbarn", "kinder", "eltern", "kollegen", "leute", "mama", "papa",
        "oma", "opa", "geschwister", "friends", "friend", "family", "neighbors", "neighbours", "kids", "children", "parents", "colleagues", "people", "mom", "dad"]
    static func isAbstract(_ w: String) -> Bool {
        abstract.contains(w) || (w.count > 6 && (w.hasSuffix("heit") || w.hasSuffix("keit") || w.hasSuffix("schaft") || w.hasSuffix("ness")))
    }
    private static let timeWords: Set<String> = ["heute", "morgen", "übermorgen", "nachher", "später", "today", "tomorrow", "tonight", "later"]
    private static let particles: Set<String> = ["ab", "an", "auf", "zu", "mit", "ein", "aus", "los", "weg", "zurück", "vorbei", "raus", "rein", "hin", "her"]
    private static let subordinators: Set<String> = ["weil", "damit", "dass", "wenn", "falls", "obwohl", "because", "since", "although", "unless", "if", "so"]

    /// Wörter, die in einer Überschrift nichts Eigenes sagen („Ich gehe … und will …“) → dann gilt das Etikett („Einkaufen:“)
    private static let light: Set<String> = ["ich", "wir", "du", "man", "muss", "müssen", "musst", "will", "wollen", "willst", "möchte", "möchten", "sollte",
        "sollten", "soll", "sollen", "gehe", "geh", "gehen", "geht", "noch", "auch", "mal", "und", "dann", "jetzt", "gleich", "schnell", "bitte", "kurz",
        "zum", "gerne", "gern", "unbedingt", "bin", "fahre", "fahren", "i", "we", "you", "need", "to", "have", "got", "gotta", "must", "should", "want",
        "will", "i'll", "we'll", "i'm", "going", "go", "still", "also", "just", "quickly", "please", "and", "then", "some", "for", "the", "am", "are",
        "'m", "gonna", "run", "head", "out", "off", "a", "few", "things"]

    private static let shopWords: Set<String> = ["einkaufen", "kaufen", "kaufe", "kauf", "kauft", "kaufst", "besorgen", "besorge", "besorg", "holen",
        "hole", "hol", "einkauf", "supermarkt", "einkaufsliste", "einkaufszettel",
        "buy", "shopping", "groceries", "grocery", "pick", "up", "grab", "get"]
    private static let stores: Set<String> = ["rewe", "aldi", "lidl", "edeka", "netto", "penny", "kaufland", "dm", "rossmann", "bäcker", "markt", "laden", "supermarket", "store"]
    private static let packWords: Set<String> = ["einpacken", "packen", "pack", "packe", "koffer", "packliste", "rucksack", "packing", "suitcase", "backpack"]

    /// Verb VOR der Aufzählung („will mitnehmen: …“, „kauf …“, „I need …“)
    private static let triggersBefore: Set<String> = ["kaufen", "kaufe", "kauf", "einkaufen", "besorgen", "besorge", "besorg", "holen", "hole", "hol",
        "mitnehmen", "mitbringen", "einpacken", "packen", "pack", "packe", "bestellen", "bestelle", "bestell", "brauche", "brauchen", "brauchst",
        "braucht", "benötige", "benötigen", "buy", "grab", "pack", "bring", "order", "need", "needs", "get"]
    private static let weakTriggers: Set<String> = ["brauche", "brauchen", "brauchst", "braucht", "benötige", "benötigen", "need", "needs", "get", "bring", "order"]
    /// Verb AM ENDE („… Milch, Brot und Eier kaufen“) bzw. abtrennbarer Teil („bring … mit“)
    private static let triggersAfter: Set<String> = ["kaufen", "einkaufen", "besorgen", "holen", "mitnehmen", "mitbringen", "einpacken", "packen", "bestellen"]
    private static let particleVerbs: [String: Set<String>] = [
        "mit": ["bringe", "bring", "bringst", "bringen", "bringt", "nimm", "nehme", "nehmen", "nimmst", "nehmt"],
        "ein": ["pack", "packe", "packen", "packst", "kauf", "kaufe", "kaufen", "packt"],
    ]

    /// Kopfwörter („Die Themen für morgen sind …“, „Agenda: …“)
    private static let headNouns: [String: Kind] = [
        "agenda": .bullets, "tagesordnung": .bullets, "themen": .bullets, "punkte": .bullets, "einkaufsliste": .bullets, "einkaufszettel": .bullets,
        "packliste": .bullets, "zutaten": .bullets, "liste": .bullets, "programm": .bullets, "ablauf": .numbered, "optionen": .bullets,
        "ideen": .bullets, "fragen": .bullets, "ziele": .bullets, "prioritäten": .numbered, "schritte": .numbered, "reihenfolge": .numbered,
        "aufgaben": .checklist, "to-dos": .checklist, "todos": .checklist, "to-do-liste": .checklist, "todo-liste": .checklist, "to-do": .checklist,
        "topics": .bullets, "points": .bullets, "items": .bullets, "list": .bullets, "ingredients": .bullets, "options": .bullets, "ideas": .bullets,
        "questions": .bullets, "goals": .bullets, "priorities": .numbered, "steps": .numbered, "tasks": .checklist, "to-do's": .checklist,
        "folgendes": .bullets, "following": .bullets, "setlist": .bullets, "setliste": .bullets,
    ]
    /// Überschriften, nach denen beliebige kurze Punkte stehen dürfen (Liedtitel, Fragen)
    private static let anyHeads: Set<String> = ["setlist", "setliste", "lieder", "songs", "fragen", "questions", "agenda", "tagesordnung", "themen", "topics", "punkte", "points", "einladen", "gäste", "teilnehmer", "guests", "invite", "attendees"]
    private static let orHeads: Set<String> = ["optionen", "options", "ideen", "ideas", "alternativen", "alternatives"]

    /// Häufige Aufforderungen (der Tagger hält „Kauf“, „Ruf“, „Schick“ für Nomen)
    private static let imperativeDE: Set<String> = ["kauf", "kaufe", "hol", "hole", "ruf", "rufe", "schick", "schicke", "schreib", "schreibe", "bring",
        "bringe", "mach", "mache", "pack", "packe", "nimm", "geh", "sag", "frag", "check", "prüf", "prüfe", "bestell", "bestelle", "buch", "buche", "lies",
        "schau", "denk", "vergiss", "such", "suche", "besorg", "besorge", "antworte", "erinner", "erinnere", "räum", "räume", "putz", "bezahl", "überweis",
        "meld", "melde", "plan", "plane", "trag", "leg", "stell", "setz", "lösch", "speicher", "sende", "send", "öffne", "starte", "start", "teste", "test",
        "installier", "lad", "lade", "druck", "drucke", "unterschreib", "gib", "zahl", "koch", "koche", "wasch", "füll", "sortier", "markier", "kopier",
        "informier", "kontaktier", "organisier", "reservier", "kündig", "verschieb", "beantworte", "erledige", "erledig", "notier", "lern", "übe", "gieß",
        "füttere", "fütter", "bereite", "bereit", "aktualisier", "update", "pushe", "push", "committe", "bau", "baue", "fix", "fixe", "trink", "iss",
        "wirf", "bestätige", "bestätig", "schließ", "schließe", "dreh", "spül", "lüfte", "sperr", "schalt", "schalte", "kläre", "klär", "besuch",
        "hilf", "zeig", "zeige", "stopp", "guck", "miete", "miet", "wechsel", "wechsle", "tausch", "tausche", "entsorge", "entsorg", "abonnier", "erstelle", "erstell", "leite", "leit", "check", "zieh", "gieße", "hör", "hoer"]
    private static let verbsEN: Set<String> = ["book", "call", "email", "text", "check", "fix", "send", "update", "finish", "water", "feed", "lock",
        "answer", "prepare", "clean", "buy", "pay", "order", "schedule", "review", "write", "read", "plan", "pick", "drop", "get", "take", "make", "do",
        "wash", "cancel", "renew", "submit", "file", "print", "sign", "return", "reply", "test", "deploy", "push", "merge", "ship", "set", "start", "stop",
        "open", "close", "restart", "install", "remove", "delete", "add", "invite", "ask", "tell", "remind", "visit", "walk", "clear", "empty", "fill",
        "charge", "back", "upload", "save", "find", "change", "run", "create", "move", "copy", "paste", "try", "use", "turn", "click", "notify", "download", "post", "share", "record", "edit", "finalize", "draft", "confirm", "follow", "meet", "go", "bring", "grab"]
    private static let auxEN: Set<String> = ["is", "are", "am", "was", "were", "be", "do", "does", "did", "can", "could", "will", "would", "shall",
        "should", "may", "might", "must", "have", "has", "had", "let's", "lets", "thank", "thanks", "sorry", "hope", "love", "like", "see"]
    private static let auxDE: Set<String> = ["ist", "sind", "war", "waren", "hat", "haben", "hatte", "kann", "können", "muss", "müssen", "soll", "sollen",
        "wird", "werden", "wurde", "gibt", "bin", "bist", "darf", "möchte", "will"]
    private static let pastDE: Set<String> = ["war", "waren", "warst", "hatte", "hatten", "hattest", "wurde", "wurden", "ging", "gingen", "kam", "kamen",
        "gab", "sah", "sahen", "machte", "machten", "sagte", "fuhr", "fuhren", "aß", "aßen", "dachte", "dachten", "wollte", "wollten", "musste",
        "mussten", "konnte", "konnten", "fand", "stand", "lief", "liefen", "saß", "las", "schrieb", "rief", "haben", "hat", "habe", "hast", "habt"]
    private static let pastEN: Set<String> = ["was", "were", "had", "did", "went", "came", "got", "took", "made", "saw", "ate", "said", "drove", "left",
        "thought", "found", "bought", "brought", "felt", "met", "ran", "sat", "told", "began"]

    // MARK: Wortarten

    private static func isNounish(_ w: T, _ c: Ctx, sentenceStart: Bool) -> Bool {
        if let tg = w.tag, [.noun, .personalName, .placeName, .organizationName].contains(tg) { return true }
        if c.de, w.capitalized, !sentenceStart, !subjectPronouns.contains(w.lower), w.lower != "sie" { return true }
        if !c.de, w.capitalized, !sentenceStart, w.lower != "i" { return true }
        return false
    }

    private static func isVerb(_ w: T, _ c: Ctx, sentenceStart: Bool) -> Bool {
        guard w.tag == .verb else { return false }
        if c.de, w.capitalized, !sentenceStart { return false }     // „das Essen“, „Treffen“
        return true
    }

    private static func isInfinitive(_ w: T, _ c: Ctx) -> Bool {
        guard w.tag == .verb || (c.de && !w.capitalized && (w.lower.hasSuffix("en") || w.lower.hasSuffix("ern") || w.lower.hasSuffix("eln"))) else { return false }
        if c.de { return !w.capitalized && (w.lower == w.lemma || w.lower.hasSuffix("en") || w.lower.hasSuffix("ern") || w.lower.hasSuffix("eln")) }
        return true
    }

    // MARK: Aufzählung in einem Satz

    private enum ItemType { case noun, verbPhrase, any }

    /// Teile [lo, hi) an Kommas + letztem „und/and“ → Wortbereiche (ohne Bindewörter)
    private static func chunks(_ c: Ctx, _ lo: Int, _ hi: Int, allowOr: Bool) -> (parts: [Range<Int>], conj: Int)? {
        guard lo < hi else { return nil }
        let t = c.t
        var parts: [Range<Int>] = []
        var s = lo
        for k in lo..<hi where t[k].comma && k < hi - 1 { parts.append(s..<(k + 1)); s = k + 1 }
        parts.append(s..<hi)
        let joiners = allowOr ? conj.union(orConj) : conj
        var removed = 0
        // „…, and bread“ (Oxford-Komma) → Bindewort vorne weg
        parts = parts.map { r in
            if r.count > 1, joiners.contains(t[r.lowerBound].lower) { removed += 1; return (r.lowerBound + 1)..<r.upperBound }
            return r
        }
        if parts.count == 1 {
            // „Milch und Brot und Eier“ ohne Kommas
            let r = parts[0]
            var out: [Range<Int>] = []
            var a = r.lowerBound
            for k in r where joiners.contains(t[k].lower) && k > a && k < r.upperBound - 1 { out.append(a..<k); a = k + 1; removed += 1 }
            out.append(a..<r.upperBound)
            parts = out
        } else if let last = parts.last, let k = last.reversed().first(where: { joiners.contains(t[$0].lower) }), k > last.lowerBound, k < last.upperBound - 1 {
            parts[parts.count - 1] = last.lowerBound..<k
            parts.append((k + 1)..<last.upperBound)
            removed += 1
        }
        // „oder“ nur bei Optionen/Ideen – sonst ist es eine Wahl, keine Liste
        if !allowOr, parts.contains(where: { r in r.contains { orConj.contains(t[$0].lower) } }) { return nil }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return (parts, removed)
    }

    private static func isNounPhrase(_ c: Ctx, _ r: Range<Int>, maxWords: Int = 6) -> Bool {
        guard r.count >= 1, r.count <= maxWords else { return false }
        let t = c.t
        if negations.contains(t[r.lowerBound].lower) { return false }
        if subordinators.contains(t[r.lowerBound].lower) { return false }
        // „für das Frühstück Brötchen“ – ein Ding beginnt nicht mit einer Präposition
        if t[r.lowerBound].tag == .preposition { return false }
        var noun = false
        // „coffee on your way home“, „Eier für das Frühstück morgen“ – Anhängsel ≥ 3 Wörter = Satz, keine Liste
        if let p = r.first(where: { t[$0].tag == .preposition && $0 > r.lowerBound }), r.upperBound - p - 1 >= 3 { return false }
        if particles.contains(t[r.upperBound - 1].lower) { return false }
        // „brauche Reis“, „hole Milch“ – das Auslöse-Verb gehört nie in einen Punkt
        if r.contains(where: { k in let x = t[k]; return !x.capitalized && (triggersBefore.contains(x.lower) || triggersAfter.contains(x.lower)) }) { return false }
        // „bei Amazon das Ladekabel“ – Artikel direkt nach einem Nomen = zwei Dinge in einem Teil
        if r.dropFirst().contains(where: { k in (t[k].tag == .determiner || stripArticles.contains(t[k].lower)) && isNounish(t[k - 1], c, sentenceStart: false) }) { return false }
        for k in r {
            let w = t[k]
            if isVerb(w, c, sentenceStart: false) {
                // Englisch: der Tagger hält „sunscreen“, „flip (flops)“ in Listen oft für Verben – echt ist es nur mit Objekt dahinter
                let objectFollows = k + 1 < r.upperBound && (t[k + 1].tag == .determiner || t[k + 1].tag == .pronoun || possessives.contains(t[k + 1].lower))
                if c.de || auxEN.contains(w.lower) || objectFollows { return false }
                // „-ed“ nur als Beiwort vor einem Nomen („used cars“); „-ing“ allein = Gerundium („hiring“), vor Nomen = Beiwort („sleeping bag“)
                let nounFollows = k + 1 < r.upperBound && isNounish(t[k + 1], c, sentenceStart: false)
                if w.lower.hasSuffix("ed"), !nounFollows { return false }
                // „matters“, „goes“ – gebeugt = Satz, kein Ding
                if w.lemma != w.lower, !w.lower.hasSuffix("ing"), !w.lower.hasSuffix("ed") { return false }
                if r.count == 1 || w.lower.hasSuffix("ing") { noun = true }
                continue
            }
            if w.tag == .pronoun, !possessives.contains(w.lower), !stripArticles.contains(w.lower), !(c.de && w.capitalized) { return false }
            if isNounish(w, c, sentenceStart: false) || (!w.bare.isEmpty && w.bare.allSatisfy(\.isNumber) && r.count == 1) { noun = true }
        }
        return noun
    }

    private static func isVerbPhrase(_ c: Ctx, _ r: Range<Int>) -> Bool {
        guard r.count >= 1, r.count <= 10 else { return false }
        let t = c.t
        if negations.contains(t[r.lowerBound].lower) || subordinators.contains(t[r.lowerBound].lower) { return false }
        if r.contains(where: { subjectPronouns.contains(t[$0].lower) }) { return false }
        if c.de {
            // „die Wäsche machen“, „Mama anrufen“ – endet mit Infinitiv, sonst kein gebeugtes Verb
            guard isInfinitive(t[r.upperBound - 1], c) else { return false }
            return !r.dropLast().contains { k in isVerb(t[k], c, sentenceStart: false) && t[k].lower != t[k].lemma && !t[k].lower.hasSuffix("en") }
        }
        var first = r.lowerBound
        if t[first].lower == "to", r.count > 1 { first += 1 }
        let w = t[first]
        // „do the laundry“ – „do“ als Vollverb mit Objekt
        if w.lower == "do", first + 1 < r.upperBound, t[first + 1].tag == .determiner || possessives.contains(t[first + 1].lower) { return true }
        if auxEN.contains(w.lower) { return false }
        // Der Tagger hält „book/water/email/answer“ am Teilanfang oft für Nomen
        if verbsEN.contains(w.lower), r.count >= 2 || w.tag == .verb { return true }
        return w.tag == .verb && (w.lemma == w.lower || w.lower == "do")
    }

    /// Überschrift aus den Wörtern vor der Aufzählung. Nur „leere“ Wörter + Einkauf/Packen → Etikett („Einkaufen:“).
    private static func heading(_ c: Ctx, _ r: Range<Int>, extra: [String] = [], checklist: Bool = false, verbatim: Bool = false,
                                drops: inout Set<String>, adds: inout Set<String>) -> (String?, shop: Bool, pack: Bool) {
        let t = c.t
        let words = t[r].map(\.lower) + extra.map { $0.lowercased() }
        let shop = words.contains { shopWords.contains($0) || stores.contains($0) } && !(words.contains("get") && !words.contains("groceries") && !words.contains("shopping") && !words.contains("store"))
        let pack = !shop && words.contains { packWords.contains($0) }
        let isLight = words.allSatisfy { light.contains($0) || shopWords.contains($0) || packWords.contains($0) || timeWords.contains($0)
            || triggersBefore.contains($0) || triggersAfter.contains($0) || $0 == "mit" || $0 == "ein" || $0 == "zu" }
        let times = t[r].filter { timeWords.contains($0.lower) }.map(\.lower)
        func label(_ l: String) -> String {
            for w in t[r] { drops.insert(w.lower) }
            for w in extra { drops.insert(w.lowercased()) }
            for w in l.lowercased().split(whereSeparator: { !$0.isLetter }) { adds.insert(String(w)) }
            return times.isEmpty ? l + ":" : l + " (" + times.joined(separator: " ") + "):"
        }
        if isLight, !verbatim {
            if checklist { return (label("To-dos"), shop, pack) }
            if shop { return (label(c.de ? "Einkaufen" : "Shopping"), shop, pack) }
            if pack { return (label(c.de ? "Packliste" : "Packing list"), shop, pack) }
        }
        guard !r.isEmpty || !extra.isEmpty else { return (nil, shop, pack) }
        var h = (t[r].map(\.text) + extra).joined(separator: " ")
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.–—-"))
        if let f = h.first { h = String(f).uppercased() + h.dropFirst() }
        return (h.isEmpty ? nil : h + ":", shop, pack)
    }

    private static func itemText(_ c: Ctx, _ r: Range<Int>, stripArticle: Bool, keepIndefinite: Bool = false, drops: inout Set<String>) -> String {
        var r = r
        let t = c.t
        let indefinite: Set<String> = ["ein", "eine", "einen", "einem", "einer", "a", "an"]
        if stripArticle, r.count == 2, stripArticles.contains(t[r.lowerBound].lower), !(keepIndefinite && indefinite.contains(t[r.lowerBound].lower)), !measure.contains(t[r.lowerBound + 1].lower),
           isNounish(t[r.lowerBound + 1], c, sentenceStart: false) {
            drops.insert(t[r.lowerBound].lower)
            r = (r.lowerBound + 1)..<r.upperBound
        }
        var s = join(t, r).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!?"))
        if let f = s.first, !(s.split(separator: " ").first.map { $0.dropFirst().contains(where: \.isUppercase) } ?? false) {
            s = String(f).uppercased() + s.dropFirst()
        }
        return s
    }

    private static func enumeration(_ c: Ctx, _ a: Int, _ b: Int) -> Block? {
        let t = c.t
        guard b - a >= 3 else { return nil }
        if t[b - 1].text.hasSuffix("?"), !c.forced { return nil }
        var drops: Set<String> = conj.union(orConj)
        var adds: Set<String> = []

        func build(heading hr0: Range<Int>, extra: [String] = [], items lo: Int, _ hi: Int, kind: Kind, type: ItemType?, allowOr: Bool = false,
                   weak: Bool = false, trigger: Bool = false, splitFirst: Bool = false, verbatim: Bool = false) -> Block? {
            guard let ch = chunks(c, lo, hi, allowOr: allowOr), ch.parts.count >= c.minItems else { return nil }
            var parts = ch.parts
            var hr = hr0
            // „brauchen wir Bibeln, …“ / „bestell bei Amazon das Ladekabel, …“ – Anfang des ersten Teils gehört zur Überschrift
            if splitFirst, !isNounPhrase(c, parts[0]), let s = firstItemStart(c, parts[0]), s > parts[0].lowerBound,
               !(hr.lowerBound..<s).contains(where: { t[$0].colon }) {
                hr = hr.lowerBound..<s
                parts[0] = s..<parts[0].upperBound
            }
            let isNP = parts.allSatisfy { isNounPhrase(c, $0) }
            let isVP = parts.allSatisfy { isVerbPhrase(c, $0) } && parts.contains { $0.count >= 2 }
            var k = kind
            switch type {
            case .noun?: guard isNP else { return nil }
            case .verbPhrase?: guard isVP else { return nil }
            case .any?: guard parts.allSatisfy({ $0.count <= 8 }) else { return nil }
            case nil:
                guard isNP || isVP else { return nil }
                if isVP, !isNP, kind == .bullets { k = .checklist }
            }
            if weak || trigger {
                // „Ich brauche Zeit, Ruhe und Geduld“, „Bring Geduld, gute Laune und Humor mit“ bleibt ein Satz
                let heads = parts.map { t[$0.upperBound - 1].lower }
                if heads.filter({ isAbstract($0) }).count >= 2 { return nil }
                // „Order matters, timing matters and people matter“ – gleiches Schlusswort in mehreren Teilen = Stilmittel, keine Liste
                let lastLemmas = parts.filter { $0.count >= 2 }.map { t[$0.upperBound - 1].lemma }
                if lastLemmas.count >= 2, Set(lastLemmas).count < lastLemmas.count { return nil }
                // „I need a break, a coffee and a nap“ – schwacher Auslöser, nichts davor, jedes Ding mit „a/ein“: Rede, keine Liste
                let indefinite: Set<String> = ["a", "an", "ein", "eine", "einen"]
                if weak, parts.count < 4, t[hr0].allSatisfy({ light.contains($0.lower) || triggersBefore.contains($0.lower) }),
                   parts.filter({ indefinite.contains(t[$0.lowerBound].lower) }).count >= 2 { return nil }
            }
            // „Ich hole Anna, Tom und Lisa ab“, „brauche Rafael, Nico und Pierre“ – Menschen sind keine Einkaufsliste
            if trigger, parts.filter({ r in r.contains { t[$0].tag == .personalName || people.contains(t[$0].lower) } }).count >= 2 { return nil }
            var d = drops, ad = adds
            let (h, shop, pack) = heading(c, hr, extra: extra, checklist: k == .checklist && isVP, verbatim: verbatim, drops: &d, adds: &ad)
            // „drei Brötchen, zwei Croissants und ein Baguette“ – „ein“ ist hier eine Menge
            let quantities = parts.contains { r in let x = t[r.lowerBound]; return (QuickPolish.numberWords.contains(x.lower) && !stripArticles.contains(x.lower)) || x.bare.first?.isNumber == true }
            let items = parts.map { itemText(c, $0, stripArticle: shop || pack, keepIndefinite: quantities, drops: &d) }
            return Block(start: a, end: b, heading: h, items: items, kind: k, drops: d, adds: ad)
        }

        // 1) Doppelpunkt / Kopfwort („Agenda: …“, „Die Themen für morgen sind …“, „Meine Top 3 Filme sind …“)
        let colonAt = (a..<(b - 1)).first { t[$0].colon }
        for i in a..<(b - 1) {
            let w = t[i]
            let head = headNouns[w.lower] ?? headNouns[w.lemma]
            let top = (w.lower == "top") && i + 1 < b && (Int(t[i + 1].bare) != nil || QuickPolish.numberWords.contains(t[i + 1].lower))
            let ranking = top || t[a..<i].contains { ["rangliste", "ranking", "reihenfolge", "order"].contains($0.lower) }
            if w.colon {
                let hr = a..<(i + 1)
                let heads = t[hr].compactMap { headNouns[$0.lower] ?? headNouns[$0.lemma] }
                let hk = ranking ? .numbered : (heads.first ?? .bullets)
                let allowOr = t[hr].contains { orHeads.contains($0.lower) }
                let fixedHead = !heads.isEmpty || t[hr].contains { anyHeads.contains($0.lower) }
                if let bl = build(heading: hr, items: i + 1, b, kind: hk, type: nil, allowOr: allowOr, verbatim: true) { return bl }
                if fixedHead, let bl = build(heading: hr, items: i + 1, b, kind: hk, type: .any, allowOr: allowOr, verbatim: true) { return bl }
                break
            }
            if (head != nil || top), colonAt == nil || colonAt! < i {
                for j in (i + 1)..<min(i + 6, b - 1) where copula.contains(t[j].lower) {
                    drops.insert(t[j].lower)
                    let k: Kind = ranking ? .numbered : (head ?? .bullets)
                    let allowOr = orHeads.contains(w.lower)
                    if let bl = build(heading: a..<j, items: j + 1, b, kind: k, type: k == .checklist || k == .numbered ? nil : .noun, allowOr: allowOr, verbatim: true) { return bl }
                    if anyHeads.contains(w.lower), let bl = build(heading: a..<j, items: j + 1, b, kind: k, type: .any, allowOr: allowOr, verbatim: true) { return bl }
                    drops.remove(t[j].lower)
                    break
                }
            }
        }

        // 2) Aufgaben: „Ich muss (heute) noch X machen, Y anrufen und Z schreiben“ / „I need to call …, do … and send …“
        let modalsDE: Set<String> = ["muss", "müssen", "musst", "sollte", "sollten", "sollst"]
        for i in a..<(b - 2) {
            let w = t[i]
            var lo: Int?
            if c.de, modalsDE.contains(w.lower) {
                var j = i + 1
                if j < b, subjectPronouns.contains(t[j].lower) { j += 1 }            // „Heute muss ich noch …“
                while j < b, ["noch", "heute", "morgen", "unbedingt", "mal", "auch", "dringend", "diese", "woche", "bis", "freitag", "gleich"].contains(t[j].lower) { j += 1 }
                lo = j
            } else if !c.de, ["need", "have", "gotta", "must", "should"].contains(w.lower) {
                var j = i + 1
                if w.lower != "gotta", w.lower != "must", w.lower != "should" { guard j < b, t[j].lower == "to" else { continue }; j += 1 }
                lo = j
            }
            guard let start = lo, start < b else { continue }
            // Subjekt muss direkt davor/danach stehen („Ich muss …“, „muss ich …“, „I still need to …“)
            let subj = (i > a && subjectPronouns.contains(t[i - 1].lower)) || (i + 1 < b && subjectPronouns.contains(t[i + 1].lower))
                || (i > a + 1 && subjectPronouns.contains(t[i - 2].lower) && ["still", "really", "also", "just", "noch", "auch"].contains(t[i - 1].lower))
            guard subj else { continue }
            if let bl = build(heading: a..<start, items: start, b, kind: .checklist, type: .verbPhrase) { return bl }
        }

        // 2b) „Don't forget to …“, „Vergiss nicht, …“ (DE: Infinitive am Ende jedes Teils)
        for i in a..<(b - 2) {
            var lo: Int?
            if !c.de, ["don't", "dont"].contains(t[i].lower), t[i + 1].lower == "forget", i + 2 < b, t[i + 2].lower == "to" { lo = i + 3 }
            if c.de, ["vergiss", "vergesst"].contains(t[i].lower), t[i + 1].lower == "nicht" { lo = i + 2 }
            if let lo, lo < b, let bl = build(heading: a..<lo, items: lo, b, kind: .checklist, type: .verbPhrase) { return bl }
        }

        // 3) Auslöser davor: „… will mitnehmen eine Banane, einen Apfel, Milch und Brot“, „I need eggs, milk and bread“
        let fillers: Set<String> = ["noch", "auch", "mal", "unbedingt", "bitte", "folgendes", "folgende", "so", "also", "some", "also", "still", "heute", "morgen", "today", "tomorrow"]
        for i in a..<(b - 2) {
            let w = t[i]
            var isTrig = triggersBefore.contains(w.lower)
            var endTrig = i
            if !c.de, w.lower == "pick", i + 1 < b, t[i + 1].lower == "up" { isTrig = true; endTrig = i + 1 }
            guard isTrig, !w.comma else { continue }     // „Einkaufen, Wäsche, Steuer“ – das Wort ist selbst ein Punkt
            if !c.de {
                if w.lower == "need" || w.lower == "needs", i + 1 < b, t[i + 1].lower == "to" { continue }
                if w.lower == "get", !(i == a || ["to", "gotta", "please", "and"].contains(t[i - 1].lower)) { continue }
            }
            // Partizip/Präteritum („gekauft“) steht nicht in der Liste; gebeugte Vergangenheit davor → Erzählung
            if t[a..<i].contains(where: { (c.de ? ["habe", "hab", "hatte", "hatten", "haben", "hast"] : ["had", "have", "has"]).contains($0.lower) }) { continue }
            var lo = endTrig + 1
            while lo < b, fillers.contains(t[lo].lower), !t[lo - 1].colon { lo += 1 }
            let weak = weakTriggers.contains(w.lower)
            if let bl = build(heading: a..<lo, items: lo, b, kind: .bullets, type: .noun, weak: weak, trigger: true, splitFirst: true) { return bl }
        }

        // 4) Auslöser am Ende: „Ich muss noch Milch, Brot und Eier kaufen“, „Ich bringe Chips, Cola und Kuchen mit“
        let last = t[b - 1]
        var trigEnd: [Int] = []
        if c.de, triggersAfter.contains(last.lower) { trigEnd = [b - 1]; if b - 2 > a, t[b - 2].lower == "zu" { trigEnd = [b - 2, b - 1] } }
        if c.de, let verbs = particleVerbs[last.lower], t[a..<(b - 1)].contains(where: { verbs.contains($0.lower) }) { trigEnd = [b - 1] }
        if let first = trigEnd.first, first - a >= 3 {
            // erstes Ding: Ende des ersten Kommateils rückwärts, solange Nomen-Wörter (Artikel, Zahl, Adjektiv, Maß)
            guard let comma = (a..<first).first(where: { t[$0].comma }), let itemStart = firstItemStart(c, a..<(comma + 1)) else { return nil }
            let extra = trigEnd.map { t[$0].bare }
            if let bl = build(heading: a..<itemStart, extra: extra, items: itemStart, first, kind: .bullets, type: .noun, trigger: true) {
                return bl
            }
        }
        return nil
    }

    /// Wo beginnt das letzte Ding in [r)? Rückwärts, solange Nomen-Wörter (Artikel, Zahl, Adjektiv, Maß); höchstens ein Nomen (+ Maßwort)
    private static func firstItemStart(_ c: Ctx, _ r: Range<Int>) -> Int? {
        let t = c.t
        var s = r.upperBound - 1
        var nouns = 0
        while s >= r.lowerBound {
            let x = t[s]
            if isNounish(x, c, sentenceStart: s == c.sentence(of: s).0) && !(c.de && s == r.lowerBound && x.tag == .verb) {
                if nouns >= 1, !measure.contains(x.lower) { break }
                nouns += 1; s -= 1; continue
            }
            if x.tag == .determiner || x.tag == .adjective || x.tag == .number || possessives.contains(x.lower) || measure.contains(x.lower)
                || QuickPolish.numberWords.contains(x.lower) || (!x.bare.isEmpty && x.bare.allSatisfy(\.isNumber)) {
                if stripArticles.contains(x.lower) || x.tag == .determiner { s -= 1; break }   // Artikel beginnt das Ding
                s -= 1; continue
            }
            break
        }
        guard nouns >= 1 else { return nil }
        return s + 1
    }

    // MARK: Reihenfolge

    private static func matchMarker(_ c: Ctx, _ i: Int, _ list: [[String]]) -> Int? {
        var best: Int?
        for m in list where i + m.count <= c.t.count {
            if (0..<m.count).allSatisfy({ c.t[i + $0].lower == m[$0] }) {
                // Innerhalb eines mehrteiligen Markers kein Satzzeichen
                if (0..<(m.count - 1)).contains(where: { c.t[i + $0].text.last.map { ",.;:!?".contains($0) } ?? false }) { continue }
                if best == nil || m.count > best! { best = m.count }
            }
        }
        return best
    }

    private static func clauseStart(_ c: Ctx, _ i: Int) -> (ok: Bool, conj: Bool) {
        if i == 0 { return (true, false) }
        let p = c.t[i - 1]
        if p.text.last.map({ ",.;:!?".contains($0) }) ?? false { return (true, false) }
        if conj.contains(p.lower) { return (true, true) }
        return (false, false)
    }

    private static func sequence(_ c: Ctx) -> Block? {
        let t = c.t
        var i = 0
        var start: (i: Int, len: Int)?
        while i < t.count {
            if let n = matchMarker(c, i, seqStart), clauseStart(c, i).ok {
                // Satzanfang oder nach Doppelpunkt
                let (sa, _) = c.sentence(of: i)
                if i == sa || t[i - 1].colon { start = (i, n); break }
            }
            i += 1
        }
        guard let st = start else { return nil }
        // „First of all, thank you“ – nur mit weiteren Markern
        var marks: [(i: Int, len: Int, conj: Bool)] = [(st.i, st.len, false)]
        var hasEnd = false
        var k = st.i + st.len
        while k < t.count {
            let cs = clauseStart(c, k)
            if cs.ok, let n = matchMarker(c, k, seqEnd) { marks.append((k, n, cs.conj)); hasEnd = true; break }
            if cs.ok, let n = matchMarker(c, k, seqMid) { marks.append((k, n, cs.conj)); k += n; continue }
            k += 1
        }
        guard marks.count >= max(3, c.minItems) else { return nil }
        guard hasEnd || marks.count >= 4 || c.forced else { return nil }
        let lastSentenceEnd = c.sentence(of: marks.last!.i).1
        var steps: [Range<Int>] = []
        for (n, m) in marks.enumerated() {
            let from = m.i + m.len
            var to = n + 1 < marks.count ? marks[n + 1].i - (marks[n + 1].conj ? 1 : 0) : lastSentenceEnd
            while to > from, conj.contains(t[to - 1].lower) { to -= 1 }
            guard to > from, to - from <= 25 else { return nil }
            steps.append(from..<to)
        }
        // Erzählung in der Vergangenheit („Zuerst waren wir essen, dann …“) bleibt Text
        let all = st.i..<lastSentenceEnd
        let past = c.de ? t[all].contains { pastDE.contains($0.lower) }
                        : t[all].contains { pastEN.contains($0.lower) || ($0.tag == .verb && $0.lower.hasSuffix("ed") && $0.lemma != $0.lower) }
        if past { return nil }
        // Deutsch: „Zuerst schneidest du …“ – ohne Marker bliebe „Schneidest du …“ (klingt wie eine Frage) → Marker behalten
        let keep = c.de && steps.contains { r in r.count >= 2 && t[r.lowerBound].tag == .verb && invPronouns.contains(t[r.lowerBound + 1].lower) }
        var drops: Set<String> = conj
        var items: [String] = []
        for (n, r) in steps.enumerated() {
            let m = marks[n]
            if keep {
                var words = t[m.i..<(m.i + m.len)].map { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: ",")) } + t[r].map(\.text)
                if var f = words.first, let ch = f.first { f = String(ch).uppercased() + f.dropFirst(); words[0] = f }
                items.append(words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!?")))
            } else {
                for w in t[m.i..<(m.i + m.len)] { drops.insert(w.lower) }
                items.append(itemText(c, r, stripArticle: false, drops: &drops))
            }
        }
        // Überschrift: Teil vor dem Doppelpunkt im selben Satz, sonst vorheriger Satz mit „:“
        let (sa, _) = c.sentence(of: st.i)
        var startTok = st.i
        var heading: String?
        if st.i > sa, t[st.i - 1].colon {
            startTok = sa
            heading = join(t, sa..<st.i).trimmingCharacters(in: CharacterSet(charactersIn: " :")) + ":"
        } else if st.i > 0, t[st.i - 1].colon {
            let (pa, _) = c.sentence(of: st.i - 1)
            startTok = pa
            heading = join(t, pa..<st.i).trimmingCharacters(in: CharacterSet(charactersIn: " :")) + ":"
        } else if st.i == sa, sa > 0 {
            // „So installierst du die App. Zuerst …“ – kurzer einziger Satz davor wird zur Überschrift
            let (pa, pb) = c.sentence(of: sa - 1)
            if pa == 0, pb - pa <= 7, t[pb - 1].text.hasSuffix(".") {
                startTok = 0
                heading = join(t, pa..<pb).trimmingCharacters(in: CharacterSet(charactersIn: " .")) + ":"
            }
        }
        return Block(start: startTok, end: lastSentenceEnd, heading: heading, items: items, kind: .numbered, drops: drops)
    }

    // MARK: Aufforderungen hintereinander

    private static func isImperative(_ c: Ctx, _ a: Int, _ b: Int) -> Bool {
        let t = c.t
        guard b - a >= 2, b - a <= 15 else { return false }
        if t[b - 1].text.hasSuffix("?") { return false }
        var i = a
        if ["bitte", "please", "und", "and", "dann", "then"].contains(t[i].lower) { i += 1 }
        guard i < b - 1 else { return false }
        let w = t[i]
        // „Setz dich.“, „Komm rein.“ sind Rede; „Order lunch.“ ist eine Aufgabe → zwei Wörter nur mit Nomen dahinter
        if b - i == 2, !isNounish(t[i + 1], c, sentenceStart: false) { return false }
        if c.de {
            if auxDE.contains(w.lower) { return false }
            if invPronouns.contains(t[i + 1].lower) || t[i + 1].lower == "sie" { return false }
            if imperativeDE.contains(w.lower) { return true }
            // „Schließ“ = Stamm von „schließen“ (Imperativ Singular), „Macht/Kommt“ (ihr) bleibt außen vor
            if w.lemma.hasSuffix("en"), w.lemma.count > 4, w.lower == String(w.lemma.dropLast(2)) || w.lower == String(w.lemma.dropLast(1)) { return true }
            return w.tag == .verb && w.lemma != w.lower && !w.lower.hasSuffix("st") && !w.lower.hasSuffix("t")
        }
        if auxEN.contains(w.lower) || ["i", "we", "you", "he", "she", "they", "it"].contains(t[i + 1].lower) { return false }
        return (w.tag == .verb && w.lemma == w.lower) || verbsEN.contains(w.lower)
    }

    private static func imperativeRun(_ c: Ctx) -> Block? {
        let ss = c.sentences
        guard ss.count >= c.minItems else { return nil }
        var runStart = -1
        var best: (Int, Int)?
        for (n, s) in ss.enumerated() {
            if isImperative(c, s.0, s.1) {
                if runStart < 0 { runStart = n }
                if n - runStart + 1 >= c.minItems, best == nil || (n - runStart) > (best!.1 - best!.0) { best = (runStart, n) }
            } else { runStart = -1 }
        }
        guard let (lo, hi) = best else { return nil }
        let t = c.t
        var drops: Set<String> = []
        let items = ss[lo...hi].map { itemText(c, $0.0..<$0.1, stripArticle: false, drops: &drops) }
        var start = ss[lo].0
        var heading: String?
        if lo > 0, t[ss[lo - 1].1 - 1].colon {
            start = ss[lo - 1].0
            heading = join(t, ss[lo - 1].0..<ss[lo - 1].1)
        }
        return Block(start: start, end: ss[hi].1, heading: heading, items: items, kind: .bullets, drops: drops)
    }

    // MARK: Erzwungen („als Liste“) ohne erkanntes Muster

    private static func generic(_ c: Ctx) -> Block? {
        let t = c.t
        // längste Komma-Reihe in einem Satz
        var best: (Int, Int, [Range<Int>])?
        for (a, b) in c.sentences {
            var lo = a
            if let col = (a..<b).first(where: { t[$0].colon }) { lo = col + 1 }
            guard let (parts, _) = chunks(c, lo, b, allowOr: true), parts.count >= 2 else { continue }
            if best == nil || parts.count > best!.2.count { best = (a, b, parts) }
        }
        var drops: Set<String> = conj.union(orConj)
        if let bestHit = best {
            let (a, b) = (bestHit.0, bestHit.1)
            var parts = bestHit.2
            var hr = a..<parts[0].lowerBound
            if hr.isEmpty, parts[0].count > 3 {
                // „Ideen fürs Wochenende Kino, …“ → Kopf = alles vor dem letzten Nomen des ersten Teils
                let r = parts[0]
                if let k = r.reversed().first(where: { isNounish(t[$0], c, sentenceStart: $0 == a) }), k > r.lowerBound {
                    var s = k
                    while s > r.lowerBound, t[s - 1].tag == .determiner || t[s - 1].tag == .adjective || t[s - 1].tag == .number { s -= 1 }
                    if s > r.lowerBound { hr = r.lowerBound..<s; parts[0] = s..<r.upperBound }
                }
            }
            var adds: Set<String> = []
            let (h, _, _) = heading(c, hr, drops: &drops, adds: &adds)
            let items = parts.map { itemText(c, $0, stripArticle: false, drops: &drops) }
            return Block(start: a, end: b, heading: h, items: items, kind: .bullets, drops: drops, adds: adds)
        }
        let ss = c.sentences
        guard ss.count >= 2 else { return nil }
        let items = ss.map { itemText(c, $0.0..<$0.1, stripArticle: false, drops: &drops) }
        return Block(start: 0, end: t.count, heading: nil, items: items, kind: .bullets, drops: drops)
    }

    // MARK: Ausgabe + Wortprobe

    private static func render(_ b: Block, _ c: Ctx, _ target: Target) -> String {
        var parts: [String] = []
        if b.start > 0 { parts.append(join(c.t, 0..<b.start)) }
        var list = b.items.enumerated().map { marker(b.kind, $0.offset, target) + $0.element }.joined(separator: "\n")
        if let h = b.heading { list = h + "\n" + list }
        parts.append(list)
        if b.end < c.t.count { parts.append(join(c.t, b.end..<c.t.count)) }
        return parts.joined(separator: "\n\n")
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { !$0.isEmpty }
    }

    /// Kein Wort dazu (außer Überschrift/Nummern), keins weg (außer erlaubten) – sonst keine Liste
    static func safe(input: String, output: String, drops: Set<String>, adds: Set<String>) -> Bool {
        var have: [String: Int] = [:]
        for w in words(input) { have[w, default: 0] += 1 }
        var got: [String: Int] = [:]
        for w in words(output) { got[w, default: 0] += 1 }
        for (w, n) in got where n > (have[w] ?? 0) {
            if adds.contains(w) || (w.allSatisfy(\.isNumber) && Int(w).map { $0 <= 30 } == true) { continue }
            return false
        }
        let dropParts = Set(drops.flatMap { words($0) })
        for (w, n) in have where n > (got[w] ?? 0) {
            if dropParts.contains(w) { continue }
            return false
        }
        return true
    }
}
