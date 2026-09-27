import AppKit
import Foundation

/// Messwerkzeuge (nie App-Modus, kein Einfügen, keine Zwischenablage):
///   --quality-polish-eval [regeln|apple|claude|aus …] [--only id,id] [--show]   Regressions-Satz Feinschliff
///   --quality-lists-eval [--show] [--only id,id]                                  Regressions-Satz intelligente Listen (je Ziel-App)
///   --quality-polish "text" [--app bundle] [--screen "text"] [--mode aus|schnell|gruendlich]
///   --quality-extract "bildschirmtext" [--app bundle]                             Begriffe + Zeit
///   --quality-extract-bench                                                       Auswerte-Zeit bei 1k–40k Zeichen
///   --quality-read [bundleID …]                                                   echtes Fenster lesen: NUR Zahlen/Zeiten, keine Texte
///   --quality-prompt-check                                                        Whisper-Hinweis alt == neu (ohne Kontext)
///   --quality-context-bench <manifest.json> [--out x.json]                        TTS-Namen mit/ohne Bildschirm
enum QualityCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1, args[1].hasPrefix("--quality-") else { return nil }
        _ = Settings.shared
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        switch args[1] {
        case "--quality-polish-eval": return wait { await polishEval(args) }
        case "--quality-lists-eval":
            var code: Int32 = 0
            _ = wait { code = await ListEval.run(args) }
            return code
        case "--quality-polish":
            let text = args.count > 2 ? args[2] : ""
            return wait {
                let snap = snapshotFor(screen: opt("--screen") ?? "", app: opt("--app") ?? "com.apple.Notes")
                let mode: AIPolish = ["aus": .off, "gruendlich": .thorough].first { $0.key == opt("--mode") }?.value ?? .fast
                let o = await Polisher.run(text, snapshot: snap, mode: mode, app: opt("--app") ?? "com.apple.Notes")
                print("[\(o.engine), \(o.ms) ms]\n\(o.text)")
                if let snap { print("Begriffe: " + snap.terms.map { "\($0.text)(\($0.kind.rawValue) \(String(format: "%.1f", $0.score)))" }.joined(separator: ", ")) }
            }
        case "--quality-extract":
            let text = args.count > 2 ? args[2].replacingOccurrences(of: "\\n", with: "\n") : ""
            let app = opt("--app") ?? "com.apple.Notes"
            _ = SpellBatch.unknown(["warmup"])
            let t0 = Date()
            let terms = ContextVocab.extract(ContextText(focused: "", cursor: nil, title: "", others: [(text, 0)], appKind: .of(bundleID: app)))
            print(String(format: "%d Begriffe in %.1f ms", terms.count, Date().timeIntervalSince(t0) * 1000))
            for t in terms { print(String(format: "  %5.2f  %-10@ %@%@", t.score, t.kind.rawValue as NSString, t.text as NSString, t.unknownWord ? "  (unbekannt)" : "")) }
            var dw: [String] = []
            for w in ContextBoost.dictionaryWords().reversed() where !dw.contains(w) { dw.append(w) }
            print("Hinweis: " + ContextBoost.prompt(dictionaryWords: dw, name: "Lena",
                                                   snapshot: .init(session: 0, bundleID: app, appKind: .of(bundleID: app), terms: terms, readMs: 0, extractMs: 0, chars: text.count)))
            return 0
        case "--quality-extract-bench": extractBench(); return 0
        case "--quality-read": return wait { await readBench(Array(args.dropFirst(2))) }
        case "--quality-prompt-check": return promptCheck()
        case "--quality-guard-test": return wait { await guardTest() }
        case "--quality-context-bench": return wait { try await ContextBench.run(args) }
        default: return nil
        }
    }

    private static func wait(_ body: @escaping () async throws -> Void) -> Int32 {
        var code: Int32 = 0
        var done = false
        Task {
            do { try await body() } catch { print("Fehler: \(error)"); code = 1 }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }

    static func snapshotFor(screen: String, app: String) -> ScreenContext.Snapshot? {
        guard !screen.isEmpty else { return nil }
        let kind = ContextAppKind.of(bundleID: app)
        let terms = ContextVocab.extract(ContextText(focused: "", cursor: nil, title: "", others: [(screen, 0)], appKind: kind))
        return .init(session: 0, bundleID: app, appKind: kind, terms: terms, readMs: 0, extractMs: 0, chars: screen.count)
    }

    // MARK: Feinschliff-Regressionen

    static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "(?m)^\\d+\\.\\s", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_")).inverted).filter { !$0.isEmpty }
    }
    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Score { var n = 0, exact = 0, meaning = 0, fixNeed = 0, fixed = 0, noFix = 0, untouched = 0, broke = 0; var ms: [Int] = [] }

    static func polishEval(_ args: [String]) async {
        let engines = args.dropFirst(2).filter { !$0.hasPrefix("--") && !$0.contains(",") }
        let wanted = engines.isEmpty ? ["aus", "regeln", "apple", "claude"] : Array(engines)
        let only = args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? Set(args[$0 + 1].split(separator: ",").map(String.init)) : nil }
        let show = args.contains("--show")
        let cases = (args.contains("--holdout") ? PolishCases.holdout : args.contains("--beide") ? PolishCases.all + PolishCases.holdout : PolishCases.all)
            .filter { only == nil || only!.contains($0.id) }
        print("\(cases.count) Fälle · Apple Intelligence: \(FMPolish.available ? "verfügbar" : "NICHT verfügbar (\(FMPolish.unavailableReason))") · Claude-CLI: \(ClaudeCLI.isAvailable ? "da" : "fehlt")")
        _ = SpellBatch.unknown(["warmup"]); _ = QuickPolish.lexicalClasses("warm up")
        var table: [(String, Score, [String: Score])] = []
        for eng in wanted {
            let mode: AIPolish
            switch eng {
            case "aus": mode = .off
            case "regeln": mode = .fast; Polisher.fmAvailable = { false }
            case "apple": mode = .fast; Polisher.fmAvailable = { FMPolish.available }
                guard FMPolish.available else { print("apple: übersprungen – \(FMPolish.unavailableReason)"); continue }
            case "claude": mode = .thorough; Polisher.fmAvailable = { false }; Polisher.longWords = 0
                guard ClaudeCLI.isAvailable else { print("claude: übersprungen – CLI fehlt"); continue }
            default: print("unbekannt: \(eng)"); continue
            }
            var total = Score()
            var byTag: [String: Score] = [:]
            for c in cases {
                let snap = snapshotFor(screen: c.screen, app: c.app)
                if eng == "apple" { FMPolish.prewarm() }
                let o = await Polisher.run(c.input, snapshot: snap, mode: mode, app: c.app)
                let out = norm(o.text), exp = norm(c.expected)
                var sc = byTag[c.tag] ?? Score()
                func bump(_ f: (inout Score) -> Void) { f(&sc); f(&total) }
                bump { $0.n += 1; $0.ms.append(o.ms) }
                let ex = out == exp, mean = words(out) == words(exp)
                if ex { bump { $0.exact += 1 } }
                if mean { bump { $0.meaning += 1 } }
                if c.needsFix {
                    bump { $0.fixNeed += 1 }
                    if ex { bump { $0.fixed += 1 } }
                } else {
                    bump { $0.noFix += 1 }
                    if out == norm(c.input) { bump { $0.untouched += 1 } }
                }
                // „kaputt gemacht“: Bedeutung weicht von der erwarteten ab UND von der Eingabe (neue/fehlende Wörter)
                if !mean && words(out) != words(c.input) { bump { $0.broke += 1 } }
                byTag[c.tag] = sc
                if show || (!ex && !engines.isEmpty) {
                    print("  \(ex ? "✓" : (mean ? "≈" : "✗")) \(eng) \(c.id) [\(o.engine) \(o.ms) ms]: \(out.replacingOccurrences(of: "\n", with: "⏎"))"
                          + (ex ? "" : "\n      erwartet: \(exp.replacingOccurrences(of: "\n", with: "⏎"))"))
                }
            }
            table.append((eng, total, byTag))
        }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%3.0f %%", Double(a) / Double(b) * 100) }
        func p(_ ms: [Int], _ q: Double) -> Int { let s = ms.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
        print("\nMotor    genau   Bedeutung  Fix-Rate  unberührt  kaputt   p50    p95")
        for (eng, t, _) in table {
            print(String(format: "%-8@ %@   %@     %@    %@     %3d   %4d ms %5d ms", eng as NSString, pct(t.exact, t.n) as NSString, pct(t.meaning, t.n) as NSString,
                         pct(t.fixed, t.fixNeed) as NSString, pct(t.untouched, t.noFix) as NSString, t.broke, p(t.ms, 0.5), p(t.ms, 0.95)))
        }
        let tags = ["korrektur", "fehlstart", "liste", "namen", "code", "chat", "ohne", "satzzeichen"]
        print("\nGenau je Art: " + table.map { $0.0 }.joined(separator: " / "))
        for tag in tags {
            let cells = table.map { t -> String in let s = t.2[tag] ?? Score(); return "\(s.exact)/\(s.n)" }
            print("  " + tag.padding(toLength: 12, withPad: " ", startingAt: 0) + cells.joined(separator: "   "))
        }
    }

    // MARK: Auswerte-Zeit

    static func extractBench() {
        let base = """
        Von: Anneliese Okonkwo <a.okonkwo@example.org> An: Daniel Brenninkmeyer Betreff: Planung Sommerfest
        Hallo Lena, danke für deine Nachricht. Ich habe gestern mit Herrn Nwachukwu telefoniert und die Rechnung an die Buchhaltung geschickt.
        Der Termin mit Rafael Duarte ist am Freitag in Wolfenbüttel. Bitte ruf fetchUserProfile erst nach dem Login auf, sonst kommt null zurück.
        Die Kinder spielen im Garten und das Wetter ist schön. @jmueller hat das Ticket VF-231 übernommen. Viele Grüße, Siobhan.

        """
        _ = SpellBatch.unknown(["warmup"])
        print("Zeichen   Begriffe   Auswerten")
        for n in [1_000, 5_000, 10_000, 20_000, 40_000] {
            var s = ""
            var k = 0
            while s.count < n { s += base.replacingOccurrences(of: "VF-231", with: "VF-\(k)"); k += 1 }
            var times: [Double] = []
            var cnt = 0
            for _ in 0..<5 {
                let t0 = Date()
                cnt = ContextVocab.extract(ContextText(focused: "", cursor: nil, title: "", others: [(String(s.prefix(n)), 0)], appKind: .mail)).count
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
            times.sort()
            print(String(format: "%7d   %8d   %6.1f ms (Median von 5)", n, cnt, times[2]))
        }
    }

    // MARK: Echtes Fenster lesen (nur Zahlen)

    static func readBench(_ bundles: [String]) async {
        guard AXIsProcessTrusted() else { print("Bedienungshilfen fehlen für dieses Programm"); return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let targets = bundles.isEmpty ? apps : apps.filter { a in bundles.contains { a.bundleIdentifier?.lowercased().hasPrefix($0.lowercased()) ?? false } }
        print("App                         lesen   Zeichen  Begriffe  auswerten  (Arten)")
        for app in targets {
            let b = app.bundleIdentifier ?? "?"
            if CorrectionLearner.blockedApps.contains(b) { print("\(b): übersprungen (Passwort-App)"); continue }
            let kind = ContextAppKind.of(bundleID: b)
            var enabled = false
            var times: [Int] = []
            var ctx: ContextText?
            for _ in 0..<3 {
                let t0 = Date()
                ctx = ScreenContext.read(pid: app.processIdentifier, kind: kind, enable: {
                    let el = AXUIElementCreateApplication(app.processIdentifier)
                    var cur: CFTypeRef?
                    let had = AXUIElementCopyAttributeValue(el, "AXManualAccessibility" as CFString, &cur) == .success && (cur as? Bool) == true
                    if !had, AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success { enabled = true }
                })
                times.append(Int(Date().timeIntervalSince(t0) * 1000))
            }
            if enabled { AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanFalse) }
            guard let c = ctx else { print("\(b): Passwortfeld – nichts gelesen"); continue }
            let t1 = Date()
            let terms = ContextVocab.extract(c)
            let ex = Int(Date().timeIntervalSince(t1) * 1000)
            var kinds: [String: Int] = [:]
            for t in terms { kinds[t.kind.rawValue, default: 0] += 1 }
            print(String(format: "%-26@ %@ ms  %7d  %8d  %6d ms  %@", String(b.prefix(26)) as NSString, times.map(String.init).joined(separator: "/") as NSString, c.charCount, terms.count, ex,
                         kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") as NSString))
        }
    }

    // MARK: Wächter + Zeitlimit (simulierte KI – Apple Intelligence ist auf diesem Mac aus)

    static func guardTest() async {
        var ok = 0, n = 0
        func check(_ c: Bool, _ label: String) { n += 1; if c { ok += 1 }; print("\(c ? "✓" : "✗") \(label)") }
        let cases: [(String, String, [String], Bool, String)] = [
            ("Wir treffen uns am Donnerstag, nein warte, am Freitag.", "Wir treffen uns am Freitag.", [], true, "Selbstkorrektur angenommen"),
            ("Kannst du mir die Folien schicken?", "Kannst du mir bitte die Folien bis morgen schicken?", [], false, "neue Wörter → verworfen"),
            ("Kannst du mir die Folien schicken?", "Can you send me the slides?", [], false, "übersetzt → verworfen"),
            ("Frag Okonkwo, ob das passt.", "Frag Okonkwu, ob das passt.", ["Okonkwo"], false, "Name verändert → verworfen"),
            ("Ich meine, das sollten wir wirklich machen.", "Das sollten wir wirklich machen.", [], false, "„Ich meine,“ gestrichen → verworfen"),
            ("I think, I think we should wait.", "We should wait.", [], false, "zu viel gestrichen → verworfen"),
            ("I think, I think we should wait.", "I think we should wait.", [], true, "Wiederholung weg → angenommen"),
            ("Wann ist das Treffen", "Das Treffen ist um 10 Uhr.", [], false, "Frage beantwortet → verworfen"),
            ("Ich brauche erstens Milch, zweitens Brot.", "Ich brauche:\n1. Milch\n2. Brot", [], true, "Liste angenommen"),
            ("Das Meeting ist morgen weil der Raum belegt ist", "Das Meeting ist morgen, weil der Raum belegt ist.", [], true, "Komma/Punkt angenommen"),
            ("Das war ein langer Tag, und jetzt gehe ich schlafen, gute Nacht.", "Langer Tag. Gute Nacht.", [], false, "gekürzt → verworfen"),
            ("Nein, warte kurz, ich komme gleich.", "Warte kurz, ich komme gleich.", [], false, "„Nein,“ ohne Grund gestrichen → verworfen"),
        ]
        for (i, o, prot, want, label) in cases { check(Polisher.accept(input: i, output: o, protected: prot) == want, label) }
        // Zeitlimit: KI braucht 2 s → nach ~1,2 s gilt das Regel-Ergebnis
        Polisher.fmAvailable = { true }
        Polisher.fm = { text, _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return (text + " EXTRA", 2000)
        }
        FMPolish.timeout = 1.2
        let slowFM: @Sendable (String, [String]) async -> (text: String, ms: Int)? = { text, terms in
            await Deadline.run(seconds: FMPolish.timeout) { () -> (text: String, ms: Int) in
                try await Task.sleep(nanoseconds: 2_000_000_000); return (text + " EXTRA", 2000)
            }
        }
        Polisher.fm = slowFM
        let t0 = Date()
        let o = await Polisher.run("Wir treffen uns am Donnerstag, nein warte, am Freitag.", snapshot: nil, mode: .fast)
        let dt = Date().timeIntervalSince(t0)
        check(o.engine == "regeln" && o.text == "Wir treffen uns am Freitag." && dt < 1.5, String(format: "KI zu langsam → Regeln nach %.2f s (%@)", dt, o.engine))
        // KI liefert Unsinn → Regeln
        Polisher.fm = { _, _ in ("Hier ist der bereinigte Text: Wir treffen uns am Freitag.", 300) }
        let o2 = await Polisher.run("Wir treffen uns am Donnerstag, nein warte, am Freitag.", snapshot: nil, mode: .fast)
        check(o2.engine == "regeln", "KI-Vorrede → verworfen, Regeln (\(o2.engine))")
        // KI gut → angenommen, Aufwand nur wenn nötig
        Polisher.fm = { _, _ in ("Wir treffen uns am Freitag.", 300) }
        let o3 = await Polisher.run("Wir treffen uns am Donnerstag, nein warte, am Freitag.", snapshot: nil, mode: .fast)
        check(o3.engine == "apple", "gute KI-Antwort angenommen (\(o3.engine))")
        var called = false
        Polisher.fm = { t, _ in called = true; return (t, 1) }
        _ = await Polisher.run("Das ist ein ganz normaler Satz ohne Fehler.", snapshot: nil, mode: .fast)
        check(!called, "sauberer Satz → KI wird gar nicht gefragt")
        print("\(ok)/\(n) bestanden")
    }

    // MARK: Whisper-Hinweis unverändert?

    static func promptCheck() -> Int32 {
        func old(_ words: [String], _ name: String) -> String {
            var list = Array(words.prefix(24))
            var sentence = ""
            while true {
                let joined = list.count > 1 ? list.dropLast().joined(separator: ", ") + " und " + list.last! : (list.first ?? "")
                sentence = "Ich bin \(name)." + (joined.isEmpty ? "" : " Heute geht es um \(joined).")
                if sentence.count <= 380 || list.isEmpty { break }
                list.removeLast()
            }
            return sentence
        }
        var words: [String] = []
        for e in Settings.frozen.dictionary.reversed() { let w = e.write.trimmingCharacters(in: .whitespaces); if !w.isEmpty, !words.contains(w) { words.append(w) } }
        var ok = true
        let long = (1...40).map { "Begriff\($0)Lang" }
        for (label, ws) in [("dein Wörterbuch", words), ("leer", []), ("40 lange Wörter", long)] {
            let a = old(ws, "Lena"), b = ContextBoost.prompt(dictionaryWords: ws, name: "Lena", snapshot: nil)
            print("\(a == b ? "✓" : "✗") \(label): \(b.count) Zeichen")
            ok = ok && a == b
        }
        let snap = snapshotFor(screen: "Von: Anneliese Okonkwo\nAn: Siobhan Nwachukwu\nfetchUserProfile get_user_by_id Hallbauer", app: PolishCases.vscode)
        for (label, ws) in [("dein Wörterbuch + Bildschirm", words), ("40 lange Wörter + Bildschirm", long)] {
            let p = ContextBoost.prompt(dictionaryWords: ws, name: "Lena", snapshot: snap)
            print("  \(label) (\(p.count) Zeichen): \(p)")
            ok = ok && p.count <= 380
        }
        return ok ? 0 : 1
    }
}
