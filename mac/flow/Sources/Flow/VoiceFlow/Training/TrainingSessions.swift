import AppKit
import Combine
import Foundation

/// Ablauf einer Level-Aufnahme: Rechte → 3-2-1 → Aufnahme (mit Pegel) → Auswertung → Ergebnis.
final class LevelSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case ready, countdown(Int), recording, processing, done, failed(String), micDenied
    }

    let id = UUID()
    let level: VoiceLevel
    let trainer: VoiceTrainer
    @Published var phase: Phase = .ready
    @Published var progress: Double = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 48)
    @Published var result: VoiceTrainer.LevelResult?
    /// Mehrere kurze Aufnahmen (Flüstern): aktuelle Aufnahme (0-basiert)
    @Published var takeIndex = 0
    private var takes: [[Float]] = []

    /// Text der aktuellen Aufnahme (Flüster-Level: ein Satz je Aufnahme, sonst der ganze Text)
    var currentText: String { level.takes.map { $0[min(takeIndex, $0.count - 1)] } ?? level.text }

    private let mic = TrainingMic()
    private var timer: Timer?
    private var generation = 0
    private var startedAt = Date()
    private var work: Task<Void, Never>?

    init(level: VoiceLevel, trainer: VoiceTrainer = .shared) {
        self.level = level
        self.trainer = trainer
    }

    var remaining: Int { max(0, Int((level.seconds * (1 - progress)).rounded(.up))) }
    /// Früher beenden erst ab 60 % (sonst zu wenig Sprache)
    var canFinishEarly: Bool { phase == .recording && progress >= (level.whisper ? 0.3 : 0.6) }

    func start() {
        generation += 1
        let gen = generation
        result = nil
        takes = []
        takeIndex = 0
        Task { @MainActor in
            guard await TrainingMic.permission() == .granted else { self.phase = .micDenied; return }
            guard gen == self.generation else { return }
            for n in [3, 2, 1] {
                self.phase = .countdown(n)
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard gen == self.generation else { return }
            }
            self.beginRecording(gen)
        }
    }

    private func beginRecording(_ gen: Int) {
        mic.onLevel = { [weak self] lv in
            DispatchQueue.main.async {
                guard let self, self.phase == .recording else { return }
                self.levels.removeFirst()
                self.levels.append(lv)
            }
        }
        do { try mic.start() } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .recording
        progress = 0
        startedAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, gen == self.generation else { t.invalidate(); return }
            self.progress = min(1, Date().timeIntervalSince(self.startedAt) / self.level.seconds)
            if self.progress >= 1 { self.finish() }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        let samples = mic.stop()
        takes.append(samples)
        let gen = generation
        // Nächste kurze Aufnahme (ohne Countdown, kurze Pause zum Lesen)
        if takes.count < level.takeCount {
            takeIndex = takes.count
            phase = .countdown(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.beginRecording(gen)
            }
            return
        }
        phase = .processing
        let all = takes
        work = Task {
            do {
                let r = try await trainer.completeLevel(level.id, takes: all)
                await MainActor.run { guard gen == self.generation else { return }; self.result = r; self.phase = .done }
            } catch {
                await MainActor.run { guard gen == self.generation else { return }; self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Abbrechen – auch mitten in der Aufnahme. Nichts wird gespeichert.
    func cancel() {
        generation += 1
        work?.cancel(); work = nil
        timer?.invalidate(); timer = nil
        mic.stop()
        if phase != .done { phase = .ready }
        progress = 0
        takes = []
        takeIndex = 0
        levels = Array(repeating: 0, count: 48)
    }
}

/// „Andere Stimme einlernen“: die andere Person liest ~30 s vor → nur Fingerabdrücke werden gespeichert.
final class OtherVoiceSession: ObservableObject, Identifiable {
    enum Phase: Equatable { case ready, countdown(Int), recording, processing, done(String), failed(String), micDenied }

    let id = UUID()
    let trainer: VoiceTrainer
    @Published var name: String
    @Published var phase: Phase = .ready
    @Published var progress: Double = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 48)
    static let seconds: Double = 30
    static let text = "Hallo, ich bin nicht der Besitzer dieses Macs. Ich lese diesen Text vor, damit Flow meine Stimme kennt und sie beim Diktieren nicht mitschreibt. Heute ist ein ganz normaler Tag: Ich schreibe ein paar Nachrichten, plane die Woche und rufe danach noch kurz an. Manchmal rede ich schnell, manchmal langsam, manchmal leise – so, wie man eben redet. Wenn wir zusammen im Raum sind, soll nur die Stimme des Besitzers im Text landen."

    private let mic = TrainingMic()
    private var timer: Timer?
    private var generation = 0
    private var startedAt = Date()
    private var work: Task<Void, Never>?

    init(name: String, trainer: VoiceTrainer = .shared) {
        self.name = name
        self.trainer = trainer
    }

    var remaining: Int { max(0, Int((OtherVoiceSession.seconds * (1 - progress)).rounded(.up))) }
    var canFinishEarly: Bool { phase == .recording && progress >= 0.5 }

    func start() {
        generation += 1
        let gen = generation
        Task { @MainActor in
            guard await TrainingMic.permission() == .granted else { self.phase = .micDenied; return }
            for n in [3, 2, 1] {
                guard gen == self.generation else { return }
                self.phase = .countdown(n)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            guard gen == self.generation else { return }
            self.mic.onLevel = { [weak self] lv in
                DispatchQueue.main.async { guard let self, self.phase == .recording else { return }; self.levels.removeFirst(); self.levels.append(lv) }
            }
            do { try self.mic.start() } catch { self.phase = .failed(error.localizedDescription); return }
            self.phase = .recording
            self.progress = 0
            self.startedAt = Date()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
                guard let self, gen == self.generation else { t.invalidate(); return }
                self.progress = min(1, Date().timeIntervalSince(self.startedAt) / OtherVoiceSession.seconds)
                if self.progress >= 1 { self.finish() }
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        let samples = mic.stop()
        phase = .processing
        let gen = generation
        let n = name.trimmingCharacters(in: .whitespaces)
        work = Task {
            do {
                let v = try await trainer.addNegative(name: n, samples: samples)
                await MainActor.run { guard gen == self.generation else { return }; self.phase = .done(v.name) }
            } catch {
                await MainActor.run { guard gen == self.generation else { return }; self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        generation += 1
        work?.cancel(); work = nil
        timer?.invalidate(); timer = nil
        mic.stop()
        if case .done = phase { return }
        phase = .ready
        progress = 0
    }
}

/// Wort-Training: 6 kurze Aufnahmen – Standard: 6 Sätze mit dem Wort vorlesen, sonst nur das Wort.
/// Jede Aufnahme stoppt von selbst (Pause nach dem Satz/Wort), dann Auswertung.
final class WordSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case intro, listening, heardNothing, gotIt, processing(String), result, failed(String), micDenied
    }

    let id = UUID()
    let word: String
    let trainer: WordTrainer
    let total = WordTrainer.takesPerWord
    @Published var phase: Phase = .intro
    @Published var takeCount = 0
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 32)
    @Published var record: WordTrainer.Record?
    /// Im Satz trainieren (Standard) oder nur das Wort
    @Published var mode: WordTrainer.Mode = .sentences
    @Published var kind: NameKind
    @Published private(set) var sentences: [String] = []
    /// Flüster-Wörter: dasselbe Training geflüstert (eigenes Ergebnis)
    @Published var whisper = false {
        didSet { record = whisper ? trainer.whisperRecord(word) : trainer.record(word) }
    }

    /// Der Satz, der gerade vorgelesen werden soll (Satz-Modus)
    var currentSentence: String? {
        guard mode == .sentences, !sentences.isEmpty else { return nil }
        return sentences[min(takeCount, sentences.count - 1)]
    }

    private let mic = TrainingMic()
    private var takes: [[Float]] = []
    private var timer: Timer?
    private var generation = 0
    // Wort-Erkennung pro Aufnahme
    private var takeStart = Date()
    private var takeIndex = 0
    private var onset: Date?
    private var lastLoud = Date()
    private var floor: Float = 0.2
    private var floorN = 0
    private var misses = 0
    private var work: Task<Void, Never>?

    static let maxWait: TimeInterval = 4.0      // so lange auf den Wortanfang warten
    static let maxWord: TimeInterval = 2.5      // ab Wortanfang höchstens
    static let silenceEnd: TimeInterval = 0.45  // so viel Stille nach dem Wort = fertig
    // Satz: länger, und erst nach einer echten Pause fertig (Atempausen im Satz sind kürzer)
    static let maxSentence: TimeInterval = 8.0
    static let sentenceSilenceEnd: TimeInterval = 0.9

    private var maxLen: TimeInterval { mode == .sentences ? WordSession.maxSentence : WordSession.maxWord }
    private var silence: TimeInterval { mode == .sentences ? WordSession.sentenceSilenceEnd : WordSession.silenceEnd }

    init(word: String, trainer: WordTrainer = .shared) {
        self.word = word
        self.trainer = trainer
        record = trainer.record(word)
        kind = trainer.record(word)?.kind ?? NameKind.guess(word)
        sentences = trainer.sentences(for: word, kind: kind)
    }

    func setKind(_ k: NameKind) {
        kind = k
        sentences = trainer.sentences(for: word, kind: k)
    }

    func start() {
        generation += 1
        let gen = generation
        takes = []
        takeCount = 0
        misses = 0
        if mode == .sentences { sentences = trainer.sentences(for: word, kind: kind) }
        Task { @MainActor in
            guard await TrainingMic.permission() == .granted else { self.phase = .micDenied; return }
            guard gen == self.generation else { return }
            self.mic.onLevel = { [weak self] lv in DispatchQueue.main.async { self?.onLevel(lv) } }
            do { try self.mic.start() } catch { self.phase = .failed(error.localizedDescription); return }
            self.nextTake(gen)
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
                guard let self, gen == self.generation else { t.invalidate(); return }
                self.tick(gen)
            }
        }
    }

    private func nextTake(_ gen: Int) {
        guard gen == generation else { return }
        takeIndex = mic.buffer.count
        takeStart = Date()
        onset = nil
        floor = 0.2; floorN = 0
        phase = .listening
    }

    private func onLevel(_ lv: Float) {
        level = lv
        levels.removeFirst(); levels.append(lv)
        guard phase == .listening else { return }
        let dt = Date().timeIntervalSince(takeStart)
        // Grundrauschen in den ersten 0,3 s messen (Wort startet selten so früh)
        if onset == nil, dt < 0.3 { floor = (floor * Float(floorN) + lv) / Float(floorN + 1); floorN += 1; return }
        // Schwellen über dem Grundrauschen, aber gedeckelt (sonst: sofort losgesprochen → nie ein Wortanfang).
        // Geflüstert ist ~15–20 dB leiser → deutlich niedrigere Schwellen, sonst werden Flüster-Wörter abgeschnitten.
        let speechThr = whisper ? min(0.4, max(0.18, floor + 0.1)) : min(0.62, max(0.42, floor + 0.18))
        let silenceThr = whisper ? min(0.3, max(0.12, floor + 0.05)) : min(0.48, max(0.3, floor + 0.08))
        if lv > speechThr {
            if onset == nil { onset = Date() }
            lastLoud = Date()
        } else if onset != nil, lv > silenceThr {
            lastLoud = Date()
        }
    }

    private func tick(_ gen: Int) {
        guard phase == .listening else { return }
        let now = Date()
        if let on = onset {
            let long = now.timeIntervalSince(on) >= maxLen
            let quiet = now.timeIntervalSince(lastLoud) >= silence && now.timeIntervalSince(on) >= (mode == .sentences ? 0.8 : 0.25)
            if long || quiet { captureTake(gen) }
        } else if now.timeIntervalSince(takeStart) >= WordSession.maxWait + (mode == .sentences ? 2 : 0) {
            misses += 1
            if misses >= 3 {
                stopMic()
                phase = .failed("Ich höre nichts. Ist das richtige Mikrofon gewählt und nicht stummgeschaltet?")
                return
            }
            phase = .heardNothing
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                guard let self, gen == self.generation, self.phase == .heardNothing else { return }
                self.nextTake(gen)
            }
        }
    }

    private func captureTake(_ gen: Int) {
        let smp = mic.buffer.snapshot(from: takeIndex)
        guard SpeechMeter.speechSeconds(smp) >= (mode == .sentences ? 0.5 : 0.12) || (whisper && WhisperDetector.hasWhisperSpeech(smp)) else {   // nur ein Knacks → diese Aufnahme neu beginnen
            nextTake(gen)
            return
        }
        misses = 0
        takes.append(smp)
        takeCount = takes.count
        if takes.count >= total {
            stopMic()
            process(gen)
            return
        }
        phase = .gotIt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, gen == self.generation, self.phase == .gotIt else { return }
            self.nextTake(gen)
        }
    }

    private func process(_ gen: Int) {
        phase = .processing("Flow hört sich deine Aufnahmen an …")
        let t = takes
        let sents = mode == .sentences ? sentences : nil
        let k = kind
        work = Task {
            do {
                let r = try await trainer.train(word: word, takes: t, sentences: sents, kind: k, whisper: whisper) { [weak self] step in
                    guard let self, gen == self.generation else { return }
                    switch step {
                    case .listening: break
                    case .recognizing(let i, let n): self.phase = .processing("Hören wie bisher … \(i)/\(n)")
                    case .learning: self.phase = .processing("Deine Aussprache lernen …")
                    case .verifying(let i, let n): self.phase = .processing("Testen mit dem Gelernten … \(i)/\(n)")
                    }
                }
                PartnerVocab.shared.learned(r.word, kind: r.kind, source: .training)   // gemeinsame Namen: nur das Wort
                await MainActor.run { guard gen == self.generation else { return }; self.record = r; self.phase = .result }
            } catch {
                await MainActor.run { guard gen == self.generation else { return }; self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func stopMic() {
        timer?.invalidate(); timer = nil
        mic.stop()
    }

    /// Abbrechen, auch mitten in einer Aufnahme: Mikro aus, nichts wird gelernt.
    func cancel() {
        generation += 1
        work?.cancel(); work = nil
        stopMic()
        takes = []
        takeCount = 0
        if phase != .result { phase = .intro }
    }
}


/// „Testen“: einmal frei sprechen (ein Satz mit dem Wort) → was Flow jetzt schreibt, mit ✓ oder ✗.
final class WordTestSession: ObservableObject, Identifiable {
    enum Phase: Equatable { case ready, listening, processing, result(WordTrainer.TestResult), failed(String), micDenied }

    let id = UUID()
    let word: String
    let trainer: WordTrainer
    @Published var phase: Phase = .ready
    @Published var levels: [Float] = Array(repeating: 0, count: 32)

    private let mic = TrainingMic()
    private var timer: Timer?
    private var generation = 0
    private var started = Date()
    private var onset: Date?
    private var lastLoud = Date()
    private var floor: Float = 0.2
    private var floorN = 0
    private var work: Task<Void, Never>?

    init(word: String, trainer: WordTrainer = .shared) {
        self.word = word
        self.trainer = trainer
    }

    func start() {
        generation += 1
        let gen = generation
        Task { @MainActor in
            guard await TrainingMic.permission() == .granted else { self.phase = .micDenied; return }
            guard gen == self.generation else { return }
            self.mic.onLevel = { [weak self] lv in DispatchQueue.main.async { self?.onLevel(lv) } }
            do { try self.mic.start() } catch { self.phase = .failed(error.localizedDescription); return }
            self.started = Date(); self.onset = nil; self.floor = 0.2; self.floorN = 0
            self.phase = .listening
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
                guard let self, gen == self.generation else { t.invalidate(); return }
                self.tick()
            }
        }
    }

    private func onLevel(_ lv: Float) {
        levels.removeFirst(); levels.append(lv)
        guard phase == .listening else { return }
        if onset == nil, Date().timeIntervalSince(started) < 0.3 { floor = (floor * Float(floorN) + lv) / Float(floorN + 1); floorN += 1; return }
        let speechThr = min(0.62, max(0.42, floor + 0.18)), silenceThr = min(0.48, max(0.3, floor + 0.08))
        if lv > speechThr { if onset == nil { onset = Date() }; lastLoud = Date() }
        else if onset != nil, lv > silenceThr { lastLoud = Date() }
    }

    private func tick() {
        guard phase == .listening else { return }
        let now = Date()
        if let on = onset {
            if now.timeIntervalSince(on) >= 10 || (now.timeIntervalSince(lastLoud) >= 1.0 && now.timeIntervalSince(on) >= 0.4) { finish() }
        } else if now.timeIntervalSince(started) >= 6 {
            stopMic()
            phase = .failed("Ich höre nichts. Ist das richtige Mikrofon gewählt?")
        }
    }

    /// Früher fertig (Knopf)
    func finish() {
        guard phase == .listening else { return }
        let smp = mic.stop()
        timer?.invalidate(); timer = nil
        guard SpeechMeter.speechSeconds(smp) >= 0.2 else { phase = .failed("Zu kurz – sag einen Satz mit „\(word)“."); return }
        phase = .processing
        let gen = generation
        work = Task {
            let r = await trainer.test(word: word, samples: smp)
            await MainActor.run { guard gen == self.generation else { return }; self.phase = .result(r) }
        }
    }

    private func stopMic() { timer?.invalidate(); timer = nil; mic.stop() }

    func cancel() {
        generation += 1
        work?.cancel(); work = nil
        stopMic()
        if case .result = phase { return }
        phase = .ready
    }
}
