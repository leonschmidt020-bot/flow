import Foundation

/// Schwellen für den HybridRecognizer aus einem Bench-Ergebnis kalibrieren:
///   Flow --engine-calibrate ergebnis.json manifest.json [whisper-konfig] [--extra Brenninkmeyer,Dufresne]
/// Rechnet für jede Schwellen-Kombination nach, welcher Motor pro Clip genommen würde, und gibt WER/Namen/Latenz aus.
enum EngineCalibrate {
    static func run(_ args: [String]) throws {
        _ = Settings.shared
        guard args.count > 3 else { print("Aufruf: --engine-calibrate ergebnis.json manifest.json [whisper-konfig] [--extra a,b]"); return }
        let recs = try JSONDecoder().decode([EngineBench.Rec].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let clips = try JSONDecoder().decode([EngineBench.Clip].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let wcfg = args.count > 4 && !args[4].hasPrefix("--") ? args[4] : "q5-t6:lang"
        let extra = args.firstIndex(of: "--extra").flatMap { $0 + 1 < args.count ? args[$0 + 1].split(separator: ",").map(String.init) : nil } ?? []
        let learn = args.contains("--learn")
        let fixed = args.firstIndex(of: "--policy").flatMap { $0 + 1 < args.count ? args[$0 + 1].split(separator: ",").compactMap { Double($0) } : nil }
        var P: [String: EngineBench.Rec] = [:], W: [String: EngineBench.Rec] = [:]
        for r in recs { if r.config == "parakeet" { P[r.clip] = r } else if r.config == wcfg { W[r.clip] = r } }
        var cs = clips.filter { P[$0.id] != nil && W[$0.id] != nil }
        // Lern-Demo: aus Stimme A (…_0) Verhörer lernen, auf Stimme B (…_1) messen
        var learned: [DictEntry] = []
        if learn {
            let dict = Settings.frozen.dictionary
            var seen: [String: (DictEntry, Int)] = [:]
            for c in cs where c.id.hasSuffix("_0") {
                for p in AliasLearner.proposals(parakeet: P[c.id]!.hyp, whisper: VocabTrigger.applyAliases(W[c.id]!.hyp, dictionary: dict), dictionary: dict) {
                    let k = p.heard.lowercased() + "→" + p.write
                    seen[k] = (DictEntry(heard: p.heard, write: p.write, learned: true), (seen[k]?.1 ?? 0) + 1)
                }
            }
            learned = seen.values.map(\.0)
            print("Gelernt aus Stimme A: " + learned.map { "„\($0.heard)“→\($0.write)" }.joined(separator: ", "))
            cs = cs.filter { $0.id.hasSuffix("_1") }
        }
        if !learn && args.contains("--bonly") { cs = cs.filter { $0.id.hasSuffix("_1") } }   // Vergleich ohne Lernen
        let dictAll = Settings.frozen.dictionary + learned
        func ruled(_ s: String) -> String { TextCleaner.applyRules(VocabTrigger.applyAliases(s, dictionary: learned), settings: Settings.shared) }
        // Fehler je Clip und Motor vorab
        var errP: [String: Int] = [:], errW: [String: Int] = [:], nameP: [String: Int] = [:], nameW: [String: Int] = [:]
        var refN = 0, nameN = 0
        for c in cs {
            let ref = BenchText.words(c.truth, lang: c.lang); refN += ref.count; nameN += c.names.count
            let hp = ruled(P[c.id]!.hyp), hw = ruled(W[c.id]!.hyp)
            errP[c.id] = VocabTrigger.levenshtein(ref, BenchText.words(hp, lang: c.lang))
            errW[c.id] = VocabTrigger.levenshtein(ref, BenchText.words(hw, lang: c.lang))
            nameP[c.id] = BenchText.nameHits(hp, names: c.names, lang: c.lang).0
            nameW[c.id] = BenchText.nameHits(hw, names: c.names, lang: c.lang).0
        }
        struct Row { let label: String; let wer: Double; let names: Double; let p50: Int; let p95: Int; let share: Double }
        func eval(_ label: String, _ usesW: (EngineBench.Clip) -> Bool) -> Row {
            var e = 0, n = 0, lat: [Int] = [], w = 0
            for c in cs {
                let u = usesW(c)
                e += u ? errW[c.id]! : errP[c.id]!; n += u ? nameW[c.id]! : nameP[c.id]!
                lat.append(P[c.id]!.ms + (u ? W[c.id]!.ms : 0)); if u { w += 1 }
            }
            lat.sort()
            return Row(label: label, wer: Double(e) / Double(refN), names: Double(n) / Double(max(nameN, 1)),
                       p50: EngineBench.pct(lat, 0.5), p95: EngineBench.pct(lat, 0.95), share: Double(w) / Double(cs.count))
        }
        func show(_ r: Row) {
            print(String(format: "%@ WER %5.1f%%  Namen %5.1f%%  p50 %5d  p95 %5d  Whisper %3.0f%%", r.label.padding(toLength: 52, withPad: " ", startingAt: 0) as NSString,
                         r.wer * 100, r.names * 100, r.p50, r.p95, r.share * 100))
        }
        print("Whisper-Konfig \(wcfg), \(cs.count) Clips, Zusatz-Namen: \(extra)")
        let base = eval("nur Parakeet + Regeln", { _ in false }); show(base)
        let whisper = eval("nur Whisper", { _ in true }); show(whisper)
        show(eval("Orakel (je Clip der bessere)", { errW[$0.id]! < errP[$0.id]! }))

        if let f = fixed, f.count >= 3 {
            var pol = HybridRecognizer.Policy()
            pol.minMeanConfidence = Float(f[0]); pol.minWordConfidence = Float(f[1]); pol.fuzzyRatio = f[2]; pol.phonetic = f.count < 4 || f[3] > 0
            pol.extraVocabulary = extra
            show(eval("Policy \(f)") { c in
                let p = P[c.id]!
                return !HybridRecognizer.decide(text: p.hyp, mean: p.meanConf ?? 0, minWord: p.minWordConf ?? 0, seconds: c.dur, policy: pol, dictionary: dictAll).accept
            })
            let noNames = cs.filter { $0.names.isEmpty }
            let nn = noNames.filter { c in let p = P[c.id]!; return !HybridRecognizer.decide(text: p.hyp, mean: p.meanConf ?? 0, minWord: p.minWordConf ?? 0, seconds: c.dur, policy: pol, dictionary: dictAll).accept }.count
            print("Clips ohne Namen: \(noNames.count), davon an Whisper: \(nn)")
            for r in recs where r.config == "parakeet" && r.clip.hasPrefix("real:") {
                let d = HybridRecognizer.decide(text: r.hyp, mean: r.meanConf ?? 0, minWord: r.minWordConf ?? 0, seconds: 10, policy: pol, dictionary: dictAll)
                print("  \(r.clip) → \(d.accept ? "Parakeet" : "Whisper") (\(d.reason))")
            }
            for c in cs {
                let p = P[c.id]!
                let d = HybridRecognizer.decide(text: p.hyp, mean: p.meanConf ?? 0, minWord: p.minWordConf ?? 0, seconds: c.dur, policy: pol, dictionary: dictAll)
                let bad = d.accept ? errP[c.id]! > errW[c.id]! : errP[c.id]! < errW[c.id]!
                if bad { print("  \(c.id) \(d.accept ? "P" : "W") errP=\(errP[c.id]!) errW=\(errW[c.id]!) \(d.reason) | \(p.hyp.prefix(80))") }
            }
            return
        }
        var rows: [(Row, HybridRecognizer.Policy)] = []
        for mm: Float in [0, 0.8, 0.85, 0.9, 0.93, 0.95, 0.97] {
            for mw: Float in [0, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7] {
                for fz in [0.0, 0.25, 0.34] {
                    for ph in [false, true] {
                        var pol = HybridRecognizer.Policy()
                        pol.minMeanConfidence = mm; pol.minWordConfidence = mw; pol.fuzzyRatio = fz; pol.phonetic = ph; pol.extraVocabulary = extra
                        let label = String(format: "mittel≥%.2f wort≥%.2f fuzzy %.2f %@", mm, mw, fz, ph ? "+klang" : "")
                        let r = eval(label) { c in
                            let p = P[c.id]!
                            return !HybridRecognizer.decide(text: p.hyp, mean: p.meanConf ?? 0, minWord: p.minWordConf ?? 0, seconds: c.dur, policy: pol, dictionary: dictAll).accept
                        }
                        rows.append((r, pol))
                    }
                }
            }
        }
        print("\nGenauigkeit ≈ Whisper (WER ≤ Whisper + 0,5 pp, Namen ≥ Whisper − 2 pp), schnellste zuerst:")
        let ok = rows.filter { $0.0.wer <= whisper.wer + 0.005 && $0.0.names >= whisper.names - 0.02 }.sorted { ($0.0.p50, $0.0.wer) < ($1.0.p50, $1.0.wer) }
        for r in ok.prefix(15) { show(r.0) }
        print("\nLockerer (WER ≤ Whisper, Namen ≥ Whisper − 8 pp), schnellste zuerst:")
        for r in rows.filter({ $0.0.wer <= whisper.wer && $0.0.names >= whisper.names - 0.08 }).sorted(by: { ($0.0.p50, $0.0.wer) < ($1.0.p50, $1.0.wer) }).prefix(8) { show(r.0) }
        print("\nBeste WER überhaupt:")
        for r in rows.sorted(by: { ($0.0.wer, $0.0.p50) < ($1.0.wer, $1.0.p50) }).prefix(8) { show(r.0) }
    }
}
