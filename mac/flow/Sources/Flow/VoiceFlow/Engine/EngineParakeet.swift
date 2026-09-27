import FluidAudio
import Foundation

/// Parakeet-Ergebnis MIT Sicherheit pro Token (Softmax-Wahrscheinlichkeit aus dem TDT-Decoder).
/// Grundlage für den HybridRecognizer: sichere Parakeet-Ergebnisse werden direkt genommen.
struct ScoredText: Sendable {
    let text: String
    /// Eine Zahl pro SentencePiece-Token, 0…1
    let tokenConfidences: [Float]
    /// Wörter mit Sicherheit = kleinste Token-Sicherheit im Wort
    let words: [(word: String, conf: Float)]
    /// Zeiten pro Wort (Sekunden ab Anfang der Samples), gleiche Reihenfolge wie `words` – für den Namen-Prüfer
    var times: [(start: Double, end: Double)] = []

    var meanConfidence: Float { tokenConfidences.isEmpty ? 0 : tokenConfidences.reduce(0, +) / Float(tokenConfidences.count) }
    var minConfidence: Float { tokenConfidences.min() ?? 0 }
    /// Kleinste Wort-Sicherheit (robuster als min über Tokens: Wortanfänge zählen wie ganze Wörter)
    var minWordConfidence: Float { words.map(\.conf).min() ?? 0 }
    /// Anteil unsicherer Wörter (< 0,5)
    var shakyWordShare: Float { words.isEmpty ? 1 : Float(words.filter { $0.conf < 0.5 }.count) / Float(words.count) }

    static func from(text: String, timings: [TokenTiming]) -> ScoredText {
        var words: [(String, Float)] = []
        var times: [(Double, Double)] = []
        for t in timings {
            let raw = t.token
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ") || words.isEmpty
            let piece = raw.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            if startsWord { words.append((piece, t.confidence)); times.append((t.startTime, t.endTime)) }
            else if var last = words.popLast() {
                last.0 += piece; last.1 = min(last.1, t.confidence); words.append(last)
                if var lt = times.popLast() { lt.1 = t.endTime; times.append(lt) }
            }
        }
        return ScoredText(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          tokenConfidences: timings.map(\.confidence),
                          words: words.map { (word: $0.0, conf: $0.1) },
                          times: times.map { (start: $0.0, end: $0.1) })
    }
}

/// Eigener Parakeet-Halter mit Sicherheitswerten – NUR für Benchmark/Tests.
/// Im laufenden Programm soll `Transcriber.shared` die Sicherheitswerte liefern (siehe Bericht: 3-Zeilen-Änderung),
/// sonst läge das Modell (≈600 MB) zweimal im Speicher.
actor EngineParakeet {
    static let shared = EngineParakeet()
    private var asr: AsrManager?
    private var layers = 2

    func load() async throws {
        if asr != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        let m = AsrManager()
        try await m.loadModels(models)
        layers = models.version.decoderLayers
        var st = TdtDecoderState.make(decoderLayers: layers)
        _ = try? await m.transcribe([Float](repeating: 0, count: 16000), decoderState: &st)
        asr = m
    }

    func transcribe(_ samples: [Float]) async throws -> ScoredText {
        try await load()
        guard let asr else { throw NSError(domain: "Flow", code: 2) }
        var s = Transcriber.normalized(samples)
        if s.count < 16000 { s.append(contentsOf: [Float](repeating: 0, count: 16000 - s.count + 1600)) }
        var st = TdtDecoderState.make(decoderLayers: layers)
        let r = try await asr.transcribe(s, decoderState: &st)
        return ScoredText.from(text: r.text, timings: r.tokenTimings ?? [])
    }
}
