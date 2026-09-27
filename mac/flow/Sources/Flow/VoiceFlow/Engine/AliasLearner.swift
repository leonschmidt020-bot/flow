import AppKit

/// „Das System trainieren“: Immer wenn Whisper (mit Wörterbuch-Hinweis) einen Namen richtig schreibt, den Parakeet
/// anders gehört hat („KiTa Nett“ → KiTaNet, „Whisperflow“ → Flow), wird Parakeets Verhörer als Hör-Variante gemerkt.
/// Nach `minSeen` Bestätigungen wird daraus ein Wörterbuch-Eintrag (learned) → beim nächsten Mal reicht Parakeet + Regel,
/// Whisper wird seltener gebraucht, Diktate werden schneller.
///
/// Eigene Datei: ~/.config/flow/engine-aliases.json (0600). Übernahme ins Wörterbuch macht der Kern (siehe Bericht).
enum AliasLearner {
    struct Candidate: Codable, Equatable { var heard: String; var write: String; var seen: Int; var last: Date }

    static let url = Paths.base.appendingPathComponent("engine-aliases.json")
    static var minSeen = 2
    private static let lock = NSLock()

    /// Häufige Wörter, die nie allein als Verhörer gelernt werden (sonst würde „all“ → „Aldi“ ersetzt)
    private static let stop: Set<String> = ["der", "die", "das", "und", "ich", "du", "er", "sie", "es", "wir", "ihr", "ein", "eine", "einen",
        "mit", "von", "zu", "zum", "zur", "in", "im", "an", "am", "auf", "für", "bei", "nach", "noch", "mal", "ja", "nein", "the", "a",
        "and", "to", "of", "on", "at", "for", "with", "is", "it", "i", "you", "we", "all", "so", "be", "was", "wie", "dass", "den", "dem"]

    private static func tokens(_ s: String) -> [String] { s.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    private static func bare(_ s: String) -> String { VocabTrigger.norm(s) }

    /// Vorschläge aus einem Paar (Parakeet-Text, Whisper-Text) für dieselbe Aufnahme.
    static func proposals(parakeet: String, whisper: String, dictionary: [DictEntry]) -> [(heard: String, write: String)] {
        let pt = tokens(parakeet), wt = tokens(whisper)
        let pn = pt.map(bare), wn = wt.map(bare)
        guard !pn.isEmpty, !wn.isEmpty else { return [] }
        // Wort-Ausrichtung (Levenshtein mit Rückverfolgung): für jede Whisper-Position die Parakeet-Position(en)
        let n = pn.count, m = wn.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }; for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n { for j in 1...m {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (pn[i - 1] == wn[j - 1] ? 0 : 1))
            } }
        }
        // w2p[j] = Parakeet-Indizes, die Whisper-Wort j gegenüberstehen (Einfügungen werden dem nächsten Wort zugeschlagen)
        var w2p = [[Int]](repeating: [], count: m)
        var i = n, j = m, pending: [Int] = []
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (pn[i - 1] == wn[j - 1] ? 0 : 1) {
                w2p[j - 1] = [i - 1] + pending; pending = []; i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                pending.insert(i - 1, at: 0); i -= 1
            } else { j -= 1 }
        }
        var out: [(String, String)] = []
        let targets = Set(dictionary.map(\.write).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        for target in targets {
            let tw = tokens(target).map(bare).filter { !$0.isEmpty }
            guard !tw.isEmpty, m >= tw.count else { continue }
            for s in 0...(m - tw.count) where Array(wn[s..<(s + tw.count)]) == tw {
                let idx = (s..<(s + tw.count)).flatMap { w2p[$0] }.sorted()
                guard let a = idx.first, let b = idx.last, b - a < 4 else { continue }
                let heardTokens = Array(pt[a...b])
                let heard = heardTokens.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                let hb = bare(heard)
                guard !hb.isEmpty, hb != tw.joined(separator: " "), hb.replacingOccurrences(of: " ", with: "") != tw.joined() else { continue }
                if heardTokens.allSatisfy({ stop.contains(bare($0)) }) { continue }
                // Muss dem Ziel ähneln (Klang oder Schreibung) – sonst hat Parakeet etwas ganz anderes gehört
                let tj = tw.joined(), hj = hb.replacingOccurrences(of: " ", with: "")
                let similar = VocabTrigger.colognePhonetic(hj) == VocabTrigger.colognePhonetic(tj)
                    || VocabTrigger.levenshtein(Array(hj), Array(tj)) <= max(2, tj.count / 2)
                if similar { out.append((heard, target)) }
            }
        }
        return out.map { (heard: $0.0, write: $0.1) }
    }

    /// Besteht der Ausdruck nur aus echten deutschen/englischen Wörtern?
    static func realWords(_ s: String) -> Bool {
        let words = tokens(s).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        let checker = NSSpellChecker.shared
        return words.allSatisfy { w in
            ["de", "en"].contains { checker.checkSpelling(of: w, startingAt: 0, language: $0, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound }
        }
    }

    static func load() -> [Candidate] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Candidate].self, from: d)) ?? []
    }

    private static func save(_ c: [Candidate]) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Paar beobachten. Gibt die Einträge zurück, die JETZT die Schwelle erreicht haben (→ ins Wörterbuch übernehmen).
    @discardableResult
    static func observe(parakeet: String, whisper: String, dictionary: [DictEntry]) -> [DictEntry] {
        let props = proposals(parakeet: parakeet, whisper: whisper, dictionary: dictionary)
        guard !props.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        var ready: [DictEntry] = []
        let known = Set(dictionary.map { bare($0.heard) })
        var taken = Set<String>()          // pro Durchlauf höchstens EIN Ziel je gehörtem Wort („Fan“ → Kitanet UND KiTaNet verhindern)
        for p in props where !known.contains(bare(p.heard)) && !taken.contains(bare(p.heard)) {
            taken.insert(bare(p.heard))
            // Echte Wörter („Fan“, „Jacke“) nie blind ersetzen – nur als Hinweis für Whisper merken
            let hintOnly = realWords(p.heard)
            if let k = all.firstIndex(where: { bare($0.heard) == bare(p.heard) && $0.write == p.write }) {
                all[k].seen += 1; all[k].last = Date()
                if all[k].seen == minSeen { ready.append(DictEntry(heard: p.heard, write: p.write, learned: true, vocabOnly: hintOnly ? true : nil)) }
            } else {
                all.append(Candidate(heard: p.heard, write: p.write, seen: 1, last: Date()))
                if minSeen <= 1 { ready.append(DictEntry(heard: p.heard, write: p.write, learned: true, vocabOnly: hintOnly ? true : nil)) }
            }
        }
        save(all)
        return ready
    }
}
