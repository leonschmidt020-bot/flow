import AppKit
import ApplicationServices
import AVFoundation

// MARK: - Klick-Kontext (15.10.2026): WAS wurde angeklickt? – über die Bedienungshilfen, für Agents als Text
//
// „[0:12] Klick auf „Speichern“ (Taste) · Safari – „Rechnung März““ statt nur ein Bild. Datenschutz: den INHALT von
// Textfeldern liest Flow nie (nur Platzhalter/Beschriftung), Passwortfelder gar nicht, Klicks auf Flow selbst nicht.

struct ScreenRecClickInfo: Equatable {
    let t: Double
    let label: String?      // „Speichern“
    let role: String?       // „Taste“, „Link“, „Textfeld“ (Rollen-Beschreibung von macOS, in Systemsprache)
    let app: String?        // „Safari“
    let window: String?     // „Rechnung März“

    /// „Klick auf „Speichern“ (Taste) · Safari – „Rechnung März““
    var text: String {
        var s = "Klick"
        if let l = label { s += " auf „\(l)“" }
        if let r = role { s += " (\(r))" }
        var where_: [String] = []
        if let a = app { where_.append(a) }
        if let w = window, w != app { where_.append("„\(w)“") }
        if !where_.isEmpty { s += " · " + where_.joined(separator: " – ") }
        return s
    }
}

enum ScreenRecClickProbe {
    static let queue = DispatchQueue(label: "flow.screenrec.clickprobe", qos: .userInitiated)

    /// p in Cocoa-Bildschirmkoordinaten (Ursprung unten links am Hauptbildschirm)
    static func describe(at p: NSPoint, t: Double, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> ScreenRecClickInfo? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let sys = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(primaryH - p.y), &hit) == .success, let el = hit else {
            return ScreenRecClickInfo(t: t, label: nil, role: nil, app: nil, window: nil)
        }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == ownPID { return nil }
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var label: String? = nil, roleDesc: String? = nil
        var cur: AXUIElement? = el
        for _ in 0..<4 {   // Bild in einer Taste angeklickt → Beschriftung der Taste
            guard let e = cur else { break }
            let role = str(e, kAXRoleAttribute)
            if role == "AXSecureTextField" { return ScreenRecClickInfo(t: t, label: nil, role: "Passwortfeld", app: app, window: windowTitle(e)) }
            if roleDesc == nil { roleDesc = str(e, kAXRoleDescriptionAttribute) }
            if let r = role, textRoles.contains(r) {
                label = str(e, kAXPlaceholderValueAttribute) ?? str(e, kAXTitleAttribute) ?? str(e, kAXDescriptionAttribute)
                break   // nie den Inhalt
            }
            label = str(e, kAXTitleAttribute) ?? str(e, kAXDescriptionAttribute)
            if label == nil, let r = role, ["AXStaticText", "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXTab"].contains(r) {
                label = str(e, kAXValueAttribute)
            }
            if label != nil { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success,
                  let pe = parent, CFGetTypeID(pe) == AXUIElementGetTypeID() else { break }
            cur = (pe as! AXUIElement)
        }
        return ScreenRecClickInfo(t: t, label: label.map(clip), role: roleDesc, app: app, window: windowTitle(el).map(clip))
    }

    private static func str(_ e: AXUIElement, _ a: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.isEmpty ? nil : t
    }

    private static func windowTitle(_ e: AXUIElement) -> String? {
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXWindowAttribute as CFString, &w) == .success, let we = w,
              CFGetTypeID(we) == AXUIElementGetTypeID() else { return nil }
        return str(we as! AXUIElement, kAXTitleAttribute)
    }

    static func clip(_ s: String) -> String { s.count > 60 ? String(s.prefix(58)) + "…" : s }
}

// MARK: - Zeichenstift (15.10.2026): ⌥ gedrückt halten → rote Linie, im Video zu sehen, verblasst nach dem Loslassen
//
// 18.10.2026 umgebaut (Wunsch: „zu langsam, hat gestockt“ – im Video wuchs der Strich nur alle 0,2–0,4 s in langen
// geraden Stücken, aus einem Kreis wurde ein Zickzack): Der Stift hängt nicht mehr am Main-Thread. Eine eigene Queue
// liest 120×/s Mausposition + ⌥ direkt vom System; gezeichnet wird gebündelt auf dem Main-Thread (nur dort kommt
// es ins Video – gemessen).
// Vorher kamen die Maus-Ereignisse über den Main-Thread und lasen erst beim Abarbeiten `NSEvent.mouseLocation` –
// hing der Main-Thread kurz, gingen alle Zwischenpunkte verloren. Dazu: geglättete Kurven statt Ecken,
// Leuchten als zweite breite Linie statt teurem Schatten.

final class ScreenRecInk {
    private var panel: NSPanel?
    /// Wurzel-Layer (Layer-Hosting: AppKit fasst die Unter-Layer nie an); geändert wird nur auf dem Main-Thread
    private var host: CALayer?
    private let q = DispatchQueue(label: "flow.stift", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    // nur auf q:
    private var line: CAShapeLayer?
    private var glow: CAShapeLayer?
    private var pts: [CGPoint] = []
    private var drawing = false
    private var screen: NSRect = .zero
    private var scale: CGFloat = 2
    private var primaryH: CGFloat = 0
    private var t0 = Date()
    private var markStart = 0.0
    private var _marks: [(start: Double, end: Double, box: NSRect)] = []

    /// Markierungen (Sekunden ab Aufnahmestart) – dort entsteht ein Schlüsselbild; `box` = Rahmen der Linie
    /// in Bildschirm-Punkten (global, Cocoa) → daraus wird der Ausschnitt fürs Video
    var marks: [(start: Double, end: Double, box: NSRect)] { q.sync { _marks } }

    var windowNumber: Int { panel?.windowNumber ?? 0 }
    static let color = NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.36, alpha: 1)
    static let hz = 120.0

    /// Panel sofort anlegen (vor der Aufnahme – nur so kommt es in den Filter), Zeichnen ab `start`
    func prepare(on s: NSScreen?) {
        let f = s?.frame ?? NSScreen.main?.frame ?? .zero
        screen = f
        scale = s?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .readOnly
        let v = NSView(frame: NSRect(origin: .zero, size: f.size))
        let root = CALayer()
        root.frame = v.bounds
        root.contentsScale = scale
        v.layer = root; v.wantsLayer = true   // erst Layer setzen, dann wantsLayer = Layer-Hosting
        p.contentView = v
        host = root
        p.setFrame(f, display: false)
        p.orderFrontRegardless()
        panel = p
    }

    /// Video folgt der Maus auf einen anderen Bildschirm: Panel (gleiches Fenster) dorthin, laufender Strich endet
    func move(to s: NSScreen) {
        guard let p = panel else { return }
        let f = s.frame, sc = s.backingScaleFactor
        p.setFrame(f, display: false)
        p.contentView?.frame = NSRect(origin: .zero, size: f.size)
        p.orderFrontRegardless()
        q.async { [self] in
            if drawing { end() }
            screen = f; scale = sc
            let h = host
            ca { h?.frame = CGRect(origin: .zero, size: f.size); h?.contentsScale = sc }
        }
    }

    /// laufende 120-Hz-Takte aller Stifte (Selbsttest: zweimal start → trotzdem nur einer)
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var _liveTimers = 0
    static var liveTimers: Int { liveLock.lock(); defer { liveLock.unlock() }; return _liveTimers }
    private static func countTimer(_ d: Int) { liveLock.lock(); _liveTimers += d; liveLock.unlock() }

    func start(at t0: Date) {
        let h = NSScreen.screens.first?.frame.height ?? 0
        q.async { [self] in
            // 18.10.2026: zweiter Start (überlappende Aufnahme-Starts) ließ den alten 120-Hz-Takt verwaist weiterlaufen
            timer?.cancel(); timer = nil
            self.t0 = t0
            primaryH = h
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: 1.0 / Self.hz, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.setCancelHandler { Self.countTimer(-1) }
            Self.countTimer(1)
            t.resume()
            timer = t
        }
    }

    /// 120×/s: ⌥ allein gehalten? Mausposition direkt vom System (unabhängig vom Main-Thread)
    private func tick() {
        let f = CGEventSource.flagsState(.combinedSessionState)
        let optionOnly = f.contains(.maskAlternate) && !f.contains(.maskCommand) && !f.contains(.maskControl) && !f.contains(.maskShift)
        guard optionOnly || drawing else { return }
        guard let l = CGEvent(source: nil)?.location else { return }
        let p = Self.local(l, primaryH: primaryH, screen: screen)
        if optionOnly && !drawing { begin(at: p) } else if !optionOnly && drawing { end(); return }
        add(p)
    }

    private func begin(at p: CGPoint) {
        guard let host else { return }
        drawing = true
        markStart = Date().timeIntervalSince(t0)
        pts = [p]
        // Nur anlegen – jede Layer-Eigenschaft wird auf dem Main-Thread gesetzt (Transaktionen von der Queue
        // erreichten das Video nicht, gemessen 18.10.)
        let g = CAShapeLayer(), l = CAShapeLayer(), sc = scale
        ca {
            for (x, w, a) in [(g, CGFloat(16), CGFloat(0.28)), (l, CGFloat(6), CGFloat(1))] {
                x.fillColor = nil; x.strokeColor = Self.color.withAlphaComponent(a).cgColor
                x.lineWidth = w; x.lineCap = .round; x.lineJoin = .round; x.contentsScale = sc
            }
            host.addSublayer(g); host.addSublayer(l)
        }
        glow = g; line = l
    }

    private func add(_ p: CGPoint) {
        guard let last = pts.last, hypot(p.x - last.x, p.y - last.y) >= 1 else { return }
        pts.append(p)
        show(Self.smooth(pts))
    }

    /// Layer-Änderungen IMMER auf dem Main-Thread: Änderungen von der Stift-Queue kamen nachweislich nicht ins Video
    /// (--ink-test sah sie, die Bildschirmaufnahme nicht). Abgetastet wird trotzdem auf der Queue – hängt der
    /// Main-Thread, kommt der Strich danach vollständig und rund nach statt als gerade Abkürzung.
    private func ca(_ body: @escaping () -> Void) {
        DispatchQueue.main.async { CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit() }
    }

    /// Pfad-Updates bündeln: höchstens ein Auftrag wartet auf dem Main-Thread, der nimmt dann den neuesten Pfad
    private var pending: (path: CGPath, line: CAShapeLayer?, glow: CAShapeLayer?)?
    private func show(_ path: CGPath) {
        let waiting = pending != nil
        pending = (path, line, glow)
        guard !waiting else { return }
        ca { [self] in
            guard let p = q.sync(execute: { () -> (path: CGPath, line: CAShapeLayer?, glow: CAShapeLayer?)? in defer { pending = nil }; return pending }) else { return }
            p.line?.path = p.path; p.glow?.path = p.path
        }
    }

    /// CGEvent-Position (Ursprung oben links am Hauptbildschirm) → Punkt im Panel (Cocoa, unten links)
    static func local(_ l: CGPoint, primaryH: CGFloat, screen: NSRect) -> CGPoint {
        CGPoint(x: l.x - screen.minX, y: primaryH - l.y - screen.minY)
    }

    /// Weiche Linie: Kurven durch die Mitten der Punkte (keine Ecken, auch bei schneller Bewegung)
    static func smooth(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 2 else { p.dropFirst().forEach { path.addLine(to: $0) }; if p.count == 1 { path.addLine(to: first) }; return path }
        for i in 1..<(p.count - 1) {
            let mid = CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: p[i])
        }
        path.addLine(to: p[p.count - 1])
        return path
    }

    private func end() {
        drawing = false
        guard let l = line, let g = glow else { return }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let len = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        if len > 12, let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() {
            let box = NSRect(x: x0 + screen.minX, y: y0 + screen.minY, width: x1 - x0, height: y1 - y0)
            _marks.append((markStart, Date().timeIntervalSince(t0), box))
        }
        line = nil; glow = nil; pts = []
        // 2 s stehen lassen, dann in 0,8 s verblassen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            for x in [l, g] {
                let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0; a.duration = 0.8
                a.fillMode = .forwards; a.isRemovedOnCompletion = false
                x.add(a, forKey: "weg")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { l.removeFromSuperlayer(); g.removeFromSuperlayer() }
        }
    }

    /// Nur für Tests (--screen-rec-probe … ink): Strich ohne echte Maus, Punkte in Panel-Koordinaten im Abstand `every` s
    func simulate(_ p: [CGPoint], every: Double) {
        q.async { [self] in
            guard let f = p.first else { return }
            t0 = Date()
            begin(at: f)
            for (i, pt) in p.enumerated().dropFirst() { q.asyncAfter(deadline: .now() + every * Double(i)) { self.add(pt) } }
            q.asyncAfter(deadline: .now() + every * Double(p.count) + 0.01) { self.end() }
        }
    }

    func stop() {
        q.sync {
            timer?.cancel(); timer = nil
            if drawing { end() }
        }
        // Panel noch kurz stehen lassen (letzte Linie verblasst), dann weg
        let p = panel; panel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { p?.orderOut(nil) }
    }
}

// MARK: - „Als Auftrag“ (15.10.2026): aus Transkript, Klicks, Markierungen und Bildern ein fertiger Auftrag für einen Agent

enum ScreenRecTask {
    static let system = """
    Du bekommst den Kontext einer Bildschirmaufnahme: Transkript mit Zeitmarken (was die Person sagt), Klicks \
    (worauf geklickt wurde), Markierungen (rot eingezeichnet, mit Ausschnitt-Bild des markierten Bereichs und dem, \
    was dabei gesagt wurde – das ist der stärkste Hinweis, worauf die Person zeigt), Schlüsselbilder und Mausspuren \
    mit Dateipfaden. \
    Schreibe daraus einen klaren Auftrag für einen Coding-Agenten (z. B. Claude Code), in der Sprache des Transkripts \
    (Standard Deutsch). Aufbau: \
    1) „Ziel“ – ein bis zwei Sätze, was die Person will. \
    2) „Was im Video passiert“ – knappe Stichpunkte mit Zeitmarken. \
    3) „Schritte zum Nachstellen“ – nur wenn es um einen Fehler oder Ablauf geht, aus den Klicks. \
    4) „Erwartet / Tatsächlich“ – nur bei einem Fehler. \
    5) „Material“ – Video-Pfad und die wichtigsten Bild-Pfade UNVERÄNDERT übernehmen (der Agent soll sie öffnen). \
    Erfinde nichts, was nicht im Kontext steht; Unklares als offene Frage am Ende. Keine Einleitung, kein Fazit, \
    nur der Auftrag als schlichter Text mit Überschriften.
    """

    /// Mit der lokalen Claude-CLI (Sonnet); ohne CLI oder bei Fehler: feste Vorlage
    static func build(video: URL, context: String) async -> String {
        if ClaudeCLI.isAvailable {
            let input = "Video: \(video.path)\n\n" + context
            if let out = try? await ClaudeCLI.run(system: system, input: input, model: "sonnet", timeout: 90) {
                let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 40 { return t }
            }
        }
        return fallback(video: video, context: context)
    }

    static func fallback(video: URL, context: String) -> String {
        "Auftrag aus einer Bildschirmaufnahme – bitte Video, Bilder und Transkript ansehen und umsetzen, was ich zeige und sage.\n\n"
            + "Video: \(video.path)\n\n" + context
    }
}

// MARK: - Aufnahme-Schutz (18.10.2026): Start-Nummern, Rückrufe, Speicherplatz, wachsende Dateien, Abspiel-Prüfung
//
// Anlass: Stopp während „starting“ + neuer Start → der alte Start-Task wachte im neuen „starting“ auf und setzte
// Stream/Ausgabe ein zweites Mal; Klick-Monitor und 30-Hz-Maus-Takt wurden überschrieben statt entfernt, der Stift
// startete zweimal (verwaister 120-Hz-Takt). Die Sicherheitsnetze und `recordingOutputDidFinishRecording` ohne
// Identitäts-Prüfung konnten die NÄCHSTE Aufnahme vorzeitig „fertig“ machen. Dazu: Platte zu 90 % voll bei bis zu
// ~23 GB/h (3024×1964, 60 fps) und ein replayd, der nach einem Fehlstart 18 GB weiterschrieb.
// Alles hier ist reine Logik → ohne Aufnahme prüfbar: Flow --selftest-aufnahme-schutz

/// Jeder Start bekommt eine neue Nummer, ein Abbruch macht die laufende ungültig. Was nach einem `await`
/// weiterläuft (Start-Task, Sicherheitsnetz), fragt zuerst: „bin ich noch dran?“ – nur auf dem Main-Thread benutzen.
final class ScreenRecStartGate {
    private(set) var current = 0
    /// neuer Start → seine Nummer
    func begin() -> Int { current += 1; return current }
    /// laufender Start wird ungültig (Stopp während „starting“, Ruhezustand, Fehler)
    func cancel() { current += 1 }
    func isCurrent(_ g: Int) -> Bool { g == current }
    /// Start-Task nach einem await: nur weiter, wenn er noch der aktuelle ist UND die Phase noch „starting“
    func mayContinue(_ g: Int, phase: ScreenRec.Phase) -> Bool { isCurrent(g) && phase == .starting }
    /// Sicherheitsnetz (6 s nach dem Stopp): nur die EIGENE Aufnahme fertig machen, nie eine schnell folgende
    func netMayFire(_ g: Int, phase: ScreenRec.Phase) -> Bool { isCurrent(g) && phase == .finishing }
}

/// Klick-Monitor, Maus-Takt & Co. einer Aufnahme: jedes Anlegen liefert seinen Abräum-Auftrag. `replace` räumt IMMER
/// erst alles Alte ab – vorher wurden Monitor und Takt bei zwei Starts einfach überschrieben (verwaist, mouse[] wuchs ewig).
final class ScreenRecTrackers {
    private var removers: [() -> Void] = []
    var count: Int { removers.count }
    func replace(_ installs: [() -> () -> Void]) {
        removeAll()
        removers = installs.map { $0() }
    }
    func removeAll() {
        let r = removers
        removers = []
        r.forEach { $0() }
    }
}

enum ScreenRecGuard {
    // MARK: Speicherplatz

    /// vor dem Start mindestens so viel frei (eine Stunde Aufnahme ≈ 23 GB)
    static let minFreeToStart: Int64 = 5_000_000_000
    /// während der Aufnahme darunter: sauber stoppen, bevor die Platte vollläuft
    static let minFreeWhileRecording: Int64 = 2_000_000_000
    /// Prüfung im Pillen-Wächter (0,5 s) nur jede 20. Runde = alle 10 s (bei 52 Mbit/s ≈ 65 MB dazwischen)
    static let spaceEveryTicks = 20

    static func spaceDue(tick: Int) -> Bool { tick > 0 && tick % spaceEveryTicks == 0 }

    /// Freier Platz wie im Finder („für wichtige Daten“, inkl. löschbarer Caches), sonst der reine freie Platz;
    /// nil = unbekannt. Frisches URL → keine zwischengespeicherten Werte. Dauert ~5–30 ms.
    static func freeBytes(at dir: URL) -> Int64? {
        let u = URL(fileURLWithPath: dir.path, isDirectory: true)
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let i = v.volumeAvailableCapacityForImportantUsage, i > 0 { return i }
        return v.volumeAvailableCapacity.map { Int64($0) }
    }

    /// unbekannter Platz blockiert nie (lieber aufnehmen als grundlos verweigern)
    static func mayStart(free: Int64?) -> Bool { free.map { $0 >= minFreeToStart } ?? true }
    static func mustStop(free: Int64?) -> Bool { free.map { $0 < minFreeWhileRecording } ?? false }

    /// „3,2 GB“ (dezimal wie der Finder, deutsches Komma)
    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(max(0, bytes)) / 1e9).replacingOccurrences(of: ".", with: ",")
    }
    static func refuseText(free: Int64) -> String {
        "Nur noch \(gb(free)) frei – eine Aufnahme braucht mindestens \(gb(minFreeToStart)) (eine Stunde kann bis zu 23 GB groß werden). Bitte erst Platz schaffen, dann ⌃⌥R."
    }
    static func stopText(free: Int64) -> String {
        "Automatisch gestoppt: nur noch \(gb(free)) frei."
    }

    // MARK: Wächst die Datei noch? (replayd schreibt nach einem Ende weiter)

    enum Growth: Equatable { case missing, empty, stable, growing }
    enum FileAction: Equatable { case none, trash, warn }

    /// Zwei Messungen (Bytes, −1 = Datei fehlt): b > a → wächst (auch „eben erst entstanden“)
    static func growth(_ a: Int, _ b: Int) -> Growth {
        if b > a { return .growing }
        if b < 0 { return .missing }
        if b == 0 { return .empty }
        return .stable
    }

    /// keep = fertige Aufnahme: nie löschen, nur warnen, wenn sie weiterwächst. Sonst (angefangene Datei eines
    /// Fehlstarts/Abbruchs): steht sie still → Papierkorb, wächst sie → warnen.
    static func action(_ g: Growth, keep: Bool) -> FileAction {
        switch g {
        case .growing: return .warn
        case .missing: return .none
        case .empty, .stable: return keep ? .none : .trash
        }
    }

    /// `killall -9 replayd` beendet ALLE Bildschirmaufnahmen des Macs → nur, wenn die Datei nachweislich JETZT wächst
    static func mayKillReplayd(_ g: Growth) -> Bool { g == .growing }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
    }

    /// Nach `after` s messen, `gap` s später nochmal (abseits des Main-Threads); Ergebnis auf dem Main-Thread
    static func sampleGrowth(_ url: URL, after: Double = 2, gap: Double = 3, _ done: @escaping (Growth, Int, Int) -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + after) {
            let a = size(url)
            Thread.sleep(forTimeInterval: gap)
            let b = size(url)
            DispatchQueue.main.async { done(growth(a, b), a, b) }
        }
    }

    // MARK: Rückrufe von SCRecordingOutput / SCStream

    enum Callback { case finish, fileError, streamStop }

    static func isCurrent(_ obj: AnyObject, _ cur: AnyObject?) -> Bool { cur.map { $0 === obj } ?? false }

    /// Nur Rückrufe der AKTUELLEN Ausgabe/des aktuellen Streams zählen – eine alte (überholter Start, vorige
    /// Aufnahme) darf die nächste nie beenden
    static func accept(_ cb: Callback, from obj: AnyObject, current: AnyObject?, phase: ScreenRec.Phase) -> Bool {
        guard isCurrent(obj, current) else { return false }
        switch cb {
        case .finish: return phase == .finishing
        case .fileError: return phase == .starting || phase == .recording || phase == .finishing
        case .streamStop: return phase == .starting || phase == .recording
        }
    }

    // MARK: Abspielbar?

    static func playable(hasVideo: Bool, duration: Double) -> Bool { hasVideo && duration.isFinite && duration > 0 }

    /// MP4 lesbar: Video-Spur da und Dauer > 0 (abseits des Main-Threads). Ohne abgeschlossenes moov → false.
    static func playable(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            let asset = AVURLAsset(url: url)
            guard let (tracks, dur) = try? await asset.load(.tracks, .duration) else { return false }
            return playable(hasVideo: tracks.contains { $0.mediaType == .video }, duration: dur.seconds)
        }.value
    }
}
