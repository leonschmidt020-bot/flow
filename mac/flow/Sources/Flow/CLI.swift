import AppKit
import CoreAudio
import FluidAudio

/// Test- und Wartungsbefehle ohne Oberfläche, z. B.
///   Flow --transcribe datei.wav
///   Flow --clean "ähm ich nehme Käsetoast, nein warte, Dino Nuggets"
///   Flow --render-pill /tmp/pille
///   Flow --diarize meeting.wav
///   Flow --process <meeting-id>
enum CLI {
    static func run(_ args: [String]) -> Int32? {
        let cmd = args[1]
        guard cmd.hasPrefix("--") else { return nil }
        let arg = args.count > 2 ? args[2] : ""
        switch cmd {
        case "--transcribe": return wait { try await transcribe(arg) }
        case "--clean": return wait { await clean(arg) }
        case "--report": print(Diagnose.report()); return 0
        case "--send-report":
            var done = false
            Diagnose.send { print($0); done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return 0
        case "--pill-ring-render": return PillRing.renderPNG(to: URL(fileURLWithPath: arg.isEmpty ? "/tmp/ring.png" : arg)) ? 0 : 1
        case "--update-badge-render":
            // optional „failed“: Fehler-Karte (Update gescheitert/zurückgenommen, „Nochmal versuchen“)
            return UpdateBadge.renderPNG(summary: "Grüner Punkt für Neues vom Partner · Automatische Updates über die Pille · +2 weitere", count: 4,
                                         failed: args.count > 3 && args[3] == "failed",
                                         to: URL(fileURLWithPath: arg.isEmpty ? "/tmp/update.png" : arg)) ? 0 : 1
        case "--shared-inbox-render":
            let now = Date()
            let demo = [SharedVaultItem(id: "a", kind: .text, text: "Kannst du mir bis Freitag die Busangebote schicken? Dann entscheiden wir am Wochenende.", image: nil, fileName: nil, createdBy: "Partner", createdAt: now.addingTimeInterval(-40), pinned: false),
                        SharedVaultItem(id: "b", kind: .link, text: "https://example.com/camp-planung", image: nil, fileName: nil, createdBy: "Partner", createdAt: now.addingTimeInterval(-900), pinned: false),
                        SharedVaultItem(id: "c", kind: .image, text: nil, image: nil, fileName: nil, createdBy: "Partner", createdAt: now.addingTimeInterval(-7300), pinned: false),
                        SharedVaultItem(id: "d", kind: .file, text: nil, image: nil, fileName: "Urlaub-Video.mp4", createdBy: "Partner", createdAt: now.addingTimeInterval(-60), pinned: false, size: 30_421_636)]
            return SharedInboxBadge.renderPNG(items: demo, to: URL(fileURLWithPath: arg.isEmpty ? "/tmp/inbox.png" : arg)) ? 0 : 1
        case "--render-pill": return renderPill(dir: arg)
        case "--diarize": return wait { try await diarize(arg) }
        case "--voicetest": return wait { try await voiceTest(Array(args.dropFirst(2))) }
        case "--enroll": return wait {
            try await VoiceID.shared.enroll(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: arg))); print("eingelernt")
        }
        case "--voicefilter": return wait {
            let smp = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: arg))
            let r = try await Transcriber.shared.transcribe(smp)
            print("ROH:    \(r.text)")
            switch await VoiceID.shared.filterWords(r.words, samples: smp) {
            case .keep(let t, let d): print("BEHALTEN (\(d) Wörter verworfen): \(t)")
            case .notMe(let b): print(String(format: "NICHT DEINE STIMME (bestes %.2f) → nichts eingefügt", b))
            }
        }
        case "--difftest":
            let pairs = CorrectionLearner.replacements(from: args[2], to: args[3]).filter { CorrectionLearner.shouldLearn(old: $0.old, new: $0.new) }
            print(pairs.isEmpty ? "– nichts gelernt" : pairs.map { "„\($0.old)“ → „\($0.new)“" }.joined(separator: ", "))
            return 0
        case "--locatetest":
            // --locatetest "eingefügt" "bildschirmtext"
            // optional: 5. Argument = Bildschirm beim Einfügen (für die Grenzen)
            var pre: [String] = [], post: [String] = []
            if args.count > 4 {
                let w0 = CorrectionLearner.words(args[4]); let l0 = w0.map { CorrectionLearner.bare($0).lowercased() }
                if let f0 = CorrectionLearner.locate(CorrectionLearner.words(args[2]), in: w0) {
                    pre = Array(l0[max(0, f0.lo - 3)..<f0.lo]); post = Array(l0[f0.hi..<min(l0.count, f0.hi + 3)])
                }
            }
            let f = CorrectionLearner.locate(CorrectionLearner.words(args[2]), in: CorrectionLearner.words(args[3]), pre: pre, post: post)
            print(f.map { "Treffer \($0.score): „\($0.words.joined(separator: " "))“" } ?? "kein Treffer")
            if let f { print(CorrectionLearner.replacements(from: args[2], to: f.words.joined(separator: " ")).map { "„\($0.old)“ → „\($0.new)“" }) }
            return 0
        case "--engine-bench": return wait { try await EngineBench.run(args) }
        case "--engine-calibrate": do { try EngineCalibrate.run(args) } catch { print(error) }; return 0
        case "--voicemask-bench": return wait { try await EngineVoiceBench.run(args) }
        case "--mem-probe", "--mem-reload", "--mem-idle-test", "--mem-hub", "--mem-hybrid-bench", "--mem-quant-bench", "--mem-meeting-peak":
            return MemCLI.run(args) ?? 2
        case "--dictation-sim": return wait { try await DictationSim.run(args) }
        case "--mask-edges": return wait { try await MaskEdgeBench.run(args) }
        case "--streamtest": return wait { try await streamTest(arg) }
        case "--make-icon": return makeIcon(arg)
        case "--render-hub": return HubRender.run(dir: arg, demo: args.contains("demo"))
        case "--echotest": return wait { try await echoTest() }
        case "--process": return wait { await MeetingProcessor.process(id: arg); print(MeetingStore.shared.meeting(arg)?.transcriptText() ?? "?") }
        default:
            if let c = MeetingContextCLI.run(args) { return c }
            if let c = OnboardingCLI.run(args) { return c }
            if let c = TrainingCLI.run(args) { return c }
            if let c = SelfTestCLI.run(args) { return c }
            if let c = MouseTargetCLI.run(args) { return c }
            if let c = CVDev.run(args) ?? VFPagesDev.run(args) ?? VFRuntimeCLI.run(args) ?? SmartCLI.run(args) ?? VoiceCommandsCLI.run(args) ?? PartnerVocabCLI.run(args) { return c }
            if let c = QualityCLI.run(args) { return c }
            if let c = AudioImportCLI.run(args) { return c }
            if let c = SpeedCLI.run(args) { return c }
            // Unbekannter Befehl: NIE die App starten (sonst läuft ein zweites Flow mit und fügt alles doppelt ein)
            FileHandle.standardError.write("Unbekannter Befehl: \(cmd)\n".data(using: .utf8)!)
            return 2
        }
    }

    private static func wait(_ body: @escaping () async throws -> Void) -> Int32 {
        var code: Int32 = 0
        var done = false
        Task {
            do { try await body() } catch { print("Fehler: \(error)"); code = 1 }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }

    private static func transcribe(_ path: String) async throws {
        let t0 = Date()
        try await Transcriber.shared.load()
        let load = Date().timeIntervalSince(t0)
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
        let t1 = Date()
        let r = try await Transcriber.shared.transcribe(samples)
        let dt = Date().timeIntervalSince(t1)
        print(String(format: "Laden %.2fs · Audio %.1fs · Erkennung %.3fs", load, Double(samples.count) / 16000, dt))
        print("ROH:    \(r.text)")
        if LanguageGuard.looksForeign(r.text) {
            let t2 = Date()
            let w = WhisperFallback.transcribe(samples, hint: r.text) ?? "–"
            print(String(format: "NICHT DE/EN → Whisper (%.2fs): %@", Date().timeIntervalSince(t2), w))
        }
        print("SAUBER: \(TextCleaner.applyRules(r.text, settings: Settings.shared))")
    }

    private static func clean(_ text: String) async {
        let rules = TextCleaner.applyRules(text, settings: Settings.shared)
        print("REGELN: \(rules)")
        let t0 = Date()
        if let p = await TextCleaner.polish(rules, settings: Settings.shared) {
            print(String(format: "KI (%.1fs): %@", Date().timeIntervalSince(t0), TextCleaner.applyRules(p, settings: Settings.shared)))
        } else {
            print("KI: – (nicht nötig/nicht verfügbar)")
        }
    }

    /// Spielt einen Satz über den MacBook-Lautsprecher und nimmt gleichzeitig das Mikro auf –
    /// einmal ohne, einmal mit Apples Echo-Unterdrückung. Danach Ausgabe zurück auf das alte Gerät.
    private static func echoTest() async throws {
        let old = OutputDevice.current()
        guard let speaker = OutputDevice.builtInSpeaker() else { print("Kein MacBook-Lautsprecher gefunden"); return }
        OutputDevice.set(speaker)
        defer { if let old { OutputDevice.set(old) } }
        try await Transcriber.shared.load()
        let texts = ["Das ist ein Video im Hintergrund, das nicht im Diktat landen soll.",
                     "Und jetzt kommt Musik mit Gesang aus dem Lautsprecher."]
        for (k, vp) in [false, true, true].enumerated() {
            let mic = MicCapture()
            mic.voiceProcessing = vp
            let buf = SampleBuffer(), sysBuf = SampleBuffer()
            mic.onSamples = { buf.append($0) }
            try mic.start(deviceUID: nil)
            let tap = SystemAudioTap()
            try? tap.start { sysBuf.append($0) }
            try await Task.sleep(nanoseconds: 400_000_000)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "Anna", texts[k == 2 ? 1 : 0]]
            try p.run(); p.waitUntilExit()
            try await Task.sleep(nanoseconds: 400_000_000)
            mic.stop(); tap.stop()
            let samples = buf.take(), sys = sysBuf.take()
            let raw = try await Transcriber.shared.transcribe(samples, normalize: !vp).text
            let g = EchoFilter.gate(mic: samples, system: sys)
            let gated = g.speechSeconds > 0.25 ? try await Transcriber.shared.transcribe(g.samples, normalize: false).text : ""
            let sysText = EchoFilter.hasSound(sys) ? try await Transcriber.shared.transcribe(sys).text : ""
            let final = EchoFilter.subtract(dictation: gated, systemText: sysText)
            print("\(vp ? "MIT " : "OHNE") Echo-Unterdr. | roh: „\(raw)“ | gefiltert: „\(gated)“ (\(String(format: "%.2f", g.speechSeconds)) s Sprache) | Mac-Ton: „\(sysText)“ | ENDE: „\(final)“")
        }
    }

    /// --voicetest einlern.wav test1.wav test2.wav … → Ähnlichkeit jedes Tests zum eingelernten Profil
    private static func voiceTest(_ files: [String]) async throws {
        guard let enrollF = files.first else { return }
        let conv = AudioConverter()
        let enroll = try conv.resampleAudioFile(URL(fileURLWithPath: enrollF))
        let prof = try await VoiceID.shared.embedding(of: enroll)
        for f in files.dropFirst() {
            let s = try conv.resampleAudioFile(URL(fileURLWithPath: f))
            let whole = try await VoiceID.shared.embedding(of: s)
            let track = try await VoiceID.shared.similarityTrack(s, profile: prof)
            print(String(format: "%@: gesamt %.2f · Fenster %@", (f as NSString).lastPathComponent, CampPlusEmbedder.cosine(whole, prof),
                         track.map { String(format: "%.1fs=%.2f", $0.t, $0.sim) }.joined(separator: " ")))
        }
    }

    /// Simuliert ein langes Diktat in Echtzeit: Stücke bei Pausen vorab erkennen, am Ende nur den Rest.
    private static func streamTest(_ path: String) async throws {
        WhisperEngine.shared.start()
        for _ in 0..<40 where !WhisperEngine.shared.ready { try await Task.sleep(nanoseconds: 250_000_000) }
        let all = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
        print(String(format: "Audio %.1f s", Double(all.count) / 16000))
        // Ohne Vorab-Erkennung
        var t0 = Date()
        let whole = try await WhisperEngine.shared.dictate(all).text
        print(String(format: "OHNE Vorab-Erkennung: %.2f s nach dem Loslassen", Date().timeIntervalSince(t0)))
        // Mit: Audio „fließt“ in 0,5-s-Schritten herein (beschleunigt: Stücke laufen parallel zur Simulation)
        var start = 0
        var starts: [Int] = []
        var pending: [Task<String, Never>] = []
        var pos = 0
        while pos < all.count {
            pos = min(all.count, pos + 8000)
            if pos - start >= 16000 * 9, let c = Dictation.findPause(Array(all[start..<pos]), minOffset: 16000 * 8) {
                starts.append(start)
                let chunk = Array(all[start..<(start + c)])
                let prev = pending.last
                pending.append(Task { let ctx = await prev?.value ?? ""; return (try? await WhisperEngine.shared.dictate(chunk, context: ctx).text) ?? "" })
                start += c
            }
            try await Task.sleep(nanoseconds: 500_000_000)   // Echtzeit
        }
        t0 = Date()
        var tail = Array(all[start...])
        if tail.count < 16000 * 4, let ls = starts.last { pending.removeLast(); tail = Array(all[ls...]) }   // kurzer Rest → mit letztem Stück
        let prev = pending.last
        pending.append(Task { let ctx = await prev?.value ?? ""; return (try? await WhisperEngine.shared.dictate(tail, context: ctx).text) ?? "" })
        var parts: [String] = []
        for p in pending { parts.append(await p.value) }
        print(String(format: "MIT Vorab-Erkennung (%d Stücke): %.2f s nach dem Loslassen", pending.count, Date().timeIntervalSince(t0)))
        print("GANZ:   \(whole.prefix(220))")
        print("STÜCKE: \(parts.joined(separator: " ").prefix(220))")
    }

    private static func diarize(_ path: String) async throws {
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
        let t0 = Date()
        let (turns, emb) = try await Diarizer.shared.diarize(samples)
        print(String(format: "%.1fs Audio in %.1fs, %d Abschnitte, %d Sprecher", Double(samples.count) / 16000,
                     Date().timeIntervalSince(t0), turns.count, emb.count))
        for t in turns.prefix(40) { print(String(format: "%7.2f–%7.2f  %@", t.start, t.end, t.speaker)) }
        for (k, e) in emb { if let m = VoiceStore.match(e) { print("\(k) ≈ \(m.0) (\(m.1))") } }
    }

    /// App-Icon 1024×1024 (macOS-Raster: Körper 824×824, abgerundet), Motiv = die Pille mit Wellen.
    static func makeIcon(_ path: String) -> Int32 {
        _ = NSApplication.shared
        let size: CGFloat = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
        // Schatten unter dem Körper
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -12); sh.set()
        NSColor.black.setFill(); squircle.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Grundfläche: warmes Graphit
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSGradient(colors: [NSColor(red: 0.23, green: 0.22, blue: 0.21, alpha: 1), NSColor(red: 0.07, green: 0.068, blue: 0.066, alpha: 1)])!
            .draw(in: body, angle: -90)
        // weicher Lichtschein oben
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        // Kapsel
        let pill = NSRect(x: 512 - 300, y: 512 - 118, width: 600, height: 236)
        let pp = NSBezierPath(roundedRect: pill, xRadius: 118, yRadius: 118)
        NSGraphicsContext.saveGraphicsState()
        let ps = NSShadow(); ps.shadowColor = NSColor.black.withAlphaComponent(0.55); ps.shadowBlurRadius = 30; ps.shadowOffset = NSSize(width: 0, height: -10); ps.set()
        NSColor(white: 0.015, alpha: 1).setFill(); pp.fill()
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: pill.insetBy(dx: 3, dy: 3), xRadius: 115, yRadius: 115)
        border.lineWidth = 6; NSColor.white.withAlphaComponent(0.28).setStroke(); border.stroke()
        // Wellen-Balken
        let heights: [CGFloat] = [0.30, 0.52, 0.78, 0.56, 1.0, 0.62, 0.84, 0.5, 0.3]
        let bw: CGFloat = 24, gap: CGFloat = 22, maxH: CGFloat = 150
        let total = CGFloat(heights.count) * bw + CGFloat(heights.count - 1) * gap
        var x = 512 - total / 2
        NSColor.white.setFill()
        for h in heights {
            let bh = max(bw, maxH * h)
            NSBezierPath(roundedRect: NSRect(x: x, y: 512 - bh / 2, width: bw, height: bh), xRadius: bw / 2, yRadius: bw / 2).fill()
            x += bw + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        // feine Kante
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1), xRadius: 185, yRadius: 185)
        edge.lineWidth = 2; NSColor.white.withAlphaComponent(0.10).setStroke(); edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("Icon: \(path)")
        return 0
    }

    /// Rendert alle Zustände der Pille als PNG (zur Sichtprüfung ohne Bildschirm).
    private static func renderPill(dir: String) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, PillView.Mode, Float, Bool)] = [
            ("1_ruhe", .idle, 0, false), ("2_ruhe_hover", .idle, 0, true), ("3_sprechen_leise", .listening, 0.2, false),
            ("4_sprechen_laut", .listening, 0.85, false), ("5_freihand", .handsFree, 0.6, false),
            ("6_verarbeiten", .transcribing, 0, false), ("7_meeting", .meeting(start: Date().addingTimeInterval(-754)), 0.5, false),
            ("8_frage", .prompt("Meeting erkannt · Zoom"), 0, false), ("9_laden", .loading(0.43), 0, false), ("8b_lernen", .question("„ID“ → „Lidl“ merken?", "Speichern"), 0, false),
            ("v1_seite_ruhe", .idle, 0, false), ("v2_seite_sprechen", .listening, 0.85, false), ("v3_seite_freihand", .handsFree, 0.6, false),
            ("v4_seite_meeting", .meeting(start: Date()), 0.6, false),
        ]
        for (name, mode, lv, hover) in states {
            let win = NSWindow(contentRect: NSRect(x: 1000, y: 500, width: 460, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
            let v = PillView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
            win.contentView = v
            v.screenRect = .zero
            v.anchor = NSPoint(x: 1230, y: 575)
            v.vertical = name.hasPrefix("v")
            v.mode = mode
            v.level = lv
            v.setHover(hover)
            if name == "4_sprechen_laut" || name == "v2_seite_sprechen" { v.showToast("In Zwischenablage kopiert", seconds: 100) }
            for _ in 0..<90 { v.tick() }
            // Hintergrund wie ein echter Screenshot (hell/meerblau), damit man die Wirkung sieht
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            let img = NSImage(size: v.bounds.size)
            img.lockFocus()
            NSGradient(colors: [NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.70, alpha: 1),
                                NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.93, alpha: 1)])!.draw(in: v.bounds, angle: 90)
            img.unlockFocus()
            v.cacheDisplay(in: v.bounds, to: rep)
            let out = NSImage(size: v.bounds.size)
            out.lockFocus()
            img.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
            rep.draw(in: v.bounds)
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let b = NSBitmapImageRep(data: tiff), let png = b.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        print("Gerendert nach \(dir)")
        return 0
    }
}

/// Standard-Ausgabegerät lesen/setzen (nur für den Echo-Test).
enum OutputDevice {
    private static var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    static func current() -> AudioDeviceID? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }
    static func set(_ id: AudioDeviceID) {
        var d = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d)
    }
    static func builtInSpeaker() -> AudioDeviceID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        for id in ids {
            var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var t: UInt32 = 0; var ts = UInt32(4)
            AudioObjectGetPropertyData(id, &ta, 0, nil, &ts, &t)
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss)
            if t == kAudioDeviceTransportTypeBuiltIn && ss > 0 { return id }
        }
        return nil
    }
}
