import AppKit

// MARK: - Fenster, die auf EINEM Schreibtisch hängen bleiben (09.10.2026)
//
// Bericht: „Wenn mir der Partner etwas schickt und ich die Seite (Schreibtisch) wechsle, ist der grüne Rahmen an der Pille weg –
// nur auf einem bestimmten Schreibtisch ist er da.“ Gemessen (CGSCopySpacesForWindows): die Pille lag auf allen 5
// Schreibtischen, der Rahmen und das Karten-Fenster nur noch auf einem – trotz `.canJoinAllSpaces`. Irgendwann im Betrieb
// (vermutlich Sperren/Aufwachen) verliert macOS diese Zugehörigkeit. Weder orderOut/orderFront noch ein neu gesetztes
// collectionBehavior holen sie zurück – ein NEU angelegtes Fenster liegt sofort wieder auf allen.
// `isOnActiveSpace` erkennt das (auch bei ausgeblendeten Fenstern): ein Allen-Schreibtischen-Fenster ist immer „hier“.
// Darum: vor jeder Wiederverwendung prüfen und ein hängendes Fenster wegwerfen.

enum SpaceGuard {
    /// Hängt das Fenster auf einem anderen Schreibtisch fest?
    static func isStuck(_ w: NSWindow) -> Bool {
        w.windowNumber > 0 && w.collectionBehavior.contains(.canJoinAllSpaces) && !w.isOnActiveSpace
    }

    /// Fragt den FENSTERSERVER (nicht AppKit): ist das Fenster gerade wirklich auf einem Bildschirm zu sehen?
    /// 10.10.2026: mit 3 Bildschirmen + Vollbild-Apps meldete AppKit „sichtbar, aktiver Space“, man sah die Liste aber nicht.
    static func isOnScreen(_ w: NSWindow) -> Bool {
        guard w.windowNumber > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]],
              let d = info.first else { return false }
        return (d[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// Sichtbar sein sollendes Fenster, das der Fensterserver nicht zeigt → durch ein frisches ersetzen (Inhalt, Lage,
    /// Ebene und Mausverhalten wandern mit). Liefert das Fenster, das ab jetzt gilt.
    static func ensureShown<W: NSWindow>(_ w: W, _ name: String, make: () -> W) -> W {
        guard w.isVisible, w.alphaValue > 0.01, !isOnScreen(w) else { return w }
        let n = make()
        let v = w.contentView
        w.contentView = NSView()
        n.contentView = v
        n.level = w.level
        n.ignoresMouseEvents = w.ignoresMouseEvents
        n.alphaValue = w.alphaValue
        n.setFrame(w.frame, display: false)
        w.orderOut(nil)
        n.orderFrontRegardless()
        log("Fenster „\(name)“ war nicht zu sehen (Fensterserver) – neu angelegt, jetzt " + (isOnScreen(n) ? "sichtbar" : "weiterhin unsichtbar"))
        return n
    }

    /// Das Fenster, wenn es noch auf allen Schreibtischen liegt – sonst nil (Aufrufer legt ein neues an)
    static func fresh<W: NSWindow>(_ w: W?, _ name: String) -> W? {
        guard let w else { return nil }
        guard isStuck(w) else { return w }
        log("Fenster „\(name)“ hing auf einem anderen Schreibtisch – neu angelegt")
        w.orderOut(nil)
        return nil
    }
}

// MARK: - Selbsttest:  Flow --space-guard-test
// Legt ein unsichtbares Testfenster (Alpha 0,01, weit außerhalb jedes Bildschirms) an, nimmt es per CoreGraphics-
// Hintertür vom AKTIVEN Schreibtisch und prüft: erkannt → weggeworfen → das neue liegt wieder hier. Fasst keine
// anderen Fenster an.
enum SpaceGuardDev {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2, args[1] == "--space-guard-test" else { return nil }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var fails = 0, n = 0
        func check(_ name: String, _ ok: Bool) { n += 1; print((ok ? "ok    " : "FEHLER ") + name); if !ok { fails += 1 } }
        func wait(_ t: Double) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
        typealias ConnFn = @convention(c) () -> Int32
        typealias CurFn = @convention(c) (Int32) -> UInt64
        typealias RemFn = @convention(c) (Int32, CFArray, CFArray) -> Void
        typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        guard let c1 = dlsym(h, "CGSMainConnectionID"), let c2 = dlsym(h, "CGSGetActiveSpace"), let c3 = dlsym(h, "CGSRemoveWindowsFromSpaces"),
              let c4 = dlsym(h, "CGSCopySpacesForWindows") else {
            print("ALLE 0 PRUEFUNGEN OK (CoreGraphics-Hintertür fehlt – übersprungen)"); return 0
        }
        let conn = unsafeBitCast(c1, to: ConnFn.self)(); _ = c2
        // von ALLEN Schreibtischen nehmen, auf denen es liegt (mehrere Bildschirme: „aktiv“ ist evtl. ein anderer)
        typealias DSFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
        let dsp = dlsym(h, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: DSFn.self) }
        // nur von den gerade AKTUELLEN Schreibtischen aller Bildschirme nehmen (ganz ohne Schreibtisch lehnt macOS ab)
        func detach(_ w: NSWindow) {
            let mine = (unsafeBitCast(c4, to: SpacesFn.self)(conn, 7, [w.windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber]) ?? []
            let displays = (dsp?(conn)?.takeRetainedValue() as? [[String: Any]]) ?? []
            let current = Set(displays.compactMap { (($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.intValue })
            let drop = mine.filter { current.contains($0.intValue) }
            unsafeBitCast(c3, to: RemFn.self)(conn, [w.windowNumber] as CFArray, drop as CFArray); wait(0.3)
        }
        func make() -> SmartBadgePanel {
            let p = SmartBadgePanel(size: NSSize(width: 4, height: 4), acceptsMouse: false)
            p.alphaValue = 0.02; p.setFrameOrigin(NSPoint(x: (NSScreen.main?.frame.minX ?? 0) + 2, y: (NSScreen.main?.frame.minY ?? 0) + 2)); p.orderFrontRegardless(); wait(0.3); return p   // 4 × 4 pt, fast durchsichtig
        }
        let p = make()
        check("neues Fenster liegt auf dem aktiven Schreibtisch", !SpaceGuard.isStuck(p) && SpaceGuard.fresh(p, "Test") === p)
        p.orderOut(nil); wait(0.2)
        check("ausgeblendet gilt es weiterhin als gesund", !SpaceGuard.isStuck(p))
        p.orderFrontRegardless(); wait(0.2)
        detach(p)
        check("vom aktiven Schreibtisch genommen → als hängend erkannt", SpaceGuard.isStuck(p))
        check("fresh() wirft es weg (nil) und blendet es aus", SpaceGuard.fresh(p, "Test") == nil && !p.isVisible)
        let q = SpaceGuard.fresh(nil as SmartBadgePanel?, "Test") ?? make()
        check("Ersatzfenster liegt wieder hier", !SpaceGuard.isStuck(q) && q.isOnActiveSpace)
        // Sichtbar laut AppKit, aber der Fensterserver zeigt es nicht → ensureShown ersetzt es (Inhalt wandert mit)
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        q.contentView = marker
        check("sichtbares Fenster: Fensterserver zeigt es", SpaceGuard.isOnScreen(q) && SpaceGuard.ensureShown(q, "Test", make: make) === q)
        detach(q)
        check("vom Schreibtisch genommen: AppKit sagt sichtbar, Fensterserver zeigt es nicht", q.isVisible && !SpaceGuard.isOnScreen(q))
        let r = SpaceGuard.ensureShown(q, "Test") { SmartBadgePanel(size: NSSize(width: 4, height: 4), acceptsMouse: false) }
        wait(0.3)
        check("ensureShown: neues Fenster, wieder zu sehen", r !== q && SpaceGuard.isOnScreen(r) && !q.isVisible)
        check("ensureShown: Inhalt, Lage und Deckkraft mitgenommen", r.contentView === marker && r.frame == q.frame && abs(r.alphaValue - 0.02) < 0.005)
        r.orderOut(nil); q.orderOut(nil); p.close(); q.close(); r.close()
        print(fails == 0 ? "ALLE \(n) PRUEFUNGEN OK" : "\(fails) VON \(n) FEHLGESCHLAGEN")
        return fails == 0 ? 0 : 1
    }
}
