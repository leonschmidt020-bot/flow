import FluidAudio
import Foundation
import NaturalLanguage

// MARK: - Auswertung einer Audiodatei (wie MeetingProcessor, aber in Stücken, abbrechbar, fortsetzbar)
//
//  1. Dekodieren → audio.pcm (16 kHz mono)                                   [AudioDecoder]
//  2. Sprechertrennung über die GANZE Datei (pyannote community-1 + VBx, gleiche Einstellung wie Meetings),
//     Ton per mmap von der Platte – ein 3-h-Mitschnitt liegt nie komplett im Speicher     → sprecher.json
//  3. Parakeet (Transcriber.shared) in ~5-min-Stücken, Stückgrenzen in Sprechpausen; Sprache DE/EN je Stück;
//     unsichere/fremdsprachig wirkende Äußerungen zusätzlich über Whisper (Hybrid, wie im Diktat)  → stuecke/NNN.json
//  4. Zusammenführen, bekannte Stimmen benennen (VoiceStore), speichern, Zusammenfassung (MeetingProcessor.summarize)
// Jeder Schritt schreibt seinen Stand in import.json → nach Abbruch oder App-Neustart geht es beim letzten Stück weiter.

final class AudioImportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    /// Live-Fortschritt 0…1 + kurzer Text (Hauptthread-Aufrufer bündelt das)
    var onProgress: (@Sendable (Double, String) -> Void)?
    /// Schätz-Hinweis für die Anzeige: (von, nächster Stand, erwartete Sekunden bis dahin)
    var onHint: (@Sendable (Double, Double, Double) -> Void)?
}

/// Eigene Sprechertrennung für Dateien: gleiche Konfiguration wie `Diarizer.shared`, aber mit Platten-Quelle
/// (mmap) statt eines riesigen Float-Arrays. Nach der Warteschlange wieder freigegeben (Speicher sparen).
actor AudioImportDiarizer {
    static let shared = AudioImportDiarizer()
    private var manager: OfflineDiarizerManager?

    func diarize(_ source: PCMSource, progress: (@Sendable (Double) -> Void)?) async throws -> (turns: [Diarizer.Turn], embeddings: [String: [Float]]) {
        if manager == nil {
            let m = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await m.prepareModels()
            manager = m
        }
        guard let manager else { return ([], [:]) }
        let r = try await manager.process(audioSource: source, audioLoadingSeconds: 0) { done, total in
            progress?(total > 0 ? Double(done) / Double(total) : 0)
        }
        let turns = r.segments.map { Diarizer.Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        var emb = r.speakerDatabase ?? [:]
        if emb.isEmpty {
            var acc: [String: ([Float], Int)] = [:]
            for s in r.segments where !s.embedding.isEmpty {
                var e = acc[s.speakerId] ?? ([Float](repeating: 0, count: s.embedding.count), 0)
                for i in 0..<min(e.0.count, s.embedding.count) { e.0[i] += s.embedding[i] }
                e.1 += 1
                acc[s.speakerId] = e
            }
            emb = acc.mapValues { v in v.0.map { $0 / Float(max(v.1, 1)) } }
        }
        return (turns, emb)
    }

    func release() {
        guard manager != nil else { return }
        manager = nil
        log("Audiodatei: Sprechertrennung freigegeben")
    }
}

enum AudioImportProcessor {
    /// Ziel-Länge eines Stücks (Sekunden, ~2,5 min: Sprache je Stück, Fortschritt, Fortsetzen). Grenze in die längste Sprechpause ±45 s.
    nonisolated(unsafe) static var chunkTarget: Double = 150
    /// Nur für Tests: nach so vielen fertigen Stücken hart abbrechen (simuliert Absturz/Beenden)
    nonisolated(unsafe) static var testStopAfterChunks: Int?
    /// Nur Messung: jede Äußerung (im Rahmen des Budgets) zusätzlich an Whisper – schlechtester Fall fürs Tempo
    static let forceWhisper = ProcessInfo.processInfo.environment["FLOW_AI_WHISPER_ALL"] == "1"
    /// Nur Messung: Speicher nach jedem Schritt ausgeben
    static let memLog = ProcessInfo.processInfo.environment["FLOW_AI_MEMLOG"] == "1"
    static func mem(_ what: String) { if memLog { print("  [Speicher] " + what.padding(toLength: 34, withPad: " ", startingAt: 0) + MemProbe.snap().description) } }

    struct StoredDiarization: Codable {
        struct T: Codable { var s: String; var a: Double; var b: Double }
        var turns: [T]
        var embeddings: [String: [Float]]
    }

    struct StoredChunk: Codable {
        var language: String
        var segments: [Segment]
        var whisperSeconds: Double
        var whisperCalls: Int
        var asrSeconds: Double
    }

    enum Outcome { case done, cancelled, failed(String), decodeFailed(String), gone }

    // MARK: Hauptablauf

    static func run(id: String, control: AudioImportControl) async -> Outcome {
        guard var job = AudioImportFiles.loadJob(id) else { return .gone }
        let t0 = Date()
        func stillThere() -> Bool { FileManager.default.fileExists(atPath: AudioImportFiles.folder(id).path) }
        func save() { if stillThere() { AudioImportFiles.saveJob(job) } }
        func report(_ f: Double, _ s: String) { control.onProgress?(f, s) }
        await setMeeting(id) { m in m.status = .processing; m.progressNote = "Wird vorbereitet …" }

        // 1) Dekodieren
        let pcmURL = AudioImportFiles.pcmURL(id)
        if !job.decoded || !FileManager.default.fileExists(atPath: pcmURL.path) {
            job.phase = .decoding; job.decoded = false; job.diarized = false; job.chunks = []; job.chunksDone = 0
            save()
            await setMeeting(id) { $0.progressNote = "Datei wird gelesen …" }
            let td = Date()
            do {
                let r = try AudioDecoder.decode(job.sourceURL, to: pcmURL,
                                                progress: { p in report(0.02 * p, "Datei wird gelesen … \(Int(p * 100)) %") },
                                                cancelled: { control.cancelled })
                job.duration = r.seconds; job.decoder = r.decoder; job.decoded = true
                job.timings["decode"] = Date().timeIntervalSince(td)
                save()
                let dur = r.seconds
                await setMeeting(id) { $0.duration = dur }
                log(String(format: "Audiodatei %@: %.0f s dekodiert (%@) in %.1f s", id, r.seconds, r.decoder, job.timings["decode"] ?? 0))
                mem("nach Dekodieren")
            } catch let e as AudioImportError where e.message == AudioImportError.cancelled.message {
                try? FileManager.default.removeItem(at: pcmURL)
                return finishCancelled(&job)
            } catch {
                try? FileManager.default.removeItem(at: pcmURL)
                job.phase = .failed; job.error = error.localizedDescription; save()
                return .decodeFailed(error.localizedDescription)
            }
        }
        guard stillThere() else { return .gone }
        let source: PCMSource
        do { source = try PCMSource(pcmURL) } catch {
            job.phase = .failed; job.error = "Zwischendatei unlesbar – bitte „Neu auswerten“."; job.decoded = false; save()
            return .failed(job.error!)
        }
        if job.duration <= 0 { job.duration = source.seconds }
        if control.cancelled { return finishCancelled(&job) }

        // Stille-Prüfung (billig, spart eine sinnlose Sprechertrennung)
        if !job.diarized {
            let speech = source.speechSeconds()
            if speech < 0.6 {
                let msg = "In „\(job.fileName)“ ist keine Sprache zu hören."
                job.phase = .failed; job.error = msg; save()
                return .decodeFailed(msg)
            }
        }

        // 2) Sprechertrennung (ganze Datei)
        var diar = loadDiarization(id)
        if !job.diarized || diar == nil {
            job.phase = .diarizing; save()
            await setMeeting(id) { $0.progressNote = "Sprecher werden erkannt …" }
            let tdz = Date()
            do {
                let r = try await AudioImportDiarizer.shared.diarize(source) { p in report(0.03 + 0.24 * p, "Sprecher werden erkannt … \(Int(p * 100)) %") }
                diar = StoredDiarization(turns: r.turns.map { .init(s: $0.speaker, a: $0.start, b: $0.end) }, embeddings: r.embeddings)
            } catch {
                // Ohne Sprechertrennung weiter (alles „Sprecher 1“) – lieber ein Transkript als gar keins
                log("Audiodatei \(id): Sprechertrennung fehlgeschlagen (\(error.localizedDescription)) – ein Sprecher")
                diar = StoredDiarization(turns: [], embeddings: [:])
            }
            if control.cancelled { return finishCancelled(&job) }
            job.timings["diarize"] = Date().timeIntervalSince(tdz)
            saveDiarization(id, diar!)
            job.diarized = true
            save()
            mem("nach Sprechertrennung")
            log(String(format: "Audiodatei %@: %d Sprecher, %d Abschnitte in %.1f s", id, Set(diar!.turns.map(\.s)).count, diar!.turns.count, job.timings["diarize"] ?? 0))
        }
        guard let diarization = diar else { return .failed("Sprechertrennung fehlt") }
        let turns = diarization.turns.map { Diarizer.Turn(speaker: $0.s, start: $0.a, end: $0.b) }
        var keyMap: [String: String] = [:]
        for t in turns where keyMap[t.speaker] == nil { keyMap[t.speaker] = "S\(keyMap.count + 1)" }

        // 3) Stücke planen + erkennen
        if job.chunks.isEmpty {
            job.chunks = planChunks(duration: job.duration, turns: turns, source: source)
            job.chunksDone = 0
        }
        job.phase = .transcribing; save()
        let nChunks = job.chunks.count
        await setMeeting(id) { $0.progressNote = "Transkribiere … 0 %" }
        try? FileManager.default.createDirectory(at: AudioImportFiles.chunkDir(id), withIntermediateDirectories: true)
        // Schon fertige Stücke (Fortsetzen) gleich anzeigen
        if job.chunksDone > 0 {
            let partial = loadChunks(id, upTo: job.chunksDone).flatMap(\.segments)
            await setMeeting(id) { $0.segments = partial }
        }
        let tr = Date()
        let useWhisper = AudioImportSettings.shared.whisperAssist && WhisperEngine.shared.ready
        // Tempo für die Anzeige-Schätzung: gemessen an den Stücken dieser Sitzung, sonst Erfahrungswert
        // (M4 Pro: Parakeet ~0,012 × Echtzeit, mit Whisper-Nachhören ~0,03)
        var sessionAudio = 0.0
        let priorRTF = useWhisper ? 0.03 : 0.013
        while job.chunksDone < nChunks {
            if control.cancelled { return finishCancelled(&job) }
            guard stillThere() else { return .gone }
            if let stop = testStopAfterChunks, job.chunksDone >= stop { log("Audiodatei \(id): Test-Stopp nach \(stop) Stücken"); return .cancelled }
            let i = job.chunksDone
            let c = job.chunks[i]
            let done = Double(i) / Double(nChunks)
            report(0.28 + 0.68 * done, "Transkribiere … \(Int(done * 100)) %")
            let rtf = sessionAudio >= 60 ? Date().timeIntervalSince(tr) / sessionAudio : priorRTF
            control.onHint?(0.28 + 0.68 * done, 0.28 + 0.68 * Double(i + 1) / Double(nChunks), max(0.3, (c.end - c.start) * rtf))
            do {
                let res = try await transcribeChunk(source: source, chunk: c, turns: turns, keyMap: keyMap, whisper: useWhisper,
                                                    budgetLeft: whisperBudget(job: job, upTo: c.end)) {
                    control.cancelled
                }
                let stored = StoredChunk(language: res.language, segments: res.segments, whisperSeconds: res.whisperSeconds,
                                         whisperCalls: res.whisperCalls, asrSeconds: res.asrSeconds)
                saveChunk(id, i, stored)
                job.chunks[i].language = res.language
                job.chunks[i].deSeconds = res.deSeconds
                job.chunks[i].enSeconds = res.enSeconds
                job.whisperSeconds += res.whisperSeconds
                job.whisperCalls += res.whisperCalls
                job.timings["asr", default: 0] += res.asrSeconds
                job.timings["whisper", default: 0] += res.whisperTime
                job.chunksDone = i + 1
                sessionAudio += c.end - c.start
                save()
                if i < 2 || i == nChunks - 1 { mem("nach Stück \(i + 1)/\(nChunks)") }
                let segs = res.segments
                let pct = Int(Double(i + 1) / Double(nChunks) * 100)
                await setMeeting(id) { m in m.segments += segs; m.progressNote = "Transkribiere … \(pct) %" }
            } catch let e as AudioImportError where e.message == AudioImportError.cancelled.message {
                return finishCancelled(&job)
            } catch {
                job.phase = .failed; job.error = "Erkennung fehlgeschlagen: \(error.localizedDescription)"; save()
                return .failed(job.error!)
            }
        }
        job.timings["transcribe"] = (job.timings["transcribe"] ?? 0) + Date().timeIntervalSince(tr)

        // 4) Zusammenführen
        job.phase = .finishing; save()
        report(0.97, "Wird zusammengeführt …")
        var segments = loadChunks(id, upTo: nChunks).flatMap(\.segments).sorted { $0.start < $1.start }
        segments = mergeAdjacent(segments)
        var embeddings: [String: [Float]] = [:]
        for (raw, e) in diarization.embeddings { if let k = keyMap[raw] { embeddings[k] = e } }
        let langs = job.chunks.compactMap(\.language)
        let finalSegments = segments
        let emb = embeddings
        await setMeeting(id) { m in
            var names = m.speakerNames
            for (k, e) in emb where names[k] == nil {
                if let (name, score) = VoiceStore.match(e) { names[k] = name; log(String(format: "Audiodatei: Stimme erkannt %@ → %@ (%.2f)", k, name, score)) }
            }
            m.segments = finalSegments
            m.speakerEmbeddings = emb
            m.speakerNames = names
            m.status = .done
            m.progressNote = nil
        }
        job.timings["total"] = Date().timeIntervalSince(t0) + (job.timings["previousRuns"] ?? 0)
        job.phase = .done
        job.error = nil
        save()
        AudioImportFiles.removeScratch(id)
        let de = langs.filter { $0 == "de" }.count, en = langs.filter { $0 == "en" }.count
        log(String(format: "Audiodatei %@ fertig: %.0f s Ton in %.1f s (Echtzeitfaktor %.3f), %d Abschnitte, %d Stücke (DE %d / EN %d), Whisper %d× %.0f s",
                   id, job.duration, job.timings["total"] ?? 0, (job.timings["total"] ?? 0) / max(job.duration, 1), finalSegments.count, nChunks, de, en,
                   job.whisperCalls, job.whisperSeconds))
        return .done
    }

    private static func finishCancelled(_ job: inout AudioImportJob) -> Outcome {
        job.phase = .cancelled
        if FileManager.default.fileExists(atPath: AudioImportFiles.folder(job.id).path) { AudioImportFiles.saveJob(job) }
        return .cancelled
    }

    /// Whisper höchstens für ~35 % der bisherigen Tonlänge (+60 s Grundbudget) – hält das Tempo weit unter Echtzeit.
    private static func whisperBudget(job: AudioImportJob, upTo end: Double) -> Double {
        max(0, 60 + 0.35 * end - job.whisperSeconds)
    }

    // MARK: Stücke planen

    static func planChunks(duration: Double, turns: [Diarizer.Turn], source: PCMSource?) -> [AudioImportChunk] {
        guard duration > chunkTarget * 1.4 else { return [AudioImportChunk(start: 0, end: duration)] }
        // Sprechpausen aus der Sprechertrennung (Lücken zwischen Abschnitten)
        var busy: [(Double, Double)] = []
        for t in turns {
            if let last = busy.last, t.start <= last.1 { busy[busy.count - 1].1 = max(last.1, t.end) } else { busy.append((t.start, t.end)) }
        }
        var gaps: [(Double, Double)] = []
        var prev = 0.0
        for b in busy { if b.0 > prev { gaps.append((prev, b.0)) }; prev = b.1 }
        gaps.append((prev, duration))
        var cuts: [Double] = []
        var pos = 0.0
        while duration - pos > chunkTarget * 1.4 {
            let lo = pos + chunkTarget - 45, hi = pos + chunkTarget + 45
            let cand = gaps.filter { $0.1 > lo && $0.0 < hi }.max { ($0.1 - $0.0) < ($1.1 - $1.0) }
            var cut: Double
            if let g = cand, g.1 - g.0 >= 0.25 {
                cut = (max(g.0, lo) + min(g.1, hi)) / 2
            } else if let source {
                cut = quietestPoint(source, from: lo, to: hi)
            } else {
                cut = pos + chunkTarget
            }
            cut = min(max(cut, pos + 60), duration - 30)
            cuts.append(cut); pos = cut
        }
        var out: [AudioImportChunk] = []
        var s = 0.0
        for c in cuts { out.append(AudioImportChunk(start: s, end: c)); s = c }
        out.append(AudioImportChunk(start: s, end: duration))
        return out
    }

    /// Leisester 100-ms-Punkt im Bereich (falls die Sprechertrennung keine Pause liefert)
    private static func quietestPoint(_ src: PCMSource, from a: Double, to b: Double) -> Double {
        let s = src.samples(from: a, to: b)
        let w = 1600
        var best = (a + b) / 2, bestE = Float.greatestFiniteMagnitude
        var i = 0
        while i + w <= s.count {
            var e: Float = 0
            for j in i..<(i + w) { e += s[j] * s[j] }
            if e < bestE { bestE = e; best = a + Double(i + w / 2) / AudioDecoder.sampleRate }
            i += w
        }
        return best
    }

    // MARK: Ein Stück erkennen

    struct ChunkResult {
        var language: String
        var segments: [Segment]
        var whisperSeconds: Double
        var whisperCalls: Int
        var asrSeconds: Double
        var whisperTime: Double
        var deSeconds: Double
        var enSeconds: Double
    }

    private struct Utterance {
        var speaker: String
        var start: Double
        var end: Double
        var words: [(word: String, conf: Float, start: Double, end: Double)]
        var text: String { words.map(\.word).joined(separator: " ") }
        var mean: Float { words.isEmpty ? 0 : words.map(\.conf).reduce(0, +) / Float(words.count) }
        var shaky: Float { words.isEmpty ? 1 : Float(words.filter { $0.conf < 0.5 }.count) / Float(words.count) }
    }

    static func transcribeChunk(source: PCMSource, chunk: AudioImportChunk, turns: [Diarizer.Turn], keyMap: [String: String],
                                whisper: Bool, budgetLeft: Double, cancelled: @escaping () -> Bool) async throws -> ChunkResult {
        let samples = source.samples(from: chunk.start, to: chunk.end)
        let ta = Date()
        let p = try await Transcriber.shared.transcribeScored(samples)
        let asrSeconds = Date().timeIntervalSince(ta)
        if cancelled() { throw AudioImportError.cancelled }
        // Wörter mit absoluten Zeiten
        var words: [(word: String, conf: Float, start: Double, end: Double)] = []
        for (i, w) in p.words.enumerated() {
            let t = i < p.times.count ? p.times[i] : (start: 0, end: 0)
            words.append((w.word, w.conf, chunk.start + t.start, chunk.start + t.end))
        }
        let mode = Settings.frozen.languageMode
        let textLang = mode != .both ? mode.rawValue : detectLanguage(p.text)
        let chunkTurns = turns.filter { $0.end > chunk.start - 2 && $0.start < chunk.end + 2 }
        // Lückenfüller: Parakeet verschluckt nach einem Sprachwechsel manchmal ganze Sätze (gemessen: EN-Satz → folgender
        // DE-Satz fehlte komplett). Sprecher-Abschnitte ohne Wörter werden einzeln nachgehört (Parakeet, sonst Whisper).
        var filled = 0
        for t in chunkTurns where t.end - t.start >= 0.8 && t.start >= chunk.start - 0.05 && t.end <= chunk.end + 0.05 {
            let covered = words.filter { $0.end > t.start && $0.start < t.end }.map { min($0.end, t.end) - max($0.start, t.start) }.reduce(0, +)
            guard covered < 0.15 * (t.end - t.start) else { continue }
            if cancelled() { throw AudioImportError.cancelled }
            let a = max(chunk.start, t.start - 0.15), b = min(chunk.end, t.end + 0.15)
            let clip = source.samples(from: a, to: b)
            var got: [(word: String, conf: Float, start: Double, end: Double)] = []
            if let q = try? await Transcriber.shared.transcribeScored(clip), !q.text.isEmpty {
                for (i, w) in q.words.enumerated() {
                    let tt = i < q.times.count ? q.times[i] : (start: 0, end: 0)
                    got.append((w.word, w.conf, a + tt.start, a + tt.end))
                }
            } else if whisper, let r = try? await WhisperEngine.shared.transcribe(Transcriber.normalizedGentle(clip), language: "auto", prompt: nil),
                      acceptWhisper(r.text, parakeet: r.text, prompt: "") {
                got = [(r.text, 1, t.start, t.end)]
            }
            if !got.isEmpty { words += got; filled += 1 }
        }
        if filled > 0 {
            words.sort { $0.start < $1.start }
            if memLog { print("  [Lücken] \(filled) Sprecher-Abschnitt(e) ohne Wörter nachgehört") }
        }
        // Wörter den Sprechern zuordnen → Äußerungen (gleicher Sprecher, Lücke < 1,5 s, höchstens 30 s)
        var utts: [Utterance] = []
        for w in words {
            let key = speaker(at: (w.start + w.end) / 2, turns: chunkTurns, keyMap: keyMap)
            if var last = utts.last, last.speaker == key, w.start - last.end < 1.5, w.end - last.start <= 30 {
                last.words.append(w); last.end = w.end
                utts[utts.count - 1] = last
            } else {
                utts.append(Utterance(speaker: key, start: w.start, end: w.end, words: [w]))
            }
        }
        // Sprache je Äußerung (ab 4 Wörtern; kürzere erben die Sprache des Stücktexts) → Stücksprache nach Sprechdauer
        // (Sprache, sicher?) – unsicher = Whisper entscheidet selbst zwischen DE/EN
        let uttLangScored: [(String, Bool)] = utts.map { u in
            if mode != .both { return (mode.rawValue, true) }
            guard u.words.count >= 4, !LanguageGuard.looksForeign(u.text) else { return (textLang, false) }
            let (l, p) = detectLanguageScored(u.text)
            return (l, p >= 0.85)
        }
        let uttLang = uttLangScored.map(\.0)
        var deSec = 0.0, enSec = 0.0
        for (i, u) in utts.enumerated() { if uttLang[i] == "en" { enSec += u.end - u.start } else { deSec += u.end - u.start } }
        let chunkLang = utts.isEmpty ? textLang : (enSec > deSec ? "en" : "de")
        // Hybrid: unsichere oder fremd wirkende Äußerungen zusätzlich mit Whisper (Sprache fest DE/EN)
        var budget = budgetLeft
        var wSec = 0.0, wCalls = 0
        let tw = Date()
        var texts = utts.map(\.text)
        if whisper {
            let dict = Settings.frozen.dictionary
            let prompt = WhisperEngine.vocabularyPrompt()
            // unsicherste zuerst, solange das Budget reicht
            let order = utts.indices.sorted { utts[$0].mean < utts[$1].mean }
            for i in order {
                let u = utts[i]
                let dur = u.end - u.start
                guard dur >= 0.8, budget >= dur else { continue }
                let foreign = LanguageGuard.looksForeign(u.text)
                let vocab = VocabTrigger.hit(in: VocabTrigger.applyAliases(u.text, dictionary: dict), dictionary: dict,
                                             policy: HybridRecognizer.policy) != nil
                // Nur wo Whisper nachweislich hilft (Messung 27.09.2026, TTS-Testset + verrauschte 10–16-kbit-Opus-Dateien):
                // fremdsprachig wirkender Parakeet-Text (48,9 → 34,0 % WER) und Wörterbuch-Namen. Bei bloß niedriger
                // Parakeet-Sicherheit war Whisper im Schnitt SCHLECHTER (34 → 36 % WER) → dort bleibt Parakeet.
                guard foreign || vocab || forceWhisper else { continue }
                if cancelled() { throw AudioImportError.cancelled }
                let (lang, sure) = uttLangScored[i]
                let clip = Transcriber.normalizedGentle(source.samples(from: max(chunk.start, u.start - 0.2), to: min(chunk.end, u.end + 0.25)))
                // Sichere Sprache → fest vorgeben (spart Whispers Spracherkennung). Unsicher → Whisper wählt, aber nur DE/EN.
                // Wörterbuch-Hinweis NUR, wenn ein Wörterbuch-Wort im Spiel ist: der (deutsche) Hinweis-Satz zieht Whisper
                // sonst bei englischen/undeutlichen Stellen ins Deutsche oder wird nachgeplappert („Ich bin Lena. Ich bin Lena.“)
                let hint: String? = vocab ? prompt : nil
                guard var r = try? await WhisperEngine.shared.transcribe(clip, language: sure ? lang : "auto", prompt: hint) else { continue }
                budget -= dur; wSec += dur; wCalls += 1
                if !sure, !r.language.isEmpty, r.language != "german", r.language != "english" {
                    let forced = LanguageGuard.guessDeEn(r.text.isEmpty ? u.text : r.text)
                    if let r2 = try? await WhisperEngine.shared.transcribe(clip, language: forced, prompt: hint) { r = r2; wCalls += 1 }
                }
                let wt = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                var take = acceptWhisper(wt, parakeet: u.text, prompt: prompt)
                // Sprache war sicher, Whisper antwortet trotzdem in der anderen → verwerfen
                if take, sure, wt.split(whereSeparator: \.isWhitespace).count >= 4, detectLanguage(wt) != lang { take = false }
                if take { texts[i] = wt }
                if memLog { print(String(format: "  [Whisper] %6.1f s %@%@ m=%.2f → %@\n     P: %@\n     W: %@", u.start, lang, sure ? "" : "?", u.mean, take ? "übernommen" : "verworfen", u.text, wt)) }
            }
        }
        let whisperTime = Date().timeIntervalSince(tw)
        var segs: [Segment] = []
        for (i, u) in utts.enumerated() {
            let t = TextCleaner.applyRules(texts[i], settings: Settings.shared)
            guard !t.isEmpty else { continue }
            segs.append(Segment(speaker: u.speaker, start: u.start, end: u.end, text: t))
        }
        return ChunkResult(language: chunkLang, segments: segs, whisperSeconds: wSec, whisperCalls: wCalls,
                           asrSeconds: asrSeconds, whisperTime: whisperTime, deSeconds: deSec, enSeconds: enSec)
    }

    /// Whisper-Text übernehmen? Nicht bei Halluzinationen, Hinweis-Nachplappern oder stark abweichender Länge.
    static func acceptWhisper(_ w: String, parakeet p: String, prompt: String) -> Bool {
        guard !w.isEmpty else { return false }
        let junk = ["untertitel", "vielen dank fürs zuschauen", "thanks for watching", "amara.org", "copyright", "untertitelung"]
        let lw = w.lowercased()
        if junk.contains(where: { lw.contains($0) }) { return false }
        let nw = w.split(whereSeparator: \.isWhitespace).count
        if nw >= 4, prompt.lowercased().contains(lw.trimmingCharacters(in: .punctuationCharacters)) { return false }
        // Wiederholungs-Schleife („Ich bin Lena. Ich bin Lena. Ich bin Lena.“)
        let sentences = w.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if sentences.count >= 3, Set(sentences).count * 2 <= sentences.count { return false }
        let np = max(1, p.split(whereSeparator: \.isWhitespace).count)
        let ratio = Double(nw) / Double(np)
        return ratio > 0.4 && ratio < 2.5
    }

    static func detectLanguageScored(_ text: String) -> (String, Double) {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english]
        r.processString(text)
        let h = r.languageHypotheses(withMaximum: 2)
        let de = h[.german] ?? 0, en = h[.english] ?? 0
        return en > de ? ("en", en) : ("de", de)
    }

    static func detectLanguage(_ text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter }).count
        guard words >= 3 else { return "de" }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english]
        r.processString(text)
        let h = r.languageHypotheses(withMaximum: 2)
        return (h[.english] ?? 0) > (h[.german] ?? 0) ? "en" : "de"
    }

    private static func speaker(at t: Double, turns: [Diarizer.Turn], keyMap: [String: String]) -> String {
        guard !turns.isEmpty else { return "S1" }
        var best = turns[0]; var bestD = Double.greatestFiniteMagnitude
        for tr in turns {
            let d = t < tr.start ? tr.start - t : (t > tr.end ? t - tr.end : 0)
            if d < bestD { bestD = d; best = tr; if d == 0 { break } }
        }
        return keyMap[best.speaker] ?? "S1"
    }

    static func mergeAdjacent(_ segs: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in segs {
            if var last = out.last, last.speaker == s.speaker, s.start - last.end < 2.0, last.text.count < 600 {
                last.text += " " + s.text; last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else { out.append(s) }
        }
        return out
    }

    // MARK: Zwischenstände

    static func saveDiarization(_ id: String, _ d: StoredDiarization) {
        if let data = try? JSONEncoder().encode(d) {
            try? data.write(to: AudioImportFiles.diarizationURL(id), options: .atomic)
            chmod(AudioImportFiles.diarizationURL(id).path, 0o600)
        }
    }

    static func loadDiarization(_ id: String) -> StoredDiarization? {
        guard let d = try? Data(contentsOf: AudioImportFiles.diarizationURL(id)) else { return nil }
        return try? JSONDecoder().decode(StoredDiarization.self, from: d)
    }

    static func saveChunk(_ id: String, _ i: Int, _ c: StoredChunk) {
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: AudioImportFiles.chunkURL(id, i), options: .atomic)
            chmod(AudioImportFiles.chunkURL(id, i).path, 0o600)
        }
    }

    static func loadChunks(_ id: String, upTo n: Int) -> [StoredChunk] {
        (0..<n).compactMap { i in
            guard let d = try? Data(contentsOf: AudioImportFiles.chunkURL(id, i)) else { return nil }
            return try? JSONDecoder().decode(StoredChunk.self, from: d)
        }
    }

    // MARK: Notiz aktualisieren (Hauptthread, Platte)

    static func setMeeting(_ id: String, _ change: @escaping (inout Meeting) -> Void) async {
        await MainActor.run {
            guard var m = MeetingStore.shared.meeting(id) ?? loadMeetingFromDisk(id) else { return }
            change(&m)
            guard FileManager.default.fileExists(atPath: AudioImportFiles.folder(id).path) else { return }
            MeetingStore.shared.save(m)
        }
    }

    static func loadMeetingFromDisk(_ id: String) -> Meeting? {
        let f = AudioImportFiles.folder(id).appendingPathComponent("meeting.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: f) else { return nil }
        return try? dec.decode(Meeting.self, from: d)
    }
}
