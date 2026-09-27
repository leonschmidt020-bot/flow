import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

// MARK: - „Flow lernt mit“ – Steuerzentrale
//
// Einbinden (AppDelegate.applicationDidFinishLaunching, NACH VFNotify.shared.pillAnchor):
//     SmartFlow.shared.start()
//     SmartPillBadge.shared.start()
// Mehr braucht es nicht: Diktate kommen über DictationHistory, Meetings über MeetingStore,
// Korrekturen über das Wörterbuch (alles per Combine beobachtet). Optionale Zusatz-Haken siehe Bericht.
//
// Threads: Auswertung + Zusammenführen + Vorschläge laufen auf `queue` (utility). Der Main-Thread
// sammelt nur eine kleine Momentaufnahme der Stores ein und zeigt Karten/Listen.

final class SmartFlow: ObservableObject {
    static let shared = SmartFlow()

    static var wissenURL: URL { Paths.base.appendingPathComponent("wissen.json") }
    static var prefsURL: URL { Paths.base.appendingPathComponent("lernen.json") }

    // Für die Oberfläche (Main-Thread)
    @Published private(set) var snapshot = SmartWissen()
    @Published private(set) var prefs = SmartPrefs()
    /// Offene Vorschläge, die gezeigt werden dürfen (sortiert: sicherste zuerst)
    @Published private(set) var visiblePending: [SmartSuggestion] = []
    @Published private(set) var started = false
    @Published private(set) var digestRunning = false

    // Haken nach außen (Standard: über den AppDelegate; in Tests ersetzbar)
    /// Läuft gerade ein Diktat oder ein Meeting?
    var isBusy: () -> Bool = {
        guard let d = NSApp?.delegate as? AppDelegate else { return false }
        if let st = d.dictation?.state, st != .idle { return true }
        return d.meeting?.isRecording ?? false
    }
    /// Pille in Ruhe (kein Diktat, keine Frage, kein Laden)?
    var pillIsIdle: () -> Bool = {
        guard let d = NSApp?.delegate as? AppDelegate, let p = d.pill else { return true }
        return p.view.mode == .idle
    }
    var toast: (String) -> Void = { msg in
        (NSApp?.delegate as? AppDelegate)?.pill?.view.showToast(msg, seconds: 2.2)
    }
    /// Ausführung der Aktionen (Wörterbuch, Snippets, Kalender …) – für Tests austauschbar
    var actions = SmartActions()
    /// Karten nie zeigen (Tests/Render)
    var cardsSuppressed = false

    let queue = DispatchQueue(label: "voiceflow.smart", qos: .utility)

    // Nur auf `queue`
    private var w = SmartWissen()
    private var loaded = false
    private var saveItem: DispatchWorkItem?
    private var publishScheduled = false
    private var perf = SmartPerf()

    // Nur auf Main
    private var bag = Set<AnyCancellable>()
    private var lastHistoryDate: Date?
    private var knownDictIDs: Set<UUID> = []
    private var requestedMeetings: Set<String> = []
    private(set) var lastDictationAt = Date.distantPast
    private var lastCardAt: Date?
    private var timer: Timer?
    private var showCheck: DispatchWorkItem?
    private var lastMaintenance = Date.distantPast
    private var recentCorrections: [String: Date] = [:]

    private init() {}

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        prefs = SmartFlow.loadPrefs()
        let ctx = makeContext()
        let records = DictationHistory.shared.records
        lastHistoryDate = records.first?.date
        knownDictIDs = Set(Settings.shared.dictionary.map(\.id))
        let enabled = prefs.enabled
        queue.async {
            self.ensureLoaded()
            if enabled { self.backfill(records, ctx: ctx) }
            SmartLearner.prune(&self.w, ctx: ctx)
            self.scheduleSave()
            self.publishNow()
            DispatchQueue.main.async { self.meetingsChanged(MeetingStore.shared.meetings) }
        }
        DictationHistory.shared.$records.dropFirst()
            .sink { [weak self] recs in self?.historyChanged(recs) }.store(in: &bag)
        MeetingStore.shared.$meetings.dropFirst()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] ms in self?.meetingsChanged(ms) }.store(in: &bag)
        Settings.shared.$dictionary.dropFirst()
            .sink { [weak self] d in self?.dictionaryChanged(d) }.store(in: &bag)
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("Flow lernt mit: gestartet (\(enabled ? "an" : "aus"))")
    }

    // MARK: Eingänge (Main-Thread)

    /// Neues Diktat (auch direkt aufrufbar, z. B. aus der Diktat-Pipeline).
    func ingestDictation(text: String, bundleID: String, date: Date = Date()) {
        guard prefs.enabled, !text.isEmpty else { return }
        guard SmartPrivacy.allowed(bundleID: bundleID) else {
            log("Flow lernt mit: Diktat übersprungen (geschützte App/Eingabe)")
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        lastDictationAt = Date()
        let ctx = makeContext()
        let mainMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        queue.async { self.process(text: text, bundleID: bundleID, date: date, ctx: ctx, backfill: false, mainMs: mainMs) }
        scheduleShowCheck(after: SmartPolicy.quietAfterDictation + 0.5)
    }

    /// Korrektur aus dem Textfeld (optional aus CorrectionLearner.onCandidate). saved = ins Wörterbuch übernommen.
    func noteCorrection(old: String, new: String, saved: Bool, dedupe: Bool = true) {
        guard prefs.enabled, !new.isEmpty else { return }
        // Zwischenstände beim Tippen melden dasselbe Paar mehrfach → nur einmal pro 2 Minuten zählen
        let pairKey = old.lowercased() + "\u{1}" + new + (saved ? "+" : "")
        if dedupe, let t = recentCorrections[pairKey], Date().timeIntervalSince(t) < 120 { return }
        recentCorrections[pairKey] = Date()
        if recentCorrections.count > 200 { recentCorrections = recentCorrections.filter { Date().timeIntervalSince($0.value) < 120 } }
        let ctx = makeContext()
        queue.async {
            self.ensureLoaded()
            guard let k = SmartLearner.noteCorrection(old: old, new: new, saved: saved, date: Date(), into: &self.w),
                  let c = self.w.corrections[k] else { return }
            if let s = SmartLearner.correctionSuggestion(c, ctx: ctx, expires: Date().addingTimeInterval(ctx.pendingAge)) {
                SmartLearner.offer([s], into: &self.w, ctx: ctx)
            }
            self.scheduleSave(); self.schedulePublish()
        }
    }

    /// Fertiges Meeting (nur Titel, Zusammenfassung, Sprechernamen werden gelesen – nie das Transkript).
    func ingestMeeting(_ m: Meeting) {
        guard prefs.enabled, m.status == .done, let summary = m.summary, !summary.isEmpty else { return }
        requestedMeetings.insert(m.id)
        let ctx = makeContext()
        let names = m.speakerNames.values.filter { !$0.isEmpty }
        let (id, title, date) = (m.id, m.title, m.date)
        queue.async {
            self.ensureLoaded()
            guard !self.w.ingestedMeetings.contains(id) else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let mf = SmartAnalyzer.analyzeMeeting(title: title, summary: summary, speakerNames: names, myName: ctx.myName)
            SmartLearner.mergeMeeting(id: id, title: title, date: date, features: mf, into: &self.w)
            var cands: [SmartSuggestion] = []
            if let s = SmartLearner.meetingSuggestion(id: id, title: title, date: date, tasks: mf.myTasks) { cands.append(s) }
            for p in mf.people {
                if let term = self.w.terms[p.lowercased()],
                   let s = SmartLearner.dictionarySuggestion(term, ctx: ctx, expires: Date().addingTimeInterval(ctx.pendingAge)) { cands.append(s) }
            }
            SmartLearner.offer(cands, into: &self.w, ctx: ctx)
            let spell = mf.people.filter { SmartAnalyzer.isTermShaped($0) && self.w.terms[$0.lowercased()]?.spellKnown == nil }
            if !spell.isEmpty { self.requestSpellCheck(spell, ctx: ctx) }
            log(String(format: "Flow lernt mit: Meeting ausgewertet in %.1f ms (%d Personen, %d Themen, %d Aufgaben)",
                       (CFAbsoluteTimeGetCurrent() - t0) * 1000, mf.people.count, mf.topics.count, mf.tasks.count))
            self.scheduleSave(); self.schedulePublish()
        }
        scheduleShowCheck(after: 8)
    }

    private func historyChanged(_ recs: [DictationRecord]) {
        guard let newest = recs.first?.date else { return }
        let cutoff = lastHistoryDate ?? .distantPast
        let fresh = recs.prefix { $0.date > cutoff }
        lastHistoryDate = max(newest, cutoff)
        for r in fresh.reversed() { ingestDictation(text: r.text, bundleID: r.bundleID, date: r.date) }
    }

    private func meetingsChanged(_ ms: [Meeting]) {
        let done = Set(snapshot.ingestedMeetings)
        for m in ms where m.status == .done && !(m.summary ?? "").isEmpty && !done.contains(m.id) && !requestedMeetings.contains(m.id) {
            ingestMeeting(m)
        }
    }

    private func dictionaryChanged(_ d: [DictEntry]) {
        let new = d.filter { !knownDictIDs.contains($0.id) }
        knownDictIDs = Set(d.map(\.id))
        for e in new where e.learned == true && e.heard.lowercased() != e.write.lowercased() {
            noteCorrection(old: e.heard, new: e.write, saved: true)
        }
        // Begriffe, die jetzt im Wörterbuch stehen, aus den offenen Vorschlägen nehmen
        let known = Set(d.flatMap { [$0.heard.lowercased(), $0.write.lowercased()] })
        let stale = visiblePending.filter { $0.kind == .dictionary && known.contains(($0.payload.term ?? "").lowercased()) }
        for s in stale { resolve(s, accepted: nil) }
    }

    // MARK: Verarbeitung (queue)

    private func process(text: String, bundleID: String, date: Date, ctx: SmartContext, backfill: Bool, mainMs: Double = 0) {
        ensureLoaded()
        if let last = w.lastRecordDate, date <= last, backfill { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let cat = AppCategory.of(bundleID: bundleID)
        let f = SmartAnalyzer.analyze(text, myName: ctx.myName, known: ctx.known, now: Date(), category: cat)
        var touched = SmartLearner.merge(f, text: text, date: date, category: cat, into: &w, ctx: ctx)
        if backfill { touched.dates = [] }   // „Freitag 14 Uhr“ von vorgestern ist kein Termin mehr
        w.lastRecordDate = max(w.lastRecordDate ?? date, date)
        let cands = SmartLearner.candidates(touched, w: w, ctx: ctx)
        let added = SmartLearner.offer(cands, into: &w, ctx: ctx)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        perf.add(ms, main: mainMs, backfill: backfill)
        if !touched.needSpell.isEmpty { requestSpellCheck(touched.needSpell, ctx: ctx) }
        if !added.isEmpty {
            log("Flow lernt mit: neuer Vorschlag " + added.map { "\($0.kind.rawValue) \(Int($0.confidence * 100)) %" }.joined(separator: ", ")
                + (Settings.frozen.logTexts ? " – " + added.map(\.key).joined(separator: ", ") : ""))
        }
        if perf.n % 50 == 0, perf.n > 0, !backfill { log(perf.summary) }
        scheduleSave()
        schedulePublish()
    }

    /// Nur für den Selbsttest: synchron verarbeiten und Dauer zurückgeben (ms, Lern-Queue)
    func processForTest(text: String, bundleID: String, date: Date, ctx: SmartContext, backfill: Bool = false) -> Double {
        queue.sync {
            let before = perf.totalMs
            process(text: text, bundleID: bundleID, date: date, ctx: ctx, backfill: backfill)
            return perf.totalMs - before
        }
    }

    private func backfill(_ records: [DictationRecord], ctx: SmartContext) {
        let last = w.lastRecordDate ?? .distantPast
        let todo = records.filter { $0.date > last && SmartPrivacy.blockedApp($0.bundleID) == false }.sorted { $0.date < $1.date }
        guard !todo.isEmpty else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        for r in todo { process(text: r.text, bundleID: r.bundleID, date: r.date, ctx: ctx, backfill: true) }
        log(String(format: "Flow lernt mit: %d Diktate aus dem Verlauf nachgelernt (%.0f ms)", todo.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    private func requestSpellCheck(_ words: [String], ctx: SmartContext) {
        let unique = Array(Set(words)).prefix(20)
        DispatchQueue.main.async {
            let results = unique.map { ($0, SmartPrivacy.spellKnown($0)) }
            self.queue.async {
                var cands: [SmartSuggestion] = []
                let exp = Date().addingTimeInterval(ctx.pendingAge)
                for (word, known) in results {
                    let k = word.lowercased()
                    guard self.w.terms[k] != nil else { continue }
                    self.w.terms[k]!.spellKnown = known
                    if let s = SmartLearner.dictionarySuggestion(self.w.terms[k]!, ctx: ctx, expires: exp) { cands.append(s) }
                }
                SmartLearner.offer(cands, into: &self.w, ctx: ctx)
                self.scheduleSave(); self.schedulePublish()
            }
        }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: SmartFlow.wissenURL), let s = try? JSONDecoder.pg.decode(SmartWissen.self, from: d) {
            w = s
            if w.hours.count != 24 { w.hours = [Int](repeating: 0, count: 24) }
            if w.weekdays.count != 7 { w.weekdays = [Int](repeating: 0, count: 7) }
        }
    }

    // MARK: Speichern / Veröffentlichen (queue)

    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveItem = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func saveNow() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(w) else { return }
        let u = SmartFlow.wissenURL
        do {
            try d.write(to: u, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        } catch { log("Flow lernt mit: Speichern fehlgeschlagen (\(error.localizedDescription))") }
    }

    /// Für Tests: gespeicherten Stand sofort schreiben
    func flush() { queue.sync { saveItem?.cancel(); saveNow() } }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.publishScheduled = false
            self?.publishNow()
        }
    }

    private func publishNow() {
        let snap = w
        DispatchQueue.main.async { self.apply(snap) }
    }

    private func apply(_ snap: SmartWissen) {
        snapshot = snap
        if let l = snap.lastCardAt { lastCardAt = max(lastCardAt ?? l, l) }
        refreshVisible()
    }

    /// Vom Pillen-Takt aufgerufen: ist ein sichtbarer Vorschlag abgelaufen, Liste (und Rahmen) neu berechnen
    func dropExpired() {
        let now = Date()
        if visiblePending.contains(where: { $0.expires <= now }) { refreshVisible() }
    }

    private func refreshVisible() {
        let p = prefs
        let v = snapshot.pending.filter { s in
            p.enabled && p.isOn(s.kind) && !p.stat(s.kind).stopped && s.expires > Date()
                && s.confidence >= SmartPolicy.listThreshold(dismissed: p.stat(s.kind).dismissed)
        }.sorted { $0.confidence > $1.confidence }
        if v != visiblePending { visiblePending = v }
    }

    // MARK: Momentaufnahme der Stores (Main)

    func makeContext() -> SmartContext {
        var c = SmartContext()
        let st = Settings.shared
        for e in st.dictionary {
            c.known.insert(e.write.lowercased()); c.known.insert(e.heard.lowercased())
            for part in e.write.split(separator: " ") where part.count >= 3 { c.known.insert(part.lowercased()) }
        }
        c.myName = Identity.myName
        for s in SnippetStore.shared.snippets { c.snippetTexts.insert(s.text.pgKey); c.snippetTriggers.insert(s.trigger.pgKey) }
        for t in TransformStore.shared.presets { c.transformKeys.insert(String(t.instruction.pgKey.prefix(60))) }
        c.styles = StyleStore.shared.styles.reduce(into: [:]) { r, kv in r[kv.key] = kv.value }
        c.retentionDays = st.retentionDays
        c.prefs = prefs
        return c
    }

    // MARK: Entscheiden (Main)

    /// „Ja“ – Aktion über die vorhandenen Stores/APIs ausführen
    func accept(_ id: UUID, choice: String? = nil) {
        guard let s = snapshot.pending.first(where: { $0.id == id }) else { return }
        actions.perform(s, choice: choice) { [weak self] ok, message in
            guard let self else { return }
            if !message.isEmpty { self.toast(message) }
            if ok {
                self.bump(s.kind) { $0.accepted += 1 }
                self.resolve(s, accepted: true)
            }
            log("Flow lernt mit: Vorschlag \(s.kind.rawValue) angenommen (\(ok ? "ok" : "fehlgeschlagen"))")
        }
    }

    /// „Nein“ – diese Art wird seltener, nach 3× hört sie auf
    func dismiss(_ id: UUID) {
        guard let s = snapshot.pending.first(where: { $0.id == id }) else { return }
        bump(s.kind) { $0.dismissed += 1 }
        resolve(s, accepted: false)
        if prefs.stat(s.kind).stopped {
            toast("Okay – solche Vorschläge kommen nicht mehr")
            log("Flow lernt mit: Art \(s.kind.rawValue) nach \(SmartPolicy.stopAfter)× Nein gestoppt")
        }
    }

    /// ✕ oder Zeitablauf: bleibt leise in der Liste
    func later(_ id: UUID) {}

    private func resolve(_ s: SmartSuggestion, accepted: Bool?) {
        visiblePending.removeAll { $0.id == s.id }
        queue.async {
            self.w.pending.removeAll { $0.id == s.id || $0.key == s.key }
            self.w.decided[s.key] = Date()
            self.scheduleSave(); self.schedulePublish()
        }
    }

    private func bump(_ k: SmartKind, _ f: (inout SmartKindStat) -> Void) {
        var st = prefs.stat(k)
        f(&st)
        prefs.stats[k.rawValue] = st
        savePrefs()
    }

    // MARK: Einstellungen (Main)

    func setEnabled(_ on: Bool) { prefs.enabled = on; savePrefs(); log("Flow lernt mit: \(on ? "an" : "aus")") }
    func setCards(_ on: Bool) { prefs.cards = on; savePrefs() }
    func setKind(_ k: SmartKind, on: Bool) {
        prefs.kinds[k.rawValue] = on
        if on, prefs.stat(k).stopped { var st = prefs.stat(k); st.dismissed = 0; prefs.stats[k.rawValue] = st }
        savePrefs()
    }
    func setNightlyDigest(_ on: Bool) { prefs.nightlyDigest = on; savePrefs(); log("Flow lernt mit: Claude-Überblick \(on ? "an" : "aus")") }

    /// „Alles vergessen“: wissen.json weg, offene Vorschläge weg. Einstellungen bleiben.
    func forgetAll() {
        visiblePending = []
        let ids = MeetingStore.shared.meetings.map(\.id)
        requestedMeetings = Set(ids)
        queue.async {
            self.saveItem?.cancel()
            self.w = SmartWissen()
            try? FileManager.default.removeItem(at: SmartFlow.wissenURL)
            // Vorhandenen Verlauf/Meetings NICHT erneut einlesen (sonst wäre sofort alles wieder da)
            self.w.lastRecordDate = Date()
            self.w.ingestedMeetings = ids
            self.saveNow()
            self.publishNow()
        }
        log("Flow lernt mit: alles vergessen")
    }

    func savePrefs() {
        refreshVisible()
        PGFile.save(prefs, "lernen.json")
    }

    func updatePrefs(_ f: (inout SmartPrefs) -> Void) { f(&prefs); savePrefs() }

    static func loadPrefs() -> SmartPrefs { PGFile.load("lernen.json", as: SmartPrefs.self) ?? SmartPrefs() }

    /// Nur Tests: Einstellungen direkt setzen
    func replacePrefsForTest(_ p: SmartPrefs) { prefs = p; refreshVisible() }

    func setDigest(_ note: SmartDigestNote) { queue.async { self.w.digest = note; self.scheduleSave(); self.schedulePublish() } }

    // MARK: Karten aus der Pille (Main)

    private func scheduleShowCheck(after s: TimeInterval) {
        showCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.considerShowing() }
        showCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: item)
    }

    private func tick() {
        considerShowing()
        if Date().timeIntervalSince(lastMaintenance) > 3600 {
            lastMaintenance = Date()
            let ctx = makeContext()
            queue.async { SmartLearner.prune(&self.w, ctx: ctx); self.scheduleSave(); self.schedulePublish() }
            meetingsChanged(MeetingStore.shared.meetings)
            SmartDigest.runIfDue()
        }
    }

    /// Warum gerade keine Karte (für Tests/Log). nil = darf.
    func cardBlocker(now: Date = Date()) -> String? {
        if !prefs.enabled { return "aus" }
        if !prefs.cards { return "Karten aus" }
        if now.timeIntervalSince(lastDictationAt) < SmartPolicy.quietAfterDictation { return "gerade diktiert" }
        if let l = lastCardAt, now.timeIntervalSince(l) < SmartPolicy.cardInterval { return "30-Minuten-Pause" }
        if isBusy() { return "Diktat/Meeting läuft" }
        if !pillIsIdle() { return "Pille beschäftigt" }
        if VFNotify.shared.isShowing { return "andere Karte sichtbar" }
        if SmartPrivacy.frontAppIsFullscreen() { return "Vollbild" }
        return nil
    }

    /// Welcher Vorschlag als Nächstes eine Karte bekommen dürfte
    func nextCardCandidate(now: Date = Date()) -> SmartSuggestion? {
        visiblePending.filter { s in
            let st = prefs.stat(s.kind)
            guard !s.shownAsCard, s.confidence >= SmartPolicy.cardThreshold(s.kind, dismissed: st.dismissed) else { return false }
            if let lc = st.lastCard, now.timeIntervalSince(lc) < SmartPolicy.cooldown(s.kind, dismissed: st.dismissed) { return false }
            return validateLive(s)
        }.max { $0.confidence < $1.confidence }
    }

    func considerShowing() {
        guard started, !cardsSuppressed else { return }
        if let why = cardBlocker() {
            if why == "gerade diktiert" { scheduleShowCheck(after: SmartPolicy.quietAfterDictation) }
            return
        }
        guard let s = nextCardCandidate() else { return }
        markShown(s)
        VFNotify.shared.show(SmartFlow.notice(for: s))
        log("Flow lernt mit: Karte \(s.kind.rawValue) (\(Int(s.confidence * 100)) %)")
    }

    /// Karte gilt als gezeigt (30-Minuten-Pause, Abklingzeit der Art, danach nur noch in der Liste)
    func markShown(_ s: SmartSuggestion, now: Date = Date()) {
        lastCardAt = now
        bump(s.kind) { $0.shown += 1; $0.lastCard = now }
        queue.async {
            self.w.lastCardAt = now
            if let i = self.w.pending.firstIndex(where: { $0.id == s.id }) { self.w.pending[i].shownAsCard = true }
            self.scheduleSave(); self.schedulePublish()
        }
        if let i = visiblePending.firstIndex(where: { $0.id == s.id }) { visiblePending[i].shownAsCard = true }
    }

    /// Nur Vorschau/Render: Stand anzeigen, ohne zu speichern
    func replaceForPreview(_ w: SmartWissen, prefs p: SmartPrefs? = nil) {
        snapshot = w
        if let p { prefs = p }
        refreshVisible()
    }

    /// Nur Tests: letzte Diktat-Zeit setzen
    func setLastDictationForTest(_ d: Date) { lastDictationAt = d }

    /// Stimmt der Vorschlag noch? (Nutzer kann inzwischen selbst gehandelt haben)
    func validateLive(_ s: SmartSuggestion) -> Bool {
        switch s.kind {
        case .dictionary:
            let t = (s.payload.correctionOld ?? s.payload.term ?? "").lowercased()
            return !Settings.shared.dictionary.contains { $0.heard.lowercased() == t || $0.write.lowercased() == t }
        case .snippet:
            let k = (s.payload.text ?? "").pgKey
            return !SnippetStore.shared.snippets.contains { $0.text.pgKey == k }
        case .style:
            guard let c = AppCategory(rawValue: s.payload.category ?? ""), let k = StyleKind(rawValue: s.payload.style ?? "") else { return false }
            return StyleStore.shared.style(for: c) != k
        case .transform:
            let k = String((s.payload.text ?? "").pgKey.prefix(60))
            return !TransformStore.shared.presets.contains { String($0.instruction.pgKey.prefix(60)) == k }
        case .calendar:
            return (s.payload.date ?? .distantPast) > Date()
        case .reminders:
            return !(s.payload.tasks ?? []).isEmpty
        }
    }

    static func primaryLabel(_ k: SmartKind) -> String {
        switch k {
        case .snippet, .transform: return "Speichern"
        case .dictionary: return "Merken"
        case .style: return "Umstellen"
        case .reminders: return "Übernehmen"
        case .calendar: return "Eintragen"
        }
    }

    static func notice(for s: SmartSuggestion) -> VFNotice {
        let flow = SmartFlow.shared
        let chips = s.kind == .snippet ? (s.payload.triggerOptions ?? []) : []
        return VFNotice(id: "smart_" + s.id.uuidString, title: s.title, text: s.text,
                        illustration: s.kind.illustration, fallbackSymbol: s.kind.symbol,
                        primary: (primaryLabel(s.kind), { flow.accept(s.id, choice: VFNotify.shared.chosen) }),
                        secondary: ("Nein", { flow.dismiss(s.id) }),
                        timeout: SmartPolicy.cardTimeout, anchor: nil,
                        onClose: { flow.later(s.id) }, choices: chips.count > 1 ? chips : [])
    }

    // MARK: Messung

    var perfSummary: String { queue.sync { perf.summary } }
    var perfStats: SmartPerf { queue.sync { perf } }
    func resetPerf() { queue.sync { perf = SmartPerf() } }
}

/// Laufzeit-Messung (nur Zahlen, kein Text)
struct SmartPerf {
    var n = 0
    var totalMs = 0.0
    var maxMs = 0.0
    var mainMsTotal = 0.0
    var backfillN = 0
    var recent: [Double] = []

    mutating func add(_ ms: Double, main: Double, backfill: Bool) {
        if backfill { backfillN += 1 }
        n += 1
        totalMs += ms
        maxMs = max(maxMs, ms)
        mainMsTotal += main
        recent.append(ms)
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
    }

    var avg: Double { n > 0 ? totalMs / Double(n) : 0 }
    var p95: Double {
        guard !recent.isEmpty else { return 0 }
        let s = recent.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * 0.95))]
    }
    var summary: String {
        String(format: "Flow lernt mit: %d Diktate, Ø %.2f ms, p95 %.2f ms, max %.1f ms (Lern-Queue); Main Ø %.3f ms",
               n, avg, p95, maxMs, n > 0 ? mainMsTotal / Double(n) : 0)
    }
}

// MARK: - Datenschutz-Prüfungen

enum SmartPrivacy {
    /// Passwort-Manager & Co.: hier wird nie gelernt
    static let blockedBundles: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc", "com.enpass.Enpass-Desktop", "com.nordpass.macos.NordPass", "com.keepersecurity.passwordmanager",
        "me.proton.pass.electron", "com.proton.pass", "com.roboform.RoboForm", "com.apple.systempreferences",
    ]

    static func blockedApp(_ bundleID: String) -> Bool {
        let b = bundleID.lowercased()
        if CorrectionLearner.blockedApps.contains(bundleID) || blockedBundles.contains(bundleID) { return true }
        return b.contains("password") || b.contains("1password") || b.contains("keychain") || b.contains("bitwarden") || b.contains("keepass")
    }

    /// Nichts lernen aus geschützten Eingaben (Passwortfeld aktiv) oder Passwort-Apps
    static func allowed(bundleID: String) -> Bool {
        if blockedApp(bundleID) { return false }
        if IsSecureEventInputEnabled() { return false }
        return true
    }

    /// Kennt die macOS-Rechtschreibung das Wort (Deutsch oder Englisch)? Nur auf dem Main-Thread.
    static func spellKnown(_ w: String) -> Bool {
        let checker = NSSpellChecker.shared
        for lang in ["de", "en"] {
            let r = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound { return true }
        }
        return false
    }

    /// Läuft die App im Vordergrund im Vollbild (Keynote, Video, Spiel)?
    static func frontAppIsFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map { $0.frame.size }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let size = CGSize(width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if screens.contains(where: { abs($0.width - size.width) < 1 && abs($0.height - size.height) < 1 }) { return true }
        }
        return false
    }
}
