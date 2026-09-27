import FluidAudio
import Foundation

/// Messbank Kontext-Diktat: `Flow --quality-context-bench manifest.json [--out ergebnis.json]`
/// manifest = [{id, file, lang, truth, names:[…], screen, app, set}]  (set: name | decoy | normal)
/// Jeder Clip läuft zweimal durch HybridRecognizer (Parakeet → ggf. Whisper, eigener Test-Server):
/// ohne Bildschirm-Kontext und mit (gefälschtem) Fenstertext. Wörterbuch + Namen-Profile sind LEER, damit nur der Kontext wirkt.
enum ContextBench {
    struct Clip: Codable { let id: String; let file: String; let lang: String; let truth: String; let names: [String]; let screen: String; let app: String; let set: String }
    struct Rec: Codable { let id: String; let set: String; let cond: String; let text: String; let engine: String; let ms: Int
        let namesHit: Int; let namesTotal: Int; let falseInserts: [String]; let wer: Double; let extractMs: Int; var trigger: String = "" }

    static func run(_ args: [String]) async throws {
        _ = Settings.shared
        TLog.quiet = true
        guard args.count > 2 else { print("Aufruf: --quality-context-bench manifest.json [--out x.json]"); return }
        let url = URL(fileURLWithPath: args[2])
        let out = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? url.deletingLastPathComponent().appendingPathComponent("kontext-ergebnis.json").path
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: url))
        let conv = AudioConverter()
        var audio: [String: [Float]] = [:]
        for c in clips { audio[c.id] = try conv.resampleAudioFile(URL(fileURLWithPath: c.file)) }
        print("\(clips.count) Clips geladen")

        let server = TestWhisperServer()
        guard server.start() else { print("Test-Whisper startet nicht"); return }
        defer { server.stop() }
        try await EngineParakeet.shared.load()
        ContextBoost.dictionaryWords = { [] }
        HybridRecognizer.learnAliases = false
        _ = SpellBatch.unknown(["warmup"])

        func env() -> HybridRecognizer.Env {
            HybridRecognizer.Env(
                parakeet: { try await EngineParakeet.shared.transcribe($0) },
                whisper: { s, ctx, lang in
                    let p = ContextBoost.prompt(dictionaryWords: [], name: "Lena") + (ctx.isEmpty ? "" : " " + String(ctx.suffix(160)))
                    return try await server.dictate(s, prompt: p, language: lang)
                },
                whisperReady: { true }, dictionary: [], names: ContextBoost.withTempProfiles([]), learnAliases: false)
        }
        // Aufwärmen
        ScreenContext.shared.end()
        for c in clips.prefix(2) { _ = await HybridRecognizer.recognize(audio[c.id]!, context: "", env: env()) }

        var recs: [Rec] = []
        for c in clips {
            for cond in ["ohne", "mit"] {
                var exMs = 0
                if cond == "mit", !c.screen.isEmpty {
                    ScreenContext.shared.inject(ContextText(focused: "", cursor: nil, title: "", others: [(c.screen, 0)], appKind: .of(bundleID: c.app)), bundleID: c.app)
                    exMs = ScreenContext.shared.snapshot?.extractMs ?? 0
                } else {
                    ScreenContext.shared.end()
                }
                let t0 = Date()
                let o = await HybridRecognizer.recognize(audio[c.id]!, context: "", env: env())
                // Feinschliff „Aus“ = nur Schreibweisen vom Bildschirm (zählt zur Kontext-Kette)
                let polished = ContextBoost.fixTerms(TextCleaner.tidy(o.text))
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let hit = c.names.filter { NameBooster.containsExact(polished, $0) }.count
                // Falsch eingesetzt: Bildschirm-Begriff im Ergebnis, der im gesprochenen Satz nicht vorkommt
                let screenTerms = cond == "mit" ? (ScreenContext.shared.snapshot?.terms.map(\.text) ?? []) : []
                // (mehrteilige Begriffe wie „Dr. Hallbauer“ zählen nicht, wenn ihr Hauptwort gesprochen wurde)
                let fi = screenTerms.filter { t in
                    let main = t.split(separator: " ").map(String.init).max(by: { $0.count < $1.count }) ?? t
                    return NameBooster.containsExact(polished, t) && !NameBooster.contains(c.truth, target: main)
                }
                let trig = cond == "mit" ? (VocabTrigger.hit(in: o.parakeetText, dictionary: [], policy: ContextBoost.policy(HybridRecognizer.Policy())) ?? "") : ""
                recs.append(Rec(id: c.id, set: c.set, cond: cond, text: polished, engine: o.engine, ms: ms, namesHit: hit, namesTotal: c.names.count,
                                falseInserts: fi, wer: wer(c.truth, polished), extractMs: exMs, trigger: trig))
                ScreenContext.shared.end()
            }
            let a = recs[recs.count - 2], b = recs[recs.count - 1]
            print(String(format: "%-8@ %@ ohne %4d ms %@ | mit %4d ms %@  %@", c.id as NSString, c.set as NSString, a.ms, "\(a.namesHit)/\(a.namesTotal)" as NSString,
                         b.ms, "\(b.namesHit)/\(b.namesTotal)" as NSString, (b.falseInserts.isEmpty ? "" : "FALSCH: " + b.falseInserts.joined(separator: ",")) as NSString))
            if a.text != b.text { print("         ohne: \(a.text)\n         mit:  \(b.text)") }
            if !b.trigger.isEmpty, c.set != "name" { print("         Auslöser: \(b.trigger)") }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try enc.encode(recs).write(to: URL(fileURLWithPath: out))

        func p(_ v: [Int], _ q: Double) -> Int { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
        print("\nSatz     Bed.   Namen richtig   WER     Whisper-Anteil  p50     p95     falsch eingesetzt")
        for set in ["name", "decoy", "normal", "alle"] {
            for cond in ["ohne", "mit"] {
                let r = recs.filter { ($0.set == set || set == "alle") && $0.cond == cond }
                guard !r.isEmpty else { continue }
                let nh = r.reduce(0) { $0 + $1.namesHit }, nt = r.reduce(0) { $0 + $1.namesTotal }
                let w = r.map(\.wer).reduce(0, +) / Double(r.count)
                let ws = Double(r.filter { !$0.engine.hasPrefix("parakeet") || $0.engine.contains("namen") }.count) / Double(r.count)
                print(String(format: "%-8@ %@   %@   %5.1f %%   %5.0f %%       %4d ms %5d ms  %d", set as NSString, cond as NSString,
                             (nt == 0 ? "   –    " : String(format: "%2d/%2d (%3.0f %%)", nh, nt, Double(nh) / Double(nt) * 100)) as NSString,
                             w * 100, ws * 100, p(r.map(\.ms), 0.5), p(r.map(\.ms), 0.95), r.reduce(0) { $0 + $1.falseInserts.count }))
            }
        }
        let ex = recs.filter { $0.cond == "mit" }.map(\.extractMs)
        print("Auswerten des Fenstertexts: p50 \(p(ex, 0.5)) ms, max \(ex.max() ?? 0) ms")
        print("gespeichert: \(out)")
    }

    static func wer(_ truth: String, _ hyp: String) -> Double {
        let a = QualityCLI.words(truth), b = QualityCLI.words(hyp)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        return Double(VocabTrigger.levenshtein(a, b)) / Double(a.count)
    }
}

extension NameBooster {
    /// Genau so geschrieben (Groß/klein zählt), ganzes Wort
    static func containsExact(_ text: String, _ target: String) -> Bool {
        let pat = "(?<![\\p{L}\\d_])" + NSRegularExpression.escapedPattern(for: target) + "(?![\\p{L}\\d_])"
        return text.range(of: pat, options: [.regularExpression]) != nil
    }
}
