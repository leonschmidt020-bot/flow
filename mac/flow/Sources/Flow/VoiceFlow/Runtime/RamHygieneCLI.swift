import AppKit
import ImageIO
import SwiftUI

/// Prüfungen zur RAM-Hygiene (18.10.2026, RamHygiene.swift):
///   Flow --selftest-ram          – Release-Gate, ohne Hardware/Fenster auf dem Bildschirm (braucht FLOW_HOME)
///   Flow --mem-ram-probe [n] [neu-zuerst]
///                                  – Entwickler: Footprint vorher/nachher mit n großen Testbildern, Hub nur offscreen
///                                    (randloses Fenster, nie gezeigt; kein Whisper, kein Ton; braucht FLOW_HOME + CLIPVAULT_HOME)
enum RamHygieneCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1 else { return nil }
        switch args[1] {
        case "--selftest-ram": return selftest()
        case "--mem-ram-probe": return probe(n: Int(args.count > 2 ? args[2] : "") ?? 12, newFirst: args.contains("neu-zuerst"))
        default: return nil
        }
    }

    // MARK: Hilfen

    /// Ohne NSApp.run leert niemand die Autorelease-Pools – sonst bliebe in der CLI alles hängen, was die App längst los wäre
    private static func pump(_ s: Double) { autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(s)) } }

    @discardableResult
    private static func until(_ timeout: Double, _ done: () -> Bool) -> Bool {
        let t0 = Date()
        while !done() {
            if Date().timeIntervalSince(t0) > timeout { return false }
            pump(0.01)
        }
        return true
    }

    private static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    /// Einfarbiges Testbild mit Rechteck (Inhalt egal – dekodiert zählt nur Breite × Höhe)
    static func syntheticImage(_ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return ctx.makeImage()
    }

    @discardableResult
    static func writePNG(_ cg: CGImage, _ url: URL) -> Bool {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, cg, nil)
        return CGImageDestinationFinalize(d)
    }

    // MARK: --selftest-ram

    private static func selftest() -> Int32 {
        guard ProcessInfo.processInfo.environment["FLOW_HOME"] != nil else {
            print("FEHLER --selftest-ram braucht FLOW_HOME (Test-Ordner)"); return 1
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = Paths.base.appendingPathComponent("RAM-Test", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cvDir = dir.appendingPathComponent("clipvault", isDirectory: true)
        try? fm.createDirectory(at: cvDir, withIntermediateDirectories: true)
        ClipVaultClient.base = cvDir           // nie das echte ~/.config/flow-clipvault
        var ok = 0, bad = 0
        func check(_ c: Bool, _ name: String) { if c { ok += 1; print("  ok     \(name)") } else { bad += 1; print("  FEHLER \(name)") } }

        // 1) Zwischenspeicher mit Kostengrenze
        guard let bigCG = syntheticImage(2000, 1500) else { print("  FEHLER Testbild"); return 1 }
        let cost = VFImageCache.cost(bigCG)
        let bigImg = NSImage(cgImage: bigCG, size: NSSize(width: bigCG.width, height: bigCG.height))
        let c = VFImageCache(countLimit: 10, costLimit: 30 << 20)
        for i in 0..<8 { c.set(bigImg, key: "b\(i)", cost: cost) }
        check(c.totalCost <= c.costLimit && c.count == 2, "Kostengrenze: 8 × \(mb(cost)) eingelegt → \(c.count) behalten, \(mb(c.totalCost)) ≤ 30 MB")
        _ = c.object("b6")
        c.set(bigImg, key: "b8", cost: cost)
        check(c.object("b6") != nil && c.object("b7") == nil, "zuletzt angesehenes Bild bleibt, das älteste fliegt")
        c.set(bigImg, key: "riesig", cost: 31 << 20)
        check(c.object("riesig") == nil && c.count == 2, "ein Bild über der Grenze wird gar nicht gehalten")
        let few = VFImageCache(countLimit: 3, costLimit: 1 << 30)
        for i in 0..<5 { few.set(bigImg, key: "\(i)", cost: 1) }
        check(few.count == 3, "Anzahlgrenze hält (\(few.count)/3)")

        // 2) CVThumbs: geteilter Speicher bleibt unter 48 MB, ≥ 1200 px kommt nie hinein
        let th = CVThumbs.shared
        th.purge()
        for i in 0..<12 { th.small.set(bigImg, key: "synth\(i)", cost: cost) }
        check(th.small.totalCost <= th.small.costLimit && th.small.costLimit == 48 << 20,
              "CVThumbs: 12 × \(mb(cost)) eingelegt → \(mb(th.small.totalCost)) ≤ 48 MB")
        th.purge()
        let png = dir.appendingPathComponent("gross.png")
        guard let srcCG = syntheticImage(2400, 1600), writePNG(srcCG, png) else { print("  FEHLER Testbild schreiben"); return 1 }
        func load(_ px: Int) -> NSImage? {
            var r: NSImage?, done = false
            th.load(png, maxPixel: px) { r = $0; done = true }
            until(10) { done }
            return r
        }
        let l320 = load(320)
        check(l320 != nil && th.small.count == 1 && th.cached(png, 320) != nil, "320 px (Liste) liegt im geteilten Zwischenspeicher")
        let l3200 = load(3200)
        check(l3200 != nil && th.small.count == 1 && th.big.count == 1, "3200 px (Leuchtkasten) NICHT im geteilten Zwischenspeicher, nur im Großbild-Platz")
        _ = load(1200); _ = load(2400)
        check(th.big.count == 2 && th.small.count == 1, "große Bilder höchstens 2 Plätze (\(th.big.count)), geteilter bleibt bei \(th.small.count)")
        check(th.cached(png, 2400) != nil && th.cached(png, 3200) == nil, "das älteste große Bild fliegt zuerst")
        th.purge()
        check(th.small.count == 0 && th.big.count == 0 && th.small.totalCost == 0, "purge() leert beide (Hub freigegeben)")

        // 3) Meeting-Bilder genauso
        let mc = MCThumbCache.shared
        mc.purge()
        var mcDone = false
        mc.load(png, 2400) { _ in mcDone = true }; until(10) { mcDone }
        mcDone = false
        mc.load(png, 640) { _ in mcDone = true }; until(10) { mcDone }
        check(mc.small.count == 1 && mc.big.count == 1, "Meeting-Leuchtkasten 2400 px nur im Großbild-Platz, 640 px im geteilten")
        mc.purge()

        // 4) Illustrationen: Existenz prüfen lädt nichts
        let illus = ["illu_geteilt"] + (2...7).map { "illu_geteilt_\($0)" }
        check(VFAsset.exists("illu_geteilt") && !VFAsset.exists("gibt_es_nicht_ram_test"), "VFAsset.exists findet Dateien (ohne Laden)")
        _ = SharedInboxBadge.randomIllustration()
        check(!illus.contains(where: VFAsset.isCached), "Zufallsbild wählen lädt keine Illustration in den Dauer-Zwischenspeicher")

        // 5) Pille: eingefärbte Symbole nur einmal bauen
        let g1 = PillSymbols.tinted("globe", size: 12, weight: .medium, white: 0.92)
        let g2 = PillSymbols.tinted("globe", size: 12, weight: .medium, white: 0.92)
        let g3 = PillSymbols.tinted("globe", size: 12, weight: .medium, white: 0.5)
        check(g1 != nil && g1 === g2, "Pille: gleiches Symbol → dieselbe Bild-Instanz")
        check(g3 != nil && g3 !== g1, "Pille: andere Deckkraft → eigenes Bild")

        // 6) Fenster-Freigabe: planen → show() in der Frist bricht ab → sonst genau einmal nach der Frist
        let rel = VFWindowReleaser(delay: 0.15)
        var fired = 0
        rel.schedule { fired += 1 }
        check(rel.isPending, "Schließen plant die Freigabe")
        rel.cancel()                                   // = show() innerhalb der Frist
        pump(0.35)
        check(fired == 0 && !rel.isPending, "Wiederöffnen in der Frist: keine Freigabe, Fenster bleibt")
        rel.schedule { fired += 1 }
        rel.schedule { fired += 1 }                    // zweimal geschlossen → nur einmal
        check(fired == 0, "vor Ablauf der Frist noch da")
        pump(0.35)
        check(fired == 1 && !rel.isPending, "nach der Frist genau einmal freigegeben (\(fired)×)")
        check(VoiceFlowWindow.shared.releaser.delay == VFWindowReleaser.defaultDelay && VFWindowReleaser.defaultDelay == 60, "Hub: Frist 60 s")

        // 7) Freigegebenes Fenster ist wirklich weg – samt SwiftUI-Baum, und dessen Timer feuern nicht mehr
        let box = RamTickBox()
        weak var weakWin: NSWindow?
        weak var weakHost: NSView?
        var win: NSWindow?
        autoreleasepool {
            let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: RamTickView(box: box))
            w.contentView = host
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); pump(0.05) }
            weakWin = w; weakHost = host; win = w
        }
        pump(0.4)
        let ticking = box.n > 0
        check(canDropFresh(win), "nie gezeigtes Fenster darf freigegeben werden")
        let rel2 = VFWindowReleaser(delay: 0.1)
        rel2.schedule {
            guard let w = win, VFWindowReleaser.canDrop(w) else { return }
            VFWindowReleaser.dismantle(w)
            win = nil
        }
        pump(0.3)
        until(2) { weakWin == nil && weakHost == nil }
        check(win == nil && weakWin == nil && weakHost == nil, "Fenster und SwiftUI-Inhalt nach der Freigabe aus dem Speicher")
        let n0 = box.n
        pump(0.4)
        if ticking { check(box.n == n0, "Timer.publish im Inhalt feuert danach nicht mehr (vorher \(n0)×)") }
        else { print("  info   Timer im offscreen-Fenster lief nicht an – Timer-Prüfung übersprungen") }

        // 8) Neu gebautes Fenster bekommt Rahmen + Autosave-Namen, auch wenn das alte noch lebt (größenveränderbar wie der Hub –
        //    bei festen Fenstern stellt setFrameUsingName nur die Lage wieder her)
        let frameName = "RamHygieneTestFenster"
        let w1 = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w1.isReleasedWhenClosed = false
        _ = w1.setFrameAutosaveName(frameName)
        w1.setFrame(NSRect(x: 230, y: 240, width: 410, height: 310), display: false)
        VFWindowReleaser.dismantle(w1, autosaveName: frameName)     // w1 bleibt absichtlich am Leben
        let w2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w2.isReleasedWhenClosed = false
        let restored = w2.setFrameUsingName(frameName)
        let took = w2.setFrameAutosaveName(frameName)
        check(restored && took && w2.frame.size == NSSize(width: 410, height: 310),
              "neu gebautes Fenster: Rahmen wiederhergestellt, Autosave-Name frei (gelesen \(restored), Name \(took), \(Int(w2.frame.width))×\(Int(w2.frame.height)))")
        _ = w2.setFrameAutosaveName("")
        NSWindow.removeFrame(usingName: frameName)
        _ = w1

        let now = Date().timeIntervalSince1970
        // 9) ClipVault: Takt + Einträge nur, solange eine Seite zu sehen ist
        func writeIndex(_ n: Int) {
            let arr: [[String: Any]] = (0..<n).map { ["id": "t\($0)", "kind": "text", "text": "Eintrag \($0)", "ts": now - Double($0)] }
            try? JSONSerialization.data(withJSONObject: arr).write(to: cvDir.appendingPathComponent("index.json"))
        }
        writeIndex(3)
        let cv = ClipVaultClient.shared
        cv.start()
        check(cv.isRunning && cv.items.count == 3, "ClipVault-Seite gezeigt: Verlauf geladen (\(cv.items.count))")
        cv.stop()
        check(!cv.isRunning && cv.items.isEmpty && cv.collections.isEmpty, "Hub freigegeben: Einträge losgelassen, Takt aus")
        writeIndex(5)
        pump(2.6)
        check(cv.items.isEmpty, "danach liest kein 2-s-Takt mehr nach")
        cv.start()
        check(cv.isRunning && cv.items.count == 5, "wieder gezeigt: start() lädt sofort neu (\(cv.items.count))")
        cv.stop()

        print("RAM: \(ok)/\(ok + bad) ok")
        return bad == 0 ? 0 : 1
    }

    private static func canDropFresh(_ w: NSWindow?) -> Bool { w.map(VFWindowReleaser.canDrop) ?? false }

    // MARK: --mem-ram-probe

    /// Resident (auch reinholbarer Bild-Zwischenspeicher von ImageIO, den der Footprint nicht zählt)
    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    /// Footprint wie bei der echten Messung (/usr/bin/footprint, malloc vorher aufgeräumt wie MemorySaver jede Minute).
    private static func probe(n: Int, newFirst: Bool) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOW_HOME"] != nil, !(env["CLIPVAULT_HOME"] ?? "").isEmpty else {
            print("FEHLER --mem-ram-probe braucht FLOW_HOME und CLIPVAULT_HOME (Test-Ordner)"); return 1
        }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        let fm = FileManager.default
        let base = ClipVaultClient.base
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        var arr: [[String: Any]] = []
        var urls: [URL] = []
        for i in 0..<n {
            let name = "ram-probe-\(i).png", u = base.appendingPathComponent(name)
            if !fm.fileExists(atPath: u.path), let cg = syntheticImage(3000, 2000) { writePNG(cg, u) }
            urls.append(u)
            arr.append(["id": "img\(i)", "kind": "image", "image": name, "ts": now - Double(i)])
        }
        for i in 0..<300 {
            arr.append(["id": "txt\(i)", "kind": "text", "text": "Testeintrag \(i) " + String(repeating: "Lorem ipsum dolor sit amet ", count: 12), "ts": now - 100 - Double(i)])
        }
        try? JSONSerialization.data(withJSONObject: arr).write(to: base.appendingPathComponent("index.json"))

        @discardableResult
        func step(_ name: String) -> Double {
            pump(1.5)
            _ = MemorySaver.trimMalloc()
            let fp = autoreleasepool { MemProbe.snap().footprintMB }
            print(name.padding(toLength: 62, withPad: " ", startingAt: 0) + String(format: "Footprint %5.0f MB · resident %5.0f MB", fp, residentMB()))
            fflush(stdout)
            return fp
        }
        func render(_ v: NSView) {
            autoreleasepool {
                for _ in 0..<6 { v.layoutSubtreeIfNeeded(); pump(0.06) }
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep) }
            }
        }
        let sizes = [320, 1200, 3200]   // Liste · Vorschau-Spalte · Leuchtkasten

        let s0 = step("0 Start (nichts geladen)")
        // vorher: NSCache wie bis 1.7.55 (countLimit 400, ohne Kostengrenze, alle Größen gemeinsam)
        var s1 = 0.0, s2 = 0.0
        let th = CVThumbs.shared
        func oldCache() {
            var old: NSCache<NSString, NSImage>? = NSCache()
            old!.countLimit = 400
            autoreleasepool {
                for u in urls { for px in sizes { if let img = CVThumbs.make(u, maxPixel: px) { old!.setObject(img, forKey: "\(px)|\(u.path)" as NSString) } } }
            }
            s1 = step("1 vorher: \(n) Bilder angesehen, NSCache ohne Kostengrenze")
            autoreleasepool { old = nil }
            step("1b vorher: dieser Zwischenspeicher wieder weg")
        }
        // nachher: CVThumbs (48 MB + 2 Großbild-Plätze)
        func newCache() {
            autoreleasepool { for u in urls { for px in sizes { var done = false; th.load(u, maxPixel: px) { _ in done = true }; until(20) { done } } } }
            s2 = step("2 nachher: \(n) Bilder angesehen (\(mb(th.small.totalCost)) + \(th.big.count) groß, \(mb(th.big.totalCost)))")
        }
        if newFirst { newCache(); oldCache() } else { oldCache(); newCache() }

        // Hub offscreen (randlos, nie gezeigt): Seiten wie --render-hub, dazu ClipVault-Verlauf + Leuchtkasten
        var hubWin: NSWindow?, cvWin: NSWindow?
        autoreleasepool {
            let hw = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 1512, height: 949), styleMask: [.borderless], backing: .buffered, defer: false)
            hw.isReleasedWhenClosed = false
            hw.contentView = NSHostingView(rootView: VFHubView())
            let hub = VFHub.shared
            for sec in [VFSection.diktat, .notetaker, .insights, .hilfe, .woerterbuch] { hub.section = sec; render(hw.contentView!) }
            hub.section = .diktat
            render(hw.contentView!)
            let cw = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 1400, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            cw.isReleasedWhenClosed = false
            cw.contentView = NSHostingView(rootView: HStack(spacing: 0) { CVSidebar().frame(width: HubMetrics.sidebarWidth); CVRootPage() }
                .frame(width: 1400, height: 900).environment(\.colorScheme, .light))
            render(cw.contentView!)
            let entries = ClipVaultClient.shared.items.compactMap { CVViewerEntry.from($0) }
            for e in entries.prefix(3) {
                CVImageViewer.shared.open(entries, id: e.id)
                render(cw.contentView!)
                pump(0.4)
                render(cw.contentView!)
            }
            hubWin = hw; cvWin = cw
        }
        let s3 = step("3 Hub offen (offscreen): Seiten, ClipVault (\(ClipVaultClient.shared.items.count) Einträge), 3 Bilder groß")
        autoreleasepool { CVImageViewer.shared.close(); render(cvWin!.contentView!) }
        pump(3)
        let s4 = step("4 Hub geschlossen, Fenster behalten (bis 1.7.55)")
        autoreleasepool {
            VFWindowReleaser.dismantle(hubWin!); hubWin = nil
            VFWindowReleaser.dismantle(cvWin!); cvWin = nil
        }
        ClipVaultClient.shared.stop()
        th.purge()
        MCThumbCache.shared.purge()
        pump(1)
        let s5 = step("5 Hub freigegeben (neu, 60 s nach dem Schließen)")
        print(String(format: "\nBilder-Zwischenspeicher: vorher %+.0f MB, nachher %+.0f MB (gegen Start)", s1 - s0, s2 - s0))
        print(String(format: "Hub zu: behalten %+.0f MB, freigegeben %+.0f MB (gegen Start) → %.0f MB gespart", s4 - s0, s5 - s0, s4 - s5))
        _ = s3
        return 0
    }
}

/// Zähler für den Timer-Test (Klasse, damit die View ihn nicht kopiert)
private final class RamTickBox { var n = 0 }

/// Winzige View mit Timer wie in den Hub-Seiten (Timer.publish + onReceive)
private struct RamTickView: View {
    let box: RamTickBox
    var body: some View {
        Text("RAM-Test").padding()
            .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in box.n += 1 }
    }
}
