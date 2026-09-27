import AppKit
import Darwin
import ScreenCaptureKit
import SwiftUI

// MARK: - Test-/Wartungsbefehle Meeting-Kontext
//   --mc-ocr                                   (Kindprozess der Texterkennung, JSON über stdin)
//   --mc-sim [min=60] [speed=1] [keyFrac]      Schlüsselbild-Erkennung offline gegen ein künstliches Meeting (ohne Bildschirm)
//   --mc-fakemeeting <sek> <speed> <t0-datei>  künstliches Meeting-Fenster zeigen (für --mc-live)
//   --mc-live <sek> <titel> [video] [t0-datei] echtes Mitschneiden eines Fensters, misst CPU/RAM/Bilder/OCR  (nur mit FLOW_HOME!)
//   --mc-summary <meeting-id>                  Zusammenfassung mit Bildern (Claude) ausgeben
//   --mc-package <meeting-id>                  Paket bauen, „Prompt für Agent“ ausgeben
//   --mc-ask <meeting-id> <frage>              Frage-Leiste mit Bildern (Claude)
//   --mc-render <ordner> <meeting-id>          Bilder-Reiter, Großansicht, Leiste, Karte offscreen als PNG

enum MeetingContextCLI {
    static func run(_ args: [String]) -> Int32? {
        let a = Array(args.dropFirst(2))
        switch args[1] {
        case "--mc-ocr": return MCOCR.childMain()
        case "--mc-sim": return sim(a)
        case "--mc-fakemeeting": return fakeMeeting(a)
        case "--mc-live": return guardHome { live(a) }
        case "--mc-summary": return guardHome { summary(a) }
        case "--mc-package": return guardHome {
            guard let id = a.first, let m = MeetingStore.shared.meeting(id) else { print("Meeting fehlt"); return 1 }
            guard let r = try? MeetingContextPackage.build(m) else { print("Fehler"); return 1 }
            print(MeetingContextPackage.agentPrompt(m, r)); return 0
        }
        case "--mc-render": return guardHome { render(a) }
        case "--mc-ask": return guardHome {
            guard a.count >= 2, let m = MeetingStore.shared.meeting(a[0]) else { print("--mc-ask <id> <frage>"); return 2 }
            var done = false
            Task {
                let sys = "Du beantwortest Fragen zu einem Meeting-Transkript. Antworte auf Deutsch, knapp und konkret, zitiere Namen und Zeitstempel wenn hilfreich. Wenn das Transkript die Antwort nicht enthält, sag das."
                let t0 = Date()
                let out = await MeetingVisualSummary.ask(meetingID: m.id, system: sys, input: "Transkript:\n\(m.transcriptText())\n\n\(MeetingContext.askContext(m.id))Frage: \(a[1])")
                print(out ?? "(keine Bilder → ohne Bilder)"); print(String(format: "— %.0f s", Date().timeIntervalSince(t0))); done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return 0
        }
        default: return nil
        }
    }

    /// Tests dürfen nie in ~/.config/flow schreiben (gemeinsamer Schutz des Release-Tors)
    private static func guardHome(_ f: () -> Int32) -> Int32 { SelfTestCLI.guardedHome(f) }

    // MARK: Messwerte des eigenen Prozesses

    struct Usage { var cpu: Double; var footprintMB: Double }
    static func usage() -> Usage {
        var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Usage(cpu: cpu, footprintMB: kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1)
    }
    static func childCPU() -> Double {
        var ru = rusage(); getrusage(RUSAGE_CHILDREN, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    // MARK: Offline-Simulation

    private static func sim(_ a: [String]) -> Int32 {
        let minutes = Double(a.first ?? "") ?? 60
        let speed = a.count > 1 ? Double(a[1]) ?? 1 : 1
        var params = MCChangeDetector.Params()
        if a.count > 2, let k = Double(a[2]) { params.keyFrac = k }
        let dump = a.count > 3 ? a[3] : nil
        _ = NSApplication.shared
        let synth = MCSynthMeeting(duration: minutes * 60, speed: speed)
        let det = MCChangeDetector(params: params)
        let w = 640, h = 400
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return 1 }
        struct Kept { var t: Double; var key: String; var tLast: Double }
        var kept: [Kept] = []
        var replaced = 0
        var detectTime = 0.0
        if let dump { try? FileManager.default.createDirectory(atPath: dump, withIntermediateDirectories: true) }
        let total = Int(minutes * 60)
        for s in 0..<total {
            let t = Double(s)
            synth.render(t: t, frameNo: s, into: ctx, w: CGFloat(w), h: CGFloat(h))
            let th = MCThumb.fromBGRA(ctx.data!, width: w, height: h, bytesPerRow: ctx.bytesPerRow)
            let t0 = Date()
            let d = det.feed(th, t: t)
            detectTime += Date().timeIntervalSince(t0)
            if let r = ProcessInfo.processInfo.environment["MC_TRACE"]?.split(separator: "-").compactMap({ Double($0) }), r.count == 2, t >= r[0], t <= r[1] {
                print(String(format: "%@ %@ vsKey=%.3f maske=%.2f %@", Meeting.stamp(t), synth.span(at: t).key, det.lastChangeVsKey, det.maskedFrac, "\(d)"))
            }
            if case .save(_, let rep, _) = d {
                let key = synth.span(at: t).key
                if rep, !kept.isEmpty { kept[kept.count - 1].key = key; kept[kept.count - 1].tLast = t; replaced += 1 }
                else { kept.append(Kept(t: t, key: key, tLast: t)) }
                if let dump, let img = ctx.makeImage() {
                    _ = MCImageIO.writeJPEG(img, to: URL(fileURLWithPath: dump).appendingPathComponent(String(format: "%03d_%@_%@.jpg", kept.count, MCText.fileStamp(t), key)), quality: 0.7)
                }
            }
        }
        let targets = synth.targets
        let keys = Set(kept.map(\.key))
        let covered = targets.filter { keys.contains($0.key) }
        var dupes = 0
        var seen = Set<String>()
        for k in kept { if seen.contains(k.key) { dupes += 1 }; seen.insert(k.key) }
        let perHour = Double(kept.count) / (minutes / 60)
        print(String(format: "Simuliert %.0f min (Tempo %.1fx, Schwelle %.3f): %d Bilder (%.0f/Std.), %d Aufbau-Stufen ersetzt",
                     minutes, speed, params.keyFrac, kept.count, perHour, replaced))
        print(String(format: "Abdeckung: %d von %d Inhalten (%.0f %%) · doppelt: %d · Galerie-Bilder: %d · Scroll-Zwischenbilder: %d · Code-Tippstände: %d",
                     covered.count, targets.count, 100 * Double(covered.count) / Double(max(1, targets.count)), dupes,
                     kept.filter { $0.key == "gallery" }.count, kept.filter { $0.key == "doc-scroll" }.count, kept.filter { $0.key == "code-typing" }.count))
        let missed = targets.filter { !keys.contains($0.key) }
        if !missed.isEmpty { print("Verpasst: " + missed.map { "\($0.key) (\(Int($0.t1 - $0.t0)) s)" }.joined(separator: ", ")) }
        print(String(format: "Erkennung: %.3f ms pro Bild · Video-Maske am Ende %.0f %% des Bilds", detectTime / Double(total) * 1000, det.maskedFrac * 100))
        return 0
    }

    // MARK: Künstliches Meeting-Fenster

    private static func fakeMeeting(_ a: [String]) -> Int32 {
        let secs = Double(a.first ?? "") ?? 300
        let speed = a.count > 1 ? Double(a[1]) ?? 4 : 4
        let t0File = a.count > 2 ? a[2] : nil
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let act = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Test-Meeting")
        defer { ProcessInfo.processInfo.endActivity(act) }
        let synth = MCSynthMeeting(duration: secs * speed + 60, speed: speed)
        let size = NSSize(width: 1280, height: 800)
        let scr = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 900)
        let win = NSWindow(contentRect: NSRect(x: scr.minX + 20, y: scr.minY + 20, width: size.width, height: size.height),
                           styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        win.title = "Zoom-Meeting (Test)"
        let iv = NSImageView(frame: NSRect(origin: .zero, size: size))
        iv.imageScaling = .scaleAxesIndependently
        win.contentView = iv
        win.orderBack(nil)   // hinter allem – ScreenCaptureKit nimmt das Fenster trotzdem auf
        let start = Date()
        if let f = t0File { try? String(start.timeIntervalSince1970).write(toFile: f, atomically: true, encoding: .utf8) }
        let px = Int(size.width), py = Int(size.height)
        guard let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: px * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return 1 }
        var n = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            let t = Date().timeIntervalSince(start)
            if t > secs { NSApp.terminate(nil) }
            n += 1
            synth.render(t: t, frameNo: n, into: ctx, w: CGFloat(px), h: CGFloat(py))
            if let img = ctx.makeImage() { iv.image = NSImage(cgImage: img, size: size) }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.run()
        return 0
    }

    // MARK: Echtes Mitschneiden (Messung)

    private static func live(_ a: [String]) -> Int32 {
        let secs = Double(a.first ?? "") ?? 120
        let needle = a.count > 1 ? a[1].lowercased() : "zoom-meeting (test)"
        let video = a.contains("video")
        let t0File = a.first { $0.hasSuffix(".t0") }
        let speed = Double(a.first { $0.hasPrefix("speed=") }?.dropFirst(6) ?? "") ?? 4
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { print("Keine Freigabe Bildschirmaufnahme"); return 3 }
        var result: Int32 = 0
        var done = false
        Task {
            defer { done = true }
            let cands = await MCWindowPicker.candidates(meetingApp: nil)
            guard let c = cands.first(where: { $0.title.lowercased().contains(needle) }), let w = await MCWindowPicker.scWindow(c.id) else {
                print("Fenster „\(needle)“ nicht gefunden. Kandidaten: " + cands.prefix(8).map(\.label).joined(separator: " | ")); result = 1; return
            }
            let id = "live-test"
            var m = Meeting(id: id, title: "Live-Test Meeting-Kontext", date: Date(), app: "Zoom")
            m.status = .done
            try? FileManager.default.removeItem(at: m.folder)
            MeetingStore.shared.save(m)
            MCStore.shared.forget(id)
            let startedAt = Date()
            let s = MCCaptureSession(meetingID: id, folder: m.folder, startedAt: startedAt, window: w, saveVideo: video)
            let u0 = usage()
            var peak = u0.footprintMB
            var samples: [(Double, Double, Double)] = []
            do { try await s.start() } catch { print("Start fehlgeschlagen: \(error)"); result = 1; return }
            print("Nehme „\(c.label)“ auf (\(Int(w.frame.width))×\(Int(w.frame.height))), \(Int(secs)) s …")
            var last = u0, lastT = Date()
            var momentsAt = (a.first { $0.hasPrefix("moments=") }?.dropFirst(8).split(separator: ",").compactMap { Double($0) }) ?? []
            while Date().timeIntervalSince(startedAt) < secs {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let el = Date().timeIntervalSince(startedAt)
                if let mt = momentsAt.first, el >= mt {
                    momentsAt.removeFirst()
                    let fr = await s.saveMoment(t: el)
                    MCStore.shared.mutate(id) { $0.moments.append(MCMoment(id: "m\(Int(el))", t: el, frame: fr?.id, liveText: "")) }
                    print("★ Moment bei \(Meeting.stamp(el)) → \(fr?.id ?? "kein Bild")")
                }
                let u = usage(), now = Date()
                let cpu = (u.cpu - last.cpu) / now.timeIntervalSince(lastT) * 100
                samples.append((now.timeIntervalSince(startedAt), cpu, u.footprintMB))
                peak = max(peak, u.footprintMB)
                last = u; lastT = now
            }
            let uEnd = usage()
            let wall = Date().timeIntervalSince(startedAt)
            await s.stop()
            let captureCPU = (uEnd.cpu - u0.cpu) / wall * 100
            let ocrT0 = Date(), child0 = childCPU()
            MCOCR.shared.flush()
            await MCOCR.shared.waitIdle(timeout: 300)
            let ocrWall = Date().timeIntervalSince(ocrT0), ocrCPU = childCPU() - child0
            let log = MCStore.shared.log(id)
            // Transkript aus dem Zeitplan (für Zusammenfassung/Paket-Test)
            var mm = m
            mm.duration = wall
            mm.speakerNames = ["S1": "Alex", "S2": "Sophie"]
            if let f = t0File, let t0s = try? String(contentsOfFile: f, encoding: .utf8), let fakeStart = Double(t0s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let synth = MCSynthMeeting(duration: secs * speed + 60, speed: speed)
                let offset = startedAt.timeIntervalSince1970 - fakeStart   // Fenster-Zeit = eigene Zeit + offset
                mm.segments = synth.transcript().compactMap { seg in
                    let st = seg.start - offset; guard st >= 0, st < wall else { return nil }
                    var x = seg; x.start = st; x.end = seg.end - offset; return x
                }
                ocrReport(log, synth: synth, offset: offset, folder: m.folder)
            }
            MeetingStore.shared.save(mm)
            let dirSize = folderSize(m.folder.appendingPathComponent("bilder"))
            print(String(format: "Bilder: %d (+%d Aufbau-Stufen ersetzt) in %.0f s → %.0f/Std. · %.1f MB (%.0f KB/Bild)",
                         log.frames.count, s.replacedCount, wall, Double(log.frames.count) / wall * 3600, Double(dirSize) / 1_048_576,
                         Double(dirSize) / 1024 / Double(max(1, log.frames.count))))
            print(String(format: "CPU Aufnahme (dieser Prozess, gemittelt): %.2f %% eines Kerns · Einzelbilder vom Stream: %d · Takte: %d", captureCPU, s.framesSeen, s.ticks))
            print(String(format: "RAM (phys_footprint): Start %.0f MB · Spitze %.0f MB · Ende %.0f MB", u0.footprintMB, peak, uEnd.footprintMB))
            print("Verlauf (s, CPU %, MB): " + samples.map { String(format: "%.0f/%.1f/%.0f", $0.0, $0.1, $0.2) }.joined(separator: " "))
            print(String(format: "Texterkennung (Kindprozess): %.1f s Wandzeit, %.1f s CPU für %d Bilder", ocrWall, ocrCPU, log.frames.count))
            if video, let v = log.video {
                print(String(format: "Video: %@ %.1f MB (→ %.0f MB/Std.)", v, Double(folderSize(m.folder.appendingPathComponent(v))) / 1_048_576,
                             Double(folderSize(m.folder.appendingPathComponent(v))) / 1_048_576 / wall * 3600))
            }
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return result
    }

    /// OCR-Qualität: erwartete Wörter der Folie (Titel + Punkte) vs. erkannter Text
    private static func ocrReport(_ log: MCLog, synth: MCSynthMeeting, offset: Double, folder: URL) {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        }
        var hit = 0, all = 0
        var lines: [String] = []
        for f in log.frames {
            let sp = synth.span(at: f.tLast + offset)
            var expected: [String] = []
            switch sp.content {
            case .slide(let i, let b):
                let sl = synth.slides[i % synth.slides.count]
                let n = sl.builds > 1 ? max(1, Int(ceil(Double(sl.bullets.count) * Double(b) / Double(sl.builds)))) : sl.bullets.count
                expected = words(sl.title + " " + sl.bullets.prefix(sl.kind == .chart ? sl.bullets.count : n).joined(separator: " "))
            case .code(let n): expected = words(MCSynthMeeting.codeLines.prefix(n).joined(separator: " "))
            case .doc, .gallery: continue
            }
            let got = Set(words(f.ocr ?? ""))
            let h = expected.filter { got.contains($0) }.count
            hit += h; all += expected.count
            lines.append(String(format: "  %@ %@: %d/%d Wörter", Meeting.stamp(f.t), sp.key, h, expected.count))
        }
        print(String(format: "OCR-Qualität (Folien + Code): %d von %d erwarteten Wörtern erkannt (%.1f %%)", hit, all, 100 * Double(hit) / Double(max(all, 1))))
        print(lines.joined(separator: "\n"))
    }

    static func folderSize(_ u: URL) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey])
        var s = 0
        while let f = e?.nextObject() as? URL { s += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return s
    }

    // MARK: Zusammenfassung mit Bildern

    static let baseSystem = """
    Du fasst ein Meeting-Transkript zusammen. Schreibe in der Sprache, die im Meeting überwiegend gesprochen wurde.
    Erste Zeile exakt: TITEL: <kurzer, konkreter Titel, max. 6 Wörter>
    Danach Markdown mit diesen Abschnitten (leere Abschnitte weglassen):
    **Kurzfassung** – 2–3 Sätze.
    **Kernpunkte** – Stichpunkte.
    **Entscheidungen** – Stichpunkte.
    **Aufgaben** – Stichpunkte im Format „Name: Aufgabe (bis wann, falls genannt)“.
    **Offene Fragen** – Stichpunkte.
    Keine Einleitung, keine Floskeln, nichts erfinden.
    """

    private static func summary(_ a: [String]) -> Int32 {
        guard let id = a.first, let m = MeetingStore.shared.meeting(id) else { print("Meeting fehlt"); return 1 }
        var code: Int32 = 0, done = false
        Task {
            let t0 = Date()
            do {
                if let out = try await MeetingVisualSummary.run(meeting: m, system: baseSystem) {
                    print(out)
                    var mm = m
                    var lines = out.components(separatedBy: "\n")
                    if let f = lines.first, f.uppercased().hasPrefix("TITEL:") { mm.title = String(f.dropFirst(6)).trimmingCharacters(in: .whitespaces); lines.removeFirst() }
                    mm.summary = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run { MeetingStore.shared.save(mm) }
                } else { print("keine Bilder"); code = 1 }
            } catch { print("Fehler: \(error.localizedDescription)"); code = 1 }
            print(String(format: "— %.0f s", Date().timeIntervalSince(t0)))
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return code
    }

    // MARK: Sichtprüfung

    private static func render(_ a: [String]) -> Int32 {
        guard a.count >= 2 else { print("--mc-render <ordner> <meeting-id>"); return 2 }
        let dir = URL(fileURLWithPath: a[0])
        let id = a[1]
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let m = MeetingStore.shared.meeting(id) else { print("Meeting fehlt"); return 1 }
        let hub = VFHub.shared
        func shot(_ name: String, size: NSSize = NSSize(width: 1512, height: 949), _ view: AnyView) {
            let v = NSHostingView(rootView: view)
            v.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = v
            for _ in 0..<14 { v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let u = dir.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: u)
            print(u.path)
            win.close()
        }
        func openNote(_ tab: HubNoteDetail.Tab) {
            hub.sidebarVisible = true; hub.showSettings = false; hub.section = .notetaker
            HubNotetakerPage.renderOpenedID = id
            HubNoteDetail.renderTab = tab
        }
        openNote(.bilder)
        shot("mk1_bilder_reiter", AnyView(VFHubView()))
        if let f = MCStore.shared.log(id).frames.dropFirst(3).first {
            HubNoteFrames.renderOpenFrame = f.id
            shot("mk2_grossansicht", AnyView(VFHubView()))
            HubNoteFrames.renderOpenFrame = nil
        }
        openNote(.zusammenfassung)
        shot("mk3_zusammenfassung", AnyView(VFHubView()))
        // Live-Leiste allein (während der Aufnahme)
        shot("mk4_live_leiste", size: NSSize(width: 860, height: 80),
             AnyView(MCLiveBar(meetingID: id).padding(12).background(VF.panel).environment(\.colorScheme, .light)))
        shot("mk5_einstellungen", size: NSSize(width: 900, height: 520), AnyView(
            VStack(spacing: 0) { MCSettingsCaptureRow(); Divider(); MCSettingsVideoRow(); Divider(); MCSettingsSummaryRow(); Divider(); MCSettingsPermissionRow() }
                .padding(.horizontal, 26).background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.cardSoft)).padding(20)
                .background(VF.panel).environment(\.colorScheme, .light)))
        // Pille im Meeting mit Kamera-Symbol (waagerecht + seitlich) und Toast „Moment gemerkt“
        for (name, vertical, cam, toast) in [("mk7_pille_kamera", false, true, false), ("mk7b_pille_ohne", false, false, false),
                                             ("mk7c_pille_seitlich", true, true, false), ("mk7d_pille_moment", false, true, true), ("mk7e_pille_prompt", false, false, true)] {
            let v = PillView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
            let win = NSWindow(contentRect: NSRect(x: 1000, y: 500, width: 460, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = v
            v.screenRect = .zero
            v.anchor = NSPoint(x: 1230, y: 575)
            v.vertical = vertical
            v.mode = .meeting(start: Date())
            v.cameraOn = cam
            v.level = 0.55
            if toast { v.showToast(name.hasSuffix("prompt") ? "Prompt kopiert ✓" : "★ Moment gemerkt – mit Bildschirmfoto", seconds: 100) }
            if name.hasSuffix("prompt") { v.mode = .idle }
            for _ in 0..<90 { v.tick() }
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            let out = NSImage(size: v.bounds.size)
            out.lockFocus()
            NSGradient(colors: [NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.70, alpha: 1),
                                NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.93, alpha: 1)])!.draw(in: v.bounds, angle: 90)
            rep.draw(in: v.bounds)
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let b = NSBitmapImageRep(data: tiff), let png = b.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png")); print(dir.appendingPathComponent("\(name).png").path)
            }
        }
        // Listenzeile beim Drüberfahren: „Prompt für Agent“ neben „Öffnen“ (Nachbau der Zeile, Hover ist privat)
        shot("mk8_listenzeile_hover", size: NSSize(width: 760, height: 96), AnyView(
            HStack(spacing: 14) {
                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VF.buttonSoft); Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(VF.muted) }
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.title).font(.system(size: 15)).foregroundStyle(VF.ink).lineLimit(1)
                    Text("\(HubFormat.time(m.date)) · \(Int(m.duration / 60)) Min. · Zoom").font(.system(size: 13)).foregroundStyle(VF.muted)
                }
                Spacer(minLength: 8)
                MCAgentButton(meeting: m, compact: true)
                Button("Öffnen") {}.buttonStyle(HubOutlineButton(height: 28)).font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 12).frame(height: 66)
            .background(VF.cardSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(15).background(VF.panel).environment(\.colorScheme, .light)))
        openNote(.transkript)
        shot("mk9_transkript_momente", AnyView(VFHubView()))
        let card = VFNotice.meetingDetectedWithScreen(app: "Zoom", accept: { _ in }, dismiss: {})
        _ = VFNotify.renderPNG(card, to: dir.appendingPathComponent("mk6_karte_meeting_erkannt.png"))
        print(dir.appendingPathComponent("mk6_karte_meeting_erkannt.png").path)
        _ = m
        return 0
    }
}
