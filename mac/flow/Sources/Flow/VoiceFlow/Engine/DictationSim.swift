import FluidAudio
import Foundation

/// „Diktat … gesamt“ nachstellen, ohne App und Mikrofon:
///   Flow --dictation-sim <wav…>
/// Spielt jede Aufnahme in ECHTZEIT ab (0,5-s-Takt wie der chunkTimer), mit denselben Regeln wie DictationController:
/// Stücke ≥ 9 s bis zur Pause laufen während der Aufnahme (Abgleich ‖ Erkennung), Rest < 4 s ans letzte Stück,
/// nach dem Loslassen Rest-Stück bzw. ganzes Diktat. Erkennung = HybridRecognizer (Parakeet → Whisper mit Hinweis,
/// eigener Test-Whisper-Server). Gemessen wird die Zeit ab dem Loslassen bis der Text fertig ist.
///   alt = FastVoiceMask 1.5.3 (ohne Vorlauf) · neu = Sitzung + Vorlauf während der Aufnahme
enum DictationSim {
    static func run(_ args: [String]) async throws {
        TLog.quiet = true
        let files = args.dropFirst(2).filter { $0.hasSuffix(".wav") }
        // --tempo: Tempo-Garantie für diesen Lauf an (nur im Speicher, schreibt nichts)
        if args.contains("--tempo") { TempoGuard.install(); TempoGuard.setForTest(true) }
        guard !files.isEmpty else { print("Aufruf: --dictation-sim <wav…>"); return }
        guard VoiceID.isEnrolled else { print("Kein Stimmprofil"); return }
        let server = TestWhisperServer()
        guard server.start() else { print("Test-Whisper startet nicht"); return }
        defer { server.stop() }
        let dict = Settings.frozen.dictionary
        let vocab = IsolatedWordBackend.vocabularyPrompt(dict)
        // --slow P,W: langsameren Mac nachstellen (gemessene Zeit × P für Parakeet, × W für Whisper; z. B. MacBook Air M4 ≈ 1.45,1.7)
        let slow = args.firstIndex(of: "--slow").flatMap { $0 + 1 < args.count ? args[$0 + 1].split(separator: ",").compactMap { Double($0) } : nil } ?? [1, 1]
        let (fp, fw) = (slow.first ?? 1, slow.count > 1 ? slow[1] : 1)
        func stretch(_ t0: Date, _ f: Double) async { let d = Date().timeIntervalSince(t0) * (f - 1); if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) } }
        let env = HybridRecognizer.Env(
            parakeet: { let t0 = Date(); let r = try await EngineParakeet.shared.transcribe($0); await stretch(t0, fp); return r },
            whisper: { s, ctx, lang in let t0 = Date(); let r = try await server.dictate(s, prompt: vocab + (ctx.isEmpty ? "" : " " + String(ctx.suffix(160))), language: lang); await stretch(t0, fw); return r },
            whisperReady: { true }, dictionary: dict, names: NameStore.shared.profiles(), learnAliases: false)
        await FastVoiceMask.shared.prepare(); await LegacyFastVoiceMask.shared.prepare()
        _ = try? await EngineParakeet.shared.transcribe([Float](repeating: 0, count: 16000))
        // Aufwärmen (erste CAM++-/Whisper-Läufe kompilieren Modelle)
        if let f = files.first, let w = try? AudioConverter().resampleAudioFile(URL(fileURLWithPath: f)) {
            _ = await LegacyFastVoiceMask.shared.mask(w); _ = await FastVoiceMask.shared.mask(w)
            _ = await HybridRecognizer.recognize(w, context: "", env: env)
        }
        var session = 5000
        print("aufnahme".padding(toLength: 28, withPad: " ", startingAt: 0) + " dauer stücke   gesamt alt   gesamt neu   (abgleich nach loslassen alt → neu)")
        for f in files {
            let s = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: f))
            var line = [String]()
            var maskMs = [Int]()
            for variant in 0..<2 {
                session += 1
                let r = await dictate(s, env: env, newMask: variant == 1, session: session)
                line.append(String(format: "%6.2f s", r.total))
                maskMs.append(r.maskAfter)
                if variant == 1 { print(String(format: "%@ %5.1fs  %3d   %@   %@   (%d → %d ms)  %@", ((f as NSString).lastPathComponent).padding(toLength: 28, withPad: " ", startingAt: 0) as NSString,
                                               Double(s.count) / 16000, r.chunks, line[0] as NSString, line[1] as NSString, maskMs[0], maskMs[1], r.engines as NSString)) }
            }
        }
    }

    struct Result { let total: Double; let chunks: Int; let maskAfter: Int; let engines: String }

    private final class Box: @unchecked Sendable { var engines: [String] = []; let lock = NSLock()
        func add(_ e: String) { lock.lock(); engines.append(e); lock.unlock() } }

    /// Ein Diktat in Echtzeit
    private static func dictate(_ s: [Float], env: HybridRecognizer.Env, newMask: Bool, session: Int) async -> Result {
        let box = Box()
        func recognize(_ a: [Float], _ ctx: String) async -> String {
            let o = await HybridRecognizer.recognize(a, context: ctx, env: env)
            box.add(o.engine)
            return o.text
        }
        func mask(_ a: [Float], _ thr: Float, _ offset: Int) async -> VoiceID.MaskResult {
            newMask ? await FastVoiceMask.shared.mask(a, clipThreshold: thr, session: session, offset: offset)
                    : await LegacyFastVoiceMask.shared.mask(a, clipThreshold: thr)
        }
        func processChunk(_ a: [Float], _ ctx: String, _ start: Int) async -> (String, Bool) {
            async let m = mask(a, 0.45, start)
            async let first = recognize(a, ctx)
            let t = await first
            switch await m {
            case .unchanged: return (t, false)
            case .notMe: return (t, true)
            case .masked(let mm, _): return (await recognize(mm, ctx), false)
            }
        }
        var chunkTasks: [Task<(String, Bool), Never>] = []
        var chunkStarts: [Int] = []
        var chunkStart = 0
        func enqueue(_ a: [Float], _ start: Int) {
            chunkStarts.append(start)
            let prev = chunkTasks.last
            chunkTasks.append(Task { let before = await prev?.value; return await processChunk(a, before?.0 ?? "", start) })
        }
        // Aufnahme in Echtzeit, 0,5-s-Takt
        final class PF: @unchecked Sendable { let lock = NSLock(); var from = 0; var busy = false }
        let pf = PF()
        var n = 0
        let tStart = Date()
        while n < s.count {
            n = min(s.count, n + 8000)
            let wakeAt = tStart.addingTimeInterval(Double(n) / 16000)
            let wait = wakeAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            // prefeed (nie zwei gleichzeitig)
            if newMask {
                pf.lock.lock()
                let from = pf.from, busy = pf.busy
                if !busy, n - from >= FastVoiceMask.win { pf.busy = true }
                pf.lock.unlock()
                if !busy, n - from >= FastVoiceMask.win {
                    let seg = Array(s[from..<n])
                    Task {
                        let next = await FastVoiceMask.shared.prefeed(seg, base: from, session: session)
                        pf.lock.lock(); pf.from = next; pf.busy = false; pf.lock.unlock()
                    }
                }
            }
            // checkChunk
            if n - chunkStart >= 16000 * 9 {
                let seg = Array(s[chunkStart..<n])
                var cut = Dictation.findPause(seg, minOffset: 16000 * 8)
                if cut == nil && seg.count > 16000 * 25 { cut = Dictation.quietestPoint(seg, from: 16000 * 18) }
                if let c = cut, c > 16000 { enqueue(Array(seg[..<c]), chunkStart); chunkStart += c }
            }
        }
        // Loslassen (+0,12 s Nachlauf wie finish()); mit --tempo gilt ab hier die Frist der Tempo-Garantie
        let mark = TempoGuard.arm(release: Date())
        defer { TempoGuard.disarm(mark) }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let t0 = Date()
        var streamed: [Task<(String, Bool), Never>] = []
        if !chunkTasks.isEmpty {
            let tailStart = min(chunkStart, s.count)
            if s.count - tailStart < 16000 * 4, let lastStart = chunkStarts.last {
                chunkTasks.removeLast().cancel(); chunkStarts.removeLast()
                enqueue(Array(s[lastStart...]), lastStart)
            } else {
                enqueue(Array(s[tailStart...]), tailStart)
            }
            streamed = chunkTasks
        }
        var maskAfter = 0
        if streamed.isEmpty {
            let tm = Date()
            async let m = mask(s, VoiceID.threshold, 0)
            async let first = recognize(s, "")
            var text = await first
            let mr = await m
            maskAfter = Int(Date().timeIntervalSince(tm) * 1000)
            if case .masked(let mm, _) = mr { text = await recognize(mm, "") }
            _ = text
        } else {
            for t in streamed { _ = await t.value }
            maskAfter = newMask ? (await FastVoiceMask.shared.lastStats?.ms ?? -1) : (await LegacyFastVoiceMask.shared.lastMs)
        }
        let total = Date().timeIntervalSince(t0)
        if newMask { await FastVoiceMask.shared.discard(session: session) }
        return Result(total: total, chunks: max(0, streamed.count), maskAfter: maskAfter, engines: box.engines.suffix(3).joined(separator: ","))
    }
}

