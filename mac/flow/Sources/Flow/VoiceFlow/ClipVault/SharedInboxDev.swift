import AppKit
import SwiftUI

// MARK: - Sichtprüfung + Tests „Neu von Nico“ (offscreen, schreibt NICHTS in ~/.config/flow-clipvault)
//   Flow --shared-inbox-renders <ordner>   Liste für 1/3/6 Einträge × Pille unten/oben/rechts/links + Wachsen + Karten
//   Flow --shared-gist-test [--echt]       Klassifizierer: erfundene Beispiele; mit --echt zusätzlich die Texte aus
//                                            shared.json (nur lesend) – ausgegeben werden NUR Art + Kernaussage + Zeit
//   Flow --shared-inbox-geometry           Lage der Liste auf allen Bildschirm-Anordnungen nachrechnen

enum SharedInboxDev {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--shared-inbox-renders": return renders(dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "inbox_renders")
        case "--shared-gist-test": return gistTest(real: args.contains("--echt"))
        case "--shared-inbox-geometry": return geometry()
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
        // Rahmen-Klick: auf dem Rahmen ja, auf der Kapsel nein, weit weg nein
        let pill = NSRect(x: 100, y: 100, width: 96, height: 26)
        let ringOK = SharedInboxBadge.isOnRing(NSPoint(x: 148, y: 128.5), pill: pill) && !SharedInboxBadge.isOnRing(NSPoint(x: 148, y: 113), pill: pill)
            && !SharedInboxBadge.isOnRing(NSPoint(x: 148, y: 140), pill: pill)
        if !ringOK { fails += 1; print("✗ Rahmen-Klick-Zone") }
        print("\(checks + 1) Lage-Prüfungen, \(fails) Fehler")
        return fails == 0 ? 0 : 1
    }
}
