import FluidAudio
import Foundation

/// Tempo-Messbank (Agent SPEED, 27.09.2026). Nur CLI, fasst weder App noch ~/.config/flow an (FLOW_HOME setzen).
///   Flow --speed-lat <wav>                 Latenz Parakeet/Whisper je Cliplänge und Encoder-Fenster (audio_ctx)
///   Flow --speed-post <wav…>               Nachbearbeitung nach der Erkennung, je Schritt (Text aus <wav>.txt)
///   Flow --speed-micro <wav>               Kleinkram auf dem kritischen Pfad
///   Flow --speed-sys <mikro> <mac-ton> …   Mac-Ton-Filter alt (nach dem Loslassen) gegen SystemTextStream
///   Flow --speed-guard manifest [--words dir] [--slow P,W]   Tempo-Garantie aus/an: WER, Namen, Latenz
enum SpeedCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args[1].hasPrefix("--speed-") else { return nil }
        // Messläufe schreiben Protokoll/Einstellungen nur in einen Test-Ordner – nie in ~/.config/flow
        if (ProcessInfo.processInfo.environment["FLOW_HOME"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            FileHandle.standardError.write("--speed-*: nur mit FLOW_HOME=<Testordner>\n".data(using: .utf8)!)
            return 3
        }
        switch args[1] {
        case "--speed-lat": return wait { try await SpeedBench.latency(args) }
        case "--speed-post": return wait { try await SpeedBench.post(args) }
        case "--speed-micro": return wait { try await SpeedBench.micro(args) }
        case "--speed-sys": return wait { try await SpeedBench.systemAudio(args) }
        case "--speed-guard": return wait { try await SpeedBench.guardBench(args) }
        default: return nil
        }
    }

    static func wait(_ body: @escaping () async throws -> Void) -> Int32 {
        var code: Int32 = 0
        var done = false
        Task {
            do { try await body() } catch { print("Fehler: \(error)"); code = 1 }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }
}

enum SpeedBench {
    static func pct(_ a: [Int], _ p: Double) -> Int {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    static func load(_ path: String) throws -> [Float] { try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path)) }

    /// Nachbearbeitung wie in DictationController.collect() nach der Erkennung, je Schritt gemessen.
    ///   --speed-post <wav mit .txt daneben …>   (Text = Ergebnis des Diktats, Ton = Mac-Ton-Ersatz gleicher Länge)
    static func post(_ args: [String]) async throws {
        TLog.quiet = true
        _ = Settings.shared
        func ms(_ t0: Date) -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        _ = try await Transcriber.shared.transcribe([Float](repeating: 0, count: 16000))
        for f in args.dropFirst(2) where f.hasSuffix(".wav") {
            let s = try load(f)
            let text = (try? String(contentsOfFile: f.replacingOccurrences(of: ".wav", with: ".txt"), encoding: .utf8)) ?? ""
            var line = String(format: "%@ %5.1fs %3d Wörter:", (f as NSString).lastPathComponent, Double(s.count) / 16000, text.split(separator: " ").count)
            var t0 = Date()
            _ = try await Transcriber.shared.transcribe(s)
            line += " mac-ton(parakeet ganzer Clip) \(ms(t0)) ms"
            t0 = Date(); let r = TextCleaner.applyRules(text, settings: Settings.shared); line += " | regeln \(ms(t0))"
            t0 = Date(); _ = VoiceCommandParser.parse(r); line += " | befehl \(ms(t0))"
            t0 = Date(); let hit = VocabTrigger.hit(in: r, dictionary: Settings.frozen.dictionary, policy: HybridRecognizer.policy); line += " | wörterbuch-prüfung \(ms(t0))"
            t0 = Date(); let o = await Polisher.run(r, snapshot: nil, mode: .fast); line += " | feinschliff(\(o.engine)) \(ms(t0))"
            t0 = Date(); let x = SnippetStore.shared.expand(o.text); line += " | snippets \(ms(t0))"
            t0 = Date(); _ = StyleStore.shared.apply(x, category: .other); line += " | stil \(ms(t0))"
            t0 = Date(); _ = TextCleaner.applyRules(o.text, settings: Settings.shared); line += " | regeln2 \(ms(t0))"
            print(line + (hit.map { " [\($0)]" } ?? ""))
        }
    }

    /// Latenz je Länge: Parakeet (ANE) und Whisper (voll 1500 Frames vs. dynamisches Fenster)
    static func latency(_ args: [String]) async throws {
        TLog.quiet = true
        let s = try load(args[2])
        let lens: [Double] = [1, 2, 3, 5, 8, 12, 17, 30, 60, 115].filter { Double(s.count) / 16000 >= $0 - 0.5 }
        try await EngineParakeet.shared.load()
        _ = try await EngineParakeet.shared.transcribe(Array(s.prefix(16000 * 3)))
        print("== Parakeet (EngineParakeet, Neural Engine)")
        for L in lens {
            let a = Array(s.prefix(Int(L * 16000)))
            var ms: [Int] = []
            for _ in 0..<3 { let t0 = Date(); _ = try await EngineParakeet.shared.transcribe(a); ms.append(Int(Date().timeIntervalSince(t0) * 1000)) }
            print(String(format: "  %6.1f s Ton → %5d ms (min %d)", L, pct(ms, 0.5), ms.min()!))
        }
        guard let model = WhisperFallback.model, let srv = WhisperServerProcess(model: model, threads: 6), await srv.waitReady() else { print("kein Whisper"); return }
        defer { srv.stop() }
        let cl = srv.client
        for _ in 0..<2 { _ = try? await cl.transcribe(Array(s.prefix(16000 * 4)), WhisperRequestOptions(language: "de")) }
        print("== Whisper large-v3-turbo q5_0 (Metal), Sprache vorgegeben, Hinweis-Satz")
        let prompt = WhisperEngine.vocabularyPrompt()
        for L in lens where L <= 30 {
            let a = Transcriber.normalizedGentle(Array(s.prefix(Int(L * 16000))))
            var line = String(format: "  %6.1f s Ton:", L)
            for ac in [0, WhisperAudioContext.frames(forSamples: a.count) ?? 0, 256, 128] where ac == 0 || ac >= Int(L * 50) + 20 {
                var ms: [Int] = []
                var txt = ""
                for _ in 0..<3 {
                    let r = try await cl.transcribe(a, WhisperRequestOptions(language: "de", prompt: prompt, audioCtx: ac))
                    ms.append(r.ms); txt = r.text
                }
                line += String(format: "  ac=%4d → %4d ms", ac == 0 ? 1500 : ac, pct(ms, 0.5))
                if L <= 3 { line += " „\(txt.prefix(40))“" }
            }
            print(line)
        }
    }

    /// Kleinkram auf dem kritischen Pfad (je Aufruf, ms)
    static func micro(_ args: [String]) async throws {
        TLog.quiet = true
        let s = try load(args[2])
        for L in [3.0, 8.0, 25.0] where Double(s.count) / 16000 >= L {
            let a = Array(s.prefix(Int(L * 16000)))
            func t(_ f: () -> Void) -> String { let t0 = Date(); for _ in 0..<5 { f() }; return String(format: "%.1f", Date().timeIntervalSince(t0) * 200) }
            print(String(format: "%5.1f s:", L), "WhisperDetector.analyze", t { _ = WhisperDetector.analyze(a) },
                  "| hasWhisperSpeech", t { _ = WhisperDetector.hasWhisperSpeech(a) }, "| normalized", t { _ = Transcriber.normalized(a) },
                  "| normalizedGentle", t { _ = Transcriber.normalizedGentle(a) }, "| EchoFilter.hasSound", t { _ = EchoFilter.hasSound(a) },
                  "| peak", t { _ = Dictation.peak(a) }, "| wav", t { _ = WhisperEngine.wavData(a) })
        }
    }

    /// Mac-Ton-Filter: alt (ganzer Mac-Ton nach dem Loslassen) gegen neu (SystemTextStream, Stücke während der Aufnahme).
    ///   --speed-sys <mikro.wav> <mac-ton.wav> …   (Paare; Mac-Ton wird in Echtzeit „abgespielt“, 0,5-s-Takt wie im Diktat)
    static func systemAudio(_ args: [String]) async throws {
        TLog.quiet = true
        _ = Settings.shared
        let files = Array(args.dropFirst(2))
        _ = try await Transcriber.shared.transcribe([Float](repeating: 0, count: 16000))
        print("mikro + mac-ton                         dauer  alt(ms) neu(ms)  Text nach Filter gleich?")
        for i in stride(from: 0, to: files.count - 1, by: 2) {
            let mic = try load(files[i]), sys = try load(files[i + 1])
            let n = min(mic.count, sys.count)
            let micText = try await Transcriber.shared.transcribe(Array(mic.prefix(n))).text
            // alt
            var t0 = Date()
            let old = try await Transcriber.shared.transcribe(Array(sys.prefix(n))).text
            let oldMs = Int(Date().timeIntervalSince(t0) * 1000)
            // neu: Echtzeit-Zufuhr
            let stream = SystemTextStream()
            var fed = 0
            let start = Date()
            while fed < n {
                fed = min(n, fed + 8000)
                let wait = start.addingTimeInterval(Double(fed) / 16000).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                let have = fed
                stream.poll(count: have, peek: { Array(sys[$0..<have]) })
            }
            let job = stream.take(Array(sys.prefix(n)))
            t0 = Date()
            let new = await job() ?? ""
            let newMs = Int(Date().timeIntervalSince(t0) * 1000)
            let a = EchoFilter.subtract(dictation: micText, systemText: old), b = EchoFilter.subtract(dictation: micText, systemText: new)
            let name = ((files[i] as NSString).lastPathComponent + " + " + (files[i + 1] as NSString).lastPathComponent)
            print(String(format: "%@ %5.1fs  %6d  %6d   %@ (%d → %d Wörter)", name.padding(toLength: 38, withPad: " ", startingAt: 0) as NSString, Double(n) / 16000,
                         oldMs, newMs, (a == b ? "ja" : "NEIN") as NSString, micText.split(separator: " ").count, b.split(separator: " ").count))
            if a != b { print("   alt: \(a.prefix(160))\n   neu: \(b.prefix(160))") }
        }
    }

    /// Genauigkeit + Latenz mit/ohne Tempo-Garantie (ganzer Clip nach dem Loslassen, 0,12 s Nachlauf eingerechnet).
    ///   --speed-guard manifest.json [--slow P,W] [--words dir] [--reps N]
    static func guardBench(_ args: [String]) async throws {
        TLog.quiet = true
        _ = Settings.shared
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let slow = (opt("--slow") ?? "1,1").split(separator: ",").compactMap { Double($0) }
        let (fp, fw) = (slow.first ?? 1, slow.count > 1 ? slow[1] : 1)
        struct Row { let id: String; let truth: String; let names: [String]; let lang: String; let a: [Float] }
        var rows: [Row] = []
        if args[2].hasSuffix(".json") {
            for c in try JSONDecoder().decode([EngineBench.Clip].self, from: Data(contentsOf: URL(fileURLWithPath: args[2]))) {
                rows.append(Row(id: c.id, truth: c.truth, names: c.names, lang: c.lang, a: try load(c.file)))
            }
        }
        let profiles = NameStore.shared.profiles()
        if let dir = opt("--words") {
            for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter({ $0.hasSuffix(".wav") }).sorted() {
                let key = String(f.split(separator: "-").first ?? "")
                let target = profiles.first { $0.target.lowercased() == key }?.target ?? Settings.frozen.dictionary.first { $0.write.lowercased() == key }?.write ?? key
                rows.append(Row(id: "wort:" + f, truth: target, names: [target], lang: "de", a: try load(dir + "/" + f)))
            }
        }
        guard let model = WhisperFallback.model, let srv = WhisperServerProcess(model: model, threads: 6), await srv.waitReady() else { print("kein Whisper"); return }
        defer { srv.stop() }
        let cl = srv.client
        try await EngineParakeet.shared.load()
        func stretch(_ t0: Date, _ f: Double) async { let d = Date().timeIntervalSince(t0) * (f - 1); if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) } }
        let env = HybridRecognizer.Env(
            parakeet: { let t0 = Date(); let r = try await EngineParakeet.shared.transcribe($0); await stretch(t0, fp); return r },
            whisper: { s, ctx, lang in let t0 = Date(); let r = try await cl.dictate(s, context: ctx, language: lang).text; await stretch(t0, fw); return r },
            whisperReady: { true }, dictionary: Settings.frozen.dictionary, names: profiles, learnAliases: false)
        for r in rows.prefix(2) { _ = await HybridRecognizer.recognize(r.a, context: "", env: env) }
        TempoGuard.install()
        var outs: [String: [(String, Int, String)]] = ["aus": [], "an": []]
        for r in rows {
            var line = r.id.padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: " %5.1fs", Double(r.a.count) / 16000)
            for mode in ["aus", "an"] {
                TempoGuard.setForTest(mode == "an")
                // Loslassen war vor 0,12 s (Nachlauf), dann startet die Erkennung
                let mark = TempoGuard.arm(release: Date().addingTimeInterval(-0.12))
                let t0 = Date()
                let o = await HybridRecognizer.recognize(r.a, context: "", env: env)
                let ms = Int(Date().timeIntervalSince(t0) * 1000) + 120
                TempoGuard.disarm(mark)
                outs[mode]!.append((o.text, ms, o.engine))
                line += String(format: " | %@ %5d ms %@", mode as NSString, ms, o.engine.padding(toLength: 18, withPad: " ", startingAt: 0) as NSString)
                // Whisper läuft nach der Frist weiter – abwarten, damit die nächste Messung nicht dahinter wartet
                if TempoGuard.expiredCount > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
            print(line)
        }
        TempoGuard.setForTest(false)
        for mode in ["aus", "an"] {
            var err = 0, ref = 0, hit = 0, nn = 0
            for (i, r) in rows.enumerated() {
                let t = BenchText.words(r.truth, lang: r.lang)
                let ruled = TextCleaner.applyRules(outs[mode]![i].0, settings: Settings.shared)
                err += VocabTrigger.levenshtein(t, BenchText.words(ruled, lang: r.lang)); ref += t.count
                let (h, n) = BenchText.nameHits(ruled, names: r.names, lang: r.lang); hit += h; nn += n
            }
            let lat = outs[mode]!.map(\.1)
            print(String(format: "Garantie %@: WER %.1f %%  Namen %.1f %% (%d)  Loslassen→Text p50 %d  p95 %d  p99/max %d ms  (> 1 s: %d von %d)", mode as NSString,
                         Double(err) / Double(max(1, ref)) * 100, Double(hit) / Double(max(1, nn)) * 100, nn, pct(lat, 0.5), pct(lat, 0.95), lat.max() ?? 0,
                         lat.filter { $0 > 1000 }.count, lat.count))
        }
    }
}
