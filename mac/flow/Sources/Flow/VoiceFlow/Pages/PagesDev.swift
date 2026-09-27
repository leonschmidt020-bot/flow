import AppKit
import SwiftUI

/// Test- und Sichtprüfung der Seiten ohne laufende App:
///   Flow --pages-test                 → Selbsttest Snippets / Stil / Transforms / Scratchpad
///   Flow --pages-render <ordner>      → jede Seite als PNG (offscreen)
/// Verdrahtung (optional) in CLI.run: `default: return VFPagesDev.run(args)`
enum VFPagesDev {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--pages-test": return selfTest()
        case "--pages-render": return render(dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "vf_pages")
        default: return nil
        }
    }

    // MARK: Selbsttest

    static func selfTest() -> Int32 {
        var fails = 0
        func check(_ name: String, _ got: String?, _ want: String?) {
            let ok = got == want
            if !ok { fails += 1 }
            print("\(ok ? "OK  " : "FAIL") \(name)\n      → \(got ?? "nil")\(ok ? "" : "\n      erwartet: \(want ?? "nil")")")
        }

        print("— Snippets —")
        let mail = "vorname@beispiel.de"
        let sn = SnippetStore(testing: [Snippet(trigger: "meine E-Mail", text: mail)] + SnippetStore.seed
                                + [Snippet(trigger: "meine Adresse", text: "Musterstraße 1, 12345 Musterstadt")])
        check("ganzes Diktat", sn.expand("Meine E-Mail."), mail)
        check("ganzes Diktat, andere Schreibweise", sn.expand("meine email"), mail)
        check("ganzes Diktat, Leerzeichen", sn.expand("  Meine e mail!  "), mail)
        check("„Snippet …“ allein", sn.expand("Snippet meine E-Mail"), mail)
        check("„… einfügen“ allein", sn.expand("Meine E-Mail einfügen."), mail)
        check("eingebettet: Snippet", sn.expand("Schreib mir an Snippet meine E-Mail, danke."), "Schreib mir an \(mail), danke.")
        check("eingebettet: einfügen", sn.expand("Meine Adresse ist meine Adresse einfügen."), "Meine Adresse ist Musterstraße 1, 12345 Musterstadt.")
        check("eingebettet: füge … ein", sn.expand("Hier füge meine E-Mail ein bitte"), "Hier \(mail) bitte")
        check("normaler Satz bleibt", sn.expand("Schick mir deine E-Mail."), "Schick mir deine E-Mail.")
        check("Auslöser ohne Befehl im Satz bleibt", sn.expand("Das ist meine E-Mail von gestern."), "Das ist meine E-Mail von gestern.")
        check("Prompt-Snippet", sn.expand("Gedanken ordnen"), SnippetStore.seed[0].text)
        check("Sonderzeichen im Text ($)", SnippetStore(testing: [Snippet(trigger: "Preis", text: "$5 \\1")]).expand("Snippet Preis"), "$5 \\1")

        print("\n— Stil —")
        let hey = "Hey, hast du morgen Zeit zum Mittagessen? Sagen wir 12, wenn’s passt."
        check("formell", StyleStore.transform(hey, .formal), hey)
        check("locker", StyleStore.transform(hey, .casual), "Hey hast du morgen Zeit zum Mittagessen? Sagen wir 12, wenn’s passt")
        check("sehr locker", StyleStore.transform(hey, .veryCasual), "hey hast du morgen Zeit zum Mittagessen? sagen wir 12, wenn’s passt")
        check("aufgeregt", StyleStore.transform("Danke für die Einladung. Ich komme gern.", .excited), "Danke für die Einladung. Ich komme gern!")
        check("URL am Ende bleibt", StyleStore.transform("Schau mal auf https://example.com/a.b.", .casual), "Schau mal auf https://example.com/a.b")
        check("sehr locker: URL am Anfang", StyleStore.transform("https://Example.com ist gut. Probier es.", .veryCasual), "https://Example.com ist gut. probier es")
        check("E-Mail-Adresse bleibt", StyleStore.transform("Schreib an alex.muster@example.org.", .veryCasual), "schreib an alex.muster@example.org")
        check("Domain bleibt", StyleStore.transform("Claude.ai ist offen.", .veryCasual), "Claude.ai ist offen")
        check("Code bleibt", StyleStore.transform("Nutze `Foo.Bar()`.", .veryCasual), "nutze `Foo.Bar()`")
        check("Abkürzung am Ende bleibt", StyleStore.transform("Äpfel, Birnen usw.", .casual), "Äpfel, Birnen usw.")
        check("Akronym am Satzanfang bleibt", StyleStore.transform("KiTaNet ist toll. ID prüfen.", .veryCasual), "KiTaNet ist toll. ID prüfen")
        check("Mehrzeilig", StyleStore.transform("Hallo, Anna.\nWie geht es dir?\nBis bald.", .veryCasual), "hallo Anna\nwie geht es dir?\nbis bald")
        check("Fragezeichen bleibt", StyleStore.transform("Kommst du?", .casual), "Kommst du?")
        check("apply() nach App-Art", StyleStore(testing: ["personal": .veryCasual]).apply("Bis morgen.", category: .personal), "bis morgen")
        check("apply() KI → Sonstiges", StyleStore(testing: ["other": .formal]).apply("Bis morgen.", category: .ai), "Bis morgen.")
        check("apply() E-Mail aufgeregt", StyleStore(testing: ["email": .excited]).apply("Vielen Dank.", category: .email), "Vielen Dank!")

        print("\n— Transforms —")
        let tr = TransformStore(testing: TransformStore.defaults)
        let cases: [(String, String?)] = [
            ("mach das kürzer", "Kürzer fassen"), ("Kannst du das bitte etwas kürzen?", "Kürzer fassen"),
            ("make it shorter", "Kürzer fassen"), ("klingt zu steif, lockerer bitte", "Lockerer"),
            ("weniger förmlich", "Lockerer"), ("professioneller", "Professioneller"),
            ("übersetz das ins Englische", "Auf Englisch"), ("auf Deutsch", "Auf Deutsch"), ("translate to german", "Auf Deutsch"),
            ("korrigier die Rechtschreibung", "Rechtschreibung korrigieren"), ("mach Stichpunkte draus", "Als Stichpunkte"),
            ("als Stichpunktliste", "Als Stichpunkte"), ("mach eine E-Mail daraus", "E-Mail daraus machen"), ("schreib eine Email draus", "E-Mail daraus machen"),
            ("schreib das als Haiku", nil), ("", nil),
        ]
        for (said, want) in cases { check("„\(said)“", tr.match(said)?.name, want) }

        print("\n— Scratchpad —")
        let sp = ScratchpadStore(testing: [], collect: false)
        check("aus → nichts", sp.appendDictation("Hallo") ? "angehängt" : "nein", "nein")
        sp.collectDictations = true
        _ = sp.appendDictation("Erste Idee.")
        _ = sp.appendDictation("Zweite Idee.")
        check("an → neue Notiz + angehängt", sp.current?.text, "Erste Idee.\nZweite Idee.")
        check("Titel", sp.current?.title, "Erste Idee.")

        print("\n\(fails == 0 ? "ALLE TESTS OK" : "\(fails) FEHLER")")
        return fails == 0 ? 0 : 1
    }

    // MARK: Offscreen-Render

    static func render(dir: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        if NSFont(name: "InstrumentSerif-Regular", size: 12) == nil {   // nur für die Sichtprüfung ohne Assets
            let fonts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills/canvas-design/canvas-fonts")
            for f in ["InstrumentSerif-Regular.ttf", "InstrumentSerif-Italic.ttf"] {
                CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(f) as CFURL, .process, nil)
            }
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "vf.pages.bannerHidden.dictionary")

        let demoNotes = [
            ScratchNote(text: "Ideen für die Sommerfreizeit\nLagerfeuer-Abend mit Lobpreis, Geländespiel „Schatzsuche“, Nachtwanderung am Donnerstag.\nMaterial: Fackeln, Seile, Taschenlampen.",
                        created: Date().addingTimeInterval(-3600), updated: Date().addingTimeInterval(-600)),
            ScratchNote(text: "Flow – offene Punkte\nSnippets testen, Stil pro App prüfen.", updated: Date().addingTimeInterval(-86400)),
            ScratchNote(text: "Einkauf\nHafermilch, Äpfel, Kaffee", updated: Date().addingTimeInterval(-3 * 86400)),
        ]
        let size = NSSize(width: 1650, height: 1180)
        let shots: [(String, AnyView, NSSize)] = [
            ("woerterbuch", AnyView(VFDictionaryPage()), size),
            ("snippets", AnyView(VFSnippetsPage()), size),
            ("stil", AnyView(VFStylePage()), size),
            ("stil_email", AnyView(StylePreviewTab(tab: AppCategory.email.rawValue)), size),
            ("stil_aufraeumen", AnyView(StylePreviewTab(tab: "cleanup")), size),
            ("transforms", AnyView(VFTransformsPage()), NSSize(width: 1650, height: 1500)),
            ("scratchpad", AnyView(VFScratchpadPage(store: ScratchpadStore(testing: demoNotes, collect: true))), NSSize(width: 1650, height: 1250)),
            ("einstellungen", AnyView(ModalPreview(section: .general)), size),
            ("einstellungen_system", AnyView(ModalPreview(section: .system)), size),
            ("einstellungen_diktat", AnyView(ModalPreview(section: .dictation)), size),
            ("einstellungen_notetaker", AnyView(ModalPreview(section: .notetaker)), size),
            ("einstellungen_stimme", AnyView(ModalPreview(section: .voice)), size),
            ("einstellungen_pille", AnyView(ModalPreview(section: .pill)), size),
            ("einstellungen_daten", AnyView(ModalPreview(section: .privacy)), size),
        ]
        for (name, view, sz) in shots {
            let host = NSHostingView(rootView: view.frame(width: sz.width, height: sz.height).environment(\.colorScheme, .light))
            host.frame = NSRect(origin: .zero, size: sz)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = (dir as NSString).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print(path)
        }
        return 0
    }
}

/// Stil-Seite direkt auf einem Reiter (nur Vorschau)
private struct StylePreviewTab: View {
    let tab: String
    var body: some View { VFStylePage(tab: tab) }
}

/// Einstellungs-Modal über einer abgedunkelten Seite
private struct ModalPreview: View {
    let section: VFSettingsModal.Section
    var body: some View {
        ZStack {
            VFSnippetsPage()
            Color.black.opacity(0.28)
            VFSettingsModal(section: section) {}.padding(.vertical, 110).padding(.horizontal, 30)
        }
    }
}
