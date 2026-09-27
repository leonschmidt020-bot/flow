import Foundation
import NaturalLanguage

/// Schnell UND genau: erst Parakeet (~50 ms, Neural Engine), und nur wenn das Ergebnis unsicher ist
/// oder Wörterbuch-Wörter im Spiel sind, Whisper mit Wörterbuch-Hinweis (~0,5–0,9 s, GPU).
///
/// Schwellen kalibriert mit `Flow --engine-bench` + `--engine-calibrate` (74 Testclips DE/EN, 26.09.2026):
/// mittlere Token-Sicherheit ≥ 0,90, kein Wort < 0,30, kein Wörterbuch-Wort (Schreibung ±34 % oder Kölner Phonetik).
/// Ergebnis: WER 8,4 % (Whisper allein 9,2–9,4 %), echte Diktate p50 ~0,14 s statt ~1,4 s.
enum HybridRecognizer {
    struct Policy: Sendable {
        /// Parakeet wird genommen, wenn die mittlere Token-Sicherheit mindestens so hoch ist …
        var minMeanConfidence: Float = 0.90
        /// … und kein einzelnes Wort unsicherer ist als das.
        var minWordConfidence: Float = 0.30
        /// Längere Clips gehen immer an Whisper (Stücke im Diktat sind ≤ ~25 s, greift also praktisch nie)
        var maxParakeetSeconds: Double = 30
        /// Wörterbuch-Nähe: Wörter, die einem Wörterbuch-Ziel bis auf so viele Buchstaben gleichen (relativ), lösen Whisper aus
        var fuzzyRatio: Double = 0.34
        /// Auch wenn ein „gehört“-Eintrag (z. B. „Whisper Flow“) direkt ersetzt werden könnte: Whisper nehmen?
        /// false = Regel reicht (TextCleaner ersetzt ihn sowieso) – nur „vocabOnly“-Einträge (z. B. „Legal“→Lidl) lösen aus.
        var ruleAliasesTriggerWhisper = false
        /// Klangähnlichkeit (Kölner Phonetik): „all die“ ≈ Aldi, „Whisperflow“ ≈ Flow → Whisper
        var phonetic = true
        /// Zusätzliche Namen (nur Hinweis/Auslöser, keine Ersetzung) – z. B. Brenninkmeyer, Dufresne
        var extraVocabulary: [String] = []
    }

    nonisolated(unsafe) static var policy = Policy()

    // Austauschbare Motoren (Kern setzt `parakeet` auf Transcriber.shared, siehe Bericht; Bench setzt eigene Server).
    nonisolated(unsafe) static var parakeet: @Sendable ([Float]) async throws -> ScoredText = { try await EngineParakeet.shared.transcribe($0) }
    /// (Samples, Zusammenhang, Sprach-Hinweis "de"/"en"/nil). Der Hinweis spart Whispers eigene Spracherkennung
    /// (gemessen 26.09.2026, 4 echte Diktate: ~2,5 s → ~1,3 s, Text identisch).
    nonisolated(unsafe) static var whisper: @Sendable ([Float], String, String?) async throws -> String = { s, ctx, lang in
        try await WhisperEngine.shared.dictate(Transcriber.normalizedGentle(s), context: ctx, language: lang).text
    }
    nonisolated(unsafe) static var whisperReady: @Sendable () -> Bool = { WhisperEngine.shared.ready }

    /// Sprache für Whisper aus dem Parakeet-Text (NLLanguageRecognizer, nur DE/EN).
    /// Spart Whispers eigene Spracherkennung = einen kompletten zweiten Encoder-Lauf (~0,55 s von ~1,15 s).
    /// nil = zu unsicher (sehr kurzer Text) → Whisper entscheidet selbst.
    static func languageHint(_ parakeetText: String) -> String? {
        let mode = Settings.frozen.languageMode
        if mode != .both { return mode.rawValue }
        let words = parakeetText.split(whereSeparator: { !$0.isLetter }).count
        guard words >= 2 else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english]
        r.processString(parakeetText)
        let h = r.languageHypotheses(withMaximum: 2)
        let de = h[.german] ?? 0, en = h[.english] ?? 0
        if max(de, en) < 0.75 { return nil }
        return en > de ? "en" : "de"
    }

    /// Lernen aus Whisper-Korrekturen (AliasLearner). Der Kern hängt die fertigen Einträge ans Wörterbuch.
    nonisolated(unsafe) static var learnAliases = true
    nonisolated(unsafe) static var onLearned: (([DictEntry]) -> Void)?

    struct Decision: Sendable { let accept: Bool; let reason: String }

    /// Soll das Parakeet-Ergebnis direkt genommen werden?
    static func decide(_ p: ScoredText, seconds: Double, policy: Policy = HybridRecognizer.policy, dictionary: [DictEntry]? = nil) -> Decision {
        let d = decide(text: p.text, mean: p.meanConfidence, minWord: p.minWordConfidence, seconds: seconds, policy: policy, dictionary: dictionary)
        // Nur ein Bildschirm-Begriff „ähnelt“ einem sicher gehörten echten Wort → kein Whisper (VoiceFlow/Speed/ScreenTriggerVeto)
        if !d.accept, d.reason.hasPrefix("wörterbuch:"),
           ScreenTriggerVeto.applies(p, policy: policy, dictionary: dictionary ?? Settings.frozen.dictionary) {
            return Decision(accept: true, reason: "sicher (Bildschirm-Treffer: echte Wörter)")
        }
        return d
    }

    static func decide(text: String, mean: Float, minWord: Float, seconds: Double, policy: Policy = HybridRecognizer.policy,
                       dictionary: [DictEntry]? = nil) -> Decision {
        if text.isEmpty { return Decision(accept: false, reason: "leer") }
        if seconds > policy.maxParakeetSeconds { return Decision(accept: false, reason: "lang") }
        if LanguageGuard.looksForeign(text) { return Decision(accept: false, reason: "fremdsprache") }
        let mode = Settings.frozen.languageMode
        if mode != .both, LanguageGuard.guessDeEn(text) != mode.rawValue { return Decision(accept: false, reason: "sprache≠\(mode.rawValue)") }
        if mean < policy.minMeanConfidence { return Decision(accept: false, reason: String(format: "mittel %.2f", mean)) }
        if minWord < policy.minWordConfidence { return Decision(accept: false, reason: String(format: "wort %.2f", minWord)) }
        let dict = dictionary ?? Settings.frozen.dictionary
        // Erst die sicheren Ersetzungen anwenden (die macht TextCleaner später ohnehin) – ein bekannter Verhörer
        // wie „Whisper Floor“ ist damit schon repariert und braucht kein Whisper.
        if let hit = VocabTrigger.hit(in: VocabTrigger.applyAliases(text, dictionary: dict), dictionary: dict, policy: ContextBoost.policy(policy)) {
            return Decision(accept: false, reason: "wörterbuch:\(hit)")
        }
        return Decision(accept: true, reason: String(format: "sicher %.2f/%.2f", mean, minWord))
    }

    /// Alles, was eine Erkennung braucht – live aus den globalen Motoren, im Test/Training austauschbar.
    struct Env: @unchecked Sendable {
        var parakeet: @Sendable ([Float]) async throws -> ScoredText
        var whisper: @Sendable ([Float], String, String?) async throws -> String
        var whisperReady: @Sendable () -> Bool
        var dictionary: [DictEntry]
        var names: [NameProfile]
        var learnAliases: Bool

        static func live() -> Env {
            Env(parakeet: HybridRecognizer.parakeet, whisper: HybridRecognizer.whisper, whisperReady: HybridRecognizer.whisperReady,
                dictionary: Settings.frozen.dictionary, names: ContextBoost.withTempProfiles(NameStore.shared.profiles()), learnAliases: HybridRecognizer.learnAliases)
        }
    }

    /// Ergebnis mit Details (für Training/Test)
    struct Outcome: Sendable {
        let text: String
        let engine: String
        let ms: Int
        /// Namen, die der Namen-Prüfer gefunden und (per Whisper oder Klang) bestätigt hat
        let namesFixed: [String]
        let parakeetText: String
        /// Warum Whisper gefragt wurde („mittel 0.82“, „wort 0.21“, „wörterbuch:Pierre“, „namen“ …) – nur fürs Protokoll
        var reason: String = ""
    }

    /// Erkennt 16-kHz-Mono-Samples. engine = "parakeet" | "whisper" | "parakeet(fallback)" | "whisper+namen" | "parakeet+namen".
    static func recognize(_ samples: [Float], context: String) async -> (text: String, engine: String, ms: Int) {
        let o = await recognize(samples, context: context, env: .live())
        return (o.text, o.reason.isEmpty ? o.engine : "\(o.engine) [\(o.reason)]", o.ms)
    }

    /// Flüstern erkennen und direkt an Whisper geben (Parakeet ist bei Flüstern schwach). Aus = altes Verhalten.
    nonisolated(unsafe) static var whisperRouting = true

    /// Frist für Whisper-Aufrufe (VoiceFlow/Speed/TempoGuard, „Tempo-Garantie“). nil = ohne Frist.
    /// Wirft bei überschrittener Frist → der Aufruf gilt als fehlgeschlagen (wie ohne Whisper: Parakeet + Klang-Namen).
    nonisolated(unsafe) static var whisperGuard: (@Sendable (String, @escaping @Sendable () async throws -> String) async throws -> String)?

    static func askWhisper(_ env: Env, _ s: [Float], _ ctx: String, _ lang: String?, _ what: String) async throws -> String {
        guard let g = whisperGuard else { return try await env.whisper(s, ctx, lang) }
        let w = env.whisper
        return try await g(what) { try await w(s, ctx, lang) }
    }

    static func recognize(_ samples: [Float], context: String, env: Env) async -> Outcome {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        let seconds = Double(samples.count) / 16000
        if whisperRouting, env.whisperReady(), WhisperDetector.analyze(samples).isWhisper,
           let o = await recognizeWhispered(samples, context: context, env: env, t0: t0) {
            return o
        }
        let p0 = try? await env.parakeet(samples)
        // Namen-Prüfer: klingt eine unsichere Stelle nach einem trainierten Namen?
        var cands = p0.map { NameBooster.candidates($0, profiles: env.names, dictionary: env.dictionary) } ?? []
        // Klang-Veto: klingt die Stelle klar anders als die eigenen Aufnahmen des Namens → gar nicht erst fragen
        if let p0, !cands.isEmpty {
            cands = cands.filter { c in
                guard let prof = env.names.first(where: { $0.target == c.target }), !prof.templates.isEmpty, !c.exact else { return true }
                return NameBooster.acousticDistance(samples, p0, candidate: c, profile: prof) <= NameBooster.rules.acousticVeto
            }
        }
        // Gelernte Kunstwörter („JarQuest“) direkt ersetzen – kein Whisper nötig (wie eine Wörterbuch-Regel)
        let direct = cands.filter(\.direct)
        cands = cands.filter { !$0.direct }
        var directFixed = direct.map(\.target)
        let p = p0.map { direct.isEmpty ? $0 : NameBooster.applyDirect($0, direct) }
        if !direct.isEmpty, let p {
            // Übrige Kandidaten beziehen sich auf die alten Wort-Positionen → neu suchen
            cands = NameBooster.candidates(p, profiles: env.names, dictionary: env.dictionary).filter { !$0.direct }
        }
        if let p, !cands.isEmpty {
            let targets = cands.map(\.target)
            if env.whisperReady() {
                // Namens-Sätze ans Ende des Hinweises (dort wirkt er am stärksten); vorheriges Stück davor, gekürzt
                let lang = NameBooster.whisperLanguage(p, candidates: cands, profiles: env.names, fallback: languageHint(p.text))
                let names = NameBooster.prompt(for: Array(Set(targets)), profiles: env.names, language: lang)
                let ctx = (context.isEmpty ? "" : String(context.suffix(max(0, 158 - names.count))) + " ") + names
                if let w = try? await askWhisper(env, samples, ctx, lang, "Whisper (Namen)"), !w.isEmpty {
                    let m = NameBooster.merge(parakeet: p, whisper: w, candidates: cands)
                    return Outcome(text: m.text, engine: m.fixed.isEmpty ? "whisper" : "whisper+namen", ms: ms(), namesFixed: m.fixed + directFixed, parakeetText: p0?.text ?? p.text)
                }
            }
            // Ohne Whisper: nur mit passendem Klang ersetzen
            var text = p.text
            var fixed: [String] = []
            var cur = p
            for c in cands.sorted(by: { $0.index > $1.index }) where c.conf < NameBooster.rules.acousticMaxConf {
                guard let prof = env.names.first(where: { $0.target == c.target }), let thr = prof.dtwThreshold else { continue }
                if NameBooster.acousticDistance(samples, p, candidate: c, profile: prof) <= thr {
                    text = NameBooster.replace(cur, candidate: c)
                    cur = ScoredText(text: text, tokenConfidences: cur.tokenConfidences,
                                     words: text.split(separator: " ").map { (word: String($0), conf: Float(1)) }, times: cur.times)
                    fixed.append(c.target)
                }
            }
            if !fixed.isEmpty { return Outcome(text: text, engine: "parakeet+namen", ms: ms(), namesFixed: fixed + directFixed, parakeetText: p0?.text ?? p.text) }
        }
        var why = p == nil ? "kein parakeet" : ""
        if let p {
            let d = decide(p, seconds: seconds, dictionary: env.dictionary)
            why = d.reason
            if d.accept || !env.whisperReady() {
                let eng = (d.accept ? "parakeet" : "parakeet(fallback)") + (directFixed.isEmpty ? "" : "+namen")
                return Outcome(text: p.text, engine: eng, ms: ms(), namesFixed: directFixed, parakeetText: p0?.text ?? p.text)
            }
        }
        let hint = p.flatMap { languageHint($0.text) }
        // Stehen trainierte Namen schon im Parakeet-Text, bekommt Whisper ihre Sätze mit (sonst „verschlimmbessert“ es sie)
        let present = p.map { NameBooster.present($0.text, profiles: env.names) } ?? []
        var ctx = context
        if !present.isEmpty {
            let names = NameBooster.prompt(for: present, profiles: env.names, language: hint)
            ctx = (context.isEmpty ? "" : String(context.suffix(max(0, 158 - names.count))) + " ") + names
        }
        if env.whisperReady(), let w = try? await askWhisper(env, samples, ctx, hint, "Whisper") {
            if env.learnAliases, let pt = p?.text, !pt.isEmpty, !w.isEmpty {
                let dict = env.dictionary
                Task.detached(priority: .utility) {
                    // Whisper-Text erst durch die bekannten Ersetzungen („Whisper Flow“ → „Flow“), dann vergleichen
                    let ready = AliasLearner.observe(parakeet: pt, whisper: VocabTrigger.applyAliases(w, dictionary: dict), dictionary: dict)
                    if !ready.isEmpty { onLearned?(ready) }
                }
            }
            // Whisper leer (z. B. als „Hinweis nachgeplappert“ verworfen), Parakeet hatte etwas → Parakeet nehmen
            if w.isEmpty, let pt = p?.text, !pt.isEmpty {
                return Outcome(text: pt, engine: "parakeet(whisper leer)", ms: ms(), namesFixed: [], parakeetText: pt, reason: why)
            }
            // Whisper-Text gilt (ganzer Satz); direkt ersetzte Namen zählen nur, wenn Whisper sie auch schreibt
            directFixed = directFixed.filter { NameBooster.contains(w, target: $0) }
            return Outcome(text: w, engine: "whisper", ms: ms(), namesFixed: directFixed, parakeetText: p0?.text ?? "", reason: why)
        }
        return Outcome(text: p?.text ?? "", engine: "parakeet(fallback)", ms: ms(), namesFixed: directFixed, parakeetText: p0?.text ?? "")
    }
}

extension HybridRecognizer {
    /// Geflüstert: Pegel für Flüstern (WhisperGain), Sprache wie gewohnt (fest eingestellt oder aus einem schnellen
    /// Parakeet-Lauf, ~50–100 ms), Whisper large-v3-turbo mit Wörterbuch-Hinweis (+ Sätze trainierter Namen).
    static func recognizeWhispered(_ samples: [Float], context: String, env: Env, t0: Date) async -> Outcome? {
        let prepared = WhisperGain.prepare(samples)
        var hint: String?
        let mode = Settings.frozen.languageMode
        var pText = ""
        if mode != .both { hint = mode.rawValue } else if let p = try? await env.parakeet(prepared) { pText = p.text; hint = languageHint(p.text) }
        let present = pText.isEmpty ? [] : NameBooster.present(pText, profiles: env.names)
        var ctx = context
        if !present.isEmpty {
            let names = NameBooster.prompt(for: present, profiles: env.names, language: hint)
            ctx = (context.isEmpty ? "" : String(context.suffix(max(0, 158 - names.count))) + " ") + names
        }
        guard let w = try? await askWhisper(env, prepared, ctx, hint, "Whisper (Flüstern)"), !w.isEmpty else { return nil }
        return Outcome(text: w, engine: "whisper", ms: Int(Date().timeIntervalSince(t0) * 1000), namesFixed: [], parakeetText: pText, reason: "flüstern")
    }
}

/// Erkennt, ob ein Parakeet-Text Wörterbuch-Wörter (oder etwas, das so ähnlich klingt/aussieht) enthält.
enum VocabTrigger {
    static func norm(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Hör-Varianten → Schreibweise (nur echte Ersetzungen, nicht „vocabOnly“) – wie TextCleaner.applyRules
    static func applyAliases(_ text: String, dictionary: [DictEntry]) -> String {
        var s = text
        for e in dictionary where !e.heard.trimmingCharacters(in: .whitespaces).isEmpty && e.vocabOnly != true {
            guard let re = TextCleaner.regex(for: e.heard) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: e.write))
        }
        return s
    }

    /// Ersten Auslöser zurückgeben (oder nil)
    static func hit(in text: String, dictionary: [DictEntry], policy: HybridRecognizer.Policy) -> String? {
        let t = " " + norm(text) + " "
        let words = t.split(separator: " ").map(String.init)
        var targets = Set<String>()
        for e in dictionary {
            let w = norm(e.write)
            if !w.isEmpty { targets.insert(w) }
            let h = norm(e.heard)
            guard !h.isEmpty, h != w else { continue }
            // Mehrdeutige Hör-Varianten („Legal“ → Lidl) kann nur Whisper mit Hinweis entscheiden
            let risky = e.vocabOnly == true || policy.ruleAliasesTriggerWhisper
            if risky, t.contains(" " + h + " ") { return "„\(e.heard)“" }
        }
        for x in policy.extraVocabulary { let w = norm(x); if !w.isEmpty { targets.insert(w) } }
        // Ziel schon richtig geschrieben da? Dann ist es kein Problem.
        // Sonst: Wortfolgen, die einem Ziel ähnlich sehen (Buchstaben-Abstand) oder klingen (Kölner Phonetik) → Whisper
        let wordCodes = words.map { colognePhonetic($0) }
        for target in targets {
            if t.contains(" " + target + " ") { continue }
            let n = target.split(separator: " ").count
            let tj = target.replacingOccurrences(of: " ", with: "")
            guard tj.count >= 4 else { continue }
            let tCode = colognePhonetic(tj)
            let maxD = max(1, Int((Double(tj.count) * policy.fuzzyRatio).rounded(.down)))
            for span in max(1, n - 1)...(n + 1) where words.count >= span {
                for i in 0...(words.count - span) {
                    let cand = words[i..<(i + span)].joined()
                    if cand == tj { continue }
                    // Klang: gleicher Code (mind. 3 Stellen, damit kurze Codes nicht überall passen)
                    // + gleicher Anfangsbuchstabe und ähnliche Länge (sonst: „halt“ ≈ „Aldi“, beide 052)
                    if policy.phonetic, tCode.count >= 3, cand.first == tj.first, abs(cand.count - tj.count) <= 2 {
                        let cCode = collapse(wordCodes[i..<(i + span)].joined())
                        if cCode == tCode { return "\(cand)≈\(target) (Klang)" }
                    }
                    if policy.fuzzyRatio <= 0 { continue }
                    if abs(cand.count - tj.count) > maxD { continue }
                    if cand.first != tj.first && levenshtein(Array(cand.prefix(2)), Array(tj.prefix(2))) > 1 { continue }
                    let d = levenshtein(Array(cand), Array(tj))
                    if d > 0 && d <= maxD { return "\(cand)≈\(target)" }
                }
            }
        }
        return nil
    }

    /// Kölner Phonetik (deutsche Laut-Codes, für englische Namen grob ausreichend). „Aldi“ = „all die“ = 052.
    static func colognePhonetic(_ word: String) -> String {
        let s = Array(word.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ä", with: "a").replacingOccurrences(of: "ö", with: "o").replacingOccurrences(of: "ü", with: "u"))
        var raw = ""
        for (i, c) in s.enumerated() {
            let prev: Character? = i > 0 ? s[i - 1] : nil
            let next: Character? = i + 1 < s.count ? s[i + 1] : nil
            switch c {
            case "a", "e", "i", "j", "o", "u", "y": raw += "0"
            case "h": continue
            case "b": raw += "1"
            case "p": raw += next == "h" ? "3" : "1"
            case "d", "t": raw += (next.map { "csz".contains($0) } ?? false) ? "8" : "2"
            case "f", "v", "w": raw += "3"
            case "g", "k", "q": raw += "4"
            case "c":
                if i == 0 { raw += (next.map { "ahkloqrux".contains($0) } ?? false) ? "4" : "8" }
                else if let p = prev, "sz".contains(p) { raw += "8" }
                else { raw += (next.map { "ahkoqux".contains($0) } ?? false) ? "4" : "8" }
            case "x": raw += (prev.map { "ckq".contains($0) } ?? false) ? "8" : "48"
            case "l": raw += "5"
            case "m", "n": raw += "6"
            case "r": raw += "7"
            case "s", "z": raw += "8"
            default: if c.isNumber { raw.append(c) }
            }
        }
        return collapse(raw)
    }

    /// Doppelte Ziffern zusammenfassen, Nullen (Vokale) außer am Anfang entfernen
    static func collapse(_ raw: String) -> String {
        var out = ""
        var last: Character?
        for ch in raw { if ch != last { out.append(ch) }; last = ch }
        guard let f = out.first else { return "" }
        return String(f) + out.dropFirst().filter { $0 != "0" }
    }

    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
