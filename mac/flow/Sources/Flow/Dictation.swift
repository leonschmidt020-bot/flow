import Accelerate
import AppKit
import AVFoundation

/// Ablauf eines Diktats: Taste → Mikrofon → Parakeet → Bereinigen → Einfügen.
final class DictationController {
    enum State: Equatable { case idle, recording(handsFree: Bool), transcribing }

    private(set) var state: State = .idle {
        // Maus-Ziel: Rahmen „Text kommt hierher“ nie stehen lassen (Abbruch, Nichts gehört, Sprachbefehl …)
        didSet { if case .idle = state { MouseTarget.shared.endTracking() } }
    }
    private let mic = MicCapture()
    private let tap = DictationTap()
    /// fn + ⌃: das Gesprochene ist ein Befehl für den markierten Text (Transforms)
    private var isCommand = false
    private var commandSel: CommandMode.Selection?
    /// Was der Mac gerade abspielt (Musik, YouTube) – um es aus dem Diktat herauszurechnen.
    private let sysTap = DictationTap()
    private var systemAudio: SystemAudioTap?
    private let sysQueue = DispatchQueue(label: "flow.dictation.sys")
    /// Mac-Ton wird schon WÄHREND der Aufnahme in ~10-s-Stücken erkannt (VoiceFlow/Speed/SystemTextStream) –
    /// vorher lief das komplett erst nach dem Loslassen (115 s Diktat mit Ton vom Mac = +0,6–1,5 s Wartezeit).
    private let sysStream = SystemTextStream()
    /// Zeitpunkt, an dem fn losgelassen wurde (für die Tempo-Zeile im Protokoll und die Tempo-Garantie)
    private var releasedAt = Date()
    private var tempoMark = 0
    /// Läuft gerade ein Anruf? Dann Mikro mit Sprachverarbeitung (sonst liefert es nur Stille)
    var callActive: () -> Bool = { false }

    // Erkennung schon während des Sprechens: fertige Stücke (bis zur letzten Pause) laufen im Hintergrund
    struct ChunkResult { let text: String; let notMe: Bool }
    private var chunkTasks: [Task<ChunkResult, Never>] = []
    private var chunkStart = 0
    /// Startpositionen der Stücke (für das Zusammenlegen mit einem kurzen Rest)
    private var chunkStarts: [Int] = []
    private var chunkTimer: Timer?
    /// „Nur meine Stimme“ rechnet schon während der Aufnahme (FastVoiceMask.prefeed) – eine Nummer pro Diktat
    private var voiceSession = 0
    private var voicePrefeed = false
    private var prefeedBusy = false
    private var prefeedFrom = 0
    private var warmStop: DispatchWorkItem?
    /// So lange bleibt das Mikro nach einem Diktat bereit (kein abgeschnittener Anfang beim nächsten).
    private let warmSeconds: TimeInterval = 20
    private let pill: PillController
    private var startedAt = Date()
    private var startSound: DispatchWorkItem?
    private var peak: Float = 0
    private var maxTimer: Timer?

    /// Welche Ruheanzeige die Pille nach dem Diktat hat (z. B. laufendes Meeting).
    var restingMode: () -> PillView.Mode = { .idle }

    init(pill: PillController) {
        self.pill = pill
        mic.onSamples = { [weak self] s in self?.tap.feed(s) }
        mic.onLevel = { [weak self] lv in
            guard let self, self.tap.isActive else { return }
            DispatchQueue.main.async {
                self.pill.view.level = lv
                self.peak = max(self.peak, lv)
            }
        }
        // Agent-Prompt: Pille zeigt „wird gebaut“, solange sie nicht schon wieder etwas anderes tut (neues Diktat)
        APFlow.shared.actions.pillBusy = { [weak self] on in
            guard let self else { return }
            if on { if self.state == .idle { self.pill.view.mode = .agentPrompt } }
            else if self.pill.view.mode == .agentPrompt { self.pill.view.mode = self.restingMode() }
        }
        APFlow.shared.actions.toast = { [weak self] m in self?.pill.view.showToast(m, seconds: 2.4) }
    }

    var isHandsFree: Bool { state == .recording(handsFree: true) }
    /// Diktat läuft gerade (Aufnahme oder Erkennung) – dann keine Karten/Updates
    var isBusy: Bool { if case .idle = state { return false }; return true }

    func handle(_ e: HotkeyMonitor.Event) {
        switch e {
        case .pressStart:
            if state == .idle { start(handsFree: false, viaHotkey: true) }
        case .holdEnd:
            if case .recording(false) = state { finish() }
        case .tapCancelled, .comboCancelled:
            if case .recording(false) = state { cancel(silent: true) }
        case .doubleTap:
            if case .recording = state {
                state = .recording(handsFree: true)
                pill.view.mode = .handsFree
                playStart()
            } else if state == .idle {
                start(handsFree: true, viaHotkey: true)
            }
        case .singleTapWhileHandsFree:
            if case .recording(true) = state { finish() }
        case .commandStart:
            if state == .idle { start(handsFree: false) }
            guard case .recording = state else { return }
            // Optional (Standard aus): braucht die Claude-CLI. Ohne sie bleibt fn + ⌃ ein normales Diktat.
            guard Settings.shared.commandMode, ClaudeCLI.isAvailable else {
                pill.view.showToast(ClaudeCLI.isAvailable ? "Command Mode ist aus (Einstellungen) – normales Diktat"
                                                          : "Command Mode braucht die Claude-CLI – normales Diktat", seconds: 2)
                return
            }
            if let sel = CommandMode.shared.captureSelection() {
                isCommand = true
                discardVoiceSession()
                commandSel = sel
                pill.view.mode = .command
            } else {
                pill.view.showToast("Nichts markiert – normales Diktat", seconds: 2)
            }
        case .commandEnd:
            if case .recording = state { finish() }
        case .escape:
            if case .recording = state { cancel(silent: false) }
            else if state == .transcribing { abortTranscription("Abgebrochen") }
            else { APCard.shared.escape() }   // Agent-Prompt-Karte schließen (beim Bauen nur mit der Maus auf der Karte)
        }
    }

    /// Nummer für „Text dorthin, wo die Maus ist“ (0 = aus / nicht über die Taste gestartet)
    private var mouseSession = 0

    /// `viaHotkey`: nur beim Start über die Diktat-Taste zählt die Maus (Klick auf die Pille/Menü zeigt ja auf uns selbst)
    func start(handsFree: Bool, viaHotkey: Bool = false) {
        guard state == .idle else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            pill.view.showToast("Mikrofon-Zugriff fehlt")
            return
        }
        pill.reposition(force: true)
        pill.pinnedToScreen = true
        peak = 0
        warmStop?.cancel()
        // Audit 27.09.2026: nach „Nichts gehört“, „Mikro lieferte nur Stille“ oder einem Abbruch blieb der Befehlsmodus
        // stehen → das NÄCHSTE normale Diktat wurde zur Claude-Anweisung für die alte Markierung. (.commandStart setzt
        // isCommand erst nach start() wieder.)
        isCommand = false; commandSel = nil
        let wantVP = callActive()
        if mic.voiceProcessing != wantVP { log("Diktat-Mikro: Sprachverarbeitung \(wantVP ? "an (Anruf läuft)" : "aus")") }
        mic.voiceProcessing = wantVP
        CorrectionLearner.shared.finish()   // neues Diktat → letzter Vergleich, dann altes Mitlesen beenden
        // Ziel unter der Maus JETZT merken (nicht beim Loslassen) – Maus bewegen beim Sprechen lenkt nicht um
        mouseSession = MouseTarget.shared.begin(enabled: viaHotkey && Settings.shared.mouseTarget)
        ScreenContext.shared.begin()      // Fenstertext für Namen/Begriffe lesen – im Hintergrund, Mikro wartet nicht
        tap.begin()   // übernimmt die letzten 0,4 s vor dem Tastendruck, falls das Mikro schon lief
        voiceSession += 1
        prefeedFrom = 0
        prefeedBusy = false
        voicePrefeed = Settings.shared.onlyMyVoice && VoiceID.isEnrolled
        chunkTasks = []
        chunkStarts = []
        chunkStart = 0
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkChunk() }
        sysTap.begin()
        sysStream.reset()
        if Settings.shared.filterMacAudio && systemAudio == nil {
            let st = SystemAudioTap()
            systemAudio = st
            sysQueue.async { [weak self] in
                do { try st.start { self?.sysTap.feed($0) } } catch { log("Mac-Ton-Filter nicht verfügbar: \(error)") }
            }
        }
        // Idempotent: läuft das Mikro schon passend (warm), passiert nichts; sonst Start/Umschalten auf der Mikro-Queue
        mic.ensureRunning(deviceUID: Settings.shared.micUID) { [weak self] err, dt, started in
            guard let self else { return }
            if let err {
                log("Mikrofon-Start fehlgeschlagen: \(err)")
                if case .recording = self.state { self.cancel(silent: true) }
                self.pill.view.showToast("Mikrofon startet nicht")
            } else if started {
                log(String(format: "Mikro bereit nach %.0f ms", dt * 1000))
            }
        }
        startedAt = Date()
        state = .recording(handsFree: handsFree)
        pill.view.mode = handsFree ? .handsFree : .listening
        if handsFree { playStart() } else {
            // Ton erst, wenn wirklich gehalten wird (kurzes Fn-Tippen bleibt stumm).
            let w = DispatchWorkItem { [weak self] in
                if case .recording = self?.state { self?.playStart() }
            }
            startSound = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: false) { [weak self] _ in
            if case .recording = self?.state { self?.finish() }
        }
    }

    func cancel(silent: Bool) {
        startSound?.cancel()
        maxTimer?.invalidate()
        _ = tap.end()
        _ = sysTap.end()
        chunkTimer?.invalidate(); chunkTimer = nil
        chunkTasks.forEach { $0.cancel() }; chunkTasks = []
        discardVoiceSession()
        sysStream.reset()
        TempoGuard.disarm()
        ScreenContext.shared.end()
        MouseTarget.shared.discard(); mouseSession = 0
        scheduleWarmStop()
        isCommand = false; commandSel = nil
        state = .idle
        pill.view.level = 0
        pill.view.mode = restingMode()
        pill.pinnedToScreen = false
        if !silent { pill.view.showToast("Abgebrochen") }
    }

    func finish() {
        startSound?.cancel()
        maxTimer?.invalidate()
        // Kurz nachlaufen lassen, damit das letzte Wort nicht abgeschnitten wird.
        state = .transcribing
        pill.view.mode = .transcribing
        releasedAt = Date()
        tempoMark = TempoGuard.arm(release: releasedAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.collect() }
    }

    private var transcribeJob: Task<Void, Never>?

    /// Erkennung abbrechen (Esc oder Zeitlimit) – Pille zurück, nichts einfügen
    private func abortTranscription(_ message: String) {
        transcribeJob?.cancel(); transcribeJob = nil
        chunkTasks.forEach { $0.cancel() }; chunkTasks = []
        discardVoiceSession()
        sysStream.reset()
        TempoGuard.disarm()
        state = .idle
        pill.view.mode = restingMode()
        pill.pinnedToScreen = false
        pill.view.showToast(message, seconds: 2)
        log("Erkennung abgebrochen: \(message)")
    }

    private func scheduleWarmStop() {
        warmStop?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Audit 27.09.2026: dauerte die Erkennung länger als 20 s (Befehlsmodus/Claude, langsamer Whisper), wurde hier
            // nur abgebrochen und nie neu geplant → Mikro (oranger Punkt) + Mac-Ton-Abgriff liefen bis zum nächsten Diktat.
            guard self.state == .idle else {
                if self.state == .transcribing { self.scheduleWarmStop() }
                return
            }
            self.mic.stopAsync()
            if let st = self.systemAudio { self.systemAudio = nil; self.sysQueue.async { st.stop() } }
        }
        warmStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + warmSeconds, execute: w)
    }

    private func collect() {
        let samples = tap.end()
        let system = sysTap.end()
        chunkTimer?.invalidate(); chunkTimer = nil
        scheduleWarmStop()
        // Mikro liefert nur Nullen? (hängt nach Geräte-Wechsel) → kalt neu starten
        if samples.count > 8000, Dictation.peak(samples) < 1e-5 {
            log("Mikro lieferte nur Stille → Neustart")
            sysStream.reset(); TempoGuard.disarm()
            mic.stopAsync()
            state = .idle; pill.view.mode = restingMode(); pill.pinnedToScreen = false
            pill.view.showToast("Mikrofon neu gestartet – bitte nochmal", seconds: 2.5)
            return
        }
        let dur = Double(samples.count) / 16000
        pill.view.level = 0
        let debugID = Dictation.saveDebug(samples)
        // Flüstern ist leise (Pegel oft unter 0,05) – geflüsterte Sprache nicht als „Nichts gehört“ verwerfen
        guard dur > 0.4, peak > 0.05 || WhisperDetector.hasWhisperSpeech(samples) else {
            sysStream.reset(); TempoGuard.disarm()
            state = .idle
            pill.view.mode = restingMode()
            pill.pinnedToScreen = false
            if dur > 0.4 { pill.view.showToast("Nichts gehört") }
            return
        }
        playStop()
        state = .transcribing
        pill.view.mode = .transcribing
        let settings = Settings.shared
        // Wurden schon Stücke vorab erkannt? Dann nur noch den Rest hinterher
        var streamed: [Task<ChunkResult, Never>] = []
        if !chunkTasks.isEmpty {
            let tailStart = min(chunkStart, samples.count)
            if samples.count - tailStart < 16000 * 4, let lastStart = chunkStarts.last {
                // Kurzer Rest: nicht allein raten lassen – mit dem letzten Stück zusammen neu erkennen
                chunkTasks.removeLast().cancel()
                chunkStarts.removeLast()
                _ = enqueueChunk(Array(samples[lastStart...]), start: lastStart)
            } else {
                _ = enqueueChunk(Array(samples[tailStart...]), start: tailStart)
            }
            streamed = chunkTasks
            chunkTasks = []
            chunkStarts = []
        }
        let macSound = settings.filterMacAudio && EchoFilter.hasSound(system)
        // Mac-Ton: vorab erkannte Stücke + nur noch der Rest
        let sysJob = sysStream.take(system)
        let released = releasedAt, mark = tempoMark
        // App im Vordergrund jetzt merken (für Stil & Statistik – bis zum Einfügen kann sie sich nicht ändern)
        // (mit „Text dorthin, wo die Maus ist“: die App unter der Maus, dort landet der Text)
        let frontBundle = MouseTarget.shared.targetBundle(mouseSession) ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        // Höchstzeit fürs Erkennen: danach aufgeben statt hängen zu bleiben
        let limit = 12 + 2 * Double(max(1, streamed.count))
        let vs = voiceSession
        voicePrefeed = false
        let ctxID = ScreenContext.shared.sessionID
        let job = Task {
            defer { Task { await FastVoiceMask.shared.discard(session: vs) } }
            defer { ScreenContext.shared.end(ctxID) }
            defer { TempoGuard.disarm(mark) }
            let t0 = Date()
            // Mac-Ton (für den Musik/YouTube-Filter) gleichzeitig mit der eigentlichen Erkennung auswerten
            async let sysTextTask: String? = macSound ? await sysJob() : nil
            // 1) Erkennen und Stimmabgleich GLEICHZEITIG (spart ~1–2 s).
            //    Nur wenn eine fremde Stimme gefunden wird, wird ohne sie noch einmal erkannt.
            let checkVoice = settings.onlyMyVoice && VoiceID.isEnrolled
            var text = ""
            var streamedNotMe = false
            if !streamed.isEmpty {
                var results: [ChunkResult] = []
                for t in streamed { results.append(await t.value) }
                let mine = results.filter { !$0.notMe }
                text = mine.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
                if mine.isEmpty { streamedNotMe = true; text = results.map(\.text).joined(separator: " ") }
                log("Diktat in \(results.count) Stücken erkannt (\(results.count - mine.count) fremde Stimme)")
            }
            async let maskTask: VoiceID.MaskResult = (checkVoice && streamed.isEmpty) ? FastVoiceMask.shared.mask(samples, session: vs, offset: 0) : (streamedNotMe ? .notMe(bestSim: 0) : .unchanged)
            async let firstTask: String = streamed.isEmpty ? ((try? self.recognize(samples, settings: settings)) ?? "") : text
            text = await firstTask
            switch await maskTask {
            case .unchanged: break
            case .masked(let m, _):
                if let t = try? await self.recognize(m, settings: settings) { text = t }
            case .notMe:
                // Sicherheitsnetz: nicht einfügen, aber in die Zwischenablage (falls es doch die eigene Stimme war)
                let copy = TextCleaner.applyRules(text, settings: settings)
                await MainActor.run {
                    // abgebrochen (Esc/Zeitlimit) oder schon ein neues Diktat → dessen Zustand nicht anfassen
                    guard !Task.isCancelled, self.voiceSession == vs, self.state == .transcribing else { return }
                    if !copy.isEmpty { Inserter.copy(copy) }
                    self.transcribeJob = nil      // sonst bricht dessen Zeitlimit später das NÄCHSTE Diktat ab
                    self.state = .idle; self.pill.view.mode = self.restingMode(); self.pill.pinnedToScreen = false
                    self.pill.view.showToast(copy.isEmpty ? "Klang nicht nach dir" : "Klang nicht nach dir – nur in Zwischenablage", seconds: 2.8)
                }
                log("Klang nicht nach dir" + (settings.logTexts ? ": „\(copy)“" : ""))
                return
            }
            let asrTime = Date().timeIntervalSince(t0)
            // 3) Mac-Ton abziehen: was auch aus dem Lautsprecher kam, fliegt raus
            let tSys = Date()
            let sysTextOpt = text.isEmpty ? nil : await sysTextTask
            let sysWait = Date().timeIntervalSince(tSys)
            if !text.isEmpty, let sysText = sysTextOpt, !sysText.isEmpty {
                let before = text
                text = EchoFilter.subtract(dictation: text, systemText: sysText)
                if text != before { log("Mac-Ton entfernt" + (settings.logTexts ? " („\(sysText)“): „\(before)“ → „\(text)“" : "")) }
            }
            // Befehlsmodus: Gesprochenes = Anweisung für den markierten Text → umschreiben statt einfügen
            if let sel = await MainActor.run(body: { self.isCommand ? self.commandSel : nil }) {
                let instruction = TextCleaner.applyRules(text, settings: settings)
                await MainActor.run { self.pill.view.mode = .commandWorking }
                let result: CommandMode.Result = instruction.isEmpty ? .failed("Nichts gehört") : await CommandMode.shared.run(instruction: instruction, on: sel)
                await MainActor.run {
                    guard !Task.isCancelled, self.voiceSession == vs, self.state == .transcribing else { return }
                    self.transcribeJob = nil
                    self.isCommand = false; self.commandSel = nil
                    self.state = .idle; self.pill.view.mode = self.restingMode(); self.pill.pinnedToScreen = false
                    switch result {
                    case .ok: self.pill.view.showToast("Umgeschrieben", seconds: 1.6)
                    case .failed(let why): self.pill.view.showToast(why, seconds: 2.6)
                    }
                }
                log("Befehl ausgeführt: \(result == .ok("") ? "" : "")\(instruction.split(separator: " ").count) Wörter Anweisung")
                return
            }
            // 4) Bereinigen
            let rawWords = text.split(whereSeparator: { $0.isWhitespace }).count
            var cleaned = TextCleaner.applyRules(text, settings: settings)
            // „Prompt: …“ / „Ich mache jetzt einen Prompt …“ → Agent-Prompt bauen statt einfügen (Original sofort gesichert)
            let useMouse = await MainActor.run { self.mouseSession > 0 }
            if await APFlow.shared.consume(cleaned, duration: dur, useMouse: useMouse, finish: {
                self.transcribeJob = nil; self.state = .idle; self.pill.view.mode = self.restingMode(); self.pill.pinnedToScreen = false
                MouseTarget.shared.discard(); self.mouseSession = 0
            }) { return }
            // Sprachbefehl am Anfang („Schick Nico: …“, „Erinner mich …“, „Termin …“, „Notiz: …“) → ausführen statt einfügen
            if await VoiceCommands.shared.consume(cleaned, duration: dur, toast: { m in self.pill.view.showToast(m, seconds: 2.4) }, finish: { self.transcribeJob = nil; self.state = .idle; self.pill.view.mode = self.restingMode(); self.pill.pinnedToScreen = false }) { return }
            let dictFixes = Settings.frozen.dictionary.filter { $0.vocabOnly != true && !$0.heard.isEmpty }
                .filter { e in TextCleaner.regex(for: e.heard)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }.count
            if !cleaned.isEmpty, let polished = await TextCleaner.polish(cleaned, settings: settings) {
                cleaned = TextCleaner.applyRules(polished, settings: settings)
            }
            // Snippets („meine E-Mail“ → Adresse), dann Stil je App-Art (formell/locker/sehr locker).
            // Wurde ein Snippet eingesetzt, bleibt es unverändert.
            if !cleaned.isEmpty {
                let expanded = SnippetStore.shared.expand(cleaned)
                if expanded != cleaned { cleaned = expanded }
                else { cleaned = StyleStore.shared.apply(cleaned, category: AppCategory.of(bundleID: frontBundle)) }
                ScratchpadStore.shared.appendDictation(cleaned)
            }
            let words = cleaned.split(whereSeparator: { $0.isWhitespace }).count
            if words > 0 {
                VFStats.shared.recordDictation(words: words, seconds: dur, bundleID: frontBundle)
                let corrected = max(0, rawWords - words)
                if dictFixes > 0 || corrected > 0 { VFStats.shared.recordFix(dictionary: dictFixes, corrected: corrected) }
            }
            log(String(format: "Diktat %.1fs → Erkennung %.2fs, gesamt %.2fs, %d Wörter", dur, asrTime, Date().timeIntervalSince(t0), words)
                + (settings.logTexts ? ": " + cleaned : ""))
            Dictation.saveDebugText(debugID, cleaned)
            if Task.isCancelled { return }
            let tReady = Date()
            let expired = TempoGuard.expiredCount
            await MainActor.run {
                guard self.state == .transcribing, self.voiceSession == vs else { return }   // inzwischen abgebrochen / neues Diktat
                self.transcribeJob = nil
                let tPaste = Date()
                self.deliver(cleaned)
                let done = Date()
                // Was der Nutzer spürt: fn los → Text steht (inkl. 0,12 s Nachlauf, Warten auf den Main-Thread, Einfügen)
                log(String(format: "Tempo: Loslassen → Text %.2f s (Nachlauf %.2f, Erkennung %.2f, Mac-Ton %.2f, Nachbearbeitung %.2f, Main %.2f, Einfügen %.2f)%@",
                           done.timeIntervalSince(released), t0.timeIntervalSince(released), asrTime, sysWait,
                           tReady.timeIntervalSince(tSys) - sysWait, tPaste.timeIntervalSince(tReady), done.timeIntervalSince(tPaste),
                           expired > 0 ? " – Tempo-Garantie: Parakeet-Ergebnis (Whisper zu langsam)" : ""))
                if !cleaned.isEmpty { DictationHistory.shared.add(text: cleaned, duration: dur) }
                // Langer Auftrag an einen Agenten? Leiser Vorschlag an der Pille (erst nach dem Einfügen, keine Verzögerung)
                if words >= 35 {
                    let text = cleaned
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { APFlow.shared.offerIfLong(text: text, duration: dur, bundleID: frontBundle) }
                }
            }
            if cleaned.isEmpty { log(String(format: "Leer erkannt – Spitzenpegel %.2f (letzte Aufnahme: ~/.config/flow/letzte-aufnahme.wav)", self.peak)) }
        }
        transcribeJob = job
        let mySession = voiceSession            // Zeitlimit gilt nur für DIESES Diktat, nie für ein später gestartetes
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, self.voiceSession == mySession, self.state == .transcribing,
                  let cur = self.transcribeJob, cur == job else { return }
            self.abortTranscription("Dauert zu lange – abgebrochen")
        }
    }

    /// Whisper (genau, mit Wörterbuch-Hinweis, nur DE/EN) – fällt auf Parakeet zurück, wenn der Server nicht läuft.
    private func recognize(_ audio: [Float], settings: Settings, context: String = "") async throws -> String {
        // Geflüstert → immer über HybridRecognizer (Whisper mit Hinweis + Flüster-Pegel), auch wenn „Parakeet“ eingestellt ist
        if WhisperEngine.shared.ready, settings.engine == .whisper || WhisperDetector.analyze(audio).isWhisper {
            let r = await HybridRecognizer.recognize(audio, context: context)
            log(String(format: "Erkennung %@ in %d ms (%.1f s Ton)", r.engine, r.ms, Double(audio.count) / 16000))
            return r.text
        }
        var text = try await Transcriber.shared.transcribe(audio).text
        let mode = settings.languageMode
        if mode != .both, !text.isEmpty, WhisperFallback.isAvailable, LanguageGuard.looksForeign(text) || LanguageGuard.guessDeEn(text) != mode.rawValue {
            // Feste Sprache gewählt, Parakeet hat etwas anderes gehört → Whisper mit fester Sprache
            if let w = WhisperFallback.transcribe(audio, hint: text, forced: mode.rawValue) { text = w }
        } else if LanguageGuard.looksForeign(text), WhisperFallback.isAvailable {
            let before = text
            if let w = WhisperFallback.transcribe(audio, hint: text) { text = w }
            // Audit 27.09.2026: stand ohne „Texte protokollieren“ im Log (und damit im Fehlerbericht an den Partner)
            log("Sprache war nicht DE/EN → Whisper" + (Settings.frozen.logTexts ? " („\(before)“ → „\(text)“)" : ""))
        }
        return text
    }

    // MARK: Erkennung während des Sprechens

    /// Alle 0,5 s: gibt es seit dem letzten Stück ≥5 s Sprache und danach eine Pause? → Stück abschicken.
    private func checkChunk() {
        guard case .recording = state else { return }
        prefeedVoice()
        prefeedSystem()
        let n = tap.count
        // Stücke ≥8 s: Whisper braucht Zusammenhang (3-s-Stücke machten aus „checkst du das“ „Tschüss, du los“)
        guard n - chunkStart >= 16000 * 9 else { return }
        let seg = tap.peek(from: chunkStart)
        var cut = Dictation.findPause(seg, minOffset: 16000 * 8)
        if cut == nil && seg.count > 16000 * 25 { cut = Dictation.quietestPoint(seg, from: 16000 * 18) }  // Dauerreden ohne Pause
        guard let c = cut, c > 16000 else { return }
        _ = enqueueChunk(Array(seg[..<c]), start: chunkStart)
        chunkStart += c
        log(String(format: "Stück %d vorab erkannt (%.1f s)", chunkTasks.count, Double(c) / 16000))
    }

    /// Stücke laufen nacheinander (ein Whisper-Server); jedes bekommt das vorige als Zusammenhang.
    private func enqueueChunk(_ samples: [Float], start: Int) -> Task<ChunkResult, Never> {
        chunkStarts.append(start)
        let prev = chunkTasks.last
        let vs = voiceSession
        let t = Task { () -> ChunkResult in
            let before = await prev?.value
            return await self.processChunk(samples, context: before?.text ?? "", start: start, session: vs)
        }
        chunkTasks.append(t)
        return t
    }

    /// Stimmabgleich schon während der Aufnahme: neue 1,5-s-Fenster rechnen (nie zwei Durchläufe gleichzeitig).
    /// Positionen ab `tap.begin()` – dieselben wie `chunkStart` und `tap.end()`.
    private func prefeedVoice() {
        guard voicePrefeed, !prefeedBusy, !isCommand else { return }
        let from = prefeedFrom
        guard tap.count - from >= FastVoiceMask.win else { return }
        prefeedBusy = true
        let seg = tap.peek(from: from)
        let id = voiceSession
        Task { [weak self] in
            let next = await FastVoiceMask.shared.prefeed(seg, base: from, session: id)
            await MainActor.run {
                guard let self, self.voiceSession == id else { return }
                self.prefeedFrom = next
                self.prefeedBusy = false
            }
        }
    }

    private func discardVoiceSession() {
        voicePrefeed = false
        let id = voiceSession
        Task { await FastVoiceMask.shared.discard(session: id) }
    }

    /// Mac-Ton schon während der Aufnahme erkennen (nur mit Mac-Ton-Filter)
    private func prefeedSystem() {
        guard Settings.shared.filterMacAudio else { return }
        sysStream.poll(count: sysTap.count, peek: { self.sysTap.peek(from: $0) })
    }

    private func processChunk(_ samples: [Float], context: String, start: Int = 0, session: Int? = nil) async -> ChunkResult {
        let settings = Settings.shared
        if Task.isCancelled { return ChunkResult(text: "", notMe: false) }
        guard EchoFilter.hasSound(samples) || WhisperDetector.hasWhisperSpeech(samples) else { return ChunkResult(text: "", notMe: false) }
        // Stimmabgleich und Erkennung gleichzeitig; nur bei fremder Stimme ein zweites Mal ohne sie
        let check = settings.onlyMyVoice && VoiceID.isEnrolled
        // Kurze Stücke: nur klar fremde Stimmen (unter 0,45) aussortieren – eigene Wörter nie verlieren
        async let maskTask: VoiceID.MaskResult = check ? FastVoiceMask.shared.mask(samples, clipThreshold: 0.45, session: session, offset: start) : .unchanged
        async let firstTask: String = (try? self.recognize(samples, settings: settings, context: context)) ?? ""
        let first = await firstTask
        switch await maskTask {
        case .unchanged: return ChunkResult(text: first, notMe: false)
        case .notMe:
            log("Stück verworfen (fremde Stimme)" + (Settings.shared.logTexts ? ": „\(first)“" : ""))
            return ChunkResult(text: first, notMe: true)
        case .masked(let m, _):
            let t = (try? await recognize(m, settings: settings, context: context)) ?? first
            return ChunkResult(text: t, notMe: false)
        }
    }

    private func deliver(_ text: String) {
        state = .idle
        pill.view.mode = restingMode()
        pill.pinnedToScreen = false
        let ms = mouseSession; mouseSession = 0
        guard !text.isEmpty else { MouseTarget.shared.discard(); pill.view.showToast("Nichts erkannt"); return }
        guard ms > 0 else { insertNow(text); return }
        // „Text dorthin, wo die Maus ist“: erst Fenster/Feld unter der Maus nach vorne (0 ms, wenn es schon aktiv ist)
        MouseTarget.shared.prepare(ms) { [weak self] prep in
            guard let self else { return }
            if let t = prep.toast { self.pill.view.showToast(t, seconds: 2.4) }
            let pasted = self.insertNow(text)
            let head = "Maus-Ziel: " + (prep.target.map { "\($0.appName) · „\(MTRules.shortTitle($0.title))“ · " } ?? "")
                + "Methode \(prep.method) (\(prep.note)) · +\(prep.extraMs) ms"
            // Enter nur nach echtem Einfügen und nur, wenn wirklich ins Maus-Ziel eingefügt wurde (0/a/b/c) – bei d landete
            // der Text im vorherigen Fenster, das soll nicht ungefragt abgeschickt werden
            guard pasted, Settings.shared.mouseTargetAutoSend, ["0", "a", "b", "c"].contains(prep.method) else { log(head); return }
            let hotkey = Settings.shared.hotkey.flag
            MouseTarget.shared.autoSend(inserted: text, prepared: prep,
                                        hotkeyHeld: { CGEventSource.flagsState(.combinedSessionState).contains(hotkey) }) { extra in
                log(head + " · " + extra)
            }
        }
    }

    /// Einfügen wie bisher. true = wirklich eingefügt (⌘V geschickt)
    @discardableResult
    private func insertNow(_ text: String) -> Bool {
        switch Inserter.insert(text) {
        case .pasted:
            if Settings.shared.learnFromEdits { CorrectionLearner.shared.watch(inserted: text) }
            return true
        case .copiedOnly(let reason):
            pill.view.showToast(reason, seconds: 2.6)
            return false
        }
    }

    private func playStart() {
        guard Settings.shared.sounds, let s = NSSound(named: "Tink") else { return }
        s.volume = 0.18; s.play()
    }

    private func playStop() {
        guard Settings.shared.sounds, let s = NSSound(named: "Pop") else { return }
        s.volume = 0.15; s.play()
    }
}

enum Dictation {
    /// Größter Betrag (ohne Kopie des ganzen Puffers)
    static func peak(_ s: [Float]) -> Float {
        var m: Float = 0
        s.withUnsafeBufferPointer { p in vDSP_maxmgv(p.baseAddress!, 1, &m, vDSP_Length(p.count)) }
        return m
    }

    private static func frameRMS(_ s: [Float]) -> [Float] {
        let f = 480
        return stride(from: 0, to: s.count - f, by: f).map { i in
            var sum: Float = 0; for j in i..<(i + f) { sum += s[j] * s[j] }; return sqrt(sum / Float(f))
        }
    }

    /// Letzte Sprechpause (≥0,36 s leise) nach minOffset, nicht ganz am Ende. Gibt die Schnittstelle (Sample) zurück.
    static func findPause(_ s: [Float], minOffset: Int) -> Int? {
        let r = frameRMS(s)
        guard r.count > 30 else { return nil }
        let sorted = r.sorted()
        let noise = sorted[Int(Double(sorted.count) * 0.15)]
        // Untergrenze 0,0015 (vorher 0,003 ≈ -50 dB): geflüsterte Silben liegen oft darunter und wurden als Pause geschnitten
        let thr = max(Float(0.0015), noise * 2.2)
        let startF = minOffset / 480, endF = r.count - 6
        var best: Int?
        var k = startF
        while k < endF {
            if r[k] < thr {
                let a = k
                while k < endF && r[k] < thr { k += 1 }
                if k - a >= 10 { best = (a + k) / 2 * 480 }
            } else { k += 1 }
        }
        return best
    }

    /// Leiseste Stelle ab from (für Dauerreden ohne Pause)
    static func quietestPoint(_ s: [Float], from: Int) -> Int? {
        let r = frameRMS(s)
        let a = from / 480
        guard r.count > a + 10 else { return nil }
        var mi = a
        for k in a..<(r.count - 6) where r[k] < r[mi] { mi = k }
        return mi * 480
    }

    /// Die letzten 5 Diktate (Ton + erkannter Text) zur Fehlersuche: ~/.config/flow/diktate/
    /// Werden mit der normalen Aufräum-Frist ohnehin nach wenigen Tagen gelöscht (nur 5 Stück).
    static let debugDir: URL = {
        let u = Paths.base.appendingPathComponent("diktate")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    @discardableResult
    static func saveDebug(_ samples: [Float]) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HHmmss"
        let id = df.string(from: Date())
        DispatchQueue.global(qos: .utility).async {
            let url = debugDir.appendingPathComponent("\(id).wav")
            if let w = try? WavWriter(url: url) { w.write(samples); w.close() }
            // letzte-aufnahme.wav bleibt als Abkürzung auf das neueste
            let latest = Paths.base.appendingPathComponent("letzte-aufnahme.wav")
            try? FileManager.default.removeItem(at: latest)
            try? FileManager.default.copyItem(at: url, to: latest)
            // nur die neuesten 5 behalten
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: debugDir.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            for f in files.dropLast(5) {
                try? FileManager.default.removeItem(at: debugDir.appendingPathComponent(f))
                try? FileManager.default.removeItem(at: debugDir.appendingPathComponent(f.replacingOccurrences(of: ".wav", with: ".txt")))
            }
        }
        return id
    }

    static func saveDebugText(_ id: String, _ text: String) {
        try? text.write(to: debugDir.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
    }
}

/// Nimmt Mikro-Samples entgegen: hält immer die letzten 0,4 s vor und sammelt, solange ein Diktat läuft.
final class DictationTap {
    private let lock = NSLock()
    private var ring: [Float] = []
    private var buffer: [Float] = []
    private var active = false
    private let prerollSamples = 6400

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    var count: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    func peek(from i: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return i < buffer.count ? Array(buffer[i...]) : []
    }

    func feed(_ s: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if active { buffer.append(contentsOf: s) }
        ring.append(contentsOf: s)
        if ring.count > prerollSamples { ring.removeFirst(ring.count - prerollSamples) }
    }

    func begin() {
        lock.lock(); defer { lock.unlock() }
        buffer = ring
        active = true
    }

    func end() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        active = false
        let b = buffer; buffer = []
        return b
    }
}
