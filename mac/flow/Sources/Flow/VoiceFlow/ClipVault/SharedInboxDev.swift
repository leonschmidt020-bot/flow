import AppKit
import SwiftUI

// MARK: - Sichtprüfung + Tests „Neu von Nico“ (offscreen, schreibt NICHTS in ~/.config/flow-clipvault)
//   Flow --shared-inbox-renders <ordner>   Liste für 1/3/6 Einträge × Pille unten/oben/rechts/links + Wachsen + Karten
//   Flow --shared-gist-test [--echt]       Klassifizierer: erfundene Beispiele; mit --echt zusätzlich die Texte aus
//                                            shared.json (nur lesend) – ausgegeben werden NUR Art + Kernaussage + Zeit
//   Flow --shared-inbox-geometry           Lage der Liste auf allen Bildschirm-Anordnungen nachrechnen
//   Flow --pill-hover-test [-v]            Überfahren der ruhenden Pille nachspielen (echte PillView, unsichtbares
//                                            Fenster): öffnet „Neu vom Partner“ von JEDER Stelle der Pille aus? alt vs. neu

enum SharedInboxDev {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--shared-inbox-renders": return renders(dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "inbox_renders")
        case "--shared-gist-test": return gistTest(real: args.contains("--echt"))
        case "--shared-inbox-geometry": return geometry()
        case "--pill-hover-test": return pillHoverTest(verbose: args.contains("-v"))
        default: return nil
        }
    }

    // MARK: Beispiele (erfunden)

    static let sampleTexts: [(String, String)] = [
        ("auftrag", """
        Hey Lena,

        # Auftrag für deinen Agent: Flow auf 1.7.3 updaten

        Bitte gib das so an deinen Claude weiter:
        - Prüfe, ob noch lokale Änderungen in flow/ liegen
        - Baue die App mit ./build.sh und teste das Diktat
        - Lies danach das Protokoll und schick mir den Fehlerbericht
        ```bash
        cd "$HOME/Library/Application Support/Flow/src/mac/flow" && ./update.sh
        ```
        Danke dir!
        """),
        ("bericht", """
        # Flow-Fehlerbericht
        Von: Nico · 2026-09-27T12:03:11Z
        Version: 1.7.1 (a1b2c3d) · macOS Version 26.0 (Build 25A354)
        App: /Users/nico/Applications/Flow.app · Quelle: –

        ## Freigaben
        Mikrofon: ja
        Bedienungshilfen: NEIN
        Eingabeüberwachung: ja

        ## Einstellungen
        Motor: whisper · Sprache: auto
        """),
        ("link", "https://example.com/artikel/wanderschuhe-trail-42"),
        ("liste", "Einkaufsliste:\n- Milch\n- Eier\n- Vollkornbrot\n- Tomaten\n- Bergkäse"),
        ("todo", "Ausflug Samstag\n[ ] Busangebot bestätigen\n[ ] Namensschilder drucken\n[x] Liederliste an Mia\n[ ] Erste-Hilfe-Koffer"),
        ("frage", "Kannst du mir bis Freitag die Busangebote für den Ausflug schicken? Dann entscheiden wir am Wochenende."),
        ("nachricht", "Moin Lena – ich hab gerade mit Pierre telefoniert, er meint, die neue Übersicht soll ab nächster Woche auch die Wochenzahlen zeigen. Können wir morgen kurz drüber reden, bevor du anfängst?"),
        ("code", "```swift\nfunc greet(_ name: String) -> String {\n    return \"Hallo \\(name)\"\n}\nprint(greet(\"Nico\"))\n```"),
        ("prompt", "Prompt für deinen Agent:\nDu bist ein Senior-iOS-Entwickler. Baue in der Beispiel-App eine Einstellung, mit der man die Notch-Animation abschalten kann.\n1. Lies zuerst README.md\n2. Füge die Einstellung in SettingsView hinzu\n3. Teste auf dem iPhone 16 Pro\n4. Committe mit klarer Nachricht"),
    ]

    static func sampleItems(dir: URL, count: Int) -> [SharedVaultItem] {
        let now = Date()
        let shot = dir.appendingPathComponent("_beispiel_screenshot.png")
        if !FileManager.default.fileExists(atPath: shot.path) { drawScreenshot(to: shot) }
        func t(_ id: String, _ key: String, _ ago: Double, kind: CVKind = .text) -> SharedVaultItem {
            SharedVaultItem(id: id, kind: kind, text: sampleTexts.first { $0.0 == key }!.1, image: nil, fileName: nil,
                            createdBy: "Nico", createdAt: now.addingTimeInterval(-ago), pinned: false)
        }
        let all: [SharedVaultItem] = [
            t("a", "auftrag", 40),
            SharedVaultItem(id: "img", kind: .image, text: "Visual Studio Code\nSharedInboxBadge.swift — flow\nfunc openList() {\n  guard !isListOpen", image: shot,
                            fileName: nil, createdBy: "Nico", createdAt: now.addingTimeInterval(-160), pinned: false),
            t("b", "bericht", 420),
            SharedVaultItem(id: "f", kind: .file, text: nil, image: nil, fileName: "Sommer-Rückblick_2026_final.mp4", createdBy: "Nico",
                            createdAt: now.addingTimeInterval(-900), pinned: false, size: 30_421_636),
            t("l", "link", 1800, kind: .link),
            t("q", "frage", 3900),
            t("n", "nachricht", 7300),
        ]
        switch count {
        case 1: return [all[0]]
        case 3: return [all[0], all[1], all[3]]
        default: return Array(all.prefix(count))
        }
    }

    /// Erfundener „VS Code“-Screenshot fürs Vorschaubild
    static func drawScreenshot(to url: URL) {
        let w = 1440, h = 900
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 260, height: h).fill()
        NSColor(red: 0.20, green: 0.20, blue: 0.24, alpha: 1).setFill(); NSRect(x: 0, y: h - 44, width: w, height: 44).fill()
        let cols: [NSColor] = [.systemPink, .systemTeal, .systemYellow, .systemPurple, .white, .systemGreen]
        for i in 0..<30 {
            let c = cols[(i * 7) % cols.count].withAlphaComponent(0.8)
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: 300 + (i % 4) * 30, y: h - 90 - i * 26, width: 180 + (i * 53) % 520, height: 12), xRadius: 4, yRadius: 4).fill()
        }
        for i in 0..<18 { NSColor.white.withAlphaComponent(0.25).setFill(); NSRect(x: 24, y: h - 90 - i * 32, width: 120 + (i * 37) % 90, height: 10).fill() }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Bilder

    struct Placement { let name: String; let pill: NSRect }
    static let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)
    static var placements: [Placement] {
        let s = screen
        return [Placement(name: "unten", pill: NSRect(x: s.midX - 48, y: s.minY + 10, width: 96, height: 26)),
                Placement(name: "rechts", pill: NSRect(x: s.maxX - 8 - 26, y: s.midY - 48, width: 26, height: 96)),
                Placement(name: "links", pill: NSRect(x: s.minX + 8, y: s.minY + 150, width: 26, height: 96)),
                Placement(name: "oben", pill: NSRect(x: s.midX - 48, y: s.maxY - 36, width: 96, height: 26))]
    }

    static func renders(dir: String) -> Int32 {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for n in [1, 3, 6] {
            let items = sampleItems(dir: out, count: n)
            for p in placements {
                let u = out.appendingPathComponent("liste_\(n)_\(p.name).png")
                ok = SharedInboxBadge.renderScene(items: items, pill: p.pill, screen: screen, to: u) && ok
                print(u.path)
            }
        }
        let six = sampleItems(dir: out, count: 6)
        // Zustände: angesehen (Punkte weg) + einer kopiert
        let u1 = out.appendingPathComponent("liste_3_zustaende.png")
        ok = SharedInboxBadge.renderScene(items: sampleItems(dir: out, count: 3), pill: placements[0].pill, screen: screen,
                                          viewed: ["a", "img"], copied: ["img"], to: u1) && ok; print(u1.path)
        // Wachsen aus der Pille
        for (i, pr) in [0.15, 0.45, 0.8].enumerated() {
            let u = out.appendingPathComponent("wachsen_\(i + 1).png")
            ok = SharedInboxBadge.renderScene(items: six, pill: placements[1].pill, screen: screen, progress: CGFloat(pr), to: u) && ok
            print(u.path)
        }
        // Ankündigungskarten mit Art + Kernaussage
        for it in sampleItems(dir: out, count: 7) {
            let n = SharedInboxBadge.announceNotice(it, total: 1, illustration: "illu_geteilt_2", copy: {}, open: {})
            let u = out.appendingPathComponent("karte_\(it.id).png")
            ok = VFNotify.renderPNG(n, to: u, pill: NSRect(x: 700, y: 30, width: 96, height: 26)) && ok
            print(u.path)
        }
        return ok ? 0 : 1
    }

    // MARK: Klassifizierer

    static func gistTest(real: Bool) -> Int32 {
        _ = NSApplication.shared
        print("— Beispiele (erfunden) —")
        for (key, text) in sampleTexts {
            let t0 = Date()
            let g = SharedGistMaker.forText(text)
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "%-9@ %6.2f ms  %@", key as NSString, ms, g.line))
        }
        let f = SharedGistMaker.file(name: "Camp-Rückblick.mp4", size: 30_421_636)
        print("datei              \(f.line)")
        guard real else { return 0 }
        print("— shared.json (nur lesend; gezeigt werden NUR Art + Kernaussage) —")
        let url = ClipVaultClient.base.appendingPathComponent("shared.json")
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let arr = o["items"] as? [[String: Any]] else { print("shared.json nicht lesbar"); return 1 }
        var worst = 0.0, total = 0.0, n = 0
        for x in arr {
            let kind: CVKind = { switch x["kind"] as? String { case "image": return .image; case "link": return .link; case "file": return .file; default: return .text } }()
            let id = (x["id"] as? String) ?? UUID().uuidString
            let img = ClipVaultClient.base.appendingPathComponent("shared/\(id).png")
            let item = SharedVaultItem(id: id, kind: kind, text: x["text"] as? String,
                                       image: kind == .image && FileManager.default.fileExists(atPath: img.path) ? img : nil,
                                       fileName: x["fileName"] as? String, createdBy: (x["createdBy"] as? String) ?? "?",
                                       createdAt: Date(timeIntervalSince1970: (x["createdAt"] as? Double) ?? 0), pinned: false,
                                       size: (x["size"] as? NSNumber)?.int64Value)
            let t0 = Date()
            let g = SharedGistMaker.make(item)
            let ms = Date().timeIntervalSince(t0) * 1000
            worst = max(worst, ms); total += ms; n += 1
            let len = (x["text"] as? String)?.count ?? 0
            print(String(format: "%-6@ %5d Z. %6.2f ms  %@", String((x["createdBy"] as? String ?? "?").prefix(5)) as NSString, len, ms, g.line))
        }
        print(String(format: "%d Einträge · Schnitt %.2f ms · langsamster %.2f ms · Apple Intelligence: %@", n, total / Double(max(n, 1)), worst,
                     SharedGistAI.available ? "verfügbar" : "nicht verfügbar"))
        return worst < 5 ? 0 : 1
    }

    // MARK: Geometrie

    static func geometry() -> Int32 {
        // Anordnungen: MacBook allein, MSI über dem MacBook, Monitor links (negative x), hochkant-Monitor rechts
        let mac = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let setups: [(String, [NSRect])] = [
            ("MacBook", [mac]),
            ("MSI oben", [mac, NSRect(x: -200, y: 982, width: 2560, height: 1440)]),
            ("Monitor links", [mac, NSRect(x: -1920, y: -98, width: 1920, height: 1080)]),
            ("Hochkant rechts", [mac, NSRect(x: 1512, y: -400, width: 1080, height: 1920)]),
        ]
        var fails = 0, checks = 0
        for (name, screens) in setups {
            for sf in screens {
                let vis = NSRect(x: sf.minX, y: sf.minY, width: sf.width, height: sf.height - 33)   // Menüleiste
                let pills: [(String, NSRect)] = [
                    ("unten", NSRect(x: vis.midX - 48, y: vis.minY + 10, width: 96, height: 26)),
                    ("oben", NSRect(x: vis.midX - 48, y: vis.maxY - 36, width: 96, height: 26)),
                    ("rechts", NSRect(x: vis.maxX - 34, y: vis.midY - 48, width: 26, height: 96)),
                    ("links", NSRect(x: vis.minX + 8, y: vis.midY - 48, width: 26, height: 96)),
                    ("rechts unten", NSRect(x: vis.maxX - 34, y: vis.minY + 12, width: 26, height: 96)),
                    ("links oben", NSRect(x: vis.minX + 8, y: vis.maxY - 110, width: 26, height: 96)),
                    ("unten Ecke", NSRect(x: vis.maxX - 110, y: vis.minY + 10, width: 96, height: 26)),
                ]
                for (pn, pill) in pills {
                    for rows in [1, 4, 6] {
                        checks += 1
                        let wanted = CGFloat(72 + 44 + 2 + rows * 96)
                        let maxH = SharedInboxBadge.maxCardHeight(pill: pill, visible: vis)
                        let size = NSSize(width: SharedInboxBadge.listWidth, height: min(wanted, maxH))
                        let lay = SharedInboxBadge.listLayout(card: size, pill: pill, visible: vis, frame: sf)
                        let card = lay.hitRectsInScreen[0]
                        let inside = vis.insetBy(dx: 9.5, dy: 9.5).contains(card)
                        let noOverlap = !card.intersects(pill)
                        let winOK = sf.contains(lay.windowFrame)
                        let corridor = SharedInboxBadge.corridor(pill: pill, card: card)
                        // Weg Pille → Liste: jeder Punkt auf der Verbindungslinie liegt im Korridor
                        let path = (0...20).allSatisfy { i in
                            let t = CGFloat(i) / 20
                            return corridor.contains(NSPoint(x: pill.midX + (card.midX - pill.midX) * t, y: pill.midY + (card.midY - pill.midY) * t))
                        }
                        if !(inside && noOverlap && winOK && path) {
                            fails += 1
                            print("✗ \(name) · Bildschirm \(Int(sf.minX)),\(Int(sf.minY)) · Pille \(pn) · \(rows) Zeilen: innen \(inside) frei \(noOverlap) Fenster \(winOK) Korridor \(path)")
                        }
                    }
                }
            }
        }
        // Echte Anordnung (08.10.2026): MacBook Hauptbildschirm, Monitor B rechts oben, Monitor A links oben; Pille „Mitte rechts“
        // auf allen drei, beim Überfahren waagerecht (~82 × 24). Die Liste muss auf DEMSELBEN Bildschirm wie die Pille liegen.
        let joel: [(String, NSRect, NSRect)] = [
            ("MacBook", NSRect(x: 0, y: 0, width: 1512, height: 982), NSRect(x: 0, y: 0, width: 1512, height: 949)),
            ("Monitor B", NSRect(x: 1027, y: 982, width: 1920, height: 1080), NSRect(x: 1027, y: 982, width: 1920, height: 1080)),
            ("Monitor A", NSRect(x: -1021, y: 982, width: 2048, height: 1152), NSRect(x: -1021, y: 982, width: 2048, height: 1152)),
        ]
        for (name, sf, vis) in joel {
            checks += 1
            let c = PillPreset.middleRight.center(in: vis)
            let w: CGFloat = 82, h: CGFloat = 24
            let cx = min(max(c.x, vis.minX + w / 2 + 6), vis.maxX - w / 2 - 6)
            let pill = NSRect(x: cx - w / 2, y: c.y - h / 2, width: w, height: h)
            let lay = SharedInboxBadge.listLayout(card: NSSize(width: SharedInboxBadge.listWidth, height: 230), pill: pill, visible: vis, frame: sf)
            let card = lay.hitRectsInScreen[0]
            let sameScreen = sf.contains(card) && sf.contains(lay.windowFrame)
            let free = !card.intersects(pill)
            print("  echt/\(name): Pille \(Int(pill.minX)),\(Int(pill.minY)) → Liste \(Int(card.minX)),\(Int(card.minY)) \(Int(card.width))×\(Int(card.height))")
            if !(sameScreen && free) { fails += 1; print("✗ echt/\(name): gleicher Bildschirm \(sameScreen) frei \(free)") }
            // Protokoll vom 07./08.10. „Liste geöffnet (1) bei 1022,221 480×230“ = genau diese Lage auf dem MacBook
            if name == "MacBook" {
                checks += 1
                if abs(card.minX - 1022) > 1 || abs(card.minY - 221) > 2 { fails += 1; print("✗ MacBook-Lage passt nicht zum Protokoll (1022,221)") }
            }
        }
        // Rahmen-Klick: auf dem Rahmen ja, auf der Kapsel nein, weit weg nein
        let pill = NSRect(x: 100, y: 100, width: 96, height: 26)
        let ringOK = SharedInboxBadge.isOnRing(NSPoint(x: 148, y: 128.5), pill: pill) && !SharedInboxBadge.isOnRing(NSPoint(x: 148, y: 113), pill: pill)
            && !SharedInboxBadge.isOnRing(NSPoint(x: 148, y: 140), pill: pill)
        if !ringOK { fails += 1; print("✗ Rahmen-Klick-Zone") }
        print("\(checks + 1) Lage-Prüfungen, \(fails) Fehler")
        return fails == 0 ? 0 : 1
    }

    // MARK: Überfahren der Pille (echte PillView in einem unsichtbaren Fenster, Maus nachgespielt)

    /// Spielt für jede Stelle der ruhenden Pille 1,5 s „Maus liegt still drauf“ nach: PillController-Takt (20/s) setzt
    /// den Hover, die Pille animiert (60/s), SharedInboxBadge prüft alle 50 ms „Maus auf der Pille“ und öffnet nach 0,4 s.
    /// alt = Rechteck der GERADE gezeichneten Kapsel ± 6 pt (bis 1.7.23) · neu = PillView.hoverZoneContains + isHovered
    static func pillHoverTest(verbose: Bool) -> Int32 {
        _ = NSApplication.shared
        let screens: [(String, NSRect)] = [("MacBook", NSRect(x: 0, y: 0, width: 1512, height: 949)),
                                           ("Monitor B", NSRect(x: 1027, y: 982, width: 1920, height: 1080)),
                                           ("Monitor A", NSRect(x: -1021, y: 982, width: 2048, height: 1152))]
        let presets: [PillPreset] = [.middleRight, .middleLeft, .bottomCenter, .topRight]
        var fails = 0
        func pad(_ x: String, _ n: Int) -> String { x.padding(toLength: max(n, x.count), withPad: " ", startingAt: 0) }
        print(pad("Bildschirm", 11) + pad("Pille", 14) + pad("öffnet alt", 12) + pad("öffnet neu", 12) + "flackert alt")
        for (sname, vis) in screens {
            for preset in presets {
                var oldOK = 0, newOK = 0, total = 0, oldFlicker = 0
                // Raster über die ruhende Kapsel ± 6 pt (Fangbereich)
                let probe = makePill(vis: vis, preset: preset)
                let zone = probe.view.restRectInScreen.insetBy(dx: -PillView.hitMargin + 0.5, dy: -PillView.hitMargin + 0.5)
                var pts: [NSPoint] = []
                for iy in 0...10 { for ix in 0...4 {
                    pts.append(NSPoint(x: zone.minX + zone.width * CGFloat(ix) / 4, y: zone.minY + zone.height * CGFloat(iy) / 10))
                } }
                for m in pts {
                    total += 1
                    let a = simulate(vis: vis, preset: preset, mouse: m, legacy: true)
                    let b = simulate(vis: vis, preset: preset, mouse: m, legacy: false)
                    if a.opens { oldOK += 1 }
                    if b.opens { newOK += 1 } else if verbose { print("   ✗ neu öffnet nicht bei \(Int(m.x)),\(Int(m.y)) (Wechsel \(b.toggles))") }
                    if a.toggles > 2 { oldFlicker += 1 }
                    if b.toggles > 1 { fails += 1; print("   ✗ neu flackert bei \(Int(m.x)),\(Int(m.y)): \(b.toggles) Wechsel") }
                }
                if newOK != total { fails += total - newOK }
                print(pad(sname, 11) + pad(preset.rawValue, 14) + pad("\(oldOK)/\(total)", 12) + pad("\(newOK)/\(total)", 12) + "\(oldFlicker)")
            }
        }
        // Weg: Maus verlässt die Pille → Hover geht wirklich aus (keine „klebende“ Pille)
        let far = simulate(vis: screens[0].1, preset: .middleRight, mouse: NSPoint(x: 1380, y: 474), legacy: false)
        if far.everHover { fails += 1; print("✗ Hover an, obwohl die Maus 100 pt neben der Pille liegt") }
        let leave = leaveTest(vis: screens[0].1)
        if !leave { fails += 1; print("✗ Hover bleibt nach dem Verlassen an") }
        // ClipVault-Knopf unter der Pille (19.10.2026): sichtbar, auf dem Bildschirm, Weg dorthin hält den Hover
        var cvOK = 0, cvTotal = 0
        for (sname, vis) in screens {
            for preset in presets + [.bottomLeft, .topCenter] {
                cvTotal += 1
                if let why = clipButtonTest(vis: vis, preset: preset) { fails += 1; print("   ✗ ClipVault-Knopf \(sname) \(preset.rawValue): \(why)") }
                else { cvOK += 1 }
            }
        }
        print("ClipVault-Knopf: \(cvOK)/\(cvTotal) Anordnungen ok")
        print(fails == 0 ? "ALLE PRÜFUNGEN OK (neu öffnet von jeder Stelle der Pille, kein Flackern)" : "\(fails) FEHLER")
        return fails == 0 ? 0 : 1
    }

    private static func makePill(vis: NSRect, preset: PillPreset) -> (view: PillView, panel: NSPanel) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        let v = PillView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        panel.contentView = v
        let pl = PillPlacement(preset: preset)
        let a = pl.center(in: vis)
        v.vertical = pl.isSide
        v.screenRect = vis
        v.anchor = a
        panel.setFrameOrigin(PillController.panelOrigin(anchor: a, size: panel.frame.size, screen: vis))
        for _ in 0..<80 { v.tick() }     // Ruhe-Größe einschwingen
        return (v, panel)
    }

    /// 1,5 s Maus still bei `mouse`. opens = SharedInboxBadge hätte nach 0,4 s geöffnet; toggles = Hover-Wechsel
    private static func simulate(vis: NSRect, preset: PillPreset, mouse m: NSPoint, legacy: Bool) -> (opens: Bool, toggles: Int, everHover: Bool) {
        let (v, panel) = makePill(vis: vis, preset: preset)
        _ = panel
        var hover = false, toggles = 0, run = 0, best = 0, ever = false
        for _ in 0..<30 {                                   // 30 × 50 ms
            let hit = legacy ? v.capsuleRectInScreen.insetBy(dx: -6, dy: -6).contains(m) : v.hoverZoneContains(m)
            if hit != hover { toggles += 1; hover = hit }
            ever = ever || hit
            v.setHover(hit)
            for _ in 0..<3 { v.tick() }                     // Pille animiert 60/s
            let pill = v.capsuleRectInScreen
            let onPill = legacy ? pill.insetBy(dx: -6, dy: -6).contains(m) : (pill.insetBy(dx: -6, dy: -6).contains(m) || v.isHovered)
            run = onPill ? run + 1 : 0
            best = max(best, run)
        }
        return (best * 50 > Int(SharedInboxBadge.hoverDelay * 1000) + 50, toggles, ever)
    }

    /// nil = ok, sonst der Grund
    private static func clipButtonTest(vis: NSRect, preset: PillPreset) -> String? {
        let (v, panel) = makePill(vis: vis, preset: preset)
        _ = panel
        v.clipVaultCheck = { true }
        let start = NSPoint(x: v.restRectInScreen.midX, y: v.restRectInScreen.midY)
        for _ in 0..<12 { v.setHover(v.hoverZoneContains(start)); for _ in 0..<3 { v.tick() } }
        guard v.isHovered else { return "Hover geht auf der Pille nicht an" }
        guard let cb = v.clipButtonRectInScreen else { return "kein Knopf beim Drüberfahren" }
        let pill = v.hoverRectInScreen
        if !vis.contains(cb) { return "Knopf ragt aus dem Bildschirm" }
        if cb.intersects(pill) { return "Knopf überdeckt die Pille" }
        let roomBelow = pill.minY - PillView.clipButtonGap - PillView.clipButtonSize >= vis.minY + 4
        if roomBelow && cb.maxY > pill.minY { return "Knopf nicht unter der Pille, obwohl Platz ist" }
        // Weg von der Pillenmitte zur Knopfmitte in 12 Schritten: Hover bleibt immer an
        let end = NSPoint(x: cb.midX, y: cb.midY)
        for i in 0...12 {
            let f = CGFloat(i) / 12
            let m = NSPoint(x: pill.midX + (end.x - pill.midX) * f, y: pill.midY + (end.y - pill.midY) * f)
            v.setHover(v.hoverZoneContains(m)); for _ in 0..<3 { v.tick() }
            if !v.isHovered { return "Hover geht auf dem Weg zum Knopf aus (\(Int(m.x)),\(Int(m.y)))" }
        }
        for _ in 0..<20 { v.setHover(v.hoverZoneContains(end)); for _ in 0..<3 { v.tick() } }
        guard v.isHovered, v.clipButtonRectInScreen == cb else { return "Knopf springt/verschwindet, wenn die Maus drauf liegt" }
        // Ohne ClipVault kein Knopf
        v.setHover(false); v.clipVaultCheck = { false }; v.setHover(true)
        if v.clipButtonRectInScreen != nil { return "Knopf sichtbar, obwohl ClipVault fehlt" }
        return nil
    }

    private static func leaveTest(vis: NSRect) -> Bool {
        let (v, panel) = makePill(vis: vis, preset: .middleRight)
        _ = panel
        let on = NSPoint(x: v.restRectInScreen.midX, y: v.restRectInScreen.maxY + 3)
        for _ in 0..<10 { v.setHover(v.hoverZoneContains(on)); for _ in 0..<3 { v.tick() } }
        guard v.isHovered else { return false }
        let off = NSPoint(x: v.restRectInScreen.midX - 140, y: v.restRectInScreen.midY + 80)
        for _ in 0..<10 { v.setHover(v.hoverZoneContains(off)); for _ in 0..<3 { v.tick() } }
        return !v.isHovered
    }
}
