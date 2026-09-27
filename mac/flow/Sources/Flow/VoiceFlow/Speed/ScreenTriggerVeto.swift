import Foundation

/// Falsche Whisper-Auslöser durch Bildschirm-Begriffe abfangen (Agent SPEED, 27.09.2026).
///
/// Seit 1.7.0 sind unbekannte Wörter vom Bildschirm zusätzliche Auslöser („Kontext-Diktat“). Das schickt auch Sätze zu
/// Whisper (+0,6–0,8 s), in denen Parakeet ein ECHTES Wort sicher gehört hat, das einem Bildschirm-Begriff nur ähnelt –
/// z. B. ein Log vom 27.09.: „wörterbuch:funktion≈funktio“ (808 ms) oder im Kontext-Test „bring≈hallbauer (Klang)“.
/// Veto nur, wenn der Treffer AUSSCHLIESSLICH von Bildschirm-Begriffen kommt (nie beim eigenen Wörterbuch/trainierten Namen)
/// und jedes Wort an der Stelle ein echtes Wort (de/en) mit Parakeet-Sicherheit ≥ 0,85 ist.
enum ScreenTriggerVeto {
    nonisolated(unsafe) static var minConfidence: Float = 0.85
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["VF_NO_SCREEN_VETO"] == nil   // Messbank: Vergleich ohne Veto

    /// true = Parakeet-Ergebnis gilt trotz Bildschirm-Treffer
    static func applies(_ p: ScoredText, policy: HybridRecognizer.Policy, dictionary: [DictEntry]) -> Bool {
        guard enabled else { return false }
        let full = ContextBoost.policy(policy)
        let screen = full.extraVocabulary.filter { e in !policy.extraVocabulary.contains { $0.caseInsensitiveCompare(e) == .orderedSame } }
        guard !screen.isEmpty else { return false }
        // Trifft schon das eigene Wörterbuch (ohne Bildschirm)? Dann bleibt es bei Whisper.
        if VocabTrigger.hit(in: VocabTrigger.applyAliases(p.text, dictionary: dictionary), dictionary: dictionary, policy: policy) != nil { return false }
        var sp = policy
        sp.extraVocabulary = screen
        guard let hits = vocabHits(p, dictionary: [], policy: sp), !hits.isEmpty else { return false }
        var words: [String] = []
        for h in hits {
            for i in h.lo..<h.hi {
                guard p.words[i].conf >= minConfidence else { return false }
                let bare = p.words[i].word.trimmingCharacters(in: .punctuationCharacters)
                guard bare.count >= 2 else { return false }
                words.append(bare)
            }
        }
        guard SpellBatch.unknown(words).isEmpty else { return false }
        log("Bildschirm-Auslöser ignoriert (Parakeet hörte sicher echte Wörter): " + hits.map { h in "\(p.words[h.lo..<h.hi].map(\.word).joined(separator: " "))≈\(h.write)" }.joined(separator: ", "))
        return true
    }

    struct Hit: Sendable, Equatable { let lo: Int; let hi: Int; let write: String }

    /// Alle Wörterbuch-/Bildschirm-Treffer mit Wort-Positionen. nil = ein Treffer lässt sich nicht verorten.
    static func vocabHits(_ p: ScoredText, dictionary: [DictEntry], policy: HybridRecognizer.Policy) -> [Hit]? {
        // flache Teil-Liste: norm-Teile je Parakeet-Wort
        var parts: [String] = [], owner: [Int] = []
        for (i, w) in p.words.enumerated() {
            for x in VocabTrigger.norm(w.word).split(separator: " ") { parts.append(String(x)); owner.append(i) }
        }
        guard !parts.isEmpty else { return [] }
        // wie decide(): was die sicheren Ersetzungen (TextCleaner) ohnehin reparieren, ist kein Treffer
        let joinedAll = " " + parts.joined(separator: " ") + " " + VocabTrigger.norm(VocabTrigger.applyAliases(p.text, dictionary: dictionary)) + " "
        var out: [Hit] = []
        func add(_ i: Int, _ span: Int, _ write: String) {
            let h = Hit(lo: owner[i], hi: owner[i + span - 1] + 1, write: write)
            if !out.contains(where: { $0.lo < h.hi && h.lo < $0.hi }) { out.append(h) }
        }
        // (1) mehrdeutige Hör-Varianten („Legal“ → Lidl)
        var targets: [(norm: String, write: String)] = []
        for e in dictionary {
            let w = VocabTrigger.norm(e.write)
            if !w.isEmpty, !targets.contains(where: { $0.norm == w }) { targets.append((w, e.write.trimmingCharacters(in: .whitespaces))) }
            let h = VocabTrigger.norm(e.heard)
            guard !h.isEmpty, h != w, e.vocabOnly == true || policy.ruleAliasesTriggerWhisper else { continue }
            let hp = h.split(separator: " ").map(String.init)
            guard hp.count <= parts.count else { continue }
            for i in 0...(parts.count - hp.count) where Array(parts[i..<(i + hp.count)]) == hp { add(i, hp.count, e.write) }
        }
        for x in policy.extraVocabulary {
            let w = VocabTrigger.norm(x)
            if !w.isEmpty, !targets.contains(where: { $0.norm == w }) { targets.append((w, x)) }
        }
        // (2) ähnlich geschriebene/klingende Wortfolgen
        let codes = parts.map { VocabTrigger.colognePhonetic($0) }
        for (target, write) in targets {
            if joinedAll.contains(" " + target + " ") { continue }
            let n = target.split(separator: " ").count
            let tj = target.replacingOccurrences(of: " ", with: "")
            guard tj.count >= 4 else { continue }
            let tCode = VocabTrigger.colognePhonetic(tj)
            let maxD = max(1, Int((Double(tj.count) * policy.fuzzyRatio).rounded(.down)))
            spans: for span in max(1, n - 1)...(n + 1) where parts.count >= span {
                for i in 0...(parts.count - span) {
                    let cand = parts[i..<(i + span)].joined()
                    if cand == tj { continue }
                    if policy.phonetic, tCode.count >= 3, cand.first == tj.first, abs(cand.count - tj.count) <= 2,
                       VocabTrigger.collapse(codes[i..<(i + span)].joined()) == tCode { add(i, span, write); break spans }
                    if policy.fuzzyRatio <= 0 { continue }
                    if abs(cand.count - tj.count) > maxD { continue }
                    if cand.first != tj.first && VocabTrigger.levenshtein(Array(cand.prefix(2)), Array(tj.prefix(2))) > 1 { continue }
                    let d = VocabTrigger.levenshtein(Array(cand), Array(tj))
                    if d > 0 && d <= maxD { add(i, span, write); break spans }
                }
            }
        }
        return out
    }
}
