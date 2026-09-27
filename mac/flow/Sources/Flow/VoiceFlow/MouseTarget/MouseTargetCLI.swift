import AppKit
import ApplicationServices

// MARK: - „Text dorthin, wo die Maus ist“: Selbsttest + Probe (ohne App-Modus)
//
//   Flow --selftest-mouse-target     reine Logik (Fensterliste, Koordinaten, eigene Fenster, Textfeld, Klick, Enter-Liste)
//                                      – keine Fenster, keine Bedienungshilfen, keine Zwischenablage (Release-Tor Schritt 3)
//   Flow --mouse-target-probe [--ohne-titel] [--json]
//                                      zeigt, was JETZT unter der Maus als Ziel gewählt würde. NUR LESEN: kein Fokus-Wechsel,
//                                      kein Klick, kein Einfügen, kein AXManualAccessibility, kein Protokoll, kein App-Modus.
//                                      Bedienungshilfen braucht das aufrufende Programm (Terminal) bzw. die installierte App:
//                                      „~/Applications/Flow.app/Contents/MacOS/Flow“ --mouse-target-probe

enum MouseTargetCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--selftest-mouse-target": return MouseTargetSelfTest.run()
        case "--mouse-target-probe":
            var point: CGPoint?
            if let i = args.firstIndex(of: "--punkt"), i + 1 < args.count {
                let v = args[i + 1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if v.count == 2 { point = CGPoint(x: v[0], y: v[1]) }
            }
            return probe(hideTitles: args.contains("--ohne-titel"), at: point, listWindows: args.contains("--fenster"))
        default: return nil
        }
    }

    private static func fmt(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))" }
    private static func fmt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }

    /// `at`: anderer Punkt (CG) statt der Maus – so lässt sich jedes Fenster prüfen, ohne die Maus zu bewegen
    static func probe(hideTitles: Bool, at: CGPoint? = nil, listWindows: Bool = false) -> Int32 {
        func title(_ t: String) -> String { hideTitles ? "\(t.count) Zeichen" : "„\(MTRules.shortTitle(t, max: 40))“" }
        print("Maus-Ziel-Probe – nur lesen: nichts wird fokussiert, geklickt oder eingefügt")
        let trusted = AXIsProcessTrusted()
        print("Bedienungshilfen: \(trusted ? "ja" : "NEIN (Fenster-Zuordnung und Textfelder unbekannt – Probe aus der installierten App starten)")")
        print("Fenster-Nummer aus AX (_AXUIElementGetWindow): \(MTAX.windowIDAvailable ? "ja" : "nein – Rahmen/Titel-Abgleich") · Fenster gezielt nach vorne (SkyLight): \(MTFocus.skyLightAvailable ? "ja" : "nein – nur Bedienungshilfen")")
        let frames = NSScreen.screens.map(\.frame)
        let h = MTGeometry.primaryHeight(frames)
        for (i, f) in frames.enumerated() {
            print("Bildschirm #\(i): Cocoa \(fmt(f)) → CG \(fmt(MTGeometry.cocoaRectToCG(f, primaryHeight: h)))\(f.origin == .zero ? " [Haupt]" : "")")
        }
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let cg = at ?? mouse
        let cocoa = NSEvent.mouseLocation
        let back = MTGeometry.cocoaToCG(cocoa, primaryHeight: h)
        let same = abs(back.x - cg.x) <= 1 && abs(back.y - cg.y) <= 1
        if at != nil { print("Geprüfter Punkt (statt Maus): CG \(fmt(cg)) · Bildschirm #\(MTGeometry.screenIndex(cg: cg, cocoaFrames: frames).map(String.init) ?? "?")") }
        print("Maus: CG \(fmt(mouse)) · Cocoa \(fmt(cocoa)) → umgerechnet \(fmt(back)) \(same ? "✓ gleich" : "✗ WEICHT AB") · Bildschirm #\(MTGeometry.screenIndex(cg: mouse, cocoaFrames: frames).map(String.init) ?? "?")")

        let t0 = Date()
        let list = MouseTarget.windowList()
        let listMs = Date().timeIntervalSince(t0) * 1000
        let own = ProcessInfo.processInfo.processIdentifier
        print(String(format: "Fensterliste: %d Fenster auf dem Bildschirm (%.1f ms)", list.count, listMs))
        if listWindows {
            for w in list where w.layer == 0 && w.alpha > 0.01 && w.bounds.width >= MTRules.minSize {
                print("  #\(w.id) \(w.owner) [\(w.bundle)] \(fmt(w.bounds)) Mitte \(fmt(CGPoint(x: w.bounds.midX, y: w.bounds.midY)))")
            }
        }
        print("Am Mauspunkt (vorne → hinten):")
        for w in list where w.bounds.contains(cg) && w.alpha > 0.01 {
            var tag = "Kandidat"
            if MTRules.isPassThrough(w, ownPID: own) { tag = "durchsichtig (eigenes/ClipVault/Overlay)" }
            else if w.layer != 0 { tag = "Ebene \(w.layer) (System/Panel)" }
            else if MTRules.systemOwners.contains(w.owner) { tag = "Systemteil" }
            else if w.bounds.width < MTRules.minSize || w.bounds.height < MTRules.minSize { tag = "zu klein" }
            print("  #\(w.id) \(w.owner) [\(w.bundle.isEmpty ? "-" : w.bundle)] Ebene \(w.layer) α \(String(format: "%.2f", w.alpha)) \(fmt(w.bounds)) → \(tag)")
        }
        let front = MouseTarget.frontmost()
        let frontName = NSRunningApplication(processIdentifier: front.pid)?.localizedName ?? "?"
        print("Vorne: \(frontName) (pid \(front.pid)) · Fenster-Nr. \(front.windowID.map(String.init) ?? "?")")

        let t1 = Date()
        let cap = MouseTarget.capture(point: cg, ownPID: own, session: 1, list: list, enableAX: nil)
        let capMs = Date().timeIntervalSince(t1) * 1000
        guard case .target(let t) = cap else {
            if case .none(let why) = cap { print("Ziel: keins – \(why) → normales Einfügen") }
            print(String(format: "Zeit: Suche %.1f ms", capMs))
            return 0
        }
        print("Ziel: \(t.appName) [\(t.bundle)] · Fenster #\(t.windowID) · \(title(t.title)) · AX-Fenster \(t.window != nil ? "gefunden" : "–")")
        print("      schon aktiv: \(t.alreadyFocused ? "ja → nichts Besonderes, 0 ms" : "nein → wird beim Einfügen nach vorne geholt") · verdeckt: \(t.covered ? "ja (kein Klick)" : "nein")")

        let t2 = Date()
        let app = AXUIElementCreateApplication(t.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let hit = MTAX.hit(app: app, at: cg)
        let chain = hit.map { MTAX.chain(from: $0, maxDepth: 24) } ?? []
        let hitMs = Date().timeIntervalSince(t2) * 1000
        print("Element unter der Maus (\(chain.count) Ebenen bis zum Fenster):")
        for (i, l) in chain.prefix(12).enumerated() {
            let n = l.node
            var extra: [String] = []
            if !n.subrole.isEmpty { extra.append(n.subrole) }
            if !n.classes.isEmpty { extra.append("." + n.classes.prefix(4).joined(separator: ".")) }
            if n.hasInsertionPoint { extra.append("Einfügemarke") }
            if n.hasEditableAncestor { extra.append("in contenteditable") }
            if MTRules.isEditable(n) { extra.append("✎ Textfeld") }
            print("  \(i): \(n.role.isEmpty ? "?" : n.role)\(extra.isEmpty ? "" : " " + extra.joined(separator: " "))")
        }
        if chain.count > 12 { print("  … \(chain.count - 12) weitere") }
        if chain.isEmpty { print("  (keins – App ohne Bedienungshilfen-Baum? Chromium/Electron bauen ihn erst beim echten Diktat auf)") }

        let t3 = Date()
        let nodes = chain.map(\.node)
        var plan = ""
        if t.alreadyFocused { plan = "0 – Maus über dem aktiven Fenster, Einfügen wie bisher" }
        else {
            switch MTRules.pickEditable(nodes) {
            case .secure: plan = "d – Passwortfeld unter der Maus, nie Ziel"
            case .at(let i): plan = "a – Textfeld \(nodes[i].role) (Ebene \(i)) fokussieren"
            case .none:
                if chain.first.flatMap({ MTAX.editableAncestor($0.el) }) != nil { plan = "a – contenteditable fokussieren" }
                else if MTAX.xtermInput(chain: chain) != nil { plan = "a – xterm-Eingabefeld des Terminals fokussieren" }
                else if let f = MTAX.focusedEditable(app), MTAX.belongs(f, to: t) { plan = "b – zuletzt benutztes Feld im Fenster (\(MTAX.node(f).role))" }
                else if MTRules.clickAllowed(bundle: t.bundle, chain: nodes, covered: t.covered) { plan = "c – ein Klick ins Terminal (falls nach dem Umschalten kein Feld aktiv ist: zuerst b)" }
                else { plan = "b oder d – erst nach dem Umschalten sichtbar; ohne Feld: zurück + „Kein Textfeld unter der Maus – normal eingefügt“" }
            }
        }
        let planMs = Date().timeIntervalSince(t3) * 1000 + hitMs
        print("Plan: \(plan)")
        let send = MTRules.autoSend(bundle: t.bundle, chain: nodes, webHost: MTAX.webHost(chain))
        print("Enter danach (wenn eingeschaltet, geschätzt am Element unter der Maus): \(send.allowed ? "ja" : "nein – \(MTAX.reason(send))")")
        print(String(format: "Zeit: Fensterliste %.1f ms · Suche+Zuordnung %.1f ms (bei Fn-Druck im Hintergrund) · Element %.1f ms · Planung vor dem Umschalten %.1f ms", listMs, capMs, hitMs, planMs))
        return 0
    }
}

// MARK: - Selbsttest (reine Logik)

enum MouseTargetSelfTest {
    typealias N = MTRules.Node
    static func win(_ id: CGWindowID, _ pid: pid_t, _ owner: String, _ r: CGRect, layer: Int = 0, alpha: Double = 1, bundle: String = "", title: String = "") -> MTWindowInfo {
        MTWindowInfo(id: id, pid: pid, owner: owner, bundle: bundle, layer: layer, alpha: alpha, bounds: r, title: title)
    }

    static func run() -> Int32 {
        let c = SelfTestChecks()

        // ── Koordinaten ──
        c.section("Koordinaten (Cocoa unten links ↔ CG/AX oben links)")
        let mac = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Beispiel-Aufbau: externer Monitor direkt ÜBER dem MacBook (Cocoa y > 982 → CG y negativ)
        let msiAbove = CGRect(x: -204, y: 982, width: 1920, height: 1080)
        let above = [mac, msiAbove]
        let h = MTGeometry.primaryHeight(above)
        c.check(h == 982, "Hauptbildschirm-Höhe = Rahmen mit Ursprung 0,0", "\(h)")
        c.check(MTGeometry.primaryHeight([msiAbove, mac]) == 982, "Hauptbildschirm auch, wenn er nicht zuerst in der Liste steht")
        c.check(MTGeometry.cocoaRectToCG(msiAbove, primaryHeight: h) == CGRect(x: -204, y: -1080, width: 1920, height: 1080), "Monitor darüber → CG y = −1080")
        let pAbove = MTGeometry.cocoaToCG(CGPoint(x: 100, y: 1500), primaryHeight: h)
        c.check(pAbove == CGPoint(x: 100, y: -518), "Punkt auf dem oberen Monitor → CG (100, −518)", "\(pAbove)")
        c.check(MTGeometry.screenIndex(cg: pAbove, cocoaFrames: above) == 1, "… liegt auf Bildschirm #1")
        c.check(MTGeometry.screenIndex(cg: CGPoint(x: 756, y: 491), cocoaFrames: above) == 0, "Mitte MacBook → #0")
        c.check(MTGeometry.screenIndex(cg: CGPoint(x: 0, y: 0), cocoaFrames: above) == 0, "CG (0,0) = obere linke Ecke des Hauptbildschirms")
        c.check(MTGeometry.screenIndex(cg: CGPoint(x: 10, y: -1), cocoaFrames: above) == 1, "1 pt über der Kante → oberer Monitor")
        c.check(MTGeometry.screenIndex(cg: CGPoint(x: 10, y: 982), cocoaFrames: above) == nil, "Unterkante gehört nicht mehr dazu")
        // Monitor LINKS vom Hauptbildschirm, höher und unten bündig
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let lay2 = [mac, left]
        let pl = MTGeometry.cocoaToCG(CGPoint(x: -100, y: 1000), primaryHeight: 982)
        c.check(pl == CGPoint(x: -100, y: -18), "Monitor links (höher): Cocoa (−100, 1000) → CG (−100, −18)", "\(pl)")
        c.check(MTGeometry.screenIndex(cg: pl, cocoaFrames: lay2) == 1, "… liegt auf dem linken Monitor")
        c.check(MTGeometry.screenIndex(cg: CGPoint(x: -1, y: 500), cocoaFrames: lay2) == 1 && MTGeometry.screenIndex(cg: CGPoint(x: 0, y: 500), cocoaFrames: lay2) == 0,
                "Kante links/Haupt: x = −1 links, x = 0 Haupt")
        // Drei Monitore: rechts tiefer, links oben versetzt
        let right = CGRect(x: 1512, y: -300, width: 2560, height: 1440)
        let upLeft = CGRect(x: -1440, y: 982, width: 1440, height: 900)
        let lay3 = [right, upLeft, mac]
        let pr = MTGeometry.cocoaToCG(CGPoint(x: 2000, y: -200), primaryHeight: MTGeometry.primaryHeight(lay3))
        c.check(pr == CGPoint(x: 2000, y: 1182) && MTGeometry.screenIndex(cg: pr, cocoaFrames: lay3) == 0, "rechter Monitor tiefer: CG y > Haupthöhe", "\(pr)")
        c.check(MTGeometry.screenIndex(cg: CGPoint(x: -700, y: -450), cocoaFrames: lay3) == 1, "Monitor links oben → #1")
        c.check(MTGeometry.screenIndex(cg: CGPoint(x: -700, y: 450), cocoaFrames: lay3) == nil, "Lücke zwischen den Monitoren → keiner")
        var roundTrip = true
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: -1919, y: 1079), CGPoint(x: 4000, y: -299.5), CGPoint(x: 12.25, y: 981)] {
            let q = MTGeometry.cgToCocoa(MTGeometry.cocoaToCG(p, primaryHeight: 982), primaryHeight: 982)
            if q != p { roundTrip = false }
        }
        c.check(roundTrip, "Hin- und Rückweg Cocoa → CG → Cocoa verlustfrei")

        // ── Fensterliste ──
        c.section("Fensterliste filtern und ordnen")
        let own: pid_t = 999
        let p = CGPoint(x: 500, y: 500)
        let big = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let vsA = win(10, 50, "Code", CGRect(x: 100, y: 100, width: 900, height: 700), bundle: "com.microsoft.VSCode", title: "A")
        let vsB = win(11, 50, "Code", CGRect(x: 0, y: 0, width: 1400, height: 900), bundle: "com.microsoft.VSCode", title: "B")
        let desktop = win(1, 70, "Dock", big, layer: -2147483624)
        let menubar = win(2, 71, "Window Server", CGRect(x: 0, y: 0, width: 1512, height: 33), layer: 24)
        let base = [menubar, vsA, vsB, desktop]
        c.check(MTRules.pick(base, at: p, ownPID: own) == .windows([vsA, vsB], covered: false), "oberstes normales Fenster zuerst, Reihenfolge vorne → hinten")
        c.check(MTRules.pick(base, at: CGPoint(x: 50, y: 50), ownPID: own) == .windows([vsB], covered: false), "Punkt nur im hinteren Fenster → das hintere")
        c.check(MTRules.pick(base, at: CGPoint(x: 50, y: 10), ownPID: own) == .blocked(owner: "Window Server", layer: 24), "Menüleiste → kein Ziel")
        let dock = win(3, 72, "Dock", CGRect(x: 300, y: 900, width: 800, height: 82), layer: 20)
        c.check(MTRules.pick([dock, vsB, desktop], at: CGPoint(x: 400, y: 950), ownPID: own) == .blocked(owner: "Dock", layer: 20), "Dock über dem Fenster → kein Ziel")
        c.check(MTRules.pick([desktop], at: p, ownPID: own) == .blocked(owner: "Dock", layer: -2147483624), "nur Schreibtisch → kein Ziel")
        c.check(MTRules.pick(base, at: CGPoint(x: 5000, y: 5000), ownPID: own) == .none, "Punkt außerhalb aller Fenster → keins")
        let tiny = win(12, 80, "Tool", CGRect(x: 490, y: 490, width: 30, height: 30))
        c.check(MTRules.pick([tiny, vsA], at: p, ownPID: own) == .windows([vsA], covered: true), "Mini-Fenster (< 40 pt) übersprungen, zählt aber als Abdeckung")
        let ghost = win(13, 81, "Ghost", big, alpha: 0)
        c.check(MTRules.pick([ghost, vsA], at: p, ownPID: own) == .windows([vsA], covered: false), "unsichtbares Fenster (α = 0) zählt gar nicht")
        let ws = win(14, 82, "Window Server", big)
        c.check(MTRules.pick([ws, vsA], at: p, ownPID: own) == .windows([vsA], covered: true), "Systemteil auf Ebene 0 übersprungen")
        let many = (0..<7).map { win(CGWindowID(100 + $0), pid_t(200 + $0), "App\($0)", big) }
        if case .windows(let ws, _) = MTRules.pick(many, at: p, ownPID: own) { c.check(ws.count == 4 && ws.first?.id == 100, "höchstens 4 Kandidaten, vorderster zuerst") }
        else { c.check(false, "höchstens 4 Kandidaten") }
        // Parser aus einem echten CGWindowList-Wörterbuch
        let d: [String: Any] = [kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 7, kCGWindowOwnerName as String: "Terminal",
                                kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
                                kCGWindowBounds as String: ["X": -1920.0, "Y": -98.0, "Width": 800.0, "Height": 600.0]]
        let parsed = MTWindowInfo(d, bundle: { _ in "com.apple.Terminal" })
        c.check(parsed == win(42, 7, "Terminal", CGRect(x: -1920, y: -98, width: 800, height: 600), bundle: "com.apple.Terminal"),
                "CGWindowList-Eintrag lesen (negative Koordinaten auf dem linken Monitor)", "\(String(describing: parsed))")

        // ── Eigene Fenster ──
        c.section("Eigene Fenster und ClipVault ausschließen")
        let pill = win(20, own, "Flow", CGRect(x: 300, y: 400, width: 460, height: 150), layer: 25)
        let hub = win(21, own, "Flow", big)
        let card = win(22, own, "Flow", CGRect(x: 400, y: 450, width: 360, height: 120), layer: 101)
        let cv = win(23, 60, "ClipVault", CGRect(x: 200, y: 200, width: 700, height: 600), layer: 3, bundle: "app.flowdictation.clipvault")
        let cvNormal = win(24, 61, "ClipVault", big, bundle: "app.flowdictation.clipvault")
        let hs = win(25, 62, "Hammerspoon", big, layer: 0, alpha: 0.4, bundle: "org.hammerspoon.Hammerspoon")
        c.check(MTRules.pick([pill, vsA], at: p, ownPID: own) == .windows([vsA], covered: true), "Pille (eigene PID, Ebene 25) → hindurch, Klick gesperrt")
        c.check(MTRules.pick([hub, vsA], at: p, ownPID: own) == .windows([vsA], covered: true), "Hub (eigene PID, Ebene 0) nie Ziel")
        c.check(MTRules.pick([card, pill, vsA, vsB], at: p, ownPID: own) == .windows([vsA, vsB], covered: true), "Karte + Pille übereinander → trotzdem das Fenster darunter")
        c.check(MTRules.pick([cv, vsA], at: p, ownPID: own) == .windows([vsA], covered: true), "ClipVault-Panel → hindurch")
        c.check(MTRules.pick([cvNormal, hs, vsA], at: p, ownPID: own) == .windows([vsA], covered: true), "ClipVault-Fenster (Ebene 0) + DimAll-Abdunklung → hindurch")
        c.check(MTRules.pick([pill], at: p, ownPID: own) == .none, "nur eigene Fenster → kein Ziel")

        // ── Fenster ↔ AX-Fenster ──
        c.section("AX-Fenster zuordnen")
        let tgt = win(10, 50, "Code", CGRect(x: 100, y: 100, width: 900, height: 700), title: "projekt — Claude")
        c.check(MTRules.matchWindow(target: tgt, candidates: [(11, nil, nil), (10, nil, nil)]) == 1, "exakte Fenster-Nummer gewinnt")
        c.check(MTRules.matchWindow(target: tgt, candidates: [(nil, CGRect(x: 0, y: 0, width: 800, height: 600), "x"),
                                                                 (nil, CGRect(x: 101, y: 99, width: 902, height: 700), "y")]) == 1, "Rahmen ±3 pt")
        c.check(MTRules.matchWindow(target: tgt, candidates: [(nil, tgt.bounds, "anderes"), (nil, tgt.bounds, "projekt — Claude")]) == 1,
                "zwei gleich große Fenster (übereinander) → Titel entscheidet")
        c.check(MTRules.matchWindow(target: tgt, candidates: [(nil, CGRect(x: 0, y: 0, width: 10, height: 10), "projekt — Claude")]) == 0, "Rahmen weicht ab, Titel eindeutig")
        c.check(MTRules.matchWindow(target: tgt, candidates: [(nil, CGRect(x: 500, y: 500, width: 10, height: 10), "x")]) == nil, "nichts passt → nil")

        // ── Textfeld erkennen ──
        c.section("Textfeld erkennen")
        c.check(MTRules.isEditable(N(role: "AXTextArea")) && MTRules.isEditable(N(role: "AXTextField")) && MTRules.isEditable(N(role: "AXComboBox")),
                "AXTextArea / AXTextField / AXComboBox")
        c.check(MTRules.isEditable(N(role: "AXTextField", subrole: "AXSearchField")), "Suchfeld")
        c.check(!MTRules.isEditable(N(role: "AXSecureTextField")) && !MTRules.isEditable(N(role: "AXTextField", subrole: "AXSecureTextField")), "Passwortfeld nie")
        c.check(!MTRules.isEditable(N(role: "AXGroup", hasInsertionPoint: true)), "Web: Einfügemarke allein nicht (Chromium meldet sie an allen Vorfahren)")
        c.check(MTRules.isEditable(N(role: "AXStaticText", hasEditableAncestor: true)), "Web: Text in contenteditable")
        // Echte Kette aus VS Code (Probe 27.09.): xterm-Eingabefeld ist AXTextField, alle Gruppen darüber melden eine Einfügemarke
        let vsLive = [N(role: "AXTextField", classes: ["xterm-helper-textarea"], hasInsertionPoint: true, hasEditableAncestor: true),
                      N(role: "AXGroup", classes: ["xterm-helpers"], hasInsertionPoint: true), N(role: "AXGroup", classes: ["xterm-screen"], hasInsertionPoint: true),
                      N(role: "AXGroup", classes: ["terminal", "xterm"], hasInsertionPoint: true)]
        c.check(MTRules.pickEditable(vsLive) == .at(0) && MTRules.pickEditable(Array(vsLive.dropFirst())) == .none,
                "VS Code live: Eingabefeld ja, die Gruppen darüber nicht")
        c.check(MTRules.isEditable(N(role: "AXGroup", editableFlag: true)), "Web: AXEditable")
        c.check(!MTRules.isEditable(N(role: "AXStaticText")) && !MTRules.isEditable(N(role: "AXButton")) && !MTRules.isEditable(N(role: "AXWebArea")), "Text, Knopf, Webseite: nein")
        c.check(MTRules.pickEditable([N(role: "AXStaticText"), N(role: "AXGroup"), N(role: "AXTextArea")]) == .at(2), "Text in einem Eingabefeld → Vorfahre (Ebene 2)")
        c.check(MTRules.pickEditable([N(role: "AXStaticText"), N(role: "AXGroup"), N(role: "AXGroup"), N(role: "AXGroup"), N(role: "AXGroup"), N(role: "AXTextArea")]) == .none,
                "mehr als 4 Ebenen darüber → nicht mehr")
        c.check(MTRules.pickEditable([N(role: "AXStaticText"), N(role: "AXSecureTextField"), N(role: "AXTextArea")]) == .secure, "Passwortfeld auf dem Weg → gesperrt")
        c.check(MTRules.pickEditable([N(role: "AXButton"), N(role: "AXWindow"), N(role: "AXTextArea")]) == .none, "Suche endet am Fenster")

        // ── Klick (Methode c) ──
        c.section("Klick nur auf Terminal-Flächen")
        c.check(MTRules.clickAllowed(bundle: "com.apple.Terminal", chain: [N(role: "AXTextArea"), N(role: "AXScrollArea"), N(role: "AXWindow")], covered: false), "Terminal-Fläche → Klick erlaubt")
        c.check(!MTRules.clickAllowed(bundle: "com.apple.Terminal", chain: [N(role: "AXTextArea")], covered: true), "etwas liegt darüber → kein Klick")
        c.check(!MTRules.clickAllowed(bundle: "com.googlecode.iterm2", chain: [N(role: "AXRadioButton"), N(role: "AXTabGroup")], covered: false), "Reiter in iTerm2 → nie")
        c.check(!MTRules.clickAllowed(bundle: "com.apple.Terminal", chain: [N(role: "AXButton"), N(role: "AXWindow")], covered: false), "Fensterknopf → nie")
        c.check(!MTRules.clickAllowed(bundle: "com.apple.Terminal", chain: [N(role: "AXStaticText"), N(role: "AXLink")], covered: false), "Link → nie")
        let xterm = [N(role: "AXGroup", classes: ["xterm-screen"]), N(role: "AXGroup", classes: ["terminal", "xterm"]), N(role: "AXGroup"), N(role: "AXWebArea")]
        c.check(MTRules.clickAllowed(bundle: "com.microsoft.VSCode", chain: xterm, covered: false), "VS Code: über dem Terminal (xterm) → Klick erlaubt")
        c.check(!MTRules.clickAllowed(bundle: "com.microsoft.VSCode", chain: [N(role: "AXTextArea", classes: ["inputarea"]), N(role: "AXGroup", classes: ["monaco-editor"])], covered: false),
                "VS Code: Code-Editor → kein Klick")
        c.check(!MTRules.clickAllowed(bundle: "com.microsoft.VSCode", chain: [N(role: "AXGroup"), N(role: "AXWebArea")], covered: false), "VS Code ohne Klassen (Baum fehlt) → kein Klick")
        c.check(!MTRules.clickAllowed(bundle: "com.microsoft.VSCode", chain: [N(role: "AXButton", classes: ["xterm-link"])] + xterm, covered: false), "Knopf im Terminal-Bereich → nie")
        c.check(!MTRules.clickAllowed(bundle: "com.google.Chrome", chain: [N(role: "AXGroup")], covered: false) &&
                !MTRules.clickAllowed(bundle: "com.apple.TextEdit", chain: [N(role: "AXTextArea")], covered: false), "Nicht-Terminals (Chrome, TextEdit) → nie klicken")

        // ── Enter-Liste ──
        c.section("Danach abschicken (Enter) – nur wo Enter „senden“ heißt")
        func send(_ b: String, _ ch: [N], _ host: String? = nil) -> Bool { MTRules.autoSend(bundle: b, chain: ch, webHost: host).allowed }
        c.check(send("com.apple.Terminal", [N(role: "AXTextArea")]) && send("com.googlecode.iterm2", []) && send("com.mitchellh.ghostty", []), "Terminal, iTerm2, Ghostty")
        c.check(send("com.microsoft.VSCode", [N(role: "AXTextArea", classes: ["xterm-helper-textarea"])] + xterm), "VS Code-Terminal (Claude Code)")
        c.check(send("com.todesktop.230313mzl4w4u92", [N(role: "AXTextArea", classes: ["xterm-helper-textarea"])] + xterm), "Cursor-Terminal")
        c.check(!send("com.microsoft.VSCode", [N(role: "AXTextArea", classes: ["inputarea"]), N(role: "AXGroup", classes: ["monaco-editor"])]), "VS Code Code-Editor → nie")
        c.check(send("com.microsoft.VSCode", [N(role: "AXTextArea"), N(role: "AXGroup", classes: ["monaco-editor"]), N(role: "AXGroup", classes: ["interactive-input-part"])]),
                "VS Code Chat-Eingabe (Copilot)")
        c.check(send("com.microsoft.VSCode", [N(role: "AXTextArea"), N(role: "AXGroup"), N(role: "AXWebArea"), N(role: "AXGroup"), N(role: "AXWebArea")]),
                "VS Code Webview-Chat (Claude-Code-Erweiterung)")
        c.check(!send("com.microsoft.VSCode", [N(role: "AXGroup"), N(role: "AXWebArea")]), "VS Code sonst → nein")
        c.check(send("com.anthropic.claudefordesktop", [N(role: "AXTextArea")]) && send("com.openai.chat", []) && send("com.apple.MobileSMS", [])
                && send("net.whatsapp.WhatsApp", []) && send("com.tinyspeck.slackmacgap", []), "Claude, ChatGPT, Nachrichten, WhatsApp, Slack")
        let webField = [N(role: "AXTextArea"), N(role: "AXGroup"), N(role: "AXWebArea")]
        c.check(send("com.google.Chrome", webField, "chatgpt.com") && send("com.google.Chrome", webField, "claude.ai") && send("com.apple.Safari", webField, "web.whatsapp.com"),
                "Chrome/Safari: ChatGPT, claude.ai, WhatsApp Web")
        c.check(send("com.google.Chrome", [N(role: "AXStaticText", hasEditableAncestor: true), N(role: "AXGroup"), N(role: "AXWebArea")], "gemini.google.com"),
                "Chrome: contenteditable-Chatfeld")
        c.check(!send("com.google.Chrome", webField, "docs.google.com") && !send("com.google.Chrome", webField, "mail.google.com"), "Google Docs, Gmail → nie")
        c.check(!send("com.google.Chrome", webField, "notchatgpt.com") && send("com.google.Chrome", webField, "www.chatgpt.com"), "Host-Endung sauber geprüft")
        c.check(!send("com.google.Chrome", [N(role: "AXTextField")], "chatgpt.com"), "Adressleiste (außerhalb der Seite) → nie")
        c.check(!send("com.google.Chrome", webField, nil), "unbekannte Seite → nein")
        c.check(!send("com.apple.mail", [N(role: "AXTextArea")]) && !send("com.apple.Notes", [N(role: "AXTextArea")]) && !send("com.apple.TextEdit", [N(role: "AXTextArea")])
                && !send("com.apple.dt.Xcode", [N(role: "AXTextArea")]) && !send("com.microsoft.Word", []), "Mail, Notizen, TextEdit, Xcode, Word → nie")
        c.check(!send("com.apple.Terminal", [N(role: "AXSecureTextField")]), "Passwortfeld → nie")

        // ── Einfügen bestätigt? ──
        c.section("Einfügen bestätigt (vor dem Enter)")
        c.check(MTRules.pasteConfirmed(inserted: "Hallo Welt, wie geht's?", fieldValue: "Vorher. Hallo Welt, wie geht's?", valueBefore: nil) == true, "Text steht im Feld → ja")
        c.check(MTRules.pasteConfirmed(inserted: "Hallo  Welt\n", fieldValue: "Hallo Welt", valueBefore: nil) == true, "Leerzeichen/Zeilenumbrüche egal")
        c.check(MTRules.pasteConfirmed(inserted: "Hallo Welt", fieldValue: "etwas anderes", valueBefore: nil) == false, "Text fehlt → nein (kein Enter)")
        c.check(MTRules.pasteConfirmed(inserted: "x", fieldValue: "gleich", valueBefore: "gleich") == false, "Feld unverändert → nein")
        c.check(MTRules.pasteConfirmed(inserted: "Hallo", fieldValue: "", valueBefore: nil) == nil && MTRules.pasteConfirmed(inserted: "Hallo", fieldValue: nil, valueBefore: nil) == nil,
                "leer/unlesbar (Terminal) → nur Fokus zählt")
        c.check(MTRules.shortTitle("ein sehr langer Fenstertitel mit Details") == "ein sehr langer Fe…" && MTRules.shortTitle("kurz") == "kurz", "Fenstertitel fürs Protokoll gekürzt")
        return c.finish("Maus-Ziel")
    }
}
