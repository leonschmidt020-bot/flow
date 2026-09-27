import AppKit
import FluidAudio
import SwiftUI

/// Selbsttests fürs Training – ohne Mikrofon, ohne echte Nutzerdaten anzufassen:
///   Flow --training-test <ordner>     Stimm-Level mit TTS, Kenntnis-%, Wort-Training mit TTS, Seiten als PNG
///   Flow --training-render <ordner>   nur die Oberfläche als PNG (Beispieldaten)
/// Alles landet in <ordner>/config (eigenes stimm-training.json, wort-training.json, meine-stimme.json);
/// Whisper läuft als eigener Server (anderer Pfad als der der laufenden App), das Wörterbuch nur im Speicher.
enum TrainingCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        if ["--training-test", "--training-render", "--training-calibrate"].contains(args[1]) { TLog.quiet = true }
        if let c = VoiceLab.run(args) { return c }
        let dir = args.count > 2 ? args[2] : FileManager.default.temporaryDirectory.appendingPathComponent("vf-training-test").path
        switch args[1] {
        case "--training-test": return wait { try await fullTest(dir: URL(fileURLWithPath: dir)) }
        case "--training-render": return wait { try await renderOnly(dir: URL(fileURLWithPath: dir)) }
        case "--training-calibrate": return wait { try await calibrate(dir: URL(fileURLWithPath: dir), files: Array(args.dropFirst(3))) }
        default: return nil
        }
    }

    private static func wait(_ body: @escaping () async throws -> Void) -> Int32 {
        _ = NSApplication.shared
        var code: Int32 = 0
        var done = false
        Task { @MainActor in
            do { try await body() } catch { print("Fehler: \(error.localizedDescription)"); code = 1 }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }

    // MARK: Voller Test

    static let ownDE = "Rocko (Deutsch (Deutschland))"
    static let ownEN = "Rocko (Englisch (USA))"

    @MainActor
    private static func fullTest(dir: URL) async throws {
        let base = dir.appendingPathComponent("config")
        try? FileManager.default.removeItem(at: base)
        TrainingFiles.secureDir(base)
        let voices = TTS.installedVoices()
        guard voices.contains(ownDE) else { throw NSError(domain: "VF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stimme \(ownDE) fehlt"]) }
        print("== STIMM-TRAINING (unechte eigene Stimme = \(ownDE) / \(ownEN)) ==")
        let vt = VoiceTrainer(base: base, profileURL: base.appendingPathComponent("meine-stimme.json"), logURL: Paths.log)
        func show(_ k: VoiceKnowledge, _ label: String) {
            print(String(format: "  %@ → %d %%  [Level %d/40 · Trennschärfe %d/30 (eigen Ø %.3f, fremd max %.3f, %d Fremd-Fenster) · Flüstern %d/15 · Diktate %d/10 (%d) · andere %d/5]",
                         label, k.percent, k.levelPoints, k.separationPoints, k.ownMean ?? -1, k.impostorMax ?? -1, k.impostorCount,
                         k.whisperPoints, k.adaptivePoints, k.adaptiveSamples, k.negativePoints))
        }
        show(vt.computeKnowledge(), "vorher")
        // Level-Aufnahmen per Sprachausgabe nachstellen
        var rng = SystemRandomNumberGenerator()
        for lv in VoiceLevel.all {
            let voice = lv.language == "en" ? ownEN : ownDE
            var s = try TTS.synth(lv.text, voice: voice, rate: lv.id == 3 ? 235 : 185)
            switch lv.id {
            case 4: s = s.map { $0 * 0.12 + Float.random(in: -0.002...0.002, using: &rng) }        // leise + Raumrauschen
            case 5:                                                                                     // „Musik“: Akkord + Rauschen
                s = s.enumerated().map { i, x in
                    let t = Float(i) / 16000
                    let music = 0.05 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277 * t) + sin(2 * .pi * 330 * t)) / 3
                    return x + music + Float.random(in: -0.01...0.01, using: &rng)
                }
            default: break
            }
            let t0 = Date()
            let r: VoiceTrainer.LevelResult
            // Flüster-Level: 3 kurze Sätze, per LPC geflüstert
            let takes = lv.whisper ? try (lv.takes ?? []).enumerated().map { i, t in Whisperizer.make(try TTS.synth(t, voice: voice), seed: UInt64(40 + i)) } : [s]
            do { r = try await vt.completeLevel(lv.id, takes: takes) } catch { print("  Level \(lv.id) abgelehnt: \(error.localizedDescription)"); continue }
            show(r.after, String(format: "Level %d %@ (%.0f s Sprache, Konsistenz %.2f, %.1fs)", lv.id, lv.title, r.speechSeconds, r.consistency, Date().timeIntervalSince(t0)))
        }
        print("  Vergleichsstimmen: \(vt.store.impostorVoices.joined(separator: ", "))")
        // Fremde Stimme will ein Level übernehmen → muss abgelehnt werden
        do {
            _ = try await vt.completeLevel(2, samples: try TTS.synth(VoiceLevel.level(2)!.text, voice: "Samantha"))
            print("  FEHLER: fremde Stimme wurde als Level akzeptiert")
        } catch { print("  Fremde Stimme (Samantha) als Level 2 → abgelehnt: \(error.localizedDescription)") }
        // bestSimilarity: neue Sätze, eigen vs. fremd
        let probe = "Kannst du mir bitte die Unterlagen von gestern schicken? Ich schaue sie mir heute Abend an."
        for v in [ownDE, "Anna", "Eddy (Deutsch (Deutschland))", "Reed (Deutsch (Deutschland))", "Shelley (Deutsch (Deutschland))"] where voices.contains(v) {
            let smp = try TTS.synth(probe, voice: v)
            let ws = try await TrainingEmbedder.shared.windows(smp, win: 24_000, hop: 16_000)
            let sims = ws.map { vt.bestSimilarity(to: $0) }
            print(String(format: "  bestSimilarity 1,5-s-Fenster %@: Ø %.2f (min %.2f, max %.2f)", v, sims.reduce(0, +) / Float(max(1, sims.count)), sims.min() ?? 0, sims.max() ?? 0))
        }
        let prof = try? JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("meine-stimme.json"))) as? [String: Any]
        print("  meine-stimme.json (Test-Kopie): \((prof?["embedding"] as? [Any])?.count ?? 0) Werte, Sekunden \(prof?["seconds"] ?? "?")")
        let (pct, parts) = vt.knowledge()
        print("  knowledge() = \(pct) %, \(parts) · Schwellen-Vorschlag \(vt.detail.suggestedThreshold.map { String(format: "%.2f", $0) } ?? "–")")

        print("\n== WORT-TRAINING ==")
        let server = TestWhisperServer()
        guard server.start() else { throw NSError(domain: "VF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Test-Whisper startet nicht"]) }
        defer { server.stop() }
        let backend = IsolatedWordBackend(server: server)
        let wt = WordTrainer(base: base, backend: backend)
        let words: [(String, String)] = [("Lidl", ownDE), ("Pierre", ownDE), ("Lumora", ownDE), ("Hallbauer", ownDE)]
        for (w, voice) in words {
            backend.dict.removeAll { $0.write.lowercased() == w.lowercased() }   // „vorher“ = Wort unbekannt
            var takes: [[Float]] = []
            for rate in [150, 175, 195, 215, 235, 260] { takes.append(try TTS.synth(w, voice: voice, rate: rate)) }
            let t0 = Date()
            let r = try await wt.train(word: w, takes: takes)
            print(String(format: "„%@“ (%@, %.1fs): ohne Hilfe %d/%d · vorher %d/%d → nachher %d/%d", w, r.language, Date().timeIntervalSince(t0),
                         r.accuracyPlain, r.total, r.accuracyBefore, r.total, r.accuracyAfter, r.total))
            for (i, t) in r.takes.enumerated() {
                print("   #\(i + 1) whisper „\(t.plain)“ · parakeet „\(t.parakeet)“ · vorher „\(t.before)“ · nachher „\(t.after)“")
            }
            print("   Varianten: \(r.variants) · gelernt: \(r.learned.map { "\($0) → \(w)" }) · nur Hinweis: \(r.hintOnly)")
        }
        print("  Test-Wörterbuch danach: \(backend.dict.filter { e in words.contains { $0.0 == e.write } }.map { "\($0.heard)→\($0.write)\($0.vocabOnly == true ? " (Hinweis)" : "")" })")
        print("  Takes gespeichert: \((try? FileManager.default.contentsOfDirectory(atPath: wt.clipsDir.path).count) ?? 0) Dateien in \(wt.clipsDir.path)")
        wt.addManual("Brenninkmeyer")
        print("  Vorschläge: " + wt.candidates().prefix(12).map { "\($0.word) [\($0.reasons.joined(separator: ", "))]" }.joined(separator: " · "))

        try await render(dir: dir, voice: vt, words: wt)
    }

    /// Kalibrierung mit echten Aufnahmen (nur lesen): die ersten Dateien werden Level 1…n, die letzte ist ein
    /// zurückgehaltenes Diktat. Druckt Ähnlichkeiten gegen die TTS-Vergleichsstimmen.
    @MainActor
    private static func calibrate(dir: URL, files: [String]) async throws {
        let base = dir.appendingPathComponent("calib-config")
        try? FileManager.default.removeItem(at: base)
        TrainingFiles.secureDir(base)
        let vt = VoiceTrainer(base: base, profileURL: base.appendingPathComponent("meine-stimme.json"), logURL: base.appendingPathComponent("kein.log"))
        guard files.count >= 2 else { print("mind. 2 WAVs"); return }
        let held = files.last!
        for (i, f) in files.dropLast().enumerated() {
            let s = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: f))
            let r = try await vt.completeLevel(i + 1, samples: s)
            print(String(format: "Level %d ← %@: %.0f s Sprache, Konsistenz %.2f → %d %% (eigen Ø %.3f, fremd max %.3f)",
                         i + 1, (f as NSString).lastPathComponent, r.speechSeconds, r.consistency, r.after.percent, r.after.ownMean ?? -1, r.after.impostorMax ?? -1))
        }
        let hs = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: held))
        let ws = try await TrainingEmbedder.shared.windows(hs, win: 24_000, hop: 16_000, limit: 40)
        let sims = ws.map { vt.bestSimilarity(to: $0) }
        print(String(format: "Zurückgehaltenes Diktat, 1,5-s-Fenster: Ø %.2f (min %.2f, max %.2f)", sims.reduce(0, +) / Float(max(1, sims.count)), sims.min() ?? 0, sims.max() ?? 0))
        let imp = vt.store.impostors.map { vt.bestSimilarity(to: $0) }
        print(String(format: "TTS-Fremdstimmen (2,5-s-Fenster): Ø %.2f, max %.2f", imp.reduce(0, +) / Float(max(1, imp.count)), imp.max() ?? 0))
        let model = vt.store.levels.values.map(\.centroid)
        for v in ["Anna", "Samantha", "Daniel", "Eddy (Deutsch (Deutschland))", "Rocko (Deutsch (Deutschland))", "Reed (Deutsch (Deutschland))", "Shelley (Deutsch (Deutschland))", "Grandpa (Deutsch (Deutschland))"] {
            guard let s = try? TTS.synth(VoiceLevel.level(1)!.text, voice: v) else { continue }
            let c = try await VoiceID.shared.embedding(of: s)
            print(String(format: "  Level-Mittel %@ vs. Eigen-Modell: %.3f", v, model.map { Vec.cos(c, $0) }.max() ?? 0))
        }
        for f in files.dropLast() {
            let c = try await VoiceID.shared.embedding(of: try AudioConverter().resampleAudioFile(URL(fileURLWithPath: f)))
            print(String(format: "  Level-Mittel eigen %@ vs. übrige: %.3f", (f as NSString).lastPathComponent,
                         model.filter { Vec.cos($0, c) < 0.999 }.map { Vec.cos(c, $0) }.max() ?? 0))
        }
        let hc = try await VoiceID.shared.embedding(of: hs)
        print(String(format: "  Level-Mittel zurückgehaltenes eigenen Diktat vs. Modell: %.3f", model.map { Vec.cos(hc, $0) }.max() ?? 0))
        // Fremde Stimme als neues Level → Schutz muss greifen
        do { _ = try await vt.completeLevel(5, samples: try TTS.synth(VoiceLevel.level(1)!.text, voice: "Anna")); print("FEHLER: Anna als Level akzeptiert") }
        catch { print("Anna als Level 5 → \(error.localizedDescription)") }
        print("knowledge() = \(vt.knowledge())")
    }

    // MARK: Oberfläche

    @MainActor
    private static func renderOnly(dir: URL) async throws {
        let base = dir.appendingPathComponent("render-config")
        try? FileManager.default.removeItem(at: base)
        TrainingFiles.secureDir(base)
        let vt = VoiceTrainer(base: base, profileURL: base.appendingPathComponent("meine-stimme.json"), logURL: base.appendingPathComponent("kein.log"))
        let backend = IsolatedWordBackend(server: nil)
        // Optional: echte Test-Ergebnisse zeigen (Ordner mit wort-training.json aus --names-lab eval)
        if let src = ProcessInfo.processInfo.environment["RENDER_WORDS"] {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: src).appendingPathComponent("wort-training.json"), to: base.appendingPathComponent("wort-training.json"))
            backend.history = ["Ich habe Pierre geschrieben.", "Meeting mit Pierre morgen.", "Pierre ruft an.", "Bei Lidl war es voll."]
        }
        let wt = WordTrainer(base: base, backend: backend)
        try await render(dir: dir, voice: vt, words: wt)
    }

    @MainActor
    private static func render(dir: URL, voice: VoiceTrainer, words: WordTrainer) async throws {
        VF.registerFonts()
        let out = dir.appendingPathComponent("png")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func snap<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat? = nil) {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
            host.appearance = NSAppearance(named: .aqua)
            let h = height ?? max(200, host.fittingSize.height)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: h)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
        snap("1_seite", VFTrainingPage(voice: voice, words: words).frame(width: 1180, height: 1500), width: 1180, height: 1500)
        // Level-Blatt in allen Zuständen
        let lv = VoiceLevel.level(min(5, voice.levelsDone + 1)) ?? VoiceLevel.all[0]
        let s1 = LevelSession(level: lv, trainer: voice)
        snap("2_level_bereit", LevelRecordingSheet(session: s1, trainer: voice) { _ in }, width: 620)
        let s2 = LevelSession(level: VoiceLevel.level(4)!, trainer: voice)
        s2.phase = .recording; s2.progress = 0.62
        s2.levels = (0..<48).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.55))) }
        snap("3_level_aufnahme", LevelRecordingSheet(session: s2, trainer: voice) { _ in }, width: 620)
        let s3 = LevelSession(level: VoiceLevel.level(2)!, trainer: voice)
        s3.result = VoiceTrainer.LevelResult(level: 2, speechSeconds: 16, consistency: 0.83, before: max(0, voice.detail.percent - 14), after: voice.detail)
        s3.phase = .done
        snap("4_level_fertig", LevelRecordingSheet(session: s3, trainer: voice) { _ in }, width: 620)
        let s4 = LevelSession(level: VoiceLevel.level(1)!, trainer: voice)
        s4.phase = .micDenied
        snap("4b_level_mikro_verboten", LevelRecordingSheet(session: s4, trainer: voice) { _ in }, width: 620)
        // Wort-Blatt
        let word = words.store.words.keys.sorted().first ?? "Pierre"
        let w1 = WordSession(word: word, trainer: words)
        w1.phase = .intro
        snap("5_wort_start", WordTrainingSheet(session: w1) {}, width: 580)
        let w1b = WordSession(word: word, trainer: words)
        w1b.mode = .word
        snap("5b_wort_start_nur_wort", WordTrainingSheet(session: w1b) {}, width: 580)
        let w2 = WordSession(word: word, trainer: words)
        w2.phase = .listening; w2.takeCount = 2
        w2.levels = (0..<32).map { i in Float(i > 18 && i < 27 ? 0.7 + 0.2 * sin(Double(i)) : 0.08) }
        snap("6_wort_aufnahme_satz", WordTrainingSheet(session: w2) {}, width: 580)
        let w3 = WordSession(word: word, trainer: words)
        w3.phase = .processing("Testen mit dem Gelernten … 4/6")
        snap("7_wort_auswertung", WordTrainingSheet(session: w3) {}, width: 580)
        let w4 = WordSession(word: word, trainer: words)
        if w4.record == nil {
            let sents = TrainingSentences.make(word, kind: .person, language: "both")
            let heard = ["Shark Wes", "Pierre", "Chuck Res", "Jar Quest", "Jack Res", "Talk quiz"]
            let takes = sents.enumerated().map { i, s in
                WordTrainer.Take(file: nil, plain: "", parakeet: s.replacingOccurrences(of: word, with: heard[i]),
                                 before: s.replacingOccurrences(of: word, with: heard[i]), after: i == 4 ? s.replacingOccurrences(of: word, with: "Jack") : s,
                                 okPlain: false, okBefore: i == 1, okAfter: i != 4, sentence: s, heardAs: heard[i])
            }
            w4.record = WordTrainer.Record(word: word, language: "de", date: Date(), takes: takes, variants: ["Shark Wes", "Chuck Res", "Jar Quest", "Jackress"],
                                           learned: ["Jackress"], hintOnly: [], accuracyPlain: 0,
                                           accuracyBefore: 1, accuracyAfter: 5, total: 6, mode: .sentences, kind: .person, templates: 8, acousticReady: false)
        }
        w4.phase = .result
        snap("8_wort_ergebnis", WordTrainingSheet(session: w4) {}, width: 580)
        let t1 = WordTestSession(word: word, trainer: words)
        t1.phase = .result(WordTrainer.TestResult(text: "Ich hab gestern mit \(word) über das Budget gesprochen.", ok: true, engine: "whisper+namen", date: Date()))
        snap("9_testen_richtig", WordTestPanel(session: t1) {}.padding(28).frame(width: 560).background(VF.panel), width: 560)
        let t2 = WordTestSession(word: word, trainer: words)
        t2.phase = .result(WordTrainer.TestResult(text: "Ich hab gestern mit Shark Wes gesprochen.", ok: false, engine: "parakeet", date: Date()))
        snap("9b_testen_falsch", WordTestPanel(session: t2) {}.padding(28).frame(width: 560).background(VF.panel), width: 560)
        print("\nPNG → \(out.path)")
    }
}

// MARK: - Abgeschottetes Backend für die Selbsttests

final class IsolatedWordBackend: WordTrainingBackend {
    var dict: [DictEntry]
    let server: TestWhisperServer?
    let names: NameStore
    var history: [String] = []
    var fixedLanguage: String? { nil }

    init(server: TestWhisperServer?, namesURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("vftest-namen-\(UUID().uuidString).json"),
         dictionary: [DictEntry]? = nil) {
        self.server = server
        names = NameStore(url: namesURL)
        // Eigenes Wörterbuch nur LESEN (Kopie im Speicher)
        struct S: Decodable { var dictionary: [DictEntry]? }
        dict = dictionary ?? (try? JSONDecoder().decode(S.self, from: Data(contentsOf: Paths.settings)))?.dictionary ?? Settings.defaultDictionary
    }

    func ensureWhisper() async -> Bool { server?.ready ?? false }

    func whisper(_ samples: [Float], language: String, prompt: String?) async throws -> (text: String, language: String) {
        guard let server else { throw TrainingError.whisperMissing }
        return try await server.transcribe(Transcriber.normalizedGentle(samples), language: language, prompt: prompt)
    }

    func scored(_ samples: [Float]) async throws -> ScoredText { try await EngineParakeet.shared.transcribe(samples) }

    /// Gleicher Satzbau wie WhisperEngine.vocabularyPrompt()
    static func vocabularyPrompt(_ dict: [DictEntry]) -> String {
        var words: [String] = []
        for e in dict.reversed() {
            let w = e.write.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty, !words.contains(w) { words.append(w) }
        }
        var list = Array(words.prefix(24))
        var sentence = ""
        while true {
            let joined = list.count > 1 ? list.dropLast().joined(separator: ", ") + " und " + list.last! : (list.first ?? "")
            sentence = "Ich bin \(Identity.myNameFrozen)." + (joined.isEmpty ? "" : " Heute geht es um \(joined).")
            if sentence.count <= 380 || list.isEmpty { break }
            list.removeLast()
        }
        return sentence
    }

    /// Umgebung für HybridRecognizer: Test-Whisper mit denselben Schutzregeln wie WhisperEngine.dictate
    func env(names: [NameProfile], dictionary: [DictEntry]) -> HybridRecognizer.Env {
        let server = self.server
        let vocab = IsolatedWordBackend.vocabularyPrompt(dictionary)
        return HybridRecognizer.Env(
            parakeet: { try await EngineParakeet.shared.transcribe($0) },
            whisper: { s, ctx, lang in
                guard let server else { throw TrainingError.whisperMissing }
                return try await server.dictate(s, prompt: vocab + (ctx.isEmpty ? "" : " " + String(ctx.suffix(160))), language: lang)
            },
            whisperReady: { server?.ready ?? false },
            dictionary: dictionary, names: names, learnAliases: false)
    }

    func recognize(_ samples: [Float], names: [NameProfile], dictionary: [DictEntry]) async -> HybridRecognizer.Outcome {
        await HybridRecognizer.recognize(samples, context: "", env: env(names: names, dictionary: dictionary))
    }

    func dictionary() -> [DictEntry] { dict }

    func learn(heard: String, write: String) async -> Bool {
        let vocab = !heard.contains(" ") && TrainingText.isRealWord(heard)
        if let i = dict.firstIndex(where: { $0.heard.lowercased() == heard.lowercased() }) {
            dict[i].write = write; dict[i].learned = true; dict[i].vocabOnly = vocab
        } else {
            dict.append(DictEntry(heard: heard, write: write, learned: true, vocabOnly: vocab))
        }
        return vocab
    }

    func ensureVocabulary(_ word: String) async {
        if !dict.contains(where: { $0.write.lowercased() == word.lowercased() }) {
            dict.append(DictEntry(heard: word, write: word, learned: nil, vocabOnly: true))
        }
    }

    func correctionLines() -> [(heard: String, write: String)] { WordTrainer.parseCorrectionLines(logURL: Paths.log) }

    func historyTexts() -> [String] { history }
}

/// Eigener whisper-server nur für Tests (eigener Port + Pfad; die laufende App räumt nur „/flow-…“-Server ab).
final class TestWhisperServer {
    private var process: Process?
    private var port = 0
    private let path = "/vftest-" + UUID().uuidString.lowercased()
    private(set) var ready = false
    private var base: String { "http://127.0.0.1:\(port)\(path)" }

    func start() -> Bool {
        guard let bin = WhisperEngine.serverBinary, let model = WhisperFallback.model, let p0 = WhisperEngine.freePort() else { return false }
        port = p0
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vftest-leer")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.currentDirectoryURL = empty
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", "\(port)", "--request-path", path,
                       "--public", empty.path, "-l", "auto", "-t", "6", "-bo", "1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        process = p
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 40 {
            if ping() { ready = true; print(String(format: "  Test-Whisper bereit nach %.1fs", Date().timeIntervalSince(t0))); return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        stop()
        return false
    }

    func stop() {
        if let p = process { p.terminate(); p.waitUntilExit() }
        process = nil; ready = false
    }

    /// Wie WhisperEngine.dictate: Sprache DE/EN, Halluzinationen und Hinweis-Nachplappern verwerfen
    func dictate(_ samples: [Float], prompt: String, language: String?) async throws -> String {
        let s = Transcriber.normalizedGentle(samples)
        var r = try await transcribe(s, language: language ?? "auto", prompt: prompt)
        if language == nil, !r.language.isEmpty, r.language != "german", r.language != "english", r.language != "de", r.language != "en" {
            r = try await transcribe(s, language: LanguageGuard.guessDeEn(r.text), prompt: prompt)
        }
        let junk = ["untertitel", "vielen dank fürs zuschauen", "thanks for watching", "amara.org", "copyright", "untertitelung"]
        if junk.contains(where: { r.text.lowercased().contains($0) }) { return "" }
        // Wie der vorgeschlagene Kern-Fix: nur ab 4 Wörtern als „Hinweis nachgeplappert“ werten (ein einzelner Name
        // wie „Lumora.“ steht natürlich auch im Hinweis und ist trotzdem richtig)
        let nWords = r.text.split(whereSeparator: { $0.isWhitespace }).count
        if nWords >= 4, r.text.count > 8, prompt.lowercased().contains(r.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) { return "" }
        return r.text
    }

    private func ping() -> Bool {
        var req = URLRequest(url: URL(string: base + "/inference")!)
        req.httpMethod = "OPTIONS"
        req.timeoutInterval = 0.5
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in ok = resp != nil; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 0.8)
        return ok
    }

    func transcribe(_ samples: [Float], language: String, prompt: String?) async throws -> (text: String, language: String) {
        let boundary = "vftest-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) { body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
        field("language", language)
        field("response_format", "json")
        field("temperature", "0")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(WhisperEngine.wavData(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: base + "/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.upload(for: req, from: body)
        let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let text = ((j["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (text, (j["language"] as? String) ?? "")
    }
}
