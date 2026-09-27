import AppKit
import SwiftUI

// MARK: - Sichtprüfung ClipVault-Modus (offscreen, schreibt NICHTS in ~/.config/flow-clipvault)
//   Flow --cv-render <ordner> [demo]   demo = erfundene Einträge statt deinem echten Verlauf
//   Flow --cv-test                     Selbsttest Datenzugriff (nur Zählwerte, keine Inhalte)
// Verdrahtung (optional) in CLI.run:  default: return CVDev.run(args) ?? VFPagesDev.run(args)

enum CVDev {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--cv-render":
            return render(dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "cv_render", demo: args.contains("demo"))
        case "--cv-test": return selfTest()
        case "--cv-ping": return ping()
        default: return SharedInboxDev.run(args)
        }
    }

    /// Befehlskanal prüfen: harmloses „ping“ (ändert nichts) und auf die Antwort warten
    static func ping() -> Int32 {
        _ = NSApplication.shared
        let cv = ClipVaultClient.shared
        guard let token = cv.token else { print("kein Token (~/.config/flow-clipvault/token)"); return 1 }
        let req = UUID().uuidString
        var answer: String?
        let obs = DistributedNotificationCenter.default().addObserver(forName: ClipVaultClient.resultName, object: nil, queue: .main) { n in
            if let s = n.object as? String, s.contains(req) { answer = s }
        }
        let obj: [String: Any] = ["token": token, "action": "ping", "reqId": req]
        let json = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        let t0 = Date()
        DistributedNotificationCenter.default().postNotificationName(ClipVaultClient.commandName, object: json, userInfo: nil, deliverImmediately: true)
        while answer == nil && Date().timeIntervalSince(t0) < 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        DistributedNotificationCenter.default().removeObserver(obs)
        print(answer.map { String(format: "Antwort nach %.0f ms: %@", Date().timeIntervalSince(t0) * 1000, $0) } ?? "keine Antwort in 3 s")
        return answer == nil ? 1 : 0
    }

    static func selfTest() -> Int32 {
        let cv = ClipVaultClient.shared
        cv.reload(force: true, sync: true)
        let kinds = Dictionary(grouping: cv.items, by: \.kind).mapValues(\.count)
        print("Einträge: \(cv.items.count) · Bereiche: \(cv.collections.count)")
        print("Arten: " + CVKind.allCases.map { "\($0.label)=\(kinds[$0] ?? 0)" }.joined(separator: " "))
        print("angeheftet=\(cv.items.filter(\.pinned).count) inBereich=\(cv.items.filter { $0.collection != nil }.count) geheim=\(cv.items.filter { cv.isSecret($0) }.count)")
        print("Link-Vorschauen gefunden: \(cv.items.compactMap(\.url).filter { cv.linkPreviewImageURL($0) != nil }.count)")
        let imgs = cv.items.filter { $0.kind == .image }.prefix(5)
        let t0 = Date()
        let ok = imgs.filter { cv.imageURL($0).flatMap { CVThumbs.make($0, maxPixel: 320) } != nil }.count
        print(String(format: "Thumbnails: %d/%d in %.0f ms", ok, imgs.count, Date().timeIntervalSince(t0) * 1000))
        let st = cv.status()
        print("ClipVault läuft=\(st.running) hotkey=\(st.hotkeyOK) · Befehlskanal=\(cv.canSendCommands ? "Token da" : "kein Token")")
        return 0
    }

    static func render(dir: String, demo: Bool, size: NSSize = NSSize(width: 1512, height: 949)) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cv = ClipVaultClient.shared
        if demo {
            let (i, c) = demoData()
            cv.replaceForPreview(items: i, collections: c)
        } else {
            cv.reload(force: true, sync: true)
        }
        let st = CVHubState.shared
        let hub = VFHub.shared
        func first(_ f: (CVItem) -> Bool) -> String? { cv.items.first(where: f)?.id }

        let shots: [(String, NSSize?, () -> Void)] = [
            ("01_flow_mit_umschalter", nil, { st.mode = .flow; hub.section = .diktat }),
            ("02_verlauf", nil, { st.mode = .clipvault; st.section = .verlauf; st.openCollection = nil; st.selectedID = first { $0.collection == nil && $0.kind == .text && !$0.pinned } }),
            ("03_verlauf_bild", nil, { st.selectedID = first { $0.collection == nil && $0.kind == .image } }),
            ("03b_bild_gross", nil, {
                let list = cv.items.filter { !cv.isSecret($0) }.compactMap(CVViewerEntry.from)
                if let id = st.selectedID { CVImageViewer.shared.open(list, id: id) }
            }),
            ("03c_bild_gross_klein", NSSize(width: 1000, height: 680), {
                let list = cv.items.filter { !cv.isSecret($0) }.compactMap(CVViewerEntry.from)
                if let id = list.dropFirst(1).first?.id { CVImageViewer.shared.open(list, id: id) }
            }),
            ("04_angeheftet", nil, { st.section = .angeheftet; st.selectedID = first(\.pinned) }),
            ("05_bereiche", nil, { st.section = .bereiche; st.openCollection = nil }),
            ("06_bereich_offen", nil, {
                st.section = .bereiche
                st.openCollection = cv.collections.first { !$0.isSecret && cv.count(in: $0.id) > 0 }?.id ?? cv.collections.first?.id
                st.selectedID = first { $0.collection == st.openCollection }
            }),
            ("07_bereich_passwoerter", nil, {
                st.section = .bereiche
                st.openCollection = cv.collections.first { $0.isSecret }?.id
                st.selectedID = first { $0.collection == st.openCollection }
            }),
            ("08_bilder", nil, { st.section = .bilder; st.openCollection = nil; st.selectedID = first { $0.kind == .image } }),
            ("09_links", nil, { st.section = .links; st.selectedID = first { $0.kind == .link } }),
            ("10_dateien", nil, { st.section = .dateien; st.selectedID = first { $0.kind == .file } }),
            ("11_geteilt_leer", nil, { st.section = .geteilt; CVShared.install(CVFileSharedSource()) }),
            ("12_geteilt_code", nil, { CVShared.shared.beginPairing() }),
            ("13_geteilt_verbunden", nil, { CVShared.install(CVDemoSharedSource(connected: true)) }),
            ("13b_geteilt_echt", nil, { CVShared.install(CVFileSharedSource()) }),
            ("13c_geteilt_bild_gross", nil, {
                let all = CVShared.shared.items.compactMap(CVViewerEntry.from)
                if let f = all.first { CVImageViewer.shared.open(all, id: f.id) }
            }),
            ("14_einstellungen", nil, { st.section = .einstellungen }),
            ("15_klein_verlauf", NSSize(width: 1000, height: 680), { st.section = .verlauf; st.selectedID = first { $0.collection == nil } }),
            ("16_ohne_seitenleiste", NSSize(width: 1100, height: 720), { hub.sidebarVisible = false }),
        ]
        CVShared.shared.start()
        // CV_RENDER_ONLY=03,03b,13b … → nur diese Bilder (z. B. ohne „12_geteilt_code“, das echt einen Kopplungscode anfordert)
        let only = ProcessInfo.processInfo.environment["CV_RENDER_ONLY"].map { $0.split(separator: ",").map(String.init) }
        for (name, sz, setup) in shots {
            if let only, !only.contains(where: { name.hasPrefix($0 + "_") }) { continue }
            if !name.contains("gross") { CVImageViewer.shared.close() }
            setup()
            if name.hasPrefix("16") == false { hub.sidebarVisible = true }
            let v = NSHostingView(rootView: VFHubView())
            v.frame = NSRect(origin: .zero, size: sz ?? size)
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: v.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = v
            for _ in 0..<24 { v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
            win.close()
        }
        // Modus nicht dauerhaft verstellen
        UserDefaults.standard.removeObject(forKey: "vf.hub.mode")
        UserDefaults.standard.removeObject(forKey: "vf.cv.section")
        return 0
    }

    /// Erfundene Einträge (nur im Speicher)
    static func demoData() -> ([CVItem], [CVCollection]) {
        let cols = [CVCollection(id: "c-ki", name: "KI", symbol: "sparkles"),
                    CVCollection(id: "c-arbeit", name: "Arbeit", symbol: "briefcase.fill"),
                    CVCollection(id: "c-pw", name: "Passwörter", symbol: "lock.fill"),
                    CVCollection(id: "c-camp", name: "Camp", symbol: "star.fill")]
        let now = Date()
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        func t(_ id: String, _ text: String, _ ago: Double, src: String? = nil, pin: Bool = false, col: String? = nil) -> CVItem {
            var i = CVItem(id: id, rawKind: "text", text: text, image: nil, date: now.addingTimeInterval(-ago), source: src, files: [],
                           pinned: pin, collection: col)
            if let det { i.url = ClipVaultClient.singleURL(text, det) }
            return i
        }
        let items: [CVItem] = [
            t("d1", "Kannst du mir bis Freitag die Busangebote schicken? Dann entscheiden wir am Wochenende.", 40),
            t("d2", "https://www.apple.com/de/macbook-pro/", 300),
            t("d3", "Fasse das folgende Meeting in fünf Stichpunkten zusammen und nenne Aufgaben mit Namen.", 900, src: "KI", col: "c-ki"),
            t("d4", "Treffpunkt Samstag 9:30 am Gemeindehaus", 1800, src: "Diktat", pin: true),
            t("d5", "func greet(name: String) -> String {\n    let msg = \"Hallo, \\(name)!\"\n    return msg\n}", 3600, src: "KI"),
            t("d6", "Rechnung SMS-2026-014 – bitte bis 30.09. überweisen.", 7200, col: "c-arbeit"),
            t("d7", "sehr-geheimes-passwort-123", 8000, col: "c-pw"),
            t("d8", "https://github.com/example/project", 90000),
            t("d9", "Packliste Camp: Schlafsack, Taschenlampe, Bibel, Wasserflasche, Regenjacke", 100000, col: "c-camp"),
            t("d10", "Danke euch allen für den tollen Abend!", 110000, src: "iPhone"),
        ]
        return (items, cols)
    }
}
