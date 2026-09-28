import AppKit
import SwiftUI
import AVFoundation
import Carbon.HIToolbox

@main
enum Main {
    static func main() {
        umask(0o077)   // alles, was Flow anlegt, kann nur der eigene Benutzer lesen
        signal(SIGPIPE, SIG_IGN)   // Pipe zu einem beendeten Kindprozess darf Flow nicht beenden
        let args = CommandLine.arguments
        // Der Schutz-Test darf den echten Datenordner nicht einmal anlegen → vor Paths.secure() (das legt ihn an)
        if args.count >= 2, args[1] == "--selftest-guard", let code = CLI.run(args) { exit(code) }
        Paths.secure()
        if args.count >= 2, let code = CLI.run(args) { exit(code) }
        // Nur die installierte App darf diktieren (ein Entwickler-Build ohne Bundle würde sonst doppelt einfügen) …
        // (Bundle-ID ist über build.sh BUNDLE_ID wählbar – geprüft wird nur, dass wir aus einem .app-Paket laufen.)
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app",
           ProcessInfo.processInfo.environment["FLOW_DEV"] != "1" {
            FileHandle.standardError.write("Kein App-Bundle – starte ~/Applications/Flow.app (oder FLOW_DEV=1).\n".data(using: .utf8)!)
            exit(2)
        }
        // … und immer nur EINE Instanz (Sperrdatei, hält bis zum Prozessende).
        if !AppLock.acquire(Paths.base.appendingPathComponent("app.lock").path) {
            log("Flow läuft schon – zweite Instanz beendet sich")
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Sperrdatei für „nur eine Instanz“ (flock, hält bis zum Prozessende – auch bei Absturz gibt macOS sie frei).
/// Eigene Funktion, damit das Release-Tor genau diese Logik prüfen kann (`--selftest-lock`).
enum AppLock {
    nonisolated(unsafe) private(set) static var heldFD: Int32 = -1
    /// true = Sperre erhalten (Deskriptor bleibt offen), false = eine andere Instanz hält sie (oder Datei nicht anlegbar)
    static func acquire(_ path: String) -> Bool {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        if fd < 0 { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        heldFD = fd
        return true
    }
    /// Nur für Tests: Sperre wieder freigeben
    static func release() { if heldFD >= 0 { close(heldFD); heldFD = -1 } }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private(set) var pill: PillController!
    private(set) var dictation: DictationController!
    private(set) var meeting: MeetingController!
    private let hotkey = HotkeyMonitor()
    private var meetingShortcut: GlobalShortcut?
    private var hotkeyRetry: Timer?
    private var retentionTimer: Timer?
    private var modelState: Transcriber.State = .notLoaded
    private var settingsWindow: SettingsWindowController?

    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    func applicationWillTerminate(_ n: Notification) { Health.shared.markCleanExit(); WhisperEngine.shared.stop() }

    func applicationDidFinishLaunching(_ n: Notification) {
        log("Flow startet (\(Bundle.main.bundlePath), \(AppVersion.line))")
        // Zuerst: voriger Lauf sauber beendet? neue Absturzberichte? Dann Lebenszeichen alle 30 s (Health-Gate beim Update)
        Health.shared.begin()
        Health.shared.startTimers()
        VF.registerFonts()
        _ = VFStats.shared          // Statistik früh anlegen (einmalig aus dem Verlauf befüllt)
        AppDelegate.registerHubPages()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        pill = PillController()
        dictation = DictationController(pill: pill)
        meeting = MeetingController(pill: pill)
        dictation.restingMode = { [weak self] in self?.meeting.restingPillMode ?? .idle }
        dictation.callActive = { [weak self] in self?.meeting.callActive ?? false }
        Health.shared.busyProbe = { Updater.appBusy }
        meeting.askOver = { app, answer in
            VFNotify.shared.meetingOver(app: app, end: { answer(true) }, keep: { answer(false) }, dismissed: { answer(nil) })
        }

        hotkey.handsFreeActive = { [weak self] in self?.dictation.isHandsFree ?? false }
        hotkey.onEvent = { [weak self] e in
            MemorySaver.shared.hotkey(e)   // geparkte Modelle schon beim Fn-Druck starten (parallel zum Sprechen)
            DispatchQueue.main.async { self?.dictation.handle(e) }
        }

        wirePill()
        setupMainMenu()
        setupStatusItem()
        // Neuer Benutzer: Freigaben fragt der Willkommens-Ablauf Schritt für Schritt ab (statt drei Dialoge auf einmal)
        if Settings.shared.onboardingDone { requestPermissions() } else { VoiceFlowWindow.shared.show() }
        startHotkey()

        meetingShortcut = GlobalShortcut(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey, id: 1) { [weak self] in
            self?.meeting.toggle()
        }

        // Fernsteuerung (Hammerspoon, Stream Deck): `flow dictate|meeting|open|status`.
        // Aufnahme-Befehle brauchen den geheimen Schlüssel aus ~/.config/flow/token (nur der eigene Benutzer kann ihn lesen).
        let dnc = DistributedNotificationCenter.default()
        let token = Remote.token()
        dnc.addObserver(forName: .init("app.flowdictation.flow.dictate"), object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? String) == token else { log("Fernsteuerung: dictate ohne gültigen Schlüssel ignoriert"); return }
            if case .recording = self.dictation.state { self.dictation.finish() } else { MemorySaver.shared.dictationWillStart(); self.dictation.start(handsFree: true) }
        }
        dnc.addObserver(forName: .init("app.flowdictation.flow.meeting"), object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? String) == token else { log("Fernsteuerung: meeting ohne gültigen Schlüssel ignoriert"); return }
            let wasRecording = self.meeting.isRecording
            self.meeting.toggle()
            if !wasRecording && self.meeting.isRecording { self.pill.view.showToast("Meeting-Aufnahme gestartet (Fernsteuerung)", seconds: 3) }
        }
        // Mikrofontest: 1,5 s aufnehmen, nur Pegel ins Log (nichts wird eingefügt oder gespeichert)
        dnc.addObserver(forName: .init("app.flowdictation.flow.mictest"), object: nil, queue: .main) { n in
            guard (n.object as? String) == token else { return }
            let mc = MicCapture(); var peak: Float = 0; var count = 0
            mc.onSamples = { s in count += s.count; peak = max(peak, Dictation.peak(s)) }
            do { try mc.start(deviceUID: Settings.shared.micUID) } catch { log("Mikrofontest: Start fehlgeschlagen \(error)"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                mc.stop()
                log(String(format: "Mikrofontest: %d Samples, Spitze %.4f", count, peak))
            }
        }
        dnc.addObserver(forName: .init("app.flowdictation.flow.open"), object: nil, queue: .main) { n in
            VoiceFlowWindow.shared.show(VFSection(rawValue: (n.object as? String) ?? "") ?? .diktat)
        }
        dnc.addObserver(forName: .init("app.flowdictation.flow.show"), object: nil, queue: .main) { [weak self] _ in self?.meeting.showWindow() }
        dnc.addObserver(forName: .init("app.flowdictation.flow.settings"), object: nil, queue: .main) { [weak self] _ in self?.showSettings() }
        dnc.addObserver(forName: .init("app.flowdictation.flow.enroll"), object: nil, queue: .main) { _ in VoiceFlowWindow.shared.show(.training) }
        dnc.addObserver(forName: .init("app.flowdictation.flow.status"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let p = self.permissionStatus
            log("Status: mic=\(p.mic) ax=\(p.accessibility) input=\(p.inputMonitoring) tap=\(p.hotkeyActive) modell=\(self.modelState) whisper=\(WhisperEngine.shared.ready)\(WhisperEngine.shared.parked ? "(geparkt)" : "") fn0=\(FnKeySetting.isNothing)")
        }
        #if DEBUG
        // Nur Entwickler-Build: Test-Befehle (Text einfügen, Bildschirm auslesen, Meeting simulieren)
        dnc.addObserver(forName: .init("app.flowdictation.flow.fakemeeting"), object: nil, queue: .main) { [weak self] _ in self?.meeting.simulateDetected(name: "Zoom") }
        dnc.addObserver(forName: .init("app.flowdictation.flow.fakecallend"), object: nil, queue: .main) { [weak self] _ in self?.meeting.simulateCallEnded() }
        dnc.addObserver(forName: .init("app.flowdictation.flow.axprobe"), object: nil, queue: .main) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AXProbe.run() } }
        dnc.addObserver(forName: .init("app.flowdictation.flow.inserttest"), object: nil, queue: .main) { n in
            let text = (n.object as? String) ?? "Test"
            if case .pasted = Inserter.insert(text) { CorrectionLearner.shared.watch(inserted: text) }
        }
        #endif

        Transcriber.shared.onState = { [weak self] s in self?.modelStateChanged(s) }
        Task { try? await Transcriber.shared.load() }
        Task { await VoiceID.shared.prepare() }
        if WhisperEngine.available { WhisperEngine.shared.start() }
        // Hybrid-Erkennung: Parakeet zuerst, Whisper nur bei Unsicherheit/Wörterbuch-Wörtern
        HybridRecognizer.parakeet = { try await Transcriber.shared.transcribeScored($0) }
        HybridRecognizer.whisper = { s, ctx, lang in
            try await WhisperEngine.shared.dictate(Transcriber.normalizedGentle(s), context: ctx, language: lang).text
        }
        HybridRecognizer.whisperReady = { WhisperEngine.shared.ready }
        TempoGuard.install()   // „Tempo-Garantie“ (Einstellungen → Allgemein); aus = unverändert
        HybridRecognizer.onLearned = { entries in
            DispatchQueue.main.async {
                let known = Set(Settings.shared.dictionary.map { $0.heard.lowercased() })
                let new = entries.filter { !known.contains($0.heard.lowercased()) }
                guard !new.isEmpty else { return }
                Settings.shared.dictionary.append(contentsOf: new)
                Settings.shared.save()
                log("Verhörer gelernt: " + new.map { "„\($0.heard)“→\($0.write)" }.joined(separator: ", "))
            }
        }
        Task { await FastVoiceMask.shared.prepare() }
        // Aufräumen (1.5.6): automatisch gelernte echte Einzelwörter nur als Hinweis (z. B. „Fan“ → Kitanet hätte jedes „Fan“ ersetzt),
        // und je gehörtem Wort nur ein automatisch gelerntes Ziel (nicht „Fan“ → Kitanet UND KiTaNet).
        do {
            var dict = Settings.shared.dictionary, changed = false, heard = Set<String>()
            dict = dict.filter { e in
                let k = e.heard.lowercased()
                if e.learned == true, heard.contains(k) { changed = true; return false }
                heard.insert(k); return true
            }
            for i in dict.indices where dict[i].learned == true && dict[i].vocabOnly == nil
                && !dict[i].heard.contains(" ") && AliasLearner.realWords(dict[i].heard) {
                dict[i].vocabOnly = true; changed = true
            }
            if changed { Settings.shared.dictionary = dict; Settings.shared.save(); log("Wörterbuch aufgeräumt: echte Wörter nur noch als Hinweis") }
        }
        MemorySaver.shared.start()
        CorrectionLearner.shared.onCandidate = { [weak self] pairs in
            VoiceAdapter.shared.dictationCorrected()   // korrigiertes Diktat nicht fürs Stimmmodell lernen
            for p in pairs { SmartFlow.shared.noteCorrection(old: p.old, new: p.options.first ?? "", saved: false) }
            self?.askToLearn(pairs)
        }
        // Meldungskarten wachsen aus der Pille
        VFNotify.shared.pillAnchor = { [weak self] in self?.pill.view.capsuleRectInScreen }
        CommandMode.shared.presetResolver = { TransformStore.shared.match($0)?.instruction }
        meeting.notifyDetected = { app, accept, dismiss in
            // Chips „Mit Bildschirm“ / „Nur Ton“ → gilt für dieses Meeting
            VFNotify.shared.show(.meetingDetectedWithScreen(app: app, accept: { screen in
                MeetingContext.shared.nextMeetingScreen = screen; accept()
            }, dismiss: dismiss))
        }
        // Meeting-Kontext: Kamera-Symbol in der Pille, solange das Meeting-Fenster mitgeschnitten wird
        MeetingContext.shared.onCaptureChanged = { [weak self] on in self?.pill.view.cameraOn = on }
        MeetingContext.shared.toast = { [weak self] s in self?.pill.view.showToast(s, seconds: 2.2) }
        meeting.notifyReady = { title, id in
            VFNotify.shared.show(.transcriptReady(title: title, open: { MeetingStore.shared.selectedID = id; VoiceFlowWindow.shared.show(.notetaker) }))
        }
        meeting.startDetection()
        // „Flow lernt mit“: lernt im Hintergrund aus Diktaten/Meetings, Vorschläge aus der Pille
        SmartFlow.shared.start()
        SmartPillBadge.shared.start()
        SharedInboxBadge.shared.start()
        PartnerVocab.shared.start()          // gemeinsame Namen mit dem Partner (ClipVault vocab)
        UpdateBadge.shared.start()
        Updater.shared.start()
        // Beim letzten Beenden unterbrochene Auswertungen fortsetzen
        for m in MeetingStore.shared.meetings where m.status == .failed && (m.progressNote ?? "").hasPrefix("Unterbrochen")
            && FileManager.default.fileExists(atPath: m.micURL.path) {
            log("Setze unterbrochene Auswertung fort: \(m.id)")
            meeting.reprocess(meetingID: m.id)
        }
        // Audiodateien: Unterbrochenes fortsetzen, Eingangsordner, Ablage auf der Pille
        AudioImport.shared.start(pill: pill)
        // Alte Transkripte aufräumen: beim Start und dann stündlich
        MeetingStore.shared.cleanup()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in MeetingStore.shared.cleanup() }
    }

    private func wirePill() {
        let v = pill.view
        v.onClick = { [weak self] in MemorySaver.shared.dictationWillStart(); self?.dictation.start(handsFree: true) }
        v.onStop = { [weak self] in
            guard let self else { return }
            if case .recording = self.dictation.state { self.dictation.finish() }
        }
        v.onCancel = { [weak self] in self?.dictation.cancel(silent: false) }
        v.onPromptAccept = { [weak self] in self?.meeting.acceptPrompt() }
        v.onPromptDismiss = { [weak self] in self?.meeting.dismissPrompt() }
        v.onMeetingClick = { [weak self] in self?.meeting.showWindow() }
        v.onQuestionAccept = { [weak self] in let h = self?.questionHandler; self?.questionHandler = nil; h?(true) }
        v.languageShort = Settings.shared.languageMode.short
        v.allVoices = !Settings.shared.onlyMyVoice
        v.onLanguageClick = { [weak self] in self?.showLanguageMenu() }
        v.onQuestionDismiss = { [weak self] in let h = self?.questionHandler; self?.questionHandler = nil; h?(false) }
        v.menuProvider = { [weak self] in self?.buildMenu(forPill: true) ?? NSMenu() }
    }

    // MARK: Sprache (Weltkugel an der Pille)

    private func showLanguageMenu() {
        let m = NSMenu()
        let head = NSMenuItem(title: "Sprache fürs Diktat", action: nil, keyEquivalent: ""); head.isEnabled = false
        m.addItem(head)
        for mode in LanguageMode.allCases {
            let i = NSMenuItem(title: mode.label, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = mode.rawValue
            i.state = Settings.shared.languageMode == mode ? .on : .off
            m.addItem(i)
        }
        // Wer darf diktieren? – „Alle Stimmen“ = Stimmfilter aus (mehrere Personen, z. B. zusammen mit dem Bruder)
        m.addItem(.separator())
        let head2 = NSMenuItem(title: "Wer darf diktieren?", action: nil, keyEquivalent: ""); head2.isEnabled = false
        m.addItem(head2)
        let mine = NSMenuItem(title: "Nur meine Stimme", action: #selector(pickVoiceFilter(_:)), keyEquivalent: "")
        mine.target = self; mine.tag = 1; mine.state = Settings.shared.onlyMyVoice ? .on : .off
        if !VoiceID.isEnrolled { mine.isEnabled = false; mine.title = "Nur meine Stimme (erst Stimme einlernen)" }
        m.addItem(mine)
        let all = NSMenuItem(title: "Alle Stimmen (mehrere Personen)", action: #selector(pickVoiceFilter(_:)), keyEquivalent: "")
        all.target = self; all.tag = 0; all.state = Settings.shared.onlyMyVoice ? .off : .on
        m.addItem(all)
        let r = pill.view.capsuleRectInScreen
        m.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 6), in: nil)
    }

    @objc private func pickVoiceFilter(_ sender: NSMenuItem) {
        let on = sender.tag == 1
        Settings.shared.onlyMyVoice = on
        Settings.shared.save()
        pill.view.allVoices = !on
        pill.view.showToast(on ? "Nur deine Stimme wird mitgeschrieben" : "Alle Stimmen werden mitgeschrieben", seconds: 2.2)
        log("Stimmfilter: \(on ? "nur meine Stimme" : "alle Stimmen")")
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = LanguageMode(rawValue: raw) else { return }
        Settings.shared.languageMode = mode
        pill.view.languageShort = mode.short
        pill.view.showToast(mode.label, seconds: 1.8)
        log("Sprache: \(mode.rawValue)")
    }

    // MARK: Lernen – Pille fragt „merken?“

    private var pendingLearn: [CorrectionLearner.Suggestion] = []
    /// Wer die aktuelle Pillen-Frage beantwortet bekommt (Lernen oder „Meeting vorbei?“)
    var questionHandler: ((Bool) -> Void)?

    private func askToLearn(_ items: [CorrectionLearner.Suggestion]) {
        let wasEmpty = pendingLearn.isEmpty
        for it in items {
            // Gleiches Wort schon offen (z. B. Zwischenstand beim Tippen) → Vorschläge zusammenführen statt doppelt fragen
            if let i = pendingLearn.firstIndex(where: { $0.old.lowercased() == it.old.lowercased() }) {
                var merged = it.options
                for o in pendingLearn[i].options where !merged.contains(o) { merged.append(o) }
                pendingLearn[i].options = Array(merged.prefix(3))
                if i == 0 && !wasEmpty { showNextLearnQuestion() }   // sichtbare Karte aktualisieren
            } else {
                pendingLearn.append(it)
            }
        }
        if wasEmpty { showNextLearnQuestion() }
    }

    private func showNextLearnQuestion() {
        guard let p = pendingLearn.first else { return }
        switch pill.view.mode {
        case .idle, .meeting, .question: break
        default:
            // Pille gerade beschäftigt (Diktat läuft) → später nochmal
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showNextLearnQuestion() }
            return
        }
        VFNotify.shared.wordLearned(old: p.old, options: p.options,
                                    save: { [weak self] choice in self?.answerLearn(save: true, choice: choice) },
                                    skip: { [weak self] in self?.answerLearn(save: false, silent: true) })
    }

    private func answerLearn(save: Bool, choice: String? = nil, silent: Bool = false) {
        guard !pendingLearn.isEmpty else { return }
        let p = pendingLearn.removeFirst()
        if save {
            CorrectionLearner.remember(old: p.old, new: choice ?? p.options[0])
        } else {
            for o in p.options { CorrectionLearner.shared.rejected.insert("\(p.old)\u{1}\(o)") }
        }
        if !silent { pill.view.showToast(save ? "Gespeichert – schreibe ich ab jetzt so" : "Nicht gespeichert", seconds: 2) }
        if !pendingLearn.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showNextLearnQuestion() }
        }
    }

    private func modelStateChanged(_ s: Transcriber.State) {
        modelState = s
        switch s {
        case .loading(let p):
            if case .idle = pill.view.mode { pill.view.mode = .loading(p) }
            else if case .loading = pill.view.mode { pill.view.mode = .loading(p) }
        case .ready:
            if case .loading = pill.view.mode {
                pill.view.mode = meeting.restingPillMode
                pill.view.showToast("Bereit – Fn halten zum Sprechen", seconds: 2.5)
            }
        case .failed(let e):
            if case .loading = pill.view.mode { pill.view.mode = .idle }
            pill.view.showToast("Modell-Fehler: \(e.prefix(40))", seconds: 4)
        case .notLoaded: break
        }
    }

    // MARK: Berechtigungen

    /// Willkommen abgeschlossen → fehlende Freigaben jetzt anfragen, Hotkey neu versuchen
    func onboardingFinished() {
        requestPermissions()
        startHotkey()
        log("Willkommen abgeschlossen (Name: \(Settings.shared.myName), Sprache: \(Settings.shared.languageMode.rawValue))")
    }

    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in log("Mikrofon: \(ok)") }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }

    func startHotkey() {
        hotkeyRetry?.invalidate()
        if hotkey.start() { return }
        // Nach der Freigabe „Eingabeüberwachung“ automatisch nochmal versuchen.
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            if self?.hotkey.start() == true { t.invalidate() }
        }
    }

    struct PermissionStatus {
        let mic: Bool, accessibility: Bool, inputMonitoring: Bool, hotkeyActive: Bool
    }

    var permissionStatus: PermissionStatus {
        PermissionStatus(mic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         accessibility: AXIsProcessTrusted(),
                         inputMonitoring: CGPreflightListenEventAccess(),
                         hotkeyActive: hotkey.isRunning)
    }

    static func openPrivacyPane(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }

    // MARK: Menü

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Flow")
            b.image?.isTemplate = true
        }
        let m = NSMenu()
        m.delegate = self
        statusItem.menu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for it in buildMenu(forPill: false).items { it.menu?.removeItem(it); menu.addItem(it) }
    }

    private func buildMenu(forPill: Bool) -> NSMenu {
        let m = NSMenu()
        let status: String
        switch modelState {
        case .ready: status = "Bereit · Parakeet lokal"
        case .loading(let p): status = "Sprachmodell lädt … \(Int(p * 100)) %"
        case .failed: status = "Sprachmodell-Fehler"
        case .notLoaded: status = "Sprachmodell startet …"
        }
        let head = NSMenuItem(title: status, action: nil, keyEquivalent: ""); head.isEnabled = false
        m.addItem(head)
        let p = permissionStatus
        if !(p.mic && p.accessibility && p.inputMonitoring && p.hotkeyActive) {
            m.addItem(item("⚠︎ Berechtigungen fehlen – beheben …", #selector(openPermissions)))
        }
        m.addItem(.separator())
        m.addItem(item("Flow öffnen …", #selector(showMain)))
        m.addItem(item("Diktat starten (Freihand)", #selector(startHandsFree)))
        let meetItem = item(meeting.isRecording ? "Meeting beenden" : "Meeting aufnehmen", #selector(toggleMeeting))
        meetItem.keyEquivalent = "m"; meetItem.keyEquivalentModifierMask = [.control, .option]
        m.addItem(meetItem)
        if meeting.isRecording {
            let scr = item("Bildschirm mitschneiden", #selector(toggleScreenCapture))
            scr.state = MeetingContext.shared.enabled ? .on : .off
            m.addItem(scr)
            let mom = item("★ Moment merken", #selector(markMoment))
            mom.keyEquivalent = "s"; mom.keyEquivalentModifierMask = [.control, .option]
            m.addItem(mom)
        }
        m.addItem(item("Meetings & Transkripte …", #selector(showMeetings)))
        m.addItem(.separator())

        let posMenu = NSMenu()
        if let screen = pill.currentScreen {
            let cur = Settings.shared.placement(for: screen)
            for pr in PillPreset.allCases {
                let i = NSMenuItem(title: pr.label, action: #selector(setPreset(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = pr.rawValue
                i.state = cur.preset == pr ? .on : .off
                posMenu.addItem(i)
            }
            posMenu.addItem(.separator())
            let hint = NSMenuItem(title: "Tipp: Pille einfach mit der Maus ziehen", action: nil, keyEquivalent: ""); hint.isEnabled = false
            posMenu.addItem(hint)
        }
        let pos = NSMenuItem(title: "Position auf diesem Bildschirm", action: nil, keyEquivalent: "")
        pos.submenu = posMenu
        m.addItem(pos)
        m.addItem(item(VoiceID.isEnrolled ? "Stimme neu einlernen …" : "Stimme einlernen (nur meine Stimme) …", #selector(enrollVoice)))
        m.addItem(item("Einstellungen …", #selector(showSettings), key: ","))
        m.addItem(item("Fehlerbericht senden …", #selector(sendReport)))
        if !forPill {
            m.addItem(.separator())
            m.addItem(item("Flow beenden", #selector(quit), key: "q"))
        }
        return m
    }

    private func item(_ t: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func startHandsFree() { dictation.start(handsFree: true) }
    @objc private func enrollVoice() { VoiceFlowWindow.shared.show(.training) }
    @objc private func toggleMeeting() { meeting.toggle() }
    @objc private func toggleScreenCapture() { MeetingContext.shared.setEnabled(!MeetingContext.shared.enabled) }
    @objc private func markMoment() { MeetingContext.shared.markMoment() }
    @objc private func showMeetings() { meeting.showWindow() }
    @objc private func setPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pr = PillPreset(rawValue: raw),
              let s = pill.currentScreen else { return }
        pill.setPlacement(pr, for: s)
    }
    @objc private func sendReport() {
        Diagnose.send { [weak self] msg in self?.pill.view.showToast(msg, seconds: 3) }
    }
    @objc func showSettings() { VoiceFlowWindow.shared.show(.einstellungen) }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: AppVersion.short,
            .version: [AppVersion.git, AppVersion.build].compactMap { $0 }.joined(separator: " · "),
            .credits: NSAttributedString(string: "Privat, alles lokal. Daten: \(Paths.baseDisplay)"),
        ])
    }
    @objc func showMain() { VoiceFlowWindow.shared.show() }
    @objc private func openPermissions() { VFHub.shared.openSettings("general"); VoiceFlowWindow.shared.show() }

    /// Finder → Öffnen mit → Flow (Audio/Video): transkribieren + Notetaker zeigen
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            if !AudioImport.shared.open(urls, origin: .finder).isEmpty { VoiceFlowWindow.shared.show(.notetaker) }
        }
    }

    /// Doppelklick auf die App / Spotlight, während sie schon läuft → Hauptfenster
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        VoiceFlowWindow.shared.show()
        return true
    }

    /// Hub-Seiten der Seiten-Agenten + Einstellungs-Modal registrieren
    static func registerHubPages() {
        VFHub.pageProvider = { s in
            switch s {
            case .woerterbuch: return AnyView(VFDictionaryPage())
            case .snippets: return AnyView(VFSnippetsPage())
            case .stil: return AnyView(VFStylePage())
            case .transforms: return AnyView(VFTransformsPage())
            case .scratchpad: return AnyView(VFScratchpadPage())
            case .gelernt: return AnyView(SmartLearnedPage())
            case .einstellungen:
                return AnyView(VFSettingsModal(section: VFSettingsModal.Section(rawValue: VFHub.shared.settingsTarget ?? "") ?? .general,
                                               onClose: { VFHub.shared.closeSettings() }))
            default: return nil
            }
        }
    }

    /// App-Menü + Bearbeiten-Menü (ohne das gehen ⌘C/⌘V/⌘A in Textfeldern nicht)
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(item("Über Flow", #selector(showAbout)))
        app.addItem(.separator())
        app.addItem(item("Einstellungen …", #selector(showSettings), key: ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Flow ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Fenster schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(item("Flow beenden", #selector(quit), key: "q"))
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    @objc private func quit() {
        // Laufendes Meeting sichern (Status „wird ausgewertet“) und sofort beenden – ausgewertet wird beim nächsten Start
        if meeting.isRecording { meeting.stop() }
        WhisperEngine.shared.stop()
        NSApp.terminate(nil)
    }
}

/// Schlüssel für die Fernsteuerung (flow liest ihn und schickt ihn mit)
enum Remote {
    static let url = Paths.base.appendingPathComponent("token")
    static func token() -> String {
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        let t = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }
}
