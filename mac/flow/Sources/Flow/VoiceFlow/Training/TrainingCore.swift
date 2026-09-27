import AppKit
import AVFoundation
import FluidAudio
import Foundation

// MARK: - Training: gemeinsame Bausteine (Speichern, Vektoren, Mikrofon, Sprachausgabe)

enum TrainingError: LocalizedError {
    case micDenied, micFailed(String), tooLittleSpeech(Double), notYou(Float), noTakes, cancelled, whisperMissing
    case notWhisper(Float), negativeVoice(String), soundsLikeYou(Float), badVoiceprint

    var errorDescription: String? {
        switch self {
        case .micDenied: return "Flow darf das Mikrofon nicht benutzen."
        case .micFailed(let m): return "Mikrofon startet nicht (\(m))."
        case .tooLittleSpeech(let s): return String(format: "Zu wenig Sprache gehört (%.0f s). Lies den Text bitte ganz vor.", s)
        case .notYou(let sim): return String(format: "Das klingt nicht nach deiner bisherigen Stimme (Ähnlichkeit %.2f). Nimm das Level bitte selbst auf.", sim)
        case .noTakes: return "Zu wenige brauchbare Aufnahmen."
        case .cancelled: return "Abgebrochen."
        case .whisperMissing: return "Whisper ist nicht bereit."
        case .notWhisper(let v): return String(format: "Das klang nicht geflüstert (%.0f %% mit Stimme). Bitte ganz ohne Stimme flüstern – nur mit Luft, wie in der Bibliothek.", v * 100)
        case .negativeVoice(let n): return "Das klingt nach \(n) (als andere Stimme eingelernt). Nimm das Level bitte selbst auf."
        case .soundsLikeYou(let sim): return String(format: "Das klingt nach dir selbst (Ähnlichkeit %.2f). Die andere Person soll selbst sprechen – bzw. importiere ihren Stimmabdruck, nicht deinen.", sim)
        case .badVoiceprint: return "Das ist kein gültiger Flow-Stimmabdruck."
        }
    }
}

/// Protokoll fürs Training. In CLI-Tests stumm (sonst landen Testzeilen in das echte flow.log
/// und würden z. B. als „sichere Diktate“ mitgezählt).
enum TLog {
    nonisolated(unsafe) static var quiet = false
    nonisolated(unsafe) static var echo = false
}

func tlog(_ s: String) {
    if TLog.echo { print("  [log] " + s) }
    if !TLog.quiet { log(s) }
}

enum TrainingFiles {
    /// JSON atomar schreiben, nur für den Nutzer lesbar (0600)
    static func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try d.write(to: url, options: .atomic) } catch { tlog("Training: \(url.lastPathComponent) nicht speicherbar: \(error)") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }

    /// Ordner nur für den Nutzer (0700)
    static func secureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func writeWav(_ samples: [Float], to url: URL) {
        try? WhisperEngine.wavData(samples).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Vec {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }
    static func norm(_ a: [Float]) -> [Float] {
        let n = sqrt(a.reduce(0) { $0 + $1 * $1 })
        return a.map { $0 / max(n, 1e-6) }
    }
    static func cos(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let na = sqrt(dot(a, a)), nb = sqrt(dot(b, b))
        return dot(a, b) / max(na * nb, 1e-6)
    }
    /// Normalisierter Mittelwert
    static func mean(_ vs: [[Float]]) -> [Float]? {
        guard let f = vs.first else { return nil }
        var acc = [Float](repeating: 0, count: f.count)
        for v in vs where v.count == f.count { for i in 0..<f.count { acc[i] += v[i] } }
        return norm(acc)
    }
}

/// Sprach-Anteil einer Aufnahme (30-ms-Rahmen über einer leisen Schwelle)
enum SpeechMeter {
    static func frameRMS(_ s: [Float], frame: Int = 480) -> [Float] {
        guard s.count >= frame else { return [] }
        return stride(from: 0, to: s.count - frame + 1, by: frame).map { a in
            var sum: Float = 0
            for j in a..<(a + frame) { sum += s[j] * s[j] }
            return sqrt(sum / Float(frame))
        }
    }

    /// Sekunden mit Sprache. Schwelle relativ zur lautesten Stelle (leise/entfernte Aufnahmen zählen auch).
    static func speechSeconds(_ s: [Float]) -> Double {
        let r = frameRMS(s)
        guard let peak = r.max(), peak > 0.0015 else { return 0 }
        let thr = max(0.0012, peak * 0.12)
        return Double(r.filter { $0 > thr }.count * 480) / 16000
    }

    /// Schneidet Stille vorn/hinten weg (mit etwas Luft), für kurze Wort-Aufnahmen.
    static func trim(_ s: [Float], padBefore: Double = 0.2, padAfter: Double = 0.3) -> [Float] {
        let r = frameRMS(s)
        guard let peak = r.max(), peak > 0.002 else { return s }
        let thr = max(0.0015, peak * 0.1)
        guard let first = r.firstIndex(where: { $0 > thr }), let last = r.lastIndex(where: { $0 > thr }) else { return s }
        let a = max(0, first * 480 - Int(padBefore * 16000))
        let b = min(s.count, (last + 1) * 480 + Int(padAfter * 16000))
        return a < b ? Array(s[a..<b]) : s
    }
}

/// Eigener CAM++-Einbetter für kurze Fenster (VoiceID mittelt immer über 3-s-Stücke).
actor TrainingEmbedder {
    static let shared = TrainingEmbedder()
    private var embedder: CampPlusEmbedder?

    private func load() async throws -> CampPlusEmbedder {
        if let e = embedder { return e }
        let e = try await CampPlusEmbedder.load()
        embedder = e
        return e
    }

    /// Ein Fingerabdruck pro Fenster (Standard 2,5 s, Schritt 2 s), nur Fenster mit Sprache. Höchstens `limit`, gleichmäßig verteilt.
    func windows(_ samples: [Float], win: Int = 40_000, hop: Int = 32_000, limit: Int = 8) async throws -> [[Float]] {
        let e = try await load()
        var starts: [Int] = []
        var st = 0
        while st + win <= samples.count { starts.append(st); st += hop }
        if starts.isEmpty, samples.count >= 16_000 { starts = [0] }
        var out: [[Float]] = []
        for a in starts {
            let chunk = Array(samples[a..<min(a + win, samples.count)])
            guard SpeechMeter.speechSeconds(chunk) >= 0.8 else { continue }
            out.append(Vec.norm(try await e.embed(audio: chunk)))
        }
        if out.count > limit {
            let step = Double(out.count) / Double(limit)
            out = (0..<limit).map { out[Int(Double($0) * step)] }
        }
        return out
    }
}

/// Mikrofon für Trainings-Aufnahmen: Rechte prüfen, Samples sammeln, Pegel melden.
final class TrainingMic {
    private let mic = MicCapture()
    let buffer = SampleBuffer()
    var onLevel: ((Float) -> Void)?
    private(set) var running = false

    enum Permission { case granted, denied }

    static func permission() async -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        default: return .denied
        }
    }

    static func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
    }

    func start() throws {
        buffer.reset()
        mic.onSamples = { [weak self] s in self?.buffer.append(s) }
        mic.onLevel = { [weak self] lv in self?.onLevel?(lv) }
        do { try mic.start(deviceUID: Settings.shared.micUID) } catch {
            // Gewähltes Mikro weg? Mit dem Standard-Mikro nochmal versuchen.
            do { try mic.start(deviceUID: nil) } catch { throw TrainingError.micFailed(error.localizedDescription) }
        }
        running = true
    }

    @discardableResult
    func stop() -> [Float] {
        if running { mic.stop() }
        running = false
        mic.onSamples = nil
        mic.onLevel = nil
        return buffer.take()
    }
}

/// macOS-Sprachausgabe (`say`) → 16-kHz-Samples. Für die Vergleichsstimmen und die Selbsttests.
enum TTS {
    static func installedVoices() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let txt = String(data: data, encoding: .utf8) ?? ""
        var out = Set<String>()
        for line in txt.split(separator: "\n") {
            // „Name (Sprache (Land))   de_DE    # …“ → Name bis vor dem Locale-Feld
            guard let r = line.range(of: "\\s+[a-z]{2,3}_[A-Z0-9]{2,3}\\s+#", options: .regularExpression) else { continue }
            out.insert(String(line[line.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    static func synth(_ text: String, voice: String, rate: Int? = nil) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vf-tts-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000"]
        if let rate { args += ["-r", "\(rate)"] }
        p.arguments = args + [text]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "VoiceFlow", code: 40, userInfo: [NSLocalizedDescriptionKey: "say \(voice) fehlgeschlagen"]) }
        return try AudioConverter().resampleAudioFile(url)
    }
}

/// Text-Helfer fürs Wort-Training
enum TrainingText {
    /// Satzzeichen weg, Leerraum vereinheitlicht („Lidl.“ → „Lidl“)
    static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^)]*\\)", with: " ", options: .regularExpression)
        t = t.components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-'’&+ ")).inverted).joined(separator: " ")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-'’")))
    }

    static func key(_ s: String) -> String {
        normalize(s).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Enthält der erkannte Text das Zielwort (als ganzes Wort, Groß/klein egal)?
    static func contains(_ text: String, target: String) -> Bool {
        let t = normalize(text), w = normalize(target)
        guard !w.isEmpty else { return false }
        let pat = "(?<![\\p{L}\\d])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\d])"
        return t.range(of: pat, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Kurze Allerweltswörter, die nie als Hörvariante gelernt werden (würden sonst jedes Diktat verbiegen)
    static let functionWords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "und", "oder", "aber", "ich", "du", "er", "sie", "es",
        "wir", "ihr", "ja", "nein", "nee", "doch", "so", "na", "also", "mal", "hier", "da", "wo", "wie", "was", "wer", "ist",
        "bin", "hat", "hab", "habe", "in", "im", "an", "am", "auf", "zu", "zum", "zur", "mit", "von", "vom", "für", "bei",
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "at", "it", "is", "i", "you", "he", "she", "we", "they",
        "yes", "no", "so", "ok", "okay", "oh", "ah", "äh", "ähm", "hm", "hmm", "mhm", "uh", "um", "danke", "thanks", "thank you",
        "hallo", "hello", "hi", "bye", "tschüss",
    ]

    /// Typische Whisper-Halluzinationen bei (fast) Stille
    static func isJunk(_ s: String) -> Bool {
        let l = s.lowercased()
        let junk = ["untertitel", "zuschauen", "thanks for watching", "amara.org", "copyright", "untertitelung", "abonnieren", "subscribe"]
        return junk.contains { l.contains($0) }
    }

    static func isRealWord(_ w: String) -> Bool {
        let checker = NSSpellChecker.shared
        for lang in ["de", "en"] {
            let r = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound { return true }
        }
        return false
    }

    static func slug(_ w: String) -> String {
        let f = w.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let s = f.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return s.isEmpty ? "wort" : String(s.prefix(40))
    }
}
