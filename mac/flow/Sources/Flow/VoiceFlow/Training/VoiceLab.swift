import AppKit
import FluidAudio
import Foundation
import SwiftUI

/// Mess-Werkzeuge für Stimmabgleich + Flüstern (nur lesen, schreibt nie in echte Nutzerdaten):
///   Flow --voice-lab detect <wav…>              Flüster-Erkennung pro Datei (+ Zeit)
///   Flow --voice-lab dump <out.json> <wav…>     CAM++-Fingerabdrücke (1,5-s- und 2,5-s-Fenster) + Flüster-Merkmale
enum VoiceLab {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 3, args[1] == "--voice-lab" else { return nil }
        TLog.quiet = true
        let rest = Array(args.dropFirst(3))
        switch args[2] {
        case "detect": return wait { try await detect(rest) }
        case "dump": return wait { try await dump(rest) }
        case "asr": return wait { try await asr(rest) }
        case "adapt-test": return wait { try await adaptTest(rest) }
        case "render": return wait { try await render(rest.first ?? "/tmp/vf-voice-render") }
        default: print("--voice-lab detect|dump"); return 2
        }
    }

    private static func wait(_ body: @escaping () async throws -> Void) -> Int32 {
        _ = NSApplication.shared
        var code: Int32 = 0
        var done = false
        Task { do { try await body() } catch { print("Fehler: \(error)"); code = 1 }; done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }

    static func load(_ path: String) throws -> [Float] { try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path)) }

    private static func detect(_ files: [String]) async throws {
        for f in files {
            let s = try load(f)
            let t0 = Date()
            let a = WhisperDetector.analyze(s)
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "%@ %5.1fs  sprache %4.1fs  stimmhaft %3.0f%%  höhen %.2f  flach %.3f  pegel %5.1f dB  mod %4.1f dB  → %@ (%.2f)  %.1f ms",
                         (f as NSString).lastPathComponent.padding(toLength: 34, withPad: " ", startingAt: 0), Double(s.count) / 16000, a.speechSeconds,
                         a.voicedRatio * 100, a.highRatio, a.flatness, a.speechDB, a.modulationDB, a.isWhisper ? "FLÜSTERN" : "normal", a.score, ms))
        }
    }

    /// Erkennung bei Flüstern: `--voice-lab asr <manifest>` (Zeilen „pfad|referenztext“).
    /// Vergleicht Parakeet allein, bisherigen Hybrid-Weg (Flüster-Weiche aus) und neuen Weg (Flüstern → Whisper + Pegel).
    private static func asr(_ args: [String]) async throws {
        guard let mf = args.first, let txt = try? String(contentsOfFile: mf, encoding: .utf8) else { print("manifest?"); return }
        let items = txt.split(separator: "\n").compactMap { l -> (String, String)? in
            let p = l.split(separator: "|", maxSplits: 1).map(String.init); return p.count == 2 ? (p[0], p[1]) : nil }
        let server = TestWhisperServer()
        guard server.start() else { print("Test-Whisper startet nicht"); return }
        defer { server.stop() }
        let dict = Settings.frozen.dictionary
        let vocab = IsolatedWordBackend.vocabularyPrompt(dict)
        let env = HybridRecognizer.Env(
            parakeet: { try await EngineParakeet.shared.transcribe($0) },
            whisper: { s, ctx, lang in try await server.dictate(s, prompt: vocab + (ctx.isEmpty ? "" : " " + String(ctx.suffix(160))), language: lang) },
            whisperReady: { true }, dictionary: dict, names: NameStore.shared.profiles(), learnAliases: false)
        _ = try? await EngineParakeet.shared.transcribe([Float](repeating: 0, count: 16000))
        if let f = items.first, let s = try? load(f.0) { _ = await HybridRecognizer.recognize(s, context: "", env: env) }
        var rows: [String: [(Double, Int)]] = [:]   // Gruppe/Weg → (WER, ms)
        var words: [String: (Int, Int)] = [:]       // Gruppe/Weg → (Fehler, Referenzwörter)
        func count(_ k: String, _ h: String, _ r: String) {
            let hw = TrainingText.key(h).split(separator: " ").map(String.init), rw = TrainingText.key(r).split(separator: " ").map(String.init)
            let e = VocabTrigger.levenshtein(hw, rw); let o = words[k] ?? (0, 0); words[k] = (o.0 + e, o.1 + rw.count)
        }
        for (path, ref) in items {
            let s = try load(path)
            let group = (path as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? "?"
            let a = WhisperDetector.analyze(s)
            let t0 = Date(); let ps = try? await EngineParakeet.shared.transcribe(s); let p = ps?.text ?? ""; let mp = Int(Date().timeIntervalSince(t0) * 1000)
            if let ps { print(String(format: "     parakeet sicher Ø %.2f, min Wort %.2f, %.1f Wörter/s, gleiche Sprache %@", ps.meanConfidence, ps.minWordConfidence,
                                     Double(ps.words.count) / max(0.5, a.speechSeconds), (LanguageGuard.guessDeEn(p) == LanguageGuard.guessDeEn(ref) ? "ja" : "nein") as NSString)) }
            HybridRecognizer.whisperRouting = false
            let o1 = await HybridRecognizer.recognize(s, context: "", env: env)
            HybridRecognizer.whisperRouting = true
            let o2 = await HybridRecognizer.recognize(s, context: "", env: env)
            let w0 = wer(p, ref), w1 = wer(o1.text, ref), w2 = wer(o2.text, ref)
            count(group + " parakeet", p, ref); count(group + " bisher", o1.text, ref); count(group + " neu", o2.text, ref)
            rows[group + " parakeet", default: []].append((w0, mp))
            rows[group + " bisher", default: []].append((w1, o1.ms))
            rows[group + " neu", default: []].append((w2, o2.ms))
            print(String(format: "%@ %@ gefl.=%@  parakeet %3.0f%% · bisher %3.0f%% (%@, %d ms) · neu %3.0f%% (%@, %d ms)", group as NSString,
                         ((path as NSString).lastPathComponent as NSString), a.isWhisper ? "ja" : "nein", w0 * 100, w1 * 100, o1.engine as NSString, o1.ms,
                         w2 * 100, o2.engine as NSString, o2.ms))
            print("     neu: „\(o2.text.prefix(140))“")
        }
        print("\nGruppe/Weg                     WER (alle Wörter)   ms p50   ms max")
        for k in rows.keys.sorted() {
            let v = rows[k]!
            let ms = v.map(\.1).sorted()
            let w = words[k] ?? (0, 1)
            print(String(format: "%@ %6.1f%% (%d/%d)  %6d  %6d", k.padding(toLength: 30, withPad: " ", startingAt: 0) as NSString,
                         Double(w.0) / Double(max(1, w.1)) * 100, w.0, w.1, ms[ms.count / 2], ms.last ?? 0))
        }
    }

    /// Wortfehlerrate (klein, ohne Satzzeichen)
    static func wer(_ hyp: String, _ ref: String) -> Double {
        let h = TrainingText.key(hyp).split(separator: " ").map(String.init)
        let r = TrainingText.key(ref).split(separator: " ").map(String.init)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(VocabTrigger.levenshtein(h, r)) / Double(r.count)
    }

    /// Anpassung aus Diktaten prüfen (nur in FLOW_HOME-Kopie!): `--voice-lab adapt-test <eigen.wav> <fremd.wav>`
    /// 1) sichere eigene Fenster → nach Korrektur verworfen, 2) ohne Korrektur übernommen, 3) Zurücknehmen,
    /// 4) fremde Fenster als „sicher“ untergeschoben → Drift-Schutz muss ablehnen.
    private static func adaptTest(_ args: [String]) async throws {
        guard args.count >= 2 else { print("adapt-test <eigen.wav> <fremd.wav>"); return }
        let vt = VoiceTrainer.shared
        guard vt.levelsDone > 0 else { print("keine Level"); return }
        if vt.store.cohort.count < 4 { try await vt.prepareImpostors(force: true) }
        func wins(_ f: String) async throws -> [[Float]] { try await TrainingEmbedder.shared.windows(try load(f), win: 24_000, hop: 16_000, limit: 12) }
        let ownV = try await wins(args[0]), foreign = try await wins(args[1])
        func verdict(_ w: [[Float]]) -> FastVoiceMask.Verdict {
            FastVoiceMask.Verdict(windows: w.map { ($0, false, Float(0.8)) }, kind: .mine, seconds: 10)
        }
        let ad = VoiceAdapter.shared
        print("Start: Pool \(vt.store.adaptiveNormal.count), Zurücknehmen möglich: \(vt.canRollback)")
        ad.observe(verdict(ownV))
        ad.dictationCorrected()
        ad.commit(now: Date().addingTimeInterval(400))
        print("1) nach Korrektur: Pool \(vt.store.adaptiveNormal.count) (erwartet unverändert)")
        ad.observe(verdict(ownV))
        ad.commit(now: Date().addingTimeInterval(60))
        print("   zu früh (60 s): Pool \(vt.store.adaptiveNormal.count) (erwartet unverändert)")
        let out = ad.commit(now: Date().addingTimeInterval(400))
        print("   Ergebnis: \(String(describing: out))")
        print("2) ohne Korrektur: Pool \(vt.store.adaptiveNormal.count) (erwartet +4), Zurücknehmen möglich: \(vt.canRollback)")
        let r = vt.rollback()
        print("3) zurückgenommen: \(r), Pool \(vt.store.adaptiveNormal.count)")
        let bad = vt.applyAdaptation(normal: Array(repeating: foreign, count: 4).flatMap { $0 }, whisper: [])
        print("4) fremde Fenster untergeschoben: \(bad) (erwartet abgelehnt), Pool \(vt.store.adaptiveNormal.count)")
        // Stimmabdruck austauschen
        if let d = vt.exportVoiceprint(name: "Test") {
            do { try await vt.importVoiceprint(d); print("5) eigener Abdruck importiert – FEHLER") } catch { print("5) eigener Abdruck → abgelehnt: \(error.localizedDescription)") }
        }
    }

    /// Trainings-Seite + neue Blätter offscreen als PNG (Daten aus FLOW_HOME, nichts wird aufgenommen)
    @MainActor
    private static func render(_ dir: String) async throws {
        VF.registerFonts()
        VoiceAdapter.enabled = false
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func snap<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat? = nil) {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
            host.appearance = NSAppearance(named: .aqua)
            let h = height ?? max(200, host.fittingSize.height)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: h)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
        }
        let vt = VoiceTrainer.shared
        let wbase = FileManager.default.temporaryDirectory.appendingPathComponent("vf-render-words-\(UUID().uuidString)")
        TrainingFiles.secureDir(wbase)
        if let src = ProcessInfo.processInfo.environment["RENDER_WORDS"] {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: wbase.appendingPathComponent("wort-training.json"))
        }
        let wt = WordTrainer(base: wbase, backend: IsolatedWordBackend(server: nil))
        snap("1_training_seite", VFTrainingPage(voice: vt, words: wt).frame(width: 1180, height: 2100), width: 1180, height: 2100)
        let lv = VoiceLevel.level(VoiceLevel.whisperID)!
        let a = LevelSession(level: lv, trainer: vt)
        snap("2_fluestern_bereit", LevelRecordingSheet(session: a, trainer: vt) { _ in }, width: 620)
        let b = LevelSession(level: lv, trainer: vt)
        b.phase = .recording; b.progress = 0.45; b.takeIndex = 1
        b.levels = (0..<48).map { i in Float(0.12 + 0.25 * abs(sin(Double(i) * 0.7))) }
        snap("3_fluestern_aufnahme", LevelRecordingSheet(session: b, trainer: vt) { _ in }, width: 620)
        let b2 = LevelSession(level: lv, trainer: vt)
        b2.phase = .countdown(0); b2.takeIndex = 2
        snap("3b_fluestern_naechster", LevelRecordingSheet(session: b2, trainer: vt) { _ in }, width: 620)
        let c = LevelSession(level: lv, trainer: vt)
        c.result = VoiceTrainer.LevelResult(level: 6, speechSeconds: 8.4, consistency: 0.84, before: max(0, vt.detail.percent - 11), after: vt.detail)
        c.phase = .done
        snap("4_fluestern_fertig", LevelRecordingSheet(session: c, trainer: vt) { _ in }, width: 620)
        let d = LevelSession(level: lv, trainer: vt)
        d.phase = .failed(TrainingError.notWhisper(0.62).errorDescription ?? "")
        snap("4b_fluestern_nicht_gefluestert", LevelRecordingSheet(session: d, trainer: vt) { _ in }, width: 620)
        let o1 = OtherVoiceSession(name: Identity.partnerName ?? "")
        snap("5_andere_stimme_bereit", OtherVoiceSheet(session: o1) {}, width: 620)
        let o2 = OtherVoiceSession(name: "Nico"); o2.phase = .recording; o2.progress = 0.4
        o2.levels = (0..<48).map { i in Float(0.3 + 0.5 * abs(sin(Double(i) * 0.5))) }
        snap("6_andere_stimme_aufnahme", OtherVoiceSheet(session: o2) {}, width: 620)
        let o3 = OtherVoiceSession(name: "Nico"); o3.phase = .done("Nico")
        snap("7_andere_stimme_fertig", OtherVoiceSheet(session: o3) {}, width: 620)
        let word = wt.store.words.keys.sorted().first ?? "Pierre"
        let w = WordSession(word: word, trainer: wt); w.whisper = true
        snap("8_fluester_woerter_start", WordTrainingSheet(session: w) {}, width: 580)
        let w2 = WordSession(word: word, trainer: wt); w2.whisper = true; w2.phase = .listening; w2.takeCount = 2
        w2.levels = (0..<32).map { i in Float(i > 18 && i < 27 ? 0.35 + 0.1 * sin(Double(i)) : 0.05) }
        snap("9_fluester_woerter_aufnahme", WordTrainingSheet(session: w2) {}, width: 580)
        _ = VFNotify.renderPNG(WhisperHint.notice, to: out.appendingPathComponent("10_hinweis_fluestern.png"))
        print("PNG → \(out.path)")
    }

    private static func dump(_ args: [String]) async throws {
        guard let out = args.first else { return }
        let e = try await CampPlusEmbedder.load()
        var files: [[String: Any]] = []
        let t0 = Date()
        var nEmb = 0
        for f in args.dropFirst() {
            let s = try load(f)
            var w15: [[String: Any]] = []
            var st = 0
            let win = 24_000, hop = 8_000
            if s.count < win {
                let v = try await e.embed(audio: s)
                let a = WhisperDetector.analyze(s)
                w15.append(["t": 0, "len": s.count, "emb": v, "whisper": a.isWhisper, "voiced": a.voicedRatio,
                            "sound": EchoFilter.hasSound(s), "db": a.speechDB])
                nEmb += 1
            }
            while st + win <= s.count {
                let chunk = Array(s[st..<(st + win)])
                let a = WhisperDetector.analyze(chunk)
                let snd = EchoFilter.hasSound(chunk)
                if snd || a.speechSeconds >= 0.4 {
                    let v = try await e.embed(audio: chunk)
                    w15.append(["t": st, "len": win, "emb": v, "whisper": a.isWhisper, "voiced": a.voicedRatio, "sound": snd, "db": a.speechDB])
                    nEmb += 1
                }
                st += hop
            }
            let w25 = try await TrainingEmbedder.shared.windows(s, limit: 64)
            let whole = try? await VoiceID.shared.embedding(of: s)
            let a = WhisperDetector.analyze(s)
            files.append(["path": f, "seconds": Double(s.count) / 16000, "w15": w15, "w25": w25, "whole": whole ?? [],
                          "whisper": a.isWhisper, "voiced": a.voicedRatio, "speech": a.speechSeconds, "db": a.speechDB])
        }
        let d = try JSONSerialization.data(withJSONObject: ["files": files])
        try d.write(to: URL(fileURLWithPath: out))
        print(String(format: "%d Dateien, %d Fenster in %.1f s → %@", files.count, nEmb, Date().timeIntervalSince(t0), out))
    }
}
