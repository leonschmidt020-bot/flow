import AppKit
import Carbon.HIToolbox
import Combine
import ScreenCaptureKit

// MARK: - Meeting-Kontext: steuert das Mitschneiden des Meeting-Fensters passend zur Meeting-Aufnahme
//
// Kern-Anbindung (MeetingController / AppDelegate):
//   MeetingContext.shared.meetingStarted(id:folder:startedAt:callApp:)      nach dem Start der Tonaufnahme
//   MeetingContext.shared.callAppChanged(_:)                                 Anruf-App erst später erkannt
//   MeetingContext.shared.meetingStopped(id:)                                beim Stoppen (vor der Auswertung)
//   MeetingContext.shared.onCaptureChanged = { pill.view.cameraOn = $0 }     Kamera-Symbol in der Pille
//   MeetingContext.shared.toast = { pill.view.showToast($0, seconds: 2.2) }
//
// Datenschutz: nur das EINE Fenster der Meeting-App (SCContentFilter desktopIndependentWindow), nie der ganze Bildschirm;
// Browser/Chat-Apps nur, wenn der Fenstertitel nach Meeting aussieht (aktiver Tab = Meet …); ohne Freigabe
// „Bildschirmaufnahme“ passiert nichts; Stopp mit dem Meeting-Ende und beim Ausschalten. Alles bleibt auf dem Mac.

final class MeetingContext: ObservableObject {
    static let shared = MeetingContext()

    /// Läuft gerade ein Meeting?
    @Published private(set) var meetingID: String?
    /// Soll in DIESEM Meeting mitgeschnitten werden (Schalter in Pille/Hub)
    @Published private(set) var enabled = false
    /// Stream läuft wirklich (Kamera-Symbol)
    @Published private(set) var capturing = false
    @Published private(set) var windowLabel: String?
    /// Deutscher Zustandstext für die Oberfläche („Zoom – Meeting wird mitgeschnitten“, „Kein Meeting-Fenster gefunden“ …)
    @Published private(set) var status = ""
    @Published private(set) var candidates: [MCWindowCandidate] = []
    @Published private(set) var permissionMissing = false

    var onCaptureChanged: ((Bool) -> Void)?
    var toast: ((String) -> Void)?
    /// Vorgabe aus der „Meeting erkannt“-Karte (Chip „Mit Bildschirm“ / „Nur Ton“) für das nächste Meeting
    var nextMeetingScreen: Bool?

    private var session: MCCaptureSession?
    private var folder: URL?
    private var startedAt = Date()
    private var callApp: String?
    private var pinnedWindow: CGWindowID?
    private var timer: Timer?
    private var hotkey: GlobalShortcut?
    private var starting = false
    private var askedPermissionThisRun = false
    private var noWindowNoted = false

    // MARK: Lebenszyklus

    func meetingStarted(id: String, folder: URL, startedAt: Date, callApp: String?) {
        meetingID = id
        self.folder = folder
        self.startedAt = startedAt
        self.callApp = callApp
        pinnedWindow = nil
        noWindowNoted = false
        enabled = nextMeetingScreen ?? MCSettings.shared.captureScreen
        nextMeetingScreen = nil
        // ⌃⌥S nur während einer Aufnahme belegen (sonst gehört die Taste anderen Apps)
        hotkey = GlobalShortcut(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey, id: 21) { [weak self] in self?.markMoment() }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.reevaluate() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if enabled { begin() } else { setStatus("Bildschirm wird nicht mitgeschnitten") }
    }

    func callAppChanged(_ bundleID: String?) {
        guard meetingID != nil, callApp != bundleID, let b = bundleID else { return }
        callApp = b
        if enabled && session == nil { begin() }
    }

    func meetingStopped(id: String) {
        guard meetingID == id else { return }
        timer?.invalidate(); timer = nil
        hotkey = nil
        let s = session
        session = nil
        meetingID = nil
        enabled = false
        setCapturing(false)
        windowLabel = nil
        candidates = []
        setStatus("")
        Task {
            await s?.stop()
            MCOCR.shared.flush()
        }
    }

    /// Schalter „Bildschirm mitschneiden“ für das laufende Meeting (Pause/Weiter)
    func setEnabled(_ on: Bool) {
        guard meetingID != nil, on != enabled else { return }
        enabled = on
        if on { begin() } else { pause(reason: "Pausiert – Bildschirm wird nicht mitgeschnitten") }
        toast?(on ? "Bildschirm wird mitgeschnitten" : "Bildschirm-Mitschnitt pausiert")
    }

    /// Fenster per Hand wählen (Wechsel erlaubt)
    func choose(windowID: CGWindowID) {
        pinnedWindow = windowID
        guard meetingID != nil else { return }
        if !enabled { enabled = true }
        Task { @MainActor in
            guard let w = await MCWindowPicker.scWindow(windowID) else { return }
            if let s = self.session { await s.switchTo(w); self.windowLabel = self.label(w); self.setStatus(self.captureStatus()) }
            else { self.begin() }
        }
    }

    // MARK: Aufnahme starten/pausieren

    private func begin() {
        guard let id = meetingID, let folder, session == nil, !starting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            permissionMissing = true
            setStatus("Freigabe „Bildschirmaufnahme“ fehlt")
            askPermission()
            return
        }
        permissionMissing = false
        starting = true
        Task { @MainActor in
            defer { self.starting = false }
            let cands = await MCWindowPicker.candidates(meetingApp: self.callApp)
            self.candidates = cands
            guard self.meetingID == id, self.enabled else { return }
            let pick: MCWindowCandidate?
            if let pin = self.pinnedWindow { pick = cands.first { $0.id == pin } }
            else { pick = cands.first { $0.matchesMeetingApp } }
            guard let c = pick, let w = await MCWindowPicker.scWindow(c.id) else {
                self.setStatus(self.callApp == nil ? "Keine Meeting-App erkannt – Fenster wählen" : "Kein Meeting-Fenster gefunden")
                if !self.noWindowNoted { self.noWindowNoted = true; log("Meeting-Kontext: kein passendes Fenster (App \(self.callApp ?? "–"))") }
                return
            }
            let s = MCCaptureSession(meetingID: id, folder: folder, startedAt: self.startedAt, window: w, saveVideo: MCSettings.shared.saveVideo)
            s.onFrameSaved = { [weak self] _ in self?.refreshStatus() }
            s.onStopped = { [weak self, weak s] _ in
                guard let self, let s, self.session === s else { return }
                self.session = nil; self.setCapturing(false)
                self.setStatus("Meeting-Fenster ist weg – suche …")
                Task { await s.stop() }
            }
            do {
                try await s.start()
                guard self.meetingID == id, self.enabled else { await s.stop(); return }
                self.session = s
                self.windowLabel = self.label(w)
                self.setCapturing(true)
                self.setStatus(self.captureStatus())
            } catch {
                log("Meeting-Kontext: Start fehlgeschlagen \(error)")
                self.setStatus("Mitschnitt startet nicht")
                if !CGPreflightScreenCaptureAccess() { self.permissionMissing = true }
            }
        }
    }

    private func pause(reason: String) {
        let s = session
        session = nil
        setCapturing(false)
        setStatus(reason)
        Task { await s?.stop() }
    }

    /// Alle 5 s: Fenster noch da? Titel noch Meeting (Browser-Tab gewechselt → Pause)? Besseres Fenster aufgetaucht?
    private func reevaluate() {
        guard meetingID != nil, enabled else { return }
        if !CGPreflightScreenCaptureAccess() { if session != nil { pause(reason: "Freigabe „Bildschirmaufnahme“ fehlt") }; permissionMissing = true; return }
        if session == nil { begin(); return }
        Task { @MainActor in
            let cands = await MCWindowPicker.candidates(meetingApp: self.callApp)
            self.candidates = cands
            guard let s = self.session else { return }
            let curID = s.window.windowID
            if let pin = self.pinnedWindow {
                if !cands.contains(where: { $0.id == pin }) { self.pinnedWindow = nil; self.pause(reason: "Gewähltes Fenster ist zu") }
                return
            }
            guard let cur = cands.first(where: { $0.id == curID }), cur.matchesMeetingApp else {
                // Browser: aktiver Tab ist nicht mehr das Meeting → nichts anderes aufnehmen
                self.pause(reason: "Meeting-Fenster nicht sichtbar – pausiert")
                return
            }
            if let best = cands.first(where: { $0.matchesMeetingApp }), best.id != curID, best.score > cur.score + 4,
               let w = await MCWindowPicker.scWindow(best.id) {
                await s.switchTo(w); self.windowLabel = self.label(w)
            } else if let w = await MCWindowPicker.scWindow(curID) {
                await s.windowResized(w)
            }
            self.setStatus(self.captureStatus())
        }
    }

    // MARK: Moment merken (⌃⌥S)

    func markMoment() {
        guard let id = meetingID else { toast?("Kein Meeting läuft"); return }
        let t = Date().timeIntervalSince(startedAt)
        let live = MeetingStore.shared.meeting(id).map { MCText.spoken($0, from: t - 30, to: t, maxChars: 1500) } ?? ""
        let mid = "m\(Int(t))_\(UUID().uuidString.prefix(4))"
        toast?(session != nil ? "★ Moment gemerkt – mit Bildschirmfoto" : "★ Moment gemerkt")
        NSSound(named: "Tink")?.play()
        let s = session
        Task {
            let fr = await s?.saveMoment(t: t)
            MCStore.shared.mutate(id) { l in l.moments.append(MCMoment(id: mid, t: t, frame: fr?.id, liveText: live)) }
            log("Meeting-Kontext: Moment gemerkt bei \(Meeting.stamp(t))\(fr != nil ? " + Bild" : "")")
        }
    }

    // MARK: Freigabe (erst fragen, wenn gebraucht)

    private func askPermission() {
        guard !askedPermissionThisRun else { return }
        askedPermissionThisRun = true
        VFNotify.shared.show(VFNotice(
            id: "bildschirm_freigabe", title: "Bildschirm mitschneiden?",
            text: "Damit Flow sieht, was im Meeting gezeigt wird, braucht es „Bildschirmaufnahme“. Nur das Meeting-Fenster, alles bleibt auf dem Mac.",
            illustration: "illu_meeting_erkannt", fallbackSymbol: "rectangle.dashed.badge.record",
            primary: ("Freigeben", { MeetingContext.requestPermission() }),
            secondary: ("Nur Ton", { [weak self] in self?.enabled = false; self?.setStatus("Bildschirm wird nicht mitgeschnitten") }),
            timeout: 30))
    }

    /// Systemdialog (beim ersten Mal) bzw. Systemeinstellungen öffnen
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
        }
        log("Meeting-Kontext: Freigabe Bildschirmaufnahme angefragt (jetzt: \(CGPreflightScreenCaptureAccess()))")
    }

    // MARK: Hilfen

    private func label(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "Fenster"
        let t = (w.title ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == app ? app : "\(app) – \(t)"
    }

    private func captureStatus() -> String {
        let n = meetingID.map { MCStore.shared.log($0).frames.count } ?? 0
        return "\(windowLabel ?? "Meeting-Fenster") · \(n) Bild\(n == 1 ? "" : "er")"
    }

    private func setStatus(_ s: String) { if status != s { status = s } }

    private func setCapturing(_ on: Bool) {
        guard capturing != on else { return }
        capturing = on
        onCaptureChanged?(on)
    }

    /// Für Hub/Pille: Status neu (nach neuem Bild)
    func refreshStatus() { if session != nil { setStatus(captureStatus()) } }

    /// Kontext für Fragen an das Meeting (erkannter Text der Bilder mit Zeit) – leer, wenn keine Bilder
    static func askContext(_ meetingID: String, maxChars: Int = 12_000) -> String {
        let l = MCStore.shared.log(meetingID)
        let frames = l.frames.filter { !($0.ocr ?? "").isEmpty }
        guard !frames.isEmpty || !l.moments.isEmpty else { return "" }
        var out = "Auf dem Bildschirm gezeigt (erkannter Text der Schlüsselbilder):\n"
        for f in frames {
            let t = (f.ocr ?? "").replacingOccurrences(of: "\n", with: " · ")
            out += "[\(Meeting.stamp(f.t))]\(f.isMoment ? " ★" : "") \(t.prefix(700))\n"
            if out.count > maxChars { break }
        }
        if !l.moments.isEmpty { out += "Wichtig markierte Momente: " + l.moments.map { Meeting.stamp($0.t) }.joined(separator: ", ") + "\n" }
        return out + "\n"
    }
}
