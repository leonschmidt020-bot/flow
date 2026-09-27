import Combine
import FluidAudio
import Foundation

/// Erkenner + Wörterbuch fürs Wort-Training. Live = echte Engines und eigenes Wörterbuch;
/// im Selbsttest eine abgeschottete Variante (eigener Whisper-Server, Wörterbuch + Namen-Profile nur in Testdateien).
protocol WordTrainingBackend: AnyObject {
    /// "de"/"en", wenn die Sprache fest eingestellt ist; nil = pro Wort erkennen
    var fixedLanguage: String? { get }
    func ensureWhisper() async -> Bool
    func whisper(_ samples: [Float], language: String, prompt: String?) async throws -> (text: String, language: String)
    /// Parakeet mit Sicherheit + Wort-Zeiten
    func scored(_ samples: [Float]) async throws -> ScoredText
    func dictionary() -> [DictEntry]
    /// Wie ein echtes Diktat: HybridRecognizer (Parakeet → Namen-Prüfer → Whisper) mit genau diesen Namen-Profilen
    /// und diesem Wörterbuch, danach die Wörterbuch-Ersetzungen.
    func recognize(_ samples: [Float], names: [NameProfile], dictionary: [DictEntry]) async -> HybridRecognizer.Outcome
    /// Variante ins Wörterbuch (echtes Wort → nur Hinweis, sonst ersetzen). true = vocabOnly. Schreibt KEINE „Gelernt“-Zeile.
    func learn(heard: String, write: String) async -> Bool
    /// Zielwort als Hinweis-Eintrag, damit Whisper es im Wörterbuch-Satz bekommt
    func ensureVocabulary(_ word: String) async
    /// Protokoll: „Gelernt: „heard“ → „write““-Zeilen (echte Korrekturen)
    func correctionLines() -> [(heard: String, write: String)]
    /// Texte aus dem Diktat-Verlauf (nur im Speicher, werden nie protokolliert)
    func historyTexts() -> [String]
    var names: NameStore { get }
}

extension WordTrainingBackend {
    func correctionCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        for c in correctionLines() { out[c.write.lowercased(), default: 0] += 1 }
        return out
    }
}

final class LiveWordBackend: WordTrainingBackend {
    var fixedLanguage: String? {
        switch Settings.frozen.languageMode { case .de: return "de"; case .en: return "en"; case .both: return nil }
    }
    var names: NameStore { NameStore.shared }

    func ensureWhisper() async -> Bool {
        if WhisperEngine.shared.ready { return true }
        guard WhisperEngine.available else { return false }
        WhisperEngine.shared.start()
        for _ in 0..<120 {   // bis 30 s
            if WhisperEngine.shared.ready { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return WhisperEngine.shared.ready
    }

    func whisper(_ samples: [Float], language: String, prompt: String?) async throws -> (text: String, language: String) {
        let r = try await WhisperEngine.shared.transcribe(Transcriber.normalizedGentle(samples), language: language, prompt: prompt)
        return (r.text, r.language)
    }

    func scored(_ samples: [Float]) async throws -> ScoredText { try await HybridRecognizer.parakeet(samples) }

    func dictionary() -> [DictEntry] {
        Thread.isMainThread ? Settings.shared.dictionary : Settings.frozen.dictionary
    }

    func recognize(_ samples: [Float], names: [NameProfile], dictionary: [DictEntry]) async -> HybridRecognizer.Outcome {
        var env = HybridRecognizer.Env.live()
        env.names = names
        env.dictionary = dictionary
        env.learnAliases = false
        return await HybridRecognizer.recognize(samples, context: "", env: env)
    }

    func learn(heard: String, write: String) async -> Bool {
        await MainActor.run {
            let st = Settings.shared
            let vocab = !heard.contains(" ") && TrainingText.isRealWord(heard)
            if let i = st.dictionary.firstIndex(where: { $0.heard.lowercased() == heard.lowercased() }) {
                st.dictionary[i].write = write; st.dictionary[i].learned = true; st.dictionary[i].vocabOnly = vocab
            } else {
                st.dictionary.append(DictEntry(heard: heard, write: write, learned: true, vocabOnly: vocab))
            }
            st.save()
            return vocab
        }
    }

    func ensureVocabulary(_ word: String) async {
        await MainActor.run {
            let st = Settings.shared
            guard !st.dictionary.contains(where: { $0.write.lowercased() == word.lowercased() }) else { return }
            st.dictionary.append(DictEntry(heard: word, write: word, learned: nil, vocabOnly: true))
            st.save()
        }
    }

    func correctionLines() -> [(heard: String, write: String)] { WordTrainer.parseCorrectionLines(logURL: Paths.log) }

    func historyTexts() -> [String] {
        if Thread.isMainThread { return DictationHistory.shared.records.map(\.text) }
        return DispatchQueue.main.sync { DictationHistory.shared.records.map(\.text) }
    }
}

/// Wort-Training: Man liest 6 kurze Sätze mit dem Wort (Standard) – oder sagt nur das Wort 6×.
/// Flow richtet das Erkannte am bekannten Satz aus, lernt daraus, wie man den Namen im Satz ausspricht
/// (Hörvarianten, Nachbarwörter, Klang-Vorlagen), und misst vorher/jetzt ehrlich: jede Aufnahme wird mit einem
/// Profil aus den ÜBRIGEN Aufnahmen geprüft.
final class WordTrainer: ObservableObject {
    static let shared = WordTrainer()
    static let takesPerWord = 6

    enum Mode: String, Codable { case sentences, word }

    struct Take: Codable, Equatable {
        var file: String?
        /// Whisper ohne Hinweis
        var plain: String
        var parakeet: String
        /// Wie ein echtes Diktat vor dem Training
        var before: String
        /// … und jetzt (Profil aus den übrigen Aufnahmen)
        var after: String
        var okPlain: Bool
        var okBefore: Bool
        var okAfter: Bool
        /// Vorgelesener Satz (Satz-Training)
        var sentence: String?
        /// Was an der Stelle des Namens gehört wurde
        var heardAs: String?
    }

    struct TestResult: Codable, Equatable {
        var text: String
        var ok: Bool
        var engine: String
        var date: Date
    }

    struct Record: Codable, Equatable, Identifiable {
        var id: String { word }
        var word: String
        var language: String
        var date: Date
        var takes: [Take]
        /// Alle falsch gehörten Varianten (normalisiert)
        var variants: [String]
        /// Davon neu ins Wörterbuch eingetragen
        var learned: [String]
        var hintOnly: [String]
        var accuracyPlain: Int
        var accuracyBefore: Int
        var accuracyAfter: Int
        var total: Int
        var mode: Mode? = nil
        var kind: NameKind? = nil
        /// Klang-Vorlagen im Profil / Klang trennt sicher genug für „ohne Whisper“
        var templates: Int? = nil
        var acousticReady: Bool? = nil
        var lastTest: TestResult? = nil
        /// Mit der neuen Erkennung nachgemessen (alte Einträge)
        var remeasured: Bool? = nil
        /// Geflüstert trainiert („Flüster-Wörter“)
        var whisper: Bool? = nil
    }

    struct Store: Codable, Equatable {
        var version = 2
        var words: [String: Record] = [:]
        var manual: [String] = []
        /// Flüster-Wörter: dasselbe Training geflüstert (eigene Messung, fehlt in alten Dateien)
        var whisperWords: [String: Record]? = nil
    }

    struct Candidate: Identifiable, Equatable {
        var id: String { word }
        var word: String
        var reasons: [String]
        var corrections: Int
        var learnedFromEdits: Bool
        var manual: Bool
        var record: Record?
    }

    /// Wie oft ein Name in eigenen Diktaten vorkam (richtig geschrieben) und wie oft man ihn korrigieren musste
    struct DictationStats: Equatable { var correct: Int; var corrected: Int }

    @Published private(set) var store: Store
    let backend: WordTrainingBackend
    let storeURL: URL
    let clipsDir: URL

    init(base: URL = Paths.base, backend: WordTrainingBackend = LiveWordBackend()) {
        storeURL = base.appendingPathComponent("wort-training.json")
        clipsDir = base.appendingPathComponent("training")
        self.backend = backend
        store = TrainingFiles.read(Store.self, from: storeURL) ?? Store()
    }

    func record(_ word: String) -> Record? { store.words[word] }
    func whisperRecord(_ word: String) -> Record? { store.whisperWords?[word] }

    // MARK: Vorschläge

    /// Wörter, die sich zu trainieren lohnen: gelernte ✨ Einträge, oft korrigierte, Namen im Wörterbuch, selbst hinzugefügte.
    func candidates() -> [Candidate] {
        let dict = backend.dictionary()
        let corr = realCorrections()
        var byWord: [String: Candidate] = [:]
        var order: [String] = []
        func add(_ word: String, reason: String?, corrections: Int = 0, learned: Bool = false, manual: Bool = false) {
            let w = word.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty, w.count <= 40 else { return }
            let key = byWord.keys.first { $0.lowercased() == w.lowercased() } ?? w
            var c = byWord[key] ?? Candidate(word: key, reasons: [], corrections: 0, learnedFromEdits: false, manual: false, record: store.words[key])
            if byWord[key] == nil { order.append(key) }
            if let reason, !c.reasons.contains(reason) { c.reasons.append(reason) }
            c.corrections = max(c.corrections, corrections)
            c.learnedFromEdits = c.learnedFromEdits || learned
            c.manual = c.manual || manual
            byWord[key] = c
        }
        // Einträge, die das Wort-Training selbst angelegt hat, zählen nicht als Korrektur
        let fromTraining = trainingLearned()
        var variantsPerWord: [String: Int] = [:]
        for e in dict where e.heard.lowercased() != e.write.lowercased() && !fromTraining.contains(e.heard.lowercased()) {
            variantsPerWord[e.write.lowercased(), default: 0] += 1
        }
        for e in dict where !fromTraining.contains(e.heard.lowercased()) {
            let w = e.write
            let n = max(corr[w.lowercased()] ?? 0, variantsPerWord[w.lowercased()] ?? 0)
            if e.learned == true || (corr[w.lowercased()] ?? 0) > 0 {
                add(w, reason: n > 1 ? "oft korrigiert" : "korrigiert", corrections: n, learned: e.learned == true)
            }
            if WordTrainer.looksLikeName(w) { add(w, reason: "Name im Wörterbuch", corrections: n) }
            else if (variantsPerWord[w.lowercased()] ?? 0) >= 2 { add(w, reason: "oft falsch gehört", corrections: n) }
        }
        for (w, n) in corr where !byWord.keys.contains(where: { $0.lowercased() == w }) {
            if let orig = dict.first(where: { $0.write.lowercased() == w })?.write { add(orig, reason: "oft korrigiert", corrections: n) }
        }
        for w in store.manual { add(w, reason: "selbst hinzugefügt", manual: true) }
        for (w, r) in store.words {
            if let n = corr[w.lowercased()], n > 0 { add(w, reason: n > 1 ? "oft korrigiert" : "korrigiert", corrections: n) }
            if r.accuracyAfter < r.total { add(w, reason: "unsicher erkannt") }
            else { add(w, reason: nil) }
        }
        for k in byWord.keys { byWord[k]?.record = store.words[k] }
        func rank(_ c: Candidate) -> Int {
            guard let r = c.record else { return 0 }
            return r.accuracyAfter < r.total ? 1 : 2
        }
        return order.compactMap { byWord[$0] }.sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            if $0.corrections != $1.corrections { return $0.corrections > $1.corrections }
            return $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
        }
    }

    private func trainingLearned() -> Set<String> {
        Set(store.words.values.flatMap { $0.learned.map { $0.lowercased() } })
    }

    /// echte Korrekturen (ohne Einträge, die das Wort-Training selbst angelegt hat) – pro Zielwort
    func realCorrections() -> [String: Int] {
        let fromTraining = trainingLearned()
        var out: [String: Int] = [:]
        for c in backend.correctionLines() where !fromTraining.contains(c.heard.lowercased()) {
            out[c.write.lowercased(), default: 0] += 1
        }
        return out
    }

    /// „in deinen Diktaten: 7× richtig, 1× korrigiert“ – aus dem Verlauf (Texte bleiben im Speicher) und echten Korrekturen
    func dictationStats(_ word: String) -> DictationStats {
        let correct = backend.historyTexts().filter { NameBooster.contains($0, target: word) }.count
        return DictationStats(correct: correct, corrected: realCorrections()[word.lowercased()] ?? 0)
    }

    /// Für mehrere Wörter auf einmal (Protokoll + Verlauf nur einmal lesen)
    func dictationStats(for words: [String]) -> [String: DictationStats] {
        let texts = backend.historyTexts()
        let corr = realCorrections()
        var out: [String: DictationStats] = [:]
        for w in words {
            out[w] = DictationStats(correct: texts.filter { NameBooster.contains($0, target: w) }.count, corrected: corr[w.lowercased()] ?? 0)
        }
        return out
    }

    /// Name/Marke: kein normales Wörterbuch-Wort oder großgeschriebene Abkürzung (Lidl, KiTaNet, Pierre)
    static func looksLikeName(_ w: String) -> Bool {
        let parts = w.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return false }
        return parts.contains { p in
            let hasUpperInside = p.dropFirst().contains { $0.isUppercase }
            return hasUpperInside || (!TrainingText.isRealWord(p) && p.first?.isLetter == true)
        }
    }

    func addManual(_ word: String) {
        let w = TrainingText.normalize(word)
        guard !w.isEmpty, !store.manual.contains(where: { $0.lowercased() == w.lowercased() }) else { return }
        var s = store
        s.manual.insert(w, at: 0)
        store = s
        save()
    }

    func removeManual(_ word: String) {
        var s = store
        s.manual.removeAll { $0.lowercased() == word.lowercased() }
        store = s
        save()
    }

    // MARK: Training

    enum Step: Equatable { case listening(Int), recognizing(Int, Int), learning, verifying(Int, Int) }

    /// Übungssätze für ein Wort (Sprache nach Einstellung)
    func sentences(for word: String, kind: NameKind) -> [String] {
        TrainingSentences.make(word, kind: kind, language: backend.fixedLanguage ?? "both")
    }

    /// Nur das Wort (alte Schnittstelle)
    func train(word target: String, takes raw: [[Float]], progress: ((Step) -> Void)? = nil) async throws -> Record {
        try await train(word: target, takes: raw, sentences: nil, kind: nil, progress: progress)
    }

    /// Wertet die Aufnahmen aus. `sentences` = vorgelesene Sätze (gleiche Reihenfolge wie `takes`), nil = nur das Wort.
    /// `progress` wird auf dem Main-Thread gemeldet.
    func train(word target: String, takes raw: [[Float]], sentences: [String]?, kind: NameKind?, whisper: Bool = false,
               progress: ((Step) -> Void)? = nil) async throws -> Record {
        let mode: Mode = sentences == nil ? .word : .sentences
        var takes: [[Float]] = [], sents: [String?] = []
        for (i, r) in raw.enumerated() {
            let t = mode == .word ? SpeechMeter.trim(r) : SpeechMeter.trim(r, padBefore: 0.25, padAfter: 0.35)
            guard SpeechMeter.speechSeconds(t) >= (mode == .word ? 0.15 : 0.5) else { continue }
            takes.append(t)
            sents.append(sentences.map { i < $0.count ? $0[i] : nil } ?? nil)
        }
        guard takes.count >= 3 else { throw TrainingError.noTakes }
        func report(_ s: Step) { if let progress { DispatchQueue.main.async { progress(s) } } }
        let kind = kind ?? NameKind.guess(target)

        let whisperOK = await backend.ensureWhisper()
        var lang = backend.fixedLanguage ?? "de"
        if mode == .word, backend.fixedLanguage == nil, whisperOK, let r = try? await backend.whisper(takes[0], language: "auto", prompt: nil) {
            lang = r.language == "english" || r.language == "en" ? "en" : "de"
        }
        let dict = backend.dictionary()
        // Geflüstert: Pegel für Flüstern vor Whisper/Parakeet (die Diktat-Erkennung macht das selbst, siehe HybridRecognizer)
        func lift(_ t: [Float]) -> [Float] { whisper ? WhisperGain.prepare(t) : t }
        let otherProfiles = backend.names.profiles().filter { $0.target != target }
        let previous = backend.names.profile(target)
        let beforeProfiles = otherProfiles + (previous.map { [$0] } ?? [])

        // 1) Ohne Hilfe hören (Parakeet mit Zeiten + Whisper ohne Hinweis) und „vorher“ = echtes Diktat mit dem bisherigen Stand
        var plain: [String] = [], para: [ScoredText?] = [], before: [String] = []
        for (i, t) in takes.enumerated() {
            report(.recognizing(i + 1, takes.count))
            let sl = sents[i].map { backend.fixedLanguage ?? TrainingSentences.language(of: $0) } ?? lang
            plain.append(whisperOK ? ((try? await backend.whisper(lift(t), language: sl, prompt: nil))?.text ?? "") : "")
            para.append(try? await backend.scored(lift(t)))
            let o = await backend.recognize(t, names: beforeProfiles, dictionary: dict)
            before.append(VocabTrigger.applyAliases(o.text, dictionary: dict))
            if Task.isCancelled { throw TrainingError.cancelled }
        }

        // 2) Lernen: pro Aufnahme die Stelle des Namens (Satz-Ausrichtung), Varianten, Nachbarwörter, Klang
        report(.learning)
        let nbTakes = takes.indices.map { NameProfileBuilder.Take(samples: takes[$0], sentence: sents[$0], parakeet: para[$0], whisperPlain: plain[$0]) }
        let pieces = nbTakes.map { NameProfileBuilder.piece($0, target: target) }
        let historyCtx = WordTrainer.contexts(of: target, in: backend.historyTexts())
        let profileLang = mode == .word ? lang : (backend.fixedLanguage ?? "de")

        // Sichere Wörterbuch-Regeln (nur Varianten, die kein echtes Wort enthalten) – je Aufnahme merken für die ehrliche Messung
        func safeRules(_ ps: [NameProfileBuilder.Piece]) -> [String] {
            var out: [String] = []
            for p in ps { for v in [p.variant, p.whisperVariant].compactMap({ $0 }) where WordTrainer.isSafeRule(v, target: target, dict: dict) {
                if !out.contains(where: { $0.lowercased() == v.lowercased() }) { out.append(v) }
            } }
            return out
        }

        // 3) Jetzt: jede Aufnahme mit dem Profil aus den ÜBRIGEN Aufnahmen (+ deren Regeln)
        var after: [String] = []
        for i in takes.indices {
            report(.verifying(i + 1, takes.count))
            let prof = NameProfileBuilder.build(target: target, kind: kind, language: profileLang, pieces: pieces, samples: takes, parakeet: para,
                                                excluding: i, extraContexts: historyCtx, previous: previous)
            var rest = pieces; rest.remove(at: i)
            let rules = safeRules(rest).map { DictEntry(heard: $0, write: target, learned: true, vocabOnly: false) }
            let d = dict + rules + [DictEntry(heard: target, write: target, learned: nil, vocabOnly: true)]
            let o = await backend.recognize(takes[i], names: otherProfiles + [prof], dictionary: d)
            after.append(VocabTrigger.applyAliases(o.text, dictionary: d))
            if Task.isCancelled { throw TrainingError.cancelled }
        }

        // 4) Endgültiges Profil aus allen Aufnahmen speichern, sichere Regeln + Hinweis ins Wörterbuch
        var final = NameProfileBuilder.build(target: target, kind: kind, language: profileLang, pieces: pieces, samples: takes, parakeet: para,
                                             extraContexts: historyCtx, previous: previous)
        // Geflüstert: nur die gehörten Varianten + Nachbarwörter dazulernen – Klang-Vorlagen (MFCC) bleiben die gesprochenen
        // (Flüstern wird ohnehin immer mit Whisper bestätigt)
        if whisper { final = WordTrainer.mergeWhisper(final, into: previous) }
        backend.names.save(final)
        var learned: [String] = [], hintOnly: [String] = []
        for v in safeRules(pieces).prefix(WordTrainer.maxLearnedPerWord) {
            if dict.contains(where: { $0.heard.lowercased() == v.lowercased() }) { continue }
            if await backend.learn(heard: v, write: target) { hintOnly.append(v) }
            learned.append(v)
        }
        await backend.ensureVocabulary(target)

        // Aufnahmen behalten (für späteres Nachprüfen)
        TrainingFiles.secureDir(clipsDir)
        let slug = TrainingText.slug(target) + (mode == .sentences ? "-satz" : "") + (whisper ? "-fluestern" : "")
        var out: [Take] = []
        for i in takes.indices {
            let name = "\(slug)-\(i + 1).wav"
            TrainingFiles.writeWav(takes[i], to: clipsDir.appendingPathComponent(name))
            out.append(Take(file: name, plain: plain[i], parakeet: para[i]?.text ?? "", before: before[i], after: after[i],
                            okPlain: WordTrainer.isCorrect(plain[i], target: target, sentence: sents[i]),
                            okBefore: WordTrainer.isCorrect(before[i], target: target, sentence: sents[i]),
                            okAfter: WordTrainer.isCorrect(after[i], target: target, sentence: sents[i]),
                            sentence: sents[i], heardAs: pieces[i].variant))
        }
        let variants = final.variants.map(\.text)
        let rec = Record(word: target, language: profileLang, date: Date(), takes: out, variants: variants, learned: learned, hintOnly: hintOnly,
                         accuracyPlain: out.filter(\.okPlain).count, accuracyBefore: out.filter(\.okBefore).count,
                         accuracyAfter: out.filter(\.okAfter).count, total: out.count, mode: mode, kind: kind,
                         templates: final.templates.count, acousticReady: final.dtwThreshold != nil)
        var saved = rec
        if whisper { saved.whisper = true }
        let recSnap = saved
        await MainActor.run {
            var s = self.store
            if whisper { var w = s.whisperWords ?? [:]; w[target] = recSnap; s.whisperWords = w } else { s.words[target] = recSnap }
            self.store = s
        }
        save()
        tlog("Wort-Training „\(target)“ (\(mode == .sentences ? "Sätze" : "Wort")\(whisper ? ", geflüstert" : "")): vorher \(rec.accuracyBefore)/\(rec.total), jetzt \(rec.accuracyAfter)/\(rec.total), \(variants.count) Hörvarianten, \(final.templates.count) Klang-Vorlagen")
        return saved
    }

    static let maxLearnedPerWord = 8

    /// Flüster-Training in ein bestehendes Profil einfügen: Varianten zählen dazu, Nachbarwörter dazu,
    /// Klang-Vorlagen und Klang-Schwelle bleiben vom gesprochenen Training (ohne es: keine Vorlagen → immer Whisper-Bestätigung).
    static func mergeWhisper(_ w: NameProfile, into prev: NameProfile?) -> NameProfile {
        guard var p = prev else { var n = w; n.templates = []; n.dtwThreshold = nil; return n }
        for v in w.variants {
            if let i = p.variants.firstIndex(where: { $0.text.lowercased() == v.text.lowercased() }) { p.variants[i].count += v.count }
            else { p.variants.append(v) }
        }
        for (k, c) in w.contexts { p.contexts[k, default: 0] += c }
        p.updated = Date()
        return p
    }

    /// Richtig = Zielwort erkannt. Nur-Wort: höchstens ein Wort drumherum („Lidl.“ ja, „Wir sind ein Lidl.“ nein).
    /// Satz: Name da, und der Rest des Satzes nicht völlig anders (sonst zählt ein halluzinierter Satz mit Namen nicht).
    static func isCorrect(_ text: String, target: String, sentence: String? = nil) -> Bool {
        guard TrainingText.contains(text, target: target) else { return false }
        guard let sentence else {
            // Wiederholungen des Namens sind ok („Pierre, Pierre“ – manche Aufnahmen enthalten das Wort zweimal)
            var rest = " " + TrainingText.key(text) + " "
            let tk = TrainingText.key(target)
            while let r = rest.range(of: " " + tk + " ") { rest.replaceSubrange(r, with: " ") }
            return rest.split(separator: " ").count <= 1
        }
        let a = SentenceAlign.tokens(TrainingText.normalize(sentence)).map(SentenceAlign.key)
        let b = SentenceAlign.tokens(TrainingText.normalize(text)).map(SentenceAlign.key)
        return Double(VocabTrigger.levenshtein(a, b)) <= max(2, Double(a.count) * 0.4)
    }

    static func isCorrect(_ text: String, target: String) -> Bool { isCorrect(text, target: target, sentence: nil) }

    /// Taugt eine Hörvariante als Profil-Eintrag?
    static func isUsableVariant(_ v: String, target: String, targetKey: String) -> Bool {
        let k = TrainingText.key(v)
        guard !k.isEmpty, k != targetKey else { return false }
        guard v.count >= 2, !TrainingText.isJunk(v) else { return false }
        let words = v.split(separator: " ")
        guard words.count <= 3 else { return false }
        if TrainingText.functionWords.contains(k) { return false }
        if words.count == 1, k.count <= 2, targetKey.count > 3 { return false }
        if k.split(separator: " ").contains(where: { String($0) == targetKey }) { return false }
        if isLatin(target), !isLatin(v) { return false }
        return true
    }

    /// Darf eine Variante als feste Wörterbuch-Regel (blind ersetzen) eingetragen werden?
    /// Nur, wenn KEIN Teil ein echtes Wort ist („Jackress“ ja, „Shark Wes“/„Chuck Res“ nein – die bleiben im
    /// Namen-Profil und brauchen dort Beweise: unsichere Stelle + Whisper-Bestätigung oder passender Klang).
    static func isSafeRule(_ v: String, target: String, dict: [DictEntry]) -> Bool {
        guard isUsableVariant(v, target: target, targetKey: TrainingText.key(target)) else { return false }
        let parts = v.split(separator: " ").map(String.init)
        guard parts.allSatisfy({ !TrainingText.isRealWord($0) && $0.count >= 3 }) else { return false }
        return !dict.contains { $0.heard.lowercased() == v.lowercased() && $0.write != target }
    }

    static func isLatin(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { !CharacterSet.letters.contains($0) || $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value) }
    }

    /// Nachbarwörter eines Namens in echten Diktaten (nur Zählung, kein Text wird gespeichert außer dem Nachbarwort)
    static func contexts(of target: String, in texts: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        let tk = SentenceAlign.tokens(target).map(SentenceAlign.key)
        for t in texts where NameBooster.contains(t, target: target) {
            let w = SentenceAlign.tokens(t).map(SentenceAlign.key)
            guard w.count >= tk.count else { continue }
            for i in 0...(w.count - tk.count) where Array(w[i..<(i + tk.count)]) == tk {
                if i > 0, !w[i - 1].isEmpty { out[w[i - 1], default: 0] += 1 }
                if i + tk.count < w.count, !w[i + tk.count].isEmpty { out[w[i + tk.count], default: 0] += 1 }
            }
        }
        return out
    }

    // MARK: Testen

    /// Einmal frei sprechen → was Flow jetzt schreiben würde (echte Erkennung mit allen Profilen + Regeln)
    func test(word: String, samples raw: [Float]) async -> TestResult {
        let s = SpeechMeter.trim(raw, padBefore: 0.25, padAfter: 0.35)
        let dict = backend.dictionary()
        let o = await backend.recognize(s, names: backend.names.profiles(), dictionary: dict)
        let text = TextCleaner.tidy(VocabTrigger.applyAliases(o.text, dictionary: dict))
        let r = TestResult(text: text, ok: NameBooster.contains(text, target: word), engine: o.engine, date: Date())
        await MainActor.run {
            var st = self.store
            if st.words[word] != nil { st.words[word]?.lastTest = r; self.store = st }
        }
        save()
        return r
    }

    /// Alte Einträge (vor dem Namen-Prüfer, „Nur das Wort“) mit den gespeicherten Aufnahmen neu auswerten:
    /// Profil bauen und ehrlich nachmessen. Einmal pro Wort.
    func upgradeOldRecords(progress: ((String) -> Void)? = nil) async {
        for (w, r) in store.words where r.remeasured != true && r.mode == nil {
            let files = r.takes.compactMap(\.file).map { clipsDir.appendingPathComponent($0) }
            let smp = files.compactMap { try? AudioConverter().resampleAudioFile($0) }
            guard smp.count >= 3 else { continue }
            progress?(w)
            let oldBefore = r.accuracyBefore
            guard var nr = try? await train(word: w, takes: smp, sentences: nil, kind: nil) else { continue }
            // „vorher“ = der damals gemessene Stand bleibt die ehrliche Ausgangszahl
            nr.accuracyBefore = min(oldBefore, nr.accuracyBefore)
            nr.remeasured = true
            let snap = nr
            await MainActor.run { var s = self.store; s.words[w] = snap; self.store = s }
            save()
        }
    }

    // MARK: Protokoll

    /// „Gelernt: „ID“ → „Lidl““-Zeilen aus dem Protokoll
    static func parseCorrectionLines(logURL: URL) -> [(heard: String, write: String)] {
        guard let txt = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for line in txt.split(separator: "\n") where line.contains("Gelernt: „") {
            guard let a = line.range(of: "Gelernt: „"), let arrow = line.range(of: "“ → „", range: a.upperBound..<line.endIndex) else { continue }
            let heard = String(line[a.upperBound..<arrow.lowerBound])
            let rest = line[arrow.upperBound...]
            guard let end = rest.firstIndex(of: "“") else { continue }
            let w = String(rest[..<end])
            if !w.isEmpty { out.append((heard, w)) }
        }
        return out.map { (heard: $0.0, write: $0.1) }
    }

    static func parseCorrections(logURL: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        for c in parseCorrectionLines(logURL: logURL) { out[c.write.lowercased(), default: 0] += 1 }
        return out
    }

    private func save() { TrainingFiles.write(store, to: storeURL) }
}
