import FluidAudio
import Foundation

/// „Nur meine Stimme“: das eigene Stimmprofil (CAM++-Fingerabdruck, 192 Zahlen) und der Abgleich pro Tonstück.
/// So fliegen Stimmen aus Videos, Liedtexte und andere Leute im Raum aus dem Diktat.
actor VoiceID {
    static let shared = VoiceID()
    private var embedder: CampPlusEmbedder?

    static let profileURL = Paths.base.appendingPathComponent("meine-stimme.json")
    /// Ab dieser Ähnlichkeit gilt ein Stück als die eigene Stimme. Seit dem Stimmmodell (VoiceModel) ist das die feste
    /// Grenze einer kalibrierten Skala: die gemessene Schwelle steckt in `VoiceTrainer.score` (0,6 = Grenze, < 0,45 stumm).
    static let threshold: Float = 0.6

    private struct Profile: Codable { var embedding: [Float]; var seconds: Double; var date: Date }

    static var isEnrolled: Bool { FileManager.default.fileExists(atPath: profileURL.path) }

    private var loading: Task<CampPlusEmbedder, Error>?
    private func load() async throws -> CampPlusEmbedder {
        if let e = embedder { return e }
        if let l = loading { return try await l.value }
        let l = Task { try await CampPlusEmbedder.load() }
        loading = l
        let e = try await l.value
        embedder = e
        loading = nil
        return e
    }

    func prepare() async { _ = try? await load() }

    /// Fingerabdruck als Mittel über 3-s-Fenster (robuster als ein einziger über alles).
    func embedding(of samples: [Float]) async throws -> [Float] {
        let e = try await load()
        let win = 48_000, hop = 24_000
        var acc = [Float](repeating: 0, count: CampPlusEmbedder.embeddingDim)
        var n = 0
        var start = 0
        repeat {
            let end = min(start + win, samples.count)
            let chunk = Array(samples[start..<end])
            if chunk.count >= 16_000, EchoFilter.hasSound(chunk) {
                let v = try await e.embed(audio: chunk)
                for i in 0..<min(acc.count, v.count) { acc[i] += v[i] }
                n += 1
            }
            start += hop
        } while start + 16_000 <= samples.count
        guard n > 0 else { throw NSError(domain: "Flow", code: 5, userInfo: [NSLocalizedDescriptionKey: "Zu wenig Sprache"]) }
        let norm = sqrt(acc.reduce(0) { $0 + $1 * $1 })
        return acc.map { $0 / max(norm, 1e-6) }
    }

    func enroll(_ samples: [Float]) async throws {
        let emb = try await embedding(of: samples)
        let p = Profile(embedding: emb, seconds: Double(samples.count) / 16000, date: Date())
        try JSONEncoder().encode(p).write(to: VoiceID.profileURL, options: .atomic)
        log(String(format: "Stimmprofil gespeichert (%.0f s)", p.seconds))
    }

    static func profile() -> [Float]? {
        guard let d = try? Data(contentsOf: profileURL), let p = try? JSONDecoder().decode(Profile.self, from: d) else { return nil }
        return p.embedding
    }

    static func deleteProfile() { try? FileManager.default.removeItem(at: profileURL) }

    /// Ähnlichkeit pro Zeitpunkt: 1,5-s-Fenster alle 0,25 s. Liefert (Mitte in s, Ähnlichkeit).
    func similarityTrack(_ samples: [Float], profile: [Float]) async throws -> [(t: Double, sim: Float)] {
        let e = try await load()
        let win = 24_000, hop = 8_000
        var out: [(Double, Float)] = []
        if samples.count < win {
            let v = try await e.embed(audio: samples)
            return [(Double(samples.count) / 32000, VoiceTrainer.shared.score(v, whisper: WhisperDetector.isWhisper(samples)).effective)]
        }
        var start = 0
        while start + win <= samples.count {
            let chunk = Array(samples[start..<(start + win)])
            // Geflüsterte Fenster: Flüster-Profil (ohne Profil neutral) – und sie zählen als Ton, auch wenn sie leiser sind
            let whisper = WhisperDetector.isWhisper(chunk)
            if whisper || EchoFilter.hasSound(chunk) {
                let v = try await e.embed(audio: chunk)
                out.append((Double(start + win / 2) / 16000, VoiceTrainer.shared.score(v, whisper: whisper).effective))
            }
            start += hop
        }
        return out
    }

    enum Verdict { case keep(String, dropped: Int), notMe(bestSim: Float) }

    /// Behält nur Wörter, die nach dir klingen.
    func filterWords(_ words: [(word: String, start: Double, end: Double)], samples: [Float]) async -> Verdict {
        let all = words.map(\.word).joined(separator: " ")
        guard let prof = VoiceID.profile(), !words.isEmpty,
              let track = try? await similarityTrack(samples, profile: prof), !track.isEmpty else {
            return .keep(all, dropped: 0)
        }
        let best = track.map(\.sim).max() ?? 0
        // Schlechte Bedingungen (leises/fernes Mikro): Schwelle relativ zum besten Stück, aber nie unter 0,45
        let thr = VoiceID.threshold
        func sim(at t: Double) -> Float {
            let near = track.filter { abs($0.t - t) <= 0.25 }.map(\.sim)
            if !near.isEmpty { return near.reduce(0, +) / Float(near.count) }
            return track.min { abs($0.t - t) < abs($1.t - t) }!.sim
        }
        var kept: [String] = []
        var dropped = 0
        for w in words {
            if sim(at: (w.start + w.end) / 2) >= thr { kept.append(w.word) } else { dropped += 1 }
        }
        log(String(format: "Stimmabgleich: bestes %.2f, Schwelle %.2f → %d behalten, %d verworfen", best, thr, kept.count, dropped))
        if best < thr || kept.isEmpty { return .notMe(bestSim: best) }
        // Anpassung an Mikro/Raum macht jetzt VoiceAdapter (mit Drift-Schutz + Zurücknehmen) über FastVoiceMask
        return .keep(kept.joined(separator: " "), dropped: dropped)
    }

    enum MaskResult { case unchanged, masked([Float], mutedSeconds: Double), notMe(bestSim: Float) }

    /// Schaltet in der Aufnahme alles stumm, was klar NICHT nach dir klingt – vor der Erkennung.
    /// Vorsichtig: nur unter 0,45 wird gestummt (eigene Wörter sollen nie verloren gehen).
    func mask(_ samples: [Float], clipThreshold: Float = VoiceID.threshold) async -> MaskResult {
        guard let prof = VoiceID.profile(), let track = try? await similarityTrack(samples, profile: prof), !track.isEmpty else {
            return .unchanged
        }
        let best = track.map(\.sim).max() ?? 0
        if best < clipThreshold {
            log(String(format: "Stimmabgleich: bestes %.2f → klingt nicht nach dir", best))
            return .notMe(bestSim: best)
        }
        let muteBelow: Float = 0.45
        // Zeitraster 50 ms: pro Rasterpunkt Ähnlichkeit des nächstgelegenen Fensters (±0,3 s gemittelt)
        let step = 800
        let n = samples.count / step + 1
        var mute = [Bool](repeating: false, count: n)
        for k in 0..<n {
            let t = Double(k * step) / 16000
            let near = track.filter { abs($0.t - t) <= 0.3 }.map(\.sim)
            let sim = near.isEmpty ? (track.min { abs($0.t - t) < abs($1.t - t) }!.sim) : near.reduce(0, +) / Float(near.count)
            mute[k] = sim < muteBelow
        }
        // Nur längere Stumm-Stücke (≥0,6 s) – kurze Einbrüche sind meist du selbst (Pausen, Atmer)
        var runs: [(Int, Int)] = []
        var k = 0
        while k < n {
            if mute[k] { let a = k; while k < n && mute[k] { k += 1 }; if (k - a) * step >= 9600 { runs.append((a, k)) } } else { k += 1 }
        }
        guard !runs.isEmpty else {
            log(String(format: "Stimmabgleich: bestes %.2f, alles eigene Stimme", best))
            return .unchanged
        }
        var out = samples
        var muted = 0
        for (a, b) in runs {
            for j in (a * step)..<min(b * step, out.count) { out[j] = 0 }
            muted += (b - a) * step
        }
        log(String(format: "Stimmabgleich: bestes %.2f, %.1f s fremde Stimme stummgeschaltet", best, Double(muted) / 16000))
        return .masked(out, mutedSeconds: Double(muted) / 16000)
    }
}
