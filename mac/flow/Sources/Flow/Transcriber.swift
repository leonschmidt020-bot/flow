import FluidAudio
import Foundation

/// Lokale Spracherkennung (Parakeet über FluidAudio, läuft auf der Neural Engine).
/// Ein einziger Actor, damit Diktat und Meeting sich das geladene Modell teilen.
actor Transcriber {
    static let shared = Transcriber()

    enum State: Equatable { case notLoaded, loading(Double), ready, failed(String) }

    private var asr: AsrManager?
    private var decoderLayers = 2
    private(set) var state: State = .notLoaded
    private var loadTask: Task<Void, Error>?

    /// Wird bei Zustandsänderungen auf dem Main-Thread aufgerufen (für Pille/Menü).
    nonisolated(unsafe) var onState: ((State) -> Void)?

    private func setState(_ s: State) {
        state = s
        let cb = onState
        DispatchQueue.main.async { cb?(s) }
    }

    func load() async throws {
        if asr != nil { return }
        if let t = loadTask { return try await t.value }
        let t = Task {
            setState(.loading(0))
            let t0 = Date()
            do {
                let models = try await AsrModels.downloadAndLoad(version: .ultra, progressHandler: { [weak self] p in
                    guard let self else { return }
                    Task { await self.setState(.loading(p.fractionCompleted)) }
                })
                let m = AsrManager()
                try await m.loadModels(models)
                self.decoderLayers = models.version.decoderLayers
                self.asr = m
                // Aufwärmen, damit das erste echte Diktat nicht auf Core-ML-Kompilierung wartet.
                var st = TdtDecoderState.make(decoderLayers: self.decoderLayers)
                _ = try? await m.transcribe([Float](repeating: 0, count: 16000), decoderState: &st)
                log(String(format: "Parakeet Ultra geladen in %.1fs", Date().timeIntervalSince(t0)))
                setState(.ready)
            } catch {
                log("Modell-Laden fehlgeschlagen: \(error)")
                setState(.failed(error.localizedDescription))
                throw error
            }
        }
        loadTask = t
        defer { loadTask = nil }
        try await t.value
    }

    struct Result {
        let text: String
        /// Wörter mit Zeitstempel (Sekunden relativ zum Anfang der übergebenen Samples).
        let words: [(word: String, start: Double, end: Double)]
    }

    /// Transkribiert 16 kHz mono Samples. Kurze Aufnahmen werden mit Stille auf ≥1 s aufgefüllt.
    func transcribe(_ samples: [Float], normalize: Bool = true) async throws -> Result {
        try await load()
        guard let asr else { throw NSError(domain: "Flow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Modell nicht geladen"]) }
        var s = normalize ? Transcriber.normalized(samples) : samples
        if s.count < 16000 { s.append(contentsOf: [Float](repeating: 0, count: 16000 - s.count + 1600)) }
        var st = TdtDecoderState.make(decoderLayers: decoderLayers)
        let r = try await asr.transcribe(s, decoderState: &st)
        return Result(text: r.text.trimmingCharacters(in: .whitespacesAndNewlines), words: Transcriber.words(from: r.tokenTimings ?? []))
    }

    /// Wie transcribe, aber mit Token-Sicherheiten (für HybridRecognizer).
    func transcribeScored(_ samples: [Float]) async throws -> ScoredText {
        try await load()
        guard let asr else { throw NSError(domain: "Flow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Modell nicht geladen"]) }
        var s = Transcriber.normalized(samples)
        if s.count < 16000 { s.append(contentsOf: [Float](repeating: 0, count: 16000 - s.count + 1600)) }
        var st = TdtDecoderState.make(decoderLayers: decoderLayers)
        let r = try await asr.transcribe(s, decoderState: &st)
        return ScoredText.from(text: r.text, timings: r.tokenTimings ?? [])
    }

    /// Leise Aufnahmen (Mikro weit weg) anheben: Spitze auf ~0,7, höchstens 24-fach.
    /// Parakeet liefert bei sehr leisem Ton sonst gern gar nichts.
    /// Sanfte Anhebung für Whisper (höchstens 4×) – starke Verstärkung schadet Whisper eher.
    static func normalizedGentle(_ s: [Float]) -> [Float] {
        guard s.count > 100 else { return s }
        var probe = stride(from: 0, to: s.count, by: 4).map { abs(s[$0]) }
        probe.sort()
        let peak = probe[min(probe.count - 1, Int(Double(probe.count) * 0.999))]
        guard peak > 1e-4 else { return s }
        let gain = min(0.6 / peak, 4)
        if gain <= 1.05 { return s }
        return s.map { max(-1, min(1, $0 * gain)) }
    }

    static func normalized(_ s: [Float]) -> [Float] {
        guard s.count > 100 else { return s }
        // 99,9-%-Spitze (aus jedem 4. Sample), damit einzelne Knackser die Verstärkung nicht bestimmen
        var probe = stride(from: 0, to: s.count, by: 4).map { abs(s[$0]) }
        probe.sort()
        let peak = probe[min(probe.count - 1, Int(Double(probe.count) * 0.999))]
        guard peak > 1e-4 else { return s }
        let gain = min(0.7 / peak, 24)
        if gain <= 1.05 { return s }
        return s.map { max(-1, min(1, $0 * gain)) }
    }

    /// SentencePiece-Tokens („▁Wort“) zu Wörtern mit Zeiten zusammensetzen.
    static func words(from tokens: [TokenTiming]) -> [(word: String, start: Double, end: Double)] {
        var out: [(String, Double, Double)] = []
        for t in tokens {
            let raw = t.token
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ") || out.isEmpty
            let piece = raw.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            if startsWord {
                out.append((piece, t.startTime, t.endTime))
            } else if var last = out.popLast() {
                last.0 += piece; last.2 = t.endTime
                out.append(last)
            }
        }
        return out.map { (word: $0.0, start: $0.1, end: $0.2) }
    }
}

/// Sprechertrennung nach dem Meeting (pyannote community-1 + VBx, lokal).
actor Diarizer {
    static let shared = Diarizer()
    private var manager: OfflineDiarizerManager?

    private var preparing: Task<OfflineDiarizerManager, Error>?
    private var busy = 0
    private var lastUse = Date()

    /// pyannote + VBx werden nur für die Meeting-Auswertung gebraucht → nach Leerlauf wieder freigeben.
    func releaseIfIdle(after seconds: TimeInterval) {
        guard manager != nil, preparing == nil, busy == 0, Date().timeIntervalSince(lastUse) >= seconds else { return }
        manager = nil
        log("Sprechertrennung freigegeben (Speicher sparen)")
    }

    func prepare() async throws {
        lastUse = Date()
        if manager != nil { return }
        if let p = preparing { manager = try await p.value; return }
        let p = Task { () throws -> OfflineDiarizerManager in
            let m = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await m.prepareModels()
            return m
        }
        preparing = p
        manager = try await p.value
        preparing = nil
    }

    struct Turn { let speaker: String; let start: Double; let end: Double }

    /// Liefert Sprecher-Abschnitte und pro Sprecher ein Stimm-Embedding (256-d).
    func diarize(_ samples: [Float], progress: (@Sendable (Double) -> Void)? = nil) async throws -> (turns: [Turn], embeddings: [String: [Float]]) {
        busy += 1; lastUse = Date()
        defer { busy -= 1; lastUse = Date() }
        try await prepare()
        guard let manager else { return ([], [:]) }
        let r = try await manager.process(audio: samples) { done, total in
            progress?(total > 0 ? Double(done) / Double(total) : 0)
        }
        let turns = r.segments.map { Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        var emb = r.speakerDatabase ?? [:]
        if emb.isEmpty {
            // Fallback: Segment-Embeddings pro Sprecher mitteln.
            var acc: [String: ([Float], Int)] = [:]
            for s in r.segments where !s.embedding.isEmpty {
                var e = acc[s.speakerId] ?? ([Float](repeating: 0, count: s.embedding.count), 0)
                for i in 0..<min(e.0.count, s.embedding.count) { e.0[i] += s.embedding[i] }
                e.1 += 1
                acc[s.speakerId] = e
            }
            emb = acc.mapValues { v in v.0.map { $0 / Float(max(v.1, 1)) } }
        }
        return (turns, emb)
    }
}
