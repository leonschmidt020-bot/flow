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
//           „Einfügen“ fügt hier nur ein (es steht ja kein Original im Eingabefeld).
//   false = normales Diktat. Die Erkennung läuft schon VOR dem Einfügen im Hintergrund (`precheck`); direkt nach dem
//           echten Einfügen (⌘V geschickt) ruft Dictation `afterPaste` → die Vorschlags-Karte kommt ohne Wartezeit
//           (1.7.21: vorher fest +0,7 s, Ziel/Markierung auf dem Main-Thread gelesen – zusammen ~1 s, oft war da
//           schon abgeschickt). Gleichzeitig wird im Hintergrund gemerkt, WO der Text steht (APReplace) – damit
//           „Einfügen“ später das Original durch den Prompt ERSETZT.
//
// Solange die Vorschlags-Karte steht (und während des Bauens), wird alle 250 ms nachgesehen, ob das Original schon
// abgeschickt ist (Box leer / neu im Verlauf / Feld geleert) – auch Enter in der Ziel-App zählt. Dann geht die Karte
// leise weg; wird schon gebaut, bietet die fertige Karte nur „Kopieren“ und „Als neue Nachricht einfügen“.
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
    /// App/Fenster/Markierung beim Diktat lesen (Main-Thread) – nur noch für „Prompt: …“
    var captureTarget: (_ useMouse: Bool) -> (APTarget?, APContext) = APFlow.liveCapture
    var now: () -> Date = { Date() }
    /// Claude-CLI installiert? (optional) – ohne sie baut Flow nach Regeln und schlägt nichts von selbst vor
    var claudeAvailable: () -> Bool = { ClaudeCLI.isAvailable }
    /// Vor dem Diktat: Claude-Code-Box der vorderen App lesen (Hintergrund)
    var preRead: (_ done: @escaping (pid_t, TerminalPrompt.Screen?) -> Void) -> Void = APReplaceLive.preRead
    /// Nach dem Einfügen: Ziel + Stelle merken (Hintergrund, meldet auf dem Main-Thread)
    var snapshot: (_ p: APPasted, _ pre: (pid: pid_t, screen: TerminalPrompt.Screen?)?, _ mouse: APTarget?,
                   _ done: @escaping (APPasteState, APTarget?, APContext?, AXUIElement?) -> Void) -> Void = APReplaceLive.snapshot
    /// Ziel jetzt nachlesen (abgeschickt?) – Hintergrund, meldet auf dem Main-Thread
    var probe: (_ p: APPasted, _ done: @escaping (APVerdict) -> Void) -> Void = APFlow.liveProbe
    /// „Einfügen“ mit Ersetzen des Originals. done(Ergebnis, Prompt wirklich eingefügt)
    var replace: (_ prompt: String, _ p: APPasted, _ done: @escaping (APReplaceOutcome, Bool) -> Void) -> Void = APFlow.liveReplace
    /// Vordere App (für „Enter in der Ziel-App“)
    var frontPID: () -> pid_t = { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
}

final class APFlow: ObservableObject {
    static let shared = APFlow()

    static let sourceOriginal = "Diktat (Original)"
    static let sourcePrompt = "Agent-Prompt"
    /// Nachlesen „abgeschickt?“: Vorschlag sichtbar / Prompt wird gebaut
    static var pollOffer: TimeInterval = 0.25
    static var pollBuilding: TimeInterval = 0.5

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
        private let fixedTarget: APTarget?
        let trigger: String
        let started: Date
        /// Vorschlag: das eingefügte Diktat (Ziel + Stelle) – „Einfügen“ ersetzt es. nil = „Prompt: …“ (nichts eingefügt)
        var pasted: APPasted?
        /// Original wurde abgeschickt, während gebaut wurde → nur noch „Als neue Nachricht einfügen“
        var originalSent = false
        var inserting = false
        var task: Task<Void, Never>?
        var record: APRecord?
        var ended = false
        var target: APTarget? { pasted?.target ?? fixedTarget }
        init(original: String, context: APContext, target: APTarget?, trigger: String, started: Date, pasted: APPasted? = nil) {
            self.original = original; self.context = context; self.fixedTarget = target; self.trigger = trigger; self.started = started
            self.pasted = pasted
        }
    }
    private(set) var job: Job?

    /// Offener Vorschlag (Auto-Erkennung): bis zum Klick, zum Abschicken des Originals oder zum nächsten Diktat
    struct Offer {
        let text: String
        let duration: Double
        let pasted: APPasted
        let detection: APDetection
        let fallbackContext: APContext
    }
    private(set) var offer: Offer?
    /// Box vor dem Diktat (eingeklappte Texte sicher erkennen)
    private var pre: (pid: pid_t, screen: TerminalPrompt.Screen?)?
    private var pollTimer: Timer?
    private var pollTick = 0
    private var probing = false
    /// Zeitpunkte für die Tempo-Zeile im Protokoll
    private(set) var lastTimings: (cardMs: Int, firstTextMs: Int?, doneMs: Int?) = (0, nil, nil)
    /// Einfügen → Vorschlags-Karte lesbar (ms), zuletzt gemessen
    private(set) var lastOfferMs: Int?

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

    /// Hintergrund (vor dem Einfügen): Erkennung rechnen – kostet beim Einfügen dann nichts mehr. (Erkennung, ms)
    static func precheck(text: String, duration: Double, bundleID: String, title: String) -> (APDetection, Int) {
        let t0 = Date()
        let d = APDetector.detect(text: text, duration: duration, bundleID: bundleID, title: title)
        return (d, Int(Date().timeIntervalSince(t0) * 1000))
    }

    /// Fenstertitel der vorderen App (Hintergrund, Bedienungshilfen) – nur für die Erkennung (Browser mit „Claude“ im Titel)
    static func frontTitle() -> String {
        guard AXIsProcessTrusted() else { return "" }
        return MouseTarget.frontmost().window.flatMap { MTAX.string($0, kAXTitleAttribute) } ?? ""
    }

    /// Neues Diktat beginnt (Main-Thread): offener Vorschlag geht weg (nie zwei übereinander), Box vorab lesen
    func dictationStarted() {
        if offer != nil {
            dropOffer(fade: true)
            log("Agent-Prompt-Angebot: neues Diktat → ausgeblendet")
        }
        pre = nil
        guard prefs.mode == .on, actions.claudeAvailable() else { return }
        actions.preRead { [weak self] pid, screen in self?.pre = (pid, screen) }
    }

    /// Main-Thread, direkt nach dem echten Einfügen eines Diktats (⌘V geschickt).
    /// `inserted` = genau so eingefügt (Inserter), `detection` = Ergebnis von `precheck` (nil = zu kurz, nicht gerechnet).
    @discardableResult
    func afterPaste(text: String, inserted: String, duration: Double, bundleID: String, title: String = "",
                    detection: (APDetection, Int)?, mouseTarget: APTarget? = nil, pastedAt: Date? = nil) -> APDetection? {
        guard prefs.mode == .on, let (d, detMs) = detection else { return nil }
        // Ohne Claude-CLI nur auf Zuruf (Regel-Prompt ist gut als Rückfall, aber kein Grund, ungefragt zu stören)
        guard actions.claudeAvailable() else { return nil }
        let tPaste = pastedAt ?? actions.now()
        log("Agent-Prompt-Erkennung: \(d.offer ? "Vorschlag" : "nein") · Punkte \(d.score) · " + d.reasons.joined(separator: " · "))
        guard d.offer else { return d }
        if isBuilding { log("Agent-Prompt-Vorschlag übersprungen: es wird gerade ein Prompt gebaut"); return d }
        let p = APPasted(text: inserted, at: tPaste, target: mouseTarget ?? APFlow.cheapFront(bundleID: bundleID))
        let fallback = APContext(appName: p.target?.appName ?? "", bundleID: bundleID, windowTitle: title)
        offer = Offer(text: text, duration: duration, pasted: p, detection: d, fallbackContext: fallback)
        let tShow = Date()
        presenter.show(.offer(d))
        let shownMs = Int(Date().timeIntervalSince(tShow) * 1000)
        let toCard = Int(Date().timeIntervalSince(tPaste) * 1000)
        lastOfferMs = toCard + APCard.offerRevealMs
        log("Agent-Prompt-Vorschlag: lesbar nach \(lastOfferMs ?? 0) ms (Einfügen → Karte \(toCard) ms, davon Aufbau \(shownMs) ms · "
            + "Einblenden ~\(APCard.offerRevealMs) ms · Erkennung vorab \(detMs) ms)")
        // Ziel + Stelle im Hintergrund merken (für „Einfügen“ = Ersetzen und „schon abgeschickt?“)
        actions.snapshot(p, pre, mouseTarget) { [weak self] state, target, ctx, el in
            guard let self else { return }
            p.state = p.state == .sentAlready ? .sentAlready : state
            if let target { p.target = target }
            p.context = ctx
            p.element = el
            log("Agent-Prompt: Stelle gemerkt nach \(Int(Date().timeIntervalSince(tPaste) * 1000)) ms – " + APFlow.describe(state))
            if state == .sentAlready { self.originalSent(p, via: "schon beim Nachlesen im Verlauf") }
        }
        startPolling()
        return d
    }

    /// Ohne Bedienungshilfen: vordere App als Ziel (genauer kommt aus `snapshot`)
    private static func cheapFront(bundleID: String) -> APTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return APTarget(pid: app.processIdentifier, windowID: nil, window: nil, bundleID: app.bundleIdentifier ?? bundleID,
                        appName: app.localizedName ?? "", title: "")
    }

    static func describe(_ s: APPasteState) -> String {
        switch s {
        case .pending: return "noch offen"
        case .sentAlready: return "schon abgeschickt"
        case .unknown(let why): return "nicht gefunden (\(why))"
        case .found(.box(_, let shown, _, _)): return APReplace.placeholders(shown).isEmpty ? "Claude-Code-Eingabe" : "Claude-Code-Eingabe (eingeklappt)"
        case .found(.field): return "Textfeld"
        }
    }

    /// Für Tests/CLI: wie früher „nach dem Einfügen prüfen“ – Erkennung hier gerechnet
    @discardableResult
    func offerIfLong(text: String, duration: Double, bundleID: String, title: String? = nil, target: APTarget? = nil) -> APDetection? {
        let det = APFlow.precheck(text: text, duration: duration, bundleID: bundleID, title: title ?? target?.title ?? "")
        return afterPaste(text: text, inserted: text, duration: duration, bundleID: bundleID, title: title ?? "", detection: det, mouseTarget: target)
    }

    // MARK: Abgeschickt? (Nachlesen + Enter)

    /// Was gerade beobachtet wird: offener Vorschlag oder das Original eines laufenden Baus
    private var watched: APPasted? {
        if let o = offer, presenter.isShowing { return o.pasted }
        if let j = job, !j.ended, !j.originalSent, let p = j.pasted, p.state != .sentAlready { return p }
        return nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTick = 0
        let t = Timer(timeInterval: APFlow.pollOffer, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
    }

    private func poll() {
        guard let p = watched else { stopPolling(); return }
        pollTick += 1
        // Beim Bauen reicht halb so oft
        if offer == nil, APFlow.pollBuilding > APFlow.pollOffer, pollTick % Int((APFlow.pollBuilding / APFlow.pollOffer).rounded()) != 0 { return }
        guard !probing, case .found = p.state else { return }
        probing = true
        actions.probe(p) { [weak self] v in
            guard let self else { return }
            self.probing = false
            if v == .sent { self.originalSent(p, via: "Eingabe leer / neu im Verlauf") }
        }
    }

    /// Enter/Return (ohne Umschalt & Co.) – vom Event-Tap (Main-Thread). Nur wenn die Ziel-App vorne ist.
    func returnPressed() {
        guard let p = watched, let t = p.target, t.pid != 0, actions.frontPID() == t.pid else { return }
        // Claude Code leert die Box sofort; zur Sicherheit kurz danach nachlesen. Nicht lesbar → zählt als abgeschickt.
        func check(_ attempt: Int) {
            guard watched === p else { return }
            actions.probe(p) { [weak self] v in
                guard let self, self.watched === p else { return }
                switch v {
                case .sent, .unreadable: self.originalSent(p, via: "Enter")
                case .intact, .edited:
                    if attempt == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { check(1) } }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { check(0) }
    }

    /// Main-Thread: Original ist abgeschickt → Vorschlag leise weg bzw. fertige Karte ohne Ersetzen
    func originalSent(_ p: APPasted, via: String) {
        p.state = .sentAlready
        if let o = offer, o.pasted === p {
            dropOffer(fade: true)
            log("Agent-Prompt-Angebot: Original abgeschickt → ausgeblendet (\(via))")
        }
        if let j = job, j.pasted === p, !j.originalSent {
            j.originalSent = true
            log("Agent-Prompt: Original abgeschickt (\(via)) – fertige Karte bietet „Als neue Nachricht einfügen“")
            if j.ended, let r = j.record, case .done(let shown, false)? = presenter.phase, shown.id == r.id {
                presenter.show(.done(r, sent: true))
            }
        }
        if watched == nil { stopPolling() }
    }

    private func dropOffer(fade: Bool) {
        guard offer != nil else { return }
        offer = nil
        if case .offer? = presenter.phase { fade ? presenter.fadeOut() : presenter.close() }
        if watched == nil { stopPolling() }
    }

    // MARK: Bauen

    private func start(original: String, context: APContext, target: APTarget?, trigger: String, pasted: APPasted? = nil) {
        job?.task?.cancel()
        offer = nil
        let j = Job(original: original, context: context, target: target, trigger: trigger, started: actions.now(), pasted: pasted)
        job = j
        let words = APText.words(original)
        let tCard = Date()
        presenter.show(.building(partial: "", words: words, started: j.started))
        lastTimings = (Int(Date().timeIntervalSince(tCard) * 1000), nil, nil)
        actions.pillBusy(true)
        if pasted != nil { startPolling() }
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
        if watched == nil { stopPolling() }
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
            let sent = j.originalSent || j.pasted?.state == .sentAlready
            presenter.show(.done(rec, sent: sent))
            let sentNote = sent ? " · Original schon abgeschickt" : ""
            log("Agent-Prompt fertig: \(res.source)\(res.note.isEmpty ? "" : " (\(res.note))") · \(APText.words(j.original)) → \(APText.words(res.prompt)) Wörter · "
                + "Karte \(lastTimings.cardMs) ms, erstes Wort \(lastTimings.firstTextMs.map { "\($0) ms" } ?? "–"), fertig \(ms) ms" + sentNote
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
            start(original: o.text, context: o.pasted.context ?? o.fallbackContext, target: o.pasted.target, trigger: "vorschlag",
                  pasted: o.pasted)
        case .dismissOffer:
            offer = nil
            presenter.close()
            if watched == nil { stopPolling() }
        case .cancel:
            cancel()
        case .close:
            if isBuilding { cancel(); return }
            offer = nil
            presenter.close()
            if watched == nil { stopPolling() }
        case .copy:
            guard let r = job?.record else { return }
            actions.copy(r.prompt, APFlow.sourcePrompt)
            presenter.flash(.copied)
        case .insert:
            guard let j = job, let r = j.record, !j.inserting else { return }
            presenter.close()
            // Vorschlag (Original steht noch im Eingabefeld) → ersetzen; „Prompt: …“ oder schon abgeschickt → nur einfügen
            if let p = j.pasted, !j.originalSent, p.state != .sentAlready {
                j.inserting = true
                CorrectionLearner.shared.stop()   // der Wort-Lerner soll das Ersetzen nicht als Korrektur lesen
                let t0 = Date()
                actions.replace(r.prompt, p) { [weak self] outcome, pasted in
                    guard let self else { return }
                    j.inserting = false
                    j.pasted = nil          // ersetzt ist ersetzt – nochmal „Einfügen“ fügt nur noch ein
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    switch outcome {
                    case .cleared: log("Agent-Prompt: Original in der Eingabe gelöscht, Prompt eingefügt (\(ms) ms)")
                    case .selected: log("Agent-Prompt: Original im Feld markiert und ersetzt (\(ms) ms)")
                    case .insertNew(_, let why): log("Agent-Prompt: Original NICHT gelöscht (\(why)) – Prompt neu eingefügt (\(ms) ms)")
                    }
                    if !pasted { self.actions.toast("Prompt liegt in der Zwischenablage") }
                    else if case .insertNew(let hint?, _) = outcome { self.actions.toast(hint) }
                }
            } else {
                actions.insert(r.prompt, APFlow.sourcePrompt, j.target) { [weak self] ok in
                    if !ok { self?.actions.toast("Prompt liegt in der Zwischenablage") }
                }
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
            start(original: j.original, context: j.context, target: j.target, trigger: j.trigger,
                  pasted: j.originalSent ? nil : j.pasted)
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

    /// Hintergrund: Ziel-Fenster nach vorne holen (ist es schon vorne → sofort). true = Ziel ist vorne.
    @discardableResult
    static func focusTarget(_ target: APTarget?) -> Bool {
        let front = MouseTarget.frontmost()
        guard let t = target, t.pid != 0 else { return true }
        if front.pid != t.pid || (t.windowID != nil && front.windowID != nil && t.windowID != front.windowID) {
            if let wid = t.windowID { _ = MTFocus.bringToFront(pid: t.pid, windowID: wid, window: t.window) }
            else { DispatchQueue.main.async { NSRunningApplication(processIdentifier: t.pid)?.activate() } }
            return MTFocus.poll(0.4) { MouseTarget.frontmost().pid == t.pid }
        }
        return true
    }

    /// Nach dem Einfügen: Enter nur mit der Einstellung „Danach automatisch abschicken“ (gleiche Regeln/Enter-Liste)
    private static func autoSendIfWanted(_ text: String) {
        guard Settings.shared.mouseTargetAutoSend else { return }
        let prep = MTPrepared(method: "0", note: "Agent-Prompt", extraMs: 0, target: nil, toast: nil)
        MouseTarget.shared.autoSend(inserted: text, prepared: prep, hotkeyHeld: { false }) { extra in log("Agent-Prompt eingefügt · \(extra)") }
    }

    /// Einfügen ins Ziel-Fenster: ist es noch vorne → sofort; sonst erst nach vorne holen (wie „Text dorthin, wo die Maus
    /// ist“). Danach Enter nur mit der Einstellung „Danach automatisch abschicken“ (gleiche Regeln/Enter-Liste).
    static func liveInsert(_ text: String, source: String, target: APTarget?, done: @escaping (Bool) -> Void) {
        APReplaceLive.queue.async {
            focusTarget(target)
            DispatchQueue.main.async {
                guard case .pasted = Inserter.insert(text, source: source) else { done(false); return }
                done(true)
                autoSendIfWanted(text)
            }
        }
    }

    /// „Einfügen“ beim Vorschlag: Ziel nach vorne, die gemerkte Eingabe wieder fokussieren, nachlesen, Original löschen
    /// bzw. markieren (APReplaceRun) – dann den Prompt einfügen. Kann nichts sicher gelöscht werden: nur einfügen.
    static func liveReplace(_ prompt: String, _ p: APPasted, done: @escaping (APReplaceOutcome, Bool) -> Void) {
        let target = p.target, element = p.element, text = p.text, state = p.state
        APReplaceLive.queue.async {
            var outcome: APReplaceOutcome
            if !focusTarget(target) {
                outcome = .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Ziel-Fenster ließ sich nicht nach vorne holen")
            } else if let t = target, AXIsProcessTrusted() {
                // Gemerkte Eingabe (xterm-Feld / Textfeld) wieder fokussieren – Tasten dürfen nur dort landen
                var focusedOK = element == nil
                if let el = element {
                    // gleich = das Element selbst oder (contenteditable) ein Absatz darin
                    func same() -> Bool {
                        guard let f = CorrectionLearner.focusedElement(pid: t.pid) else { return false }
                        return CFEqual(f, el) || (CorrectionLearner.editableRoot(f).map { CFEqual($0, el) } ?? false)
                    }
                    if same() { focusedOK = true }
                    else {
                        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        focusedOK = MTFocus.poll(0.2, same)
                    }
                }
                if focusedOK {
                    // Bedienungshilfen-Baum (Electron/Chrome) läuft nach 60 s wieder aus – vor dem Nachlesen sicher an
                    ScreenContext.shared.enableAX(t.pid)
                    MouseTarget.shared.enableWebAX(pid: t.pid, bundle: t.bundleID)
                    let io = APReplaceLive.IO(pid: t.pid, bundle: t.bundleID, element: element, known: APReplaceLive.known(text))
                    if case .found(let m) = state {
                        // frisch eingeschaltet baut Chromium den Baum erst auf – kurz warten, bis wieder lesbar
                        MTFocus.poll(0.6) { if case .box = m { return io.readBox() != nil }; return io.readField() != nil }
                    }
                    outcome = APReplaceRun.run(state, io: io)
                } else {
                    outcome = .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Eingabe ließ sich nicht wieder fokussieren")
                }
            } else {
                outcome = .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Bedienungshilfen fehlen")
            }
            DispatchQueue.main.async {
                // Leerzeichen-Regel des Inserters („direkt nach dem letzten Diktat“) gilt nicht, wenn das Original weg ist
                switch outcome {
                case .cleared: Inserter.forgetLast()
                case .insertNew(let hint, _) where hint == APReplaceOutcome.hintSent: Inserter.forgetLast()
                default: break
                }
                guard case .pasted = Inserter.insert(prompt, source: APFlow.sourcePrompt) else { done(outcome, false); return }
                done(outcome, true)
                autoSendIfWanted(prompt)
            }
        }
    }

    /// Nachlesen „abgeschickt?“ (Hintergrund). Ziel-App muss vorne sein, sonst nicht lesbar.
    static func liveProbe(_ p: APPasted, done: @escaping (APVerdict) -> Void) {
        let state = p.state, target = p.target, element = p.element, text = p.text
        guard case .found(let m) = state, let t = target else {
            done(state == .sentAlready ? .sent : .unreadable("Stelle unbekannt")); return
        }
        APReplaceLive.queue.async {
            var v: APVerdict
            if MouseTarget.frontmost().pid != t.pid { v = .unreadable("Ziel-App nicht vorne") }
            else {
                let io = APReplaceLive.IO(pid: t.pid, bundle: t.bundleID, element: element, known: APReplaceLive.known(text))
                if io.isSecure() { v = .unreadable("sichere Eingabe") }
                else {
                    switch m {
                    case .box: v = APReplace.judgeBox(m, now: io.readBox())
                    case .field: v = APReplace.judgeField(m, value: io.readField()?.value).0
                    }
                }
            }
            DispatchQueue.main.async { done(v) }
        }
    }
}
