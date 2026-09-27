import FluidAudio
import Foundation

/// Stimmabgleich messen: `Flow --voicemask-bench <ordner-mit-eigenen-wavs> <fremde-stimme.wav> [--whisper]`
///
/// Spalten: VoiceID.mask (alt) · FastVoiceMask 1.5.3 (v1) · neu ohne Vorlauf · neu MIT Vorlauf (Aufnahme wird in
/// 0,5-s-Schritten nachgespielt, gezählt wird nur die Zeit NACH dem Loslassen). Lange Fälle werden wie im Diktat in
/// Stücke geteilt (≥ 9 s bis zur Pause, Rest < 4 s ans letzte Stück) – gemessen wird das Rest-Stück nach dem Loslassen.
/// Bei „gestummt“: zweite Parakeet-Erkennung vs. Wörter aus der ersten Erkennung herausgeschnitten (gleich?).
/// `--whisper`: Abgleich und Whisper gleichzeitig vs. nacheinander (eigener Test-Whisper-Server).
enum EngineVoiceBench {
    static func run(_ args: [String]) async throws {
        guard args.count > 3 else { print("Aufruf: --voicemask-bench <ordner> <fremd.wav> [--whisper]"); return }
        guard VoiceID.isEnrolled else { print("Kein Stimmprofil"); return }
        TLog.quiet = true
        let conv = AudioConverter()
        let dir = args[2]
        let foreign = try conv.resampleAudioFile(URL(fileURLWithPath: args[3]))
        var cases: [(String, [Float])] = []
        var all: [Float] = []
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter({ $0.hasSuffix(".wav") }).sorted() {
            let s = try conv.resampleAudioFile(URL(fileURLWithPath: dir + "/" + f))
            all += s
            let name = String(f.prefix(17))
            cases.append(("eigen \(name) ganz", s))
            if s.count > 16000 * 10 { cases.append(("eigen \(name) 10s", Array(s.prefix(16000 * 10)))) }
            cases.append(("eigen \(name) 3s", Array(s.prefix(16000 * 3))))
            if s.count > 16000 * 6 {
                let mid = s.count / 2
                let ins = Array(foreign.prefix(16000 * 3)).map { $0 * 0.8 }
                cases.append(("eigen+fremd \(name)", Array(s[..<mid]) + ins + Array(s[mid...])))
            }
        }
        // Lange Diktate (Stücke + Rest-Stück): alles hintereinander, und mit fremder Stimme im Rest-Stück
        if all.count > 16000 * 20 {
            let long = Array(all.prefix(16000 * 45))
            cases.append(("eigen lang", long))
            let at = long.count - 16000 * 6
            cases.append(("eigen lang+fremd im Rest", Array(long[..<at]) + Array(foreign.prefix(16000 * 3)).map { $0 * 0.8 } + Array(long[at...])))
        }
        cases.append(("fremd allein", foreign))

        _ = await VoiceID.shared.mask(cases[0].1)
        await FastVoiceMask.shared.prepare(); await LegacyFastVoiceMask.shared.prepare()
        _ = await FastVoiceMask.shared.mask(cases[0].1); _ = await LegacyFastVoiceMask.shared.mask(cases[0].1)
        _ = try? await EngineParakeet.shared.transcribe(Array(cases[0].1.prefix(16000 * 2)))

        func label(_ r: VoiceID.MaskResult) -> String {
            switch r {
            case .unchanged: return "unverändert"
            case .masked(_, let m): return String(format: "gestummt %.1fs", m)
            case .notMe(let b): return String(format: "nicht ich (%.2f)", b)
            }
        }
        func kind(_ r: VoiceID.MaskResult) -> String { String(label(r).prefix(6)) }
        func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

        var session = 1000
        var sum = [0, 0, 0, 0], agreeV1 = 0, agreeCache = 0, agreeOld = 0
        var cutSame = 0, cutTotal = 0
        print("fall".padding(toLength: 30, withPad: " ", startingAt: 0)
              + " dauer  alt   v1  neu  +vorlauf (vorlauf gesamt)  urteil alt | v1 | neu | neu+vorlauf")
        for (name, s) in cases {
            let t0 = Date(); let a = await VoiceID.shared.mask(s); let m0 = ms(t0)
            let t1 = Date(); let b = await LegacyFastVoiceMask.shared.mask(s); let m1 = ms(t1)
            let t2 = Date(); let c = await FastVoiceMask.shared.mask(s); let m2 = ms(t2)
            // Aufnahme nachspielen: alle 0,5 s prefeed mit dem, was es bis dahin gibt
            session += 1
            var from = 0, pre = 0
            var n = 8000
            while n <= s.count {
                let tp = Date()
                from = await FastVoiceMask.shared.prefeed(Array(s[from..<n]), base: from, session: session)
                pre += ms(tp)
                n += 8000
            }
            let t3 = Date(); let d = await FastVoiceMask.shared.mask(s, session: session, offset: 0); let m3 = ms(t3)
            let st = await FastVoiceMask.shared.lastStats
            await FastVoiceMask.shared.discard(session: session)
            sum[0] += m0; sum[1] += m1; sum[2] += m2; sum[3] += m3
            if kind(b) == kind(c) { agreeV1 += 1 }
            if label(c) == label(d) { agreeCache += 1 }
            if kind(a) == kind(d) { agreeOld += 1 }
            print(String(format: "%@ %5.1fs %4d %4d %4d %5d ms (%4d ms, %d/%d Fenster vorab)  %@ | %@ | %@ | %@",
                         name.padding(toLength: 30, withPad: " ", startingAt: 0) as NSString, Double(s.count) / 16000, m0, m1, m2, m3, pre,
                         st?.cached ?? 0, (st?.cached ?? 0) + (st?.computed ?? 0),
                         label(a) as NSString, label(b) as NSString, label(c) as NSString, label(d) as NSString))
            // Gestummt: zweite Erkennung vs. Herausschneiden
            if case .masked(let m, _) = d, let p = try? await EngineParakeet.shared.transcribe(s), p.times.count == p.words.count {
                let words = zip(p.words, p.times).map { TimedWord(word: $0.0.word, start: $0.1.start, end: $0.1.end) }
                let cut = FastVoiceMask.cut(words, muted: FastVoiceMask.mutedSpans(m))
                let tr = Date()
                let again = (try? await EngineParakeet.shared.transcribe(m))?.text ?? ""
                let mr = ms(tr)
                cutTotal += 1
                let same = TrainingText.key(cut) == TrainingText.key(again)
                if same { cutSame += 1 }
                print("   zweite Erkennung (\(mr) ms): „\(again)“")
                print("   herausgeschnitten (0 ms):   „\(cut)“ \(same ? "= gleich" : "≠ anders")")
            }
        }
        print("Summe nach dem Loslassen: alt \(sum[0]) ms · v1 \(sum[1]) ms · neu \(sum[2]) ms · neu+Vorlauf \(sum[3]) ms")
        print("Urteil gleich: v1↔neu \(agreeV1)/\(cases.count) · neu↔neu+Vorlauf \(agreeCache)/\(cases.count) (exakt) · alt↔neu+Vorlauf \(agreeOld)/\(cases.count)")
        if cutTotal > 0 { print("Herausschneiden = zweite Erkennung: \(cutSame)/\(cutTotal)") }

        try await chunked(cases.filter { $0.1.count > 16000 * 12 }, session: &session)

        if args.contains("--whisper") { try await parallel(cases) }

        let e = try await CampPlusEmbedder.load()
        let w = Array(cases[0].1.prefix(24000))
        _ = try await e.embed(audio: w)
        let t = Date(); for _ in 0..<20 { _ = try await e.embed(audio: w) }
        print(String(format: "CAM++ 1,5-s-Fenster: %.1f ms", Date().timeIntervalSince(t) * 1000 / 20))
    }

    /// Wie im Diktat: Stücke ≥ 9 s bis zur Pause laufen während der Aufnahme, das Rest-Stück nach dem Loslassen.
    private static func chunked(_ cases: [(String, [Float])], session: inout Int) async throws {
        guard !cases.isEmpty else { return }
        print("\n== Stücke wie im Diktat: Rest-Stück nach dem Loslassen ==")
        print("fall".padding(toLength: 30, withPad: " ", startingAt: 0) + " stücke rest   v1(ms) neu+vorlauf(ms)  urteil v1 | neu")
        for (name, s) in cases {
            // Schnittstellen wie DictationController.checkChunk
            var starts: [Int] = [], chunkStart = 0
            var n = 8000
            while n <= s.count {
                if n - chunkStart >= 16000 * 9 {
                    let seg = Array(s[chunkStart..<n])
                    var cut = Dictation.findPause(seg, minOffset: 16000 * 8)
                    if cut == nil && seg.count > 16000 * 25 { cut = Dictation.quietestPoint(seg, from: 16000 * 18) }
                    if let c = cut, c > 16000 { starts.append(chunkStart); chunkStart += c }
                }
                n += 8000
            }
            var restStart = chunkStart
            if s.count - chunkStart < 16000 * 4, let last = starts.popLast() { restStart = last }
            let rest = Array(s[restStart...])
            session += 1
            // Vorlauf während der Aufnahme
            var from = 0
            n = 8000
            while n <= s.count {
                from = await FastVoiceMask.shared.prefeed(Array(s[from..<n]), base: from, session: session)
                n += 8000
            }
            // Stücke während der Aufnahme (Urteil mit Speicher)
            var i = 0
            for st in starts {
                let e = i + 1 < starts.count ? starts[i + 1] : restStart
                _ = await FastVoiceMask.shared.mask(Array(s[st..<e]), clipThreshold: 0.45, session: session, offset: st)
                i += 1
            }
            let t1 = Date(); let a = await LegacyFastVoiceMask.shared.mask(rest, clipThreshold: 0.45); let m1 = Int(Date().timeIntervalSince(t1) * 1000)
            let t2 = Date(); let b = await FastVoiceMask.shared.mask(rest, clipThreshold: 0.45, session: session, offset: restStart)
            let m2 = Int(Date().timeIntervalSince(t2) * 1000)
            let st = await FastVoiceMask.shared.lastStats
            await FastVoiceMask.shared.discard(session: session)
            func label(_ r: VoiceID.MaskResult) -> String {
                switch r {
                case .unchanged: return "unverändert"
                case .masked(_, let m): return String(format: "gestummt %.1fs", m)
                case .notMe(let b): return String(format: "nicht ich (%.2f)", b)
                }
            }
            print(String(format: "%@ %5d  %4.1fs  %7d  %7d (%d/%d vorab)   %@ | %@", name.padding(toLength: 30, withPad: " ", startingAt: 0) as NSString,
                         starts.count, Double(rest.count) / 16000, m1, m2, st?.cached ?? 0, (st?.cached ?? 0) + (st?.computed ?? 0),
                         label(a) as NSString, label(b) as NSString))
        }
    }

    /// Abgleich ‖ Whisper: gleichzeitig vs. nacheinander (Test-Whisper-Server, wie im Diktat mit `async let`)
    private static func parallel(_ cases: [(String, [Float])]) async throws {
        let server = TestWhisperServer()
        guard server.start() else { print("Test-Whisper startet nicht"); return }
        defer { server.stop() }
        print("\n== Abgleich ‖ Whisper ==")
        for (name, s) in cases where s.count >= 16000 * 3 && s.count <= 16000 * 30 && name.hasPrefix("eigen") {
            _ = try? await server.transcribe(Array(s.prefix(16000)), language: "de", prompt: nil)
            let t0 = Date()
            _ = await FastVoiceMask.shared.mask(s)
            let mMask = Int(Date().timeIntervalSince(t0) * 1000)
            let t1 = Date()
            _ = try? await server.transcribe(Transcriber.normalizedGentle(s), language: "de", prompt: nil)
            let mW = Int(Date().timeIntervalSince(t1) * 1000)
            let t2 = Date()
            async let m = FastVoiceMask.shared.mask(s)
            async let w = try? server.transcribe(Transcriber.normalizedGentle(s), language: "de", prompt: nil)
            _ = await (m, w)
            let mBoth = Int(Date().timeIntervalSince(t2) * 1000)
            print(String(format: "%@ %5.1fs  Abgleich %4d ms · Whisper %4d ms · nacheinander %4d ms · gleichzeitig %4d ms",
                         name.padding(toLength: 30, withPad: " ", startingAt: 0) as NSString, Double(s.count) / 16000, mMask, mW, mMask + mW, mBoth))
        }
    }
}

/// v1.5.3-Fassung von FastVoiceMask – NUR als Vergleich im `--voicemask-bench`.
/// Schneller Vorab-Check für „Nur meine Stimme“.
/// VoiceID.mask rechnet CAM++ auf 1,5-s-Fenstern alle 0,5 s (bei 10 s Ton ≈ 18 Durchläufe).
/// Sobald Parakeet in ~50 ms fertig ist (HybridRecognizer), wäre DAS der langsamste Schritt.
/// Hier: grobes Raster (1,5-s-Fenster alle 1,0 s ≈ halb so viele CAM++-Durchläufe). Nur rund um verdächtige Fenster
/// (unter 0,45 + `margin`) wird im 0,5-s-Raster des Originals nachgerechnet; Stummschalt-Regeln identisch zu VoiceID.mask.
actor LegacyFastVoiceMask {
    static let shared = LegacyFastVoiceMask()
    private var embedder: CampPlusEmbedder?
    /// Grobes Raster
    var hop = 16_000
    let win = 24_000
    /// Sicherheitsabstand über der Stumm-Schwelle 0,45
    var margin: Float = 0.12

    private func load() async throws -> CampPlusEmbedder {
        if let e = embedder { return e }
        let e = try await CampPlusEmbedder.load()
        embedder = e
        return e
    }

    func prepare() async { _ = try? await load() }

    struct Stats: Sendable { let windows: Int; let minSim: Float; let best: Float; let fast: Bool }
    private(set) var lastStats: Stats?
    /// Dauer des letzten Aufrufs (ms)
    private(set) var lastMs = 0

    func mask(_ samples: [Float], clipThreshold: Float = VoiceID.threshold) async -> VoiceID.MaskResult {
        let t0 = Date()
        defer { lastMs = Int(Date().timeIntervalSince(t0) * 1000) }
        guard let prof = VoiceID.profile(), let e = try? await load() else { return .unchanged }
        var track: [Int: Float] = [:]   // Fensterstart → Ähnlichkeit
        func sim(at s: Int) async -> Float? {
            if let v = track[s] { return v }
            let chunk = Array(samples[s..<(s + win)])
            guard EchoFilter.hasSound(chunk), let v = try? await e.embed(audio: chunk) else { return nil }
            let c = VoiceTrainer.shared.bestSimilarity(to: v)
            track[s] = c
            return c
        }
        if samples.count < win {
            guard let v = try? await e.embed(audio: samples) else { return .unchanged }
            let c = VoiceTrainer.shared.bestSimilarity(to: v)
            lastStats = Stats(windows: 1, minSim: c, best: c, fast: true)
            return c < clipThreshold ? .notMe(bestSim: c) : .unchanged
        }
        // 1) Grobes Raster (auf dem 0,5-s-Raster des Originals, jedes 2. Fenster)
        let fine = 8_000
        var coarse: [Int] = []
        var st = 0
        while st + win <= samples.count { coarse.append(st); st += hop }
        let lastFine = (samples.count - win) / fine * fine
        if let l = coarse.last, l < lastFine { coarse.append(lastFine) }
        var suspicious: [Int] = []
        for s in coarse { if let v = await sim(at: s), v < 0.45 + margin { suspicious.append(s) } }
        // 2) Nur um verdächtige Stellen fein nachrechnen (±1 s, 0,5-s-Raster wie VoiceID)
        for s in suspicious {
            var k = max(0, s - hop)
            while k <= min(lastFine, s + hop) { _ = await sim(at: k); k += fine }
        }
        let pts = track.map { (t: Double($0.key + win / 2) / 16000, sim: $0.value) }.sorted { $0.t < $1.t }
        guard !pts.isEmpty else { lastStats = Stats(windows: 0, minSim: 0, best: 0, fast: true); return .unchanged }
        let best = pts.map(\.sim).max() ?? 0
        lastStats = Stats(windows: pts.count, minSim: pts.map(\.sim).min() ?? 0, best: best, fast: suspicious.isEmpty)
        if best < clipThreshold { return .notMe(bestSim: best) }
        // 3) Stummschalten – gleiche Regeln wie VoiceID.mask (50-ms-Raster, ±0,3 s gemittelt, nur Stücke ≥ 0,6 s unter 0,45)
        let step = 800, n = samples.count / step + 1
        var mute = [Bool](repeating: false, count: n)
        for k in 0..<n {
            let t = Double(k * step) / 16000
            let near = pts.filter { abs($0.t - t) <= 0.3 }.map(\.sim)
            let v = near.isEmpty ? pts.min { abs($0.t - t) < abs($1.t - t) }!.sim : near.reduce(0, +) / Float(near.count)
            mute[k] = v < 0.45
        }
        var runs: [(Int, Int)] = []
        var k = 0
        while k < n {
            if mute[k] { let a = k; while k < n && mute[k] { k += 1 }; if (k - a) * step >= 9600 { runs.append((a, k)) } } else { k += 1 }
        }
        guard !runs.isEmpty else { return .unchanged }
        var out = samples
        var muted = 0
        for (a, b) in runs {
            for j in (a * step)..<min(b * step, out.count) { out[j] = 0 }
            muted += (b - a) * step
        }
        return .masked(out, mutedSeconds: Double(muted) / 16000)
    }
}

/// Rand-Zugabe beim Stummschalten messen: `Flow --mask-edges <eigene-wavs> <fremd.wav…> [--legacy]`
/// Fremde Stimme (3 s, ×0,8) mitten in jedes eigenen Diktat > 6 s. Je Zugabe (0 / 0,25 / 0,5 s):
/// gestummt innerhalb/außerhalb der fremden Stelle, und nach der zweiten Erkennung: verlorene eigene Wörter
/// (gegen Parakeet auf dem Original ohne Einschub) und übrig gebliebene fremde Wörter.
enum MaskEdgeBench {
    static func run(_ args: [String]) async throws {
        TLog.quiet = true
        VoiceAdapter.enabled = false
        let conv = AudioConverter()
        let dir = args[2]
        let foreign = args.dropFirst(3).filter { $0.hasSuffix(".wav") }
        if args.contains("--legacy") {
            FastVoiceMask.scorer = { e, _ in VoiceTrainer.shared.legacySimilarity(to: e) }
            FastVoiceMask.windowFlag = { _ in false }
        }
        await FastVoiceMask.shared.prepare()
        var own: [(String, [Float])] = []
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter({ $0.hasSuffix(".wav") }).sorted() {
            let s = try conv.resampleAudioFile(URL(fileURLWithPath: dir + "/" + f))
            if s.count > 16000 * 6 { own.append((String(f.prefix(17)), Array(s.prefix(16000 * 14)))) }
        }
        func words(_ t: String) -> [String] { TrainingText.key(t).split(separator: " ").map(String.init) }
        func lcs(_ a: [String], _ b: [String]) -> Int {
            var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in 0..<a.count { for j in 0..<b.count { d[i + 1][j + 1] = a[i] == b[j] ? d[i][j] + 1 : max(d[i][j + 1], d[i + 1][j]) } }
            return d[a.count][b.count]
        }
        // Varianten „Zugabe@Randschwelle“, z. B. EDGES="0@0.55,0.25@0.5,0.25@0.55"
        let spec = ProcessInfo.processInfo.environment["EDGES"] ?? "0@0.50,0.25@0.50,0.25@0.55"
        let variants: [(Double, Float)] = spec.split(separator: ",").compactMap { v in
            let p = v.split(separator: "@"); guard p.count == 2, let e = Double(p[0]), let t = Float(p[1]) else { return nil }; return (e, t) }
        let exts = variants.map(\.0)
        var tot = [[Double]](repeating: [0, 0, 0, 0, 0], count: exts.count)   // innen, außen, verloren, rest, fälle
        print("fall".padding(toLength: 44, withPad: " ", startingAt: 0) + " zugabe  gestummt innen/außen  eigene Wörter verloren  fremde Reste")
        for fpath in foreign {
            let fs = Array(try conv.resampleAudioFile(URL(fileURLWithPath: fpath)).prefix(16000 * 3)).map { $0 * 0.8 }
            let fname = ((fpath as NSString).lastPathComponent as NSString).deletingPathExtension
            for (name, s) in own {
                let ref = words((try? await EngineParakeet.shared.transcribe(s))?.text ?? "")
                let mid = s.count / 2
                let mix = Array(s[..<mid]) + fs + Array(s[mid...])
                let ia = Double(mid) / 16000, ib = ia + Double(fs.count) / 16000
                for (ei, e) in exts.enumerated() {
                    FastVoiceMask.edgeExtend = e
                    FastVoiceMask.edgeSim = variants[ei].1
                    let r = await FastVoiceMask.shared.mask(mix)
                    var inside = 0.0, outside = 0.0
                    var hyp: [String]
                    switch r {
                    case .masked(let m, _):
                        for (a, b) in FastVoiceMask.mutedSpans(m) {
                            let i = max(0, min(b, ib) - max(a, ia)); inside += i; outside += (b - a) - i
                        }
                        hyp = words((try? await EngineParakeet.shared.transcribe(m))?.text ?? "")
                    case .unchanged: hyp = words((try? await EngineParakeet.shared.transcribe(mix))?.text ?? "")
                    case .notMe: hyp = []
                    }
                    let common = lcs(ref, hyp)
                    let lost = ref.count - common, rest = hyp.count - common
                    tot[ei][0] += inside; tot[ei][1] += outside; tot[ei][2] += Double(lost); tot[ei][3] += Double(rest); tot[ei][4] += 1
                    print(String(format: "%@ %4.2fs   %4.1fs / %4.1fs          %3d / %3d            %3d", ("\(name)+\(fname)").padding(toLength: 44, withPad: " ", startingAt: 0) as NSString,
                                 e, inside, outside, lost, ref.count, rest))
                }
            }
        }
        print("\nSumme je Zugabe (\(Int(tot[0][4])) Fälle, je 3 s fremde Stimme):")
        for (ei, e) in exts.enumerated() {
            print(String(format: "  Zugabe %.2f s @ %.2f: gestummt innen %.1f s (von %.0f s), außen %.1f s · eigene Wörter verloren %.0f · fremde Reste %.0f",
                         e, variants[ei].1, tot[ei][0], tot[ei][4] * 3, tot[ei][1], tot[ei][2], tot[ei][3]))
        }
        FastVoiceMask.edgeExtend = 0.25; FastVoiceMask.edgeSim = 0.50
    }
}
