import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Kontext-Diktat: Beim Drücken der Diktat-Taste liest Flow – parallel zur Aufnahme, ohne das
/// Mikro zu verzögern – den sichtbaren Text des aktiven Fensters (Bedienungshilfen) und holt daraus Namen,
/// seltene Wörter und Code-Bezeichner. Die helfen Whisper (Hinweis-Satz), dem Namen-Prüfer (Auslöser) und dem
/// Feinschliff (exakte Schreibweise).
///
/// Datenschutz: nichts wird gespeichert oder protokolliert (nur Anzahl + Dauer; Begriffe nur mit „Texte protokollieren“).
/// Der Kontext gilt nur für EIN Diktat: `end()` löscht ihn, spätestens nach 45 s ist er weg.
/// Nie gelesen: Passwort-Apps (`CorrectionLearner.blockedApps`), sichere Eingabe, Passwortfelder.
final class ScreenContext: @unchecked Sendable {
    static let shared = ScreenContext()

    struct Snapshot: Sendable {
        let session: Int
        let bundleID: String
        let appKind: ContextAppKind
        let terms: [ContextTerm]
        /// Lesen + Auswerten (ms), Zeichen gelesen
        let readMs: Int
        let extractMs: Int
        let chars: Int
        var isEmpty: Bool { terms.isEmpty }
    }

    /// Ein/aus (Standard an). Nur für Messungen/Tests abschaltbar – keine eigene Einstellung nötig.
    nonisolated(unsafe) static var enabled = true
    /// Höchstzeit fürs Lesen des Fensters (die AX-Zeitgrenze pro Aufruf ist 0,25 s)
    nonisolated(unsafe) static var readBudget: TimeInterval = 0.18
    nonisolated(unsafe) static var maxNodes = 2500

    private let lock = NSLock()
    private var session = 0
    private var current: Snapshot?
    private var expiry: DispatchWorkItem?
    private let queue = DispatchQueue(label: "flow.screencontext", qos: .userInitiated)
    /// Apps, bei denen WIR AXManualAccessibility eingeschaltet haben (werden nach 60 s Ruhe zurückgestellt)
    private var enabledPids: Set<pid_t> = []
    private var restore: DispatchWorkItem?

    /// Bei Fn-Druck (Main-Thread). Kostet auf dem Main-Thread < 1 ms, der Rest läuft im Hintergrund.
    /// App im Vordergrund beim letzten Fn-Druck (nur die Bundle-ID, kein Inhalt) – Listen-Form, auch ohne gelesenen Kontext
    nonisolated(unsafe) static var lastFrontBundle = ""

    func begin() {
        ScreenContext.lastFrontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard ScreenContext.enabled else { return }
        let id: Int = { lock.lock(); defer { lock.unlock() }; session += 1; current = nil; return session }()
        scheduleExpiry()
        Polisher.prewarm()
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundle = app.bundleIdentifier ?? ""
        if CorrectionLearner.blockedApps.contains(bundle) || IsSecureEventInputEnabled() { return }
        if bundle == Bundle.main.bundleIdentifier { return }
        guard AXIsProcessTrusted() else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in self?.capture(pid: pid, bundle: bundle, session: id) }
    }

    /// Nummer des laufenden Diktats (für `end(_:)` aus dem Erkennungs-Task)
    var sessionID: Int { lock.lock(); defer { lock.unlock() }; return session }

    /// Diktat fertig/abgebrochen → Kontext vergessen. Mit Nummer: nur, wenn inzwischen kein neues Diktat begonnen hat.
    func end(_ id: Int? = nil) {
        lock.lock()
        if let id, id != session { lock.unlock(); return }
        current = nil; session += 1
        lock.unlock()
        ContextBoost.forget()
        // Der 45-s-Zeitgeber ruft end(seineNummer) – nach einem neuen Diktat ist das wirkungslos
    }

    /// Kontext des laufenden Diktats (nil = noch nicht fertig gelesen / keiner / abgelaufen)
    var snapshot: Snapshot? { lock.lock(); defer { lock.unlock() }; return current }

    /// Tests/Messbank: Kontext direkt setzen (ohne Bildschirm)
    func inject(_ ctx: ContextText, bundleID: String = "") {
        let t0 = Date()
        let terms = ContextVocab.extract(ctx)
        lock.lock(); session += 1
        current = Snapshot(session: session, bundleID: bundleID, appKind: ctx.appKind, terms: terms, readMs: 0,
                           extractMs: Int(Date().timeIntervalSince(t0) * 1000), chars: ctx.charCount)
        lock.unlock()
    }

    func injectTerms(_ terms: [ContextTerm], appKind: ContextAppKind = .other) {
        lock.lock(); session += 1
        current = Snapshot(session: session, bundleID: "", appKind: appKind, terms: terms, readMs: 0, extractMs: 0, chars: 0)
        lock.unlock()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        let id = sessionID
        let w = DispatchWorkItem { [weak self] in self?.end(id) }
        expiry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: w)
    }

    private func capture(pid: pid_t, bundle: String, session id: Int) {
        let t0 = Date()
        let kind = ContextAppKind.of(bundleID: bundle)
        guard let raw = ScreenContext.read(pid: pid, kind: kind, enable: { [weak self] in self?.enableAX(pid) }) else {
            log("Kontext: nicht lesbar (Passwortfeld oder kein Fenster)")
            return
        }
        let readMs = Int(Date().timeIntervalSince(t0) * 1000)
        let t1 = Date()
        let terms = raw.isEmpty ? [] : ContextVocab.extract(raw)
        let exMs = Int(Date().timeIntervalSince(t1) * 1000)
        let snap = Snapshot(session: id, bundleID: bundle, appKind: kind, terms: terms, readMs: readMs, extractMs: exMs, chars: raw.charCount)
        lock.lock()
        let stillCurrent = session == id
        if stillCurrent { current = snap }
        lock.unlock()
        guard stillCurrent else { return }
        let names = Settings.frozen.logTexts ? ": " + terms.prefix(12).map(\.text).joined(separator: ", ") : ""
        log("Kontext: \(terms.count) Begriffe aus \(raw.charCount) Zeichen (\(kind.rawValue)) – lesen \(readMs) ms, auswerten \(exMs) ms" + names)
    }

    // MARK: Bedienungshilfen

    /// Chrome/Electron (Slack, VS Code) zeigen ihren Text erst mit AXManualAccessibility. Bleibt 60 s an
    /// (mehrere Diktate hintereinander bauen den Baum nicht jedes Mal neu), dann zurück.
    /// Auch für „Text dorthin, wo die Maus ist“ (MouseTarget): Ziel-App unter der Maus bekommt ihren Baum schon bei Fn-Druck.
    func enableAX(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var cur: CFTypeRef?
        let had = AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &cur) == .success && (cur as? Bool) == true
        if !had, AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            lock.lock(); enabledPids.insert(pid); lock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restore?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.restoreAX() }
            self.restore = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
        }
    }

    private func restoreAX() {
        lock.lock(); let pids = enabledPids; enabledPids.removeAll(); lock.unlock()
        queue.async {
            for pid in pids { AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        }
    }

    private static let skipRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuItem", "AXScrollBar", "AXValueIndicator", "AXImage",
                                                 "AXToolbar", "AXSecureTextField", "AXDisclosureTriangle"]
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox", "AXHeading", "AXCell", "AXLink"]

    /// Liest fokussiertes Feld (mit Cursor), Fenstertitel und sichtbare Texte. nil = Passwortfeld (gar nichts lesen).
    static func read(pid: pid_t, kind: ContextAppKind, enable: () -> Void = {}) -> ContextText? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        enable()
        var ctx = ContextText(appKind: kind)
        let deadline = Date().addingTimeInterval(readBudget)

        var focused: AXUIElement?
        var f: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success, let el = f,
           CFGetTypeID(el) == AXUIElementGetTypeID() {
            focused = (el as! AXUIElement)
        }
        if let el = focused {
            if CorrectionLearner.isSecure(el) { return nil }
            if let v = CorrectionLearner.value(of: el), !v.isEmpty {
                var cursor: Int?
                var r: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let rv = r,
                   CFGetTypeID(rv) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(rv as! AXValue, .cfRange, &range) { cursor = range.location }
                }
                // Audit 27.09.2026: große Felder (Terminal-Verlauf, lange Dokumente) nicht auf den ANFANG kürzen, sondern auf
                // 60 000 Zeichen um den Cursor – und den Cursor in diesen Ausschnitt umrechnen (vorher: Cursor im vollen Text,
                // Text gekürzt → falsche Stelle bzw. Absturz in ContextVocab).
                let ns = v as NSString
                if ns.length > 60_000 {
                    let c = min(max(0, cursor ?? ns.length), ns.length)
                    let lo = max(0, min(c - 30_000, ns.length - 60_000))
                    let win = ns.rangeOfComposedCharacterSequences(for: NSRange(location: lo, length: 60_000))
                    ctx.focused = ns.substring(with: win)
                    ctx.cursor = cursor.map { min(max(0, $0 - win.location), win.length) }
                } else {
                    ctx.focused = v
                    ctx.cursor = cursor
                }
            }
        }
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let wv = w,
              CFGetTypeID(wv) == AXUIElementGetTypeID() else { return ctx }
        let win = wv as! AXUIElement
        var t: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t) == .success, let s = t as? String { ctx.title = s }

        // Baum ablaufen (Breite zuerst, damit sichtbare Hauptinhalte vor tiefen Nebenbäumen kommen), mit Zeit-/Knotengrenze.
        let attrs = [kAXRoleAttribute, kAXValueAttribute, kAXChildrenAttribute, kAXTitleAttribute] as CFArray
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var head = 0
        var visited = 0
        var focusIndex: Int?
        var found: [(String, Int)] = []
        var chars = 0
        while head < queue.count, visited < maxNodes, chars < 40_000 {
            if visited % 32 == 0, Date() > deadline { break }
            let (el, depth) = queue[head]; head += 1
            visited += 1
            if let fe = focused, CFEqual(fe, el) { focusIndex = visited; continue }   // Feldinhalt haben wir schon
            var vals: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &vals) == .success,
                  let arr = vals as? [Any], arr.count == 4 else { continue }
            let role = arr[0] as? String ?? ""
            if skipRoles.contains(role) { continue }
            if textRoles.contains(role) {
                if let s = arr[1] as? String, !s.isEmpty { found.append((s, visited)); chars += s.count }
                else if role == "AXLink" || role == "AXHeading", let s = arr[3] as? String, !s.isEmpty { found.append((s, visited)); chars += s.count }
            }
            if depth < 60, let kids = arr[2] as? [AXUIElement] {
                for k in kids.prefix(400) { queue.append((k, depth + 1)) }
            }
        }
        let fi = focusIndex ?? 0
        ctx.others = found.map { (text: $0.0, distance: focusIndex == nil ? 200 : abs($0.1 - fi)) }
        return ctx
    }
}
