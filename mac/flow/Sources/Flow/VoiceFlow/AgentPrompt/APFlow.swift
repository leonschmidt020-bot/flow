import AppKit
import ApplicationServices

// MARK: - Agent-Prompt: Ablauf (Diktat → Karte → Prompt → Zwischenablage/Einfügen/Verlauf)
//
// Einstieg aus DictationController.collect() (direkt nach `TextCleaner.applyRules`, VOR den Sprachbefehlen):
//
//   if await APFlow.shared.consume(cleaned, duration: dur, useMouse: ms > 0, finish: { … Pille zurück … }) { return }
//
//   true  = „Prompt: …“ erkannt → nichts einfügen. Das Original (ohne Auslöser) liegt SOFORT als „Diktat (Original)“
//           in der Zwischenablage/ClipVault und im Diktat-Verlauf, dann wird gebaut. Fertig → Prompt als „Agent-Prompt“
//           in die Zwischenablage + prompts/ (mit Original). Abbruch/Fehler → Karte mit „Original einfügen/kopieren“.
//   false = normales Diktat. Nach dem Einfügen: `APFlow.shared.offerIfLong(text:duration:bundleID:)` – bei einem langen
//           Auftrag an einen Agenten erscheint leise die Vorschlags-Karte („Daraus einen Agent-Prompt machen?“).
//
// Claude-CLI ist optional: Ohne sie baut Flow auf Zuruf einen Prompt nach Regeln (APRules – sortiert die Sätze in
// Ziel/Kontext/Aufgabe/Regeln/Offene Punkte, verliert kein Detail, formuliert aber nichts um); die Karte sagt dann leise
// „ohne KI“. Automatische Vorschläge gibt es nur MIT Claude: der Regel-Umbau lohnt keine ungefragte Unterbrechung
// (der Text steht ja schon da) – wer ihn will, sagt „Prompt: …“.
//
// Nie: Zwischenablage-Inhalte an Claude schicken. Kontext = App, Fenstertitel (nur Entwickler-/Agenten-Apps) und
// markierter Text (nur per Bedienungshilfen gelesen).

/// Wohin „Einfügen“ schreibt: das Fenster, das beim Diktat das Ziel war (unter der Maus bzw. vorne)
struct APTarget {
    var pid: pid_t
    var windowID: CGWindowID?
    var window: AXUIElement?
    var bundleID: String
    var appName: String
    var title: String
}

/// Alles, was nach außen wirkt – austauschbar für Tests (keine Zwischenablage, kein Einfügen, kein Hub)
struct APActions {
    var copy: (_ text: String, _ source: String) -> Void = { Inserter.copy($0, source: $1) }
    var insert: (_ text: String, _ source: String, _ target: APTarget?, _ done: @escaping (Bool) -> Void) -> Void = APFlow.liveInsert
    var openHub: (_ id: String) -> Void = { id in
        APStore.shared.selectedID = id
        APStore.shared.hubTab = "prompts"
        VoiceFlowWindow.shared.show(.scratchpad)
    }
    var addHistory: (_ text: String, _ duration: Double) -> Void = { DictationHistory.shared.add(text: $0, duration: $1) }
    var toast: (String) -> Void = { _ in }
    /// Pille zeigt „Prompt wird gebaut“ (true) bzw. zurück in Ruhe (false)
    var pillBusy: (Bool) -> Void = { _ in }
    /// App/Fenster/Markierung beim Diktat lesen (Main-Thread)
    var captureTarget: (_ useMouse: Bool) -> (APTarget?, APContext) = APFlow.liveCapture
    var now: () -> Date = { Date() }
    /// Claude-CLI installiert? (optional) – ohne sie baut Flow nach Regeln und schlägt nichts von selbst vor
    var claudeAvailable: () -> Bool = { ClaudeCLI.isAvailable }
}

final class APFlow: ObservableObject {
    static let shared = APFlow()

    static let sourceOriginal = "Diktat (Original)"
    static let sourcePrompt = "Agent-Prompt"

    @Published var prefs: APPrefs { didSet { if prefs != oldValue, persist { PGFile.save(prefs, APPrefs.file) } } }
    var actions = APActions()
    var presenter: APPresenter
    let store: APStore
    /// Für Tests: eigener Builder (Schein-Claude)
    var makeBuilder: (APPrefs) -> APBuilder = { p in
        let b = APBuilder(); b.model = p.model; b.effort = p.effort; b.timeout = p.timeout; b.ruleFallback = p.ruleFallback; return b
    }
    private let persist: Bool

    /// Ein Durchlauf (höchstens einer gleichzeitig)
    final class Job {
        let id = UUID().uuidString
        let original: String
        let context: APContext
        let target: APTarget?
        let trigger: String
        let started: Date
        var task: Task<Void, Never>?
        var record: APRecord?
        var ended = false
        init(original: String, context: APContext, target: APTarget?, trigger: String, started: Date) {
            self.original = original; self.context = context; self.target = target; self.trigger = trigger; self.started = started
        }
    }
    private(set) var job: Job?
    /// Offener Vorschlag (Auto-Erkennung): Text + Ziel, bis zum Klick
    private var offer: (text: String, duration: Double, target: APTarget?, context: APContext, detection: APDetection)?
    /// Zeitpunkte für die Tempo-Zeile im Protokoll
    private(set) var lastTimings: (cardMs: Int, firstTextMs: Int?, doneMs: Int?) = (0, nil, nil)

    private init() {
        persist = true
        prefs = PGFile.load(APPrefs.file, as: APPrefs.self) ?? APPrefs()
        store = APStore.shared
        presenter = APCard.shared
        presenter.onAction = { [weak self] a in self?.handle(a) }
    }

    /// Für Tests: ohne Dateien der echten Einstellungen, mit eigenem Speicher/Presenter
    init(testing prefs: APPrefs, store: APStore, presenter: APPresenter, actions: APActions) {
        persist = false
        self.prefs = prefs
        self.store = store
        self.presenter = presenter
        self.actions = actions
        presenter.onAction = { [weak self] a in self?.handle(a) }
    }

    var isBuilding: Bool { if let j = job, !j.ended { return true }; return false }

    // MARK: 1. Auf Zuruf („Prompt: …“)

    /// Hintergrund-Task des Diktats. Siehe Kopf der Datei.
    func consume(_ text: String, duration: Double, useMouse: Bool, finish: @escaping () -> Void) async -> Bool {
        let mode = await MainActor.run { self.prefs.mode }
        guard mode != .off, !Task.isCancelled, let m = APTrigger.match(text) else { return false }
        await MainActor.run {
            finish()
            self.startExplicit(m, duration: duration, useMouse: useMouse)
        }
        log("Agent-Prompt: Auslöser „\(m.phrase)“ – \(APText.words(m.body)) Wörter" + (Settings.frozen.logTexts ? ": „\(m.body)“" : ""))
        return true
    }

    /// Main-Thread
    func startExplicit(_ m: APTrigger.Match, duration: Double, useMouse: Bool) {
        let (target, ctx) = actions.captureTarget(useMouse)
        // Das Original geht NIE verloren: sofort Zwischenablage + ClipVault („Diktat (Original)“) + Diktat-Verlauf
        actions.copy(m.body, APFlow.sourceOriginal)
        actions.addHistory(m.body, duration)
        start(original: m.body, context: ctx, target: target, trigger: "zuruf")
    }

    // MARK: 2. Automatisch erkannt (nach dem normalen Einfügen)

    /// Main-Thread, direkt nach dem Einfügen. Zeigt höchstens eine leise Vorschlags-Karte.
    @discardableResult
    func offerIfLong(text: String, duration: Double, bundleID: String, title: String? = nil, target: APTarget? = nil) -> APDetection? {
        guard prefs.mode == .on, !isBuilding, !presenter.isShowing else { return nil }
        // Ohne Claude-CLI nur auf Zuruf (Regel-Prompt ist gut als Rückfall, aber kein Grund, ungefragt zu stören)
        guard actions.claudeAvailable() else { return nil }
        let (capTarget, ctx) = target.map { ($0, APContext(appName: $0.appName, bundleID: $0.bundleID, windowTitle: $0.title)) } ?? actions.captureTarget(false)
        let t = capTarget
        let d = APDetector.detect(text: text, duration: duration, bundleID: bundleID.isEmpty ? (t?.bundleID ?? "") : bundleID,
                                  title: title ?? t?.title ?? "")
        log("Agent-Prompt-Erkennung: \(d.offer ? "Vorschlag" : "nein") · Punkte \(d.score) · " + d.reasons.joined(separator: " · "))
        guard d.offer else { return d }
        offer = (text, duration, t, ctx, d)
        presenter.show(.offer(d))
        return d
    }

    // MARK: Bauen

    private func start(original: String, context: APContext, target: APTarget?, trigger: String) {
        job?.task?.cancel()
        let j = Job(original: original, context: context, target: target, trigger: trigger, started: actions.now())
        job = j
        let words = APText.words(original)
        let tCard = Date()
        presenter.show(.building(partial: "", words: words, started: j.started))
        lastTimings = (Int(Date().timeIntervalSince(tCard) * 1000), nil, nil)
        actions.pillBusy(true)
        let builder = makeBuilder(prefs)
        let req = APRequest(transcript: original, context: context)
        var lastShown = Date.distantPast
        j.task = Task { [weak self] in
            let r = await builder.build(req) { partial in
                DispatchQueue.main.async {
                    guard let self, self.job === j, !j.ended, !partial.isEmpty else { return }
                    if self.lastTimings.firstTextMs == nil { self.lastTimings.firstTextMs = Int(Date().timeIntervalSince(j.started) * 1000) }
                    // Live-Text höchstens ~12× pro Sekunde neu setzen
                    guard Date().timeIntervalSince(lastShown) > 0.08 else { return }
                    lastShown = Date()
                    self.presenter.show(.building(partial: partial, words: words, started: j.started))
                }
            }
            await MainActor.run { self?.finishBuild(j, r) }
        }
    }

    /// Main-Thread
    private func finishBuild(_ j: Job, _ r: APOutcome) {
        guard job === j, !j.ended else { return }
        j.ended = true
        actions.pillBusy(false)
        let ms = Int(actions.now().timeIntervalSince(j.started) * 1000)
        lastTimings.doneMs = ms
        switch r {
        case .ok(let res):
            let rec = APRecord(id: j.id, created: actions.now(), prompt: res.prompt, original: j.original,
                               appName: j.context.appName, windowTitle: j.context.includesTitle ? j.context.windowTitle : "",
                               source: res.source, note: res.note, trigger: j.trigger, buildMs: res.ms)
            j.record = rec
            store.add(rec)
            actions.copy(res.prompt, APFlow.sourcePrompt)
            presenter.show(.done(rec))
            log("Agent-Prompt fertig: \(res.source)\(res.note.isEmpty ? "" : " (\(res.note))") · \(APText.words(j.original)) → \(APText.words(res.prompt)) Wörter · "
                + "Karte \(lastTimings.cardMs) ms, erstes Wort \(lastTimings.firstTextMs.map { "\($0) ms" } ?? "–"), fertig \(ms) ms"
                + (res.missing.isEmpty ? "" : " · \(res.missing.count) Zahl(en)/Datei(en) nicht wörtlich übernommen"
                   + (Settings.frozen.logTexts ? ": \(res.missing.prefix(6).joined(separator: ", "))" : "")))
        case .failed(let why):
            presenter.show(.stopped(.failed, reason: why, original: j.original))
            log("Agent-Prompt nicht gebaut: \(why)")
        case .cancelled:
            presenter.show(.stopped(.cancelled, reason: "Abgebrochen", original: j.original))
            log("Agent-Prompt abgebrochen")
        }
    }

    func cancel() {
        guard let j = job, !j.ended else { return }
        j.task?.cancel()
        // Sofort umschalten (der Prozess wird im Hintergrund beendet)
        finishBuild(j, .cancelled)
    }

    // MARK: Karte

    /// Esc (globale Taste): beim Bauen nur mit der Maus auf der Karte abbrechen (Esc in Claude Code soll den Prompt
    /// nicht versehentlich abbrechen) – sonst Karte schließen. Nichts geht verloren.
    func escape(mouseOnCard: Bool) {
        guard presenter.isShowing else { return }
        if isBuilding { if mouseOnCard { cancel() } ; return }
        handle(.close)
    }

    func handle(_ a: APCardAction) {
        switch a {
        case .build:
            guard let o = offer else { presenter.close(); return }
            offer = nil
            start(original: o.text, context: o.context, target: o.target, trigger: "vorschlag")
        case .dismissOffer:
            offer = nil
            presenter.close()
        case .cancel:
            cancel()
        case .close:
            if isBuilding { cancel(); return }
            offer = nil
            presenter.close()
        case .copy:
            guard let r = job?.record else { return }
            actions.copy(r.prompt, APFlow.sourcePrompt)
            presenter.flash(.copied)
        case .insert:
            guard let r = job?.record else { return }
            let target = job?.target
            presenter.close()
            actions.insert(r.prompt, APFlow.sourcePrompt, target) { [weak self] ok in
                if !ok { self?.actions.toast("Prompt liegt in der Zwischenablage") }
            }
        case .open:
            guard let r = job?.record else { return }
            presenter.close()
            actions.openHub(r.id)
        case .copyOriginal:
            guard let o = job?.original else { return }
            actions.copy(o, APFlow.sourceOriginal)
            presenter.flash(.copiedOriginal)
        case .insertOriginal:
            guard let j = job else { return }
            presenter.close()
            actions.insert(j.original, APFlow.sourceOriginal, j.target) { [weak self] ok in
                if !ok { self?.actions.toast("Original liegt in der Zwischenablage") }
            }
        case .retry:
            guard let j = job, j.ended else { return }
            start(original: j.original, context: j.context, target: j.target, trigger: j.trigger)
        }
    }

    // MARK: Echte Umgebung

    /// App + Fenster (unter der Maus, wenn „Text dorthin, wo die Maus ist“ läuft, sonst vorne) + Markierung (nur AX)
    static func liveCapture(useMouse: Bool) -> (APTarget?, APContext) {
        guard AXIsProcessTrusted() else {
            let app = NSWorkspace.shared.frontmostApplication
            let t = app.map { APTarget(pid: $0.processIdentifier, windowID: nil, window: nil, bundleID: $0.bundleIdentifier ?? "", appName: $0.localizedName ?? "", title: "") }
            return (t, APContext(appName: t?.appName ?? "", bundleID: t?.bundleID ?? "", windowTitle: "", selection: ""))
        }
        var target: APTarget?
        if useMouse {
            let own = ProcessInfo.processInfo.processIdentifier
            if case .target(let m) = MouseTarget.capture(point: MouseTarget.mousePoint(), ownPID: own, session: 0) {
                target = APTarget(pid: m.pid, windowID: m.windowID, window: m.window, bundleID: m.bundle, appName: m.appName, title: m.title)
            }
        }
        if target == nil {
            let f = MouseTarget.frontmost()
            if f.pid != 0, f.pid != ProcessInfo.processInfo.processIdentifier {
                let app = NSRunningApplication(processIdentifier: f.pid)
                target = APTarget(pid: f.pid, windowID: f.windowID, window: f.window, bundleID: app?.bundleIdentifier ?? "",
                                  appName: app?.localizedName ?? "", title: f.window.flatMap { MTAX.string($0, kAXTitleAttribute) } ?? "")
            }
        }
        var ctx = APContext(appName: target?.appName ?? "", bundleID: target?.bundleID ?? "", windowTitle: target?.title ?? "", selection: "")
        if let t = target, !CorrectionLearner.blockedApps.contains(t.bundleID),
           NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid,
           let sel = CommandMode.shared.captureSelection(allowCopyFallback: false) {   // nie ⌘C – Zwischenablage bleibt unberührt
            ctx.selection = String(sel.text.prefix(4000))
        }
        return (target, ctx)
    }

    /// Einfügen ins Ziel-Fenster: ist es noch vorne → sofort; sonst erst nach vorne holen (wie „Text dorthin, wo die Maus
    /// ist“). Danach Enter nur mit der Einstellung „Danach automatisch abschicken“ (gleiche Regeln/Enter-Liste).
    static func liveInsert(_ text: String, source: String, target: APTarget?, done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let front = MouseTarget.frontmost()
            if let t = target, t.pid != 0, front.pid != t.pid || (t.windowID != nil && front.windowID != nil && t.windowID != front.windowID) {
                if let wid = t.windowID { _ = MTFocus.bringToFront(pid: t.pid, windowID: wid, window: t.window) }
                else { NSRunningApplication(processIdentifier: t.pid)?.activate() }
                MTFocus.poll(0.4) { MouseTarget.frontmost().pid == t.pid }
            }
            DispatchQueue.main.async {
                guard case .pasted = Inserter.insert(text, source: source) else { done(false); return }
                done(true)
                guard Settings.shared.mouseTargetAutoSend else { return }
                let prep = MTPrepared(method: "0", note: "Agent-Prompt", extraMs: 0, target: nil, toast: nil)
                MouseTarget.shared.autoSend(inserted: text, prepared: prep, hotkeyHeld: { false }) { extra in log("Agent-Prompt eingefügt · \(extra)") }
            }
        }
    }
}
