import Foundation

/// Whisper large-v3-turbo als dauerhaft laufender lokaler Server (whisper.cpp, Metal).
/// Genauer als Parakeet bei der eigenen Stimme, kann Sprache fest auf DE/EN setzen,
/// bekommt das Wörterbuch als Hinweis (Namen, Marken, Flow …) und schreibt „ähm“ als „ähm“.
/// ~0,6 s pro Diktat, weil das Modell im Speicher bleibt.
final class WhisperEngine {
    static let shared = WhisperEngine()
    /// Zufälliger freier Port + geheimer Pfad pro Start → keine Webseite/kein fremder Prozess kann ihn nutzen.
    private(set) var port = 8765
    private let secretPath = "/flow-" + UUID().uuidString.lowercased()
    private var base: String { "http://127.0.0.1:\(port)\(secretPath)" }
    private var process: Process?
    private let queue = DispatchQueue(label: "flow.whisper")
    /// Server läuft und antwortet.
    private(set) var serverUp = false
    /// Absichtlich angehalten, um Arbeitsspeicher zu sparen („Speicher sparen“). Startet beim nächsten Fn-Druck
    /// bzw. bei der nächsten Anfrage von selbst wieder (gemessen ~0,25–0,45 s, auch wenn das Modell nicht mehr im Datei-Cache liegt).
    private(set) var parked = false
    /// Nutzbar: läuft – oder ist geparkt und startet bei Bedarf. So bleibt der Hybrid-Weg (Parakeet + Whisper) aktiv.
    var ready: Bool { serverUp || parked }
    var serverPID: Int32? { process?.processIdentifier }
    /// Letzte Nutzung (Anfrage oder Fn-Druck) – für das Parken nach Leerlauf.
    private(set) var lastUse = Date()
    private let useLock = NSLock()
    private var inFlight = 0

    static var available: Bool { WhisperFallback.cli != nil && WhisperFallback.model != nil && serverBinary != nil }
    static let serverBinary: String? = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Server starten (oder einen schon laufenden weiterverwenden).
    func start() {
        queue.async { [self] in
            guard process == nil else { return }
            // Nur den EIGENEN alten Server (z. B. nach Absturz) beenden – über die PID-Datei.
            // Früher: pkill auf alle Flow-Server → ein Testlauf oder eine zweite Instanz hat dem laufenden
            // Flow den Server weggeschossen (Neustart-Schleife, Diktat ohne Whisper).
            WhisperEngine.killPrevious()
            guard let bin = WhisperEngine.serverBinary, let model = WhisperFallback.model else { return }
            port = WhisperEngine.freePort() ?? 8765
            let empty = Paths.base.appendingPathComponent("leer")
            try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.currentDirectoryURL = empty
            p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", "\(port)", "--request-path", secretPath,
                           "--public", empty.path, "-l", "auto", "-t", "6", "-bo", "1"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Freigegebene große malloc-Blöcke nicht im Prozess horten (gemessen: Server 788 → 712 MB, Tempo gleich)
            var env = ProcessInfo.processInfo.environment
            env["MallocLargeCache"] = "0"
            p.environment = env
            p.terminationHandler = { [weak self] pr in
                guard let self else { return }
                self.queue.async {
                    // Ein geparkter/ersetzter Server darf den neuen Zustand nicht überschreiben
                    guard self.process === pr else { return }
                    log("Whisper-Server beendet (\(pr.terminationStatus))")
                    self.serverUp = false
                    self.process = nil
                    // Abgestürzt, obwohl Flow läuft → neu starten, aber höchstens 5× hintereinander (dann Parakeet)
                    guard !self.stopping, !self.parked, self.restarts < 5 else { return }
                    self.restarts += 1
                    self.queue.asyncAfter(deadline: .now() + Double(self.restarts) * 2) { self.start() }
                }
            }
            do { try p.run() } catch { log("Whisper-Server startet nicht: \(error)"); parked = false; return }
            process = p
            try? "\(p.processIdentifier)".write(to: WhisperEngine.pidURL, atomically: true, encoding: .utf8)
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 30 {
                if ping() {
                    serverUp = true; restarts = 0
                    log(String(format: parked ? "Whisper-Server wieder da nach %.2fs (war geparkt)" : "Whisper-Server bereit nach %.1fs", Date().timeIntervalSince(t0)))
                    parked = false
                    return
                }
                // Feines Raster: beim Aufwecken aus dem Parken zählt jede Zehntelsekunde
                Thread.sleep(forTimeInterval: parked ? 0.03 : 0.25)
            }
            log("Whisper-Server antwortet nicht")
            parked = false
        }
    }

    /// App und Testläufe haben getrennte PID-Dateien, damit sie sich nie gegenseitig beenden.
    static var pidURL: URL {
        Paths.base.appendingPathComponent(Bundle.main.bundlePath.hasSuffix(".app") ? "whisper.pid" : "whisper-test.pid")
    }

    static func killPrevious() {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return }
        // Nur beenden, wenn es wirklich (noch) ein whisper-server ist – PIDs werden wiederverwendet
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return }
        let path = String(cString: buf)
        if path.hasSuffix("/whisper-server") { kill(pid, SIGTERM); usleep(200_000) }
    }

    private var stopping = false
    private var restarts = 0
    func stop() { stopping = true; process?.terminate(); process = nil; serverUp = false; parked = false }

    // MARK: Speicher sparen (Parken bei Leerlauf)

    /// Fn gedrückt / Diktat beginnt: Nutzung merken und einen geparkten Server sofort starten –
    /// der Start (~0,3 s) läuft parallel zum Sprechen.
    func noteActivity() {
        useLock.lock(); lastUse = Date(); useLock.unlock()
        queue.async { [self] in if parked, process == nil, !stopping { start() } }
    }

    /// Server anhalten, um ~0,7 GB freizugeben. Nie während einer Anfrage.
    func park(reason: String) {
        queue.async { [self] in
            guard let p = process, serverUp, !stopping else { return }
            useLock.lock(); let busy = inFlight > 0; useLock.unlock()
            guard !busy else { return }
            parked = true
            serverUp = false
            process = nil
            p.terminate()
            try? FileManager.default.removeItem(at: WhisperEngine.pidURL)   // sonst wartet killPrevious() beim Aufwecken 0,2 s
            log("Whisper-Server geparkt (\(reason)) – startet beim nächsten Fn-Druck")
        }
    }

    /// Parken, wenn seit `seconds` nichts mehr lief.
    func parkIfIdle(after seconds: TimeInterval) {
        useLock.lock(); let idle = Date().timeIntervalSince(lastUse); let busy = inFlight > 0; useLock.unlock()
        if !busy, idle >= seconds, serverUp { park(reason: String(format: "%.0f min ohne Diktat", idle / 60)) }
    }

    /// Wartet, bis ein geparkter Server wieder antwortet (höchstens `timeout`).
    func ensureUp(timeout: TimeInterval = 4) async -> Bool {
        if serverUp { return true }
        guard parked else { return false }
        queue.async { [self] in if process == nil, !stopping { start() } }
        let t0 = Date()
        while !serverUp, parked || process != nil, Date().timeIntervalSince(t0) < timeout {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return serverUp
    }

    private func ping() -> Bool {
        var req = URLRequest(url: URL(string: base + "/inference")!)
        req.httpMethod = "OPTIONS"
        req.timeoutInterval = 0.5
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse) != nil
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 0.8)
        return ok
    }

    /// Hinweis-Satz mit eigenem Namen und Wörterbuch-Wörtern – als natürlicher Satz, sonst plappert Whisper eine Liste nach.
    static func vocabularyPrompt() -> String {
        var words: [String] = []
        let fz = Settings.frozen
        for e in fz.dictionary.reversed() {   // neueste (gelernte) zuerst
            let w = e.write.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty, !words.contains(w) { words.append(w) }
        }
        let name = fz.myName.isEmpty ? Identity.systemFirstName : fz.myName
        // Satzbau + Begriffe vom Bildschirm (Kontext-Diktat) – ohne Kontext genau der bisherige Satz
        return ContextBoost.prompt(dictionaryWords: words, name: name)
    }

    struct Result { let text: String; let language: String; let words: [(word: String, start: Double, end: Double)] }

    /// Erkennung über den Server. language: "auto" / "de" / "en".
    func transcribe(_ samples: [Float], language: String = "auto", prompt: String? = nil, wordTimes: Bool = false) async throws -> Result {
        useLock.lock(); inFlight += 1; lastUse = Date(); useLock.unlock()
        defer { useLock.lock(); inFlight -= 1; lastUse = Date(); useLock.unlock() }
        if !serverUp, parked {
            let t0 = Date()
            let ok = await ensureUp()
            log(String(format: "Whisper geweckt für Anfrage: %.0f ms gewartet", Date().timeIntervalSince(t0) * 1000))
            _ = ok
        }
        guard serverUp else { throw NSError(domain: "Flow", code: 7, userInfo: [NSLocalizedDescriptionKey: "Whisper-Server nicht bereit"]) }
        let wav = WhisperEngine.wavData(samples)
        let boundary = "flow-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("language", language)
        // „verbose_json“ (Wort-Zeiten) kostet ~0,7 s extra – nur anfordern, wenn wirklich gebraucht
        field("response_format", wordTimes ? "verbose_json" : "json")
        field("temperature", "0")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: base + "/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = max(10, Double(samples.count) / 16000 * 0.6)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.upload(for: req, from: body)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Flow", code: 8, userInfo: [NSLocalizedDescriptionKey: "Whisper-Antwort unlesbar"])
        }
        // Abschnitte bringen ihr führendes Leerzeichen selbst mit – eine Grenze kann mitten im Wort liegen
        // („erk|ennst“), deshalb NICHT mit Leerzeichen verbinden.
        let segTexts = ((j["segments"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
        // json: nur „text“ (Abschnitte mit \n getrennt, führende Leerzeichen bleiben erhalten)
        let joined = segTexts.isEmpty ? ((j["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: "") : segTexts.joined()
        let text = joined
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var words: [(String, Double, Double)] = []
        for seg in (j["segments"] as? [[String: Any]]) ?? [] {
            for w in (seg["words"] as? [[String: Any]]) ?? [] {
                guard let s = w["word"] as? String else { continue }
                words.append((s.trimmingCharacters(in: .whitespaces), (w["start"] as? Double) ?? 0, (w["end"] as? Double) ?? 0))
            }
        }
        let lang = (j["language"] as? String) ?? ""
        return Result(text: text, language: lang, words: words.map { (word: $0.0, start: $0.1, end: $0.2) })
    }

    /// Diktat: Sprache automatisch, aber nur Deutsch oder Englisch; Wörterbuch als Hinweis.
    /// language: "de"/"en" aus dem Parakeet-Text (HybridRecognizer.languageHint) – spart Whispers eigene
    /// Spracherkennung = einen zweiten Encoder-Lauf (~0,55 s). nil = wie bisher automatisch.
    func dictate(_ samples: [Float], context: String = "", language: String? = nil) async throws -> Result {
        // Wörterbuch-Satz + Ende des vorigen Stücks (Zusammenhang bei langen Diktaten)
        let prompt = WhisperEngine.vocabularyPrompt() + (context.isEmpty ? "" : " " + String(context.suffix(160)))
        let mode = Settings.frozen.languageMode
        var r = try await transcribe(samples, language: mode == .both ? (language ?? "auto") : mode.rawValue, prompt: prompt)
        if mode == .both, language == nil, (r.language.isEmpty ? LanguageGuard.looksForeign(r.text) : (r.language != "german" && r.language != "english")) {
            let lang = LanguageGuard.guessDeEn(r.text)
            log("Whisper hörte \(r.language) → erzwinge \(lang)")
            r = try await transcribe(samples, language: lang, prompt: prompt)
        }
        // Halluzinationen bei (fast) Stille verwerfen
        let junk = ["untertitel", "vielen dank fürs zuschauen", "thanks for watching", "amara.org", "copyright", "untertitelung"]
        if junk.contains(where: { r.text.lowercased().contains($0) }) { return Result(text: "", language: r.language, words: []) }
        // Plappert Whisper nur den Hinweis nach? Dann verwerfen. Erst ab 4 Wörtern – ein einzeln gesagter Name
        // („Lumora.“, „Pierre.“) steht natürlich auch im Hinweis und ist trotzdem richtig.
        let nWords = r.text.split(whereSeparator: { $0.isWhitespace }).count
        if !prompt.isEmpty, nWords >= 4, r.text.count > 8, prompt.lowercased().contains(r.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            log("Whisper hat nur den Hinweis wiederholt → verworfen")
            return Result(text: "", language: r.language, words: [])
        }
        return r
    }

    /// Freien Port vom System holen
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func wavData(_ samples: [Float]) -> Data {
        var d = Data()
        let n = samples.count
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n * 2))
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
