import AppKit
import SwiftUI

// MARK: - Sichtprüfung: Hub-Seiten offscreen als PNG rendern
//   Flow --render-hub <ordner> [demo]     (demo = erfundene Statistik, schreibt NICHTS nach ~/.config/flow)
//   Flow --hub-demo [demo]                (Fenster zum Anklicken, ohne Diktat/Hotkey)

enum HubRender {
    static func run(dir: String, demo: Bool, size: NSSize = NSSize(width: 1512, height: 949)) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        prepare(demo: demo)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hub = VFHub.shared
        let shots: [(String, () -> Void)] = [
            ("1_diktat", { hub.section = .diktat; hub.showSettings = false }),
            ("2_notetaker", { hub.section = .notetaker }),
            ("3_insights", { hub.section = .insights }),
            ("4_hilfe", { hub.section = .hilfe }),
            ("5_woerterbuch_platzhalter", { hub.section = .woerterbuch }),
            ("6_einstellungen_modal", { hub.section = .diktat; hub.showSettings = true }),
            ("6b_einstellungen_klein", { hub.section = .insights; hub.showSettings = true }),
            ("7_insights_stimme", { hub.showSettings = false; hub.section = .insights; HubInsightsPage.defaultTab = .stimme }),
            ("8_ohne_seitenleiste", { hub.section = .notetaker; hub.sidebarVisible = false }),
        ] + noteShots(hub)
        if VFHub.pageProvider == nil {       // Testbild: echte Einstellungen statt Platzhalter
            VFHub.pageProvider = { sec in sec == .einstellungen ? AnyView(VFSettingsModal(onClose: {})) : nil }
        }
        for (name, setup) in shots {
            setup()
            let v = NSHostingView(rootView: VFHubView())
            v.frame = NSRect(origin: .zero, size: (name.hasPrefix("8") || name.hasPrefix("6b")) ? NSSize(width: 1000, height: 680) : size)
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: v.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = v
            for _ in 0..<6 { v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
            win.close()
        }
        return 0
    }

    /// Notiz-Detail: echte Meetings (nur lesen) + erfundene Demo-Meetings (nur im Speicher, nie auf der Platte)
    private static func noteShots(_ hub: VFHub) -> [(String, () -> Void)] {
        let store = MeetingStore.shared
        let real = store.meetings.first { $0.status == .done && !($0.summary ?? "").isEmpty && $0.speakerKeys.count > 1 }
            ?? store.meetings.first { $0.status == .done }
        func open(_ id: String?, _ tab: HubNoteDetail.Tab, ask: Bool = false) {
            hub.sidebarVisible = true; hub.showSettings = false; hub.section = .notetaker
            HubNotetakerPage.renderOpenedID = id
            HubNoteDetail.renderTab = tab
            HubNoteDetail.renderAskOpen = ask
        }
        var shots: [(String, () -> Void)] = []
        if let real {
            shots.append(("9a_notiz_echt_zusammenfassung", { open(real.id, .zusammenfassung) }))
            shots.append(("9b_notiz_echt_transkript", { open(real.id, .transkript) }))
        }
        shots.append(("9c_notiz_demo_live", {
            let m = demoMeeting(recording: true); store.update(m); open(m.id, .transkript, ask: true)
        }))
        shots.append(("9d_notiz_demo_zusammenfassung", {
            let m = demoMeeting(recording: false); store.update(m); open(m.id, .zusammenfassung)
        }))
        shots.append(("9e_notiz_meine_notizen", {
            let m = demoMeeting(recording: false); store.update(m); open(m.id, .notizen)
        }))
        shots.append(("9f_notiz_ohne_zusammenfassung", {
            var m = demoMeeting(recording: false); m.id = "demo-leer"; m.summary = nil; m.title = "Kurzer Anruf"; store.update(m)
            open(m.id, .zusammenfassung)
        }))
        shots.append(("9g_notetaker_liste", { open(nil, .transkript) }))
        return shots
    }

    private static func demoMeeting(recording: Bool) -> Meeting {
        var m = Meeting(id: recording ? "demo-live" : "demo-fertig", title: "Camp-Planung Herbst", date: Date().addingTimeInterval(-1800))
        m.app = "Zoom"
        m.duration = 1740
        m.status = recording ? .recording : .done
        m.speakerNames = ["S1": "Alex", "S2": "Sophie"]
        let lines: [(String, String)] = [
            ("S1", "Okay, dann lass uns kurz über das Camp im Oktober reden. Wie viele Anmeldungen haben wir inzwischen?"),
            ("S2", "Stand heute sind es 64 Kinder. Die Warteliste hat noch mal zwölf."),
            ("S2", "Wir bräuchten also eigentlich einen zweiten Bus."),
            ("me", "Den zweiten Bus kann ich morgen anfragen. Ich schick dir dann die Angebote bis Freitag."),
            ("S1", "Super. Und die Anmeldeseite – ist die fertig?"),
            ("me", "Fast. Es fehlt nur noch die Bestätigungsmail, das mache ich heute Abend."),
            ("S2", "Wer übernimmt eigentlich die Andacht am Samstag? Das ist noch offen, oder?"),
        ]
        var t = 0.0
        m.segments = lines.map { sp, tx in defer { t += 14 }; return Segment(speaker: sp, start: t, end: t + 12, text: tx) }
        if recording {
            m.chat = [ChatMessage(question: "Was habe ich verpasst?",
                                  answer: "**Zuletzt besprochen**\n- 64 Anmeldungen, 12 auf der Warteliste\n- Ein **zweiter Bus** wird gebraucht – du fragst morgen an\n\n**Offen**\n- Wer hält die Andacht am Samstag?"),
                      ChatMessage(question: "Bis wann soll ich die Angebote schicken?", answer: nil)]
        } else {
            m.summary = """
            **Kurzfassung** – Das Camp im Oktober ist mit 64 Anmeldungen fast voll, zwölf Kinder stehen auf der Warteliste. Deshalb wird ein zweiter Bus organisiert; die Anmeldeseite ist bis auf die Bestätigungsmail fertig.

            **Entscheidungen**
            - Zweiter Bus wird angefragt
            - Warteliste bleibt offen bis *15. Oktober*

            **Aufgaben**
            - \(Identity.myName): Busangebote einholen und bis **Freitag** verschicken
            - \(Identity.myName): Bestätigungsmail der Anmeldeseite fertigstellen (heute)
              - Text mit Sophie abstimmen

            **Offene Fragen**
            1. Wer übernimmt die Andacht am Samstag?
            2. Reicht das Budget für den zweiten Bus? Mehr unter [example.com](https://example.com)
            """
        }
        return m
    }

    /// Interaktives Fenster ohne den Rest der App (zum Durchklicken)
    static func demoWindow(demo: Bool) -> Int32 {
        let app = NSApplication.shared
        VF.registerFonts()
        prepare(demo: demo)
        app.setActivationPolicy(.regular)
        VoiceFlowWindow.shared.show()
        app.run()
        return 0
    }

    private static func prepare(demo: Bool) {
        // Render/Demo schreibt die Statistik nie in die echte Datei
        VFStats.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("vf-statistik-render.json")
        try? FileManager.default.removeItem(at: VFStats.fileURL)
        if demo { VFStats.shared.replaceForPreview(demoDays()) }
    }

    private static func demoDays() -> [String: VFDayStats] {
        var out: [String: VFDayStats] = [:]
        var rng = SystemRandomNumberGenerator()
        let cal = Calendar.current
        for back in 0..<150 {
            guard Int.random(in: 0..<10, using: &rng) < 8 || back < 3 else { continue }
            let d = cal.date(byAdding: .day, value: -back, to: Date())!
            var s = VFDayStats()
            s.dictations = Int.random(in: 5...90, using: &rng)
            s.words = s.dictations * Int.random(in: 20...60, using: &rng)
            s.speakSeconds = Double(s.words) / 160 * 60
            s.categories = ["ai": s.dictations * 3 / 4, "other": s.dictations / 5, "personal": s.dictations / 40,
                            "email": s.dictations / 60, "work": s.dictations / 80]
            s.apps = ["com.anthropic.claudefordesktop": 3, "com.apple.mail": 1, "net.whatsapp.whatsapp": 1, "app\(back % 40)": 1]
            s.dictionaryFixes = s.dictations / 3
            s.wordsCorrected = s.words / 15
            out[VFStats.key(d)] = s
        }
        return out
    }
}
