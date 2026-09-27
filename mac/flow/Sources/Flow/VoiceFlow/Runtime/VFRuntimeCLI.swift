import AppKit
import ApplicationServices

// MARK: - Flow Runtime: Test-Befehle ohne Oberfläche
//
// Einbinden in CLI.run (default-Zweig):   default: return VFRuntimeCLI.run(args)
//
//   Flow --vf-notify-render <ordner> [bildordner]   alle Meldungs-Voreinstellungen als PNG
//   Flow --vf-notify-demo [sekunden]                 Karten live zeigen (Schlange, unten rechts)
//   Flow --vf-command "mach das kürzer" "Text …"     nur KI-Teil + Plausibilitätsprüfung
//   Flow --vf-command-sanity                         Plausibilitätsprüfung (ohne KI)
//   Flow --vf-command-textedit ["Befehl"]            Ende-zu-Ende in einem NEUEN TextEdit-Dokument
enum VFRuntimeCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        let a2 = args.count > 2 ? args[2] : ""
        switch args[1] {
        case "--vf-notify-render": return renderAll(dir: a2, images: args.count > 3 ? args[3] : nil)
        case "--vf-notify-demo": return demo(seconds: Double(a2) ?? 4)
        case "--vf-command":
            let instr = a2, text = args.count > 3 ? args[3] : ""
            return wait {
                let r = await CommandMode.shared.transform(instruction: instr, text: text)
                print(r)
            }
        case "--vf-command-sanity": return sanity()
        case "--vf-command-textedit":
            CommandMode.shared.debugForceCopy = args.contains("--copy")
            return wait { await textEditTest(instruction: (a2.isEmpty || a2 == "--copy") ? "mach das kürzer" : a2) }
        default: return nil
        }
    }

    private static func wait(_ body: @escaping () async -> Void) -> Int32 {
        var done = false
        Task { await body(); done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return 0
    }

    // MARK: Meldungen

    static let presets: [(String, VFNotice)] = [
        ("1_meeting_erkannt", .meetingDetected(app: "Zoom", accept: {}, dismiss: {})),
        ("2_meeting_vorbei", .meetingOver(app: "Zoom", end: {}, keep: {})),
        ("3_wort_gelernt", .wordLearned(old: "ID", new: "Lidl", save: {}, skip: {})),
        ("3b_wort_auswahl", .wordLearned(old: "auffixen", options: ["auch fixen", "auch", "auf fixen"], save: { _ in }, skip: {})),
        ("4_mikrofon", .micMissing(open: {})),
        ("5_willkommen", .welcome(open: {})),
        ("6_stimme", .voiceEnroll(open: {})),
        ("7_transkript", .transcriptReady(title: "Weekly mit Pierre", open: {})),
        ("8_transkript_scratchpad", .transcriptReady(title: "Notiz", open: {}, illustration: "illu_scratchpad")),
    ]

    private static func renderAll(dir: String, images: String?) -> Int32 {
        let out = URL(fileURLWithPath: dir.isEmpty ? "/tmp/vf-notify" : dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        VF.registerFonts()
        if let images {
            // Test: Illustrationen aus einem anderen Ordner
            VFNotify.imageProvider = { name in
                for ext in ["png", "jpg"] {
                    if let img = NSImage(contentsOfFile: "\(images)/\(name).\(ext)") { return img }
                }
                return VFAsset.image(name)
            }
        }
        // Gedachter MacBook-Bildschirm; Pille unten mittig im Sprechen-Zustand
        let scr = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let bottom = NSRect(x: 723, y: 24, width: 66, height: 24)
        for (name, n) in presets {
            let u = out.appendingPathComponent("\(name).png")
            print(VFNotify.renderPNG(n, to: u, progress: 1, pill: bottom, screen: scr) ? "✓ \(u.path)" : "✗ \(name)")
        }
        // Morph in 4 Schlüsselbildern für drei Pillen-Lagen
        let n = presets[0].1
        let pills: [(String, NSRect)] = [("unten", bottom),
                                          ("rechts", NSRect(x: 1512 - 30, y: 440, width: 24, height: 66)),
                                          ("oben", NSRect(x: 723, y: 949 - 40, width: 66, height: 24)),
                                          ("unten_ruhe", NSRect(x: 734, y: 30, width: 44, height: 9))]
        for (lage, pill) in pills {
            for p in [0.0, 0.25, 0.6, 1.0] {
                let u = out.appendingPathComponent("morph_\(lage)_\(Int(p * 100)).png")
                _ = VFNotify.renderPNG(n, to: u, progress: CGFloat(p), pill: pill, screen: scr)
            }
            let lay = VFNotify.layout(for: n, pill: pill, visible: scr, frame: scr)
            print("Morph \(lage): Seite \(lay.side), Fenster \(NSStringFromRect(lay.windowFrame)), im Bildschirm: \(scr.contains(lay.windowFrame))")
        }
        return 0
    }

    /// Nur kurz live zeigen (max. 2 s) – für Positions-Checks. Normal: Offscreen-Renders verwenden.
    private static func demo(seconds: Double) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        VF.registerFonts()
        let secs = min(seconds, 2)
        VFNotify.shared.show(.wordLearned(old: "ID", new: "Lidl", save: {}, skip: {}))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if let p = NSApp.windows.first(where: { $0 is VFNotifyPanel }), let s = p.screen {
                print("Fenster: \(NSStringFromRect(p.frame)) auf \(s.localizedName), innerhalb: \(s.frame.contains(p.frame))")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs - 0.4) { VFNotify.shared.dismissAll() }
        let end = Date().addingTimeInterval(secs + 0.2)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return 0
    }

    // MARK: Command Mode

    private static func sanity() -> Int32 {
        let cases: [(String, String, Bool)] = [
            ("Hallo Welt, das ist ein Test.", "Hallo Welt.", true),
            ("Hallo", "", false),
            ("kurz", String(repeating: "x", count: 100), true),                  // Spielraum 120
            ("kurz", String(repeating: "x", count: 130), false),
            (String(repeating: "a", count: 100), String(repeating: "b", count: 499), true),
            (String(repeating: "a", count: 100), String(repeating: "b", count: 501), false),
        ]
        var fails = 0
        for (i, o, expectOK) in cases {
            let ok = CommandMode.sanityProblem(input: i, output: o) == nil
            if ok != expectOK { fails += 1 }
            print("\(ok == expectOK ? "✓" : "✗") in=\(i.count) out=\(o.count) → \(ok ? "ok" : "abgelehnt")")
        }
        let c1 = CommandMode.cleanOutput("```\nHallo\n```", original: "Hi")
        let c2 = CommandMode.cleanOutput("„Hallo Welt“", original: "hallo welt")
        let c3 = CommandMode.cleanOutput("Neuer Absatz", original: "alter Absatz\n")
        print("clean: \(c1 == "Hallo" ? "✓" : "✗") \(c2 == "Hallo Welt" ? "✓" : "✗") \(c3 == "Neuer Absatz\n" ? "✓" : "✗")")
        return fails == 0 ? 0 : 1
    }

    @discardableResult
    private static func osa(_ script: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { print("AppleScript-Fehler: \(err)"); return nil }
        return r?.stringValue
    }

    /// Öffnet ein NEUES TextEdit-Dokument, markiert per AX alles, wendet den Befehl an, prüft, schließt ohne Sichern.
    /// Andere TextEdit-Dokumente werden nicht angefasst.
    private static func textEditTest(instruction: String) async {
        print("Bedienungshilfen: \(AXIsProcessTrusted() ? "ja" : "NEIN – Einfügen/Lesen per AX nicht möglich")")
        let original = "Also ich wollte dir eigentlich nur ganz kurz sagen, dass ich heute leider ein bisschen später komme, weil der Zug mal wieder Verspätung hat und ich deshalb erst gegen acht Uhr da sein werde."
        let marker = "VFTEST-\(Int(Date().timeIntervalSince1970))"
        guard let docName = osa("""
            tell application "TextEdit"
                set d to make new document with properties {text:"\(original)"}
                set n to name of d
                activate
                return n
            end tell
            """) else { print("✗ TextEdit-Dokument nicht angelegt"); return }
        print("Testdokument: \(docName) (\(marker))")
        defer {
            _ = osa("tell application \"TextEdit\" to close (document \"\(docName)\") saving no")
            print("Testdokument geschlossen (ohne Sichern)")
        }
        try? await Task.sleep(nanoseconds: 700_000_000)

        // Alles markieren über AX (Textbereich im Fenster des Testdokuments)
        guard let te = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { print("✗ TextEdit läuft nicht"); return }
        let axApp = AXUIElementCreateApplication(te.processIdentifier)
        guard let area = findTextArea(app: axApp, windowTitle: docName, expectedText: original) else { print("✗ Textbereich des Testdokuments nicht gefunden"); return }
        var focused = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var range = CFRange(location: 0, length: (original as NSString).length)
        let rv = AXValueCreate(.cfRange, &range)!
        let setErr = AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, rv)
        print("Markieren per AX: \(setErr == .success ? "ok" : "Fehler \(setErr.rawValue)"), Fokus \(focused.rawValue)")
        focused = .success
        try? await Task.sleep(nanoseconds: 300_000_000)
        te.activate()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        print("Vordergrund: \(front)")
        guard front == "com.apple.TextEdit" else { print("✗ TextEdit nicht vorn (Fokus woanders) – Abbruch, keine Taste gesendet"); return }

        guard let sel = CommandMode.shared.captureSelection() else { print("✗ Keine Markierung gelesen"); return }
        guard sel.text == original else { print("✗ Falsches Feld markiert (\(sel.text.prefix(30))…) – Abbruch, nichts ersetzt"); return }
        print("Markierung (\(sel.viaCopy ? "⌘C" : "AX")): \(sel.text.count) Zeichen")
        let pbBefore = NSPasteboard.general.string(forType: .string)
        let t0 = Date()
        let r = await CommandMode.shared.run(instruction: instruction, on: sel)
        print(String(format: "Ergebnis nach %.1fs: %@", Date().timeIntervalSince(t0), String(describing: r)))
        try? await Task.sleep(nanoseconds: 900_000_000)
        let now = osa("tell application \"TextEdit\" to get text of document \"\(docName)\"") ?? "?"
        print("Dokument jetzt: \(now)")
        let pbAfter = NSPasteboard.general.string(forType: .string)
        print("Zwischenablage zurückgelegt: \(pbBefore == pbAfter ? "ja" : "NEIN")")
        if case .ok(let t) = r {
            print(now.trimmingCharacters(in: .whitespacesAndNewlines) == t.trimmingCharacters(in: .whitespacesAndNewlines) && now != original
                  ? "✓ Dokument wurde ersetzt (\(original.count) → \(now.count) Zeichen)" : "✗ Dokument entspricht nicht dem Ergebnis")
        }
    }

    private static func findTextArea(app: AXUIElement, windowTitle: String, expectedText: String) -> AXUIElement? {
        var wRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wRef) == .success, let wins = wRef as? [AXUIElement] else { return nil }
        for w in wins {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            // Exakt das Testfenster („Ohne Titel 2“) – nie ein echtes „Ohne Titel“
            guard let title = t as? String, title == windowTitle || title.hasPrefix(windowTitle + " ") else { continue }
            // Fenster nach vorn holen
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            var found: AXUIElement?
            func walk(_ el: AXUIElement, _ d: Int) {
                guard found == nil, d < 12 else { return }
                var r: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success, (r as? String) == "AXTextArea" { found = el; return }
                var k: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &k) == .success, let kids = k as? [AXUIElement] {
                    for c in kids { walk(c, d + 1) }
                }
            }
            walk(w, 0)
            // Sicherheitsnetz: nur ein Feld nehmen, das genau den Testsatz enthält
            if let f = found, CorrectionLearner.value(of: f) != expectedText { print("✗ Textbereich enthält nicht den Testsatz – Abbruch"); return nil }
            return found
        }
        return nil
    }
}
