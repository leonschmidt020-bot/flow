import AppKit
import SwiftUI

// MARK: - Sprachbefehle: Test-Befehle ohne Oberfläche
//
// Einbinden in CLI.run (default-Zweig):   … ?? VoiceCommandsCLI.run(args)
// --vcmd-flow/-render/-vault verweigern ohne eigenes FLOW_HOME (wie das Release-Tor) – dein ~/.config/flow bleibt unberührt.
//
//   Flow --vcmd-test [-v]                    Testsatz: Genauigkeit/Trefferquote (feste Uhr)
//   Flow --vcmd-parse "Text" [Partner]       einen Satz zerlegen (echte Uhr)
//   Flow --vcmd-corpus <datei.json|.txt> [-v]  fremder Testsatz ({normal:[…],commands:[{text,kind}]}) oder Diktat-Verlauf (nur „normal“)
//   Flow --vcmd-flow                         Ablauf headless: Karte, Countdown, Maus drauf, ✕, Fehlerfälle (Probelauf)
//   Flow --vcmd-eventkit                     echte EKReminder/EKEvent bauen – Probelauf, speichert NICHTS
//   Flow --vcmd-vault "Schick Nico: …"      gegen einen TEST-Tresor (nur mit CLIPVAULT_HOME ≠ ~/.config/flow-clipvault)
//   Flow --vcmd-render <ordner>              Karten, Pillen-Toasts, Einstellungen, Hilfe als PNG

enum VoiceCommandsCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        let a2 = args.count > 2 ? args[2] : ""
        switch args[1] {
        case "--vcmd-test": return test(verbose: args.contains("-v"))
        case "--vcmd-parse":
            var o = VoiceCommandParser.Options()
            o.partners = [args.count > 3 ? args[3] : "Nico"]
            let c = VoiceCommandParser.parse(a2, options: o)
            print(VCTestSet.describe(c))
            if let c { let k = VCText.card(c); print("Karte: \(k.title) – \(k.text) [\(k.primary)]") }
            return 0
        case "--vcmd-corpus": return corpus(a2, showAll: args.contains("-v"))
        case "--vcmd-flow": return SelfTestCLI.guardedHome { flow() }
        case "--vcmd-eventkit": return eventKit()
        case "--vcmd-vault": return SelfTestCLI.guardedHome { vault(a2) }
        case "--vcmd-render": return SelfTestCLI.guardedHome { render(dir: a2.isEmpty ? "/tmp/vcmd-render" : a2) }
        default: return nil
        }
    }

    // MARK: Testsatz

    private static func test(verbose: Bool) -> Int32 {
        let t0 = Date()
        let r = VCTestSet.run(verbose: verbose)
        let ms = Date().timeIntervalSince(t0) * 1000
        r.lines.forEach { print($0) }
        let total = VCTestSet.normal.count + VCTestSet.commands.count
        let precision = r.tp + r.fp == 0 ? 1 : Double(r.tp) / Double(r.tp + r.fp)
        let recall = Double(r.tp) / Double(max(1, VCTestSet.commands.count))
        let exact = Double(r.exact) / Double(max(1, VCTestSet.commands.count))
        print("")
        print("Normale Sätze: \(VCTestSet.normal.count) · Befehle: \(VCTestSet.commands.count)")
        print("Falsch ausgelöst (normal → Befehl): \(r.fp) von \(VCTestSet.normal.count)")
        print("Erkannt: \(r.tp)/\(VCTestSet.commands.count) · falsche Art: \(r.wrongKind) · nicht erkannt: \(r.fn - r.wrongKind)")
        print(String(format: "Precision %.3f · Recall %.3f · exakt (Art + Text + Zeit) %.3f · %d Sätze in %.0f ms (%.2f ms/Satz)",
                     precision, recall, exact, total, ms, ms / Double(total)))
        return r.fp == 0 ? 0 : 1
    }

    // MARK: Fremder Testsatz / echter Verlauf (nur lesen)

    private static func corpus(_ path: String, showAll: Bool) -> Int32 {
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { print("Datei fehlt: \(path)"); return 2 }
        var normal: [String] = [], commands: [(String, String)] = []
        if path.hasSuffix(".txt") {
            normal = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else if let o = try? JSONSerialization.jsonObject(with: data) {
            if let d = o as? [String: Any] {
                normal = (d["normal"] as? [String]) ?? []
                commands = ((d["commands"] as? [[String: Any]]) ?? []).compactMap { c in (c["text"] as? String).map { ($0, (c["kind"] as? String) ?? "") } }
            } else if let arr = o as? [[String: Any]] {
                normal = arr.compactMap { $0["text"] as? String }     // z. B. verlauf.json: alles, was wirklich eingefügt wurde
            }
        }
        var o = VoiceCommandParser.Options(); o.partners = ["Nico"]; o.me = "Lena"
        var fp = 0, tp = 0, wrong = 0, miss = 0
        for s in normal {
            if let c = VoiceCommandParser.parse(s, options: o) { fp += 1; print("FALSCH AUSGELÖST  „\(VCText.short(s, 110))“ → \(VCTestSet.describe(c))") }
        }
        for (s, k) in commands {
            let c = VoiceCommandParser.parse(s, options: o)
            if let c, c.kind.rawValue == k { tp += 1; if showAll { print("ok  „\(s)“ → \(VCTestSet.describe(c))") } }
            else if let c { wrong += 1; print("FALSCHE ART      „\(s)“ (\(k)) → \(VCTestSet.describe(c))") }
            else { miss += 1; print("NICHT ERKANNT    „\(s)“ (\(k))") }
        }
        print("")
        print("Normal: \(normal.count) · davon falsch ausgelöst: \(fp)")
        if !commands.isEmpty {
            let prec = tp + fp + wrong == 0 ? 1 : Double(tp) / Double(tp + fp + wrong)
            print(String(format: "Befehle: %d · erkannt %d · falsche Art %d · nicht erkannt %d · Precision %.3f · Recall %.3f",
                         commands.count, tp, wrong, miss, prec, Double(tp) / Double(max(1, commands.count))))
        }
        return 0
    }

    // MARK: Ablauf headless (Probelauf)

    /// Test-Karten: merkt sich, was gezeigt wird; Maus/Klicks werden simuliert.
    final class FakePresenter: VCCardPresenter {
        var shown: [VFNotice] = []
        var current: String?
        var hovered = false
        var dismissed: [String] = []
        func show(_ n: VFNotice) { shown.append(n); current = n.id }
        func dismiss(id: String) { dismissed.append(id); if current == id { current = nil } }
        func isCurrent(_ id: String) -> Bool { current == id }
        func isHovered(_ n: VFNotice) -> Bool { hovered }
        var last: VFNotice? { shown.last }
    }

    private static func flow() -> Int32 {
        _ = NSApplication.shared
        var fails = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "✓ " : "✗ ") + what); if !ok { fails += 1 } }
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        var log: [String] = []
        var toasts: [String] = []
        var copied: [String] = []
        var shares: [String] = []
        var connected = true
        let presenter = FakePresenter()
        var acts = VCActions()
        let ek = VCEventKit.dryRun { log.append($0) }
        acts.addReminder = ek.addReminder
        acts.addEvent = ek.addEvent
        acts.syncState = { VCVault.SyncState(connected: connected, reason: connected ? "" : "Keine Verbindung zum Tresor") }
        acts.share = { t, done in shares.append(t); done(.success(true)) }
        acts.addNote = { log.append("NOTIZ „\($0)“") }
        acts.openURL = { log.append("URL \($0.absoluteString)") }
        acts.copy = { copied.append($0) }
        acts.addHistory = { t, _ in log.append("VERLAUF „\(t)“") }
        acts.polish = { _ in nil }
        acts.presenter = presenter
        var prefs = VCPrefs(); prefs.confirmSeconds = 4
        let vc = VoiceCommands(testing: prefs, actions: acts)
        let toast: (String) -> Void = { toasts.append($0) }

        func consume(_ text: String, partner: String = "Nico") -> Bool {
            var result: Bool?
            var finished = false
            Task {
                // Partner fest setzen (sonst aus Einstellungen/ClipVault)
                let r = await vc.consumeForTest(text, partner: partner, toast: toast, finish: { finished = true })
                result = r
            }
            while result == nil { pump(0.02) }
            if result == true && !finished { print("  (finish wurde nicht aufgerufen!)") }
            return result!
        }

        print("— 1) Termin: Karte, Countdown 4 s, führt selbst aus")
        check(consume("Termin am Freitag 14 Uhr mit Pierre"), "als Befehl erkannt (nichts eingefügt)")
        check(presenter.last?.title == "Termin eintragen", "Karte „Termin eintragen“: \(presenter.last?.text ?? "-")")
        check(presenter.last?.secondary?.0 == "Abbrechen · 4", "Countdown im Knopf: \(presenter.last?.secondary?.0 ?? "-")")
        for _ in 0..<10 { vc.pending?.step(0.2) }
        check(presenter.last?.secondary?.0 == "Abbrechen · 2", "nach 2 s: \(presenter.last?.secondary?.0 ?? "-")")
        check(log.filter { $0.hasPrefix("EKEvent") }.isEmpty, "vor Ablauf nichts eingetragen")
        for _ in 0..<11 { vc.pending?.step(0.2) }
        pump(0.05)
        check(log.contains { $0.hasPrefix("EKEvent") && $0.contains("Termin mit Pierre") && $0.contains("30 min") }, "nach 4 s eingetragen (Probelauf): \(log.last ?? "")")
        check(toasts.last == "Termin eingetragen ✓", "Pillen-Toast: \(toasts.last ?? "-")")
        check(presenter.dismissed.count == 1, "Karte geschlossen")

        print("— 2) Erinnerung: Maus drauf hält an, danach wieder volle Zeit")
        log.removeAll()
        check(consume("Erinner mich morgen um 9 an den Zahnarzt"), "erkannt")
        for _ in 0..<15 { vc.pending?.step(0.2) }            // 3 s
        presenter.hovered = true
        for _ in 0..<50 { vc.pending?.step(0.2) }            // 10 s mit Maus drauf
        check(!log.contains { $0.hasPrefix("EKReminder") }, "mit Maus drauf nach 13 s noch nicht angelegt")
        check(presenter.last?.secondary?.0 == "Abbrechen", "Knopf ohne Countdown während Hover: \(presenter.last?.secondary?.0 ?? "-")")
        presenter.hovered = false
        for _ in 0..<15 { vc.pending?.step(0.2) }            // 3 s
        check(!log.contains { $0.hasPrefix("EKReminder") }, "nach Verlassen 3 s: noch nicht")
        for _ in 0..<6 { vc.pending?.step(0.2) }
        pump(0.05)
        check(log.contains { $0.hasPrefix("EKReminder") && $0.contains("Zahnarzt") && $0.contains("09:00") }, "dann angelegt: \(log.last ?? "")")

        print("— 3) Schicken: ✕ bricht ab")
        log.removeAll(); shares.removeAll()
        check(consume("Schick Nico: Ich komme zehn Minuten später."), "erkannt")
        check(presenter.last?.title == "An Nico schicken", "Karte: \(presenter.last?.title ?? "-") \(presenter.last?.text ?? "")")
        presenter.last?.onClose?()
        for _ in 0..<30 { vc.pending?.step(0.2) }
        check(shares.isEmpty, "nichts geschickt")
        check(toasts.last == "Abgebrochen – steht im Verlauf", "Toast: \(toasts.last ?? "-")")
        check(log.contains { $0.hasPrefix("VERLAUF") }, "Text steht im Diktat-Verlauf")

        print("— 4) Schicken: Knopf „Schicken“ sofort")
        check(consume("Schick Nico: Bin gleich da"), "erkannt")
        presenter.last?.primary?.1()
        pump(0.05)
        check(shares == ["Bin gleich da"], "geschickt: \(shares)")
        check(toasts.last == "An Nico geschickt ✓", "Toast: \(toasts.last ?? "-")")

        print("— 5) Schicken ohne Verbindung → Zwischenablage + Karte")
        connected = false; copied.removeAll(); shares.removeAll()
        check(consume("Schick Nico: Offline-Test"), "erkannt")
        presenter.last?.primary?.1()
        pump(0.05)
        check(copied == ["Offline-Test"], "in der (Test-)Zwischenablage: \(copied)")
        check(presenter.last?.id == "sprachbefehl_nicht_verbunden", "Karte „\(presenter.last?.title ?? "-")“ – \(presenter.last?.text ?? "")")
        check(shares.isEmpty, "nicht geteilt, solange nicht verbunden")
        presenter.last?.primary?.1()   // „Später schicken“
        pump(0.05)
        check(shares == ["Offline-Test"], "„Später schicken“ legt es in den Tresor (wartet auf Sync)")
        connected = true

        print("— 6) Ohne Bestätigung: sofort")
        vc.prefs.confirm = false
        log.removeAll()
        let shownBefore = presenter.shown.count
        check(consume("Remind me in 2 hours to check the oven"), "erkannt")
        pump(0.05)
        check(presenter.shown.count == shownBefore, "keine Karte")
        check(log.contains { $0.hasPrefix("EKReminder") && $0.contains("Check the oven") }, "sofort angelegt: \(log.last ?? "")")
        vc.prefs.confirm = true

        print("— 7) Notiz, Suche, normaler Text, unvollständiger Befehl, ausgeschaltet")
        log.removeAll()
        check(consume("Notiz: Milch und Eier"), "Notiz erkannt")
        check(log.contains("NOTIZ „Milch und Eier“"), "im Scratchpad (Probelauf)")
        check(toasts.last == "Notiz gespeichert ✓", "Toast: \(toasts.last ?? "-")")
        check(consume("Such nach Pizzerien in Hamburg"), "Suche erkannt")
        check(log.contains { $0.contains("google.com/search?q=Pizzerien%20in%20Hamburg") }, "Suche geöffnet: \(log.last ?? "")")
        check(!consume("Termin am Freitag passt mir leider nicht."), "normaler Satz → wird eingefügt")
        check(!consume("Erinner mich"), "unvollständig („Erinner mich“) → wird normal eingefügt")
        check(!consume("Schick Nico:"), "unvollständig („Schick Nico:“) → wird normal eingefügt")
        vc.prefs.enabled = false
        check(!consume("Schick Nico: aus"), "ausgeschaltet → normal eingefügt")
        vc.prefs.enabled = true

        print("— 8) Karte wartet in der Schlange (andere Karte sichtbar) → zählt erst, wenn sie dran ist")
        log.removeAll()
        check(consume("Termin morgen um 10 Uhr Zahnarzt"), "erkannt")
        presenter.current = "meeting_erkannt"
        for _ in 0..<40 { vc.pending?.step(0.2) }
        check(!log.contains { $0.hasPrefix("EKEvent") }, "8 s in der Schlange: nichts eingetragen")
        presenter.current = vc.pending?.id
        for _ in 0..<21 { vc.pending?.step(0.2) }
        pump(0.05)
        check(log.contains { $0.hasPrefix("EKEvent") }, "danach 4 s sichtbar → eingetragen")

        print("\n\(fails == 0 ? "ABLAUF OK" : "\(fails) FEHLER")")
        return fails == 0 ? 0 : 1
    }

    // MARK: EventKit-Probelauf

    private static func eventKit() -> Int32 {
        var out: [String] = []
        let ek = VCEventKit.dryRun { out.append($0) }
        var o = VoiceCommandParser.Options(); o.partners = ["Nico"]
        let samples = ["Erinner mich morgen um 9 an den Zahnarzt", "Erinnere mich am Freitag, Pierre anzurufen", "Erinner mich daran, dass ich Milch kaufen muss",
                       "Termin am Freitag 14 Uhr mit Pierre", "Kalender: Geburtstag Mama am 3. Oktober", "Termin Montag von 14 bis 15 Uhr Teammeeting",
                       "Remind me tomorrow at 5pm to call mom", "Calendar: lunch with Mike tomorrow at noon"]
        for s in samples {
            guard let c = VoiceCommandParser.parse(s, options: o) else { print("✗ nicht erkannt: \(s)"); continue }
            print("„\(s)“")
            print("  Karte: \(VCText.card(c).title) – \(VCText.card(c).text)")
            switch c.kind {
            case .reminder: ek.addReminder(c.text, c.date, c.allDay) { _ in }
            case .event: ek.addEvent(c.text, c.date!, c.end ?? c.date!, c.allDay) { _ in }
            default: break
            }
            print("  " + (out.last ?? "-"))
        }
        print("\nModus: PROBELAUF – EKReminder/EKEvent gebaut, aber nie gespeichert (kein Kalender-Zugriff, keine Test-Kalender nötig).")
        return 0
    }

    // MARK: Test-Tresor

    private static func vault(_ text: String) -> Int32 {
        let home = ProcessInfo.processInfo.environment["CLIPVAULT_HOME"] ?? ""
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow-clipvault").standardizedFileURL.path
        guard !home.isEmpty, URL(fileURLWithPath: (home as NSString).expandingTildeInPath).standardizedFileURL.path != real else {
            print("Abbruch: nur gegen einen Test-Tresor (CLIPVAULT_HOME=<testordner>), nie gegen ~/.config/flow-clipvault"); return 2
        }
        _ = NSApplication.shared
        print("Test-Tresor: \(ClipVaultClient.base.path)")
        let st = VCVault.syncState()
        print("Sync: \(st.connected ? "verbunden" : "nicht verbunden – \(st.reason)")")
        var o = VoiceCommandParser.Options(); o.partners = [Identity.partnerName ?? "Nico"]
        guard let c = VoiceCommandParser.parse(text, options: o), c.kind == .send else { print("kein Schick-Befehl: \(text)"); return 1 }
        print("Befehl: \(VCTestSet.describe(c))")
        var toasts: [String] = [], copied: [String] = []
        let presenter = FakePresenter()
        var acts = VCActions()
        acts.copy = { copied.append($0) }        // nie die echte Zwischenablage
        acts.presenter = presenter
        acts.addHistory = { _, _ in }
        let vc = VoiceCommands(testing: VCPrefs(), actions: acts)
        vc.run(c, toast: { toasts.append($0) })
        presenter.last?.primary?.1()             // „Schicken“ klicken
        let deadline = Date().addingTimeInterval(15)
        while toasts.isEmpty && presenter.shown.last?.id != "sprachbefehl_nicht_verbunden" && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("Toast: \(toasts.last ?? "–") · Zwischenablage (Test): \(copied) · Karte: \(presenter.shown.last.map { "\($0.title) – \($0.text)" } ?? "–")")
        return toasts.last.map { $0.hasSuffix("geschickt ✓") || $0.hasPrefix("Wartet") } == true ? 0 : 1
    }

    // MARK: Bilder

    private static func render(dir: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = VCTestSet.now
        var o = VCTestSet.options(for: VCCase(text: ""))
        o.calendar = VCTestSet.calendar
        let scr = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let pill = NSRect(x: 723, y: 24, width: 66, height: 24)
        let items: [(String, String, Bool)] = [
            ("karte_termin", "Termin am Freitag 14 Uhr mit Pierre", false),
            ("karte_erinnerung", "Erinner mich morgen um 9 an den Zahnarzt", false),
            ("karte_schicken", "Schick Nico: Ich komme zehn Minuten später, fangt schon mal ohne mich an.", false),
            ("karte_termin_hover", "Termin Montag von 14 bis 15 Uhr Teammeeting", true),
            ("karte_erinnerung_ohne_datum", "Erinner mich daran, dass ich Milch kaufen muss", false),
            ("karte_termin_ganztag", "Kalender: Geburtstag Mama am 3. Oktober", false),
        ]
        for (name, text, hover) in items {
            guard let c = VoiceCommandParser.parse(text, now: now, options: o) else { print("✗ \(name)"); continue }
            let conf = VCConfirm(cmd: c, now: now, seconds: 4, presenter: FakePresenter(), onConfirm: {}, onCancel: {})
            let n = conf.notice(remaining: hover ? nil : 4, paused: hover)
            let u = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            print(VFNotify.renderPNG(n, to: u, progress: 1, pill: pill, screen: scr) ? "✓ \(u.path)" : "✗ \(name)")
        }
        // Keine Verbindung
        let off = VFNotice(id: "sprachbefehl_nicht_verbunden", title: "Nicht an Nico geschickt",
                           text: "Keine Verbindung zum Tresor. Der Text liegt in der Zwischenablage.",
                           illustration: "illu_geteilt", fallbackSymbol: "person.2.slash",
                           primary: ("Später schicken", {}), secondary: ("OK", {}), timeout: 12)
        let u = URL(fileURLWithPath: dir).appendingPathComponent("karte_nicht_verbunden.png")
        print(VFNotify.renderPNG(off, to: u, progress: 1, pill: pill, screen: scr) ? "✓ \(u.path)" : "✗ offline")
        // Morph (halb aufgewachsen) für die Sichtprüfung der Animation
        if let c = VoiceCommandParser.parse("Termin am Freitag 14 Uhr mit Pierre", now: now, options: o) {
            let conf = VCConfirm(cmd: c, now: now, seconds: 4, presenter: FakePresenter(), onConfirm: {}, onCancel: {})
            let n = conf.notice(remaining: 4, paused: false)
            let m = URL(fileURLWithPath: dir).appendingPathComponent("karte_termin_morph50.png")
            print(VFNotify.renderPNG(n, to: m, progress: 0.5, pill: pill, screen: scr) ? "✓ \(m.path)" : "✗ morph")
        }
        // Pillen-Toasts
        for (name, t) in [("toast_geschickt", "An Nico geschickt ✓"), ("toast_erinnerung", "Erinnerung angelegt ✓"),
                          ("toast_notiz", "Notiz gespeichert ✓"), ("toast_abgebrochen", "Abgebrochen – steht im Verlauf")] {
            renderToast(t, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        // Einstellungen + Hilfe (Modal höher, damit die Karte „Sprachbefehle“ ohne Scrollen sichtbar ist)
        VFSettingsModal.maxHeight = 1440
        let shots: [(String, AnyView, NSSize)] = [
            ("einstellungen_zeilen", AnyView(VStack(alignment: .leading, spacing: 10) {
                Text("SPRACHBEFEHLE").font(.system(size: 13, weight: .semibold)).tracking(1.2).foregroundStyle(VF.muted).padding(.leading, 4)
                VoiceCommandSettingsRows().padding(.horizontal, 26).background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.cardSoft))
            }.padding(40).background(VF.card)), NSSize(width: 1000, height: 560)),
            ("einstellungen_diktat", AnyView(VFSettingsModal(section: .dictation) {}.padding(30).background(Color.black.opacity(0.25))), NSSize(width: 1331, height: 1500)),
            ("hilfe_abschnitt", AnyView(VoiceCommandsHelpSection().padding(40).frame(width: 1046).background(VF.panel)), NSSize(width: 1126, height: 640)),
            ("hilfe_seite", AnyView(HubHilfePage().background(VF.panel)), NSSize(width: 1200, height: 1900)),
        ]
        for (name, view, sz) in shots {
            let host = NSHostingView(rootView: view.frame(width: sz.width, height: sz.height, alignment: .topLeading).environment(\.colorScheme, .light))
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
            print("✓ \(path)")
        }
        return 0
    }

    private static func renderToast(_ text: String, to url: URL) {
        let win = NSWindow(contentRect: NSRect(x: 1000, y: 500, width: 460, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        let v = PillView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        win.contentView = v
        v.screenRect = .zero
        v.anchor = NSPoint(x: 1230, y: 575)
        v.mode = .idle
        v.showToast(text, seconds: 100)
        for _ in 0..<90 { v.tick() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // Einblenden (0,15 s) abwarten
        v.tick()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        let bg = NSImage(size: v.bounds.size)
        bg.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.70, alpha: 1), NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.93, alpha: 1)])!.draw(in: v.bounds, angle: 90)
        bg.unlockFocus()
        v.cacheDisplay(in: v.bounds, to: rep)
        let out = NSImage(size: v.bounds.size)
        out.lockFocus()
        bg.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        rep.draw(in: v.bounds)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let b = NSBitmapImageRep(data: tiff), let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: url); print("✓ \(url.path)")
        }
    }
}

extension VoiceCommands {
    /// Wie `consume`, aber mit festem Partner (Tests ohne Einstellungen/ClipVault)
    func consumeForTest(_ text: String, partner: String, toast: @escaping (String) -> Void, finish: @escaping () -> Void) async -> Bool {
        guard prefs.enabled else { return false }
        var o = VoiceCommandParser.Options(); o.partners = [partner]; o.search = prefs.search
        return await consume(text, options: o, toast: toast, finish: finish)
    }
}
