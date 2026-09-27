import AppKit
import SwiftUI

// MARK: - Warteschlange + Zustand für die Oberfläche
//
//  AudioImport.shared.open(urls, origin:)   Dateien annehmen → je Datei eine Notiz „Datei“, Auswertung nacheinander
//  AudioImport.shared.cancel(id)            abbrechen (Zwischenstand bleibt → „Fortsetzen“)
//  AudioImport.shared.resume(id)            fortsetzen bzw. neu auswerten
//  AudioImport.shared.start(pill:)          beim App-Start: Unterbrochenes fortsetzen, Eingangsordner, Pillen-Ablage
// Es läuft immer nur EINE Datei gleichzeitig (Speicher). Zusammenfassungen laufen danach im Hintergrund.

final class AudioImport: ObservableObject {
    static let shared = AudioImport()

    struct Live: Equatable {
        var fraction: Double
        var label: String
        var started: Date
        /// Sekunden bis fertig (grob, aus dem bisherigen Tempo)
        var eta: Double?
        /// Schätz-Hinweis für die Anzeige: ab `hintFrom` (Zeitpunkt `hintAt`) ist nach ~`hintSeconds` das nächste
        /// Stück (`hintNext`) fertig – daraus wird der Pegel zwischen den Stufen weich weitergeschätzt
        var hintFrom: Double? = nil
        var hintNext: Double? = nil
        var hintAt: Date? = nil
        var hintSeconds: Double? = nil
    }

    struct ErrorCard: Identifiable, Equatable {
        let id = UUID()
        let fileName: String
        let message: String
        let date = Date()
    }

    /// Fortschritt je Notiz-ID (nur laufende/wartende)
    @Published private(set) var live: [String: Live] = [:]
    @Published private(set) var runningID: String?
    @Published private(set) var waiting: [String] = []
    /// Letzte Fehler (für die Karte im Notetaker), neueste zuerst
    @Published var errors: [ErrorCard] = []
    /// Datei wird gerade über das Hub-Fenster gezogen
    @Published var hubDropTargeted = false

    var isBusy: Bool { runningID != nil || !waiting.isEmpty }
    /// Gesamtfortschritt für die Pille (laufende Datei)
    var pillFraction: Double? { runningID.flatMap { live[$0]?.fraction } }
    /// Zuletzt erfolgreich fertig gewordene Datei (Pille: Wasser läuft voll und blendet aus)
    private(set) var lastDone: String?

    private var control: AudioImportControl?
    private var worker: Task<Void, Never>?
    private var lastPush = Date.distantPast
    private var pendingLive: (String, Double, String)?
    private(set) var inbox: AudioInbox?

    /// Läuft in der echten App (Meldungen an der Pille, Fenster öffnen) – nicht im CLI-Test
    var appMode: Bool { NSApp?.delegate is AppDelegate }

    private init() {}

    static func isFileNote(_ id: String) -> Bool { AudioImportFiles.isFileNote(id) }

    // MARK: Annehmen

    /// Nimmt Dateien (oder Ordner → Audiodateien darin) an. Liefert die neuen Notiz-IDs.
    @discardableResult
    func open(_ urls: [URL], origin: AudioImportOrigin, ownedCopies: Bool = false) -> [String] {
        dispatchPrecondition(condition: .onQueue(.main))
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files += inside.filter { AudioImportFormats.accepts($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files.append(u)
            }
        }
        var ids: [String] = []
        for f in files {
            guard AudioImportFormats.accepts(f) else {
                reportError(file: f.lastPathComponent, "„\(f.lastPathComponent)“ ist keine Audio- oder Videodatei.")
                continue
            }
            let path = f.standardizedFileURL.path
            if let running = AudioImportFiles.allJobs().first(where: { $0.source == path && $0.phase.isActive }) {
                log("Audiodatei läuft schon: \(running.id)")
                if appMode { (NSApp.delegate as? AppDelegate)?.pill?.view.showToast("„\(f.lastPathComponent)“ läuft schon", seconds: 2) }
                continue
            }
            ids.append(createNote(for: f, origin: origin, owned: ownedCopies))
        }
        if !ids.isEmpty, appMode {
            let n = ids.count
            (NSApp.delegate as? AppDelegate)?.pill?.view.showToast(n == 1 ? "Datei wird transkribiert" : "\(n) Dateien werden transkribiert", seconds: 2)
        }
        pump()
        return ids
    }

    private func createNote(for url: URL, origin: AudioImportOrigin, owned: Bool = false) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HHmm"
        let now = Date()
        let id = df.string(from: now) + "_" + String(UUID().uuidString.prefix(4)) + "_datei"
        let name = url.lastPathComponent
        var m = Meeting(id: id, title: url.deletingPathExtension().lastPathComponent, date: now, app: "Datei")
        m.status = .processing
        m.progressNote = "Wartet …"
        m.duration = AudioDecoder.probeDuration(url) ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var job = AudioImportJob(id: id, source: url.standardizedFileURL.path, fileName: name, origin: origin, bytes: size, added: now)
        if owned { job.ownedCopy = true }
        try? FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
        AudioImportFiles.saveJob(job)
        MeetingStore.shared.save(m)
        if MeetingStore.shared.selectedID == nil || origin != .inbox { MeetingStore.shared.selectedID = id }
        live[id] = Live(fraction: 0, label: "Wartet …", started: now)
        waiting.append(id)
        log("Audiodatei angenommen (\(origin.rawValue)): \(name) → \(id)")
        return id
    }

    // MARK: Steuern

    func cancel(_ id: String) {
        if runningID == id { control?.cancel(); return }
        guard waiting.contains(id) else { return }
        waiting.removeAll { $0 == id }
        live[id] = nil
        if var j = AudioImportFiles.loadJob(id) { j.phase = .cancelled; AudioImportFiles.saveJob(j) }
        markCancelled(id)
    }

    func cancelAll() {
        for id in waiting { cancel(id) }
        if let r = runningID { cancel(r) }
    }

    /// Fortsetzen (Abbruch/Unterbrechung) oder komplett neu auswerten (fertige Notiz).
    func resume(_ id: String) {
        guard var j = AudioImportFiles.loadJob(id), runningID != id, !waiting.contains(id) else { return }
        if j.phase == .done || j.phase == .summarizing {
            // Neu auswerten: Zwischenstände weg, Original wieder dekodieren
            if !FileManager.default.fileExists(atPath: j.source) {
                reportError(file: j.fileName, "Die Originaldatei „\(j.fileName)“ ist nicht mehr da – neu auswerten geht nur mit der Datei.")
                return
            }
            AudioImportFiles.removeScratch(id)
            j.decoded = false; j.diarized = false; j.chunks = []; j.chunksDone = 0; j.whisperSeconds = 0; j.whisperCalls = 0; j.timings = [:]
        }
        j.resumes += 1
        j.phase = .queued; j.error = nil
        AudioImportFiles.saveJob(j)
        if var m = MeetingStore.shared.meeting(id) {
            m.status = .processing; m.progressNote = "Wird fortgesetzt …"
            MeetingStore.shared.save(m)
        }
        live[id] = Live(fraction: j.fraction, label: "Wartet …", started: Date())
        waiting.append(id)
        pump()
    }

    // MARK: App-Start

    private var started = false

    func start(pill: PillController?) {
        guard !started else { return }
        started = true
        // Unterbrochene Aufträge (App beendet/abgestürzt) fortsetzen – wie unterbrochene Meetings
        for j in AudioImportFiles.allJobs().sorted(by: { $0.added < $1.added }) {
            if j.phase.isActive {
                log("Audiodatei: setze unterbrochene Auswertung fort: \(j.id) (\(j.chunksDone)/\(j.chunks.count) Stücke)")
                resume(j.id)
            } else if j.phase == .summarizing {
                var jj = j; jj.phase = .done; AudioImportFiles.saveJob(jj)
                if var m = MeetingStore.shared.meeting(j.id), m.status == .failed { m.status = .done; m.progressNote = nil; MeetingStore.shared.save(m) }
                if Settings.shared.autoSummary { Task { await MeetingProcessor.summarize(id: j.id, force: false) } }
            } else if j.phase == .cancelled, var m = MeetingStore.shared.meeting(j.id), m.status == .failed {
                m.progressNote = cancelledNote(j); MeetingStore.shared.save(m)
            }
        }
        AudioDropReader.cleanupOrphans()
        if let pill { AudioImportPillOverlay.shared.attach(pill) }
        inbox = AudioInbox()
        inbox?.apply()
        AudioImportSettings.shared.onInboxChange = { [weak self] in self?.inbox?.apply() }
    }

    // MARK: Abarbeiten

    private func pump() {
        guard runningID == nil, let next = waiting.first else { return }
        waiting.removeFirst()
        runningID = next
        let ctl = AudioImportControl()
        control = ctl
        let startedAt = Date()
        live[next] = Live(fraction: live[next]?.fraction ?? 0, label: "Datei wird gelesen …", started: startedAt)
        ctl.onProgress = { [weak self] f, s in
            DispatchQueue.main.async { self?.pushLive(next, f, s) }
        }
        ctl.onHint = { [weak self] from, to, secs in
            DispatchQueue.main.async { self?.pushHint(next, from: from, next: to, seconds: secs) }
        }
        worker = Task.detached(priority: .utility) { [weak self] in
            let outcome = await AudioImportProcessor.run(id: next, control: ctl)
            await MainActor.run { self?.finished(next, outcome) }
        }
    }

    private func pushLive(_ id: String, _ f: Double, _ s: String) {
        guard var l = live[id] else { return }
        // höchstens 5×/s neu zeichnen
        if Date().timeIntervalSince(lastPush) < 0.2, abs(f - l.fraction) < 0.02 { return }
        lastPush = Date()
        l.fraction = max(l.fraction, f)
        l.label = s
        let el = Date().timeIntervalSince(l.started)
        l.eta = l.fraction > 0.08 && el > 3 ? el / l.fraction * (1 - l.fraction) : nil
        live[id] = l
        AudioImportPillOverlay.shared.refresh()
    }

    /// Schätz-Hinweis (nie gedrosselt – kommt nur einmal je Stück)
    private func pushHint(_ id: String, from: Double, next: Double, seconds: Double) {
        guard var l = live[id] else { return }
        l.fraction = max(l.fraction, from)
        l.hintFrom = from; l.hintNext = next; l.hintAt = Date(); l.hintSeconds = seconds
        live[id] = l
    }

    private func finished(_ id: String, _ outcome: AudioImportProcessor.Outcome) {
        runningID = nil
        control = nil
        worker = nil
        live[id] = nil
        if case .done = outcome { lastDone = id }
        AudioImportPillOverlay.shared.finishedRunning(id, success: { if case .done = outcome { return true }; return false }())
        AudioProgressSmoother.shared.forget(id)
        let job = AudioImportFiles.loadJob(id)
        switch outcome {
        case .done:
            if let job, job.origin == .inbox { inbox?.moveDone(job) }
            if let job, job.ownedCopy == true { adoptOwnedCopy(job) }
            let willSummarize = Settings.shared.autoSummary && !(MeetingStore.shared.meeting(id)?.segments.isEmpty ?? true)
            // Sofort melden (nicht erst nach der Zusammenfassung) – der Titel wird nachgereicht, sobald Claude fertig ist
            notifyDone(id, summarizing: willSummarize)
            if willSummarize {
                if var j = AudioImportFiles.loadJob(id) { j.phase = .summarizing; AudioImportFiles.saveJob(j) }
                Task.detached(priority: .utility) {
                    await MeetingProcessor.summarize(id: id, force: false)
                    await MainActor.run {
                        if var j = AudioImportFiles.loadJob(id) { j.phase = .done; AudioImportFiles.saveJob(j) }
                        AudioImport.shared.updateDoneCard(id)
                    }
                }
            }
        case .cancelled:
            markCancelled(id)
        case .failed(let msg):
            if var m = MeetingStore.shared.meeting(id) { m.status = .failed; m.progressNote = msg; MeetingStore.shared.save(m) }
            reportError(file: job?.fileName ?? "Datei", msg)
        case .decodeFailed(let msg):
            // Nichts Brauchbares in der Datei → keine leere Notiz zurücklassen, nur die Fehlerkarte
            if let job, job.origin == .inbox { inbox?.moveFailed(job) }
            if let job, job.ownedCopy == true, AudioDropReader.isInside(job.source, AudioDropReader.promiseRoot) {
                try? FileManager.default.removeItem(at: job.sourceURL.deletingLastPathComponent())   // nie außerhalb von abgelegt/
            }
            MeetingStore.shared.delete(id)
            reportError(file: job?.fileName ?? "Datei", msg)
        case .gone:
            if let job, job.ownedCopy == true, AudioDropReader.isInside(job.source, AudioDropReader.promiseRoot) {
                try? FileManager.default.removeItem(at: job.sourceURL.deletingLastPathComponent())
            }
            log("Audiodatei \(id): Notiz wurde gelöscht – Auswertung beendet")
        }
        AudioImportPillOverlay.shared.refresh()
        if waiting.isEmpty {
            // Warteschlange leer → Sprechertrennung freigeben + freie Blöcke an macOS zurück
            Task.detached(priority: .utility) {
                await AudioImportDiarizer.shared.release()
                MemorySaver.trimMalloc()
            }
        }
        pump()
    }

    private func cancelledNote(_ j: AudioImportJob) -> String {
        let pct = Int(j.fraction * 100)
        return pct > 0 ? "Abgebrochen bei \(pct) % – Rechtsklick → „Neu auswerten“ setzt fort" : "Abgebrochen – Rechtsklick → „Neu auswerten“ setzt fort"
    }

    private func markCancelled(_ id: String) {
        guard var m = MeetingStore.shared.meeting(id) else { return }
        let j = AudioImportFiles.loadJob(id)
        m.status = .failed
        m.progressNote = j.map(cancelledNote) ?? "Abgebrochen"
        MeetingStore.shared.save(m)
        log("Audiodatei \(id): abgebrochen")
    }

    func reportError(file: String, _ message: String) {
        log("Audiodatei-Fehler (\(file)): \(message)")
        errors.insert(ErrorCard(fileName: file, message: message), at: 0)
        if errors.count > 3 { errors.removeLast(errors.count - 3) }
        guard appMode else { return }
        VFNotify.shared.show(VFNotice(id: "audiodatei_fehler", title: "Datei nicht lesbar", text: message,
                                      illustration: "illu_leer", fallbackSymbol: "exclamationmark.triangle.fill",
                                      primary: ("Andere Datei wählen …", { AudioImport.shared.pickFiles() }), secondary: ("OK", {}),
                                      timeout: 20))
    }

    /// Versprochene Datei (Sprachmemos …) in den Notiz-Ordner übernehmen → wird mit der Notiz gelöscht
    private func adoptOwnedCopy(_ job: AudioImportJob) {
        let src = job.sourceURL
        guard AudioDropReader.isInside(src.path, AudioDropReader.promiseRoot), FileManager.default.fileExists(atPath: src.path) else { return }
        let dst = AudioImportFiles.folder(job.id).appendingPathComponent("original." + src.pathExtension)
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: src, to: dst)
            try? FileManager.default.removeItem(at: src.deletingLastPathComponent())
            if var j = AudioImportFiles.loadJob(job.id) { j.source = dst.path; AudioImportFiles.saveJob(j) }
        } catch { log("Audiodatei: abgelegte Datei nicht übernommen: \(error.localizedDescription)") }
    }

    /// Welche Notiz zeigt die Fertig-Karte gerade?
    private(set) var doneCardID: String?

    /// Karte „Sprachmemo · <worum es geht>“ mit „Transkript öffnen“ / „Kopieren“
    func doneNotice(_ id: String, summarizing: Bool) -> VFNotice? {
        guard let m = MeetingStore.shared.meeting(id) else { return nil }
        let job = AudioImportFiles.loadJob(id)
        let kind = job?.kindLabel ?? "Datei"
        var facts: [String] = [kind]
        if m.duration >= 1 { facts.append(HubNoteDetail.duration(m.duration)) }
        let n = m.speakerKeys.count
        if n > 0 { facts.append(n == 1 ? "1 Sprecher" : "\(n) Sprecher") }
        // Titel = Art + Eckdaten (kurz, passt immer); Text = worum es geht (darf umbrechen, wird nicht abgeschnitten)
        // Zusammenfassung läuft noch → erst der Dateiname, der Claude-Titel wird in derselben Karte nachgereicht
        let gist = "„\(m.title)“"
        return VFNotice(id: "audiodatei_fertig", title: facts.joined(separator: " · "), text: gist,
                        illustration: "illu_insights", fallbackSymbol: VFNotify.symbol(for: "illu_insights"),
                        primary: ("Transkript öffnen", { AudioImport.openTranscript(id) }),
                        secondary: ("Kopieren", { AudioImport.copyTranscript(id) }),
                        timeout: summarizing ? 30 : 15)
    }

    func notifyDone(_ id: String, summarizing: Bool) {
        guard appMode, AudioImportSettings.shared.notifyWhenDone, let n = doneNotice(id, summarizing: summarizing) else { return }
        doneCardID = id
        VFNotify.shared.show(n)
    }

    /// Zusammenfassung fertig → Titel in der noch offenen Karte nachreichen (nie eine zweite Karte aufdrängen)
    func updateDoneCard(_ id: String) {
        guard appMode, doneCardID == id, VFNotify.shared.currentID == "audiodatei_fertig",
              let n = doneNotice(id, summarizing: false) else { return }
        VFNotify.shared.show(n)
    }

    /// Transkript-Reiter der Notiz öffnen (ganzer Text, oben)
    static func openTranscript(_ id: String) {
        MeetingStore.shared.selectedID = id
        HubNoteDetail.pendingTab = .transkript
        HubNotetakerPage.pendingOpen = id
        VoiceFlowWindow.shared.show(.notetaker)
        NotificationCenter.default.post(name: HubNotetakerPage.openNoteRequest, object: id)
    }

    static func copyTranscript(_ id: String) {
        guard let m = MeetingStore.shared.meeting(id), !m.segments.isEmpty else { return }
        Inserter.copy(m.transcriptText(), source: "Meeting")
        (NSApp.delegate as? AppDelegate)?.pill?.view.showToast("Transkript kopiert", seconds: 1.6)
    }

    func dismissError(_ e: ErrorCard) { errors.removeAll { $0.id == e.id } }

    // MARK: Hilfen für die Oberfläche

    static func openNote(_ id: String) { openTranscript(id) }

    /// „Datei wählen …“
    func pickFiles() {
        let p = NSOpenPanel()
        p.title = "Audiodatei transkribieren"
        p.prompt = "Transkribieren"
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = AudioImportFormats.contentTypes
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { open(p.urls, origin: .picker) }
    }
}

// MARK: - Nur Sichtprüfung: Zustand vorgeben, ohne etwas auszuwerten
extension AudioImport {
    func previewState(live: [String: Live], running: String?, waiting: [String], errors: [ErrorCard]) {
        self.live = live
        self.runningID = running
        self.waiting = waiting
        self.errors = errors
    }
}
