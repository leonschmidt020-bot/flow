import AppKit

// MARK: - Sprachbefehle: Einstieg aus der Diktat-Pipeline
//
// EIN Aufruf in DictationController.collect(), direkt nach `TextCleaner.applyRules` (vor Feinschliff/Snippets/Einfügen):
//
//   if await VoiceCommands.shared.consume(cleaned, duration: dur, toast: { m in self.pill.view.showToast(m, seconds: 2.4) },
//                                         finish: { self.transcribeJob = nil; self.state = .idle; self.pill.view.mode = self.restingMode(); self.pill.pinnedToScreen = false }) { return }
//
// true  = war ein Befehl: nichts einfügen (Pille wird über `finish` zurückgesetzt, Karte/Toast kommt von hier).
// false = kein Befehl (oder unvollständig) → das Diktat läuft ganz normal weiter und wird eingefügt.

struct VCPrefs: Codable, Equatable {
    var enabled = true
    /// Vor Termin/Erinnerung/Schicken eine Karte an der Pille zeigen
    var confirm = true
    /// So lange, bis die Karte von selbst ausführt (Maus drauf hält an)
    var confirmSeconds: Double = 4
    /// „Such nach …“ öffnet eine Websuche
    var search = true

    static let file = "sprachbefehle.json"
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        confirm = (try? c.decode(Bool.self, forKey: .confirm)) ?? true
        confirmSeconds = (try? c.decode(Double.self, forKey: .confirmSeconds)) ?? 4
        search = (try? c.decode(Bool.self, forKey: .search)) ?? true
    }
}

/// Alles, was nach außen wirkt – austauschbar für Tests (Probelauf ohne echte Kalender, ohne Tresor, ohne Zwischenablage).
struct VCActions {
    var addReminder: (_ title: String, _ due: Date?, _ allDay: Bool, _ done: @escaping (String?) -> Void) -> Void = VCEventKit.live.addReminder
    var addEvent: (_ title: String, _ start: Date, _ end: Date, _ allDay: Bool, _ done: @escaping (String?) -> Void) -> Void = VCEventKit.live.addEvent
    var syncState: () -> VCVault.SyncState = { VCVault.syncState() }
    var share: (_ text: String, _ done: @escaping (Result<Bool, VCVault.Failure>) -> Void) -> Void = { VCVault.share($0, done: $1) }
    var addNote: (String) -> Void = { t in ScratchpadStore.shared.newNote(t) }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var copy: (String) -> Void = { Inserter.copy($0, source: "Sprachbefehl") }
    var addHistory: (_ text: String, _ duration: Double) -> Void = { DictationHistory.shared.add(text: $0, duration: $1) }
    var polish: (String) async -> String? = { await TextCleaner.polish($0, settings: Settings.shared) }
    var presenter: VCCardPresenter = VCNotifyPresenter()
}

final class VoiceCommands: ObservableObject {
    static let shared = VoiceCommands()

    @Published var prefs: VCPrefs { didSet { if prefs != oldValue, persist { PGFile.save(prefs, VCPrefs.file) } } }
    var actions = VCActions()
    private let persist: Bool
    /// Laufende Bestätigung (höchstens eine gleichzeitig)
    private(set) var pending: VCConfirm?

    private init() {
        persist = true
        prefs = PGFile.load(VCPrefs.file, as: VCPrefs.self) ?? VCPrefs()
    }

    /// Für Tests: eigene Instanz ohne Datei
    init(testing prefs: VCPrefs, actions: VCActions) {
        persist = false
        self.prefs = prefs
        self.actions = actions
    }

    /// Wer ist „der Partner“? Einstellungen/ClipVault-Kopplung (Main-Thread)
    static func currentOptions(search: Bool) -> VoiceCommandParser.Options {
        var o = VoiceCommandParser.Options()
        if let p = Identity.partnerName { o.partners = [p] }
        o.me = Identity.myName
        o.search = search
        return o
    }

    // MARK: Diktat-Pipeline

    /// Hintergrund-Task des Diktats. Siehe Kopf der Datei.
    func consume(_ text: String, duration: Double = 0, now: Date = Date(),
                 toast: @escaping (String) -> Void, finish: @escaping () -> Void) async -> Bool {
        let p = await MainActor.run { self.prefs }
        guard p.enabled, !Task.isCancelled, !text.isEmpty else { return false }
        let opts = await MainActor.run { Self.currentOptions(search: p.search) }
        return await consume(text, options: opts, duration: duration, now: now, toast: toast, finish: finish)
    }

    func consume(_ text: String, options opts: VoiceCommandParser.Options, duration: Double = 0, now: Date = Date(),
                 toast: @escaping (String) -> Void, finish: @escaping () -> Void) async -> Bool {
        guard !Task.isCancelled, !text.isEmpty else { return false }
        guard var cmd = VoiceCommandParser.parse(text, now: now, options: opts) else { return false }
        // Nachricht/Notiz wie ein normales Diktat feinschleifen („nein warte …“), Titel/Suche nicht
        if cmd.kind == .send || cmd.kind == .note {
            // Nachricht an den Partner in Chat-Form formatieren (nicht in der Form der App, die gerade vorne ist)
            if cmd.kind == .send { SmartLists.bundleOverride = "net.whatsapp.WhatsApp" }
            let pol = await actions.polish(cmd.text)
            if cmd.kind == .send { SmartLists.bundleOverride = nil }
            if let pol, !pol.isEmpty { cmd.text = pol }
        }
        if Task.isCancelled { return false }
        let found = cmd
        await MainActor.run {
            finish()
            // Nichts geht verloren: der Befehl steht im Diktat-Verlauf (dort kopierbar)
            self.actions.addHistory(text, duration)
            self.run(found, now: now, toast: toast)
        }
        log("Sprachbefehl erkannt: \(found.kind.rawValue)" + (Settings.frozen.logTexts ? " – „\(text)“" : ""))
        return true
    }

    // MARK: Ausführen (Main-Thread)

    func run(_ cmd: VoiceCommand, now: Date = Date(), toast: @escaping (String) -> Void) {
        switch cmd.kind {
        case .note:
            actions.addNote(cmd.text)
            toast(cmd.english ? "Note saved ✓" : "Notiz gespeichert ✓")
        case .search:
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: cmd.text)]
            if let u = c.url { actions.openURL(u) }
            toast("Suche: \(VCText.short(cmd.text, 28))")
        case .send, .reminder, .event:
            if prefs.confirm {
                pending?.cancel(silently: true)
                let c = VCConfirm(cmd: cmd, now: now, seconds: prefs.confirmSeconds, presenter: actions.presenter,
                                  onConfirm: { [weak self] in self?.execute(cmd, toast: toast) },
                                  onCancel: { toast("Abgebrochen – steht im Verlauf") })
                pending = c
                c.start()
            } else {
                execute(cmd, toast: toast)
            }
        }
    }

    func execute(_ cmd: VoiceCommand, toast: @escaping (String) -> Void) {
        pending = nil
        switch cmd.kind {
        case .reminder:
            actions.addReminder(cmd.text, cmd.date, cmd.allDay) { [weak self] err in
                DispatchQueue.main.async {
                    if let err { self?.failed(cmd, err, toast: toast) } else { toast("Erinnerung angelegt ✓") }
                }
            }
        case .event:
            guard let s = cmd.date else { return }
            actions.addEvent(cmd.text, s, cmd.end ?? s.addingTimeInterval(1800), cmd.allDay) { [weak self] err in
                DispatchQueue.main.async {
                    if let err { self?.failed(cmd, err, toast: toast) } else { toast("Termin eingetragen ✓") }
                }
            }
        case .send:
            let who = cmd.partner ?? Identity.partner(.accusative)
            let st = actions.syncState()
            guard st.connected else {
                notConnected(cmd, reason: st.reason, toast: toast)
                return
            }
            actions.share(cmd.text) { [weak self] r in
                DispatchQueue.main.async {
                    switch r {
                    case .success(true): toast("An \(who) geschickt ✓")
                    case .success(false): toast("Wartet im Tresor – geht an \(who), sobald verbunden")
                    case .failure(let f): self?.notConnected(cmd, reason: f.message, toast: toast)
                    }
                }
            }
        case .note, .search: run(cmd, toast: toast)
        }
    }

    /// Kein Sync: Text in die Zwischenablage + Karte (mit „Trotzdem in den Tresor“ – wird dann nachgeschickt)
    private func notConnected(_ cmd: VoiceCommand, reason: String, toast: @escaping (String) -> Void) {
        actions.copy(cmd.text)
        let who = cmd.partner ?? Identity.partner(.nominative)
        let n = VFNotice(id: "sprachbefehl_nicht_verbunden",
                         title: "Nicht an \(who) geschickt",
                         text: "\(reason). Der Text liegt in der Zwischenablage.",
                         illustration: "illu_geteilt", fallbackSymbol: "person.2.slash",
                         primary: ("Später schicken", { [weak self] in
                             self?.actions.share(cmd.text) { r in
                                 DispatchQueue.main.async {
                                     if case .failure(let f) = r { toast(f.message) } else { toast("Wartet im Tresor – geht raus, sobald verbunden") }
                                 }
                             }
                         }),
                         secondary: ("OK", {}), timeout: 12)
        actions.presenter.show(n)
    }

    private func failed(_ cmd: VoiceCommand, _ why: String, toast: @escaping (String) -> Void) {
        actions.copy(VCText.summary(cmd))
        toast("\(why) – Text in der Zwischenablage")
    }
}

// MARK: - Texte für Karten

enum VCText {
    static func short(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    /// Kurzform für die Zwischenablage bei Fehlern („Termin: Fr 14:00 Termin mit Pierre“)
    static func summary(_ c: VoiceCommand) -> String {
        switch c.kind {
        case .event, .reminder:
            if let d = c.date { return "\(c.text) – \(VCDateParser.label(d, allDay: c.allDay, end: c.kind == .event ? c.end : nil))" }
            return c.text
        default: return c.text
        }
    }

    /// Titel + Text der Bestätigungs-Karte
    static func card(_ c: VoiceCommand, now: Date = Date()) -> (title: String, text: String, primary: String, illustration: String, symbol: String) {
        switch c.kind {
        case .event:
            let when = c.date.map { VCDateParser.label($0, allDay: c.allDay, end: c.allDay ? nil : c.end, now: now) } ?? ""
            return ("Termin eintragen", "\(when) · ‚\(short(c.text, 40))‘", "Eintragen", "illu_befehl_termin", "calendar.badge.plus")
        case .reminder:
            let when = c.date.map { VCDateParser.label($0, allDay: c.allDay, now: now) } ?? "Ohne Datum"
            return ("Erinnerung anlegen", "\(when) · ‚\(short(c.text, 44))‘", "Anlegen", "illu_befehl_erinnerung", "bell.badge.fill")
        case .send:
            return ("An \(c.partner ?? Identity.partner(.accusative)) schicken", "„\(short(c.text, 70))“", "Schicken", "illu_geteilt", "paperplane.fill")
        case .note: return ("Notiz", short(c.text, 70), "Speichern", "illu_scratchpad", "doc.text.fill")
        case .search: return ("Suche", short(c.text, 70), "Suchen", "illu_befehl_suche", "magnifyingglass")
        }
    }
}

// MARK: - Bestätigungs-Karte an der Pille (führt nach N s selbst aus, Maus drauf hält an)

protocol VCCardPresenter: AnyObject {
    func show(_ n: VFNotice)
    func dismiss(id: String)
    /// Ist genau diese Karte gerade sichtbar (nicht nur in der Schlange)?
    func isCurrent(_ id: String) -> Bool
    /// Liegt die Maus über der Karte?
    func isHovered(_ n: VFNotice) -> Bool
}

final class VCNotifyPresenter: VCCardPresenter {
    func show(_ n: VFNotice) { VFNotify.shared.show(n) }
    func dismiss(id: String) { VFNotify.shared.dismiss(id: id) }
    func isCurrent(_ id: String) -> Bool { VFNotify.shared.currentID == id }
    func isHovered(_ n: VFNotice) -> Bool {
        guard let pill = n.anchor ?? VFNotify.shared.pillAnchor?(), pill.width > 0 else { return false }
        let m = NSEvent.mouseLocation
        return VFNotify.layout(for: n, pill: pill).hitRectsInScreen.contains { $0.insetBy(dx: -4, dy: -4).contains(m) }
    }
}

final class VCConfirm {
    let id = "sprachbefehl_" + UUID().uuidString.prefix(8)
    let cmd: VoiceCommand
    private let seconds: Double
    private let presenter: VCCardPresenter
    private let onConfirm: () -> Void
    private let onCancel: () -> Void
    private let now: Date
    private var timer: Timer?
    private(set) var elapsed: Double = 0
    private(set) var done = false
    private(set) var outcome: String?
    private var lastShown = -1
    static let tick: Double = 0.2

    init(cmd: VoiceCommand, now: Date, seconds: Double, presenter: VCCardPresenter, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.cmd = cmd; self.now = now; self.seconds = max(1, seconds); self.presenter = presenter
        self.onConfirm = onConfirm; self.onCancel = onCancel
    }

    /// Karte mit Countdown im Abbrechen-Knopf („Abbrechen · 3“)
    func notice(remaining: Int?, paused: Bool) -> VFNotice {
        let c = VCText.card(cmd, now: now)
        let cancelLabel = paused || remaining == nil ? "Abbrechen" : "Abbrechen · \(remaining!)"
        return VFNotice(id: id, title: c.title, text: c.text, illustration: c.illustration, fallbackSymbol: c.symbol,
                        primary: (c.primary, { [weak self] in self?.finish("geklickt", confirm: true, dismissCard: false) }),
                        secondary: (cancelLabel, { [weak self] in self?.finish("abgebrochen", confirm: false, dismissCard: false) }),
                        timeout: nil,
                        onClose: { [weak self] in self?.finish("✕", confirm: false, dismissCard: false) })
    }

    func start() {
        let n = notice(remaining: Int(ceil(seconds)), paused: false)
        lastShown = Int(ceil(seconds))
        presenter.show(n)
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.step(Self.tick) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Ein Zeitschritt (auch direkt aus Tests aufrufbar)
    func step(_ dt: Double) {
        guard !done else { return }
        guard presenter.isCurrent(id) else { return }       // wartet noch in der Schlange
        let n = notice(remaining: nil, paused: true)
        if presenter.isHovered(n) {
            // Maus drauf: anhalten, beim Verlassen wieder von vorn zählen
            elapsed = 0
            if lastShown != 0 { presenter.show(n); lastShown = 0 }
            return
        }
        elapsed += dt
        let remaining = max(0, Int(ceil(seconds - elapsed)))
        if elapsed >= seconds {
            finish("automatisch", confirm: true, dismissCard: true)
            return
        }
        if remaining != lastShown { lastShown = remaining; presenter.show(notice(remaining: remaining, paused: false)) }
    }

    func cancel(silently: Bool) {
        guard !done else { return }
        done = true; outcome = "ersetzt"
        timer?.invalidate(); timer = nil
        presenter.dismiss(id: id)
        if !silently { onCancel() }
    }

    private func finish(_ why: String, confirm: Bool, dismissCard: Bool) {
        guard !done else { return }
        done = true; outcome = why
        timer?.invalidate(); timer = nil
        if dismissCard { presenter.dismiss(id: id) }
        log("Sprachbefehl \(cmd.kind.rawValue): \(confirm ? "ausgeführt" : "abgebrochen") (\(why))")
        if confirm { onConfirm() } else { onCancel() }
    }
}
