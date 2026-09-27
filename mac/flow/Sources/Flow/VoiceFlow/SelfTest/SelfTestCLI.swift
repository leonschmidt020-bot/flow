import AppKit
import Foundation

// MARK: - Release-Tor: Selbsttests ohne Oberfläche (scripts/release.sh)
//
//   FLOW_HOME=<leer> Flow --selftest-learner              Wort-Lerner (CorrectionLearner + AliasLearner), Fälle aus der Geschichte
//   FLOW_HOME=<leer> Flow --selftest-lock                 app.lock: zweite Instanz abgewiesen, nach Freigabe/Absturz wieder frei
//   FLOW_HOME=<leer> Flow --selftest-health               health.json: Lebenszeichen, unsauberes Ende, Absturzberichte (.ips)
//   Flow --selftest-guard                                   nur der Schutz: ohne/mit echtem FLOW_HOME → Exit 3
//   Flow --selftest-lock-probe <datei> [hold]              intern: Sperre versuchen (0 = frei, 1 = belegt), „hold“ = halten bis kill
//   Flow --updater-command <ordner> <logdatei>             genau der Shell-Befehl, den „Installieren“ ausführt
//   CLIPVAULT_HOME=<gerät> Flow --selftest-shared-new [--mark-all]
//                                                            Neu-Liste (grüner Punkt) so, wie die Pille sie sieht, als JSON
//
// Alle Tests mit Daten verweigern den Start ohne FLOW_HOME (bzw. CLIPVAULT_HOME) – die echten Ordner bleiben unberührt.
// Nie App-Modus: kein NSApplication.run, keine Pille, kein Hotkey, keine Zwischenablage.

enum SelfTestCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--selftest-learner": return guardedHome { LearnerSelfTest.run() }
        case "--selftest-lock": return guardedHome { LockSelfTest.run() }
        case "--selftest-health": return guardedHome { HealthSelfTest.run() }
        // Prüft nur den Schutz selbst (harmlos, falls er versagt): 0 = läuft mit Test-Ordner, 3 = verweigert
        case "--selftest-guard": return guardedHome { print("Testordner: \(Paths.base.path)"); return 0 }
        case "--selftest-lock-probe":
            guard args.count > 2 else { return 2 }
            return LockSelfTest.probe(args[2], hold: args.count > 3 && args[3] == "hold")
        case "--updater-command":
            guard args.count > 3 else { FileHandle.standardError.write("Aufruf: --updater-command <ordner> <logdatei>\n".data(using: .utf8)!); return 2 }
            print(Updater.installScript(dir: args[2], logPath: args[3]))
            return 0
        case "--selftest-shared-new": return SharedNewSelfTest.run(markAll: args.contains("--mark-all"))
        default: return nil
        }
    }

    /// Nur mit eigenem, von ~/.config/flow verschiedenem FLOW_HOME
    static func guardedHome(_ body: () -> Int32) -> Int32 {
        let env = ProcessInfo.processInfo.environment["FLOW_HOME"] ?? ""
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow").standardizedFileURL.path
        // Erst prüfen, DANN Paths.base anfassen (Paths.base legt den Ordner an – nie den echten)
        let envPath = env.isEmpty ? "" : URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL.path
        guard !envPath.isEmpty, envPath != real else {
            FileHandle.standardError.write("Abbruch: bitte mit FLOW_HOME=<leerer Testordner> starten (nie ~/.config/flow).\n".data(using: .utf8)!)
            return 3
        }
        guard Paths.base.standardizedFileURL.path == URL(fileURLWithPath: env).standardizedFileURL.path,
              Paths.base.standardizedFileURL.path != real else {
            FileHandle.standardError.write("Abbruch: bitte mit FLOW_HOME=<leerer Testordner> starten (Paths.base = \(Paths.base.path)).\n".data(using: .utf8)!)
            return 3
        }
        return body()
    }
}

/// Kleines Prüf-Gerüst: jede Prüfung eine Zeile „ok …“ / „FEHLER …“, Ende „N/M ok“, Exit 1 bei einem Fehler.
final class SelfTestChecks {
    private(set) var passed = 0, failed = 0
    private var failures: [String] = []
    func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ok      \(what)") } else {
            failed += 1
            let d = detail()
            failures.append(what)
            print("  FEHLER  \(what)\(d.isEmpty ? "" : " – \(d)")")
        }
    }
    func section(_ s: String) { print(s) }
    func finish(_ name: String) -> Int32 {
        print("\(name): \(passed)/\(passed + failed) ok\(failed > 0 ? " – fehlgeschlagen: " + failures.joined(separator: "; ") : "")")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - Wort-Lerner

enum LearnerSelfTest {
    typealias Pair = (old: String, new: String)
    static func fmt(_ p: [Pair]) -> String { p.isEmpty ? "–" : p.map { "„\($0.old)“→„\($0.new)“" }.joined(separator: ", ") }
    static func has(_ p: [Pair], _ o: String, _ n: String) -> Bool { p.contains { $0.old == o && $0.new == n } }
    static func learned(_ a: String, _ b: String) -> [Pair] {
        CorrectionLearner.replacements(from: a, to: b).filter { CorrectionLearner.shouldLearn(old: $0.old, new: $0.new) }
    }
    static func lower(_ w: [String]) -> [String] { w.map { CorrectionLearner.bare($0).lowercased() } }

    /// Grenzen beim Einfügen (wie CorrectionLearner.watch): je 3 Wörter davor/danach
    static func bounds(inserted: String, screen: String) -> (pre: [String], post: [String])? {
        let w = CorrectionLearner.words(screen), l = lower(w)
        guard let f = CorrectionLearner.locate(CorrectionLearner.words(inserted), in: w) else { return nil }
        return (Array(l[max(0, f.lo - 3)..<f.lo]), Array(l[f.hi..<min(l.count, f.hi + 3)]))
    }

    /// Ein ganzer Beobachtungs-Durchlauf wie CorrectionLearner.poll(): Bildschirm beim Einfügen → nach der Korrektur
    static func observe(inserted: String, before: String, after: String) -> [Pair] {
        guard let b = bounds(inserted: inserted, screen: before) else { return [] }
        let insW = CorrectionLearner.words(inserted), valW = CorrectionLearner.words(after)
        let region: [String]? = insW.count == 1
            ? CorrectionLearner.regionBetween(pre: b.pre, post: b.post, in: valW)
            : CorrectionLearner.locate(insW, in: valW, pre: b.pre, post: b.post)?.words
        guard let region else { return [] }
        return learned(inserted, region.joined(separator: " "))
    }

    /// Settings.frozen (von TextCleaner benutzt) folgt Änderungen über die Main-RunLoop → kurz laufen lassen
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    // MARK: Terminal-Fixtures (synthetisch – nachgebaut nach der gemessenen Struktur von VS Code/xterm.js + Claude Code,
    // 27.09.2026: eine Zeile je Gruppe, auf volle Breite mit Leerzeichen aufgefüllt; KEIN echter Terminal-Text)

    static let rule = String(repeating: "─", count: 60)
    static func pad(_ r: String, _ w: Int = 60) -> String { r.count >= w ? r : r + String(repeating: " ", count: w - r.count) }

    /// Claude Code (neue Box): Verlauf, abgeschickte Nachrichten („❯ …“, Fortsetzung eingerückt), Linie, Eingabe („❯\u{00A0}…“), Linie, Status
    static func claude(input: [String], sent: [[String]] = [], above: [String] = ["⏺ Erledigt, die Tests laufen wieder.", "", "✻ Gearbeitet für 1m 12s"],
                       spinner: String = "✻ Gearbeitet für 1m 12s") -> [String] {
        var r = above + [""]
        for m in sent {
            r.append("❯ " + m[0]); r += m.dropFirst().map { "  " + $0 }
            r += ["", "⏺ Mache ich.", "", spinner, ""]
        }
        r.append(rule)
        r.append("❯\u{00A0}" + (input.first ?? ""))       // gemessen: Eingabezeile mit geschütztem Leerzeichen
        r += input.dropFirst().map { "  " + $0 }
        r.append(rule)
        r += ["  Modell: Opus 4.7 (1M context) · Kontext: 42%", "  ⏵⏵ accept edits on (shift+tab to cycle) · 3 files"]
        return r.map { pad($0) }
    }

    /// Ältere Claude-Code-Box mit Rahmen „╭─╮ │ > … │ ╰─╯“
    static func claudeOld(input: [String]) -> [String] {
        let w = 60
        var r = ["⏺ Fertig.", "", "╭" + String(repeating: "─", count: w - 2) + "╮"]
        for (i, l) in input.enumerated() { r.append("│ " + pad((i == 0 ? "> " : "  ") + l, w - 4) + " │") }
        r += ["╰" + String(repeating: "─", count: w - 2) + "╯", "  ? for shortcuts"]
        return r
    }

    static func knownWords(_ ins: String) -> Set<String> { Set(CorrectionLearner.words(ins).map { CorrectionLearner.bare($0).lowercased() }) }

    /// Ganzer Ablauf wie CorrectionLearner.poll(): Stand beim Einfügen → Lesungen (leeres Array = nichts lesbar).
    /// `finalLast` = die letzte Lesung ist der letzte Vergleich (neues Diktat).
    static func flow(_ ins: String, _ start: [String], _ polls: [[String]], field: Bool = false, finalLast: Bool = false)
        -> (asks: [Pair], end: String?, anchor: CorrectionLearner.AnchorResult, tracker: CorrectionLearner.Tracker) {
        let k = knownWords(ins)
        func scr(_ rows: [String]) -> TerminalPrompt.Screen {
            field ? TerminalPrompt.Screen(all: CorrectionLearner.norm(rows.joined(separator: "\n"))) : TerminalPrompt.parse(rows, known: k)
        }
        let res = CorrectionLearner.anchor(inserted: CorrectionLearner.norm(ins), in: scr(start), fieldMode: field)
        var tr = CorrectionLearner.Tracker()
        guard case .found(let a) = res else { return ([], nil, res, tr) }
        var asks: [Pair] = []
        for (i, p) in polls.enumerated() {
            let readable = !p.isEmpty
            let st = tr.step(readable ? CorrectionLearner.reading(a, scr(p)) : nil, readable: readable, final: finalLast && i == polls.count - 1)
            asks += st.ask
            if let e = st.end { return (asks, e, res, tr) }
        }
        return (asks, nil, res, tr)
    }
    static func place(_ r: CorrectionLearner.AnchorResult) -> String {
        switch r { case .found(let a): return a.place.rawValue; case .sentAlready: return "schon abgeschickt"; case .notFound(let s): return "nicht gefunden (\(s))" }
    }

    static func run() -> Int32 {
        _ = NSApplication.shared          // NSSpellChecker braucht eine App-Instanz (ohne run)
        let t = SelfTestChecks()
        AliasLearner.minSeen = 2
        try? FileManager.default.removeItem(at: AliasLearner.url)

        t.section("1) replacements / Verhörer vs. Grammatik")
        var p = learned("ich will das heute noch auffixen", "ich will das heute noch auch fixen")
        t.check(has(p, "auffixen", "auch fixen"), "„auffixen“ → „auch fixen“ (ein Wort wird zwei)", fmt(p))
        p = learned("wir gehen zur Legal einkaufen", "wir gehen zu Lidl einkaufen")
        t.check(has(p, "Legal", "Lidl") && !p.contains { $0.old == "zur" }, "„zur Legal“ → „zu Lidl“: nur Legal→Lidl, zur→zu ist Grammatik", fmt(p))
        p = learned("ich gehe morgen", "Ich gehe morgen")
        t.check(p.isEmpty, "nur Groß/klein („ich“ → „Ich“) wird nicht gelernt", fmt(p))
        t.check(!CorrectionLearner.shouldLearn(old: "zur", new: "zu"), "shouldLearn(zur → zu) = nein (Grammatik)")
        t.check(!CorrectionLearner.shouldLearn(old: "das", new: "dass"), "shouldLearn(das → dass) = nein (Grammatik)")
        t.check(CorrectionLearner.shouldLearn(old: "ID", new: "Lidl"), "shouldLearn(ID → Lidl) = ja (Name)")
        p = learned("Whisper Floor ist schnell", "Flow ist schnell")
        t.check(has(p, "Whisper Floor", "Flow"), "Name aus zwei Wörtern wird als Ganzes gelernt", fmt(p))
        p = learned("das ist ein ganz anderer Satz mit vielen Wörtern", "heute regnet es und wir bleiben lieber zu Hause")
        t.check(p.isEmpty, "großer Umbau statt Korrektur → nichts", fmt(p))

        t.section("2) locate: „West“ gelöscht darf nicht mit der Statuszeile gepaart werden")
        let ins = "West wurde gelöscht und neu angelegt"
        let before = "Opus 4 Modell ❯ West wurde gelöscht und neu angelegt"
        let after = "Opus 4 Modell ❯ wurde gelöscht und neu angelegt"
        p = observe(inserted: ins, before: before, after: after)
        t.check(!p.contains { $0.new.lowercased().contains("modell") || $0.old == "West" }, "Löschen von „West“ → kein Paar mit „Modell“", fmt(p))
        let noGuard = CorrectionLearner.locate(CorrectionLearner.words(ins), in: CorrectionLearner.words(after))
        t.check(noGuard?.words.first == "Modell", "Gegenprobe ohne Grenzen findet „Modell“ (der alte Fehler ist nachstellbar)", noGuard?.words.joined(separator: " ") ?? "–")
        p = observe(inserted: "wir treffen uns bei ID um acht", before: "Status: bereit ❯ wir treffen uns bei ID um acht",
                    after: "Status: bereit ❯ wir treffen uns bei Lidl um acht")
        t.check(has(p, "ID", "Lidl") && p.count == 1, "Wort mitten im Satz ersetzt → genau ID→Lidl", fmt(p))
        let loc = CorrectionLearner.locate(CorrectionLearner.words("ganz am Ende steht Okonkwo"), in: CorrectionLearner.words("xx yy ganz am Ende steht Okonkwu zz"))
        t.check(loc?.words.last == "Okonkwu" && loc?.score == 4, "locate nimmt geändertes letztes Wort mit", loc.map { "\($0.words) \($0.score)" } ?? "–")

        t.section("3) Diktat aus einem einzigen Wort (regionBetween)")
        p = observe(inserted: "Lidel", before: "Wir gehen morgen zu Lidel und dann heim", after: "Wir gehen morgen zu Lidl und dann heim")
        t.check(has(p, "Lidel", "Lidl"), "einzelnes Wort in der Mitte: Lidel → Lidl", fmt(p))
        p = observe(inserted: "auffixen", before: "Kannst du das bitte auffixen", after: "Kannst du das bitte auch fixen")
        t.check(has(p, "auffixen", "auch fixen"), "einzelnes Wort am Ende: auffixen → auch fixen (höchstens 2 Wörter)", fmt(p))
        let r = CorrectionLearner.regionBetween(pre: ["gehen", "zu"], post: [], in: CorrectionLearner.words("wir gehen zu Lidl und dann nach Hause"))
        t.check(r == ["Lidl", "und"], "am Ende ohne Nachbarn danach: höchstens 2 Wörter", "\(r ?? [])")
        t.check(CorrectionLearner.regionBetween(pre: ["gehen", "zu"], post: ["heute"], in: CorrectionLearner.words("ganz anderer Text")) == nil,
                "Nachbarn nicht mehr da → nil (nichts raten)")
        t.check(CorrectionLearner.regionBetween(pre: [], post: [], in: ["Lidl"]) == ["Lidl"], "Feld enthält nur das Wort → das Wort")
        t.check(CorrectionLearner.regionBetween(pre: ["a"], post: ["b"], in: CorrectionLearner.words("a eins zwei drei vier b")) == nil,
                "mehr als 3 Wörter dazwischen → nil")

        t.section("4) options: Vorschläge")
        let o = CorrectionLearner.options(old: "auffixen", new: "auch fixen", seen: ["auch fixen", "auch f", "auch", "auch fi"])
        t.check(o.first == "auch fixen", "erster Vorschlag = zuletzt Geschriebenes", "\(o)")
        t.check(!o.contains("auch f") && !o.contains("auch fi"), "halb getippte Zwischenstände werden nicht angeboten", "\(o)")
        t.check(o.contains("auch"), "Zwischenstand „auch“ wird angeboten", "\(o)")
        t.check(o.count <= 3 && !o.contains { $0.lowercased() == "auffixen" }, "höchstens 3, nie das Original", "\(o)")

        t.section("5) „Fan“ bleibt nur Hinweis (vocabOnly)")
        let dict = [DictEntry(heard: "DEFAN", write: "DeFan"), DictEntry(heard: "De Fan", write: "Defan")]
        AliasLearner.minSeen = 1
        let ready = AliasLearner.observe(parakeet: "Das Team von Fan ist toll", whisper: "Das Team von DeFan ist toll", dictionary: dict)
        t.check(ready.count == 1, "je gehörtem Wort nur EIN Ziel (nicht Fan→Defan UND Fan→DeFan)", ready.map { "\($0.heard)→\($0.write)" }.joined(separator: ", "))
        t.check(ready.first?.heard == "Fan" && ready.first?.vocabOnly == true, "AliasLearner: „Fan“ → nur Hinweis", "\(ready.first.map { "\($0.heard) vocabOnly=\(String(describing: $0.vocabOnly))" } ?? "–")")
        AliasLearner.minSeen = 2
        let st = Settings.shared
        st.dictionary = Settings.defaultDictionary
        CorrectionLearner.remember(old: "Fan", new: "DeFan")
        settle()
        let fan = st.dictionary.first { $0.heard == "Fan" }
        t.check(fan?.vocabOnly == true && fan?.learned == true, "CorrectionLearner.remember(Fan → DeFan) = nur Hinweis", "\(String(describing: fan))")
        t.check(Settings.frozen.dictionary.contains { $0.heard == "Fan" }, "Eintrag ist im aktiven Wörterbuch (Gegenprobe)")
        let cleaned = TextCleaner.applyRules("Ich bin ein großer Fan davon.", settings: st)
        t.check(cleaned.contains("Fan") && !cleaned.contains("DeFan"), "Regeln ersetzen „Fan“ im Satz NICHT", cleaned)
        CorrectionLearner.remember(old: "Okonkwu", new: "Okonkwo")
        settle()
        let kol = st.dictionary.first { $0.heard == "Okonkwu" }
        t.check(kol?.vocabOnly == false, "Kunstwort „Okonkwu“ → echte Ersetzung", "\(String(describing: kol))")
        t.check(TextCleaner.applyRules("Das hat Okonkwu gesagt.", settings: st).contains("Okonkwo"), "Regel ersetzt Okonkwu → Okonkwo")
        st.dictionary = Settings.defaultDictionary
        settle()

        t.section("6) AliasLearner-Regeln")
        let aldi = [DictEntry(heard: "Aldi", write: "Aldi", vocabOnly: true)]
        t.check(AliasLearner.proposals(parakeet: "wir gehen noch zu all", whisper: "wir gehen noch zu Aldi", dictionary: aldi).isEmpty,
                "Füllwort allein („all“) wird nie als Verhörer gelernt")
        t.check(AliasLearner.proposals(parakeet: "wir gehen noch zum Bäcker", whisper: "wir gehen noch zu Aldi", dictionary: aldi).isEmpty,
                "ganz anderes Wort („Bäcker“) ist kein Verhörer")
        let wf = [DictEntry(heard: "Clip Vault", write: "Clip Vault", vocabOnly: true)]
        let prop = AliasLearner.proposals(parakeet: "Klipvault ist schnell", whisper: "Clip Vault ist schnell", dictionary: wf)
        t.check(prop.contains { $0.heard == "Klipvault" && $0.write == "Clip Vault" }, "Klang-/Schreibähnliches wird vorgeschlagen", prop.map { "\($0.heard)→\($0.write)" }.joined(separator: ", "))
        try? FileManager.default.removeItem(at: AliasLearner.url)
        let first = AliasLearner.observe(parakeet: "Klipvault ist schnell", whisper: "Clip Vault ist schnell", dictionary: wf)
        let second = AliasLearner.observe(parakeet: "Klipvault ist schnell", whisper: "Clip Vault ist schnell", dictionary: wf)
        t.check(first.isEmpty && second.count == 1 && second.first?.vocabOnly == nil, "erst nach minSeen=2 Bestätigungen, Kunstwort = Ersetzung",
                "1.: \(first.count), 2.: \(second.map { "\($0.heard)→\($0.write) vocabOnly=\(String(describing: $0.vocabOnly))" })")
        let known = wf + [DictEntry(heard: "Klipvault", write: "Clip Vault", learned: true)]
        t.check(AliasLearner.observe(parakeet: "Klipvault ist schnell", whisper: "Clip Vault ist schnell", dictionary: known).isEmpty,
                "schon im Wörterbuch → nicht nochmal")
        t.check(AliasLearner.realWords("Jacke") && !AliasLearner.realWords("Okonkwu"), "realWords: echtes Wort vs. Kunstwort")

        t.section("7) Claude-Code-Box zerlegen (synthetische Terminal-Zeilen)")
        let insK = "frag mal Klot ob das mit dem neuen Build und den Terminal-Zeilen jetzt wirklich zuverlässig funktioniert"
        let boxRows = claude(input: ["frag mal Klot ob das mit dem neuen Build und den", "Terminal-Zeilen jetzt wirklich zuverlässig funktioniert"])
        let sc = TerminalPrompt.parse(boxRows, known: knownWords(insK))
        t.check(sc.input == insK, "umbrochene Eingabe über 2 Zeilen, ohne Prompt/Linien/Einrückung", sc.input ?? "–")
        t.check(sc.hasBox && sc.sent.isEmpty, "Box erkannt, noch nichts abgeschickt", "\(sc.sent)")
        t.check(!(sc.input ?? "").contains("Modell") && !(sc.input ?? "").contains("Gearbeitet"), "Status- und Spinner-Zeilen gehören nicht zur Eingabe")
        let old = TerminalPrompt.parse(claudeOld(input: ["bitte prüf das mit", "dem Wortlerner nochmal"]))
        t.check(old.input == "bitte prüf das mit dem Wortlerner nochmal", "ältere Box „│ > … │“: Rahmen weg", old.input ?? "–")
        let hist = TerminalPrompt.parse(claude(input: [""], sent: [["frag mal Claude ob das mit dem neuen Build und den", "Terminal-Zeilen jetzt wirklich zuverlässig funktioniert"]]),
                                        known: knownWords(insK))
        t.check(hist.input == "" && hist.sent.last == insK.replacingOccurrences(of: "Klot", with: "Claude"),
                "abgeschickt: Box leer, Nachricht als „❯ …“ im Verlauf (2 Zeilen)", "\(hist.input ?? "–") | \(hist.sent)")
        let glued = TerminalPrompt.join([("bitte den Wortler", true), ("ner prüfen", false)], known: knownWords("bitte den Wortlerner prüfen"))
        t.check(glued == "bitte den Wortlerner prüfen", "mitten im Wort umbrochen (volle Zeile) → wieder zusammengesetzt", glued)
        let apart = TerminalPrompt.join([("frag mal", true), ("Klot ob", false)], known: knownWords("frag mal Klot ob"))
        t.check(apart == "frag mal Klot ob", "volle Zeile, aber zwei bekannte Wörter → Leerzeichen bleibt", apart)
        t.check(TerminalPrompt.parse(claude(input: ["[Pasted text #1 +12 lines]"])).collapsed, "eingeklappter Text „[Pasted text …]“ erkannt")
        let shell = TerminalPrompt.parse(["~/code main", "❯ git commit -m \"Wortlerner geht wieder\"", ""].map { pad($0) })
        t.check(!shell.hasBox, "normale Shell mit „❯“-Prompt ist keine Claude-Code-Box")

        t.section("8) Ablauf im Terminal: Box bearbeiten, abschicken, neues Diktat")
        let insC = "frag mal Klot ob das mit dem neuen Build geht"
        let boxStart = claude(input: ["frag mal Klot ob das mit dem neuen Build geht"])
        let edited = claude(input: ["frag mal Claude ob das mit dem neuen Build geht"], spinner: "✻ Gearbeitet für 1m 13s")
        let sentEdited = claude(input: [""], sent: [["frag mal Claude ob das mit dem neuen Build geht"]])
        var f = flow(insC, boxStart, [edited, edited, edited])
        t.check(place(f.anchor) == "Claude-Code-Eingabe", "Stelle beim Einfügen: Claude-Code-Eingabe", place(f.anchor))
        t.check(has(f.asks, "Klot", "Claude") && f.asks.count == 1, "in der Box korrigiert, 3 Runden gleich → „Klot“ → „Claude“", fmt(f.asks))
        f = flow(insC, boxStart, [edited, sentEdited])
        t.check(has(f.asks, "Klot", "Claude") && f.end == "abgeschickt", "korrigiert + sofort Enter → gesendete Fassung zählt sofort", "\(fmt(f.asks)) · \(f.end ?? "–")")
        f = flow(insC, boxStart, [sentEdited])
        t.check(has(f.asks, "Klot", "Claude"), "Korrektur erst im Verlauf gesehen (Enter vor der ersten Runde)", fmt(f.asks))
        f = flow(insC, boxStart, [boxStart, claude(input: [""], sent: [["frag mal Klot ob das mit dem neuen Build geht"]])])
        t.check(f.asks.isEmpty && f.end == "abgeschickt", "ohne Änderung abgeschickt → nichts gefragt, Beobachtung endet", "\(fmt(f.asks)) · \(f.end ?? "–")")
        f = flow(insC, boxStart, [edited], finalLast: true)
        t.check(has(f.asks, "Klot", "Claude") && f.end == "vorbei", "korrigiert, dann gleich neues Diktat (finish) → trotzdem gefragt", "\(fmt(f.asks)) · \(f.end ?? "–")")
        f = flow(insC, boxStart, [edited, edited, claude(input: [""], above: ["⏺ viel Ausgabe", "  noch mehr Ausgabe"])])
        t.check(has(f.asks, "Klot", "Claude"), "Änderung stand 2 Runden, dann weggescrollt → gefragt", fmt(f.asks))
        let longer = claude(input: ["frag mal Klot ob das mit dem neuen Build geht. Und schau dir danach", "bitte auch die Logs an"])
        f = flow(insC, boxStart, [longer, longer, longer, longer])
        t.check(f.asks.isEmpty && !f.tracker.everSaw, "neuen Satz angehängt → keine Korrektur", fmt(f.asks))
        let deleted = claude(input: ["frag mal Klot ob das mit dem Build geht"])
        f = flow(insC, boxStart, [deleted, deleted, deleted])
        t.check(f.asks.isEmpty, "nur ein Wort gelöscht → keine Korrektur", fmt(f.asks))
        f = flow("teste bitte den Wort Lerner im Terminal", claude(input: ["teste bitte den Wort Lerner im Terminal"]),
                 [claude(input: ["teste bitte den Wortlerner im Terminal"])], finalLast: true)
        t.check(has(f.asks, "Wort Lerner", "Wortlerner"), "zusammengeschrieben (2 Wörter → 1) wird erkannt", fmt(f.asks))
        let insG = "der Code liegt auf Github im privaten Repo"
        f = flow(insG, claude(input: [insG]), [claude(input: ["der Code liegt auf GitHub im privaten Repo"])], finalLast: true)
        t.check(has(f.asks, "Github", "GitHub"), "nur andere Groß/klein-Schreibung IM Wort (Github → GitHub) wird gelernt", fmt(f.asks))
        f = flow("wir sehen uns morgen früh", claude(input: ["wir sehen uns morgen früh"]), [claude(input: ["wir gehen uns morgen früh"])], finalLast: true)
        t.check(has(f.asks, "sehen", "gehen"), "echtes Wort durch anderes echtes Wort (kleingeschrieben) = Verhörer", fmt(f.asks))
        let typing = ["L", "Li", "Lid", "Lidl", "Lidl", "Lidl"].map { claude(input: ["wir treffen uns bei \($0) um acht"]) }
        f = flow("wir treffen uns bei ID um acht", claude(input: ["wir treffen uns bei ID um acht"]), typing)
        let optsT = CorrectionLearner.options(old: "ID", new: "Lidl", seen: f.tracker.seen["ID"] ?? [])
        t.check(f.asks.count == 1 && has(f.asks, "ID", "Lidl") && !optsT.contains("Lid"), "langsam getippt: erst „Lidl“ gefragt, Zwischenstände nicht angeboten",
                "\(fmt(f.asks)) · \(optsT)")
        let repeatOld = claude(input: [insC], sent: [[insC]])
        f = flow(insC, repeatOld, [claude(input: [""], sent: [[insC], ["frag mal Claude ob das mit dem neuen Build geht"]])])
        t.check(has(f.asks, "Klot", "Claude"), "gleicher Text schon früher im Verlauf → die NEUE Nachricht zählt", fmt(f.asks))
        t.check(place(flow(insC, sentEdited.map { $0.replacingOccurrences(of: "Claude", with: "Klot") }, []).anchor) == "schon abgeschickt",
                "Text nur noch im Verlauf (automatisch abgeschickt) → nichts beobachten")
        f = flow(insC, boxStart, [[], [], edited, edited, edited])
        t.check(has(f.asks, "Klot", "Claude") && f.tracker.unreadable == 2, "zwischendurch nicht lesbar (Bedienungshilfen aus) → zählt nicht als „Text weg“",
                "\(fmt(f.asks)) · nicht lesbar \(f.tracker.unreadable)")
        let shellBefore = ["~/code main", "❯ git commit -m \"Wortlerner geht wieder\""].map { pad($0) }
        t.check(place(flow("git commit -m Wortlerner geht wieder", shellBefore, []).anchor) == "Terminal-Zeilen",
                "normale Shell: ganze Terminal-Zeilen (nicht „schon abgeschickt“)", place(flow("git commit -m Wortlerner geht wieder", shellBefore, []).anchor))

        t.section("9) Textfeld (TextEdit/Notizen/Chrome) und Grammatik-Regeln")
        let note = ["Liebe Grüße an alle,", "wir treffen uns morgen bei ID um acht", "am Eingang"]
        let noteFixed = ["Liebe Grüße an alle,", "wir treffen uns morgen bei Lidl um acht", "am Eingang"]
        f = flow("wir treffen uns morgen bei ID um acht", note, [noteFixed, noteFixed, noteFixed], field: true)
        t.check(place(f.anchor) == "Textfeld" && has(f.asks, "ID", "Lidl"), "Textfeld: Wort ersetzt → gefragt", "\(place(f.anchor)) · \(fmt(f.asks))")
        f = flow("sag Mia bitte dass wir bei ID sind", ["sag Mia bitte dass wir bei ID sind"],
                 [["sag Mia bitte dass wir bei Lidl sind"], ["sag Mia bitte dass wir bei Lidl sind"], [""]], field: true)
        t.check(has(f.asks, "ID", "Lidl"), "Chat: korrigiert, stand eine Runde, dann Enter (Feld leer) → gefragt", fmt(f.asks))
        t.check(!CorrectionLearner.shouldLearn(old: "gehe", new: "gehen"), "shouldLearn(gehe → gehen) = nein (nur Endung)")
        t.check(!CorrectionLearner.shouldLearn(old: "den", new: "dem"), "shouldLearn(den → dem) = nein (Artikel)")
        t.check(CorrectionLearner.shouldLearn(old: "Zeilen", new: "Teilen") && CorrectionLearner.shouldLearn(old: "fixen", new: "mixen"),
                "shouldLearn(Zeilen → Teilen, fixen → mixen) = ja (Verhörer)")
        try? FileManager.default.removeItem(at: AliasLearner.url)
        return t.finish("Wort-Lerner")
    }
}

// MARK: - Nur eine Instanz

enum LockSelfTest {
    /// Kindprozess: Sperre versuchen. hold = halten, bis der Prozess beendet wird.
    static func probe(_ path: String, hold: Bool) -> Int32 {
        guard AppLock.acquire(path) else { print("belegt"); return 1 }
        print("frei"); fflush(stdout)
        if hold { while true { sleep(60) } }
        return 0
    }

    static func child(_ args: [String]) -> (code: Int32, out: String, proc: Process?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)", nil) }
        if args.last == "hold" {
            // warten bis „frei“ gemeldet ist (Sperre gehalten)
            let line = pipe.fileHandleForReading.availableLine(timeout: 5)
            return (0, line, p)
        }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    static func run() -> Int32 {
        let t = SelfTestChecks()
        // Nie die Datei löschen: eine gehaltene Sperre hängt am offenen Deskriptor, Löschen würde sie aushebeln
        let path = Paths.base.appendingPathComponent("app.lock").path
        t.check(AppLock.acquire(path), "erste Instanz bekommt die Sperre (\((path as NSString).lastPathComponent))")
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        t.check(mode & 0o077 == 0, "Sperrdatei nur für den eigenen Benutzer", String(format: "%o", mode))
        var c = child(["--selftest-lock-probe", path])
        t.check(c.code == 1 && c.out == "belegt", "zweite Instanz (anderer Prozess) wird abgewiesen", "exit \(c.code) „\(c.out)“")
        AppLock.release()
        c = child(["--selftest-lock-probe", path])
        t.check(c.code == 0 && c.out == "frei", "nach dem Beenden der ersten Instanz wieder frei", "exit \(c.code) „\(c.out)“")
        // Absturz: Kind hält die Sperre, wird mit SIGKILL beendet → Sperre muss frei werden
        let h = child(["--selftest-lock-probe", path, "hold"])
        t.check(h.out == "frei" && h.proc != nil, "Kind hält die Sperre", h.out)
        t.check(!AppLock.acquire(path), "solange das Kind läuft: belegt")
        if let p = h.proc { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        t.check(AppLock.acquire(path), "nach Absturz (SIGKILL) des Halters wieder frei")
        AppLock.release()
        return t.finish("Nur eine Instanz")
    }
}

private extension FileHandle {
    /// Erste Zeile lesen (höchstens `timeout` Sekunden)
    func availableLine(timeout: Double) -> String {
        var buf = Data()
        let t0 = Date()
        let fd = fileDescriptor
        var byte: UInt8 = 0
        while Date().timeIntervalSince(t0) < timeout {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&pfd, 1, 100) > 0 {
                if Darwin.read(fd, &byte, 1) <= 0 { break }
                if byte == 10 { break }
                buf.append(byte)
            }
        }
        return String(data: buf, encoding: .utf8) ?? ""
    }
}

// MARK: - Grüner Punkt (Neu vom Partner) – genau die Regel der Pille

enum SharedNewSelfTest {
    static func run(markAll: Bool) -> Int32 {
        let env = ProcessInfo.processInfo.environment["CLIPVAULT_HOME"] ?? ""
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow-clipvault").standardizedFileURL.path
        guard !env.isEmpty, ClipVaultClient.base.standardizedFileURL.path != real else {
            FileHandle.standardError.write("Abbruch: bitte mit CLIPVAULT_HOME=<Testgerät> starten.\n".data(using: .utf8)!)
            return 3
        }
        let src = CVFileSharedSource()
        src.start()
        let seen = SharedSeenState.load()
        let new = src.items.filter { seen.isNew($0) }
        if markAll {
            var s = seen
            s.seen.append(contentsOf: new.map(\.id))
            s.save()
        }
        let out: [String: Any] = [
            "me": Identity.clipVaultMe,
            "items": src.items.count,
            "new": new.map(\.id),
            "fromPartner": src.items.filter { !$0.fromMe }.map(\.id),
            "marked": markAll ? new.count : 0,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) { print(s) }
        return 0
    }
}
