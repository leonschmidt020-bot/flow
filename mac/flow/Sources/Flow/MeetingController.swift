import AppKit
import AVFoundation

/// Meeting-Aufnahme: eigenes Mikrofon + Systemton getrennt, Live-Mitschrift,
/// danach Sprechertrennung, Stimmerkennung und Zusammenfassung.
final class MeetingController {
    static var activeID: String?

    private let pill: PillController
    private let store = MeetingStore.shared
    private let detector = MeetingAppDetector()
    private var mic: MicCapture?
    private var tap: SystemAudioTap?
    private var micWriter: WavWriter?
    private var sysWriter: WavWriter?
    private var micSeg = LiveSegmenter()
    private var sysSeg = LiveSegmenter()
    private var current: Meeting?
    private var startedAt = Date()
    private var autoStartedFor: String?
    /// Anruf-App dieses Meetings (für „Meeting vorbei?“)
    private var callApp: String?
    private var callAppName: String?
    private var micUsesVP = false
    /// Nach dem Beenden über „Meeting vorbei?“ das Transkript direkt zeigen
    private var showWhenDone = false
    /// Meldungskarten (aus der Pille): „Meeting erkannt“, „Meeting vorbei?“, „Transkript fertig“
    var notifyDetected: ((String, @escaping () -> Void, @escaping () -> Void) -> Void)?
    /// Karte „Meeting abgeschlossen?“ – Antwort: true = beenden, false = ausdrücklich weiter aufnehmen, nil = weggeklickt/abgelaufen
    var askOver: ((String, @escaping (Bool?) -> Void) -> Void)?
    var notifyReady: ((String, String) -> Void)?
    private var appGoneSince: Date?
    private var promptedFor: Set<String> = []
    private var promptApp: MeetingAppDetector.ActiveApp?
    private let liveQueue = DispatchQueue(label: "flow.meeting.live")
    private var window: MeetingWindowController?
    private var sysFrames: Int64 = 0
    private var micFrames: Int64 = 0

    var isRecording: Bool { current != nil }

    var restingPillMode: PillView.Mode {
        if isRecording { return .meeting(start: startedAt) }
        return .idle
    }

    init(pill: PillController) { self.pill = pill }

    // MARK: Erkennung

    func startDetection() {
        detector.onChange = { [weak self] apps in self?.appsChanged(apps) }
        detector.start(interval: 3)
        // Anruf-App ganz geschlossen (z. B. WhatsApp beendet) → Meeting sofort beenden, nicht weiter aufnehmen
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let self, self.isRecording, let call = self.callApp,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier?.lowercased(),
                  id == call.lowercased() || id.hasPrefix(call.lowercased() + ".") else { return }
            log("Meeting: \(self.callAppName ?? call) wurde beendet → Aufnahme endet")
            self.pill.view.showToast("\(self.callAppName ?? "Anruf-App") geschlossen – Meeting beendet", seconds: 3)
            self.showWhenDone = true
            self.stop()
        }
    }

    private func appsChanged(_ apps: [MeetingAppDetector.ActiveApp]) {
        // Apps, die das Mikro losgelassen haben, dürfen beim nächsten Mal wieder fragen.
        promptedFor = promptedFor.filter { id in apps.contains { $0.bundleID == id } }
        if isRecording {
            // Welche Anruf-App gehört zu diesem Meeting? (auch bei manuell gestarteter Aufnahme)
            if callApp == nil, let first = apps.first {
                callApp = first.bundleID; callAppName = first.name
                MeetingContext.shared.callAppChanged(first.bundleID)
            }
            updateMicMode(callActive: !apps.isEmpty)
            if let call = callApp {
                if apps.contains(where: { $0.bundleID == call }) {
                    appGoneSince = nil
                } else if appGoneSince == nil {
                    appGoneSince = Date()
                    log("Meeting: \(callAppName ?? call) hat das Mikro freigegeben")
                    // 4 s Puffer (kurze Aussetzer), dann fragen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        guard let self, self.isRecording, self.appGoneSince != nil else { return }
                        self.askMeetingOver()
                    }
                }
            }
            return
        }
        if case .prompt = pill.view.mode, let p = promptApp, !apps.contains(where: { $0.bundleID == p.bundleID }) {
            dismissPrompt()
        }
        guard Settings.shared.meetingDetection != .off,
              let app = apps.first(where: { !promptedFor.contains($0.bundleID) }) else { return }
        promptedFor.insert(app.bundleID)
        switch Settings.shared.meetingDetection {
        case .auto:
            start(app: app.name)
            autoStartedFor = app.bundleID
            pill.view.showToast("\(app.name): Meeting-Aufnahme läuft", seconds: 3)
        case .ask:
            promptApp = app
            if let notify = notifyDetected {
                // Karte wächst aus der Pille („Meeting erkannt“ + Aufnehmen / Nicht jetzt)
                notify(app.name, { [weak self] in self?.acceptPrompt() }, { [weak self] in self?.dismissPrompt() })
            } else {
                guard case .idle = pill.view.mode else { return }
                pill.view.mode = .prompt("Meeting erkannt · \(app.name)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                    if case .prompt = self?.pill.view.mode, self?.promptApp == app { self?.dismissPrompt() }
                }
            }
        case .off: break
        }
    }

    /// Nur zum Testen der Meldung ohne echtes Meeting.
    func simulateDetected(name: String) {
        guard !isRecording else { return }
        let app = MeetingAppDetector.ActiveApp(bundleID: "test.\(name.lowercased())", name: name, pid: 0)
        promptedFor.remove(app.bundleID)
        promptApp = app
        pill.view.mode = .prompt("Meeting erkannt · \(app.name)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            if case .prompt = self?.pill.view.mode, self?.promptApp == app { self?.dismissPrompt() }
        }
    }

    /// Test: so tun, als hätte die Anruf-App das Mikro freigegeben
    func simulateCallEnded() {
        guard isRecording else { return }
        callAppName = callAppName ?? "FaceTime"
        appGoneSince = Date()
        askMeetingOver()
    }

    /// Karte „Meeting abgeschlossen?“ – „Ja, beenden“ → Transkript; „Weiter aufnehmen“ → läuft weiter.
    /// Weggeklickt, abgelaufen oder von einem Diktat verdrängt zählt NICHT als weiter aufnehmen: nach 12 s wird noch
    /// einmal gefragt, und spätestens 60 s nach dem Freigeben des Mikros endet die Aufnahme von selbst.
    private func askMeetingOver() {
        guard let gone = appGoneSince else { return }
        let name = callAppName ?? "Anruf"
        var answered = false
        askOver?(name) { [weak self] answer in
            guard let self, !answered, self.isRecording, self.appGoneSince == gone else { return }
            switch answer {
            case true?:
                answered = true
                self.showWhenDone = true; self.stop()
            case false?:
                answered = true
                self.appGoneSince = nil; self.callApp = nil; self.pill.view.mode = self.restingPillMode   // weiter aufnehmen
            case nil:
                // nur weggeklickt – später noch einmal fragen (die 60-s-Grenze läuft weiter)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, self.isRecording, self.appGoneSince == gone,
                          Date().timeIntervalSince(gone) < 50 else { return }
                    self.askMeetingOver()
                }
            }
        }
        // Keine ausdrückliche Antwort → 60 s nach dem Freigeben selbst beenden (einmal pro Freigabe)
        guard !overDeadlineArmed else { return }
        overDeadlineArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, 60 - Date().timeIntervalSince(gone))) { [weak self] in
            guard let self else { return }
            self.overDeadlineArmed = false
            guard self.isRecording, self.appGoneSince == gone else { return }
            log("Meeting: keine Antwort 60 s nach dem Freigeben → Aufnahme endet")
            self.pill.view.showToast("Meeting beendet – wird ausgewertet", seconds: 3)
            self.showWhenDone = true
            self.stop()
        }
    }
    private var overDeadlineArmed = false

    /// Im Anruf NIE Apples Sprachverarbeitung einschalten: gemessen – dann bekommt eine Anruf-App ohne sie (z. B. Teams)
    /// nur noch absolute Stille, die anderen im Meeting hören dich nicht. Stattdessen bleibt das Mikro normal und wird
    /// bei Bedarf selbst verstärkt (MicCapture.callBoost) – kein Neustart, die Anruf-App merkt nichts.
    private func updateMicMode(callActive: Bool) {
        guard isRecording, let mc = mic, callActive != micUsesVP else { return }
        micUsesVP = callActive
        mc.callBoost = callActive
        log("Meeting-Mikro: \(callActive ? "Anruf läuft – eigene Verstärkung an" : "normal")")
    }

    var callActive: Bool { !detector.active.isEmpty }

    func acceptPrompt() {
        guard let app = promptApp else { return }
        promptApp = nil
        pill.view.mode = .idle
        start(app: app.name)
        autoStartedFor = app.bundleID
    }

    func dismissPrompt() {
        promptApp = nil
        if case .prompt = pill.view.mode { pill.view.mode = .idle }
    }

    // MARK: Aufnahme

    func toggle() { isRecording ? stop() : start(app: nil) }

    func start(app: String?) {
        guard !isRecording else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            pill.view.showToast("Mikrofon-Zugriff fehlt")
            return
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HHmm"
        let now = Date()
        let tf = DateFormatter(); tf.locale = Locale(identifier: "de_DE"); tf.dateFormat = "d. MMM, HH:mm"
        var m = Meeting(id: df.string(from: now) + "_" + String(UUID().uuidString.prefix(4)),
                        title: (app.map { "\($0)-Meeting" } ?? "Meeting") + " · " + tf.string(from: now),
                        date: now, app: app)
        m.status = .recording
        try? FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
        do {
            micWriter = try WavWriter(url: m.micURL)
            sysWriter = try WavWriter(url: m.systemURL)
        } catch {
            pill.view.showToast("Aufnahme-Datei nicht anlegbar")
            log("WAV-Fehler: \(error)")
            return
        }
        micFrames = 0; sysFrames = 0
        micSeg = LiveSegmenter(); sysSeg = LiveSegmenter()
        micSeg.onSegment = { [weak self] t, s in self?.liveTranscribe(t, s, speaker: "me") }
        sysSeg.onSegment = { [weak self] t, s in self?.liveTranscribe(t, s, speaker: "live") }

        let mc = MicCapture()
        mc.onSamples = { [weak self] s in
            guard let self else { return }
            self.liveQueue.async {
                self.micWriter?.write(s); self.micFrames += Int64(s.count); self.micSeg.feed(s)
            }
        }
        mc.onLevel = { [weak self] lv in DispatchQueue.main.async { if case .meeting = self?.pill.view.mode { self?.pill.view.level = lv } } }
        micUsesVP = callActive
        mc.voiceProcessing = false          // siehe updateMicMode – nie Sprachverarbeitung
        mc.callBoost = micUsesVP
        do { try mc.start(deviceUID: Settings.shared.micUID) } catch {
            micWriter?.close(); sysWriter?.close(); micWriter = nil; sysWriter = nil
            try? FileManager.default.removeItem(at: m.folder)
            pill.view.showToast("Mikrofon startet nicht"); return
        }
        mic = mc
        if let first = detector.active.first { callApp = first.bundleID; callAppName = first.name }
        log("Meeting-Mikro: \(micUsesVP ? "Anruf läuft – eigene Verstärkung an" : "normal")")

        let st = SystemAudioTap()
        do {
            try st.start { [weak self] s in
                guard let self else { return }
                var sum: Float = 0; for x in s { sum += x * x }
                let rms = sqrt(sum / Float(max(s.count, 1)))
                let lv = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 43))
                DispatchQueue.main.async { self.pill.view.level2 = lv }
                self.liveQueue.async {
                    // Systemton an die Mikro-Zeitachse angleichen (Tap startet evtl. später / pausiert bei Stille).
                    if self.sysFrames < self.micFrames - 16000 {
                        self.sysWriter?.pad(to: self.micFrames); self.sysSeg.feed([Float](repeating: 0, count: Int(self.micFrames - self.sysFrames)))
                        self.sysFrames = self.micFrames
                    }
                    self.sysWriter?.write(s); self.sysFrames += Int64(s.count); self.sysSeg.feed(s)
                }
            }
            tap = st
        } catch {
            log("Systemton-Tap fehlgeschlagen: \(error)")
            pill.view.showToast("Nur Mikrofon – Systemton nicht erlaubt", seconds: 3.5)
        }

        current = m
        MeetingController.activeID = m.id
        startedAt = now
        store.save(m)
        store.selectedID = m.id
        pill.view.mode = .meeting(start: now)
        // Meeting-Kontext: Meeting-Fenster mitschneiden (falls eingeschaltet + Freigabe da)
        MeetingContext.shared.meetingStarted(id: m.id, folder: m.folder, startedAt: now, callApp: callApp)
        log("Meeting gestartet \(m.id) app=\(app ?? "-") tap=\(tap != nil)")
    }

    private var livePending = 0
    private var liveChain: Task<Void, Never>?

    /// Live-Mitschrift: nacheinander, höchstens 3 wartende Abschnitte (älteste werden übersprungen)
    private func liveTranscribe(_ t: Double, _ samples: [Float], speaker: String) {
        DispatchQueue.main.async {
            guard self.livePending < 3 else { return }
            self.livePending += 1
            let prev = self.liveChain
            self.liveChain = Task {
                await prev?.value
                defer { Task { @MainActor in self.livePending -= 1 } }
                guard let r = try? await Transcriber.shared.transcribe(samples), !r.text.isEmpty else { return }
                let text = TextCleaner.applyRules(r.text, settings: Settings.shared)
                guard !text.isEmpty else { return }
                await MainActor.run {
                    guard var m = self.current else { return }
                    let seg = Segment(speaker: speaker, start: t, end: t + Double(samples.count) / 16000, text: text)
                    let i = m.segments.firstIndex { $0.start > t } ?? m.segments.count
                    m.segments.insert(seg, at: i)
                    m.duration = Date().timeIntervalSince(self.startedAt)
                    self.current = m
                    self.store.update(m)
                }
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard var m = current else { completion?(); return }
        MeetingContext.shared.meetingStopped(id: m.id)
        mic?.stop(); mic = nil
        tap?.stop(); tap = nil
        liveQueue.sync {
            micSeg.flush(); sysSeg.flush()
            if sysFrames > 0 { sysWriter?.pad(to: micFrames) }
        }
        micWriter?.close(); sysWriter?.close()
        micWriter = nil; sysWriter = nil
        autoStartedFor = nil; appGoneSince = nil; callApp = nil; callAppName = nil; micUsesVP = false
        let openAfter = showWhenDone
        showWhenDone = false
        m.duration = Date().timeIntervalSince(startedAt)
        m.status = .processing
        m.progressNote = "Sprecher werden erkannt …"
        current = nil
        store.save(m)
        pill.view.mode = .idle
        pill.view.level = 0; pill.view.level2 = 0
        pill.view.showToast("Meeting gespeichert – wird ausgewertet", seconds: 2.5)
        log("Meeting gestoppt \(m.id), \(Int(m.duration)) s")
        let id = m.id
        Task {
            await MeetingProcessor.process(id: id)
            MeetingController.activeID = nil
            await MainActor.run {
                if openAfter { self.store.selectedID = id; self.showWindow() }
                else if let done = self.store.meeting(id), done.status == .done { self.notifyReady?(done.title, id) }
                completion?()
            }
        }
    }

    func showWindow() {
        if let c = current { store.selectedID = c.id }
        VoiceFlowWindow.shared.show(.notetaker)
    }

    // MARK: Fragen an das Meeting

    func whatDidIMiss(meetingID: String) { ask(meetingID: meetingID, question: "Was habe ich verpasst?", recap: true) }

    func ask(meetingID: String, question: String, recap: Bool = false) {
        guard var m = store.meeting(meetingID) else { return }
        let msg = ChatMessage(question: question)
        m.chat.append(msg)
        if current?.id == meetingID { current?.chat = m.chat; store.update(m) } else { store.save(m) }
        var transcript = m.transcriptText()
        if recap {
            // Letzte ~6 Minuten genügen für „was hab ich verpasst“.
            let cutoff = max(0, (m.segments.last?.end ?? 0) - 360)
            let recent = m.segments.filter { $0.start >= cutoff }
            var tmp = m; tmp.segments = recent
            transcript = tmp.transcriptText()
        }
        let system = recap
            ? "Du hilfst in einem laufenden Meeting. Fasse in 3–6 kurzen Stichpunkten zusammen, was zuletzt besprochen wurde – Entscheidungen, Fragen an mich, Aufgaben zuerst. Antworte auf Deutsch, knapp, ohne Einleitung."
            : "Du beantwortest Fragen zu einem Meeting-Transkript. Antworte auf Deutsch, knapp und konkret, zitiere Namen und Zeitstempel wenn hilfreich. Wenn das Transkript die Antwort nicht enthält, sag das."
        let input = "Transkript:\n\(transcript)\n\n\(MeetingContext.askContext(meetingID))Frage: \(question)"
        Task {
            let answer: String
            do {
                // Gibt es Bilder (Schlüsselbilder/eigene Screenshots)? Dann darf Claude sie ansehen (nur Lesen, nur das Paket).
                if !recap, let visual = await MeetingVisualSummary.ask(meetingID: meetingID, system: system, input: input) { answer = visual }
                else { answer = try await ClaudeCLI.run(system: system, input: input, model: "sonnet", timeout: 120) }
            }
            catch {
                answer = ClaudeCLI.isAvailable ? "⚠︎ \(error.localizedDescription)"
                    : "⚠︎ Fragen und Zusammenfassungen brauchen die optionale Claude-CLI (nicht installiert). Das Transkript ist trotzdem vollständig."
            }
            await MainActor.run {
                guard var mm = self.store.meeting(meetingID) else { return }
                if let i = mm.chat.firstIndex(where: { $0.id == msg.id }) { mm.chat[i].answer = answer }
                if self.current?.id == meetingID { self.current?.chat = mm.chat; self.store.update(mm) } else { self.store.save(mm) }
            }
        }
    }

    /// Sprecher umbenennen (optional Stimme merken).
    func rename(meetingID: String, speaker: String, to name: String, remember: Bool) {
        guard var m = store.meeting(meetingID) else { return }
        m.speakerNames[speaker] = name
        if remember, let e = m.speakerEmbeddings[speaker] { VoiceStore.remember(name: name, embedding: e) }
        if current?.id == meetingID { current?.speakerNames = m.speakerNames; store.update(m) } else { store.save(m) }
    }

    func reprocess(meetingID: String) {
        if AudioImport.isFileNote(meetingID) { AudioImport.shared.resume(meetingID); return }   // Audiodatei: fortsetzen/neu
        guard var m = store.meeting(meetingID), m.status != .recording else { return }
        m.status = .processing; m.progressNote = "Wird neu ausgewertet …"
        store.save(m)
        Task { await MeetingProcessor.process(id: meetingID) }
    }

    func summarize(meetingID: String) {
        Task { await MeetingProcessor.summarize(id: meetingID, force: true) }
    }
}

/// Auswertung nach dem Meeting (läuft komplett lokal, nur die Zusammenfassung geht an Claude).
enum MeetingProcessor {
    private static func note(_ id: String, _ text: String?) async {
        await MainActor.run {
            guard var m = MeetingStore.shared.meeting(id) else { return }
            m.progressNote = text
            MeetingStore.shared.update(m)
        }
    }

    static func process(id: String) async {
        guard var m = await MainActor.run(body: { MeetingStore.shared.meeting(id) }) else { return }
        let t0 = Date()
        // Speicher: die Spuren nacheinander laden (1-h-Meeting ≈ 230 MB je Spur) – erst Systemton, dann Mikrofon
        var sys = WavWriter.read(m.systemURL)
        let sysSpeech = speechSeconds(sys)

        var segments: [Segment] = []
        var embeddings: [String: [Float]] = [:]
        var names = m.speakerNames
        // Online-Meeting, sobald die anderen hörbar waren – oder eine Anruf-App erkannt wurde (Teams, Zoom, WhatsApp …).
        // 28.09.2026: die Gegenseite sprach im Test nur ~3 s → galt als Präsenz-Meeting, ihre Spur wurde ignoriert und alles
        // landete als „Sprecher 1“ statt „Ich“ + andere.
        let callMeeting = m.app.map { $0 != "Datei" && $0 != "Mikrofon" && !$0.isEmpty } ?? false
        let online = sysSpeech > 4 || (callMeeting && sysSpeech > 0.5)

        do {
            if online {
                await note(id, "Sprecher werden erkannt …")
                let (turns, emb) = try await Diarizer.shared.diarize(sys)
                let keyMap = speakerKeyMap(turns)
                for (raw, e) in emb { if let k = keyMap[raw] { embeddings[k] = e } }
                await note(id, "Transkribiere Teilnehmer …")
                let words = try await Transcriber.shared.transcribe(sys).words
                segments += assign(words: words, turns: turns, keyMap: keyMap)
            }
            sys = []
            // Leise Spur (Anruf-App mit Sprachverarbeitung) vor der Sprach-Messung angleichen – sonst zählt sie als stumm
            let mic = Transcriber.normalized(WavWriter.read(m.micURL))
            let micSpeech = speechSeconds(mic)
            log(String(format: "Auswertung %@: Mikro %.0fs Sprache, System %.0fs Sprache", id, micSpeech, sysSpeech))
            if micSpeech > 1 {
                await note(id, "Transkribiere dein Mikrofon …")
                if online {
                    let words = try await Transcriber.shared.transcribe(mic).words
                    let mine = group(words: words, speaker: "me")
                    segments += removeEcho(mine, others: segments)
                } else {
                    // Präsenz-Meeting: alles kommt übers Mikrofon → dort Sprecher trennen.
                    await note(id, "Sprecher im Raum werden erkannt …")
                    let (turns, emb) = try await Diarizer.shared.diarize(mic)
                    let keyMap = speakerKeyMap(turns)
                    for (raw, e) in emb { if let k = keyMap[raw] { embeddings[k] = e } }
                    let words = try await Transcriber.shared.transcribe(mic).words
                    segments += assign(words: words, turns: turns, keyMap: keyMap)
                }
            }
        } catch {
            log("Auswertung fehlgeschlagen: \(error)")
            m.status = .failed
            m.progressNote = "Fehler: \(error.localizedDescription)"
            let mm = m
            await MainActor.run { MeetingStore.shared.save(mm) }
            return
        }

        // Bekannte Stimmen automatisch benennen.
        for (k, e) in embeddings where names[k] == nil {
            if let (name, score) = VoiceStore.match(e) {
                names[k] = name
                log(String(format: "Stimme erkannt: %@ → %@ (%.2f)", k, name, score))
            }
        }

        segments.sort { $0.start < $1.start }
        segments = mergeAdjacent(segments)
        m.segments = segments
        m.speakerEmbeddings = embeddings
        m.speakerNames = names
        m.status = .done
        m.progressNote = nil
        log(String(format: "Auswertung fertig in %.1fs: %d Abschnitte", Date().timeIntervalSince(t0), segments.count))
        let mm = m
        await MainActor.run { MeetingStore.shared.save(mm) }
        // „Audio behalten“ aus → Tonspuren nach erfolgreicher Auswertung löschen
        if !Settings.shared.keepAudio {
            try? FileManager.default.removeItem(at: mm.micURL)
            try? FileManager.default.removeItem(at: mm.systemURL)
        }
        if Settings.shared.autoSummary && ClaudeCLI.isAvailable && !segments.isEmpty { await summarize(id: id, force: false) }
    }

    static func summarize(id: String, force: Bool) async {
        guard var m = await MainActor.run(body: { MeetingStore.shared.meeting(id) }), !m.segments.isEmpty else { return }
        if m.summary != nil && !force { return }
        await note(id, "Zusammenfassung wird geschrieben …")
        let system = """
        Du fasst ein Meeting-Transkript zusammen. Schreibe in der Sprache, die im Meeting überwiegend gesprochen wurde.
        Erste Zeile exakt: TITEL: <kurzer, konkreter Titel, max. 6 Wörter>
        Danach Markdown mit diesen Abschnitten (leere Abschnitte weglassen):
        **Kurzfassung** – 2–3 Sätze.
        **Kernpunkte** – Stichpunkte.
        **Entscheidungen** – Stichpunkte.
        **Aufgaben** – Stichpunkte im Format „Name: Aufgabe (bis wann, falls genannt)“.
        **Offene Fragen** – Stichpunkte.
        Keine Einleitung, keine Floskeln, nichts erfinden.
        """
        do {
            // Mit Bildern (Folien/geteilte Bildschirme), falls mitgeschnitten – sonst wie bisher nur das Transkript
            var visual: String?
            do { visual = try await MeetingVisualSummary.run(meeting: m, system: system) }
            catch { log("Zusammenfassung mit Bildern fehlgeschlagen, nur Text: \(error.localizedDescription)") }
            let out: String
            if let visual { out = visual } else { out = try await ClaudeCLI.run(system: system, input: m.transcriptText(), model: "sonnet", timeout: 240) }
            var lines = out.components(separatedBy: "\n")
            if let first = lines.first, first.uppercased().hasPrefix("TITEL:") {
                let t = first.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { m.title = t }
                lines.removeFirst()
            }
            m.summary = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            m.progressNote = nil
        } catch {
            m.progressNote = "Zusammenfassung fehlgeschlagen: \(error.localizedDescription)"
        }
        let mm = m
        await MainActor.run { MeetingStore.shared.save(mm) }
    }

    // MARK: Hilfen

    private static func speechSeconds(_ s: [Float]) -> Double {
        let f = 480
        guard s.count > f else { return 0 }
        var n = 0
        var i = 0
        while i + f <= s.count {
            var sum: Float = 0
            for j in i..<(i + f) { sum += s[j] * s[j] }
            if sqrt(sum / Float(f)) > 0.01 { n += 1 }
            i += f
        }
        return Double(n * f) / 16000
    }

    /// Diarizer-IDs in Reihenfolge des ersten Auftretens auf S1, S2, … abbilden.
    private static func speakerKeyMap(_ turns: [Diarizer.Turn]) -> [String: String] {
        var map: [String: String] = [:]
        for t in turns where map[t.speaker] == nil { map[t.speaker] = "S\(map.count + 1)" }
        return map
    }

    private static func assign(words: [(word: String, start: Double, end: Double)], turns: [Diarizer.Turn],
                               keyMap: [String: String]) -> [Segment] {
        guard !turns.isEmpty else { return group(words: words, speaker: "S1") }
        var out: [Segment] = []
        for w in words {
            let mid = (w.start + w.end) / 2
            var best = turns[0]; var bestD = Double.greatestFiniteMagnitude
            for t in turns {
                let d = mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0)
                if d < bestD { bestD = d; best = t; if d == 0 { break } }
            }
            let key = keyMap[best.speaker] ?? "S1"
            if var last = out.last, last.speaker == key, w.start - last.end < 1.5 {
                last.text += " " + w.word; last.end = w.end
                out[out.count - 1] = last
            } else {
                out.append(Segment(speaker: key, start: w.start, end: w.end, text: w.word))
            }
        }
        return out.map { var s = $0; s.text = TextCleaner.applyRules(s.text, settings: Settings.shared); return s }
            .filter { !$0.text.isEmpty }
    }

    private static func group(words: [(word: String, start: Double, end: Double)], speaker: String) -> [Segment] {
        var out: [Segment] = []
        for w in words {
            if var last = out.last, w.start - last.end < 1.2 {
                last.text += " " + w.word; last.end = w.end
                out[out.count - 1] = last
            } else {
                out.append(Segment(speaker: speaker, start: w.start, end: w.end, text: w.word))
            }
        }
        return out.map { var s = $0; s.text = TextCleaner.applyRules(s.text, settings: Settings.shared); return s }
            .filter { !$0.text.isEmpty }
    }

    /// Wenn ohne Kopfhörer: das Mikro hört die anderen mit. Solche Doppel entfernen.
    private static func removeEcho(_ mine: [Segment], others: [Segment]) -> [Segment] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        }
        return mine.filter { seg in
            let a = words(seg.text)
            guard !a.isEmpty else { return false }
            let overlapping = others.filter { $0.start < seg.end + 1 && $0.end > seg.start - 1 }
            let b = overlapping.reduce(into: Set<String>()) { $0.formUnion(words($1.text)) }
            let common = Double(a.intersection(b).count) / Double(a.count)
            return common < 0.5
        }
    }

    private static func mergeAdjacent(_ segs: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in segs {
            if var last = out.last, last.speaker == s.speaker, s.start - last.end < 2.0, last.text.count < 600 {
                last.text += " " + s.text; last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else { out.append(s) }
        }
        return out
    }
}
