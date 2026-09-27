import Foundation

/// Optionen pro Anfrage an whisper-server (werden als Formularfelder mitgeschickt – kein zweiter Server nötig).
struct WhisperRequestOptions: Sendable {
    var language = "auto"
    var prompt: String? = nil
    /// Encoder-Fenster in Frames (50 Frames = 1 s). nil = volle 1500 (30 s).
    var audioCtx: Int? = nil
    var bestOf: Int? = nil
    var beamSize: Int? = nil
}

/// Wie groß muss das Encoder-Fenster für einen Clip sein?
/// Whisper rechnet sonst IMMER 30 s (1500 Frames) – ein 3-s-Diktat kostet dann so viel wie ein 30-s-Diktat.
/// Gemessen (Bench 26.09.2026): Fenster = Cliplänge + 1 s Luft, auf 64 Frames aufgerundet, mindestens 256 (≈5 s);
/// darunter halluziniert Whisper am Ende (wiederholt Wörter). Ab 20 s lohnt es kaum noch → volle Länge.
enum WhisperAudioContext {
    static var minFrames = 256
    static var padSeconds = 1.0
    static var maxClipSeconds = 20.0

    static func frames(forSamples n: Int) -> Int? {
        let sec = Double(n) / 16000
        guard sec <= maxClipSeconds else { return nil }
        let f = Int(((sec + padSeconds) * 50).rounded(.up))
        let r = max(minFrames, (f + 63) / 64 * 64)
        return r >= 1500 ? nil : r
    }
}

/// Kleiner whisper-server-Client für beliebige Adressen (Bench + zweiter Server).
struct WhisperClient: Sendable {
    let base: String   // z. B. http://127.0.0.1:PORT/pfad

    struct Output: Sendable { let text: String; let ms: Int }

    func transcribe(_ samples: [Float], _ o: WhisperRequestOptions) async throws -> Output {
        let t0 = Date()
        let boundary = "vf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("language", o.language)
        field("response_format", "json")
        field("temperature", "0")
        field("prompt", o.prompt ?? "")
        // Immer explizit schicken: whisper-server merkt sich Felder sonst u. U. von der vorigen Anfrage
        field("audio_ctx", "\(o.audioCtx ?? 0)")
        field("best_of", "\(o.bestOf ?? 1)")
        field("beam_size", "\(o.beamSize ?? -1)")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(WhisperEngine.wavData(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: base + "/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = max(15, Double(samples.count) / 16000 * 1.0)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.upload(for: req, from: body)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Flow", code: 8, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "?"])
        }
        let raw = ((j["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: "")
        let text = raw.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return Output(text: text, ms: Int(Date().timeIntervalSince(t0) * 1000))
    }

    /// Wie WhisperEngine.dictate: nur DE/EN, Wörterbuch-Hinweis, Halluzinationen verwerfen.
    /// language: "de"/"en" fest (spart den zweiten Encoder-Lauf der Spracherkennung, ~0,55 s) – nil = wie bisher automatisch.
    func dictate(_ samples: [Float], context: String = "", usePrompt: Bool = true, audioCtx: Int? = nil,
                 bestOf: Int? = nil, beamSize: Int? = nil, language: String? = nil, extraVocabulary: [String] = []) async throws -> Output {
        let t0 = Date()
        let vocab = extraVocabulary.isEmpty ? WhisperEngine.vocabularyPrompt() : EngineVocab.prompt(extra: extraVocabulary)
        let prompt = usePrompt ? vocab + (context.isEmpty ? "" : " " + String(context.suffix(160))) : ""
        let mode = Settings.frozen.languageMode
        var o = WhisperRequestOptions(language: mode == .both ? (language ?? "auto") : mode.rawValue, prompt: prompt, audioCtx: audioCtx, bestOf: bestOf, beamSize: beamSize)
        let audio = Transcriber.normalizedGentle(samples)
        var r = try await transcribe(audio, o)
        if mode == .both, language == nil, LanguageGuard.looksForeign(r.text) {
            o.language = LanguageGuard.guessDeEn(r.text)
            r = try await transcribe(audio, o)
        }
        var text = r.text
        let junk = ["untertitel", "vielen dank fürs zuschauen", "thanks for watching", "amara.org", "copyright", "untertitelung"]
        if junk.contains(where: { text.lowercased().contains($0) }) { text = "" }
        if !prompt.isEmpty, text.count > 8, prompt.lowercased().contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters)) { text = "" }
        return Output(text: text, ms: Int(Date().timeIntervalSince(t0) * 1000))
    }
}

/// Startet einen eigenen whisper-server (Bench / optionaler zweiter Server). Nie Port 8765, nie „/flow-“-Pfad
/// (den beendet Flow beim Start).
final class WhisperServerProcess {
    let port: Int
    let path = "/vfbench-" + UUID().uuidString.lowercased().prefix(8)
    private(set) var process: Process?
    var client: WhisperClient { WhisperClient(base: "http://127.0.0.1:\(port)\(path)") }
    var pid: Int32 { process?.processIdentifier ?? 0 }

    init?(model: String, threads: Int, extra: [String] = []) {
        guard let bin = WhisperEngine.serverBinary, var p = WhisperEngine.freePort() else { return nil }
        if p == 8765 { p = 8799 }
        port = p
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vfbench-leer")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: bin)
        pr.currentDirectoryURL = empty
        pr.arguments = ["-m", model, "--host", "127.0.0.1", "--port", "\(port)", "--request-path", path,
                        "--public", empty.path, "-l", "auto", "-t", "\(threads)", "-bo", "1"] + extra
        pr.standardOutput = FileHandle.nullDevice
        pr.standardError = FileHandle.nullDevice
        do { try pr.run() } catch { return nil }
        process = pr
    }

    /// Wartet, bis der Server antwortet (max. 40 s)
    func waitReady() async -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 40 {
            var req = URLRequest(url: URL(string: client.base + "/inference")!)
            req.httpMethod = "OPTIONS"; req.timeoutInterval = 0.5
            if let (_, resp) = try? await URLSession.shared.data(for: req), resp is HTTPURLResponse { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// CPU-Zeit des Server-Prozesses in Sekunden (user+sys)
    func cpuSeconds() -> Double {
        guard let p = process, p.isRunning else { return 0 }
        var info = proc_taskinfo()
        let n = proc_pidinfo(p.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        guard n > 0 else { return 0 }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ticks = Double(info.pti_total_user + info.pti_total_system)
        return ticks * Double(tb.numer) / Double(tb.denom) / 1e9
    }

    func stop() { process?.terminate(); process?.waitUntilExit(); process = nil }
    deinit { stop() }
}

/// Wie WhisperEngine.vocabularyPrompt, aber mit zusätzlichen Namen (Bench: „was bringt ein größeres Wörterbuch?“)
enum EngineVocab {
    static func prompt(extra: [String], dictionary: [DictEntry] = Settings.frozen.dictionary, myName: String = Settings.frozen.myName) -> String {
        var words: [String] = []
        for w in extra + dictionary.reversed().map({ $0.write.trimmingCharacters(in: .whitespaces) }) where !w.isEmpty && !words.contains(w) { words.append(w) }
        let name = myName.isEmpty ? Identity.systemFirstName : myName
        var list = Array(words.prefix(24))
        var sentence = ""
        while true {
            let joined = list.count > 1 ? list.dropLast().joined(separator: ", ") + " und " + list.last! : (list.first ?? "")
            sentence = "Ich bin \(name)." + (joined.isEmpty ? "" : " Heute geht es um \(joined).")
            if sentence.count <= 380 || list.isEmpty { break }
            list.removeLast()
        }
        return sentence
    }
}
