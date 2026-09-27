import Foundation

/// Speist die Bildschirm-Begriffe in die drei Stellen der Diktat-Kette:
///  (a) Whisper-Hinweissatz (`prompt`) – Wörterbuch zuerst, Bildschirm-Begriffe füllen den Rest (≤ 380 Zeichen)
///  (b) Auslöser für die Whisper-Prüfung + vorläufige Namen-Profile (nur für dieses Diktat)
///  (c) Feinschliff: exakte Schreibweise und zusammengesprochene Bezeichner („fetch user profile“ → fetchUserProfile)
enum ContextBoost {
    static let maxPrompt = 380
    /// So viele Wörterbuch-Wörter bleiben mindestens im Hinweis, auch wenn Bildschirm-Begriffe Platz brauchen
    static var minDictionaryWords = 12
    static var maxPromptTerms = 10
    static var maxTriggerTerms = 12

    /// Aktueller Kontext (nil = keiner) – im Test austauschbar
    nonisolated(unsafe) static var source: () -> ScreenContext.Snapshot? = { ScreenContext.shared.snapshot }
    /// Wörterbuch-Schreibweisen (Messbank: leer, damit nur der Bildschirm wirkt)
    nonisolated(unsafe) static var dictionaryWords: () -> [String] = { Settings.frozen.dictionary.map { $0.write.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    // MARK: (a) Whisper-Hinweis

    static func promptTerms(_ snap: ScreenContext.Snapshot?, excluding dict: [String]) -> [String] {
        guard let snap else { return [] }
        // eigener Name steht schon vorne („Ich bin Lena.“)
        let me = Settings.frozen.myName.isEmpty ? Identity.systemFirstName : Settings.frozen.myName
        let known = Set((dict + [me]).map { $0.lowercased() })
        var out: [String] = []
        for t in snap.terms where t.score >= 2.0 && t.kind != .email && !t.text.contains(" ") {
            let k = t.text.lowercased()
            if known.contains(k) || out.contains(where: { $0.lowercased() == k }) { continue }
            out.append(t.text)
            if out.count >= maxPromptTerms { break }
        }
        return out
    }

    /// Ersetzt den Satzbau aus `WhisperEngine.vocabularyPrompt()`: ohne Bildschirm-Kontext Zeichen für Zeichen derselbe Satz.
    static func prompt(dictionaryWords words: [String], name: String, snapshot: ScreenContext.Snapshot? = ContextBoost.source()) -> String {
        func join(_ l: [String]) -> String { l.count > 1 ? l.dropLast().joined(separator: ", ") + " und " + l.last! : (l.first ?? "") }
        func base(_ l: [String]) -> String { "Ich bin \(name)." + (l.isEmpty ? "" : " Heute geht es um \(join(l)).") }
        var list = Array(words.prefix(24))
        var sentence = base(list)
        while sentence.count > maxPrompt, !list.isEmpty { list.removeLast(); sentence = base(list) }
        var ctx = promptTerms(snapshot, excluding: words)
        guard !ctx.isEmpty else { return sentence }
        func extra(_ c: [String]) -> String { " Auf dem Bildschirm: \(join(c))." }
        // Platz für die wichtigsten Bildschirm-Begriffe schaffen (älteste Wörterbuch-Wörter zuerst weg, nie unter 12)
        let want = extra(Array(ctx.prefix(5))).count
        while sentence.count + want > maxPrompt, list.count > minDictionaryWords { list.removeLast(); sentence = base(list) }
        while !ctx.isEmpty, sentence.count + extra(ctx).count > maxPrompt { ctx.removeLast() }
        return ctx.isEmpty ? sentence : sentence + extra(ctx)
    }

    // MARK: (b) Auslöser + vorläufige Namen

    /// Nur unbekannte Wörter (keine echten Wörter wie „Garten“) – sonst ginge jedes Diktat zu Whisper
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (key: String, terms: [String])?

    static func triggerTerms(_ snap: ScreenContext.Snapshot? = ContextBoost.source()) -> [String] {
        guard let snap else { return [] }
        // Je Diktat einmal rechnen (decide() fragt pro Stück); Schlüssel = Sitzung + Begriffe
        let key = "\(snap.session)|" + snap.terms.map(\.text).joined(separator: "|")
        cacheLock.lock()
        if let c = cache, c.key == key { cacheLock.unlock(); return c.terms }
        cacheLock.unlock()
        let t = computeTriggers(snap)
        cacheLock.lock(); cache = (key, t); cacheLock.unlock()
        return t
    }

    /// Cache leeren (ScreenContext.end) – nichts vom Bildschirm bleibt nach dem Diktat im Speicher
    static func forget() { cacheLock.lock(); cache = nil; cacheLock.unlock() }

    private static func computeTriggers(_ snap: ScreenContext.Snapshot) -> [String] {
        let dict = Set(dictionaryWords().map { $0.lowercased() })
        // Unbekannte Wörter („Okonkwo“, „kubectl“) immer; bekannte Vornamen/Namen („Rafael“, „Brenninkmeyer“, „Anneliese“) nur als Person
        // und nur, wenn die kleine Form kein echtes Wort ist (sonst würde „Will“, „Mark“ jedes Diktat zu Whisper schicken)
        let pool = snap.terms.filter { t in
            t.score >= 2.2 && !t.text.contains(" ") && t.text.count >= 5 && t.kind != .email && !dict.contains(t.text.lowercased())
                && (t.unknownWord || t.kind == .person || t.kind == .name)
        }
        let known = pool.filter { !$0.unknownWord }
        let lowerUnknown = known.isEmpty ? [] : SpellBatch.unknown(known.map { $0.text.lowercased() })
        return pool.filter { $0.unknownWord || lowerUnknown.contains($0.text.lowercased()) }.prefix(maxTriggerTerms).map(\.text)
    }

    /// Richtlinie mit den Bildschirm-Begriffen als zusätzliche Auslöser (nur solange der Kontext gilt)
    static func policy(_ p: HybridRecognizer.Policy) -> HybridRecognizer.Policy {
        let extra = triggerTerms()
        guard !extra.isEmpty else { return p }
        var q = p
        q.extraVocabulary += extra.filter { e in !q.extraVocabulary.contains(where: { $0.caseInsensitiveCompare(e) == .orderedSame }) }
        return q
    }

    /// Hook für `HybridRecognizer.Env.live()`: trainierte Profile + vorläufige vom Bildschirm
    static func withTempProfiles(_ p: [NameProfile]) -> [NameProfile] { p + tempProfiles(existing: p) }

    /// Vorläufige Namen-Profile (ohne Klang-Vorlagen → ersetzt wird nur, wenn Whisper den Namen bestätigt)
    static func tempProfiles(existing: [NameProfile], _ snap: ScreenContext.Snapshot? = ContextBoost.source()) -> [NameProfile] {
        guard let snap else { return [] }
        let have = Set(existing.map { $0.target.lowercased() })
        let terms = triggerTerms(snap).filter { !have.contains($0.lowercased()) }
        return terms.prefix(8).compactMap { t -> NameProfile? in
            guard let term = snap.terms.first(where: { $0.text == t }) else { return nil }
            let kind: String
            switch term.kind {
            case .person, .name, .handle: kind = "person"
            case .organization: kind = "company"
            case .place: kind = "place"
            case .rare, .code, .email: kind = "term"
            }
            return NameProfile(target: t, kind: kind, language: "de", variants: [], contexts: [:], templates: [], dtwThreshold: nil, updated: Date())
        }
    }

    // MARK: (c) Feinschliff

    /// Begriffe, die der Feinschliff nicht verändern darf (Wörterbuch + Bildschirm)
    static func protectedTerms(_ snap: ScreenContext.Snapshot? = ContextBoost.source()) -> [String] {
        var out = dictionaryWords()
        for t in snap?.terms ?? [] where t.score >= 2.0 && t.kind != .email { out.append(t.text) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Schreibweise vom Bildschirm übernehmen: „okonkwo“ → „Okonkwo“, „fetch user profile“ → „fetchUserProfile“ (nur Editor/Terminal/KI-App).
    static func fixTerms(_ text: String, snapshot snap: ScreenContext.Snapshot? = ContextBoost.source()) -> String {
        guard let snap, !snap.terms.isEmpty, !text.isEmpty else { return text }
        var s = text
        let codeApp = snap.appKind.codeFriendly || AppCategory.of(bundleID: snap.bundleID) == .ai
        // Bekannte Namen („Siobhan“, „Anneliese“) nur, wenn die kleine Form kein echtes Wort ist („will“ ≠ „Will“)
        let knownNames = snap.terms.filter { !$0.unknownWord && $0.score >= 2.0 && $0.text.count >= 4 && !$0.text.contains(" ")
            && [.person, .name, .organization, .place].contains($0.kind) && $0.text.first?.isUppercase == true
            && text.range(of: $0.text, options: [.caseInsensitive]) != nil && !text.contains($0.text) }
        let lowerUnknown = knownNames.isEmpty ? [] : SpellBatch.unknown(knownNames.map { $0.text.lowercased() })
        let caseTerms = snap.terms.filter { $0.unknownWord } + knownNames.filter { lowerUnknown.contains($0.text.lowercased()) }
        for t in caseTerms where t.text.count >= 4 && t.kind != .email {
            // Groß/klein angleichen (ganzes Wort, sonst gleich)
            let pat = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: t.text) + "(?![\\p{L}\\p{N}_])"
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                let ns = s as NSString
                for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
                where ns.substring(with: m.range) != t.text {
                    s = (s as NSString).replacingCharacters(in: m.range, with: t.text)
                }
            }
            // Zusammensetzen: „fetch user profile“ / „get user by ID“ → Bezeichner
            guard codeApp, t.kind == .code, !t.text.contains(".") else { continue }
            let parts = ContextVocab.identifierParts(t.text)
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { continue }
            let spoken = parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "[\\s\\-]+")
            let sp = "(?<![\\p{L}\\p{N}_])" + spoken + "(?![\\p{L}\\p{N}_])"
            if let re = try? NSRegularExpression(pattern: sp, options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: t.text))
            }
        }
        return s
    }
}
