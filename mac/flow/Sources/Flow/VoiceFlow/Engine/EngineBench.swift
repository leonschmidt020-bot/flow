import FluidAudio
import Foundation

/// Messbank für die Erkennung: `Flow --engine-bench <manifest.json> [--out ergebnis.json] [--real <ordner>] [--only a,b]`
///
/// manifest.json = [{id, file, lang, truth, names:[…], dur}] (erzeugt von make_testset.py: say-Stimmen DE/EN).
/// Misst je Konfiguration: WER (roh / nach Wörterbuch-Regeln), Namens-Treffer, Latenz p50/p95, CPU-Zeit.
/// Startet eigene whisper-server auf freien Ports (nie 8765, nie „/flow-“) und beendet sie wieder.
enum EngineBench {
    struct Clip: Codable { let id: String; let file: String; let lang: String; let truth: String; let names: [String]; let dur: Double }

    struct Rec: Codable {
        let clip: String; let config: String; let hyp: String; let ms: Int
        var meanConf: Float? = nil, minWordConf: Float? = nil, minTokConf: Float? = nil, shaky: Float? = nil
        var engine: String? = nil, reason: String? = nil
        var words: [String]? = nil, wordConf: [Float]? = nil
    }

    struct Summary: Codable { let config: String; let n: Int; let werRaw: Double; let werRules: Double; let nameAcc: Double
        let p50: Int; let p95: Int; let mean: Int; let cpuMsPerClip: Int; let whisperShare: Double? }

    static func run(_ args: [String]) async throws {
        _ = Settings.shared
        guard args.count > 2 else { print("Aufruf: --engine-bench manifest.json [--out x.json] [--real dir] [--only a,b]"); return }
        let manifestURL = URL(fileURLWithPath: args[2])
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let out = opt("--out") ?? manifestURL.deletingLastPathComponent().appendingPathComponent("ergebnis.json").path
        let only = opt("--only").map { Set($0.split(separator: ",").map(String.init)) }
        func want(_ c: String) -> Bool { only == nil || only!.contains(c) || only!.contains(where: { c.hasPrefix($0 + ":") }) }

        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: manifestURL))
        let conv = AudioConverter()
        var audio: [String: [Float]] = [:]
        for c in clips { audio[c.id] = try conv.resampleAudioFile(URL(fileURLWithPath: c.file)) }
        // Echte Aufnahmen (nur Latenz + Übereinstimmung)
        var real: [Clip] = []
        if let dir = opt("--real") {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            for f in files {
                let s = try conv.resampleAudioFile(URL(fileURLWithPath: dir + "/" + f))
                let id = "real:" + f.replacingOccurrences(of: ".wav", with: "")
                audio[id] = s
                let txt = (try? String(contentsOfFile: dir + "/" + f.replacingOccurrences(of: ".wav", with: ".txt"), encoding: .utf8)) ?? ""
                real.append(Clip(id: id, file: f, lang: "de", truth: txt, names: [], dur: Double(s.count) / 16000))
            }
        }
        let all = clips + real
        print("\(clips.count) Testclips + \(real.count) echte Aufnahmen geladen")

        var recs: [Rec] = []
        var cpu: [String: Double] = [:]

        // ── Parakeet ──
        try await EngineParakeet.shared.load()
        for c in all.prefix(3) { _ = try await EngineParakeet.shared.transcribe(audio[c.id]!) }  // aufwärmen
        var parakeetOut: [String: ScoredText] = [:]
        let pc0 = selfCPU()
        for c in all {
            let t0 = Date()
            let r = try await EngineParakeet.shared.transcribe(audio[c.id]!)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            parakeetOut[c.id] = r
            recs.append(Rec(clip: c.id, config: "parakeet", hyp: r.text, ms: ms, meanConf: r.meanConfidence, minWordConf: r.minWordConfidence,
                            minTokConf: r.minConfidence, shaky: r.shakyWordShare, words: r.words.map(\.word), wordConf: r.words.map(\.conf)))
        }
        cpu["parakeet"] = (selfCPU() - pc0) / Double(all.count)
        print("Parakeet fertig")

        // ── Whisper-Server ──
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper-cpp/models").path
        let extraDir = opt("--models") ?? ""
        func model(_ name: String) -> String? {
            for d in [dir, extraDir] where !d.isEmpty { let p = d + "/" + name; if FileManager.default.fileExists(atPath: p) { return p } }
            return nil
        }
        struct ReqCfg { let name: String; let prompt: Bool; let ac: (Int) -> Int?; let beam: Int?; var lang = false; var extra: [String] = [] }
        let acDyn: (Int) -> Int? = { WhisperAudioContext.frames(forSamples: $0) }
        let reqFull = ReqCfg(name: "prompt", prompt: true, ac: { _ in nil }, beam: nil)
        let reqNoPrompt = ReqCfg(name: "noprompt", prompt: false, ac: { _ in nil }, beam: nil)
        let reqBeam = ReqCfg(name: "beam5", prompt: true, ac: { _ in nil }, beam: 5)
        let reqAcDyn = ReqCfg(name: "acdyn", prompt: true, ac: acDyn, beam: nil)
        let reqAc768 = ReqCfg(name: "ac768", prompt: true, ac: { $0 <= 16000 * 14 ? 768 : nil }, beam: nil)
        // Sprache aus dem (ohnehin schon vorliegenden) Parakeet-Text statt Whisper-Autoerkennung
        let reqLang = ReqCfg(name: "lang", prompt: true, ac: { _ in nil }, beam: nil, lang: true)
        let reqLangAcDyn = ReqCfg(name: "lang-acdyn", prompt: true, ac: acDyn, beam: nil, lang: true)
        let reqLangAc768 = ReqCfg(name: "lang-ac768", prompt: true, ac: { $0 <= 16000 * 14 ? 768 : nil }, beam: nil, lang: true)
        let reqLangBeam = ReqCfg(name: "lang-beam5", prompt: true, ac: { _ in nil }, beam: 5, lang: true)
        let reqLangNoPrompt = ReqCfg(name: "lang-noprompt", prompt: false, ac: { _ in nil }, beam: nil, lang: true)
        // Größeres Wörterbuch (Namen, die oft gesagt, aber noch nicht eingetragen werden)
        let extraNames = (ProcessInfo.processInfo.environment["VF_BENCH_EXTRA"] ?? "Brenninkmeyer,Dufresne,Lumora,Wolfenbüttel").split(separator: ",").map(String.init)
        let reqLangX = ReqCfg(name: "lang-xvocab", prompt: true, ac: { _ in nil }, beam: nil, lang: true, extra: extraNames)
        let servers: [(String, String?, Int, [ReqCfg])] = [
            ("q5-t6", model("ggml-large-v3-turbo-q5_0.bin"), 6, [reqFull, reqNoPrompt, reqBeam, reqAcDyn, reqAc768, reqLang, reqLangAcDyn, reqLangAc768, reqLangBeam, reqLangNoPrompt, reqLangX]),
            ("q5-t4", model("ggml-large-v3-turbo-q5_0.bin"), 4, [reqFull, reqLang]),
            ("q5-t8", model("ggml-large-v3-turbo-q5_0.bin"), 8, [reqFull, reqLang]),
            ("q8-t6", model("ggml-large-v3-turbo-q8_0.bin"), 6, [reqFull, reqLang]),
            ("f16-t6", model("ggml-large-v3-turbo-f16.bin"), 6, [reqFull, reqLang]),
        ]
        var hybridServer: WhisperServerProcess?
        for (sname, path, threads, reqs) in servers {
            guard let path else { print("– \(sname): Modell fehlt"); continue }
            let todo = reqs.filter { want("\(sname):\($0.name)") }
            let needHybrid = sname == "q5-t6" && (want("hybrid") || want("hybrid-xvocab") || want("hybrid-acdyn"))
            if todo.isEmpty && !needHybrid { continue }
            // Pro Anfrage-Konfig ein FRISCHER Server: whisper-server behält sonst Zustand aus vorigen Anfragen
            // (gemessen: nach audio_ctx-Anfragen wurde die normale Erkennung schlechter)
            func freshServer() async -> WhisperServerProcess? {
                guard let s = WhisperServerProcess(model: path, threads: threads), await s.waitReady() else { return nil }
                for c in all.prefix(2) { _ = try? await s.client.dictate(audio[c.id]!) }  // aufwärmen
                return s
            }
            for rq in todo {
                guard let srv = await freshServer() else { print("– \(sname): Server startet nicht"); continue }
                defer { srv.stop() }
                let cl = srv.client
                let cfg = "\(sname):\(rq.name)"
                let c0 = srv.cpuSeconds()
                for c in all {
                    let s = audio[c.id]!
                    let lang = rq.lang ? HybridRecognizer.languageHint(parakeetOut[c.id]!.text) : nil
                    let r = (try? await cl.dictate(s, usePrompt: rq.prompt, audioCtx: rq.ac(s.count), beamSize: rq.beam, language: lang, extraVocabulary: rq.extra)) ?? .init(text: "", ms: -1)
                    recs.append(Rec(clip: c.id, config: cfg, hyp: r.text, ms: r.ms))
                }
                cpu[cfg] = (srv.cpuSeconds() - c0) / Double(all.count)
                print("\(cfg) fertig")
            }
            if needHybrid { hybridServer = await freshServer() }
        }

        // ── Hybrid (echter Durchlauf mit kalibrierter Policy) ──
        if let srv = hybridServer {
            let env = ProcessInfo.processInfo.environment
            if let v = env["VF_MINMEAN"].flatMap(Float.init) { HybridRecognizer.policy.minMeanConfidence = v }
            if let v = env["VF_MINWORD"].flatMap(Float.init) { HybridRecognizer.policy.minWordConfidence = v }
            let cl = srv.client
            HybridRecognizer.whisperReady = { true }
            HybridRecognizer.learnAliases = false   // Bench schreibt nichts in echte Nutzerdaten
            HybridRecognizer.parakeet = { try await EngineParakeet.shared.transcribe($0) }
            let extraNames = (ProcessInfo.processInfo.environment["VF_BENCH_EXTRA"] ?? "Brenninkmeyer,Dufresne,Lumora,Wolfenbüttel").split(separator: ",").map(String.init)
            let basePolicy = HybridRecognizer.policy
            for (name, useAc, xv) in [("hybrid", false, false), ("hybrid-xvocab", false, true), ("hybrid-acdyn", true, false)] where want(name) {
                let extra = xv ? extraNames : []
                HybridRecognizer.policy = basePolicy
                HybridRecognizer.policy.extraVocabulary = extra
                HybridRecognizer.whisper = { s, ctx, lang in try await cl.dictate(s, context: ctx, audioCtx: useAc ? WhisperAudioContext.frames(forSamples: s.count) : nil, language: lang, extraVocabulary: extra).text }
                let c0 = srv.cpuSeconds(), p0 = selfCPU()
                var nW = 0
                for c in all {
                    let r = await HybridRecognizer.recognize(audio[c.id]!, context: "")
                    let d = HybridRecognizer.decide(parakeetOut[c.id]!, seconds: c.dur)
                    if r.engine == "whisper" { nW += 1 }
                    recs.append(Rec(clip: c.id, config: name, hyp: r.text, ms: r.ms, engine: r.engine, reason: d.reason))
                }
                cpu[name] = (srv.cpuSeconds() - c0 + selfCPU() - p0) / Double(all.count)
                print("\(name) fertig – Whisper bei \(nW)/\(all.count)")
            }
            srv.stop()
        }

        // ── Nebenkosten: Stimmabgleich (CAM++), Parakeet auf Mac-Ton ──
        if want("voiceid"), VoiceID.isEnrolled, let long = clips.max(by: { $0.dur < $1.dur }) {
            for secs in [3.0, 10.0, 25.0] {
                let s = Array(audio[long.id]!.prefix(Int(secs * 16000)))
                _ = await VoiceID.shared.mask(s)
                let t0 = Date(); _ = await VoiceID.shared.mask(s)
                recs.append(Rec(clip: "voiceid-\(Int(secs))s", config: "voiceid:mask", hyp: "", ms: Int(Date().timeIntervalSince(t0) * 1000)))
            }
        }

        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(recs).write(to: URL(fileURLWithPath: out))
        let sums = summarize(recs, clips: clips, real: real, cpu: cpu)
        try enc.encode(sums).write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".json", with: "-summary.json")))
        print("\nErgebnis: \(out)")
    }

    static func selfCPU() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func summarize(_ recs: [Rec], clips: [Clip], real: [Clip], cpu: [String: Double]) -> [Summary] {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let realIDs = Set(real.map(\.id))
        var configs: [String] = []
        for r in recs where !configs.contains(r.config) { configs.append(r.config) }
        var out: [Summary] = []
        print(String(format: "\n%@ %5@ %7@ %7@ %7@ %6@ %6@ %6@ %6@  %@", "config".padding(toLength: 20, withPad: " ", startingAt: 0) as NSString, "n" as NSString, "WERroh" as NSString, "WERreg" as NSString,
                     "Namen" as NSString, "p50" as NSString, "p95" as NSString, "real50" as NSString, "cpu" as NSString, "Whisper-Anteil" as NSString))
        for cfg in configs where !cfg.hasPrefix("voiceid") {
            let rs = recs.filter { $0.config == cfg && byID[$0.clip] != nil }
            guard !rs.isEmpty else { continue }
            var errRaw = 0, errRules = 0, refN = 0, nameHit = 0, nameN = 0
            for r in rs {
                let c = byID[r.clip]!
                let ref = BenchText.words(c.truth, lang: c.lang)
                errRaw += VocabTrigger.levenshtein(ref, BenchText.words(r.hyp, lang: c.lang))
                let ruled = TextCleaner.applyRules(r.hyp, settings: Settings.shared)
                errRules += VocabTrigger.levenshtein(ref, BenchText.words(ruled, lang: c.lang))
                refN += ref.count
                let (h, n) = BenchText.nameHits(ruled, names: c.names, lang: c.lang)
                nameHit += h; nameN += n
            }
            let lat = rs.map(\.ms).sorted()
            let realLat = recs.filter { $0.config == cfg && realIDs.contains($0.clip) }.map(\.ms).sorted()
            let wShare: Double? = rs.first?.engine == nil ? nil : Double(rs.filter { $0.engine == "whisper" }.count) / Double(rs.count)
            let s = Summary(config: cfg, n: rs.count, werRaw: Double(errRaw) / Double(refN), werRules: Double(errRules) / Double(refN),
                            nameAcc: nameN == 0 ? 1 : Double(nameHit) / Double(nameN), p50: pct(lat, 0.5), p95: pct(lat, 0.95),
                            mean: lat.reduce(0, +) / lat.count, cpuMsPerClip: Int((cpu[cfg] ?? 0) * 1000), whisperShare: wShare)
            out.append(s)
            print(String(format: "%@ %5d %6.1f%% %6.1f%% %6.1f%% %6d %6d %6d %6d  %@", cfg.padding(toLength: 20, withPad: " ", startingAt: 0) as NSString, s.n, s.werRaw * 100, s.werRules * 100, s.nameAcc * 100,
                         s.p50, s.p95, pct(realLat, 0.5), s.cpuMsPerClip, (wShare.map { String(format: "%.0f%%", $0 * 100) } ?? "") as NSString))
        }
        for r in recs where r.config.hasPrefix("voiceid") { print("\(r.clip): \(r.ms) ms") }
        return out
    }

    static func pct(_ s: [Int], _ p: Double) -> Int { s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
}

/// Text-Normalisierung für WER (Groß/klein und Satzzeichen egal, kleine Zahlen als Wort)
enum BenchText {
    static let numDE = ["0": "null", "1": "eins", "2": "zwei", "3": "drei", "4": "vier", "5": "fünf", "6": "sechs", "7": "sieben", "8": "acht", "9": "neun", "10": "zehn", "11": "elf", "12": "zwölf"]
    static let numEN = ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine", "10": "ten", "11": "eleven", "12": "twelve"]

    static func words(_ s: String, lang: String) -> [String] {
        let t = s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
        return t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map { w in
            if let n = (lang == "en" ? numEN : numDE)[w] { return n }
            if w == "ok" { return "okay" }
            return w
        }
    }

    /// Wie viele der Soll-Namen stehen (als Wortfolge) im Ergebnis?
    static func nameHits(_ hyp: String, names: [String], lang: String) -> (Int, Int) {
        let h = words(hyp, lang: lang)
        var used = [Bool](repeating: false, count: h.count)
        var hit = 0
        for name in names {
            let n = words(name, lang: lang)
            guard !n.isEmpty, h.count >= n.count else { continue }
            for i in 0...(h.count - n.count) where !used[i] && Array(h[i..<(i + n.count)]) == n {
                for k in i..<(i + n.count) { used[k] = true }
                hit += 1; break
            }
        }
        return (hit, names.count)
    }
}
