import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - „Text dorthin, wo die Maus ist“ (Einstellungen › Diktat, Standard AUS)
//
// Ablauf:
//   1. Fn gedrückt (DictationController.start, nur über die Taste): `begin()` merkt sich den Mauspunkt und sucht – im
//      Hintergrund, der Main-Thread wartet nicht – das oberste normale Fenster darunter (CGWindowList vorne → hinten,
//      Ebene 0, nicht die eigene Pille/Karten/Hub, nicht ClipVault), dazu das passende AX-Fenster. Liegt die Maus schon
//      über dem aktiven Fenster, bleibt alles wie bisher (0 ms extra).
//   2. Text fertig (DictationController.deliver): `prepare()` holt Fenster + App nach vorne, wartet, bis sie wirklich
//      vorne ist (höchstens 400 ms, kein festes Warten) und wählt das Eingabefeld:
//        a) Textfeld unter der Maus (oder ein Vorfahre bis 4 Ebenen, xterm: dessen Eingabefeld) → fokussieren
//        b) das zuletzt benutzte Feld des Fensters (z. B. Claude Code im Terminal, Chat-Eingabe) → so lassen
//        c) Terminal (Terminal, iTerm2, Ghostty, Warp, VS Code-Terminal …): EIN Linksklick auf den ursprünglichen Punkt
//           (setzt dort nur den Fokus) – nie auf Knöpfe, Links, Reiter, nie wenn etwas darüber liegt
//        d) sonst: zurück zum vorherigen Fenster, normal einfügen, Hinweis „Kein Textfeld unter der Maus – normal eingefügt“
//   3. Inserter fügt wie immer ein. Optional danach Enter (nur wenn das Einfügen bestätigt ist und die App auf der
//      Enter-Liste steht, siehe MTRules.autoSend).
//
// Nie: Passwortfelder/sichere Eingabe, Passwort-Apps, Klicks auf etwas anderes als eine Terminal-Fläche.
// Protokoll: eine Zeile pro Diktat (App, Fenstertitel gekürzt, Methode, Zusatzzeit) – nie der diktierte Text.

/// Was bei Fn-Druck unter der Maus lag
struct MTTarget {
    let session: Int
    /// Mauspunkt (CG-Koordinaten)
    let point: CGPoint
    let pid: pid_t
    let bundle: String
    let appName: String
    let windowID: CGWindowID
    let window: AXUIElement?
    let title: String
    /// Etwas Sichtbares (Pille, ClipVault, Schatten) liegt an dem Punkt über dem Fenster → kein Klick
    let covered: Bool
    /// Maus liegt über dem schon aktiven Fenster → nichts Besonderes tun
    let alreadyFocused: Bool
    /// Vorher aktiv (für „während des Diktats umgeschaltet?“ und das Zurückschalten bei d)
    let prevPid: pid_t
    let prevWindow: AXUIElement?
    let prevWindowID: CGWindowID?
    let captureMs: Int
    /// Rahmen des Ziel-Fensters (CG-Koordinaten) – für die Markierung während des Diktats
    var bounds: CGRect = .zero
}

enum MTCapture {
    /// Kein Ziel (Grund für Protokoll/Probe)
    case none(String)
    case target(MTTarget)
}

/// Ergebnis der Vorbereitung vor dem Einfügen
struct MTPrepared {
    /// „a“ … „d“, „0“ = Maus über dem aktiven Fenster, „–“ = kein Ziel/übersprungen
    var method: String
    var note: String
    var extraMs: Int
    var target: MTTarget?
    /// Toast an der Pille (nur bei d)
    var toast: String?
    static func skip(_ note: String) -> MTPrepared { MTPrepared(method: "–", note: note, extraMs: 0, target: nil, toast: nil) }
}

final class MouseTarget: @unchecked Sendable {
    static let shared = MouseTarget()

    private let queue = DispatchQueue(label: "flow.mousetarget", qos: .userInteractive)
    private let lock = NSLock()
    private var session = 0
    private var captured: [Int: MTCapture] = [:]
    private var pendingGroup: [Int: DispatchGroup] = [:]

    // MARK: 1. Fn gedrückt

    /// Main-Thread, < 1 ms: Mauspunkt jetzt nehmen, Rest im Hintergrund. Liefert die Diktat-Nummer (0 = aus).
    func begin(enabled: Bool) -> Int {
        guard enabled, AXIsProcessTrusted() else { return 0 }
        let p = CGEvent(source: nil)?.location ?? MTGeometry.cocoaToCG(NSEvent.mouseLocation, primaryHeight: MTGeometry.primaryHeight(NSScreen.screens.map(\.frame)))
        let own = ProcessInfo.processInfo.processIdentifier
        let id: Int = { lock.lock(); defer { lock.unlock() }; session += 1; captured = [:]; return session }()
        let g = DispatchGroup(); g.enter()
        lock.lock(); pendingGroup = [id: g]; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let c = MouseTarget.capture(point: p, ownPID: own, session: id, enableAX: { pid, bundle in
                ScreenContext.shared.enableAX(pid)   // Electron (VS Code, Slack, Claude)
                self.enableWebAX(pid: pid, bundle: bundle)   // Chrome & Co.
            })
            self.lock.lock(); if self.session == id { self.captured[id] = c; self.capturedAt = p }; self.lock.unlock()
            g.leave()
            DispatchQueue.main.async { if self.trackSession == id { self.highlight.show(c) } }
        }
        startTracking(id, from: p)
        return id
    }

    // MARK: Während des Diktats: Ziel folgt der Maus
    //
    // Viele drücken Fn zuerst und geht DANN mit der Maus zum Fenster, in das der Text soll (27.09.2026: alle Versuche
    // landeten im Fenster, in dem er Fn gedrückt hatte). Deshalb gilt das Fenster unter der Maus beim LOSLASSEN. Solange
    // gesprochen wird, zeigt ein dünner blauer Rahmen, wohin der Text kommt – so sieht man es vorher.

    private var trackTimer: Timer?
    private var trackSession = 0
    private var trackBusy = false
    private var capturedAt: CGPoint?
    private let highlight = MTHighlight()

    static func mousePoint() -> CGPoint {
        CGEvent(source: nil)?.location
            ?? MTGeometry.cocoaToCG(NSEvent.mouseLocation, primaryHeight: MTGeometry.primaryHeight(NSScreen.screens.map(\.frame)))
    }

    private static func moved(_ a: CGPoint?, _ b: CGPoint) -> Bool {
        guard let a else { return true }
        return abs(a.x - b.x) > 4 || abs(a.y - b.y) > 4
    }

    /// Main-Thread. Alle 0,12 s: hat sich die Maus bewegt, Ziel im Hintergrund neu suchen (nie zwei Suchen gleichzeitig)
    private func startTracking(_ id: Int, from p: CGPoint) {
        trackTimer?.invalidate()
        trackSession = id
        var last = p
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.trackSession == id, !self.trackBusy else { return }
            let now = MouseTarget.mousePoint()
            guard MouseTarget.moved(last, now) else { return }
            last = now
            self.trackBusy = true
            let own = ProcessInfo.processInfo.processIdentifier
            self.queue.async {
                let c = MouseTarget.capture(point: now, ownPID: own, session: id, enableAX: { pid, bundle in
                    ScreenContext.shared.enableAX(pid)
                    self.enableWebAX(pid: pid, bundle: bundle)
                })
                self.lock.lock(); if self.session == id { self.captured[id] = c; self.capturedAt = now }; self.lock.unlock()
                DispatchQueue.main.async {
                    self.trackBusy = false
                    if self.trackSession == id { self.highlight.show(c) }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    /// Diktat vorbei (auch ohne Einfügen): Mitlaufen + Rahmen aus, das gemerkte Ziel bleibt für `prepare`
    func endTracking() {
        if Thread.isMainThread { stopTracking() } else { DispatchQueue.main.async { self.stopTracking() } }
    }

    /// Main-Thread
    private func stopTracking() {
        trackTimer?.invalidate(); trackTimer = nil
        trackSession = 0
        highlight.hide()
    }

    // MARK: Chromium-Browser: Web-Baum an (nur solange gebraucht)

    private var webAXPids: Set<pid_t> = []
    private var webAXRestore: DispatchWorkItem?

    /// Chrome & Co. zeigen Webseiten-Felder erst mit AXEnhancedUserInterface. Wir schalten es nur für das Ziel-Fenster
    /// an (nicht, wenn es schon an war) und nach 60 s ohne weiteres Diktat wieder aus – es kann Fenster-Animationen bremsen.
    func enableWebAX(pid: pid_t, bundle: String) {
        guard MTRules.chromiumBrowsers.contains(bundle) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let had = (MTAX.attr(app, "AXEnhancedUserInterface") as? Bool) == true
        if !had, AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
            lock.lock(); webAXPids.insert(pid); lock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.webAXRestore?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock(); let pids = self.webAXPids; self.webAXPids.removeAll(); self.lock.unlock()
                self.queue.async {
                    for p in pids { AXUIElementSetAttributeValue(AXUIElementCreateApplication(p), "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
                }
            }
            self.webAXRestore = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
        }
    }

    func discard() {
        if Thread.isMainThread { stopTracking() } else { DispatchQueue.main.async { self.stopTracking() } }
        lock.lock(); session += 1; captured = [:]; pendingGroup = [:]; lock.unlock()
    }

    /// Bundle des Ziel-Fensters (für Stil/Statistik), nur wenn wirklich umgeschaltet wird
    func targetBundle(_ id: Int) -> String? {
        guard id > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if case .target(let t)? = captured[id], !t.alreadyFocused { return t.bundle }
        return nil
    }

    /// Nimmt das Ziel heraus (wartet höchstens 150 ms, falls die Suche noch läuft – in der Praxis ist sie längst fertig)
    private func take(_ id: Int) -> MTCapture? {
        lock.lock(); let g = pendingGroup[id]; lock.unlock()
        _ = g?.wait(timeout: .now() + 0.15)
        lock.lock(); defer { lock.unlock() }
        let c = captured[id]; captured[id] = nil
        return c
    }

    // MARK: Suche (Hintergrund; auch von der Probe benutzt – dort ohne enableAX)

    static func windowList() -> [MTWindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var bundles: [pid_t: String] = [:]
        let skip = MTHighlight.windowNumbers
        return raw.compactMap { d in
            if let n = d[kCGWindowNumber as String] as? Int, skip.contains(n) { return nil }
            return MTWindowInfo(d, bundle: { pid in
                if let b = bundles[pid] { return b }
                let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                bundles[pid] = b
                return b
            })
        }
    }

    /// Fokussiertes Fenster der vorderen App (über Bedienungshilfen – stimmt auch auf Hintergrund-Threads)
    static func frontmost() -> (pid: pid_t, window: AXUIElement?, windowID: CGWindowID?) {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.2)
        var pid: pid_t = 0
        if let app = MTAX.element(sys, kAXFocusedApplicationAttribute) { AXUIElementGetPid(app, &pid) }
        if pid == 0 { pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        guard pid != 0 else { return (0, nil, nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let w = MTAX.element(app, kAXFocusedWindowAttribute)
        return (pid, w, w.flatMap(MTAX.windowID))
    }

    static func capture(point p: CGPoint, ownPID: pid_t, session: Int, list: [MTWindowInfo]? = nil,
                        enableAX: ((pid_t, String) -> Void)? = nil) -> MTCapture {
        let t0 = Date()
        let front = frontmost()
        switch MTRules.pick(list ?? windowList(), at: p, ownPID: ownPID) {
        case .none: return .none("kein Fenster unter der Maus")
        case .blocked(let owner, let layer): return .none("Maus über \(owner) (Ebene \(layer))")
        case .windows(let wins, let covered):
            for w in wins {
                if CorrectionLearner.blockedApps.contains(w.bundle) { return .none("Passwort-App unter der Maus") }
                let app = AXUIElementCreateApplication(w.pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                let axWins = MTAX.elements(app, kAXWindowsAttribute)
                let cands = axWins.map { (id: MTAX.windowID($0), frame: MTAX.frame($0), title: MTAX.string($0, kAXTitleAttribute)) }
                guard let i = MTRules.matchWindow(target: w, candidates: cands) else {
                    // Kein echtes Fenster (Overlay, Leinwand, Hilfsfenster) → darunter weitersuchen
                    continue
                }
                let axw = axWins[i]
                let title = cands[i].title ?? w.title
                // Schon aktiv? Gleiche Fenster-Nummer, sonst gleiches AX-Fenster
                var already = false
                if w.pid == front.pid {
                    if let fid = front.windowID { already = fid == w.id }
                    else if let fw = front.window { already = CFEqual(fw, axw) }
                    else { already = true }   // App verrät ihr Fenster nicht → wie bisher
                }
                if !already { enableAX?(w.pid, w.bundle) }   // Chromium/Electron bauen den Baum bis zum Einfügen auf
                let name = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? w.owner
                return .target(MTTarget(session: session, point: p, pid: w.pid, bundle: w.bundle, appName: name, windowID: w.id,
                                        window: axw, title: title, covered: covered || wins.first?.id != w.id,
                                        alreadyFocused: already, prevPid: front.pid, prevWindow: front.window, prevWindowID: front.windowID,
                                        captureMs: Int(Date().timeIntervalSince(t0) * 1000), bounds: w.bounds))
            }
            return .none("kein Bedienungshilfen-Fenster passt")
        }
    }

    // MARK: 2. Vor dem Einfügen

    /// Main-Thread. Ruft `done` auf dem Main-Thread – bei „Maus über dem aktiven Fenster“ sofort (0 ms).
    func prepare(_ id: Int, done: @escaping (MTPrepared) -> Void) {
        guard id > 0 else { done(.skip("aus")); return }
        stopTracking()
        let p = MouseTarget.mousePoint()
        _ = take(id)
        // Immer am Punkt beim Loslassen neu suchen (~15 ms): Ziel UND „vorher aktives Fenster“ stammen dann aus demselben
        // Moment. Mit der Suche vom Mitlaufen war das aktive Fenster manchmal veraltet → „Fokus gewechselt“, normal eingefügt.
        let own = ProcessInfo.processInfo.processIdentifier
        queue.async {
            let c = MouseTarget.capture(point: p, ownPID: own, session: id, enableAX: { pid, bundle in
                ScreenContext.shared.enableAX(pid)
                self.enableWebAX(pid: pid, bundle: bundle)
            })
            DispatchQueue.main.async { self.finish(c, done: done) }
        }
    }

    /// Main-Thread
    private func finish(_ cap: MTCapture, done: @escaping (MTPrepared) -> Void) {
        guard case .target(let t) = cap else {
            if case .none(let why) = cap { done(.skip(why)) }
            return
        }
        if t.alreadyFocused { done(MTPrepared(method: "0", note: "Maus über dem aktiven Fenster", extraMs: 0, target: t, toast: nil)); return }
        if IsSecureEventInputEnabled() { done(.skip("sichere Eingabe aktiv")); return }
        queue.async {
            let r = MouseTarget.focusAndPick(t)
            DispatchQueue.main.async { done(r) }
        }
    }

    /// Hintergrund: Fenster nach vorne, Eingabefeld wählen (a → b → c → d)
    static func focusAndPick(_ t: MTTarget) -> MTPrepared {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        func result(_ m: String, _ note: String, toast: String? = nil) -> MTPrepared {
            MTPrepared(method: m, note: note, extraMs: ms(), target: t, toast: toast)
        }
        // Hat der Nutzer während des Diktats selbst woanders hingeklickt? Dann gilt seine Wahl.
        let now = frontmost()
        if now.pid != t.prevPid || (now.windowID != nil && t.prevWindowID != nil && now.windowID != t.prevWindowID) {
            return MTPrepared(method: "–", note: "Fokus während des Diktats gewechselt – normal eingefügt", extraMs: 0, target: t, toast: nil)
        }
        let app = AXUIElementCreateApplication(t.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Plan VOR dem Umschalten: was liegt unter der Maus?
        let hit = MTAX.hit(app: app, at: t.point)
        var chain = hit.map { MTAX.chain(from: $0) } ?? []
        // Zwei Fenster derselben App übereinander (zwei VS-Code-Fenster): die App beantwortet den Punkt evtl. mit dem
        // ANDEREN Fenster → dann gilt nichts davon (kein Feld, kein Klick)
        if let w = chain.last(where: { $0.node.role == "AXWindow" }), let id = MTAX.windowID(w.el), id != t.windowID { chain = [] }
        let nodes = chain.map(\.node)
        var editable: AXUIElement?
        switch MTRules.pickEditable(nodes) {
        case .secure: return result("d", "Passwortfeld unter der Maus – normal eingefügt")
        case .at(let i): editable = MTAX.editableAncestor(chain[i].el) ?? chain[i].el
        case .none:
            if let e = chain.first.flatMap({ MTAX.editableAncestor($0.el) }) { editable = e }
            else { editable = MTAX.xtermInput(chain: chain) }
        }
        if let e = editable, CorrectionLearner.isSecure(e) { return result("d", "Passwortfeld – normal eingefügt") }
        let clickOK = MTRules.clickAllowed(bundle: t.bundle, chain: nodes, covered: t.covered)

        // Fenster + App nach vorne und warten, bis es wirklich das fokussierte Fenster ist
        let focused = MTFocus.bringToFront(pid: t.pid, windowID: t.windowID, window: t.window)
        if !focused && !clickOK {
            MTFocus.restore(t)
            return result("d", "Fenster ließ sich nicht nach vorne holen", toast: "Kein Textfeld unter der Maus – normal eingefügt")
        }
        // a) Textfeld unter der Maus
        if focused, let e = editable {
            AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            var got: AXUIElement?
            if MTFocus.poll(0.12, { got = MTAX.focusedEditable(app); return got.map { CFEqual($0, e) } ?? false }) {
                return result("a", "Textfeld unter der Maus")
            }
            if let g = got, MTAX.belongs(g, to: t) { return result("b", "Textfeld im Fenster (nicht das unter der Maus)") }
        }
        // b) das Feld, das im Fenster zuletzt aktiv war
        if focused, let f = MTAX.focusedEditable(app), MTAX.belongs(f, to: t) {
            return result("b", "zuletzt benutztes Feld im Fenster")
        }
        // c) Terminal: ein Klick auf den ursprünglichen Punkt setzt nur den Fokus
        // Vor dem Klick nochmal: liegt an dem Punkt JETZT unser Fenster ganz oben, ohne etwas darüber?
        if clickOK, case .windows(let ws, covered: false) = MTRules.pick(windowList(), at: t.point, ownPID: ProcessInfo.processInfo.processIdentifier),
           ws.first?.id == t.windowID {
            MTFocus.click(at: t.point)
            if MTFocus.poll(0.2, { frontmost().windowID == t.windowID || (frontmost().pid == t.pid && MTAX.focusedEditable(app) != nil) }) {
                return result("c", "Klick ins Terminal")
            }
        }
        // d) nichts gefunden → zurück, normal einfügen
        MTFocus.restore(t)
        return result("d", "kein Textfeld gefunden", toast: "Kein Textfeld unter der Maus – normal eingefügt")
    }

    // MARK: 3. Nach dem Einfügen: Enter?

    /// Main-Thread, direkt nach `Inserter.insert` == .pasted. Drückt Enter nur, wenn das Einfügen bestätigt ist.
    /// `log` bekommt den Zusatz für die Protokollzeile („Enter gesendet“ / „kein Enter: …“).
    func autoSend(inserted: String, prepared: MTPrepared, hotkeyHeld: @escaping () -> Bool, done: @escaping (String) -> Void) {
        let expectPid = prepared.target.map { $0.alreadyFocused ? MouseTarget.frontmost().pid : $0.pid } ?? MouseTarget.frontmost().pid
        queue.async {
            let t0 = Date()
            let front = MouseTarget.frontmost()
            guard front.pid == expectPid, front.pid != 0 else { DispatchQueue.main.async { done("kein Enter: Fenster gewechselt") }; return }
            let app = AXUIElementCreateApplication(front.pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            let bundle = NSRunningApplication(processIdentifier: front.pid)?.bundleIdentifier ?? ""
            guard let focused = MTAX.element(app, kAXFocusedUIElementAttribute) else {
                // Kein AX-Element (manche Terminals): nur für Terminals erlaubt
                let d = MTRules.autoSend(bundle: bundle, chain: [], webHost: nil)
                if d.allowed { usleep(180_000); MTFocus.pressReturn() }
                DispatchQueue.main.async { done(d.allowed ? "Enter gesendet" : "kein Enter: \(MTAX.reason(d))") }
                return
            }
            let chain = MTAX.chain(from: focused, maxDepth: 30)
            let d = MTRules.autoSend(bundle: bundle, chain: chain.map(\.node), webHost: MTAX.webHost(chain))
            guard d.allowed else { DispatchQueue.main.async { done("kein Enter: \(MTAX.reason(d))") }; return }
            // Einfügen bestätigt? Lesbares Feld: Text muss drinstehen (bis 300 ms warten). Terminals nicht lesen (ganzer
            // Verlauf, Rahmenzeichen von Claude Code, umgebrochene Zeilen) – dort reicht die Fokus-Prüfung.
            var ok: Bool? = nil
            if !MTRules.nativeTerminals.contains(bundle), !MTRules.xtermEditors.contains(bundle) {
                _ = MTFocus.poll(0.3) {
                    ok = MTRules.pasteConfirmed(inserted: inserted, fieldValue: CorrectionLearner.value(of: focused), valueBefore: nil)
                    return ok != false
                }
            }
            if ok == false { DispatchQueue.main.async { done("kein Enter: Einfügen nicht bestätigt") }; return }
            // Terminals/xterm verarbeiten ⌘V asynchron (Bracketed Paste) – kurz Luft lassen, sonst kommt Enter zu früh
            let waited = Date().timeIntervalSince(t0)
            if ok == nil, waited < 0.18 { usleep(useconds_t((0.18 - waited) * 1_000_000)) }
            guard MouseTarget.frontmost().pid == expectPid, !hotkeyHeld(), !IsSecureEventInputEnabled() else {
                DispatchQueue.main.async { done("kein Enter: Fokus/Taste geändert") }; return
            }
            MTFocus.pressReturn()
            DispatchQueue.main.async { done("Enter gesendet") }
        }
    }
}

// MARK: - Bedienungshilfen-Helfer

/// RTLD_DEFAULT ((void *)-2) – in Swift nicht als Konstante verfügbar
private let mtRTLDDefault = UnsafeMutableRawPointer(bitPattern: -2)

enum MTAX {
    struct Link { let el: AXUIElement; let node: MTRules.Node }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let arr = attr(el, name) as? [AnyObject] else { return [] }
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Fenster-Nummer eines AX-Fensters (privat, aber seit Jahren stabil; über dlsym – fehlt sie, bleibt der Rahmen-Abgleich)
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindowFn? = {
        guard let p = dlsym(mtRTLDDefault, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(p, to: GetWindowFn.self)
    }()
    static var windowIDAvailable: Bool { getWindow != nil }
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        guard let f = getWindow else { return nil }
        var id: CGWindowID = 0
        return f(el, &id) == .success && id != 0 ? id : nil
    }

    static func node(_ el: AXUIElement) -> MTRules.Node {
        var n = MTRules.Node(role: string(el, kAXRoleAttribute) ?? "", subrole: string(el, kAXSubroleAttribute) ?? "")
        n.classes = (attr(el, "AXDOMClassList") as? [String]) ?? []
        n.editableFlag = (attr(el, "AXEditable") as? Bool) ?? false
        var v: CFTypeRef?
        n.hasInsertionPoint = AXUIElementCopyAttributeValue(el, kAXInsertionPointLineNumberAttribute as CFString, &v) == .success
        n.hasEditableAncestor = element(el, "AXEditableAncestor") != nil
        return n
    }

    /// Element + Vorfahren (bis Fenster/App)
    static func chain(from el: AXUIElement, maxDepth: Int = 14) -> [Link] {
        var out: [Link] = []
        var cur: AXUIElement? = el
        while let c = cur, out.count < maxDepth {
            let n = node(c)
            out.append(Link(el: c, node: n))
            if n.role == "AXWindow" || n.role == "AXApplication" { break }
            cur = element(c, kAXParentAttribute)
        }
        return out
    }

    /// Element am Punkt, von der Ziel-App selbst beantwortet (auch wenn ihr Fenster gerade nicht vorne ist)
    static func hit(app: AXUIElement, at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &el) == .success, let e = el else { return nil }
        AXUIElementSetMessagingTimeout(e, 0.2)
        return e
    }

    /// Chromium: Text in einem contenteditable → das editierbare Wurzel-Element
    static func editableAncestor(_ el: AXUIElement) -> AXUIElement? {
        element(el, "AXHighestEditableAncestor") ?? element(el, "AXEditableAncestor")
    }

    /// xterm.js: das versteckte Eingabefeld („xterm-helper-textarea“) im Terminal-Knoten (Breitensuche, begrenzt).
    /// `chain` = Element unter der Maus + Vorfahren; gesucht wird ab dem obersten Knoten mit „xterm“-Klasse.
    static func xtermInput(chain: [Link]) -> AXUIElement? {
        guard let root = chain.last(where: { MTRules.hasClass([$0.node], "xterm") })?.el else { return nil }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        var anyTextArea: AXUIElement?
        while !queue.isEmpty, seen < 120 {
            let (el, depth) = queue.removeFirst(); seen += 1
            let n = node(el)
            if n.role == "AXTextArea" || n.role == "AXTextField" {   // VS Code meldet das xterm-Feld als AXTextField
                if n.classes.contains(where: { $0.contains("xterm-helper-textarea") }) { return el }
                if anyTextArea == nil { anyTextArea = el }
            }
            if depth < 6 { queue += elements(el, kAXChildrenAttribute).prefix(24).map { ($0, depth + 1) } }
        }
        return anyTextArea
    }

    /// Fokussiertes Element der App, wenn es ein Textfeld ist (nie Passwortfeld)
    static func focusedEditable(_ app: AXUIElement) -> AXUIElement? {
        guard let f = element(app, kAXFocusedUIElementAttribute) else { return nil }
        let n = node(f)
        if MTRules.isSecure(n) { return nil }
        return MTRules.isEditable(n) || n.hasEditableAncestor ? f : nil
    }

    /// Gehört das Element zum Ziel-Fenster?
    static func belongs(_ el: AXUIElement, to t: MTTarget) -> Bool {
        guard let w = element(el, kAXWindowAttribute) ?? element(el, "AXTopLevelUIElement") else { return true }
        if let id = windowID(w) { return id == t.windowID }
        if let tw = t.window { return CFEqual(w, tw) }
        return true
    }

    /// Host der Webseite (für die Web-Chat-Liste) – nur der Host, nie der Pfad
    static func webHost(_ chain: [Link]) -> String? {
        for l in chain where l.node.role == "AXWebArea" {
            if let u = attr(l.el, kAXURLAttribute) {
                if let url = u as? URL { return url.host }
                if let s = u as? String { return URL(string: s)?.host }
            }
        }
        return nil
    }

    static func reason(_ d: MTRules.SendDecision) -> String { if case .no(let r) = d { return r }; return "" }
}

// MARK: - Fenster nach vorne, Klick, Enter

enum MTFocus {
    /// Kurz nachfragen statt fest warten: bis `cond` stimmt oder die Zeit um ist
    @discardableResult
    static func poll(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if cond() { return true }
            usleep(8_000)
        } while Date() < end
        return cond()
    }

    // Privates SkyLight (wie AltTab): genau DIESES Fenster einer App nach vorne – auch das zweite Fenster derselben App
    // (zwei VS-Code-Fenster). Über dlsym: fehlt es in einer macOS-Version, bleibt der Weg über die Bedienungshilfen.
    private typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias FrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private static let sky: (psn: PSNFn, front: FrontFn, post: PostFn)? = {
        let rtldDefault = mtRTLDDefault
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let a = dlsym(rtldDefault, "GetProcessForPID"), let b = dlsym(rtldDefault, "_SLPSSetFrontProcessWithOptions"),
              let c = dlsym(rtldDefault, "SLPSPostEventRecordTo") else { return nil }
        return (unsafeBitCast(a, to: PSNFn.self), unsafeBitCast(b, to: FrontFn.self), unsafeBitCast(c, to: PostFn.self))
    }()

    /// Für die Probe: sind die privaten Helfer in dieser macOS-Version da?
    static var skyLightAvailable: Bool { sky != nil }

    private static func skyFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let s = sky else { return false }
        var psn = ProcessSerialNumber()
        guard s.psn(pid, &psn) == noErr else { return false }
        guard s.front(&psn, windowID, 0x200) == .success else { return false }   // kCPSUserGenerated
        // „Fenster wird Schlüsselfenster“-Ereignis (Aufbau wie AltTab/yabai)
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { raw in for i in 0..<4 { bytes[0x3c + i] = raw[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { s.post(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { s.post(&psn, $0.baseAddress!) }
        return true
    }

    /// true = Fenster ist jetzt wirklich das fokussierte Fenster der vorderen App (höchstens ~400 ms)
    static func bringToFront(pid: pid_t, windowID: CGWindowID, window: AXUIElement?) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        func isFront() -> Bool {
            let f = MouseTarget.frontmost()
            guard f.pid == pid else { return false }
            if let id = f.windowID { return id == windowID }
            if let w = window, let fw = f.window { return CFEqual(w, fw) }
            return true
        }
        let sky = skyFocus(pid: pid, windowID: windowID)
        if let w = window {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        if !sky {
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
        }
        if poll(sky ? 0.25 : 0.4, isFront) { return true }
        // Zweiter Weg, falls der erste nicht gegriffen hat
        if sky {
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let w = window {
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
            return poll(0.15, isFront)
        }
        return false
    }

    /// d: zurück zum Fenster, das vor dem Diktat aktiv war (nur wenn schon umgeschaltet wurde)
    static func restore(_ t: MTTarget) {
        let f = MouseTarget.frontmost()
        guard f.pid != t.prevPid || (f.windowID != nil && f.windowID != t.prevWindowID), t.prevPid != 0 else { return }
        if let id = t.prevWindowID { _ = bringToFront(pid: t.prevPid, windowID: id, window: t.prevWindow) }
        else {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(t.prevPid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            _ = poll(0.3) { MouseTarget.frontmost().pid == t.prevPid }
        }
    }

    /// c: EIN Linksklick an den ursprünglichen Punkt, Mauszeiger danach zurück, wo er jetzt ist
    static func click(at p: CGPoint) {
        let now = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        for e in [down, up] {
            e?.flags = []
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            HotkeyMonitor.markSynthetic(e)
        }
        down?.post(tap: .cghidEventTap)
        usleep(12_000)
        up?.post(tap: .cghidEventTap)
        if let now, hypot(now.x - p.x, now.y - p.y) > 1 {
            usleep(10_000)
            CGWarpMouseCursorPosition(now)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    static func pressReturn() {
        let src = CGEventSource(stateID: .privateState)
        let k = CGKeyCode(kVK_Return)
        let down = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)
        down?.flags = []; up?.flags = []
        HotkeyMonitor.markSynthetic(down); HotkeyMonitor.markSynthetic(up)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
