import AppKit
import FluidAudio
import Foundation
import SwiftUI

/// Speicher-Messbank (nur CLI, startet nie die App):
///   Flow --mem-probe [meeting.wav]      – was kostet welches Modell (Footprint + Neural-Engine-Speicher), lädt/entlädt der Reihe nach
///   Flow --mem-reload [n]               – Parakeet laden/entladen: Zeiten + ob der Neural-Speicher wirklich frei wird
///   Flow --mem-idle-test                – WhisperEngine parken + warm starten wie in der App (eigener Test-Server)
///   Flow --mem-hub                      – Hub-Fenster: alle Seiten durchklicken, schließen, freigeben (offscreen)
///   Flow --mem-hybrid-bench manifest.json [--modes warm,prewarm,cold]
///                                         – echter Hybrid-Weg (Transcriber + WhisperEngine) mit laufendem / geparktem Whisper:
///                                           WER, Namen, Latenz p50/p95 (Testclips + echte Diktate)
///   Flow --mem-quant-bench manifest.json --models a.bin,b.bin
///                                         – Whisper-Quantisierungen: Speicher des Servers, WER/Namen/Latenz (nur Whisper + Hybrid)
///   Flow --mem-meeting-peak andere.wav ich.wav [min] [alt]
///                                         – Spitzenspeicher der Meeting-Auswertung (wie MeetingProcessor, Ton auf [min] gekachelt)
/// Alle Zahlen kommen aus `/usr/bin/footprint` (dieselbe Quelle wie die Aktivitätsanzeige).
/// Aufruf am besten mit `FLOW_HOME=<Testordner>`, damit Log/PID-Datei nicht im echten Datenordner landen.
enum MemCLI {
    static func run(_ args: [String]) -> Int32? {
        switch args[1] {
        case "--mem-probe": return wait { try await MemProbe.inventory(args.count > 2 ? args[2] : nil) }
        case "--mem-reload": return wait { try await MemProbe.reload(n: Int(args.count > 2 ? args[2] : "") ?? 3) }
        case "--mem-idle-test": return wait { try await MemProbe.whisperIdle() }
        case "--mem-hub": return MemProbe.hub()
        case "--mem-hybrid-bench": return wait { try await MemProbe.hybridBench(args) }
        case "--mem-quant-bench": return wait { try await MemProbe.quantBench(args) }
        case "--mem-meeting-peak": return wait { try await MemProbe.meetingPeak(args) }
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

enum MemProbe {
    struct Snap: CustomStringConvertible {
        let footprintMB: Double, neuralMB: Double
        var totalMB: Double { footprintMB + neuralMB }
        var description: String { String(format: "Footprint %6.0f MB · Neural %6.0f MB · zusammen %6.0f MB", footprintMB, neuralMB, totalMB) }
    }

    /// Footprint + „Owned physical footprint (neural)“ (Dirty+Clean+Reclaimable) eines Prozesses.
    static func snap(_ pid: Int32 = getpid()) -> Snap {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        p.arguments = ["\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Snap(footprintMB: -1, neuralMB: -1) }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        func mb(_ s: Substring) -> Double {
            let t = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard t.count >= 2, let v = Double(t[0]) else { return 0 }
            switch t[1] { case "GB": return v * 1024; case "MB": return v; case "KB": return v / 1024; default: return v / 1_048_576 }
        }
        var fp = 0.0, neural = 0.0
        for line in out.split(separator: "\n") {
            if let r = line.range(of: "Footprint: ") { fp = mb(line[r.upperBound...].prefix(while: { $0 != "(" })) }
            if line.contains("(neural)") {
                // Spalten: Dirty Clean Reclaimable Regions Category – je „Zahl Einheit“
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                var vals: [Double] = []
                var i = 0
                while i + 1 < parts.count, vals.count < 3 {
                    if Double(parts[i]) != nil, ["B", "KB", "MB", "GB"].contains(String(parts[i + 1])) { vals.append(mb(parts[i] + " " + parts[i + 1])); i += 2 } else { i += 1 }
                }
                neural += vals.reduce(0, +)
            }
        }
        return Snap(footprintMB: fp, neuralMB: neural)
    }

    static func settle() async { try? await Task.sleep(nanoseconds: 1_500_000_000) }

    static func step(_ name: String, _ t: Double? = nil) async -> Snap {
        await settle()
        let s = snap()
        print(name.padding(toLength: 44, withPad: " ", startingAt: 0) + s.description + (t.map { String(format: "  (%.2f s)", $0) } ?? ""))
        return s
    }

    static func realDictations() -> [[Float]] {
        // Immer die echten Diktate (nur lesen) – auch wenn FLOW_HOME auf einen Testordner zeigt
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow/diktate")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        let conv = AudioConverter()
        return files.compactMap { try? conv.resampleAudioFile(dir.appendingPathComponent($0)) }
    }

    static func inventory(_ meetingPath: String?) async throws {
        _ = Settings.shared
        let clips = realDictations()
        print("Echte Diktate: \(clips.count) (nur gelesen)")
        let s0 = await step("0 Start (nichts geladen)")

        var t = Date()
        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        var asr: AsrManager? = AsrManager()
        try await asr!.loadModels(models)
        var st = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
        _ = try? await asr!.transcribe([Float](repeating: 0, count: 16000), decoderState: &st)
        let s1 = await step("1 Parakeet Ultra geladen+aufgewärmt", Date().timeIntervalSince(t))
        for c in clips { var d = TdtDecoderState.make(decoderLayers: 2); _ = try await asr!.transcribe(Transcriber.normalized(c), decoderState: &d) }
        let s1b = await step("1b nach \(clips.count) echten Diktaten")

        t = Date()
        var cam1: CampPlusEmbedder? = try await CampPlusEmbedder.load()
        _ = try await cam1!.embed(audio: Array(clips.first?.prefix(24000) ?? []) + [Float](repeating: 0.01, count: 24000))
        let s2 = await step("2 CAM++ #1 (VoiceID)", Date().timeIntervalSince(t))
        var cam2: CampPlusEmbedder? = try await CampPlusEmbedder.load()
        _ = try await cam2!.embed(audio: [Float](repeating: 0.01, count: 24000))
        let s3 = await step("3 CAM++ #2 (FastVoiceMask)")
        var cam3: CampPlusEmbedder? = try await CampPlusEmbedder.load()
        _ = try await cam3!.embed(audio: [Float](repeating: 0.01, count: 24000))
        let s4 = await step("4 CAM++ #3 (TrainingEmbedder)")

        t = Date()
        var dia: OfflineDiarizerManager? = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await dia!.prepareModels()
        let s5 = await step("5 Diarizer (pyannote+VBx) vorbereitet", Date().timeIntervalSince(t))
        var s6 = s5
        if let mp = meetingPath {
            let base = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: mp))
            var long: [Float] = []
            while long.count < 16000 * 600 { long += base }   // ~10 min Meeting nachbilden
            t = Date()
            let r = try await dia!.process(audio: long)
            s6 = await step("6 Diarisiert (\(long.count / 16000 / 60) min, \(Set(r.segments.map(\.speakerId)).count) Sprecher)", Date().timeIntervalSince(t))
            long = []
            _ = r
            // Parakeet auf 10 min (so macht es die Meeting-Auswertung)
            t = Date()
            var d = TdtDecoderState.make(decoderLayers: 2)
            var l2: [Float] = []
            while l2.count < 16000 * 600 { l2 += base }
            _ = try await asr!.transcribe(l2, decoderState: &d)
            l2 = []
            _ = await step("6b Parakeet auf 10 min Meeting-Ton", Date().timeIntervalSince(t))
        }
        dia = nil
        let s7 = await step("7 Diarizer freigegeben")
        cam2 = nil; cam3 = nil
        let s8 = await step("8 CAM++ #2/#3 freigegeben")
        await asr!.cleanup(); asr = nil
        let s9 = await step("9 Parakeet freigegeben (cleanup + nil)")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let s9b = await step("9b … 3 s später")
        cam1 = nil
        let s10 = await step("10 alles freigegeben")

        print("\nKosten je Modell (Footprint+Neural, Differenzen):")
        func d(_ a: Snap, _ b: Snap) -> String { String(format: "%+5.0f MB (Footprint %+5.0f, Neural %+5.0f)", b.totalMB - a.totalMB, b.footprintMB - a.footprintMB, b.neuralMB - a.neuralMB) }
        print("  Parakeet Ultra laden      " + d(s0, s1))
        print("  Parakeet nach Diktaten    " + d(s1, s1b))
        print("  CAM++ #1                  " + d(s1b, s2))
        print("  CAM++ #2                  " + d(s2, s3))
        print("  CAM++ #3                  " + d(s3, s4))
        print("  Diarizer vorbereiten      " + d(s4, s5))
        print("  Diarisieren 10 min        " + d(s5, s6))
        print("  Diarizer freigeben        " + d(s6, s7))
        print("  CAM++ #2/#3 freigeben     " + d(s7, s8))
        print("  Parakeet freigeben        " + d(s8, s9) + " / nach 3 s " + d(s8, s9b))
        print("  CAM++ #1 freigeben        " + d(s9b, s10))
        _ = cam1
    }

    /// Parakeet laden → Diktat → entladen (cleanup + alle Referenzen weg), n Runden. Zeigt, ob der Neural-Speicher frei wird.
    static func reload(n: Int) async throws {
        _ = Settings.shared
        guard let clip = realDictations().first else { print("keine Diktate"); return }
        _ = await step("Start")
        for i in 0..<n {
            let t0 = Date()
            var asr: AsrManager? = AsrManager()
            do {
                let models = try await AsrModels.downloadAndLoad(version: .ultra)
                try await asr!.loadModels(models)
            }
            var st = TdtDecoderState.make(decoderLayers: 2)
            _ = try? await asr!.transcribe([Float](repeating: 0, count: 16000), decoderState: &st)
            let tl = Date().timeIntervalSince(t0)
            let t1 = Date()
            var d = TdtDecoderState.make(decoderLayers: 2)
            _ = try await asr!.transcribe(Transcriber.normalized(clip), decoderState: &d)
            let tf = Date().timeIntervalSince(t1)
            let s = await step(String(format: "Runde %d geladen", i))
            print(String(format: "   Laden+Aufwärmen %.2f s · 1. Diktat %.0f ms", tl, tf * 1000))
            await asr!.cleanup(); asr = nil
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let u = await step("   entladen")
            print(String(format: "   frei geworden: %.0f MB (Footprint %.0f, Neural %.0f)", s.totalMB - u.totalMB, s.footprintMB - u.footprintMB, s.neuralMB - u.neuralMB))
        }
    }

    /// Whisper-Parken wie in der App: Test-Server (eigene PID-Datei), parken, dann „Fn gedrückt“ + Diktat.
    static func whisperIdle() async throws {
        _ = Settings.shared
        let clips = realDictations()
        guard !clips.isEmpty else { print("keine Diktate"); return }
        let w = WhisperEngine.shared
        w.start()
        for _ in 0..<80 where !w.serverUp { try await Task.sleep(nanoseconds: 50_000_000) }
        guard w.serverUp else { print("Server startet nicht"); return }
        var warm: [Int] = []
        for c in clips { let t = Date(); _ = try await w.dictate(c, language: "de"); warm.append(Int(Date().timeIntervalSince(t) * 1000)) }
        print("warm: \(warm) ms, Server-Footprint \(w.serverPID.map { snap($0).description } ?? "?")")
        var cold: [Int] = [], coldPrewarm: [Int] = []
        for c in clips {
            // a) geparkt, Diktat kommt ohne Vorwarnung (schlechtester Fall)
            w.park(reason: "Test"); try await Task.sleep(nanoseconds: 800_000_000)
            precondition(!w.serverUp && w.parked)
            var t = Date(); _ = try await w.dictate(c, language: "de"); cold.append(Int(Date().timeIntervalSince(t) * 1000))
            // b) geparkt, Fn-Druck startet den Server, Diktat kommt nach der Sprechzeit
            w.park(reason: "Test"); try await Task.sleep(nanoseconds: 800_000_000)
            w.noteActivity()
            try await Task.sleep(nanoseconds: UInt64(Double(c.count) / 16000 * 1e9))   // „sprechen“
            t = Date(); _ = try await w.dictate(c, language: "de"); coldPrewarm.append(Int(Date().timeIntervalSince(t) * 1000))
        }
        print("geparkt, ohne Vorwarmen: \(cold) ms")
        print("geparkt, Fn wärmt vor:   \(coldPrewarm) ms (nach dem Loslassen)")
        print("Laufzeiten der Diktate: \(clips.map { String(format: "%.1fs", Double($0.count) / 16000) })")
        w.park(reason: "Test")
        try await Task.sleep(nanoseconds: 500_000_000)
        print("geparkt: Server läuft = \(w.serverUp), ready (nutzbar) = \(w.ready)")
        w.stop()
    }

    /// Hub offscreen öffnen, jede Seite zeigen, dann schließen (wie heute: Fenster bleibt) und danach wirklich freigeben.
    static func hub() -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func show(_ n: String) { pump(1.5); print(n.padding(toLength: 44, withPad: " ", startingAt: 0) + snap().description) }
        show("0 ohne Hub")
        var win: NSWindow? = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1320, height: 860), styleMask: [.titled, .closable, .resizable],
                                      backing: .buffered, defer: false)
        win!.isReleasedWhenClosed = false
        win!.contentView = NSHostingView(rootView: VFHubView())
        win!.orderFrontRegardless()
        show("1 Hub offen (Diktat)")
        for sec in VFSection.allCases where sec != .einstellungen {
            VFHub.shared.go(sec)
            for _ in 0..<8 { win!.contentView?.layoutSubtreeIfNeeded(); win!.displayIfNeeded(); pump(0.08) }
        }
        VFHub.shared.go(.diktat)
        show("2 alle \(VFSection.allCases.count - 1) Seiten besucht")
        win!.orderOut(nil)
        show("3 geschlossen, Fenster behalten (heute)")
        win!.contentView = nil
        win = nil
        show("4 Fenster + Inhalt freigegeben")
        return 0
    }

    static func hybridBench(_ args: [String]) async throws {
        _ = Settings.shared
        guard args.count > 2 else { print("Aufruf: --mem-hybrid-bench manifest.json [--modes warm,prewarm,cold]"); return }
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let modes = (opt("--modes") ?? "warm,prewarm,cold").split(separator: ",").map(String.init)
        let clips = try JSONDecoder().decode([EngineBench.Clip].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let conv = AudioConverter()
        var items: [(id: String, s: [Float], clip: EngineBench.Clip?)] = []
        for c in clips { items.append((c.id, try conv.resampleAudioFile(URL(fileURLWithPath: c.file)), c)) }
        for (k, r) in realDictations().enumerated() { items.append(("real\(k)", r, nil)) }
        print("\(clips.count) Testclips + \(items.count - clips.count) echte Diktate")

        HybridRecognizer.parakeet = { try await Transcriber.shared.transcribeScored($0) }
        HybridRecognizer.whisper = { s, ctx, lang in try await WhisperEngine.shared.dictate(Transcriber.normalizedGentle(s), context: ctx, language: lang).text }
        HybridRecognizer.whisperReady = { WhisperEngine.shared.ready }
        HybridRecognizer.learnAliases = false
        try await Transcriber.shared.load()
        let w = WhisperEngine.shared
        w.start()
        for _ in 0..<200 where !w.serverUp { try await Task.sleep(nanoseconds: 50_000_000) }
        guard w.serverUp else { print("Whisper startet nicht"); return }
        for it in items.prefix(3) { _ = await HybridRecognizer.recognize(it.s, context: "") }   // aufwärmen

        func waitParked() async { for _ in 0..<100 where w.serverUp { try? await Task.sleep(nanoseconds: 20_000_000) } }
        for mode in modes {
            var recs: [(id: String, hyp: String, ms: Int, engine: String)] = []
            for it in items {
                if mode != "warm" {
                    w.park(reason: "Bench"); await waitParked()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if mode == "prewarm" {
                        w.noteActivity()
                        try? await Task.sleep(nanoseconds: UInt64(Double(it.s.count) / 16000 * 1e9))   // Sprechzeit
                    }
                } else if !w.serverUp { _ = await w.ensureUp() }
                let r = await HybridRecognizer.recognize(it.s, context: "")
                recs.append((it.id, r.text, r.ms, r.engine))
            }
            var errRules = 0, refN = 0, nameHit = 0, nameN = 0
            for r in recs {
                guard let c = items.first(where: { $0.id == r.id })?.clip else { continue }
                let ref = BenchText.words(c.truth, lang: c.lang)
                let ruled = TextCleaner.applyRules(r.hyp, settings: Settings.shared)
                errRules += VocabTrigger.levenshtein(ref, BenchText.words(ruled, lang: c.lang))
                refN += ref.count
                let (h, n) = BenchText.nameHits(ruled, names: c.names, lang: c.lang)
                nameHit += h; nameN += n
            }
            let lat = recs.filter { !$0.id.hasPrefix("real") }.map(\.ms).sorted()
            let real = recs.filter { $0.id.hasPrefix("real") }.map(\.ms).sorted()
            let wShare = Double(recs.filter { $0.engine.hasPrefix("whisper") }.count) / Double(recs.count)
            print(String(format: "%-8@ WER %.1f %% · Namen %.1f %% · Test p50 %d / p95 %d ms · echte Diktate p50 %d / max %d ms · Whisper-Anteil %.0f %%",
                         mode as NSString, Double(errRules) / Double(max(refN, 1)) * 100, Double(nameHit) / Double(max(nameN, 1)) * 100,
                         EngineBench.pct(lat, 0.5), EngineBench.pct(lat, 0.95), EngineBench.pct(real, 0.5), real.last ?? 0, wShare * 100))
            print("         echte Diktate: \(real) ms")
            let out = URL(fileURLWithPath: args[2]).deletingLastPathComponent().appendingPathComponent("mem-hybrid-\(mode).json")
            let rows = recs.map { ["id": $0.id, "hyp": $0.hyp, "ms": "\($0.ms)", "engine": $0.engine] }
            try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        }
        w.stop()
    }

    static func quantBench(_ args: [String]) async throws {
        _ = Settings.shared
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard args.count > 2, let models = opt("--models")?.split(separator: ",").map(String.init) else {
            print("Aufruf: --mem-quant-bench manifest.json --models a.bin,b.bin"); return
        }
        let clips = try JSONDecoder().decode([EngineBench.Clip].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let conv = AudioConverter()
        var audio: [String: [Float]] = [:]
        for c in clips { audio[c.id] = try conv.resampleAudioFile(URL(fileURLWithPath: c.file)) }
        let real = realDictations()
        try await Transcriber.shared.load()
        var pk: [String: ScoredText] = [:]
        for c in clips { pk[c.id] = try await Transcriber.shared.transcribeScored(audio[c.id]!) }
        var pkReal: [ScoredText] = []
        for r in real { pkReal.append(try await Transcriber.shared.transcribeScored(r)) }
        HybridRecognizer.parakeet = { try await Transcriber.shared.transcribeScored($0) }
        HybridRecognizer.whisperReady = { true }
        HybridRecognizer.learnAliases = false

        func score(_ hyps: [String: String]) -> (wer: Double, names: Double) {
            var e = 0, n = 0, h = 0, nn = 0
            for c in clips {
                let ref = BenchText.words(c.truth, lang: c.lang)
                let ruled = TextCleaner.applyRules(hyps[c.id] ?? "", settings: Settings.shared)
                e += VocabTrigger.levenshtein(ref, BenchText.words(ruled, lang: c.lang)); n += ref.count
                let (a, b) = BenchText.nameHits(ruled, names: c.names, lang: c.lang); h += a; nn += b
            }
            return (Double(e) / Double(max(n, 1)), Double(h) / Double(max(nn, 1)))
        }
        for m in models {
            guard let srv = WhisperServerProcess(model: m, threads: 6), await srv.waitReady() else { print("\(m): Server startet nicht"); continue }
            let cl = srv.client
            for c in clips.prefix(2) { _ = try? await cl.dictate(audio[c.id]!) }
            var hyps: [String: String] = [:], lat: [Int] = [], realLat: [Int] = [], realTexts: [String] = []
            var peak = snap(srv.pid).footprintMB
            for c in clips {
                let r = (try? await cl.dictate(audio[c.id]!, language: HybridRecognizer.languageHint(pk[c.id]!.text))) ?? .init(text: "", ms: -1)
                hyps[c.id] = r.text; lat.append(r.ms)
            }
            peak = max(peak, snap(srv.pid).footprintMB)
            for (k, r) in real.enumerated() {
                let o = (try? await cl.dictate(r, language: HybridRecognizer.languageHint(pkReal[k].text))) ?? .init(text: "", ms: -1)
                realLat.append(o.ms); realTexts.append(o.text)
            }
            // Hybrid mit diesem Whisper
            HybridRecognizer.whisper = { s, ctx, lang in try await cl.dictate(s, context: ctx, language: lang).text }
            var hy: [String: String] = [:], hyLat: [Int] = [], hyReal: [Int] = []
            for c in clips { let r = await HybridRecognizer.recognize(audio[c.id]!, context: ""); hy[c.id] = r.text; hyLat.append(r.ms) }
            for r in real { hyReal.append(await HybridRecognizer.recognize(r, context: "").ms) }
            peak = max(peak, snap(srv.pid).footprintMB)
            let a = score(hyps), b = score(hy)
            lat.sort(); realLat.sort(); hyLat.sort(); hyReal.sort()
            print(String(format: "%@\n   Server-Footprint max %.0f MB\n   Whisper allein: WER %.1f %% · Namen %.1f %% · p50 %d ms · echte Diktate p50 %d ms\n   Hybrid:         WER %.1f %% · Namen %.1f %% · p50 %d ms · echte Diktate p50 %d ms",
                         (m as NSString).lastPathComponent, peak, a.wer * 100, a.names * 100, EngineBench.pct(lat, 0.5), EngineBench.pct(realLat, 0.5),
                         b.wer * 100, b.names * 100, EngineBench.pct(hyLat, 0.5), EngineBench.pct(hyReal, 0.5)))
            for t in realTexts { print("   echt: \(t.prefix(110))") }
            srv.process?.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    static func meetingPeak(_ args: [String]) async throws {
        _ = Settings.shared
        guard args.count > 3 else { print("Aufruf: --mem-meeting-peak andere.wav ich.wav [min]"); return }
        let minutes = Int(args.count > 4 ? args[4] : "") ?? 60
        func tile(_ path: String) throws -> [Float] {
            let b = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
            var out: [Float] = []; out.reserveCapacity(16000 * 60 * minutes)
            while out.count < 16000 * 60 * minutes { out += b }
            return Array(out.prefix(16000 * 60 * minutes))
        }
        try await Transcriber.shared.load()
        let base = await step("Parakeet geladen (wie App-Leerlauf)")
        final class Peak: @unchecked Sendable { var v = 0.0; var run = true }
        let peak = Peak()
        let sampler = Task.detached {
            while peak.run { peak.v = max(peak.v, MemProbe.snap().totalMB); try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        let t0 = Date()
        // Reihenfolge wie MeetingProcessor: „alt“ = beide Spuren vorab laden, sonst Systemton → freigeben → Mikrofon
        let old = args.contains("alt")
        var sys = try tile(args[2])
        var mic: [Float] = old ? try tile(args[3]) : []
        _ = await step("\(minutes) min Ton geladen (\(old ? "beide Spuren" : "Systemton"))")
        let (turns, _) = try await Diarizer.shared.diarize(sys)
        _ = await step("Sprecher getrennt (\(Set(turns.map(\.speaker)).count))")
        _ = try await Transcriber.shared.transcribe(sys).words
        sys = []
        if !old { mic = try tile(args[3]) }
        _ = try await Transcriber.shared.transcribe(mic).words
        mic = []
        peak.run = false
        _ = await sampler.value
        print(String(format: "Auswertung %.0f s · Spitze %.0f MB (+%.0f MB über Leerlauf)", Date().timeIntervalSince(t0), peak.v, peak.v - base.totalMB))
        _ = await step("danach")
        await Diarizer.shared.releaseIfIdle(after: 0)
        _ = await step("Sprechertrennung freigegeben")
        let tt = Date()
        let freed = MemorySaver.trimMalloc()
        _ = await step(String(format: "malloc aufgeräumt (%.0f MB, %.1f ms)", Double(freed) / 1_048_576, Date().timeIntervalSince(tt) * 1000))
        if let p = ProcessInfo.processInfo.environment["VF_MEM_PAUSE"], let sec = Double(p) {
            print("PID \(getpid()) – warte \(Int(sec)) s für vmmap/footprint"); fflush(stdout)
            try? await Task.sleep(nanoseconds: UInt64(sec * 1e9))
        }
    }
}
