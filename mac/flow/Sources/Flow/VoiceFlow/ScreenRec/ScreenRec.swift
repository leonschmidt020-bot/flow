import AppKit
import AVFoundation
import ScreenCaptureKit

// MARK: - Bildschirmaufnahme über die Pille
//
// Problem mit der macOS-Aufnahme: mit mehreren Bildschirmen landet sie oft auf dem falschen, und Ton gibt es nur
// mit Umwegen. Hier:
//   ⌃⌥R (oder Menü „Bildschirm aufnehmen …“, Kontrollzentrum-Knopf) → Karte an der Pille: „Erkannt: <Bildschirm
//   unter der Maus>“ (wandert mit, wenn die Maus den Bildschirm wechselt; der Bildschirm bekommt einen roten Rahmen),
//   Ton-Wahl „Ohne Ton · Mikrofon · Systemton“ (letzte Wahl vorgewählt), Schalter „Maus leuchtet“ → „Aufnehmen“
//   (oder ⌃⌥R) → Countdown 3 · 2 · 1 in der Pille → Aufnahme NUR dieses Bildschirms. Flow selbst (Pille, Karten,
//   Rahmen) ist auf dem Video nicht zu sehen – außer dem Maus-Leuchten. Pille zeigt ● Laufzeit ■; Klick/⌃⌥R = Stopp.
//   → Karte „Aufnahme fertig“ sofort: „Kopieren“ (echte Datei + Pfad, wahlweise mit Transkript, Schlüsselbildern und
//   Mausspuren für Agents) · „Nochmal“ (gleicher Bildschirm, gleicher Ton, sofort Countdown).
// Datei: Ablageort der macOS-Bildschirmfotos (com.apple.screencapture location) → sonst Schreibtisch.
// Technik: ScreenCaptureKit + SCRecordingOutput (H.264-MP4). Das Mikrofon mischt macOS in DIESELBE Tonspur –
// jeder Player spielt es ab. Transkript lokal mit Parakeet (wie das Diktat).

/// Ton-Wahl: entweder Mikrofon ODER Systemton („beides zusammen“ war verwirrend).
enum ScreenRecSound: String, CaseIterable {
    case none = "Ohne Ton", mic = "Mikrofon", system = "Systemton"
    var short: String { self == .none ? "ohne Ton" : self == .mic ? "mit Mikrofon" : "mit Systemton" }
    /// 16.10.2026 (Bericht: bei Systemton kam kein Transkript): Transkript, sobald Ton aufgenommen wird
    var transcribes: Bool { self != .none }
    /// gespeicherte Wahl (alte Fassung „Systemton + Mikro“ → Mikrofon: da wurde erklärt)
    static func stored(_ raw: String?) -> ScreenRecSound {
        if raw == "Systemton + Mikro" { return .mic }
        return ScreenRecSound(rawValue: raw ?? "") ?? .system
    }
}

/// Kopier-Art der fertigen Aufnahme: nur die Datei – oder mit Kontext für Agents (Schlüsselbilder, mit Mikrofon
/// auch das Transkript)
enum ScreenRecCopy: String, CaseIterable {
    case video = "Nur Video", withContext = "Mit Kontext", task = "Als Auftrag"
    /// Kurz, damit drei Chips in die Karte passen; was „Kontext“ ist, sagt der Kartentext
    static func label(_ c: ScreenRecCopy, sound: ScreenRecSound) -> String { c.rawValue }
}

final class ScreenRec: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    static let shared = ScreenRec()

    enum Phase: Equatable { case idle, arming, countdown, starting, recording, finishing }
    private(set) var phase: Phase = .idle

    weak var pill: PillController?
    /// Pillen-Zustand, wenn gerade nichts Eigenes läuft (Meeting o. Ä.) – vom AppDelegate gesetzt
    var fallbackMode: () -> PillView.Mode = { .idle }

    static let cardID = "bildschirm_aufnahme"
    static let doneID = "aufnahme_fertig"
    private static let soundKey = "screenRecSound"
    private static let glowKey = "screenRecGlow"

    private var armTimer: Timer?
    private var countdownTimer: Timer?
    private var guardTimer: Timer?
    private var target: NSScreen?
    private var sound: ScreenRecSound = .system
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var fileURL: URL?
    private var filter: SCContentFilter?
    private var display: SCDisplay?
    private var startedAt = Date()
    private var frame: ScreenRecFrame?
    private var glow = false
    private var glowView: ScreenRecCursorGlow?
    /// fertige Aufnahme (Karte erscheint sofort beim Beenden, die Datei wird dahinter fertig geschrieben)
    private var done: ScreenRecDone?
    /// Klicks während der Aufnahme (Sekunden ab Start) – dort entstehen Schlüsselbilder
    private var clicks: [TimeInterval] = []
    private var clickInfos: [ScreenRecClickInfo] = []
    private var inkView: ScreenRecInk?
    /// Mausposition während der Aufnahme (30×/s, Bildschirm-Koordinaten) → Mausspur-Bilder
    private var mouse: [ScreenRecMouse] = []
    /// Klick-Monitor + 30-Hz-Maus-Takt (18.10.2026: vor jedem Anlegen wird das Alte abgeräumt, nie überschrieben)
    private let trackers = ScreenRecTrackers()
    /// 18.10.2026: Start-Nummer – ein Start, der nach einem await nicht mehr dran ist, baut nur seinen eigenen Stream ab
    let gate = ScreenRecStartGate()
    private var guardTicks = 0
    private var spaceChecking = false
    private var systemObservers: [NSObjectProtocol] = []
    /// 16.10.2026 (Wunsch: „mit der Maus auf einen anderen Bildschirm gehen und der wird dann aufgenommen“):
    /// das Video folgt der Maus über alle Bildschirme. Wechsel = (Zeit, Bildschirm-Rahmen, Name), erster Eintrag bei 0.
    private var switches: [ScreenRecSwitch] = []
    private var current: NSScreen?
    private var pendingScreen: (screen: NSScreen, since: Date)?
    private var switching = false
    private var glowWin: SCWindow?
    private var inkWin: SCWindow?
    private var me: [SCRunningApplication] = []
    static let followKey = "screenRecFollowMouse"
    var followsMouse: Bool { UserDefaults.standard.object(forKey: Self.followKey) as? Bool ?? true }

    var isRecording: Bool { phase == .recording || phase == .starting }
    /// Pille während Countdown/Aufnahme (Diktat dazwischen kehrt hierher zurück)
    var restingPillMode: PillView.Mode? {
        switch phase {
        case .recording: return .screenRec(start: startedAt)
        default: return nil
        }
    }

    // MARK: Auslöser

    /// ⌃⌥R / Menü: je nach Zustand öffnen → starten → stoppen
    func toggle() {
        switch phase {
        case .idle: arm()
        case .arming: begin(sound: VFNotify.shared.currentChoice.flatMap(ScreenRecSound.init(rawValue:)) ?? sound,
                            glow: VFNotify.shared.currentToggle ?? glow)
        case .countdown: cancelCountdown()
        case .starting, .recording: stop()
        case .finishing: break
        }
    }

    /// Klick auf die Pille während Countdown (abbrechen) oder Aufnahme (stoppen)
    func pillClicked() {
        if phase == .countdown { cancelCountdown() } else if isRecording { stop() }
    }

    // MARK: 1. Karte: Bildschirm erkannt + Ton wählen

    func arm() {
        guard phase == .idle else { return }
        guard enoughSpaceToStart() else { return }
        VFNotify.shared.dismiss(id: Self.doneID)
        sound = ScreenRecSound.stored(UserDefaults.standard.string(forKey: Self.soundKey))
        glow = UserDefaults.standard.bool(forKey: Self.glowKey)
        phase = .arming
        target = Self.screenUnderMouse()
        showArmCard()
        frame = ScreenRecFrame()
        frame?.show(on: target)
        armTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.followMouse() }
        RunLoop.main.add(t, forMode: .common)
        armTimer = t
        log("Bildschirmaufnahme: bereit – \(Self.name(target))")
    }

    private func followMouse() {
        guard phase == .arming else { return }
        // Karte schon weg (✕ oder Zeit abgelaufen)? → ganz abbrechen
        if VFNotify.shared.currentID != Self.cardID, !VFNotify.shared.isShowing { disarm(); return }
        let s = Self.screenUnderMouse()
        guard s != target else { return }
        target = s
        frame?.show(on: s)
        showArmCard()
    }

    private func showArmCard() {
        let s = target
        var n = VFNotice(id: Self.cardID, title: "Bildschirm aufnehmen",
                         text: "Erkannt: \(Self.name(s))\(Self.sizeLabel(s)). Anderen? Maus hinbewegen – beim Aufnehmen folgt das Video der Maus.",
                         illustration: "illu_bildschirm_aufnahme", fallbackSymbol: "record.circle")
        n.choices = ScreenRecSound.allCases.map(\.rawValue)
        n.preselect = ScreenRecSound.allCases.firstIndex(of: sound) ?? 2
        n.toggle = VFNoticeToggle(label: "Maus leuchtet (fürs Erklären)", symbol: "cursorarrow.rays", on: glow)
        n.primary = ("Aufnehmen", { [weak self] in
            guard let self else { return }
            self.begin(sound: VFNotify.shared.chosen.flatMap(ScreenRecSound.init(rawValue:)) ?? self.sound,
                       glow: VFNotify.shared.chosenToggle ?? self.glow)
        })
        n.secondary = ("Abbrechen", { [weak self] in self?.disarm() })
        n.timeout = nil
        n.onClose = { [weak self] in self?.disarm() }
        n.chip = VFNoticeChip(label: "Pille und Karten sind nicht im Video", symbol: "eye.slash", tint: .red)
        VFNotify.shared.show(n)
    }

    private func disarm() {
        guard phase == .arming else { return }
        armTimer?.invalidate(); armTimer = nil
        frame?.hide(); frame = nil
        VFNotify.shared.dismiss(id: Self.cardID)
        phase = .idle
        log("Bildschirmaufnahme: abgebrochen")
    }

    // MARK: 2. Countdown

    private func begin(sound s: ScreenRecSound, glow g: Bool) {
        guard phase == .arming || phase == .idle else { return }
        // auch für „Nochmal“ (geht nicht über arm): unter 5 GB frei gar nicht erst anfangen
        guard enoughSpaceToStart() else {
            armTimer?.invalidate(); armTimer = nil
            frame?.hide(); frame = nil
            VFNotify.shared.dismiss(id: Self.cardID)
            phase = .idle
            return
        }
        watchSystem()
        sound = s; glow = g
        UserDefaults.standard.set(s.rawValue, forKey: Self.soundKey)
        UserDefaults.standard.set(g, forKey: Self.glowKey)
        armTimer?.invalidate(); armTimer = nil
        VFNotify.shared.dismiss(id: Self.cardID)
        if target == nil { target = Self.screenUnderMouse() }
        if frame == nil { frame = ScreenRecFrame() }
        frame?.show(on: target)
        guard CGPreflightScreenCaptureAccess() else { phase = .idle; frame?.hide(); frame = nil; askPermission(); return }
        phase = .countdown
        var n = 3
        setPill(.screenRecCountdown(n))
        countdownTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] tm in
            guard let self, self.phase == .countdown else { tm.invalidate(); return }
            n -= 1
            if n > 0 { self.setPill(.screenRecCountdown(n)) } else { tm.invalidate(); self.startCapture() }
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    private func cancelCountdown() {
        guard phase == .countdown else { return }
        countdownTimer?.invalidate(); countdownTimer = nil
        frame?.hide(); frame = nil
        phase = .idle
        setPill(fallbackMode())
        pill?.view.showToast("Aufnahme abgebrochen")
    }

    // MARK: Schutz: Speicherplatz, Ruhezustand/Sperre (18.10.2026)

    /// Platte 90 % voll, eine Stunde Aufnahme bis ~23 GB → unter 5 GB frei gar nicht erst anfangen (Karte erklärt warum)
    private func enoughSpaceToStart() -> Bool {
        let free = ScreenRecGuard.freeBytes(at: Self.folder())
        guard !ScreenRecGuard.mayStart(free: free), let free else { return true }
        log("Bildschirmaufnahme: nicht gestartet – nur \(ScreenRecGuard.gb(free)) frei (mindestens \(ScreenRecGuard.gb(ScreenRecGuard.minFreeToStart)))")
        VFNotify.shared.show(id: "aufnahme_speicher", title: "Zu wenig Speicher für eine Aufnahme",
                             text: ScreenRecGuard.refuseText(free: free),
                             illustration: "illu_bildschirm_aufnahme",
                             primary: ("Speicher ansehen", {
                                 NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                             }), secondary: ("OK", {}), timeout: 20)
        return false
    }

    /// Ruhezustand, Bildschirmsperre, Benutzerwechsel → Aufnahme sauber beenden, statt dass macOS sie irgendwo
    /// abschneidet (MP4 womöglich nie abgeschlossen). Einmal angemeldet, gilt für die ganze Laufzeit.
    private func watchSystem() {
        guard systemObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        systemObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSuspend("Ruhezustand", reason: "Gestoppt, weil der Mac in den Ruhezustand ging.", sync: true)
        })
        systemObservers.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSuspend("Benutzerwechsel/Sperre", reason: "Gestoppt, weil die Sitzung gewechselt oder gesperrt wurde.", sync: false)
        })
        systemObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                                                  object: nil, queue: .main) { [weak self] _ in
            self?.systemSuspend("Bildschirm gesperrt", reason: "Gestoppt, weil der Bildschirm gesperrt wurde.", sync: false)
        })
    }

    /// sync: im Ruhezustand blockierend stoppen (macOS wartet auf willSleep-Beobachter), damit das MP4 vor dem
    /// Schlafen abgeschlossen ist
    private func systemSuspend(_ what: String, reason: String, sync: Bool) {
        switch phase {
        case .countdown:
            log("Bildschirmaufnahme: Countdown abgebrochen – \(what)")
            cancelCountdown()
        case .starting:
            abortStart(what)
        case .recording:
            log("Bildschirmaufnahme: gestoppt – \(what)")
            stop(reason: reason, sync: sync)
        default: break
        }
    }

    // MARK: 3. Aufnahme

    private func startCapture() {
        // 18.10.2026: Stopp während „starting“ (SCShareableContent langsam) + neuer Start → der alte Task wachte im
        // neuen „starting“ auf, kam am Phasen-Wächter vorbei und überschrieb Stream, Klick-Monitor und Maus-Takt.
        // Darum: eigene Start-Nummer, nach JEDEM await geprüft; Stream/Monitore werden nur gesetzt, solange sie passt.
        let g = gate.begin()
        phase = .starting
        frame?.hide(); frame = nil
        let screen = target ?? Self.screenUnderMouse()
        let sound = self.sound
        let url = Self.newFileURL()
        // Reste eines früheren Starts (dürfte es nicht mehr geben) erst abräumen, nie überschreiben
        trackers.removeAll()
        glowView?.stop(); inkView?.stop()
        // Leuchten um die Maus: eigenes Fenster, das als einziges von Flow MIT ins Video kommt
        let glowV: ScreenRecCursorGlow? = glow ? ScreenRecCursorGlow() : nil
        glowV?.start()
        glowView = glowV
        // Zeichenstift (⌥ halten): Panel jetzt anlegen, damit es als Ausnahme mit ins Video kommt
        let ink = ScreenRecInk(); ink.prepare(on: screen); inkView = ink
        fileURL = url
        Task { @MainActor in
            // gehören nur diesem Start – abgebaut wird nur das hier, nie der Stream eines neueren Starts
            var st: SCStream?, out: SCRecordingOutput?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard self.gate.mayContinue(g, phase: self.phase) else {
                    log("Bildschirmaufnahme: Start #\(g) überholt (gestoppt oder neu gestartet) – verworfen, bevor etwas lief")
                    glowV?.stop(); ink.stop()
                    return
                }
                let id = Self.displayID(screen)
                guard let disp = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                    throw NSError(domain: "ScreenRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "kein Bildschirm gefunden"])
                }
                // Flow selbst (Pille, Karten, Rahmen) gehört nicht ins Video
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let glowWin = glowV.flatMap { gv in content.windows.first { $0.windowID == CGWindowID(gv.windowNumber) } }
                if glowV != nil && glowWin == nil { log("Bildschirmaufnahme: Maus-Leuchten nicht gefunden – Aufnahme ohne") }
                let inkWin = content.windows.first { $0.windowID == CGWindowID(ink.windowNumber) }
                let filter = SCContentFilter(display: disp, excludingApplications: me,
                                             exceptingWindows: [glowWin, inkWin].compactMap { $0 })
                let cfg = Self.configuration(display: disp, screen: screen, sound: sound)
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                st = s
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = url
                rc.outputFileType = .mp4
                rc.videoCodecType = .h264
                let o = SCRecordingOutput(configuration: rc, delegate: self)
                out = o
                try s.addRecordingOutput(o)
                // seit dem Wächter oben kein await → dieser Start ist noch dran
                self.me = me; self.glowWin = glowWin; self.inkWin = inkWin
                self.stream = s; self.output = o
                Self.setLive(s)
                self.filter = filter; self.display = disp
                try await s.startCapture()
                guard self.gate.mayContinue(g, phase: self.phase) else {
                    log("Bildschirmaufnahme: Start #\(g) überholt, während macOS startete – Stream wieder abgebaut")
                    await Self.tearDown(s, o, captureStarted: true, why: "veralteter Start")
                    if self.stream === s { self.stream = nil; self.output = nil }
                    glowV?.stop(); ink.stop()
                    Self.watchFile(url, keep: false)
                    return
                }
                self.startedAt = Date()
                self.clicks = []
                let t0 = self.startedAt
                self.clickInfos = []
                ink.start(at: t0)
                self.pill?.view.showToast("⌥ halten = auf dem Bildschirm zeichnen", seconds: 2.6)
                self.mouse = []
                self.current = screen
                self.pendingScreen = nil
                self.switches = [ScreenRecSwitch(t: 0, frame: screen?.frame ?? .zero, name: Self.name(screen))]
                self.installTrackers(t0: t0, gen: g)
                self.phase = .recording
                self.setPill(.screenRec(start: self.startedAt))
                self.startGuard()
                log("Bildschirmaufnahme läuft: \(Self.name(screen)) \(cfg.width)×\(cfg.height), \(sound.rawValue)\(glowV != nil ? ", Maus leuchtet" : "") → \(url.lastPathComponent)")
            } catch {
                log("Bildschirmaufnahme: Start #\(g) fehlgeschlagen – \(error.localizedDescription)")
                // 18.10.2026: Ausgabe hing schon am Stream → replayd schrieb nach „Mikrofon konnte nicht starten“
                // 1,5 h unbemerkt weiter (18 GB, Flow-Neustart half nicht). Darum Ausgabe abhängen + Stream stoppen,
                // die angefangene Datei prüfen (wächst sie → Warnung, steht sie → Papierkorb).
                await Self.tearDown(st, out, captureStarted: false, why: "Fehlstart")
                Self.watchFile(url, keep: false)
                if self.gate.mayContinue(g, phase: self.phase) {
                    self.reset()
                    self.pill?.view.showToast("Aufnahme ging nicht: \(error.localizedDescription.prefix(50))", seconds: 4)
                } else {
                    // schon überholt: nur die eigenen Reste, den neueren Start nicht anfassen
                    if let st, self.stream === st { self.stream = nil; self.output = nil }
                    glowV?.stop(); ink.stop()
                }
            }
        }
    }

    /// Klick-Monitor (Schlüsselbilder + Klick-Kontext) und 30-Hz-Maus-Takt (Mausspur, Video folgt der Maus).
    /// `replace` räumt vorher alles Alte ab – zwei Starts hinterließen sonst einen verwaisten globalen Monitor und Takt.
    private func installTrackers(t0: Date, gen g: Int) {
        trackers.replace([
            { [weak self] in
                let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                    guard let self, self.gate.isCurrent(g), self.phase == .recording else { return }
                    let t = Date().timeIntervalSince(t0), p = NSEvent.mouseLocation
                    self.clicks.append(t)
                    ScreenRecClickProbe.queue.async {
                        guard let info = ScreenRecClickProbe.describe(at: p, t: t) else { return }
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.gate.isCurrent(g) else { return }   // nie in die nächste Aufnahme
                            self.clickInfos.append(info)
                        }
                    }
                }
                return { if let m { NSEvent.removeMonitor(m) } }
            },
            { [weak self] in
                let mt = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    guard let self, self.phase == .recording else { return }
                    let m = NSEvent.mouseLocation
                    self.mouse.append(ScreenRecMouse(t: Date().timeIntervalSince(t0), x: m.x, y: m.y))
                    self.followMouse(m)
                }
                RunLoop.main.add(mt, forMode: .common)
                return { mt.invalidate() }
            },
        ])
    }

    /// Stopp/Ruhezustand/Fehler während „starting“: Start-Nummer ungültig machen. Der Start-Task baut beim Aufwachen
    /// seinen Stream selbst ab; hängt schon einer am Objekt, wird er sofort mit abgebaut (falls macOS nie zurückkommt).
    private func abortStart(_ why: String, toast: String = "Aufnahme abgebrochen") {
        guard phase == .starting else { return }
        gate.cancel()
        let st = stream, url = fileURL
        log("Bildschirmaufnahme: Start abgebrochen – \(why)")
        reset()
        if let st {
            Task { @MainActor in
                // Start läuft noch: nur stoppen. Wirft startCapture danach, hängt der Start-Task die Ausgabe selbst ab
                // (Fehlstart); kommt es zurück, stoppt er als „veralteter Start“ – nie beides auf einem laufenden Writer.
                await Self.tearDown(st, nil, captureStarted: true, why: why)
                if let url { Self.watchFile(url, keep: false) }
            }
        }
        pill?.view.showToast(toast, seconds: 2.5)
    }

    static func configuration(display: SCDisplay, screen: NSScreen?, sound: ScreenRecSound) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let scale = screen?.backingScaleFactor ?? 2
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 8
        cfg.showsCursor = true
        cfg.showMouseClicks = true
        cfg.capturesAudio = sound == .system
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = sound == .mic
        // Wechselt das Video auf einen anders geformten Bildschirm: einpassen statt verzerren
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        return cfg
    }

    /// Maus steht ≥ 0,35 s auf einem anderen Bildschirm → Video wechselt dorthin (gleiche Datei, kein Neustart)
    private func followMouse(_ m: NSPoint) {
        guard followsMouse, phase == .recording, !switching, NSScreen.screens.count > 1 else { return }
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        if s == current { pendingScreen = nil; return }
        if let p = pendingScreen, p.screen == s {
            if Date().timeIntervalSince(p.since) >= 0.35 { switchTo(s) }
        } else {
            pendingScreen = (s, Date())
        }
    }

    private func switchTo(_ s: NSScreen) {
        guard let st = stream else { return }
        switching = true
        pendingScreen = nil
        let id = Self.displayID(s), t = Date().timeIntervalSince(startedAt)
        Task { @MainActor in
            defer { self.switching = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // dieselbe Aufnahme? (inzwischen gestoppt/neu gestartet → nichts anfassen)
                guard self.phase == .recording, self.stream === st, let disp = content.displays.first(where: { $0.displayID == id }) else { return }
                // Stift-Panel mitnehmen (gleiches Fenster → bleibt Ausnahme im Filter)
                self.inkView?.move(to: s)
                let f = SCContentFilter(display: disp, excludingApplications: self.me,
                                        exceptingWindows: [self.glowWin, self.inkWin].compactMap { $0 })
                try await st.updateContentFilter(f)
                guard self.stream === st else { return }
                self.filter = f; self.display = disp
                self.current = s
                self.switches.append(ScreenRecSwitch(t: t, frame: s.frame, name: Self.name(s)))
                log("Bildschirmaufnahme: Bildschirm gewechselt → \(Self.name(s)) bei \(String(format: "%.1f", t)) s")
            } catch {
                log("Bildschirmaufnahme: Wechsel auf \(Self.name(s)) ging nicht – \(error.localizedDescription)")
                self.current = s   // nicht ständig neu versuchen
            }
        }
    }

    /// Pille bleibt auf „Aufnahme“, auch wenn Diktat oder Meeting sie zwischendurch umstellen.
    /// 18.10.2026: alle 10 s zusätzlich der freie Platz (abseits des Main-Threads) – unter 2 GB sauber stoppen.
    private func startGuard() {
        guardTimer?.invalidate()
        guardTicks = 0; spaceChecking = false
        let g = gate.current, dir = fileURL?.deletingLastPathComponent() ?? Self.folder()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.phase == .recording else { return }
            if let v = self.pill?.view {
                if case .idle = v.mode { v.mode = .screenRec(start: self.startedAt) }
                if case .meeting = v.mode { v.mode = .screenRec(start: self.startedAt) }
            }
            self.guardTicks += 1
            guard ScreenRecGuard.spaceDue(tick: self.guardTicks), !self.spaceChecking else { return }
            self.spaceChecking = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let free = ScreenRecGuard.freeBytes(at: dir)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.spaceChecking = false
                    guard self.phase == .recording, self.gate.isCurrent(g), ScreenRecGuard.mustStop(free: free), let free else { return }
                    log("Bildschirmaufnahme: nur noch \(ScreenRecGuard.gb(free)) frei – automatisch gestoppt")
                    self.stop(reason: ScreenRecGuard.stopText(free: free))
                    self.pill?.view.showToast("Speicher fast voll – Aufnahme gestoppt", seconds: 4)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        guardTimer = t
    }

    /// reason: warum automatisch gestoppt wurde (Speicher, Ruhezustand, macOS) – steht dann in der Fertig-Karte.
    /// sync: blockierend stoppen (Ruhezustand), höchstens 1,5 s.
    func stop(reason: String? = nil, sync: Bool = false) {
        // Stopp während „starting“ = Abbruch: Start-Nummer ungültig, der Start-Task räumt seinen Stream selbst ab
        if phase == .starting { abortStart(reason ?? "Stopp während des Starts"); return }
        guard phase == .recording, let st = stream else { return }
        let g = gate.current, out = output
        phase = .finishing
        guardTimer?.invalidate(); guardTimer = nil
        glowView?.stop(); glowView = nil
        trackers.removeAll()
        // Markierungen fürs Video lesen, BEVOR der Stift aufräumt
        let inkMarks = inkView?.marks ?? []
        inkView?.stop(); inkView = nil
        // 15.10.2026 (Wunsch: „5 s lang kam nichts – wo ist das Video?“): Karte SOFORT zeigen; Datei, Vorschaubild und
        // Transkript kommen dahinter nach (Kopieren wartet, falls die Datei noch nicht fertig ist).
        if let url = fileURL {
            let d = ScreenRecDone(url: url, duration: Date().timeIntervalSince(startedAt), screen: Self.name(target), sound: sound)
            d.clicks = clicks
            d.clickInfos = clickInfos
            d.marks = inkMarks.map { [$0.start, $0.end] }
            d.markBoxes = inkMarks.map(\.box)
            d.mouse = mouse
            d.screenFrame = target?.frame ?? Self.screenUnderMouse()?.frame ?? .zero
            d.switches = switches.isEmpty ? [ScreenRecSwitch(t: 0, frame: d.screenFrame, name: d.screen)] : switches
            let names = Set(d.switches.map(\.name))
            if names.count > 1 { d.screen = "\(names.count) Bildschirme" }
            d.stopReason = reason
            d.onChange = { [weak self, weak d] in if let d { self?.showDone(d) } }
            done = d
            showDone(d)
        }
        setPill(fallbackMode())
        if sync {
            let ok = Self.stopNow(st, timeout: 1.5)
            log("Bildschirmaufnahme: blockierend gestoppt\(ok ? "" : " (ohne Rückmeldung nach 1,5 s)")")
        }
        Task { @MainActor in
            if !sync { await Self.tearDown(st, out, captureStarted: true, why: reason == nil ? "Stopp" : "automatischer Stopp") }
            // fertig wird die Datei erst mit recordingOutputDidFinishRecording; Sicherheitsnetz nach 6 s – nur für
            // DIESE Aufnahme (vorher konnte es eine schnell folgende nächste vorzeitig „fertig“ machen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.gate.netMayFire(g, phase: self.phase) else { return }
                log("Bildschirmaufnahme: keine Fertig-Meldung nach 6 s – Sicherheitsnetz")
                self.finished()
            }
        }
    }

    // MARK: Abbau (18.10.2026): ein Weg für jedes Ende

    /// Was beim Abbau passiert. 19.10.2026 – fünf Aufnahmen hintereinander „beschädigt“ (kein moov-Atom, replayd-Absturz
    /// in -[AVAssetWriter endSessionAtSourceTime:] bei JEDEM Stopp seit 1.7.56): Ausgabe abhängen UND Stream stoppen ließ
    /// replayd die Datei zweimal abschließen (exportAndInvalidate 2× in 1 ms) – der zweite Aufruf brach replayd ab. War der
    /// erste schon fertig, blieb das Video heil, sonst fehlte der Index. Darum: läuft die Aufnahme (startCapture kam
    /// zurück), NUR stopCapture – so lief es bis 1.7.55 wochenlang. Ausgabe abhängen nur beim Fehlstart (startCapture
    /// warf, die Ausgabe hing aber schon dran – sonst schreibt replayd weiter, 18.10.: 18 GB).
    enum TeardownStep: Equatable { case detachOutput, stopCapture }
    static func teardownSteps(captureStarted: Bool, hasOutput: Bool) -> [TeardownStep] {
        captureStarted || !hasOutput ? [.stopCapture] : [.detachOutput, .stopCapture]
    }

    /// Ein Weg für jedes Ende; danach prüft `watchFile`, ob die Datei trotzdem weiterwächst (replayd-Geist).
    @MainActor static func tearDown(_ st: SCStream?, _ out: SCRecordingOutput?, captureStarted: Bool, why: String) async {
        guard let st else { return }
        for step in teardownSteps(captureStarted: captureStarted, hasOutput: out != nil) {
            switch step {
            case .detachOutput:
                if let out { do { try st.removeRecordingOutput(out) } catch { log("Bildschirmaufnahme: Ausgabe abhängen (\(why)) – \(error.localizedDescription)") } }
            case .stopCapture:
                do { try await st.stopCapture() } catch { log("Bildschirmaufnahme: Stopp (\(why)) – \(error.localizedDescription)") }
            }
        }
        setLive(nil, if: st)
    }

    /// Laufende Aufnahme blockierend stoppen (Ruhezustand): höchstens `timeout` auf macOS warten – nur stopCapture (s. o.)
    @discardableResult
    static func stopNow(_ st: SCStream, timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        st.stopCapture { _ in sem.signal() }
        let ok = sem.wait(timeout: .now() + timeout) == .success
        setLive(nil, if: st)
        return ok
    }

    /// Je Datei zählt nur die letzte Prüfung (Abbruch + aufwachender Start-Task prüfen dieselbe Datei)
    private static var watchTokens: [String: Int] = [:]

    /// Nach jedem Ende: Datei nach ~2 s und ~5 s messen. keep = fertige Aufnahme → nie löschen, nur warnen, wenn sie
    /// weiterwächst. Sonst (angefangene Datei eines Fehlstarts/Abbruchs): steht sie still → Papierkorb, wächst sie → Warnung.
    static func watchFile(_ url: URL, keep: Bool) {
        let key = url.path
        let tok = (watchTokens[key] ?? 0) + 1
        watchTokens[key] = tok
        ScreenRecGuard.sampleGrowth(url) { g, a, b in
            guard watchTokens[key] == tok else { return }
            watchTokens[key] = nil
            switch ScreenRecGuard.action(g, keep: keep) {
            case .none: break
            case .trash:
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                log("Bildschirmaufnahme: angefangene Datei in den Papierkorb (\(max(b, 0)) B)")
            case .warn:
                log("Bildschirmaufnahme: ACHTUNG – \(url.lastPathComponent) wächst \(keep ? "nach dem Stopp" : "nach Fehlstart") weiter (\(a) → \(b) B), replayd schreibt")
                showGhost(url, keep: keep, size: b)
            }
        }
    }

    /// Warnung „läuft weiter“ – nur, wenn die Datei nachweislich wächst (sonst kommt die Karte gar nicht)
    private static func showGhost(_ url: URL, keep: Bool, size: Int) {
        let what = keep ? "macOS schreibt nach dem Stopp weiter in „\(url.lastPathComponent)“"
                        : "macOS nimmt nach einem Fehlstart im Hintergrund weiter auf"
        VFNotify.shared.show(id: "aufnahme_geist", title: "Aufnahme läuft im Hintergrund weiter",
                             text: "\(what) (schon \(ScreenRecGuard.gb(Int64(size))), wächst). Stoppen beendet den macOS-Aufnahmedienst – "
                                + "auch andere laufende Bildschirmaufnahmen (z. B. QuickTime, Meeting-Kontext) brechen dann ab.",
                             illustration: "illu_bildschirm_aufnahme",
                             primary: ("Stoppen", { killReplaydIfGrowing(url, keep: keep) }), secondary: ("Später", {}), timeout: nil)
    }

    /// „Stoppen“: erst noch einmal messen. `killall -9 replayd` trifft ALLE Bildschirmaufnahmen des Macs – darum nur,
    /// wenn die Datei JETZT noch wächst.
    private static func killReplaydIfGrowing(_ url: URL, keep: Bool) {
        ScreenRecGuard.sampleGrowth(url, after: 0, gap: 1.5) { g, a, b in
            guard ScreenRecGuard.mayKillReplayd(g) else {
                log("Bildschirmaufnahme: Stoppen gedrückt, Datei wächst nicht mehr (\(a) → \(b) B) – replayd NICHT beendet")
                ScreenRec.shared.pill?.view.showToast("Aufnahme hat inzwischen aufgehört – nichts beendet", seconds: 3)
                if !keep { watchFile(url, keep: false) }
                return
            }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["-9", "replayd"]; try? p.run()
            log("Bildschirmaufnahme: replayd beendet (Datei wuchs weiter: \(a) → \(b) B)")
            if !keep { watchFile(url, keep: false) }   // steht sie danach still → Papierkorb
        }
    }

    // MARK: Beenden der App

    /// Laufender Stream, thread-sicher – für das Beenden (Quit, Update, SIGTERM). Ohne das endete die App mitten in
    /// der Aufnahme: MP4 nie abgeschlossen (Video verloren) und replayd schrieb womöglich weiter (18.10.: 18-GB-Geist).
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live: SCStream?
    static var hasLive: Bool { liveLock.lock(); defer { liveLock.unlock() }; return live != nil }

    static func setLive(_ s: SCStream?, if current: SCStream? = nil) {
        liveLock.lock(); defer { liveLock.unlock() }
        if s == nil, let current, live !== current { return }   // ein neuerer Stream bleibt stehen
        live = s
    }

    /// Von jedem Thread: laufenden Stream stoppen (replayd schließt die Datei ab), höchstens `timeout` warten.
    static func finishForQuit(timeout: TimeInterval = 1.2) {
        liveLock.lock(); let st = live; live = nil; liveLock.unlock()
        guard let st else { return }
        let sem = DispatchSemaphore(value: 0)
        st.stopCapture { _ in sem.signal() }
        let ok = sem.wait(timeout: .now() + timeout) == .success
        log("Bildschirmaufnahme beim Beenden gestoppt\(ok ? "" : " (ohne Rückmeldung)")")
    }

    /// Wo die Pille auf diesem Bildschirm steht (gespeicherte Position) – falls die echte Pille nicht greifbar ist
    static func pillGuess(_ s: NSScreen) -> NSRect {
        let pl = Settings.shared.placement(for: s)
        let c = pl.center(in: s.visibleFrame)
        let size = pl.isSide ? NSSize(width: 26, height: 118) : NSSize(width: 118, height: 26)
        return NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
    }

    // SCRecordingOutputDelegate – 18.10.2026: nur Rückrufe der AKTUELLEN Ausgabe zählen; eine alte (überholter
    // Start, vorige Aufnahme) beendete sonst die nächste vorzeitig
    func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard ScreenRecGuard.accept(.finish, from: r, current: self.output, phase: self.phase) else {
                if !ScreenRecGuard.isCurrent(r, self.output) { log("Bildschirmaufnahme: Fertig-Meldung einer alten Ausgabe – ignoriert") }
                return
            }
            self.finished()
        }
    }
    func recordingOutput(_ r: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard ScreenRecGuard.accept(.fileError, from: r, current: self.output, phase: self.phase) else {
                log("Bildschirmaufnahme: Datei-Fehler einer alten Ausgabe – ignoriert (\(error.localizedDescription))"); return
            }
            log("Bildschirmaufnahme: Datei-Fehler – \(error.localizedDescription)")
            switch self.phase {
            case .starting: self.abortStart("Datei-Fehler", toast: "Aufnahme ging nicht: \(error.localizedDescription.prefix(50))")
            case .recording: self.stop(reason: "Gestoppt: macOS konnte die Datei nicht weiterschreiben.")
            case .finishing: self.finished()   // Abspiel-Prüfung entscheidet, ob die Datei taugt
            default: break
            }
        }
    }
    // SCStreamDelegate: z. B. Bildschirm abgesteckt, Freigabe entzogen. Gleicher Abbau wie beim Stopp (Ausgabe
    // abhängen, Stream stoppen, Datei prüfen) – vorher blieb die Ausgabe hängen und niemand sah nach, ob sie weiterwächst.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard ScreenRecGuard.accept(.streamStop, from: stream, current: self.stream, phase: self.phase) else {
                if !ScreenRecGuard.isCurrent(stream, self.stream) { log("Bildschirmaufnahme: Stopp-Meldung eines alten Streams – ignoriert") }
                return
            }
            log("Bildschirmaufnahme: von macOS beendet – \(error.localizedDescription)")
            if self.phase == .starting {
                self.abortStart("von macOS beendet", toast: "Aufnahme ging nicht: \(error.localizedDescription.prefix(50))")
            } else {
                self.stop(reason: "Von macOS beendet (\(error.localizedDescription.prefix(60))).")
            }
        }
    }

    // MARK: 4. Fertig: Kopieren · Nochmal

    private func finished() {
        let url = fileURL, sound = self.sound, screen = target
        let d = done
        reset()
        guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
            if let url { Self.watchFile(url, keep: true) }   // leer, aber schreibt macOS doch noch? → warnen
            VFNotify.shared.dismiss(id: Self.doneID)
            pill?.view.showToast("Aufnahme leer – nichts gespeichert", seconds: 3); return
        }
        log("Bildschirmaufnahme fertig: \(url.lastPathComponent), \(Int(d?.duration ?? 0)) s, \(size / 1_000_000) MB")
        let done = d ?? ScreenRecDone(url: url, duration: 0, screen: Self.name(screen), sound: sound)
        if d == nil { done.onChange = { [weak self, weak done] in if let done { self?.showDone(done) } }; self.done = done }
        // wächst die fertige Datei weiter (replayd-Geist)? → warnen, nie löschen
        Self.watchFile(url, keep: true)
        Task { @MainActor in
            // 18.10.2026: erst prüfen, ob das MP4 abspielbar ist (Spuren + Dauer, abseits des Main-Threads) – sonst
            // hieß es „Aufnahme fertig“ und „Kopieren“ legte eine kaputte Datei in die Zwischenablage.
            // Bis zu 3 Versuche (0 / 2 / 4 s): kam die Fertig-Meldung nicht, schreibt macOS evtl. noch den Abschluss.
            var ok = false
            for wait in [0.0, 2, 2] {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                if await ScreenRecGuard.playable(url) { ok = true; break }
            }
            guard ok else {
                log("Bildschirmaufnahme: \(url.lastPathComponent) lässt sich nicht abspielen (\(size / 1_000_000) MB) – kein Kopieren angeboten")
                done.markBroken()
                return
            }
            done.fileReady()
            done.buildContext()
            done.thumbnail = await Self.thumbnail(of: url)
            done.changed()
        }
    }

    /// Karte „Aufnahme fertig“ zeigen bzw. aktualisieren – aber nie wieder öffnen, wenn sie schon zu ist
    private func showDone(_ d: ScreenRecDone) {
        guard d.cardOpen else { return }
        if d.shownOnce && VFNotify.shared.currentID != Self.doneID { return }
        d.shownOnce = true
        let n = Self.doneNotice(d,
            copy: { [weak d] in d?.copyRequested(VFNotify.shared.chosen.flatMap(ScreenRecCopy.init(rawValue:)) ?? .withContext) },
            again: { [weak self, weak d] in
                d?.cardOpen = false
                guard let self, self.phase == .idle, let d else { return }
                self.target = NSScreen.screens.first { ScreenRec.name($0) == d.screen } ?? Self.screenUnderMouse()
                self.phase = .arming
                self.begin(sound: d.sound, glow: self.glow)
            },
            closed: { [weak d] in d?.cardOpen = false })
        VFNotify.shared.show(n)
    }

    static func doneNotice(_ d: ScreenRecDone, copy: @escaping () -> Void, again: @escaping () -> Void, closed: @escaping () -> Void = {}) -> VFNotice {
        let sec = max(1, Int(d.duration.rounded()))
        let why = d.stopReason.map { "\($0) " } ?? ""
        // 18.10.2026: Datei nicht abspielbar → sagen, statt eine kaputte Datei zum Kopieren anzubieten
        if d.broken {
            var n = VFNotice(id: doneID, title: "Aufnahme beschädigt · \(sec / 60):\(String(format: "%02d", sec % 60))",
                             text: "\(why)\(d.screen), \(d.sound.short). Die Datei lässt sich nicht abspielen – darum kein Kopieren. Sie liegt unverändert im Ordner.",
                             illustration: "illu_aufnahme_fertig", fallbackSymbol: "exclamationmark.triangle.fill")
            let u = d.url
            n.primary = ("Im Finder zeigen", { NSWorkspace.shared.activateFileViewerSelecting([u]) })
            n.secondary = ("Nochmal", again)
            n.timeout = nil
            n.onClose = closed
            n.thumbnailCaption = u.lastPathComponent
            return n
        }
        let state: String
        if !d.ready { state = "Wird gespeichert …" }
        else if d.context == nil { state = d.sound.transcribes ? "Transkript und Bilder werden erstellt …" : "Schlüsselbilder werden erstellt …" }
        else {
            let n = d.keyframes.count, sp = d.trails.count
            let ck = d.clickInfos.count, mk = d.marks.count
            state = (d.sound.transcribes ? (d.saidSomething ? "Transkript + " : "Nichts gesprochen · ") : "") + "\(n) Bild\(n == 1 ? "" : "er")"
                + (ck > 0 ? " + \(ck) Klick\(ck == 1 ? "" : "s")" : "") + (mk > 0 ? " + \(mk) Markierung\(mk == 1 ? "" : "en")" : "")
                + (sp > 0 ? " + \(sp) Mausspur\(sp == 1 ? "" : "en")" : "") + " für den Agent."
        }
        var n = VFNotice(id: doneID, title: "Aufnahme fertig · \(sec / 60):\(String(format: "%02d", sec % 60))",
                         text: "\(why)\(d.screen), \(d.sound.short). \(state)",
                         illustration: "illu_aufnahme_fertig", fallbackSymbol: "play.rectangle.fill")
        n.primary = ("Kopieren", copy)
        n.secondary = ("Nochmal", again)
        // automatisch gestoppt (Speicher, Ruhezustand, Sperre): Karte bleibt, bis man zurück ist
        n.timeout = d.stopReason == nil ? 45 : nil
        n.onClose = closed
        n.choices = ScreenRecCopy.allCases.map { ScreenRecCopy.label($0, sound: d.sound) }
        n.preselect = 1   // für den Agent: Kontext ist meist gewollt
        if let t = d.thumbnail { n.thumbnails = [t] }
        n.thumbnailCaption = d.url.lastPathComponent
        return n
    }

    /// Echte Datei + Pfad als Text (wie ClipVault): ⌘V fügt das Video in Chats/Mail/Finder ein, im Terminal den Pfad.
    /// Mit Transkript: der Text-Teil enthält zusätzlich, was im Video gesagt wurde (mit Zeitmarken) – für Agents.
    @discardableResult
    func copy(_ url: URL, context: String? = nil, isTask: Bool = false, quiet: Bool = false) -> Int {
        let it = NSPasteboardItem()
        it.setString(url.absoluteString, forType: .fileURL)
        var text = Self.shellEscape(url.path)
        let transcript = context
        if let t = context, !t.isEmpty { text += "\n\n" + t }
        it.setString(text, forType: .string)
        let pb = NSPasteboard.general
        pb.clearContents(); pb.writeObjects([it])
        let cc = pb.changeCount
        if quiet { log("Bildschirmaufnahme kopiert (Video sofort, Kontext folgt): \(url.lastPathComponent)"); return cc }
        pill?.view.showToast(isTask ? "Auftrag kopiert – ⌘V beim Agent" : (transcript?.isEmpty == false ? "Video + Kontext kopiert – ⌘V" : "Video kopiert – ⌘V zum Einfügen"), seconds: 2.4)
        log("Bildschirmaufnahme kopiert: \(url.lastPathComponent)\(transcript?.isEmpty == false ? " + Kontext" : "")")
        return cc
    }

    /// Auftrag fertig, aber die Zwischenablage ist inzwischen anders belegt: nicht überschreiben, sondern Karte anbieten
    func copyLater(_ url: URL, task: String) {
        var n = VFNotice(id: "screenrec.task", title: "Auftrag ist fertig",
                         text: "Du hast inzwischen etwas anderes kopiert – deshalb liegt der Auftrag noch nicht in der Zwischenablage.",
                         illustration: "illu_aufnahme_fertig", fallbackSymbol: "sparkles")
        n.primary = ("Auftrag kopieren", { [weak self] in self?.copy(url, context: task, isTask: true) })
        n.timeout = 30
        VFNotify.shared.show(n)
        log("Bildschirmaufnahme: Auftrag fertig, Zwischenablage belegt – Karte angeboten")
    }

    // MARK: Hilfen

    /// Pfad für Terminal/Claude Code (Leerzeichen & Sonderzeichen mit \)
    static func shellEscape(_ p: String) -> String {
        let special = Set(" \t!\"#$&'()*,;<>?[\\]^`{|}~=%")
        return p.reduce(into: "") { o, ch in if special.contains(ch) { o.append("\\") }; o.append(ch) }
    }

    private func reset() {
        armTimer?.invalidate(); armTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
        guardTimer?.invalidate(); guardTimer = nil
        frame?.hide(); frame = nil
        glowView?.stop(); glowView = nil
        trackers.removeAll()
        inkView?.stop(); inkView = nil
        stream = nil; output = nil; filter = nil; display = nil
        phase = .idle
        if let v = pill?.view {
            switch v.mode { case .screenRec, .screenRecCountdown: v.mode = fallbackMode(); default: break }
        }
    }

    private func setPill(_ m: PillView.Mode) { pill?.view.mode = m }

    private func askPermission() {
        CGRequestScreenCaptureAccess()
        VFNotify.shared.show(id: "aufnahme_freigabe", title: "Freigabe für Bildschirmaufnahme fehlt",
                             text: "Systemeinstellungen → Datenschutz → Bildschirm- & Systemaudioaufnahme → Flow einschalten, dann ⌃⌥R.",
                             illustration: "illu_bildschirm_aufnahme",
                             primary: ("Einstellungen öffnen", {
                                 NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                             }), secondary: ("Später", {}), timeout: 20)
    }

    static func screenUnderMouse() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
    }

    static func displayID(_ s: NSScreen?) -> CGDirectDisplayID {
        (s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func name(_ s: NSScreen?) -> String {
        guard let s else { return "Bildschirm" }
        let n = s.localizedName
        if n.localizedCaseInsensitiveContains("retina") || n.localizedCaseInsensitiveContains("integriert") || n.localizedCaseInsensitiveContains("built-in") {
            return "MacBook-Bildschirm"
        }
        return n
    }

    static func sizeLabel(_ s: NSScreen?) -> String {
        guard let s else { return "" }
        return " (\(Int(s.frame.width)) × \(Int(s.frame.height)))"
    }

    /// Zielordner: Ablageort der macOS-Bildschirmfotos (falls eingestellt und vorhanden) → Schreibtisch
    static func folder() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var dir: ObjCBool = false
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let u = URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
            if fm.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue { return u }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func fileName(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return "Bildschirmaufnahme \(f.string(from: d)).mp4"
    }

    static func newFileURL() -> URL {
        let dir = folder()
        var u = dir.appendingPathComponent(fileName())
        var i = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(fileName().replacingOccurrences(of: ".mp4", with: " (\(i)).mp4")); i += 1
        }
        return u
    }

    /// Vorschaubild (erstes Drittel des Videos) als JPEG im Cache
    static func thumbnail(of url: URL) async -> URL? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let dur = (try? await AVURLAsset(url: url).load(.duration)) ?? .zero
        let at = CMTime(seconds: max(0.1, dur.seconds / 3), preferredTimescale: 600)
        guard let (img, _) = try? await gen.image(at: at) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-aufnahme", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg")
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        try? data.write(to: out)
        return out
    }
}

// MARK: - Fertige Aufnahme: Karte sofort, Datei/Vorschau/Transkript kommen nach

final class ScreenRecDone {
    let url: URL
    let duration: TimeInterval
    var screen: String
    let sound: ScreenRecSound
    var clicks: [TimeInterval] = []
    var clickInfos: [ScreenRecClickInfo] = []
    /// Markierungen mit dem Zeichenstift: [Start, Ende] in Sekunden
    var marks: [[Double]] = []
    /// Rahmen jeder Markierung (Bildschirm-Punkte, global) – gleiche Reihenfolge wie `marks`
    var markBoxes: [NSRect] = []
    private var task: String?
    private var taskRunning = false
    var mouse: [ScreenRecMouse] = []
    var screenFrame: NSRect = .zero
    var switches: [ScreenRecSwitch] = []
    private(set) var trails: [ScreenRecTrail] = []
    private(set) var ready = false
    /// 18.10.2026: Datei ließ sich nicht abspielen → Karte sagt es, Kopieren gibt es nicht
    private(set) var broken = false
    /// automatisch gestoppt (Speicher fast voll, Ruhezustand, Sperre, macOS) – erster Satz der Karte
    var stopReason: String?
    var thumbnail: URL?
    /// fertiger Kontext-Text für Agents (Transkript + Bilder); nil = wird noch erstellt
    private(set) var context: String?
    private(set) var keyframes: [ScreenRecKeyframe] = []
    private(set) var saidSomething = false
    var cardOpen = true
    var shownOnce = false
    var onChange: () -> Void = {}
    private var pendingCopy: ScreenRecCopy?
    /// 15.10.2026 (Wunsch: „auf Kopieren gedrückt – kam nichts in die Zwischenablage“): Video liegt sofort drin; der Auftrag
    /// ersetzt es nur, solange seitdem nichts anderes kopiert wurde (changeCount unverändert).
    private var earlyCopy: Int?
    /// „Mit Kontext“, Kontext noch nicht fertig: Video sofort, Text als Versprechen (ScreenRecClip, 19.10.2026)
    private var clip: ScreenRecClip?

    init(url: URL, duration: TimeInterval, screen: String, sound: ScreenRecSound) {
        self.url = url; self.duration = duration; self.screen = screen; self.sound = sound
    }

    func changed() { onChange(); tryCopy() }
    func fileReady() { ready = true; changed() }

    /// Abspiel-Prüfung fehlgeschlagen: wartendes Kopieren verwerfen (nie eine kaputte Datei in die Zwischenablage)
    func markBroken() {
        broken = true
        ScreenRecClip.finish(url, context: nil)   // wartendes Einfügen nicht hängen lassen
        let waited = pendingCopy
        pendingCopy = nil
        if waited == .task { APCard.shared.endJob() }
        if waited != nil || !cardOpen {
            ScreenRec.shared.pill?.view.showToast("Aufnahme lässt sich nicht abspielen – nichts kopiert", seconds: 4)
        }
        onChange()
    }

    /// „Kopieren“ gedrückt – sofort, oder sobald Datei (und ggf. Kontext) fertig sind
    func copyRequested(_ mode: ScreenRecCopy) {
        guard !broken else {
            ScreenRec.shared.pill?.view.showToast("Aufnahme lässt sich nicht abspielen – nichts kopiert", seconds: 3); return
        }
        cardOpen = false
        pendingCopy = mode
        if mode == .task {
            showTaskCard()
        } else if !ready {
            ScreenRec.shared.pill?.view.showToast("Video wird noch gespeichert – kopiere gleich …", seconds: 2.5)
        }
        if ready && mode == .task { earlyCopy = ScreenRec.shared.copy(url, quiet: true) }
        if ready && mode == .withContext && context == nil { promiseCopy() }
        tryCopy()
    }

    /// Video sofort in die Zwischenablage, der Text (Pfad + Kontext) als Versprechen: ⌘V wartet notfalls auf den Kontext
    private func promiseCopy() {
        let c = ScreenRecClip(url: url)
        c.onWait = { ScreenRec.shared.pill?.view.showToast("Moment – Transkript kommt mit …", seconds: 2.5) }
        c.write()
        clip = c
        ScreenRec.shared.pill?.view.showToast("Kopiert – ⌘V fügt Video + Kontext ein", seconds: 2.5)
        log("Bildschirmaufnahme kopiert (Video sofort, Kontext als Versprechen): \(url.lastPathComponent)")
    }

    private func tryCopy() {
        guard let m = pendingCopy, ready else { return }
        if m == .withContext && context == nil && clip == nil { promiseCopy() }   // Datei wurde gerade fertig
        if m == .task && earlyCopy == nil { earlyCopy = ScreenRec.shared.copy(url, quiet: true) }
        if (m == .withContext || m == .task) && context == nil { return }
        if m == .withContext, let c = clip {
            pendingCopy = nil
            // Wird gerade eingefügt: das Versprechen liefert gleich Pfad + Kontext – jetzt nichts drüberschreiben
            if c.isProviding { return }
            if c.pasteboard.changeCount == c.changeCount {
                // noch unsere Zwischenablage: Kontext fest hineinlegen (hält auch, wenn Flow vor dem Einfügen beendet wird)
                ScreenRec.shared.copy(url, context: context)
            } else {
                log("Bildschirmaufnahme: Kontext fertig, Zwischenablage inzwischen anders belegt" + (c.delivered ? " (vorher mit Kontext eingefügt)" : ""))
            }
            return
        }
        if m == .task {
            guard let t = task else {
                if !taskRunning, let ctx = context {
                    taskRunning = true
                    let url = self.url
                    Task { @MainActor in
                        let t0 = Date()
                        self.task = await ScreenRecTask.build(video: url, context: ctx)
                        let secs = Date().timeIntervalSince(t0)
                        log("Bildschirmaufnahme: Auftrag gebaut in \(String(format: "%.1f", secs)) s")
                        ScreenRecDone.learnTaskSeconds(secs)
                        self.taskRunning = false
                        self.tryCopy()
                    }
                }
                return
            }
            pendingCopy = nil
            APCard.shared.endJob()
            if let cc = earlyCopy, NSPasteboard.general.changeCount != cc {
                // inzwischen etwas anderes kopiert/diktiert: Auftrag nicht drüberlegen, aber anbieten
                ScreenRec.shared.copyLater(url, task: t)
                return
            }
            ScreenRec.shared.copy(url, context: t, isTask: true)
            return
        }
        pendingCopy = nil
        ScreenRec.shared.copy(url, context: m == .withContext ? context : nil)
    }

    // MARK: „Als Auftrag“: Karte wie beim Agent-Prompt, mit Restzeit

    private var taskStarted = Date()

    /// geschätzte Dauer Klick → Auftrag fertig: Kontext (falls noch nicht da) + gelernte KI-Dauer
    private func taskExpected() -> Double {
        let ctx = context == nil ? max(2, duration / 40) : 0
        return ctx + Self.taskSeconds()
    }

    static func taskSeconds() -> Double {
        let v = UserDefaults.standard.double(forKey: "screenRecTaskSecs")
        return v > 3 ? v : 20
    }
    static func learnTaskSeconds(_ s: Double) {
        guard s > 1, s < 120 else { return }
        let old = UserDefaults.standard.double(forKey: "screenRecTaskSecs")
        UserDefaults.standard.set(old > 3 ? old * 0.6 + s * 0.4 : s, forKey: "screenRecTaskSecs")
    }

    private func showTaskCard() {
        taskStarted = Date()
        let job = APCardJob(chip: "Auftrag", title: "Auftrag wird mit KI gebaut …",
                            line: "Claude liest Video, Bilder\(sound.transcribes ? ", Transkript" : "") und Mausspuren und schreibt den Auftrag.",
                            expected: taskExpected(), note: "Video liegt schon in der Zwischenablage")
        let shown = APCard.shared.showJob(job, started: taskStarted) { [weak self] a in
            guard let self, a == .cancel || a == .close else { return }
            guard self.pendingCopy == .task else { return }
            self.pendingCopy = nil
            log("Bildschirmaufnahme: Auftrag abgebrochen")
            ScreenRec.shared.pill?.view.showToast("Auftrag abgebrochen – Video liegt in der Zwischenablage", seconds: 2.5)
        }
        if !shown { ScreenRec.shared.pill?.view.showToast("Auftrag für den Agent wird gebaut … (~\(Int(job.expected)) s)", seconds: 3) }
    }

    /// Transkript (nur Mikrofon) + Schlüsselbilder → ein Text für Agents
    func buildContext() {
        let url = self.url, dur = self.duration, clicks = self.clicks, sound = self.sound, screen = self.screen
        let mouse = self.mouse, infos = self.clickInfos, marks = self.marks, boxes = self.markBoxes
        let sw = switches.isEmpty ? [ScreenRecSwitch(t: 0, frame: screenFrame, name: screen)] : switches
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let segs = sound.transcribes ? (await ScreenRecTranscript.segments(url) ?? []) : []
            let markEnds = marks.compactMap { $0.last }
            let times = ScreenRecKeyframes.times(duration: dur, clicks: clicks, speech: segs.map(\.start), marks: markEnds)
            let frames = await ScreenRecKeyframes.extract(url, at: times, clicks: clicks, marks: markEnds)
            let trails = await ScreenRecTrails.render(url, mouse: mouse, screens: sw)
            let crops = await ScreenRecMarks.crops(url, marks: marks, boxes: boxes, switches: sw)
            let text = ScreenRecKeyframes.compose(duration: dur, screen: screen, sound: sound, segments: segs, frames: frames, trails: trails,
                                                  clicks: infos, marks: marks, switches: sw, markCrops: crops)
            ScreenRecClip.finish(url, context: text)   // wartendes ⌘V sofort beliefern – ohne Umweg über den Hauptfaden
            ScreenRecClip.saveContext(url, text)       // … und für späteres Kopieren aus ClipVault neben die Bilder
            await MainActor.run {
                self.trails = trails
                self.keyframes = frames
                self.saidSomething = !segs.isEmpty
                self.context = text
                log("Bildschirmaufnahme: Kontext \(segs.count) Sätze, \(frames.count) Bilder, \(trails.count) Mausspuren in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                self.changed()
            }
        }
    }
}

/// Was im Video (Mikrofon) gesagt wird → Sätze mit Startzeit, lokal mit Parakeet
enum ScreenRecTranscript {
    static let chunkSeconds = 30.0
    struct Segment: Equatable { let start: Double; let text: String }

    static func segments(_ url: URL) async -> [Segment]? {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("flow-aufnahme-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        do { _ = try AudioDecoder.decode(url, to: raw) } catch { log("Bildschirmaufnahme: Ton für Transkript nicht lesbar – \(error.localizedDescription)"); return nil }
        guard let data = try? Data(contentsOf: raw), data.count > 3200 else { return [] }
        let samples: [Float] = data.withUnsafeBytes { b in b.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        return await segments(samples)
    }

    typealias Words = [(word: String, start: Double, end: Double)]

    /// 30-s-Stücke erkennen, Wörter zu Sätzen bündeln (Satzzeichen, Pause > 1,2 s oder > 28 Wörter)
    static func segments(_ samples: [Float], recognize: (([Float]) async throws -> Words)? = nil) async -> [Segment] {
        let step = Int(chunkSeconds * 16000)
        var out: [Segment] = []
        var i = 0
        while i < samples.count {
            let piece = Array(samples[i..<min(samples.count, i + step)])
            let words: Words
            if let recognize { words = (try? await recognize(piece)) ?? [] }
            else { words = (try? await Transcriber.shared.transcribe(piece).words) ?? [] }
            out += sentences(words, offset: Double(i) / 16000)
            i += step
        }
        return out
    }

    static func sentences(_ words: Words, offset: Double) -> [Segment] {
        var out: [Segment] = []
        var cur: [String] = [], start = 0.0, lastEnd = -1.0
        func flush() {
            let t = cur.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(Segment(start: offset + start, text: t)) }
            cur = []
        }
        for w in words {
            if !cur.isEmpty && (w.start - lastEnd > 1.2 || cur.count >= 28) { flush() }
            if cur.isEmpty { start = w.start }
            cur.append(w.word); lastEnd = w.end
            if let c = w.word.last, ".?!".contains(c) { flush() }
        }
        flush()
        return out
    }
}

/// Schlüsselbild aus der Aufnahme (für Agents: Bild + Zeit + warum)
struct ScreenRecKeyframe: Equatable {
    let time: Double
    let url: URL
    let click: Bool
    var mark = false
}

enum ScreenRecKeyframes {
    static let maxFrames = 14
    static let minGap = 3.0

    static func stamp(_ t: Double) -> String {
        let s = max(0, Int(t)); return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// Zeitpunkte: kurz nach jedem Klick (Ergebnis sichtbar), Anfang jedes Satzes, Anfang und Ende; dicht beieinander
    /// liegende fallen zusammen (Klick gewinnt), höchstens maxFrames (gleichmäßig ausgedünnt)
    static func times(duration: Double, clicks: [Double], speech: [Double], marks: [Double] = []) -> [Double] {
        guard duration > 0.3 else { return [] }
        let end = max(0.2, duration - 0.3)
        var cands: [(t: Double, prio: Int)] = [(min(0.5, end), 1), (end, 1)]
        cands += clicks.map { (min(end, $0 + 0.35), 3) }
        cands += speech.map { (min(end, $0 + 0.2), 2) }
        cands += marks.map { (min(end, $0 + 0.1), 4) }   // Markierung: kurz nach dem Loslassen, Linie noch voll sichtbar
        cands.sort { $0.t < $1.t }
        var picked: [(t: Double, prio: Int)] = []
        for c in cands {
            if let last = picked.last, c.t - last.t < minGap {
                if c.prio > last.prio { picked[picked.count - 1] = c }
            } else { picked.append(c) }
        }
        var ts = picked.map(\.t)
        if ts.count > maxFrames {
            ts = (0..<maxFrames).map { k in ts[Int((Double(k) * Double(ts.count - 1) / Double(maxFrames - 1)).rounded())] }
        }
        return ts
    }

    /// Ordner neben dem Video: „<Video> – Bilder/0m12s.jpg“, lange Seite 1600 px (lesbar, nicht riesig)
    static func extract(_ url: URL, at times: [Double], clicks: [Double], marks: [Double] = []) async -> [ScreenRecKeyframe] {
        guard !times.isEmpty else { return [] }
        let folder = URL(fileURLWithPath: url.deletingPathExtension().path + " – Bilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        var out: [ScreenRecKeyframe] = []
        for t in times {
            guard let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            let s = Int(t)
            let f = folder.appendingPathComponent("\(s / 60)m\(String(format: "%02d", s % 60))s.jpg")
            guard let data = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
                  (try? data.write(to: f)) != nil else { continue }
            out.append(ScreenRecKeyframe(time: t, url: f, click: clicks.contains { abs(($0 + 0.35) - t) < 0.4 },
                                         mark: marks.contains { abs(($0 + 0.1) - t) < 0.3 }))
        }
        return out
    }

    /// Text für den Agent: Sätze und Bilder in zeitlicher Reihenfolge
    static func compose(duration: Double, screen: String, sound: ScreenRecSound, segments: [ScreenRecTranscript.Segment],
                        frames: [ScreenRecKeyframe], trails: [ScreenRecTrail] = [],
                        clicks: [ScreenRecClickInfo] = [], marks: [[Double]] = [], switches: [ScreenRecSwitch] = [],
                        markCrops: [Int: URL] = [:]) -> String {
        var rows: [(t: Double, order: Int, line: String)] = []
        for w in switches.dropFirst() { rows.append((w.t, 0, "[\(stamp(w.t))] Video wechselt auf: \(w.name)")) }
        for c in clicks { rows.append((c.t, 1, "[\(stamp(c.t))] \(c.text)")) }
        // Markierung: Ausschnitt des markierten Bereichs + was dabei gesagt wurde (18.10.2026, Wunsch: „1 und 4“)
        for (i, m) in marks.enumerated() where m.count == 2 {
            var line = "[\(stamp(m[0]))–\(stamp(m[1]))] Rot eingezeichnet (Markierung)"
            if let c = markCrops[i] { line += " – Ausschnitt: \(c.path)" }
            if let said = ScreenRecMarks.said(segments, start: m[0], end: m[1]) { line += "\n    dazu gesagt: „\(said)“" }
            rows.append((m[0], 1, line))
        }
        for tr in trails { rows.append((tr.start, 3, "[\(stamp(tr.start))–\(stamp(tr.end))] Mausspur (grün = Anfang, rot = Ende): \(tr.url.path)")) }
        for s in segments { rows.append((s.start, 0, "[\(stamp(s.start))] \(s.text)")) }
        for f in frames { rows.append((f.time, 2, "[\(stamp(f.time))] Bild\(f.mark ? " (mit Markierung)" : f.click ? " (nach Klick)" : ""): \(f.url.path)")) }
        rows.sort { $0.t != $1.t ? $0.t < $1.t : $0.order < $1.order }
        let what = sound == .mic ? "was ich sage und was dabei zu sehen ist"
            : sound == .system ? "was zu hören (Systemton) und zu sehen ist" : "was dabei zu sehen ist"
        var head = "Bildschirmaufnahme (\(stamp(duration)), \(screen)) – \(what):"
        if sound.transcribes && segments.isEmpty { head += "\n(kein gesprochener Text erkannt)" }
        return ([head] + rows.map(\.line)).joined(separator: "\n")
    }
}

// MARK: - Markierung auswerten (18.10.2026): Ausschnitt + was dabei gesagt wurde
//
// Der rote Kreis im Vollbild ist für eine KI klein und leicht zu übersehen. Darum: der markierte Bereich als eigenes,
// scharfes Bild („Markierung 0m13s.jpg“, aus dem vollen Videobild kurz nach dem Loslassen, Linie noch sichtbar) und
// im Kontext direkt darunter die Sätze, die beim Zeichnen gesagt wurden („Genau diesen Bereich“).

enum ScreenRecMarks {
    static let padFactor: CGFloat = 0.25
    static let minPad: CGFloat = 60
    static let minSize = CGSize(width: 480, height: 300)
    static let maxSide: CGFloat = 1600

    /// Rahmen der Linie (Bildschirm-Punkte, Cocoa) → Pixel-Rechteck im Videobild (Ursprung oben links) mit Rand
    static func rect(_ box: NSRect, screen: NSRect, W: CGFloat, H: CGFloat) -> CGRect? {
        guard screen.width > 0, box.width >= 0 else { return nil }
        let a = ScreenRecTrails.map(NSPoint(x: box.minX, y: box.minY), screen: screen, W: W, H: H)
        let b = ScreenRecTrails.map(NSPoint(x: box.maxX, y: box.maxY), screen: screen, W: W, H: H)
        var r = CGRect(x: a.x, y: H - b.y, width: b.x - a.x, height: b.y - a.y)
        let pad = max(minPad, padFactor * max(r.width, r.height))
        r = r.insetBy(dx: -pad, dy: -pad)
        if r.width < minSize.width { r = r.insetBy(dx: -(minSize.width - r.width) / 2, dy: 0) }
        if r.height < minSize.height { r = r.insetBy(dx: 0, dy: -(minSize.height - r.height) / 2) }
        r = r.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        return r.width > 20 && r.height > 20 ? r : nil
    }

    /// Je Markierung ein Ausschnitt-Bild neben den Schlüsselbildern; Schlüssel = Index in `marks`
    static func crops(_ url: URL, marks: [[Double]], boxes: [NSRect], switches sw: [ScreenRecSwitch]) async -> [Int: URL] {
        guard !boxes.isEmpty, !marks.isEmpty else { return [:] }
        let folder = URL(fileURLWithPath: url.deletingPathExtension().path + " – Bilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var out: [Int: URL] = [:]
        for (i, m) in marks.enumerated() where i < boxes.count && m.count == 2 {
            guard let (img, _) = try? await gen.image(at: CMTime(seconds: m[1] + 0.1, preferredTimescale: 600)),
                  let r = rect(boxes[i], screen: ScreenRecTrails.frame(at: m[0], sw), W: CGFloat(img.width), H: CGFloat(img.height)),
                  let cut = img.cropping(to: r), let small = shrink(cut),
                  let data = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.88])
            else { continue }
            let s = Int(m[0])
            var f = folder.appendingPathComponent("Markierung \(s / 60)m\(String(format: "%02d", s % 60))s.jpg")
            if out.values.contains(f) { f = folder.appendingPathComponent("Markierung \(s / 60)m\(String(format: "%02d", s % 60))s-\(i + 1).jpg") }
            if (try? data.write(to: f)) != nil { out[i] = f }
        }
        return out
    }

    /// Lange Seite höchstens 1600 px (Ausschnitt bleibt scharf, Datei klein)
    static func shrink(_ img: CGImage) -> CGImage? {
        let k = min(1, maxSide / CGFloat(max(img.width, img.height)))
        guard k < 1 else { return img }
        let w = Int(CGFloat(img.width) * k), h = Int(CGFloat(img.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Was beim Zeichnen gesagt wurde: Sätze, die bis 3 s vorher oder 2,5 s nachher beginnen oder beim Ansetzen
    /// noch laufen (höchstens 320 Zeichen)
    static func said(_ segs: [ScreenRecTranscript.Segment], start: Double, end: Double) -> String? {
        var hits: [String] = []
        for (k, s) in segs.enumerated() {
            let sEnd = min(s.start + 8, k + 1 < segs.count ? segs[k + 1].start : s.start + 6)
            let begins = s.start >= start - 3 && s.start <= end + 2.5
            let running = s.start < start && sEnd > start
            if begins || running { hits.append(s.text) }
        }
        guard !hits.isEmpty else { return nil }
        let t = hits.joined(separator: " ")
        return t.count > 320 ? String(t.prefix(318)) + "…" : t
    }
}

// MARK: - Mausspur: was du mit der Maus zeigst, einkreist oder schreibst (15.10.2026)
//
// Ein Standbild zeigt nur, wo die Maus gerade IST. Wer mit der Maus etwas einkreist oder ein Wort „schreibt“, braucht
// die Spur – geteilt an den Pausen der Maus (feste Zeitfenster schnitten mitten durch Buchstaben). Flow schreibt die
// Maus während der Aufnahme 30×/s mit, teilt an Pausen ≥ 0,3 s und zeichnet jeden Strich auf das (abgedunkelte) Bild
// des Moments: grün = Anfang, rot = Ende.

struct ScreenRecMouse: Equatable { let t: Double; let x: Double; let y: Double }
struct ScreenRecSwitch: Equatable { let t: Double; let frame: NSRect; let name: String }
struct ScreenRecTrail: Equatable { let start: Double; let end: Double; let url: URL }

enum ScreenRecTrails {
    static let maxTrails = 12
    /// Maus steht, wenn sie sich (geglättet) weniger als so viele Punkte pro Abtastung bewegt
    static let stillPerSample = 0.8
    static let minPause = 0.3
    /// Striche, die kürzer sind (Weg in Punkten), sind kein Zeigen
    static let minPath = 40.0

    /// Spur in Striche teilen: an Pausen (Maus steht ≥ 0,3 s); zu kurze fallen weg; zu viele → benachbarte zusammen
    static func strokes(_ m: [ScreenRecMouse]) -> [Range<Int>] {
        guard m.count > 3 else { return [] }
        var v = [Double](repeating: 0, count: m.count)
        for i in 1..<m.count { v[i] = hypot(m[i].x - m[i - 1].x, m[i].y - m[i - 1].y) }
        var still = [Bool](repeating: false, count: m.count)
        for i in 0..<m.count {
            let a = max(0, i - 2), b = min(m.count - 1, i + 2)
            still[i] = v[a...b].reduce(0, +) / Double(b - a + 1) < stillPerSample
        }
        var out: [Range<Int>] = []
        var i = 0, startMove: Int? = nil
        while i < m.count {
            if still[i] {
                var j = i
                while j < m.count && still[j] { j += 1 }
                let pauseLong = m[min(j, m.count - 1)].t - m[i].t >= minPause || j == m.count
                if pauseLong, let s = startMove { out.append(s..<i); startMove = nil }
                i = j
            } else {
                if startMove == nil { startMove = i }
                i += 1
            }
        }
        if let s = startMove { out.append(s..<m.count) }
        out = out.filter { r in
            var len = 0.0
            for k in r.dropFirst() { len += v[k] }
            return len >= minPath
        }
        while out.count > maxTrails {   // die zwei kürzesten Nachbarn zusammenlegen
            var best = 0, bestLen = Double.infinity
            for k in 0..<(out.count - 1) {
                let l = Double(out[k + 1].upperBound - out[k].lowerBound)
                if l < bestLen { bestLen = l; best = k }
            }
            out[best] = out[best].lowerBound..<out[best + 1].upperBound
            out.remove(at: best + 1)
        }
        return out
    }

    /// Jeder Strich auf dem Video-Bild am Ende des Strichs (abgedunkelt), JPEG neben den Schlüsselbildern
    static func render(_ url: URL, mouse m: [ScreenRecMouse], screen: NSRect) async -> [ScreenRecTrail] {
        await render(url, mouse: m, screens: [ScreenRecSwitch(t: 0, frame: screen, name: "")])
    }

    /// Welcher Bildschirm war zur Zeit t im Video?
    static func frame(at t: Double, _ sw: [ScreenRecSwitch]) -> NSRect {
        sw.last(where: { $0.t <= t })?.frame ?? sw.first?.frame ?? .zero
    }

    /// Bildschirm-Punkt → Videobild (W×H), eingepasst mit erhaltenem Seitenverhältnis (wie preservesAspectRatio)
    static func map(_ p: NSPoint, screen: NSRect, W: CGFloat, H: CGFloat) -> NSPoint {
        let k = min(W / screen.width, H / screen.height)
        let ox = (W - screen.width * k) / 2, oy = (H - screen.height * k) / 2
        return NSPoint(x: ox + (p.x - screen.minX) * k, y: oy + (p.y - screen.minY) * k)
    }

    static func render(_ url: URL, mouse m: [ScreenRecMouse], screens sw: [ScreenRecSwitch]) async -> [ScreenRecTrail] {
        let rs = strokes(m)
        guard !rs.isEmpty, (sw.first?.frame.width ?? 0) > 0 else { return [] }
        let folder = URL(fileURLWithPath: url.deletingPathExtension().path + " – Bilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        var out: [ScreenRecTrail] = []
        for r in rs {
            let a = m[r.lowerBound].t, b = m[r.upperBound - 1].t
            guard let (bg, _) = try? await gen.image(at: CMTime(seconds: b, preferredTimescale: 600)) else { continue }
            let W = CGFloat(bg.width), H = CGFloat(bg.height)
            let screen = frame(at: b, sw)
            let img = NSImage(size: NSSize(width: W, height: H), flipped: false) { rect in
                NSImage(cgImage: bg, size: rect.size).draw(in: rect)
                NSColor.black.withAlphaComponent(0.55).setFill(); rect.fill(using: .sourceAtop)
                // nur der Teil des Strichs, der auf dem Bildschirm lag, der da im Video war
                let pts = m[r].filter { NSMouseInRect(NSPoint(x: $0.x, y: $0.y), screen.insetBy(dx: -2, dy: -2), false) }
                    .map { map(NSPoint(x: $0.x, y: $0.y), screen: screen, W: W, H: H) }
                guard pts.count > 1 else { return true }
                for k in 1..<pts.count {
                    let f = CGFloat(k) / CGFloat(pts.count)
                    NSColor(calibratedRed: 0.25 + 0.75 * f, green: 0.85 - 0.6 * f, blue: 0.35 - 0.15 * f, alpha: 1).setStroke()
                    let p = NSBezierPath(); p.move(to: pts[k - 1]); p.line(to: pts[k])
                    p.lineWidth = max(4, W / 260); p.lineCapStyle = .round; p.stroke()
                }
                if let s = pts.first {
                    NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.35, alpha: 1).setStroke()
                    let c = NSBezierPath(ovalIn: NSRect(x: s.x - 10, y: s.y - 10, width: 20, height: 20)); c.lineWidth = 3; c.stroke()
                }
                return true
            }
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { continue }
            func st(_ t: Double) -> String { let s = Int(t); return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
            let f = folder.appendingPathComponent("Mausspur \(st(a))–\(st(b)).jpg")
            if (try? data.write(to: f)) != nil { out.append(ScreenRecTrail(start: a, end: b, url: f)) }
        }
        return out
    }
}

// MARK: - Leuchten um die Maus (Schalter „Maus leuchtet“) – das einzige Fenster von Flow, das ins Video kommt

final class ScreenRecCursorGlow {
    private var panel: NSPanel?
    private var view: ScreenRecGlowView?
    private var timer: Timer?
    private var monitor: Any?
    static let size: CGFloat = 132

    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func start() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .readOnly
        let v = ScreenRecGlowView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        p.contentView = v
        panel = p; view = v
        follow()
        p.orderFrontRegardless()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.view?.pulse() }
    }

    private func follow() {
        let m = NSEvent.mouseLocation
        panel?.setFrameOrigin(NSPoint(x: m.x - Self.size / 2, y: m.y - Self.size / 2))
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil); panel = nil; view = nil
    }
}

final class ScreenRecGlowView: NSView {
    private let halo = CAGradientLayer()
    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let gold = NSColor(calibratedRed: 1, green: 0.82, blue: 0.25, alpha: 1)
        halo.type = .radial
        halo.colors = [gold.withAlphaComponent(0.55).cgColor, gold.withAlphaComponent(0.22).cgColor, gold.withAlphaComponent(0).cgColor]
        halo.locations = [0, 0.38, 1]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        let c: CGFloat = 52
        halo.frame = bounds.insetBy(dx: (bounds.width - c * 2) / 2, dy: (bounds.height - c * 2) / 2)
        layer?.addSublayer(halo)
        let r: CGFloat = 22
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.fillColor = nil; ring.strokeColor = gold.cgColor; ring.lineWidth = 3; ring.opacity = 0
        layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Klick: Ring schlägt aus, Leuchten blitzt kurz auf
    func pulse() {
        let sc = CABasicAnimation(keyPath: "transform.scale"); sc.fromValue = 0.45; sc.toValue = 2.3
        let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 1; op.toValue = 0
        let g = CAAnimationGroup(); g.animations = [sc, op]; g.duration = 0.45
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(g, forKey: "klick")
        let hb = CAKeyframeAnimation(keyPath: "transform.scale"); hb.values = [1, 1.25, 1]; hb.duration = 0.3
        halo.add(hb, forKey: "klick")
    }
}

// MARK: - Roter Rahmen um den erkannten Bildschirm (nur vor dem Start; gehört zu Flow → nie im Video)

final class ScreenRecFrame {
    private var panel: NSPanel?

    func show(on s: NSScreen?) {
        guard let s else { hide(); return }
        let p = panel ?? Self.makePanel()
        panel = p
        p.setFrame(s.frame, display: true)
        (p.contentView as? ScreenRecFrameView)?.label = ScreenRec.name(s)
        p.contentView?.needsDisplay = true
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = ScreenRecFrameView()
        return p
    }
}

final class ScreenRecFrameView: NSView {
    var label = ""
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        path.lineWidth = 5
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.systemRed.withAlphaComponent(0.8); sh.shadowBlurRadius = 14; sh.set()
        NSColor.systemRed.withAlphaComponent(0.9).setStroke(); path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
        // Marke oben mittig: „● Dieser Bildschirm wird aufgenommen · <Name>“
        let text = "●  Dieser Bildschirm wird aufgenommen · \(label)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = (text as NSString).size(withAttributes: attrs)
        let tag = NSRect(x: bounds.midX - sz.width / 2 - 14, y: bounds.maxY - 40 - sz.height, width: sz.width + 28, height: sz.height + 12)
        NSColor.systemRed.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: tag, xRadius: tag.height / 2, yRadius: tag.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: tag.minX + 14, y: tag.minY + 6), withAttributes: attrs)
    }
}

// MARK: - Selbsttest:  Flow --screen-rec-test (reine Logik, nimmt nichts auf)
//                     Flow --screen-rec-render <ordner> (Karten + Pillen-Zustände als PNG)
//                     Flow --screen-rec-probe <datei.mp4> (2 s echte Aufnahme des Bildschirms unter der Maus, ohne Ton)

enum ScreenRecDev {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--screen-rec-test": return test()
        case "--screen-rec-clip-read":   // nur für den Selbsttest: liest eine Test-Zwischenablage wie eine fremde App beim Einfügen
            let pb = NSPasteboard(name: NSPasteboard.Name(args.count > 2 ? args[2] : "app.flowdictation.flowtest.none"))
            print(pb.string(forType: .string) ?? "<nichts>")
            return 0
        case "--screen-rec-render": return render(dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "aufnahme")
        case "--screen-rec-trail-demo": return trailDemo(args.count > 2 ? args[2] : "")
        case "--screen-rec-context": return contextDemo(args.count > 2 ? args[2] : "", sound: args.count > 3 && args[3] == "system" ? .system : args.count > 3 && args[3] == "none" ? .none : .mic)
        case "--ink-test": return inkTest(args.count > 2 ? args[2] : NSTemporaryDirectory() + "ink.png")
        case "--screen-rec-probe": return probe(args.count > 2 ? args[2] : NSTemporaryDirectory() + "probe.mp4",
                                                 screenName: args.count > 3 && args[3] != "-" ? args[3] : nil, withGlow: args.contains("glow"))
        default: return nil
        }
    }

    static func test() -> Int32 {
        var fails = 0, n = 0
        func check(_ ok: Bool, _ what: String) { n += 1; if !ok { fails += 1; print("FEHLER \(what)") } }
        _ = NSApplication.shared
        // Ton-Wahl → Konfiguration
        let fake = Self.fakeDisplayConfig
        let none = fake(.none), sys = fake(.system), mic = fake(.mic)
        check(!none.capturesAudio && !none.captureMicrophone, "Ohne Ton: kein Ton, kein Mikro")
        check(sys.capturesAudio && !sys.captureMicrophone, "Systemton: Ton ja, Mikro nein")
        check(!mic.capturesAudio && mic.captureMicrophone, "Mikrofon: nur Mikro, kein Systemton")
        check(ScreenRecSound.stored("Systemton + Mikro") == .mic && ScreenRecSound.stored(nil) == .system, "alte Ton-Wahl wird übernommen")
        check(ScreenRecSound.system.transcribes && ScreenRecSound.mic.transcribes && !ScreenRecSound.none.transcribes, "Transkript auch bei Systemton, nicht ohne Ton")
        // Video folgt der Maus: anderer Bildschirm wird eingepasst (Seitenverhältnis bleibt), Mausspur trifft trotzdem
        let wide = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let mid = ScreenRecTrails.map(NSPoint(x: wide.midX, y: wide.midY), screen: wide, W: 3024, H: 1964)
        let corner = ScreenRecTrails.map(NSPoint(x: wide.minX, y: wide.minY), screen: wide, W: 3024, H: 1964)
        check(abs(mid.x - 1512) < 0.5 && abs(mid.y - 982) < 0.5 && abs(corner.x) < 0.5 && abs(corner.y - 131.5) < 0.5,
              "Mausspur auf breiterem Bildschirm sitzt richtig (Balken oben/unten)")
        let sw = [ScreenRecSwitch(t: 0, frame: .zero, name: "A"), ScreenRecSwitch(t: 5, frame: wide, name: "B")]
        check(ScreenRecTrails.frame(at: 4.9, sw) == .zero && ScreenRecTrails.frame(at: 6, sw) == wide, "richtiger Bildschirm je Zeitpunkt")
        let swCtx = ScreenRecKeyframes.compose(duration: 10, screen: "2 Bildschirme", sound: .none, segments: [], frames: [], switches: sw)
        check(swCtx.contains("[0:05] Video wechselt auf: B"), "Bildschirmwechsel steht im Kontext")
        check(sys.excludesCurrentProcessAudio, "eigene Töne (Flow) nicht im Video")
        check(sys.showsCursor && sys.showMouseClicks, "Mauszeiger + Klicks sichtbar")
        check(ScreenRecSound.allCases.map(\.rawValue) == ["Ohne Ton", "Mikrofon", "Systemton"], "drei Ton-Chips in fester Reihenfolge")
        // Dateiname
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 15; c.hour = 17; c.minute = 5; c.second = 9
        let d = Calendar(identifier: .gregorian).date(from: c)!
        check(ScreenRec.fileName(d) == "Bildschirmaufnahme 2026-10-15 um 17.05.09.mp4", "Dateiname: \(ScreenRec.fileName(d))")
        check(ScreenRec.shellEscape("/a b/c(1).mp4") == "/a\\ b/c\\(1\\).mp4", "Pfad fürs Terminal maskiert: \(ScreenRec.shellEscape("/a b/c(1).mp4"))")
        // Ordner existiert
        var dir: ObjCBool = false
        check(FileManager.default.fileExists(atPath: ScreenRec.folder().path, isDirectory: &dir) && dir.boolValue, "Zielordner existiert: \(ScreenRec.folder().path)")
        // Fertig-Karte
        let url = URL(fileURLWithPath: "/tmp/Bildschirmaufnahme x.mp4")
        let rd = ScreenRecDone(url: url, duration: 83.4, screen: "Externer Monitor", sound: .mic)
        var card = ScreenRec.doneNotice(rd, copy: {}, again: {})
        check(card.title == "Aufnahme fertig · 1:23", "Titel mit Laufzeit: \(card.title)")
        check(card.primary?.0 == "Kopieren" && card.secondary?.0 == "Nochmal", "Knöpfe Kopieren · Nochmal")
        check(card.text.contains("Externer Monitor") && card.text.contains("Mikrofon") && card.text.contains("gespeichert"), "sofort: Bildschirm, Ton, „wird gespeichert“")
        check(card.choices == ["Nur Video", "Mit Kontext", "Als Auftrag"] && card.preselect == 1, "Kopier-Wahl: Video · Kontext · Auftrag, Kontext vorgewählt")
        rd.fileReady()
        card = ScreenRec.doneNotice(rd, copy: {}, again: {})
        check(card.text.contains("Transkript und Bilder werden erstellt"), "danach: Kontext läuft")
        let sysD = ScreenRecDone(url: url, duration: 5, screen: "X", sound: .system)
        check(ScreenRec.doneNotice(sysD, copy: {}, again: {}).choices.count == 3, "ohne Mikro: dieselben drei Wahlen")
        // Klick-Kontext als Text
        let ci = ScreenRecClickInfo(t: 12.4, label: "Speichern", role: "Taste", app: "Safari", window: "Rechnung März")
        check(ci.text == "Klick auf „Speichern“ (Taste) · Safari – „Rechnung März“", "Klick-Text: \(ci.text)")
        check(ScreenRecClickInfo(t: 1, label: nil, role: nil, app: "Finder", window: "Finder").text == "Klick · Finder", "Klick ohne Beschriftung")
        check(ScreenRecClickProbe.clip(String(repeating: "x", count: 80)).count == 59, "lange Beschriftung gekürzt")
        // Stift (18.10.): Koordinaten direkt vom System, weiche Kurven statt Ecken
        let lp = ScreenRecInk.local(CGPoint(x: 1600, y: 100), primaryH: 982, screen: NSRect(x: 1512, y: -200, width: 1920, height: 1080))
        check(lp == CGPoint(x: 88, y: 1082), "Stift: Position auf dem zweiten Bildschirm richtig umgerechnet (\(lp))")
        let ring = (0..<60).map { i -> CGPoint in let a = Double(i) / 60 * 2 * .pi; return CGPoint(x: 200 + 100 * cos(a), y: 200 + 100 * sin(a)) }
        let sp = ScreenRecInk.smooth(ring)
        var curves = 0, lines = 0
        sp.applyWithBlock { e in switch e.pointee.type { case .addQuadCurveToPoint: curves += 1; case .addLineToPoint: lines += 1; default: break } }
        check(curves == 58 && lines == 1, "Stift: Kreis wird aus Kurven gebaut (\(curves) Kurven, \(lines) Linie)")
        let bb = sp.boundingBoxOfPath
        check(abs(bb.width - 200) < 4 && abs(bb.height - 200) < 4, "Stift: geglätteter Kreis behält seine Größe (\(Int(bb.width))×\(Int(bb.height)))")
        check(ScreenRecInk.hz >= 120, "Stift tastet ≥ 120×/s ab")
        // Markierung auswerten (18.10.): Ausschnitt-Rechteck + was dabei gesagt wurde
        let mr = ScreenRecMarks.rect(NSRect(x: 100, y: 800, width: 200, height: 100), screen: NSRect(x: 0, y: 0, width: 1512, height: 982), W: 3024, H: 1964)
        check(mr == CGRect(x: 100, y: 64, width: 600, height: 400), "Markierung: Ausschnitt um die Linie mit Rand, oben-links-Pixel (\(String(describing: mr)))")
        let edge = ScreenRecMarks.rect(NSRect(x: 0, y: 0, width: 10, height: 10), screen: NSRect(x: 0, y: 0, width: 1512, height: 982), W: 3024, H: 1964)
        check(edge.map { $0.minX >= 0 && $0.maxY <= 1964 && $0.width >= 240 } == true, "Markierung am Rand: Ausschnitt bleibt im Bild (\(String(describing: edge)))")
        let segsM = [ScreenRecTranscript.Segment(start: 5, text: "Das hier finde ich cool."), ScreenRecTranscript.Segment(start: 12, text: "Komisch."),
                     ScreenRecTranscript.Segment(start: 15, text: "Genau diesen Bereich."), ScreenRecTranscript.Segment(start: 21, text: "Anderes Thema.")]
        let saidM = ScreenRecMarks.said(segsM, start: 13.2, end: 17.0) ?? ""
        check(saidM == "Komisch. Genau diesen Bereich.", "Markierung: Sätze beim Zeichnen gefunden (\(saidM))")
        let ctxM = ScreenRecKeyframes.compose(duration: 30, screen: "Test", sound: .mic, segments: segsM, frames: [], marks: [[13.2, 17.0]],
                                              markCrops: [0: URL(fileURLWithPath: "/tmp/Markierung 0m13s.jpg")])
        check(ctxM.contains("[0:13–0:17] Rot eingezeichnet (Markierung) – Ausschnitt: /tmp/Markierung 0m13s.jpg\n    dazu gesagt: „Komisch. Genau diesen Bereich.“"),
              "Markierung im Kontext: Ausschnitt + dazu gesagt")
        // Markierung → Bild mit höchster Priorität
        let tm = ScreenRecKeyframes.times(duration: 30, clicks: [10], speech: [11], marks: [11.5])
        check(tm.contains(11.6) && !tm.contains(10.35), "Bild nach Markierung schlägt Klick daneben: \(tm)")
        let ctx3 = ScreenRecKeyframes.compose(duration: 20, screen: "X", sound: .system, segments: [], frames: [],
                                              clicks: [ci], marks: [[14, 16]])
        check(ctx3.contains("[0:12] Klick auf „Speichern“") && ctx3.contains("[0:14–0:16] Rot eingezeichnet"), "Klicks + Markierungen im Kontext")
        check(ScreenRecTask.fallback(video: url, context: "K").contains("Video: \(url.path)"), "Auftrag ohne Claude: Vorlage mit Video-Pfad")
        let words: ScreenRecTranscript.Words = [("Hallo", 0.2, 0.5), ("zusammen.", 0.6, 1.0), ("Hier", 1.3, 1.5), ("klicke", 1.6, 1.9),
                                                ("ich", 2.0, 2.1), ("dann", 4.0, 4.2), ("weiter", 4.3, 4.6)]
        let sents = ScreenRecTranscript.sentences(words, offset: 30)
        check(sents.map(\.text) == ["Hallo zusammen.", "Hier klicke ich", "dann weiter"] && sents.map(\.start) == [30.2, 31.3, 34.0],
              "Sätze: \(sents.map { "\($0.start) \($0.text)" })")
        let ts = ScreenRecKeyframes.times(duration: 40, clicks: [5, 6, 20], speech: [0.2, 12, 20.5])
        check(ts.first == 0.4 && ts.contains(5.35) && !ts.contains(6.35) && ts.contains(20.35) && ts.contains(12.2) && ts.last == 39.7,
              "Bild-Zeitpunkte: \(ts)")
        let many = ScreenRecKeyframes.times(duration: 600, clicks: (0..<60).map { Double($0) * 10 }, speech: [])
        check(many.count == ScreenRecKeyframes.maxFrames, "höchstens \(ScreenRecKeyframes.maxFrames) Bilder (\(many.count))")
        // Mausspur: zwei Striche mit Pause dazwischen, ein Zittern fällt weg
        var ms: [ScreenRecMouse] = []
        func addLine(_ t0: Double, _ x0: Double, _ x1: Double) { for k in 0...30 { ms.append(.init(t: t0 + Double(k) / 30, x: x0 + (x1 - x0) * Double(k) / 30, y: 100)) } }
        func addStill(_ t0: Double, _ x: Double, _ secs: Double) { for k in 1...Int(secs * 30) { ms.append(.init(t: t0 + Double(k) / 30, x: x, y: 100)) } }
        addLine(0, 0, 300); addStill(1, 300, 0.6); addLine(1.6, 300, 600); addStill(2.6, 600, 0.6)
        for k in 0..<10 { ms.append(.init(t: 3.2 + Double(k) / 30, x: 600 + Double(k % 2) * 3, y: 100)) }
        let rs = ScreenRecTrails.strokes(ms)
        check(rs.count == 2 && abs(ms[rs[0].lowerBound].t) < 0.2 && abs(ms[rs[1].lowerBound].t - 1.6) < 0.2,
              "Mausspur-Striche an Pausen: \(rs.map { (ms[$0.lowerBound].t, ms[$0.upperBound - 1].t) })")
        let fr = [ScreenRecKeyframe(time: 5.35, url: URL(fileURLWithPath: "/x/0m05s.jpg"), click: true)]
        let ctx = ScreenRecKeyframes.compose(duration: 32, screen: "Monitor", sound: .mic,
                                             segments: [.init(start: 0.2, text: "Hier geht nichts."), .init(start: 6, text: "Komisch.")], frames: fr)
        let ctx2 = ScreenRecKeyframes.compose(duration: 32, screen: "Monitor", sound: .system, segments: [], frames: [],
                                              trails: [ScreenRecTrail(start: 12.3, end: 15.1, url: URL(fileURLWithPath: "/x/Mausspur 0m12s–0m15s.jpg"))])
        check(ctx2.hasSuffix("[0:12–0:15] Mausspur (grün = Anfang, rot = Ende): /x/Mausspur 0m12s–0m15s.jpg"), "Mausspur im Kontext: \(ctx2)")
        check(ctx == "Bildschirmaufnahme (0:32, Monitor) – was ich sage und was dabei zu sehen ist:\n[0:00] Hier geht nichts.\n[0:05] Bild (nach Klick): /x/0m05s.jpg\n[0:06] Komisch.",
              "Kontext-Text: \(ctx.replacingOccurrences(of: "\n", with: " | "))")
        // Bildschirm-Zuordnung: jede NSScreen-ID ist eine CGDisplay-ID
        for s in NSScreen.screens { check(CGDisplayBounds(ScreenRec.displayID(s)).width > 0, "Display-ID für \(s.localizedName)") }
        // Pille: Umfang der Kapsel (für den kreisenden Lichtschweif)
        let per = PillView.perimeter(NSRect(x: 0, y: 0, width: 118, height: 26))
        check(abs(per - (2 * 92 + .pi * 26)) < 0.01, "Kapsel-Umfang \(per)")
        clipTest(check)
        // Abbau (19.10.2026): laufende Aufnahme NUR stoppen – Ausgabe abhängen + stoppen ließ replayd bei jedem Stopp abstürzen
        check(ScreenRec.teardownSteps(captureStarted: true, hasOutput: true) == [.stopCapture], "Stopp einer laufenden Aufnahme: nur stopCapture (kein doppelter Abschluss)")
        check(ScreenRec.teardownSteps(captureStarted: false, hasOutput: true) == [.detachOutput, .stopCapture], "Fehlstart: Ausgabe abhängen, dann stoppen (kein Geist)")
        check(ScreenRec.teardownSteps(captureStarted: false, hasOutput: false) == [.stopCapture], "Fehlstart ohne Ausgabe: nur stoppen")
        print("\(n - fails)/\(n) Prüfungen bestanden – Bildschirmaufnahme")
        return fails == 0 ? 0 : 1
    }

    private static var fakeDisplayConfig: (ScreenRecSound) -> SCStreamConfiguration = { sound in
        // SCDisplay lässt sich nicht bauen → dieselben Ton-/Zeiger-Regeln wie ScreenRec.configuration, ohne Größe
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = true; cfg.showMouseClicks = true
        cfg.capturesAudio = sound == .system
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = sound == .mic
        return cfg
    }

    static func render(dir: String) -> Int32 {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let scr = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let bottom = NSRect(x: scr.midX - 22, y: 14, width: 44, height: 9)
        var ok = true
        var arm = VFNotice(id: ScreenRec.cardID, title: "Bildschirm aufnehmen",
                           text: "Erkannt: Externer Monitor (1920 × 1080). Anderen? Maus hinbewegen.",
                           illustration: "illu_bildschirm_aufnahme", fallbackSymbol: "record.circle")
        arm.choices = ScreenRecSound.allCases.map(\.rawValue); arm.preselect = 1
        arm.primary = ("Aufnehmen", {}); arm.secondary = ("Abbrechen", {}); arm.timeout = nil
        arm.toggle = VFNoticeToggle(label: "Maus leuchtet (fürs Erklären)", symbol: "cursorarrow.rays", on: true)
        arm.chip = VFNoticeChip(label: "Pille und Karten sind nicht im Video", symbol: "eye.slash", tint: .red)
        ok = VFNotify.renderPNG(arm, to: out.appendingPathComponent("1_bereit.png"), pill: bottom, screen: scr) && ok
        let dd = ScreenRecDone(url: URL(fileURLWithPath: "/x/Bildschirmaufnahme 2026-10-15 um 17.05.09.mp4"),
                               duration: 42, screen: "Externer Monitor", sound: .mic)
        dd.fileReady()
        let done = ScreenRec.doneNotice(dd, copy: {}, again: {})
        ok = VFNotify.renderPNG(done, to: out.appendingPathComponent("2_fertig.png"), pill: bottom, screen: scr) && ok
        print(out.path)
        return ok ? 0 : 1
    }

    /// Mausspur-Bild prüfen: künstlicher Kreis (Mitte des Bildschirms 1512×982) → Bild neben dem Video
    static func trailDemo(_ path: String) -> Int32 {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: path)
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        var m: [ScreenRecMouse] = []
        for k in 0..<30 { m.append(.init(t: 1 + Double(k) / 30, x: 756, y: 491)) }
        for k in 0...60 { let a = Double(k) / 60 * 2 * .pi; m.append(.init(t: 2 + Double(k) / 30, x: 756 + 200 * cos(a), y: 491 + 200 * sin(a))) }
        for k in 1...30 { m.append(.init(t: 4 + Double(k) / 30, x: 956, y: 491)) }
        var rc: Int32 = 1
        let sem = DispatchSemaphore(value: 0)
        Task { let t = await ScreenRecTrails.render(url, mouse: m, screen: screen); t.forEach { print($0.url.path) }; rc = t.isEmpty ? 1 : 0; sem.signal() }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return rc
    }

    /// „Mit Kontext“ als Versprechen (19.10.2026): ⌘V vor dem fertigen Kontext bekommt trotzdem Pfad + Kontext.
    /// Nur eigene Test-Zwischenablagen – die echte Zwischenablage wird nie angefasst.
    static func clipTest(_ check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        let tmp = FileManager.default.temporaryDirectory
        func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("app.flowdictation.flowtest.screenrec-\(UUID().uuidString)")) }
        func video() -> URL { tmp.appendingPathComponent("Test Aufnahme \(UUID().uuidString.prefix(6)).mp4") }
        func later(_ s: Double, _ url: URL, _ ctx: String?) {
            DispatchQueue.global().asyncAfter(deadline: .now() + s) { ScreenRecClip.finish(url, context: ctx) }
        }
        // 1) Einfügen in Flow selbst, Kontext kommt 0,4 s später → wartet und bekommt alles
        do {
            let pb = board(), u = video(), c = ScreenRecClip(url: u, pasteboard: pb)
            c.write(); later(0.4, u, "[0:01] Das hier ist kaputt.")
            let t0 = Date(); let s = pb.string(forType: .string) ?? ""; let dt = Date().timeIntervalSince(t0)
            check(s.contains("Das hier ist kaputt.") && s.hasPrefix(CVPickSet.shellEscape(u.path)) && dt > 0.3,
                  String(format: "Versprechen: ⌘V wartet auf den Kontext (%.2f s) und bekommt Pfad + Gesagtes", dt))
            check(pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL == u, "Versprechen: Datei liegt sofort drin")
            check(!c.isPending && c.delivered, "Versprechen: nach dem Einfügen erfüllt")
            pb.releaseGlobally()
        }
        // 2) Wie im echten Fall: fremde App fügt sofort ein (eigener Prozess), Kontext kommt 1 s später
        if let exe = Bundle.main.executablePath {
            let pb = board(), u = video(), c = ScreenRecClip(url: u, pasteboard: pb)
            c.write(); later(1.0, u, "[0:02] Genau diesen Knopf meine ich.")
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["--screen-rec-clip-read", pb.name.rawValue]; p.standardOutput = out
            let t0 = Date()
            var s = ""
            if (try? p.run()) != nil {
                while p.isRunning && Date().timeIntervalSince(t0) < 20 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
                s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }
            check(s.contains("Genau diesen Knopf meine ich.") && s.hasPrefix(CVPickSet.shellEscape(u.path)),
                  String(format: "Versprechen: andere App fügt sofort ein → wartet %.1f s, bekommt Pfad + Gesagtes", Date().timeIntervalSince(t0)))
            pb.releaseGlobally()
        }
        // 3) Kontext schon fertig → sofort
        do {
            let pb = board(), u = video(), c = ScreenRecClip(url: u, pasteboard: pb)
            ScreenRecClip.finish(u, context: "[0:00] Fertig."); c.write()
            let t0 = Date(); let s = pb.string(forType: .string) ?? ""
            check(s.hasSuffix("[0:00] Fertig.") && Date().timeIntervalSince(t0) < 0.2, "Versprechen: fertiger Kontext kommt ohne Warten")
            pb.releaseGlobally()
        }
        // 4) Kontext wird nie fertig → nach waitLimit Pfad + ehrlicher Hinweis (kein Hängen)
        do {
            let keep = ScreenRecClip.waitLimit; ScreenRecClip.waitLimit = 0.3
            let pb = board(), u = video(), c = ScreenRecClip(url: u, pasteboard: pb)
            c.write()
            let t0 = Date(); let s = pb.string(forType: .string) ?? ""; let dt = Date().timeIntervalSince(t0)
            check(s.hasPrefix(CVPickSet.shellEscape(u.path)) && s.contains("noch nicht fertig") && dt < 1.5, String(format: "Versprechen: Höchstwartezeit greift (%.2f s)", dt))
            ScreenRecClip.waitLimit = keep
            pb.releaseGlobally()
        }
        // 5) Diktat/Befehlsmodus sichert die Zwischenablage: wartet NICHT, legt danach das Versprechen zurück
        do {
            let pb = board(), u = video(), c = ScreenRecClip(url: u, pasteboard: pb)
            c.write()
            let t0 = Date(); let snap = CommandMode.snapshot(pb); let dt = Date().timeIntervalSince(t0)
            check(dt < 0.1 && snap.count == 1 && snap[0][ScreenRecClip.markerType] != nil, String(format: "Sichern beim Diktat wartet nicht auf den Kontext (%.3f s)", dt))
            pb.clearContents(); pb.setString("diktierter Text", forType: .string)
            CommandMode.restore(snap, into: pb)
            later(0.2, u, "[0:03] Zurückgelegt.")
            let s = pb.string(forType: .string) ?? ""
            check(s.contains("Zurückgelegt.") && (pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL) == u,
                  "Nach dem Diktat liegt wieder Video + Kontext in der Zwischenablage")
            pb.releaseGlobally()
        }
    }

    /// Kontext (Transkript + Schlüsselbilder) für ein vorhandenes Video bauen und ausgeben – Bilder landen neben dem Video
    static func contextDemo(_ path: String, sound: ScreenRecSound) -> Int32 {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { print("Datei fehlt"); return 1 }
        var rc: Int32 = 1
        let sem = DispatchSemaphore(value: 0)
        Task {
            let dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            let t0 = Date()
            let segs = sound.transcribes ? (await ScreenRecTranscript.segments(url) ?? []) : []
            // mark=Start,Ende,x,y,b,h (Bildschirm-Punkte, Ursprung unten links; Bildschirm = Videogröße in Punkten)
            var marks: [[Double]] = [], boxes: [NSRect] = []
            for a in CommandLine.arguments where a.hasPrefix("mark=") {
                let v = a.dropFirst(5).split(separator: ",").compactMap { Double($0) }
                if v.count == 6 { marks.append([v[0], v[1]]); boxes.append(NSRect(x: v[2], y: v[3], width: v[4], height: v[5])) }
            }
            let tr = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
            let px = (try? await tr?.load(.naturalSize)) ?? .zero
            let sw = [ScreenRecSwitch(t: 0, frame: NSRect(x: 0, y: 0, width: px.width / 2, height: px.height / 2), name: "Test")]
            let times = ScreenRecKeyframes.times(duration: dur, clicks: [], speech: segs.map(\.start), marks: marks.compactMap(\.last))
            let frames = await ScreenRecKeyframes.extract(url, at: times, clicks: [], marks: marks.compactMap(\.last))
            let crops = await ScreenRecMarks.crops(url, marks: marks, boxes: boxes, switches: sw)
            print(ScreenRecKeyframes.compose(duration: dur, screen: "Test", sound: sound, segments: segs, frames: frames,
                                             marks: marks, switches: sw, markCrops: crops))
            print(String(format: "– %.1f s", Date().timeIntervalSince(t0)))
            rc = frames.isEmpty ? 1 : 0
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return rc
    }

    /// Stift ohne Aufnahme: Kreis zeichnen (Main-Thread hängt zweimal 0,5 s), Stift-Fenster abfotografieren, Rot zählen
    static func inkTest(_ path: String) -> Int32 {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { print("Keine Freigabe Bildschirmaufnahme"); return 3 }
        let screen = ScreenRec.screenUnderMouse()
        let ink = ScreenRecInk(); ink.prepare(on: screen)
        let c = CGPoint(x: (screen?.frame.width ?? 1000) / 2, y: (screen?.frame.height ?? 800) / 2)
        let ring = (0...180).map { i -> CGPoint in let a = Double(i) / 180 * 2 * .pi; return CGPoint(x: c.x + 220 * cos(a), y: c.y + 160 * sin(a)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        ink.simulate(ring, every: 1.0 / 120)
        var shots: [(Double, Int)] = []
        let t0 = Date()
        func shoot() {
            let sem = DispatchSemaphore(value: 0)
            Task {
                defer { sem.signal() }
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                      let w = content.windows.first(where: { $0.windowID == CGWindowID(ink.windowNumber) }) else { return }
                let cfg = SCStreamConfiguration(); cfg.width = Int(w.frame.width); cfg.height = Int(w.frame.height)
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { return }
                let rep = NSBitmapImageRep(cgImage: img)
                var red = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    if let col = rep.colorAt(x: x, y: y), col.redComponent > 0.8, col.greenComponent < 0.45, col.alphaComponent > 0.6 { red += 1 }
                } }
                shots.append((Date().timeIntervalSince(t0), red))
                if shots.count == 4 { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
            }
            while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Thread.sleep(forTimeInterval: 0.5) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.25)); shoot() }
        print("Stift: " + shots.map { String(format: "%.2fs=%d", $0.0, $0.1) }.joined(separator: " "))
        print("Markierungen: \(ink.marks.count) → \(path)")
        ink.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (shots.map(\.1).max() ?? 0) > 50 ? 0 : 1
    }

    /// screenName: Teil des Bildschirm-Namens statt Bildschirm unter der Maus
    static func probe(_ path: String, screenName: String? = nil, withGlow: Bool = false) -> Int32 {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { print("Keine Freigabe Bildschirmaufnahme"); return 3 }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        final class D: NSObject, SCRecordingOutputDelegate {
            var done = false
            func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) { done = true }
        }
        let d = D()
        var rc: Int32 = 1
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            let glow: ScreenRecCursorGlow? = withGlow ? await MainActor.run { let g = ScreenRecCursorGlow(); g.start(); return g } : nil
            // 18.10.2026: was hier läuft, wird bei einem Fehler im catch abgebaut (nie eine Aufnahme/Stift/Leuchten zurücklassen)
            var ink: ScreenRecInk?
            var live: SCStream?, liveOut: SCRecordingOutput?
            do {
                let screen = screenName.flatMap { n in NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(n) } } ?? ScreenRec.screenUnderMouse()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let disp = content.displays.first(where: { $0.displayID == ScreenRec.displayID(screen) }) else {
                    print("Bildschirm nicht gefunden"); await MainActor.run { glow?.stop() }; return
                }
                let cfg = ScreenRec.configuration(display: disp, screen: screen, sound: .none)
                // wie in der App: eigene Fenster raus – außer dem Maus-Leuchten (glow)
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let gw = glow.flatMap { g in content.windows.first { $0.windowID == CGWindowID(g.windowNumber) } }
                if glow != nil { print("Leuchten-Fenster im Inhalt: \(gw != nil)") }
                // „ink“: Stift malt einen Kreis, während der Main-Thread absichtlich zweimal 0,5 s hängt
                let withInk = CommandLine.arguments.contains("ink")
                ink = withInk ? await MainActor.run { let k = ScreenRecInk(); k.prepare(on: screen); return k } : nil
                let content2 = withInk ? try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) : content
                let iw = ink.flatMap { k in content2.windows.first { $0.windowID == CGWindowID(k.windowNumber) } }
                if withInk { print("Stift-Fenster im Inhalt: \(iw != nil)") }
                let st = SCStream(filter: SCContentFilter(display: disp, excludingApplications: me, exceptingWindows: [gw, iw].compactMap { $0 }), configuration: cfg, delegate: nil)
                let oc = SCRecordingOutputConfiguration(); oc.outputURL = url; oc.outputFileType = .mp4; oc.videoCodecType = .h264
                let out = SCRecordingOutput(configuration: oc, delegate: d)
                live = st; liveOut = out
                try st.addRecordingOutput(out)
                try await st.startCapture()
                if let k = ink, let sc = screen {
                    let c = CGPoint(x: sc.frame.width / 2, y: sc.frame.height / 2)
                    let ring = (0...180).map { i -> CGPoint in let a = Double(i) / 180 * 2 * .pi; return CGPoint(x: c.x + 220 * cos(a), y: c.y + 160 * sin(a)) }
                    try await Task.sleep(nanoseconds: 300_000_000)
                    k.simulate(ring, every: 1.0 / 120)
                    for d in [0.3, 0.9] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { Thread.sleep(forTimeInterval: 0.5) } }
                    try await Task.sleep(nanoseconds: 2_200_000_000)
                    print("Stift: \(k.marks.count) Markierung(en)")
                    await MainActor.run { k.stop() }
                    ink = nil
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                // „switch“: wie „Video folgt der Maus“ – mitten in der Aufnahme auf einen anderen Bildschirm wechseln
                if CommandLine.arguments.contains("switch"), let other = content.displays.first(where: { $0.displayID != disp.displayID }) {
                    try await st.updateContentFilter(SCContentFilter(display: other, excludingApplications: me, exceptingWindows: []))
                    print("gewechselt auf Bildschirm \(other.displayID) (\(other.width)×\(other.height))")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                await MainActor.run { glow?.stop() }
                // „teardown“: genau der Abbau der App (Ausgabe abhängen → Stream stoppen) statt nur stopCapture
                if CommandLine.arguments.contains("teardown") { await ScreenRec.tearDown(st, out, captureStarted: true, why: "Probe") }
                else { try await st.stopCapture() }
                live = nil; liveOut = nil
                for _ in 0..<60 where !d.done { try await Task.sleep(nanoseconds: 100_000_000) }
                let tracks = try await AVURLAsset(url: url).load(.tracks)
                let v = tracks.first { $0.mediaType == .video }
                let size = try await v?.load(.naturalSize) ?? .zero
                print("\(ScreenRec.name(screen)): \(Int(size.width))×\(Int(size.height)), Spuren \(tracks.count) → \(url.path)")
                rc = v != nil && size.width >= CGFloat(disp.width) ? 0 : 1
            } catch {
                print("Fehler: \(error.localizedDescription)")
                await ScreenRec.tearDown(live, liveOut, captureStarted: true, why: "Probe")
                let k = ink
                await MainActor.run { k?.stop(); glow?.stop() }   // Layer/Fenster nur auf dem Main-Thread
            }
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return rc
    }
}
