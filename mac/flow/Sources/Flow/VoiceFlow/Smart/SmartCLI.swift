import AppKit
import SwiftUI

// MARK: - „Flow lernt mit“: Test-Befehle (nie im App-Modus, nie echte Daten)
//
//   FLOW_HOME=/tmp/x Flow --smart-selftest            synthetische Verläufe, Prüfungen + Messung (ms/Diktat)
//   FLOW_HOME=/tmp/x Flow --smart-render <ordner>     Karten, Pille (Punkt + Liste), Seite „Gelernt“ als PNG
//
// Beide verweigern den Start, wenn FLOW_HOME nicht gesetzt ist (das echte ~/.config/flow bleibt unberührt).

enum SmartCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--smart-selftest": return guarded { SmartSelfTest.run() }
        case "--smart-render": return guarded { SmartRender.run(dir: args.count > 2 ? args[2] : "/tmp/smart-render") }
        default: return nil
        }
    }

    private static func guarded(_ body: () -> Int32) -> Int32 {
        let env = ProcessInfo.processInfo.environment["FLOW_HOME"] ?? ""
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow").standardizedFileURL.path
        guard !env.isEmpty, Paths.base.standardizedFileURL.path == URL(fileURLWithPath: env).standardizedFileURL.path,
              Paths.base.standardizedFileURL.path != real else {
            FileHandle.standardError.write("Abbruch: bitte mit FLOW_HOME=<leerer Testordner> starten (Paths.base = \(Paths.base.path)).\n".data(using: .utf8)!)
            return 3
        }
        return body()
    }
}

// MARK: - Synthetische Diktate (erfundener Alltag; eigener Name = Identity.myName, alle anderen Namen erfunden)

enum SmartDemo {
    struct Item {
        let text: String; let bundle: String
        init(text: String, bundle: String) { self.text = text.replacingOccurrences(of: "{ICH}", with: SmartDemo.me); self.bundle = bundle }
    }

    /// Eigener Name (wie in der App: Einstellungen → Vorname des macOS-Kontos)
    static var me: String { Identity.myName }

    static let personal = "net.whatsapp.WhatsApp", mail = "com.apple.mail", slack = "com.tinyspeck.slackmacgap"
    static let claude = "com.anthropic.claudefordesktop", textedit = "com.apple.TextEdit", onepw = "com.1password.1password"

    static let longPrompt = "Fasse dieses Meeting-Transkript in fünf Stichpunkten zusammen, nenne alle Aufgaben mit Namen und Frist, schreibe auf Deutsch und lass Floskeln weg, am Ende bitte eine kurze Liste offener Fragen und wer sie klären soll."

    static let pool: [Item] = [
        Item(text: "Hey Tobi, hast du heute Abend Zeit? Ich wollte mit dir über das Camp reden. Liebe Grüße, {ICH}", bundle: personal),
        Item(text: "Hi Maren, danke dir für die Fotos vom Wochenende, die sind richtig schön geworden! Liebe Grüße, {ICH}", bundle: personal),
        Item(text: "Na, wie läuft's bei dir? Ich melde mich morgen bei dir wegen dem Bus nach Hannover.", bundle: personal),
        Item(text: "Okonkwo hat heute im Livestream gepredigt, das war richtig stark. Hast du das gesehen?", bundle: personal),
        Item(text: "Hey, ich melde mich morgen bei dir wegen dem Bus, bin gerade noch unterwegs. Liebe Grüße, {ICH}", bundle: personal),
        Item(text: "Sehr geehrte Frau Müller, vielen Dank für Ihre Nachricht. Ich sende Ihnen die Unterlagen bis Freitag zu. Mit freundlichen Grüßen {ICH} Mustermann", bundle: mail),
        Item(text: "Sehr geehrter Herr Okonkwo, anbei finden Sie die Planung für die Konferenz in Lissabon. Mit freundlichen Grüßen {ICH} Mustermann", bundle: mail),
        Item(text: "Hallo Herr Weber, können Sie mir bitte die Rechnung noch einmal schicken? Mit freundlichen Grüßen {ICH} Mustermann", bundle: mail),
        Item(text: "Dear Pierre, thank you for the update on the KiTaNet partnership. I will send you the numbers soon. Best regards, {ICH}", bundle: mail),
        Item(text: "Kurzes Update: das Portal für KiTaNet ist live, Pierre Dufresne hat die Zahlen schon geprüft.", bundle: slack),
        Item(text: "Können wir das Timesheet noch fertig machen? Pierre Dufresne braucht es für das Budget.", bundle: slack),
        Item(text: longPrompt, bundle: claude),
        Item(text: "Schreib mir eine Swift Funktion, die ein JSON aus dem Konfigurationsordner lädt und Fehler sauber behandelt.", bundle: claude),
        Item(text: "Notiz: Adebayo Archiv sortieren und die Lumora Lieder für den Herbst auswählen.", bundle: textedit),
        Item(text: "Okonkwo und Benson wollen nächste Woche über das Lumora Projekt sprechen.", bundle: textedit),
    ]

    /// Deterministischer Zufall (gleiche Messung bei jedem Lauf)
    struct RNG { var s: UInt64; mutating func next() -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int(s >> 33) } }

    static func stream(count: Int, seed: UInt64 = 7) -> [Item] {
        var r = RNG(s: seed)
        return (0..<count).map { i in
            var it = pool[r.next() % pool.count]
            if it.text == longPrompt, i % 2 == 0 {
                it = Item(text: longPrompt.replacingOccurrences(of: "fünf", with: "sechs"), bundle: claude)   // leicht abgewandelt
            }
            return it
        }
    }

    static var meetingSummary: String { meetingSummaryTemplate.replacingOccurrences(of: "{ICH}", with: me) }
    static let meetingSummaryTemplate = """
    **Kurzfassung** – Das Camp im Oktober ist mit 64 Anmeldungen fast voll. Tobi und Maren planen den zweiten Bus.

    **Kernpunkte**
    - Zweiter Bus wird gebraucht
    - Anmeldeseite fast fertig

    **Aufgaben**
    - {ICH}: Busangebote einholen und bis Freitag verschicken
    - {ICH}: Bestätigungsmail der Anmeldeseite fertigstellen
      - Text mit Maren abstimmen
    - Maren: Andacht am Samstag klären

    **Offene Fragen**
    1. Reicht das Budget für den zweiten Bus?
    """

    static func meeting() -> Meeting {
        var m = Meeting(id: "smart-test-meeting", title: "Camp-Planung Herbst", date: Date().addingTimeInterval(-1800))
        m.status = .done
        m.speakerNames = ["S1": "Tobi", "S2": "Maren"]
        m.summary = meetingSummary
        m.segments = [Segment(speaker: "S1", start: 0, end: 4, text: "(Transkript wird nie gelesen)")]
        return m
    }
}

// MARK: - Selbsttest

enum SmartSelfTest {
    private static var fails = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1; print("  ✓ \(what)") } else { fails += 1; print("  ✗ \(what)") }
    }

    private static func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Lern-Queue leerlaufen lassen + Veröffentlichung abwarten
    private static func settle(_ flow: SmartFlow) {
        for _ in 0..<3 { flow.queue.sync {}; spin(0.35) }
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("„Flow lernt mit“ – Selbsttest in \(Paths.base.path)")
        let flow = SmartFlow.shared
        flow.cardsSuppressed = true            // nie eine echte Karte auf dem Bildschirm
        flow.isBusy = { false }
        flow.pillIsIdle = { true }
        flow.toast = { print("    (Pille) \($0)") }

        // --- 1) Analyse-Einheiten
        print("1) Analyse")
        let f = SmartAnalyzer.analyze("Hey Tobi, ich hab mit Okonkwo und Pierre Dufresne über KiTaNet gesprochen. Liebe Grüße, \(SmartDemo.me)", myName: SmartDemo.me)
        check(f.signOff?.form == "Liebe Grüße, \(SmartDemo.me)", "Abschied erkannt: \(f.signOff?.form ?? "–")")
        check(f.greeting?.form == "Hey", "Gruß erkannt: \(f.greeting?.form ?? "–")")
        let terms = f.terms.map(\.form)
        check(terms.contains("Okonkwo") && terms.contains("KiTaNet"), "Namen/Begriffe: \(terms.joined(separator: ", "))")
        check(!terms.contains(SmartDemo.me) && !terms.contains("Liebe"), "eigener Name und „Liebe“ sind keine Begriffe")
        let fm = SmartAnalyzer.analyze("Sehr geehrte Frau Müller, vielen Dank für Ihre Nachricht. Können Sie mir das schicken? Mit freundlichen Grüßen \(SmartDemo.me)")
        check(fm.formal > fm.casual, "Register formell (\(fm.formal):\(fm.casual))")
        check(fm.signOff?.key == "mit freundlichen grüßen " + SmartDemo.me.lowercased(), "längste Grußformel gewinnt: \(fm.signOff?.form ?? "–")")
        let fd = SmartAnalyzer.analyze("Lass uns am Freitag um 14 Uhr wegen dem Camp telefonieren.")
        check(fd.dates.count == 1 && fd.dates[0].meetingWord, "Termin erkannt: \(fd.dates.first.map { "\($0.title) · \(SmartLearner.shortDate($0.date))" } ?? "–")")
        check(SmartAnalyzer.analyze("Das mache ich heute noch.").dates.isEmpty, "„heute“ ohne Uhrzeit ist kein Termin")
        let a = SmartAnalyzer.minHash(SmartDemo.longPrompt.lowercased().split(separator: " ").map(String.init))
        let b = SmartAnalyzer.minHash(SmartDemo.longPrompt.replacingOccurrences(of: "fünf", with: "sechs").lowercased().split(separator: " ").map(String.init))
        let c = SmartAnalyzer.minHash("Heute war ein schöner Tag am See mit der ganzen Familie und wir haben viel gelacht und gegessen".lowercased().split(separator: " ").map(String.init))
        check(SmartAnalyzer.similarity(a, b) >= 0.6 && SmartAnalyzer.similarity(a, c) < 0.2,
              String(format: "Fingerabdruck: ähnlich %.2f, fremd %.2f", SmartAnalyzer.similarity(a, b), SmartAnalyzer.similarity(a, c)))
        check(SmartAnalyzer.triggerOptions(for: "Liebe Grüße, \(SmartDemo.me)", existing: [], myName: SmartDemo.me).first == "lg", "Kürzel-Vorschläge: \(SmartAnalyzer.triggerOptions(for: "Liebe Grüße, \(SmartDemo.me)", existing: [], myName: SmartDemo.me))")
        let mf = SmartAnalyzer.analyzeMeeting(title: "Camp-Planung Herbst", summary: SmartDemo.meetingSummary, speakerNames: ["Tobi", "Maren"], myName: SmartDemo.me)
        check(mf.tasks.count == 3 && mf.myTasks.count == 2, "Meeting-Aufgaben: \(mf.tasks.count), davon meine: \(mf.myTasks.count)")
        check(mf.myTasks.first?.due != nil, "Fälligkeit „bis Freitag“ erkannt")
        check(mf.people.contains("Tobi") && mf.people.contains("Maren"), "Personen: \(mf.people.joined(separator: ", "))")
        check(!mf.topics.isEmpty, "Themen: \(mf.topics.joined(separator: ", "))")

        // --- 2) Verlauf der letzten 3 Tage vorbereiten (wird beim Start nachgelernt)
        print("2) Nachlernen aus verlauf.json")
        StyleStore.shared.set(.casual, for: .email)      // damit „Mail formell“ vorgeschlagen werden kann
        var recs: [DictationRecord] = []
        let hist = SmartDemo.stream(count: 150, seed: 3)
        for (i, it) in hist.enumerated() {
            let d = Date().addingTimeInterval(-Double(150 - i) * 1500)   // ~2,6 Tage
            recs.append(DictationRecord(date: d, text: it.text, app: "Test", bundleID: it.bundle, duration: 5))
        }
        recs.append(DictationRecord(date: Date().addingTimeInterval(-600), text: "Mein Hund Bello frisst gern Karotten im Garten hinter dem Schuppen.", app: "WhatsApp", bundleID: SmartDemo.personal, duration: 4))
        recs.append(DictationRecord(date: Date().addingTimeInterval(-500), text: "supergeheimes Passwort Zebra Mondlicht", app: "1Password", bundleID: SmartDemo.onepw, duration: 2))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(recs.sorted { $0.date > $1.date }).write(to: Paths.base.appendingPathComponent("verlauf.json"))
        let tBack = CFAbsoluteTimeGetCurrent()
        flow.start()
        settle(flow)
        let backMs = (CFAbsoluteTimeGetCurrent() - tBack) * 1000
        check(flow.snapshot.dictations == 151, "nachgelernt: \(flow.snapshot.dictations) Diktate (Passwort-App übersprungen) in \(Int(backMs)) ms")

        // --- 3) Live-Diktate + Messung
        print("3) 400 neue Diktate (Messung auf der Lern-Queue)")
        flow.resetPerf()
        let ctx = flow.makeContext()
        var mainCtx: [Double] = []
        for _ in 0..<200 { let t = CFAbsoluteTimeGetCurrent(); _ = flow.makeContext(); mainCtx.append((CFAbsoluteTimeGetCurrent() - t) * 1000) }
        for it in SmartDemo.stream(count: 400, seed: 11) {
            _ = flow.processForTest(text: it.text, bundleID: it.bundle, date: Date(), ctx: ctx)
        }
        _ = flow.processForTest(text: "Lass uns am Freitag um 14 Uhr wegen dem Camp telefonieren.", bundleID: SmartDemo.personal, date: Date(), ctx: ctx)
        settle(flow)
        let perf = flow.perfStats
        print("  " + perf.summary)
        print(String(format: "  Main-Thread je Diktat (Stores einsammeln): Ø %.3f ms", mainCtx.reduce(0, +) / Double(mainCtx.count)))
        check(perf.avg <= 20, String(format: "Ø %.2f ms ≤ 20 ms", perf.avg))
        // echte Pipeline-Eingangstür einmal durchlaufen (Main → Queue)
        flow.ingestDictation(text: "Test über die normale Tür, Okonkwo.", bundleID: SmartDemo.textedit)
        flow.ingestDictation(text: "supergeheim", bundleID: SmartDemo.onepw)
        settle(flow)

        // --- 4) Vorschläge
        print("4) Vorschläge")
        let pend = flow.visiblePending
        for s in pend { print(String(format: "    · %@ %.0f %% – %@ | %@", s.kind.rawValue, s.confidence * 100, s.title, s.text)) }
        let okonkwo = pend.first { $0.kind == .dictionary && $0.payload.term == "Okonkwo" }
        check(okonkwo != nil, "„Okonkwo“ fürs Wörterbuch vorgeschlagen")
        check(!pend.contains { $0.payload.term == "Hannover" }, "bekannte Wörter (Hannover) nicht vorgeschlagen")
        let lg = pend.first { $0.kind == .snippet && $0.payload.text == "Liebe Grüße, \(SmartDemo.me)" }
        check(lg != nil && lg?.payload.triggerOptions?.first == "lg", "Snippet „Liebe Grüße, \(SmartDemo.me)“ mit Kürzel \(lg?.payload.triggerOptions ?? [])")
        check(pend.contains { $0.kind == .style && $0.payload.category == "email" && $0.payload.style == "formal" }, "Stil: Mail → Formell")
        let tf = pend.first { $0.kind == .transform }
        check(tf != nil, "wiederholter Prompt → Transform")
        check(pend.contains { $0.kind == .calendar }, "Termin → Kalender")
        if let tf { check(tf.expires <= Date().addingTimeInterval(Double(Settings.shared.retentionDays) * 86400 + 60), "Vorschlag mit Text verfällt mit der Löschfrist") }

        // Meeting
        flow.ingestMeeting(SmartDemo.meeting())
        settle(flow)
        let rem = flow.visiblePending.first { $0.kind == .reminders }
        check(rem?.payload.tasks?.count == 2, "Meeting: \(rem?.title ?? "keine Aufgaben") – \(rem?.text ?? "")")
        check(flow.snapshot.meetingPeople["tobi"] != nil && !flow.snapshot.meetingTopics.isEmpty, "Meeting: Personen & Themen gelernt")

        // --- 5) Regeln fürs Zeigen
        print("5) Karten-Regeln")
        flow.setLastDictationForTest(Date())
        check(flow.cardBlocker() == "gerade diktiert", "keine Karte direkt nach einem Diktat")
        flow.setLastDictationForTest(Date().addingTimeInterval(-60))
        flow.isBusy = { true }
        check(flow.cardBlocker() == "Diktat/Meeting läuft", "keine Karte während Diktat/Meeting")
        flow.isBusy = { false }; flow.pillIsIdle = { false }
        check(flow.cardBlocker() == "Pille beschäftigt", "keine Karte, solange die Pille beschäftigt ist")
        flow.pillIsIdle = { true }
        flow.cardsSuppressed = false
        let blocker = flow.cardBlocker()
        check(blocker == nil || blocker == "Vollbild", "sonst frei (\(blocker ?? "frei"))")
        let first = flow.nextCardCandidate()
        check(first != nil, "beste Karte: \(first.map { "\($0.kind.rawValue) \(Int($0.confidence * 100)) %" } ?? "–")")
        if let first { flow.markShown(first) }
        check(flow.cardBlocker() == "30-Minuten-Pause" || flow.cardBlocker() == "Vollbild", "danach 30 Minuten Ruhe")
        check(flow.nextCardCandidate()?.id != first?.id, "gezeigte Karte kommt nicht erneut (bleibt in der Liste)")
        flow.cardsSuppressed = true
        settle(flow)

        // --- 6) Annehmen über die vorhandenen Stores
        print("6) Annehmen")
        var gotTasks: [SmartTask] = []
        var gotEvent: (String, Date)?
        flow.actions.addReminders = { tasks, _, done in gotTasks = tasks; done(.success(tasks.count)) }
        flow.actions.addEvent = { title, date, done in gotEvent = (title, date); done(.success(())) }
        if let k = okonkwo { flow.accept(k.id) }
        if let lg { flow.accept(lg.id, choice: "lg") }
        if let st = flow.visiblePending.first(where: { $0.kind == .style }) { flow.accept(st.id) }
        if let tf { flow.accept(tf.id) }
        if let rem { flow.accept(rem.id) }
        if let cal = flow.visiblePending.first(where: { $0.kind == .calendar }) { flow.accept(cal.id) }
        settle(flow)
        check(Settings.shared.dictionary.contains { $0.write == "Okonkwo" && $0.vocabOnly == true && $0.learned == true }, "Wörterbuch: Okonkwo (nur Hinweis)")
        check(SnippetStore.shared.snippets.contains { $0.trigger == "lg" && $0.text == "Liebe Grüße, \(SmartDemo.me)" }, "Snippet „lg“ gespeichert")
        check(StyleStore.shared.style(for: .email) == .formal, "Stil E-Mail = Formell")
        check(TransformStore.shared.presets.contains { $0.instruction.hasPrefix("Fasse dieses Meeting") }, "Transform gespeichert")
        check(gotTasks.count == 2, "Erinnerungen übergeben: \(gotTasks.map(\.title))")
        check(gotEvent != nil, "Termin übergeben: \(gotEvent.map { "\($0.0) \(SmartLearner.shortDate($0.1))" } ?? "–")")
        check(!flow.visiblePending.contains { $0.key == okonkwo?.key }, "angenommene Vorschläge verschwinden")
        check(flow.prefs.stat(.dictionary).accepted == 1, "Zähler „angenommen“")

        // --- 7) „Nein“ lernt
        print("7) Nein lernt")
        for (o, n) in [("ID", "Lidl"), ("Lumoraa", "Lumora"), ("Adebajo", "Adebayo")] {
            flow.noteCorrection(old: o, new: n, saved: false)
            flow.noteCorrection(old: o, new: n, saved: false)          // Zwischenstand – zählt nicht doppelt
            flow.noteCorrection(old: o, new: n, saved: false, dedupe: false)   // „später“ noch einmal
        }
        settle(flow)
        let corr = flow.visiblePending.filter { $0.key.hasPrefix("corr:") }
        check(corr.count >= 2, "\(corr.count) Korrektur-Vorschläge (2× korrigiert → leise in der Liste; höchstens 5 Wörterbuch-Vorschläge offen)")
        check(flow.visiblePending.filter { $0.kind == .dictionary }.count <= SmartPolicy.maxPendingPerKind(.dictionary), "Obergrenze je Art eingehalten")
        check(corr.allSatisfy { $0.confidence < SmartKind.dictionary.cardThreshold }, "2× reicht nicht für eine Karte")
        let toDismiss = corr + flow.visiblePending.filter { $0.kind == .dictionary && !$0.key.hasPrefix("corr:") }
        for s in toDismiss.prefix(3) { flow.dismiss(s.id) }
        settle(flow)
        check(flow.prefs.stat(.dictionary).stopped, "nach 3× Nein gestoppt")
        check(!flow.visiblePending.contains { $0.kind == .dictionary }, "keine Wörterbuch-Vorschläge mehr sichtbar")
        flow.setKind(.dictionary, on: true)
        check(!flow.prefs.stat(.dictionary).stopped, "Einschalten auf der Seite hebt den Stopp auf")

        // --- 8) Datenschutz & Löschfrist
        print("8) Datenschutz")
        flow.flush()
        let url = SmartFlow.wissenURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        check((attrs?[.posixPermissions] as? Int) == 0o600, "wissen.json hat Rechte 0600")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        print("    wissen.json: \(raw.utf8.count / 1024) KB")
        check(!raw.contains("Karotten") && !raw.contains("Schuppen"), "einmaliger Satz steht NICHT in wissen.json")
        check(!raw.lowercased().contains("supergeheim") && !raw.contains("Zebra"), "nichts aus der Passwort-App gelernt")
        let payload = SmartDigest.payload(flow.snapshot, prefs: flow.prefs, styles: StyleStore.shared.styles)
        check(!payload.contains("Karotten") && !payload.contains("Fasse dieses"), "Claude-Überblick enthält keine Diktate")
        check(flow.prefs.nightlyDigest == false, "Claude-Überblick standardmäßig AUS")
        var future = flow.snapshot
        let before = (future.seeds.count, future.terms.values.filter { $0.n <= 1 }.count)
        SmartLearner.prune(&future, ctx: flow.makeContext(), now: Date().addingTimeInterval(4 * 86400))
        check(future.seeds.isEmpty && !future.terms.values.contains { $0.n <= 1 && $0.fromMeetings == 0 },
              "nach der Löschfrist: \(before.0) Prüfsummen + \(before.1) Einzelbegriffe weg")
        check(future.phrases.values.contains { $0.values.contains { $0.n >= 3 } }, "wiederkehrende Formulierungen bleiben")
        check(!(future.pending.contains { $0.kind == .transform }), "Vorschläge mit Text verfallen")

        // --- 9) Alles vergessen
        print("9) Alles vergessen")
        flow.forgetAll()
        settle(flow)
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(flow.snapshot.dictations == 0 && flow.visiblePending.isEmpty && !after.contains("Okonkwo"), "wissen.json geleert, keine Vorschläge")
        check(flow.prefs.stat(.dictionary).accepted == 1, "Einstellungen/Entscheidungen bleiben (lernen.json)")

        print("\n\(passes) bestanden, \(fails) fehlgeschlagen")
        return fails == 0 ? 0 : 1
    }
}

// MARK: - Offscreen-Bilder

enum SmartRender {
    static func run(dir: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let flow = SmartFlow.shared
        flow.cardsSuppressed = true

        // Demo-Wissen rein im Speicher (nichts wird gespeichert)
        var w = SmartWissen()
        w.createdAt = Date().addingTimeInterval(-9 * 86400)
        let ctx = flow.makeContext()
        var r = SmartDemo.RNG(s: 5)
        var pending: [SmartSuggestion] = []
        for (i, it) in SmartDemo.stream(count: 260, seed: 5).enumerated() {
            let d = Date().addingTimeInterval(-Double(260 - i) * 2900 - Double(r.next() % 1800))
            let cat = AppCategory.of(bundleID: it.bundle)
            let f = SmartAnalyzer.analyze(it.text, myName: ctx.myName, known: ctx.known, category: cat)
            var t = SmartLearner.merge(f, text: it.text, date: d, category: cat, into: &w, ctx: ctx)
            t.dates = []
            for word in t.needSpell where w.terms[word.lowercased()]?.spellKnown == nil { w.terms[word.lowercased()]?.spellKnown = SmartPrivacy.spellKnown(word) }
            _ = SmartLearner.candidates(t, w: w, ctx: ctx)
        }
        let mf = SmartAnalyzer.analyzeMeeting(title: "Camp-Planung Herbst", summary: SmartDemo.meetingSummary, speakerNames: ["Tobi", "Maren"], myName: SmartDemo.me)
        SmartLearner.mergeMeeting(id: "demo", title: "Camp-Planung Herbst", date: Date().addingTimeInterval(-3 * 3600), features: mf, into: &w)
        _ = SmartLearner.noteCorrection(old: "ID", new: "Lidl", saved: true, date: Date(), into: &w)
        _ = SmartLearner.noteCorrection(old: "Lumoraa", new: "Lumora", saved: false, date: Date(), into: &w)
        _ = SmartLearner.noteCorrection(old: "Lumoraa", new: "Lumora", saved: false, date: Date().addingTimeInterval(700), into: &w)
        let exp = Date().addingTimeInterval(3 * 86400)
        if let t = w.terms["okonkwo"] { var tt = t; tt.spellKnown = false; if let s = SmartLearner.dictionarySuggestion(tt, ctx: ctx, expires: exp) { pending.append(s) } }
        pending.append(SmartSuggestion(kind: .snippet, key: "snip:lg", title: "Als Snippet speichern?",
                                       text: "Du schreibst oft „Liebe Grüße, \(SmartDemo.me)“. Mit welchem Kürzel abrufen?", confidence: 0.86, expires: exp,
                                       payload: SmartPayload(trigger: "lg", triggerOptions: ["lg", "Liebe", "Liebe Grüße"], text: "Liebe Grüße, \(SmartDemo.me)")))
        if let s = SmartLearner.meetingSuggestion(id: "demo", title: "Camp-Planung Herbst", date: Date().addingTimeInterval(-3 * 3600), tasks: mf.myTasks) { pending.append(s) }
        pending.append(SmartSuggestion(kind: .calendar, key: "cal:demo", title: "Termin eintragen?",
                                       text: "„Wegen dem Camp telefonieren“ am \(SmartLearner.shortDate(Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date().addingTimeInterval(6 * 86400))!)) in den Kalender eintragen?",
                                       confidence: 0.78, expires: exp, payload: SmartPayload(date: Date().addingTimeInterval(6 * 86400), eventTitle: "Wegen dem Camp telefonieren")))
        pending.append(SmartSuggestion(kind: .style, key: "style:email:formal", title: "Stil für E-Mail",
                                       text: "In Mails schreibst du meist formell (9 von 10). Auf „Formell“ stellen?", confidence: 0.84, expires: exp,
                                       payload: SmartPayload(category: "email", style: "formal")))
        pending.append(SmartSuggestion(kind: .transform, key: "rep:demo", title: "Als Transform speichern?",
                                       text: "Diese Anweisung diktierst du öfter (3×). Künftig mit einem Wort abrufen?", confidence: 0.85, expires: exp,
                                       payload: SmartPayload(trigger: "Fasse dieses Meeting-Transkript", text: SmartDemo.longPrompt)))
        w.pending = pending
        w.digest = SmartDigestNote(date: Date().addingTimeInterval(-14 * 3600), text: "- Du diktierst 3× mehr in Claude als in Mail – leg deine Standard-Prompts als Transforms an.\n- „Liebe Grüße, \(SmartDemo.me)“ kam 31× vor: ein Snippet spart dir jeden Tag Sekunden.\n- Nach Meetings übernimmst du Aufgaben selten – probier die Erinnerungen aus.")
        var prefs = SmartPrefs()
        prefs.stats[SmartKind.dictionary.rawValue] = SmartKindStat(shown: 4, accepted: 3, dismissed: 1)
        prefs.stats[SmartKind.style.rawValue] = SmartKindStat(shown: 3, accepted: 0, dismissed: 3)
        prefs.stats[SmartKind.snippet.rawValue] = SmartKindStat(shown: 2, accepted: 2, dismissed: 0)
        flow.replaceForPreview(w, prefs: prefs)
        var shownPrefs = prefs; shownPrefs.stats[SmartKind.style.rawValue] = SmartKindStat()
        flow.replaceForPreview(w, prefs: shownPrefs)
        let visible = flow.visiblePending
        flow.replaceForPreview(w, prefs: prefs)

        // 1) Karten aus der Pille
        let scr = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let pill = NSRect(x: 734, y: 30, width: 44, height: 9)
        for s in pending {
            let u = out.appendingPathComponent("karte_\(s.kind.rawValue).png")
            print(VFNotify.renderPNG(SmartFlow.notice(for: s), to: u, progress: 1, pill: pill, screen: scr) ? u.path : "✗ \(s.kind)")
        }
        // 2) Pille: nur Punkt / Liste beim Darüberfahren
        let dotURL = out.appendingPathComponent("pille_punkt.png")
        SmartPillBadge.renderPNG(items: [], to: dotURL, hoveredPill: false); print(dotURL.path)
        let listURL = out.appendingPathComponent("pille_liste.png")
        SmartPillBadge.renderPNG(items: visible, to: listURL, hoveredPill: true); print(listURL.path)

        // 3) Seite „Gelernt“ (lang) + leer + im Hub
        render(SmartLearnedPage(), size: NSSize(width: 1180, height: 3300), to: out.appendingPathComponent("gelernt_seite.png"))
        if let sec = VFSection(rawValue: "gelernt") {
            Settings.shared.onboardingDone = true      // nur im Test-Ordner (FLOW_HOME)
            AppDelegate.registerHubPages()
            VFStats.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("vf-statistik-render.json")
            VFHub.shared.section = sec
            render(VFHubView(), size: NSSize(width: 1512, height: 949), to: out.appendingPathComponent("gelernt_im_hub.png"))
        }
        render(VStack(spacing: 20) { SmartInsightsCard(); SmartSettingsRows().padding(.horizontal, 26).background(RoundedRectangle(cornerRadius: 14).fill(VF.cardSoft)) }
                .padding(30).frame(width: 960).background(VF.panel),
               size: NSSize(width: 960, height: 420), to: out.appendingPathComponent("insights_karte_und_einstellung.png"))
        flow.replaceForPreview(SmartWissen(), prefs: SmartPrefs())
        render(SmartLearnedPage(), size: NSSize(width: 1180, height: 1500), to: out.appendingPathComponent("gelernt_leer.png"))
        return 0
    }

    private static func render<V: View>(_ v: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: v.environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
        win.close()
    }
}
