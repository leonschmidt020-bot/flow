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
    /// gespeicherte Wahl (frühe Fassung „Systemton + Mikro“ → Mikrofon: da wurde erklärt)
    static func stored(_ raw: String?) -> ScreenRecSound {
        if raw == "Systemton + Mikro" { return .mic }
        return ScreenRecSound(rawValue: raw ?? "") ?? .system
    }
}

/// Kopier-Art der fertigen Aufnahme: nur die Datei – oder mit Kontext für Agents (Schlüsselbilder, mit Mikrofon
/// auch das Transkript)
enum ScreenRecCopy: String, CaseIterable {
    case video = "Nur Video", withContext = "mit Kontext"
    static func label(_ c: ScreenRecCopy, sound: ScreenRecSound) -> String {
        c == .video ? "Nur Video" : (sound == .mic ? "Video + Transkript + Bilder" : "Video + Bilder")
    }
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
    private var clickMonitor: Any?
    /// Mausposition während der Aufnahme (30×/s, Bildschirm-Koordinaten) → Mausspur-Bilder
    private var mouse: [ScreenRecMouse] = []
    private var mouseTimer: Timer?

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
                         text: "Erkannt: \(Self.name(s))\(Self.sizeLabel(s)). Anderen? Maus hinbewegen.",
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

    // MARK: 3. Aufnahme

    private func startCapture() {
        phase = .starting
        frame?.hide(); frame = nil
        let screen = target ?? Self.screenUnderMouse()
        let sound = self.sound
        let url = Self.newFileURL()
        // Leuchten um die Maus: eigenes Fenster, das als einziges von Flow MIT ins Video kommt
        if glow { let g = ScreenRecCursorGlow(); g.start(); glowView = g } else { glowView = nil }
        fileURL = url
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let id = Self.displayID(screen)
                guard let disp = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                    throw NSError(domain: "ScreenRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "kein Bildschirm gefunden"])
                }
                // Flow selbst (Pille, Karten, Rahmen) gehört nicht ins Video
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let glowWin = self.glowView.flatMap { g in content.windows.first { $0.windowID == CGWindowID(g.windowNumber) } }
                if self.glowView != nil && glowWin == nil { log("Bildschirmaufnahme: Maus-Leuchten nicht gefunden – Aufnahme ohne") }
                let filter = SCContentFilter(display: disp, excludingApplications: me, exceptingWindows: glowWin.map { [$0] } ?? [])
                let cfg = Self.configuration(display: disp, screen: screen, sound: sound)
                let st = SCStream(filter: filter, configuration: cfg, delegate: self)
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = url
                rc.outputFileType = .mp4
                rc.videoCodecType = .h264
                let out = SCRecordingOutput(configuration: rc, delegate: self)
                try st.addRecordingOutput(out)
                self.stream = st; self.output = out
                self.filter = filter; self.display = disp
                try await st.startCapture()
                guard self.phase == .starting else { try? await st.stopCapture(); return }
                self.startedAt = Date()
                self.clicks = []
                let t0 = self.startedAt
                self.clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                    self?.clicks.append(Date().timeIntervalSince(t0))
                }
                self.mouse = []
                let mt = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let m = NSEvent.mouseLocation
                    self.mouse.append(ScreenRecMouse(t: Date().timeIntervalSince(t0), x: m.x, y: m.y))
                }
                RunLoop.main.add(mt, forMode: .common)
                self.mouseTimer = mt
                self.phase = .recording
                self.setPill(.screenRec(start: self.startedAt))
                self.startGuard()
                log("Bildschirmaufnahme läuft: \(Self.name(screen)) \(cfg.width)×\(cfg.height), \(sound.rawValue)\(self.glowView != nil ? ", Maus leuchtet" : "") → \(url.lastPathComponent)")
            } catch {
                log("Bildschirmaufnahme: Start fehlgeschlagen – \(error.localizedDescription)")
                self.reset()
                self.pill?.view.showToast("Aufnahme ging nicht: \(error.localizedDescription.prefix(50))", seconds: 4)
            }
        }
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
        return cfg
    }

    /// Pille bleibt auf „Aufnahme“, auch wenn Diktat oder Meeting sie zwischendurch umstellen
    private func startGuard() {
        guardTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.phase == .recording, let v = self.pill?.view else { return }
            if case .idle = v.mode { v.mode = .screenRec(start: self.startedAt) }
            if case .meeting = v.mode { v.mode = .screenRec(start: self.startedAt) }
        }
        RunLoop.main.add(t, forMode: .common)
        guardTimer = t
    }

    func stop() {
        guard isRecording, let st = stream else { if phase == .starting { reset() }; return }
        phase = .finishing
        guardTimer?.invalidate(); guardTimer = nil
        glowView?.stop(); glowView = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }; clickMonitor = nil
        mouseTimer?.invalidate(); mouseTimer = nil
        // Karte SOFORT zeigen (sonst wirkt es sekundenlang, als käme nichts); Datei, Vorschaubild und Transkript
        // kommen dahinter nach (Kopieren wartet, falls die Datei noch nicht fertig ist).
        if let url = fileURL {
            let d = ScreenRecDone(url: url, duration: Date().timeIntervalSince(startedAt), screen: Self.name(target), sound: sound)
            d.clicks = clicks
            d.mouse = mouse
            d.screenFrame = target?.frame ?? Self.screenUnderMouse()?.frame ?? .zero
            d.onChange = { [weak self, weak d] in if let d { self?.showDone(d) } }
            done = d
            showDone(d)
        }
        setPill(fallbackMode())
        Task { @MainActor in
            do { try await st.stopCapture() } catch { log("Bildschirmaufnahme: Stopp – \(error.localizedDescription)") }
            // fertig wird die Datei erst mit recordingOutputDidFinishRecording; Sicherheitsnetz nach 6 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.phase == .finishing else { return }
                self.finished()
            }
        }
    }

    // SCRecordingOutputDelegate
    func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) {
        DispatchQueue.main.async { [weak self] in if self?.phase == .finishing { self?.finished() } }
    }
    func recordingOutput(_ r: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            log("Bildschirmaufnahme: Datei-Fehler – \(error.localizedDescription)")
            guard let self else { return }
            if self.phase == .recording || self.phase == .starting { self.stop() }
        }
    }
    // SCStreamDelegate: z. B. Bildschirm abgesteckt, Freigabe entzogen
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            log("Bildschirmaufnahme: von macOS beendet – \(error.localizedDescription)")
            self.phase = .finishing
            self.guardTimer?.invalidate(); self.guardTimer = nil
            self.setPill(self.fallbackMode())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if self.phase == .finishing { self.finished() } }
        }
    }

    // MARK: 4. Fertig: Kopieren · Nochmal

    private func finished() {
        let url = fileURL, sound = self.sound, screen = target
        let d = done
        reset()
        guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
            VFNotify.shared.dismiss(id: Self.doneID)
            pill?.view.showToast("Aufnahme leer – nichts gespeichert", seconds: 3); return
        }
        log("Bildschirmaufnahme fertig: \(url.lastPathComponent), \(Int(d?.duration ?? 0)) s, \(size / 1_000_000) MB")
        let done = d ?? ScreenRecDone(url: url, duration: 0, screen: Self.name(screen), sound: sound)
        if d == nil { done.onChange = { [weak self, weak done] in if let done { self?.showDone(done) } }; self.done = done }
        done.fileReady()
        Task { @MainActor in
            done.thumbnail = await Self.thumbnail(of: url)
            done.changed()
        }
        done.buildContext()
    }

    /// Karte „Aufnahme fertig“ zeigen bzw. aktualisieren – aber nie wieder öffnen, wenn sie schon zu ist
    private func showDone(_ d: ScreenRecDone) {
        guard d.cardOpen else { return }
        if d.shownOnce && VFNotify.shared.currentID != Self.doneID { return }
        d.shownOnce = true
        let n = Self.doneNotice(d,
            copy: { [weak d] in d?.copyRequested(VFNotify.shared.chosen == "Nur Video" ? .video : .withContext) },
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
        let state: String
        if !d.ready { state = "Wird gespeichert …" }
        else if d.context == nil { state = d.sound == .mic ? "Transkript und Bilder werden erstellt …" : "Schlüsselbilder werden erstellt …" }
        else {
            let n = d.keyframes.count, sp = d.trails.count
            state = (d.sound == .mic ? (d.saidSomething ? "Transkript + " : "Nichts gesprochen · ") : "") + "\(n) Bild\(n == 1 ? "" : "er")"
                + (sp > 0 ? " + \(sp) Mausspur\(sp == 1 ? "" : "en")" : "") + " für den Agent."
        }
        var n = VFNotice(id: doneID, title: "Aufnahme fertig · \(sec / 60):\(String(format: "%02d", sec % 60))",
                         text: "\(d.screen), \(d.sound.short). \(state)",
                         illustration: "illu_aufnahme_fertig", fallbackSymbol: "play.rectangle.fill")
        n.primary = ("Kopieren", copy)
        n.secondary = ("Nochmal", again)
        n.timeout = 45
        n.onClose = closed
        n.choices = ScreenRecCopy.allCases.map { ScreenRecCopy.label($0, sound: d.sound) }
        n.preselect = 1   // für den Agent: Kontext ist meist gewollt
        if let t = d.thumbnail { n.thumbnails = [t] }
        n.thumbnailCaption = d.url.lastPathComponent
        return n
    }

    /// Echte Datei + Pfad als Text (wie ClipVault): ⌘V fügt das Video in Chats/Mail/Finder ein, im Terminal den Pfad.
    /// Mit Transkript: der Text-Teil enthält zusätzlich, was im Video gesagt wurde (mit Zeitmarken) – für Agents.
    func copy(_ url: URL, context: String? = nil) {
        let it = NSPasteboardItem()
        it.setString(url.absoluteString, forType: .fileURL)
        var text = Self.shellEscape(url.path)
        let transcript = context
        if let t = context, !t.isEmpty { text += "\n\n" + t }
        it.setString(text, forType: .string)
        let pb = NSPasteboard.general
        pb.clearContents(); pb.writeObjects([it])
        pill?.view.showToast(transcript?.isEmpty == false ? "Video + Kontext kopiert – ⌘V" : "Video kopiert – ⌘V zum Einfügen", seconds: 2.4)
        log("Bildschirmaufnahme kopiert: \(url.lastPathComponent)\(transcript?.isEmpty == false ? " + Kontext" : "")")
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
        if let m = clickMonitor { NSEvent.removeMonitor(m) }; clickMonitor = nil
        mouseTimer?.invalidate(); mouseTimer = nil
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
    let screen: String
    let sound: ScreenRecSound
    var clicks: [TimeInterval] = []
    var mouse: [ScreenRecMouse] = []
    var screenFrame: NSRect = .zero
    private(set) var trails: [ScreenRecTrail] = []
    private(set) var ready = false
    var thumbnail: URL?
    /// fertiger Kontext-Text für Agents (Transkript + Bilder); nil = wird noch erstellt
    private(set) var context: String?
    private(set) var keyframes: [ScreenRecKeyframe] = []
    private(set) var saidSomething = false
    var cardOpen = true
    var shownOnce = false
    var onChange: () -> Void = {}
    private var pendingCopy: ScreenRecCopy?

    init(url: URL, duration: TimeInterval, screen: String, sound: ScreenRecSound) {
        self.url = url; self.duration = duration; self.screen = screen; self.sound = sound
    }

    func changed() { onChange(); tryCopy() }
    func fileReady() { ready = true; changed() }

    /// „Kopieren“ gedrückt – sofort, oder sobald Datei (und ggf. Kontext) fertig sind
    func copyRequested(_ mode: ScreenRecCopy) {
        cardOpen = false
        pendingCopy = mode
        if !ready || (mode == .withContext && context == nil) {
            ScreenRec.shared.pill?.view.showToast(ready ? "Bilder/Transkript kommen gleich – kopiere dann …" : "Video wird noch gespeichert – kopiere gleich …", seconds: 2.5)
        }
        tryCopy()
    }

    private func tryCopy() {
        guard let m = pendingCopy, ready else { return }
        if m == .withContext && context == nil { return }
        pendingCopy = nil
        ScreenRec.shared.copy(url, context: m == .withContext ? context : nil)
    }

    /// Transkript (nur Mikrofon) + Schlüsselbilder → ein Text für Agents
    func buildContext() {
        let url = self.url, dur = self.duration, clicks = self.clicks, sound = self.sound, screen = self.screen
        let mouse = self.mouse, sf = self.screenFrame
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let segs = sound == .mic ? (await ScreenRecTranscript.segments(url) ?? []) : []
            let times = ScreenRecKeyframes.times(duration: dur, clicks: clicks, speech: segs.map(\.start))
            let frames = await ScreenRecKeyframes.extract(url, at: times, clicks: clicks)
            let trails = await ScreenRecTrails.render(url, mouse: mouse, screen: sf)
            let text = ScreenRecKeyframes.compose(duration: dur, screen: screen, sound: sound, segments: segs, frames: frames, trails: trails)
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
}

enum ScreenRecKeyframes {
    static let maxFrames = 14
    static let minGap = 3.0

    static func stamp(_ t: Double) -> String {
        let s = max(0, Int(t)); return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// Zeitpunkte: kurz nach jedem Klick (Ergebnis sichtbar), Anfang jedes Satzes, Anfang und Ende; dicht beieinander
    /// liegende fallen zusammen (Klick gewinnt), höchstens maxFrames (gleichmäßig ausgedünnt)
    static func times(duration: Double, clicks: [Double], speech: [Double]) -> [Double] {
        guard duration > 0.3 else { return [] }
        let end = max(0.2, duration - 0.3)
        var cands: [(t: Double, prio: Int)] = [(min(0.5, end), 1), (end, 1)]
        cands += clicks.map { (min(end, $0 + 0.35), 3) }
        cands += speech.map { (min(end, $0 + 0.2), 2) }
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
    static func extract(_ url: URL, at times: [Double], clicks: [Double]) async -> [ScreenRecKeyframe] {
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
            out.append(ScreenRecKeyframe(time: t, url: f, click: clicks.contains { abs(($0 + 0.35) - t) < 0.4 }))
        }
        return out
    }

    /// Text für den Agent: Sätze und Bilder in zeitlicher Reihenfolge
    static func compose(duration: Double, screen: String, sound: ScreenRecSound, segments: [ScreenRecTranscript.Segment],
                        frames: [ScreenRecKeyframe], trails: [ScreenRecTrail] = []) -> String {
        var rows: [(t: Double, order: Int, line: String)] = []
        for tr in trails { rows.append((tr.start, 2, "[\(stamp(tr.start))–\(stamp(tr.end))] Mausspur (grün = Anfang, rot = Ende): \(tr.url.path)")) }
        for s in segments { rows.append((s.start, 0, "[\(stamp(s.start))] \(s.text)")) }
        for f in frames { rows.append((f.time, 1, "[\(stamp(f.time))] Bild\(f.click ? " (nach Klick)" : ""): \(f.url.path)")) }
        rows.sort { $0.t != $1.t ? $0.t < $1.t : $0.order < $1.order }
        let what = sound == .mic ? "was ich sage und was dabei zu sehen ist" : "was dabei zu sehen ist"
        var head = "Bildschirmaufnahme (\(stamp(duration)), \(screen)) – \(what):"
        if sound == .mic && segments.isEmpty { head += "\n(kein gesprochener Text erkannt)" }
        return ([head] + rows.map(\.line)).joined(separator: "\n")
    }
}

// MARK: - Mausspur: was du mit der Maus zeigst, einkreist oder schreibst
//
// Ein Standbild zeigt nur, wo die Maus gerade IST. Wer mit der Maus etwas einkreist oder ein Wort „schreibt“, braucht
// die Spur – geteilt an den Pausen der Maus (feste Zeitfenster schnitten mitten durch Buchstaben). Flow schreibt die
// Maus während der Aufnahme 30×/s mit, teilt an Pausen ≥ 0,3 s und zeichnet jeden Strich auf das (abgedunkelte) Bild
// des Moments: grün = Anfang, rot = Ende.

struct ScreenRecMouse: Equatable { let t: Double; let x: Double; let y: Double }
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
        let rs = strokes(m)
        guard !rs.isEmpty, screen.width > 0 else { return [] }
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
            let sx = W / screen.width, sy = H / screen.height
            let img = NSImage(size: NSSize(width: W, height: H), flipped: false) { rect in
                NSImage(cgImage: bg, size: rect.size).draw(in: rect)
                NSColor.black.withAlphaComponent(0.55).setFill(); rect.fill(using: .sourceAtop)
                let pts = m[r].map { NSPoint(x: ($0.x - screen.minX) * sx, y: ($0.y - screen.minY) * sy) }
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
        case "--screen-rec-render": return render(dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "aufnahme")
        case "--screen-rec-trail-demo": return trailDemo(args.count > 2 ? args[2] : "")
        case "--screen-rec-context": return contextDemo(args.count > 2 ? args[2] : "", sound: args.count > 3 && args[3] == "system" ? .system : .mic)
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
        check(card.choices == ["Nur Video", "Video + Transkript + Bilder"] && card.preselect == 1, "mit Mikro: Kopier-Wahl, Kontext vorgewählt")
        rd.fileReady()
        card = ScreenRec.doneNotice(rd, copy: {}, again: {})
        check(card.text.contains("Transkript und Bilder werden erstellt"), "danach: Kontext läuft")
        let sysD = ScreenRecDone(url: url, duration: 5, screen: "X", sound: .system)
        check(ScreenRec.doneNotice(sysD, copy: {}, again: {}).choices == ["Nur Video", "Video + Bilder"], "ohne Mikro: Video + Bilder")
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
            let segs = sound == .mic ? (await ScreenRecTranscript.segments(url) ?? []) : []
            let times = ScreenRecKeyframes.times(duration: dur, clicks: [], speech: segs.map(\.start))
            let frames = await ScreenRecKeyframes.extract(url, at: times, clicks: [])
            print(ScreenRecKeyframes.compose(duration: dur, screen: "Test", sound: sound, segments: segs, frames: frames))
            print(String(format: "– %.1f s", Date().timeIntervalSince(t0)))
            rc = frames.isEmpty ? 1 : 0
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return rc
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
            do {
                let screen = screenName.flatMap { n in NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(n) } } ?? ScreenRec.screenUnderMouse()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let disp = content.displays.first(where: { $0.displayID == ScreenRec.displayID(screen) }) else { print("Bildschirm nicht gefunden"); return }
                let cfg = ScreenRec.configuration(display: disp, screen: screen, sound: .none)
                // wie in der App: eigene Fenster raus – außer dem Maus-Leuchten (glow)
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let gw = glow.flatMap { g in content.windows.first { $0.windowID == CGWindowID(g.windowNumber) } }
                if glow != nil { print("Leuchten-Fenster im Inhalt: \(gw != nil)") }
                let st = SCStream(filter: SCContentFilter(display: disp, excludingApplications: me, exceptingWindows: gw.map { [$0] } ?? []), configuration: cfg, delegate: nil)
                let oc = SCRecordingOutputConfiguration(); oc.outputURL = url; oc.outputFileType = .mp4; oc.videoCodecType = .h264
                try st.addRecordingOutput(SCRecordingOutput(configuration: oc, delegate: d))
                try await st.startCapture()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { glow?.stop() }
                try await st.stopCapture()
                for _ in 0..<60 where !d.done { try await Task.sleep(nanoseconds: 100_000_000) }
                let tracks = try await AVURLAsset(url: url).load(.tracks)
                let v = tracks.first { $0.mediaType == .video }
                let size = try await v?.load(.naturalSize) ?? .zero
                print("\(ScreenRec.name(screen)): \(Int(size.width))×\(Int(size.height)), Spuren \(tracks.count) → \(url.path)")
                rc = v != nil && size.width >= CGFloat(disp.width) ? 0 : 1
            } catch { print("Fehler: \(error.localizedDescription)") }
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return rc
    }
}
