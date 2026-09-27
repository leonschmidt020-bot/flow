import AppKit
import SwiftUI

// MARK: - Sichtprüfung: Flow --audio-import-render <ordner>
// Rendert offscreen (nie App-Modus). Echte Datei-Notizen aus FLOW_HOME werden nur gelesen; Demo-Zustände nur im Speicher.

enum AudioImportRender {
    static func run(dir: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        VFStats.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("vf-statistik-render-ai.json")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = URL(fileURLWithPath: dir)
        let store = MeetingStore.shared
        let hub = VFHub.shared
        OnboardingState.hidden = true   // Willkommen-Überlagerung im Testordner nicht zeigen (nichts wird gesichert)
        if VFHub.pageProvider == nil {
            VFHub.pageProvider = { sec in sec == .einstellungen
                ? AnyView(VFSettingsModal(section: .notetaker, onClose: {})) : nil }
        }

        // Echte, fertige Datei-Notiz (aus einem Testlauf) – sonst Demo
        let real = store.meetings.first { $0.app == "Datei" && $0.status == .done && !$0.segments.isEmpty }
        // Demo: laufende Datei + wartende + Fehler
        var running = Meeting(id: "demo-datei-laeuft", title: "Weekly Team-Call", date: Date().addingTimeInterval(-120), app: "Datei")
        running.status = .processing; running.progressNote = "Transkribiere … 42 %"; running.duration = 3612
        var waiting = Meeting(id: "demo-datei-wartet", title: "WhatsApp Sprachnachricht Nico", date: Date().addingTimeInterval(-60), app: "Datei")
        waiting.status = .processing; waiting.progressNote = "Wartet …"; waiting.duration = 84
        store.update(running); store.update(waiting)
        let now = Date()
        AudioImport.shared.previewState(
            live: ["demo-datei-laeuft": .init(fraction: 0.42, label: "Transkribiere … 42 %", started: now.addingTimeInterval(-40), eta: 55),
                   "demo-datei-wartet": .init(fraction: 0, label: "Wartet …", started: now)],
            running: "demo-datei-laeuft", waiting: ["demo-datei-wartet"],
            errors: [.init(fileName: "kaputt.mp3", message: "„kaputt.mp3“ ist beschädigt oder kein Audio – nicht lesbar.")])

        func openNote(_ id: String?, _ tab: HubNoteDetail.Tab) {
            hub.sidebarVisible = true; hub.showSettings = false; hub.section = .notetaker
            HubNotetakerPage.renderOpenedID = id
            HubNoteDetail.renderTab = tab
        }
        var shots: [(String, NSSize, () -> AnyView)] = []
        shots.append(("1_notetaker_ablage_fortschritt", NSSize(width: 1512, height: 949), {
            openNote(nil, .transkript); store.selectedID = "demo-datei-laeuft"; return AnyView(VFHubView())
        }))
        shots.append(("1b_listenzeilen", NSSize(width: 980, height: 330), {
            var done = real ?? running
            if real == nil { done.id = "demo-datei-fertig"; done.status = .done; done.progressNote = nil; done.title = "Interview Kapstadt" }
            var failed = running; failed.id = "demo-datei-abgebrochen"; failed.title = "Predigt Sonntag.m4a"
            failed.status = .failed; failed.progressNote = "Abgebrochen bei 63 % – Rechtsklick → „Neu auswerten“ setzt fort"
            store.update(failed)
            return AnyView(VStack(spacing: 4) {
                HubMeetingRow(meeting: running, selected: true, select: {}, open: {})
                HubMeetingRow(meeting: waiting, selected: false, select: {}, open: {})
                HubMeetingRow(meeting: done, selected: false, select: {}, open: {})
                HubMeetingRow(meeting: failed, selected: false, select: {}, open: {})
            }.padding(30).frame(width: 980).background(VF.panel))
        }))
        shots.append(("2_karte_normal", NSSize(width: 900, height: 470), {
            AnyView(AudioImportCard().padding(30).frame(width: 900).background(VF.panel))
        }))
        // Schmalster Hub (1000 pt Fenster → ~560 pt Spalte): nichts darf abgeschnitten werden
        shots.append(("2b_karte_schmal", NSSize(width: 620, height: 560), {
            AnyView(AudioImportCard().padding(30).frame(width: 620).background(VF.panel))
        }))
        shots.append(("3_karte_datei_darueber", NSSize(width: 900, height: 400), {
            AnyView(AudioImportCard(forceTargeted: true).padding(30).frame(width: 900).background(VF.panel))
        }))
        shots.append(("1c_notetaker_schmal", NSSize(width: 1000, height: 680), {
            openNote(nil, .transkript); store.selectedID = "demo-datei-laeuft"; return AnyView(VFHubView())
        }))
        shots.append(("4_hub_datei_darueber", NSSize(width: 1512, height: 949), {
            openNote(nil, .transkript); return AnyView(VFHubView().overlay(AudioImportDropOverlay()))
        }))
        if let real {
            shots.append(("5a_notiz_datei_zusammenfassung", NSSize(width: 1512, height: 949), {
                openNote(real.id, .zusammenfassung); return AnyView(VFHubView())
            }))
            shots.append(("5b_notiz_datei_transkript", NSSize(width: 1512, height: 949), {
                openNote(real.id, .transkript); return AnyView(VFHubView())
            }))
        }
        if let real {
            // Wie „Transkript öffnen“ aus der Fertig-Karte: Notiz hat eine Zusammenfassung, geöffnet wird trotzdem der Transkript-Reiter
            shots.append(("5d_transkript_oeffnen", NSSize(width: 1512, height: 949), {
                HubNotetakerPage.renderOpenedID = nil
                HubNoteDetail.renderTab = nil
                HubNoteDetail.pendingTab = .transkript
                HubNotetakerPage.pendingOpen = real.id
                hub.sidebarVisible = true; hub.showSettings = false; hub.section = .notetaker
                return AnyView(VFHubView())
            }))
        }
        shots.append(("5c_notiz_datei_laeuft", NSSize(width: 1512, height: 949), {
            var m = running
            m.segments = [Segment(speaker: "S1", start: 0, end: 9, text: "Okay, dann lass uns kurz über das Herbstcamp im Oktober reden."),
                          Segment(speaker: "S2", start: 10, end: 16, text: "Stand heute sind es 64 Kinder, die Warteliste hat noch mal zwölf.")]
            store.update(m)
            openNote(m.id, .transkript); return AnyView(VFHubView())
        }))
        shots.append(("6_einstellungen_audiodateien", NSSize(width: 1512, height: 949), {
            HubNotetakerPage.renderOpenedID = nil
            hub.section = .notetaker; hub.showSettings = true; return AnyView(VFHubView())
        }))
        shots.append(("6b_einstellungen_zeilen", NSSize(width: 900, height: 560), {
            AnyView(VStack(alignment: .leading, spacing: 22) { AudioImportSettingsRows() }
                .padding(34).frame(width: 900, alignment: .leading).background(VF.card))
        }))
        for (name, size, make) in shots {
            let root = make()
            render(root, size: size, to: out.appendingPathComponent("\(name).png"))
            hub.showSettings = false
        }
        // Pille
        let pills: [(String, AudioImportPillOverlay.RenderState)] = [
            ("7a_pille_datei_in_der_naehe", .dragNear), ("7b_pille_datei_darueber", .dragOver),
            ("7b2_pille_rechts_hochkant_darueber", .dragOverRightEdge),
            ("7c_pille_wasser_42_a", .progress(0.42, phase: 0)), ("7c_pille_wasser_42_b", .progress(0.42, phase: 0.9)),
            ("7c_pille_wasser_80", .progress(0.8, phase: 1.7)),
            ("7d_pille_fortschritt_hover", .progressHover(0.42, phase: 0.6)),
            ("7e_pille_hochkant_wasser_30", .progressVertical(0.3, phase: 0.4)),
            ("7e_pille_hochkant_wasser_65", .progressVertical(0.65, phase: 1.3)),
        ]
        for (n, s) in pills {
            let u = out.appendingPathComponent("\(n).png")
            if AudioImportPillOverlay.renderPNG(s, to: u) { print(u.path) }
        }
        // Lupe (4×) für die Wasser-Form auf dem kleinen Strich
        for (n, s) in [("7z_lupe_waagerecht", AudioImportPillOverlay.RenderState.progress(0.42, phase: 0.9)),
                       ("7z_lupe_hochkant", .progressVertical(0.55, phase: 1.3))] {
            let u = out.appendingPathComponent("\(n).png")
            if AudioImportPillOverlay.renderPNG(s, to: u, size: NSSize(width: 110, height: 100), scale: 4) { print(u.path) }
        }
        waterSheet(out: out)
        // Meldungskarten
        let err = VFNotice(id: "audiodatei_fehler", title: "Datei nicht lesbar",
                           text: "„kaputt.mp3“ ist beschädigt oder kein Audio – nicht lesbar.",
                           illustration: "illu_leer", fallbackSymbol: "exclamationmark.triangle.fill",
                           primary: ("Andere Datei wählen …", {}), secondary: ("OK", {}), timeout: 20)
        var cards: [(String, VFNotice)] = [("8a_meldung_fehler", err)]
        if let real, let a = AudioImport.shared.doneNotice(real.id, summarizing: true), let b = AudioImport.shared.doneNotice(real.id, summarizing: false) {
            cards.append(("8b_fertig_sofort", a)); cards.append(("8c_fertig_mit_titel", b))
        }
        var memo = Meeting(id: "demo-memo", title: "SOM Finance-App Rollout", date: Date(), app: "Datei")
        memo.status = .done; memo.duration = 842
        memo.segments = [Segment(speaker: "S1", start: 0, end: 5, text: "x"), Segment(speaker: "S2", start: 6, end: 9, text: "y")]
        memo.summary = "…"
        store.update(memo)
        if var n = AudioImport.shared.doneNotice("demo-memo", summarizing: false) {
            n.title = "Sprachmemo · 14 Min. · 2 Sprecher"
            cards.append(("8d_fertig_sprachmemo", n))
        }
        for (n, card) in cards {
            let u = out.appendingPathComponent("\(n).png")
            if VFNotify.renderPNG(card, to: u) { print(u.path) }
        }
        return 0
    }

    // MARK: Wasser-Lupe: Pegel 5/30/60/95/100 % je Pillen-Form + 12-Bilder-Folge aus einem simulierten Lauf

    static func waterSheet(out: URL) {
        let scale: CGFloat = 4
        let fracs = [0.05, 0.30, 0.60, 0.95, 1.0]
        typealias Make = (Double, Double) -> AudioImportPillOverlay.RenderState
        let kinds: [(String, Make, NSSize)] = [
            ("9a_wasser_hochkant_9x44", { .progressVertical($0, phase: $1) }, NSSize(width: 34, height: 58)),
            ("9b_wasser_waagerecht_44x9", { .progress($0, phase: $1) }, NSSize(width: 60, height: 22)),
            ("9c_wasser_hover_96x26", { .progressHover($0, phase: $1) }, NSSize(width: 112, height: 36)),
        ]
        let labelH: CGFloat = 26
        for (name, make, size) in kinds {
            let cellW = size.width * 2 * scale, cellH = size.height * scale
            let img = NSImage(size: NSSize(width: cellW * CGFloat(fracs.count) + CGFloat(fracs.count - 1) * 8, height: cellH + labelH))
            img.lockFocus()
            NSColor.white.setFill(); NSRect(origin: .zero, size: img.size).fill()
            for (i, f) in fracs.enumerated() {
                let x = CGFloat(i) * (cellW + 8)
                AudioImportPillOverlay.drawRender(make(f, 0.4 + Double(i) * 0.7), size: size, scale: scale, showLabel: false,
                                                  origin: NSPoint(x: x, y: labelH))
                ("\(Int(f * 100)) %" as NSString).draw(at: NSPoint(x: x + 6, y: 5),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
            }
            img.unlockFocus()
            save(img, out.appendingPathComponent("\(name).png"))
        }
        // Simulierter Lauf (Zeiten wie im Log: 866 s Ton, 6 Stücke, Stück ≈ 3–4 s): Echtwerte in Stufen + Schätz-Hinweise
        var events: [(Double, Double, (Double, Double, Double)?)] = []   // (Zeit, Echtwert, Hinweis von/nach/Sekunden)
        events.append((0, 0, nil)); events.append((0.2, 0.01, nil)); events.append((0.4, 0.02, nil))
        for k in 1...10 { events.append((0.4 + Double(k) * 0.29, 0.03 + 0.024 * Double(k), nil)) }
        var tt = 3.4
        let actual = [3.1, 4.4, 3.6, 2.9, 4.0, 2.2]
        for (i, d) in actual.enumerated() {
            let from = 0.28 + 0.68 * Double(i) / 6, to = 0.28 + 0.68 * Double(i + 1) / 6
            events.append((tt, from, (from, to, 150 * 0.025)))
            tt += d
        }
        events.append((tt, 0.97, nil))
        let doneAt = tt + 0.4
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let sm = AudioProgressSmoother()
        var live = AudioImport.Live(fraction: 0, label: "", started: t0)
        var ei = 0
        var trace: [(t: Double, shown: Double, raw: Double, alpha: CGFloat)] = []
        var last = 0.0, maxStep = 0.0, maxAhead = 0.0, backwards = 0
        let fps = 30.0
        let total = doneAt + AudioImportPillOverlay.finishFill + AudioImportPillOverlay.finishHold + AudioImportPillOverlay.finishFade
        var fin: Double?
        for n in 0...Int(total * fps) {
            let t = Double(n) / fps
            while ei < events.count, events[ei].0 <= t {
                let e = events[ei]
                live.fraction = max(live.fraction, e.1)
                if let h = e.2 { live.hintFrom = h.0; live.hintNext = h.1; live.hintAt = t0.addingTimeInterval(e.0); live.hintSeconds = h.2 }
                ei += 1
            }
            var shown: Double, alpha: CGFloat = 1
            if t < doneAt {
                shown = sm.value("sim", live: live, at: t0.addingTimeInterval(t))
                let chunk = 0.68 / 6
                maxAhead = max(maxAhead, shown - live.fraction)
                if shown > live.fraction + chunk + 1e-9 { print("  ✗ über Echtwert + 1 Stück bei t=\(t)") }
            } else {
                if fin == nil { fin = last }
                guard let st = AudioImportPillOverlay.finishState(from: fin!, elapsed: t - doneAt) else { break }
                shown = st.level; alpha = st.alpha
            }
            if shown < last - 1e-9 { backwards += 1 }
            maxStep = max(maxStep, shown - last)
            last = shown
            trace.append((t, shown, live.fraction, alpha))
        }
        print(String(format: "Wasser-Simulation: %d Bilder @30 fps, größter Schritt/Bild %.2f %%, max. vor Echtwert %.1f %% (1 Stück = %.1f %%), rückwärts %d×",
                     trace.count, maxStep * 100, maxAhead * 100, 0.68 / 6 * 100, backwards))
        // Verlauf als CSV (zum Nachprüfen)
        let csv = "t,angezeigt,echt,alpha\n" + trace.map { String(format: "%.3f,%.4f,%.4f,%.2f", $0.t, $0.shown, $0.raw, $0.alpha) }.joined(separator: "\n")
        try? csv.write(to: out.appendingPathComponent("9z_wasser_verlauf.csv"), atomically: true, encoding: .utf8)
        // 12 Bilder gleichmäßig über den Lauf (inkl. Fertig-Ausklang), hochkant + waagerecht
        let picks = (0..<12).map { trace[min(trace.count - 1, Int(Double($0) / 11 * Double(trace.count - 1)))] }
        for (name, make, size) in [("9d_wasser_folge_hochkant", { (f: Double, p: Double) in AudioImportPillOverlay.RenderState.progressVertical(f, phase: p) }, NSSize(width: 26, height: 56)),
                                   ("9e_wasser_folge_waagerecht", { (f: Double, p: Double) in AudioImportPillOverlay.RenderState.progress(f, phase: p) }, NSSize(width: 56, height: 18))] as [(String, Make, NSSize)] {
            let s2: CGFloat = 3
            let cellW = size.width * s2   // nur dunkler Grund (rechte Hälfte)
            let img = NSImage(size: NSSize(width: cellW * 12 + 11 * 4, height: size.height * s2 + labelH))
            img.lockFocus()
            NSColor.white.setFill(); NSRect(origin: .zero, size: img.size).fill()
            for (i, p) in picks.enumerated() {
                let x = CGFloat(i) * (cellW + 4)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: x, y: labelH, width: cellW, height: size.height * s2)).addClip()
                AudioImportPillOverlay.drawRender(make(p.shown, p.t), size: size, scale: s2, showLabel: false, alpha: p.alpha,
                                                  origin: NSPoint(x: x - cellW, y: labelH))
                NSGraphicsContext.restoreGraphicsState()
                (String(format: "%.1fs", p.t) as NSString).draw(at: NSPoint(x: x + 2, y: 13),
                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.black])
                (String(format: "%d%%", Int((p.shown * 100).rounded())) as NSString).draw(at: NSPoint(x: x + 2, y: 2),
                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.darkGray])
            }
            img.unlockFocus()
            save(img, out.appendingPathComponent("\(name).png"))
        }
        // Listen-Kachel + Balken (SwiftUI) bei 5/30/60/95/100 %
        let rowView = AnyView(VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ForEach(fracs, id: \.self) { f in
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VF.chrome)
                            Image(systemName: "waveform").font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                            AudioImportTileWater(meetingID: "-", renderFraction: f)
                        }
                        .frame(width: 36, height: 36)
                        ZStack(alignment: .leading) {
                            Capsule().fill(AudioWater.surfaceColor.opacity(0.14))
                            AudioWaterFill(fraction: f, axis: .right, time: 0.8)
                        }
                        .frame(width: 110, height: 6)
                        Text("\(Int(f * 100)) %").font(.system(size: 11)).foregroundStyle(VF.muted)
                    }
                }
            }
        }.padding(20).background(VF.panel))
        render(rowView, size: NSSize(width: 720, height: 120), to: out.appendingPathComponent("9f_wasser_liste_kachel_balken.png"), scale: 3)
    }

    static func save(_ img: NSImage, _ url: URL) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print(url.path)
    }

    static func render(_ view: AnyView, size: NSSize, to url: URL, scale: CGFloat) {
        let v = NSHostingView(rootView: view.scaleEffect(scale, anchor: .topLeading).frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading))
        v.frame = NSRect(origin: .zero, size: NSSize(width: size.width * scale, height: size.height * scale))
        let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: v.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = v
        for _ in 0..<6 { v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
        win.close()
    }

    static func render(_ view: AnyView, size: NSSize, to url: URL) {
        let v = NSHostingView(rootView: view)
        v.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = v
        for _ in 0..<6 { v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
        win.close()
    }
}
