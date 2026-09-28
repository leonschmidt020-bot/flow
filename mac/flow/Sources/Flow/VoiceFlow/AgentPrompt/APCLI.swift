import AppKit
import SwiftUI

// MARK: - Agent-Prompt: Test-Befehle ohne Oberfläche
//
//   FLOW_HOME=<leer> Flow --selftest-agent-prompt [-v]   Auslöser (+ Verhörer), Erkennung (≥40 Fälle), Regel-Rückfall,
//                                                           Builder mit Schein-Claude (Zeitlimit, Fehler, Abbruch), Verlauf
//                                                           (atomar, kaputte Dateien), Ablauf (Original zuerst gesichert,
//                                                           Abbrechen/Fehler → Original einfügen/kopieren). Kein Claude, keine Zwischenablage.
//   FLOW_HOME=<leer> Flow --agent-prompt-render <ordner>  alle Karten-Zustände + Hub-Ansicht als PNG
//   Flow --agent-prompt-detect "Text" [Sekunden] [Bundle-ID] [Fenstertitel]   Punktzahl + Gründe
//   FLOW_HOME=<leer> Flow --agent-prompt-build <text|@datei> [--rules] [--model sonnet] [--effort low]
//                                                           ECHTER Claude-Aufruf (Qualität/Zeit prüfen), druckt Prompt + Zeiten

enum APCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        let a2 = args.count > 2 ? args[2] : ""
        switch args[1] {
        case "--selftest-agent-prompt": return SelfTestCLI.guardedHome { APSelfTest.run(verbose: args.contains("-v")) }
        case "--agent-prompt-render": return SelfTestCLI.guardedHome { render(dir: a2.isEmpty ? "/tmp/agent-prompt-render" : a2) }
        case "--agent-prompt-detect":
            let d = APDetector.detect(text: a2, duration: args.count > 3 ? Double(args[3]) ?? 0 : 0,
                                      bundleID: args.count > 4 ? args[4] : "", title: args.count > 5 ? args[5] : "")
            print("\(d.offer ? "VORSCHLAG" : "nein") · Punkte \(d.score) · " + d.reasons.joined(separator: " · "))
            if let m = APTrigger.match(a2) { print("Auslöser „\(m.phrase)“ → „\(m.body)“") }
            return 0
        case "--agent-prompt-build": return SelfTestCLI.guardedHome { build(args) }
        default: return nil
        }
    }

    private static func spin(_ seconds: Double = 120, until: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Echter Lauf

    private static func build(_ args: [String]) -> Int32 {
        var text = args.count > 2 ? args[2] : ""
        if text.hasPrefix("@") { text = (try? String(contentsOfFile: String(text.dropFirst()), encoding: .utf8)) ?? "" }
        guard !text.isEmpty else { print("Text fehlt"); return 2 }
        let b = APBuilder()
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { b.model = args[i + 1] }
        if let i = args.firstIndex(of: "--effort"), i + 1 < args.count { b.effort = args[i + 1] }
        if args.contains("--rules") { b.available = { false } }
        var first: Date?
        let t0 = Date()
        var out: APOutcome?
        Task {
            out = await b.build(APRequest(transcript: text)) { p in if first == nil, !p.isEmpty { first = Date() } }
        }
        spin(90) { out != nil }
        let total = Date().timeIntervalSince(t0)
        switch out {
        case .ok(let r)?:
            print(r.prompt)
            print("\n— \(r.source)\(r.note.isEmpty ? "" : " (\(r.note))") · erstes Wort nach \(first.map { String(format: "%.1f s", $0.timeIntervalSince(t0)) } ?? "–") · fertig nach \(String(format: "%.1f s", total))"
                  + " · \(APText.words(text)) → \(APText.words(r.prompt)) Wörter" + (r.missing.isEmpty ? "" : " · fehlt wörtlich: \(r.missing.joined(separator: ", "))"))
            print("Kurzzeile: \(APGist.of(r.prompt).line)")
            return 0
        case .failed(let why)?: print("FEHLGESCHLAGEN: \(why)"); return 1
        case .cancelled?: print("abgebrochen"); return 1
        case nil: print("Zeitlimit"); return 1
        }
    }

    // MARK: Bilder

    static let samplePromptDE = """
    **Ziel:** Die Settings Page im Dashboard schneller machen, indem statt aller User nur die ersten 50 geladen und per Infinite Scroll nachgeladen werden.

    ## Kontext
    - Fenster: SettingsPanel.tsx — admin-dashboard (Visual Studio Code)
    - Die Seite braucht beim Öffnen ca. 3 Sekunden; der `useEffect` in `SettingsPanel.tsx` lädt alle ca. 12.000 User auf einmal.

    ## Aufgabe
    1. Baue das Laden in `SettingsPanel.tsx` so um, dass zunächst nur die ersten 50 User geladen werden.
    2. Implementiere Infinite Scroll zum Nachladen (keine klassische Pagination).
    3. Prüfe, ob `/api/users` einen `limit`-Parameter unterstützt.
    4. Falls nicht: ergänze ihn im Backend in `users.controller.ts`.
    5. Führe `npm run test` aus.

    ## Akzeptanzkriterien
    - Beim Öffnen werden nur 50 User geladen, weitere beim Scrollen.
    - `/api/users` akzeptiert `limit`.
    - `npm run test` ist komplett grün.

    ## Regeln
    - Keine neuen Dependencies (kein react-query).
    - Styling nicht anfassen (hat Lisa gerade gemacht).

    ## Offene Punkte
    - Soll der Suchfilter auch serverseitig laufen?
    """

    static let samplePromptEN = """
    **Goal:** Add retry logic to the upload client.

    ## Task
    1. Retry failed uploads up to 3 times with exponential backoff.
    2. Keep the public API of `UploadClient` unchanged.

    ## Acceptance criteria
    - A failing upload is retried 3 times, then reported.
    - All tests pass.
    """

    static let sampleOriginalDE = "Okay also es geht um die Settings Page in unserem Dashboard, die ist gerade echt langsam, wenn man die öffnet dauert das so drei Sekunden bis überhaupt was kommt. Ich glaube das liegt an dem useEffect in der SettingsPanel.tsx, der lädt irgendwie alle User auf einmal, das sind so zwölftausend Einträge. Bau das bitte so um, dass nur die ersten fünfzig geladen werden und dann Pagination, nein warte, lieber Infinite Scroll. Und prüf auch mal ob der API Endpoint slash api slash users überhaupt einen limit Parameter hat. Keine neuen Dependencies und fass das Styling nicht an, das hat Lisa gerade gemacht."

    private static func render(dir: String) -> Int32 {
        _ = NSApplication.shared
        let d = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let now = Date()
        // Bilder unabhängig davon, ob auf diesem Mac eine Claude-CLI liegt
        let realClaude = APCardStyle.claudeAvailable
        APCardStyle.claudeAvailable = { true }
        defer { APCardStyle.claudeAvailable = realClaude }
        func rec(_ p: String, _ o: String, source: String = "claude/sonnet/low", note: String = "", ms: Int = 11_400) -> APRecord {
            APRecord(id: UUID().uuidString, created: now, prompt: p, original: o, appName: "Visual Studio Code", windowTitle: "", source: source, note: note, buildMs: ms)
        }
        let det = APDetector.detect(text: APTestSet.longDE1, duration: 42, bundleID: APTestSet.vsc, title: "SettingsPanel.tsx — admin-dashboard")
        let partial = String(samplePromptDE.prefix(420))
        let long = rec(samplePromptDE, sampleOriginalDE)
        let rules = rec(APRules.structure(APTestSet.fallbackDE), APTestSet.fallbackDE, source: "regeln", note: "Zeitlimit (45 s)", ms: 45_100)
        let en = rec(samplePromptEN, "Agent prompt: add retry logic to the upload client, three attempts with backoff, keep the API the same and make sure tests pass.", ms: 7_900)
        typealias Shot = (String, APCardPhase, CGFloat, Bool, Bool, NSRect?, String?)
        let pillBottom = NSRect(x: 560, y: 30, width: 66, height: 24)
        let pillRightEdge = NSRect(x: 1488, y: 440, width: 9, height: 44)
        let pillLeftEdge = NSRect(x: 15, y: 440, width: 9, height: 44)
        let shots: [Shot] = [
            ("1_vorschlag", .offer(det), 1, false, false, nil, nil),
            ("2a_baut_start", .building(partial: "", words: 118, started: now.addingTimeInterval(-2)), 1, false, false, nil, nil),
            ("2b_baut_live", .building(partial: partial, words: 118, started: now.addingTimeInterval(-6)), 1, false, false, nil, nil),
            ("2c_morph_halb", .building(partial: "", words: 118, started: now), 0.5, false, false, nil, nil),
            ("3a_fertig", .done(long), 1, false, false, nil, "illu_prompt_fertig"),
            ("3b_fertig_hover", .done(long), 1, true, false, nil, "illu_prompt_fertig_2"),
            ("3c_fertig_original", .done(long), 1, false, true, nil, "illu_prompt_fertig_3"),
            ("3d_fertig_kurz_en", .done(en), 1, false, false, nil, "illu_prompt_fertig_4"),
            ("3e_fertig_regeln", .done(rules), 1, false, false, nil, nil),
            ("4a_abgebrochen", .stopped(.cancelled, reason: "Abgebrochen", original: sampleOriginalDE), 1, false, false, nil, nil),
            ("4b_fehlgeschlagen", .stopped(.failed, reason: "Claude nicht erreichbar", original: sampleOriginalDE), 1, false, false, nil, nil),
            ("5a_pille_rechts_hochkant", .done(long), 1, false, false, pillRightEdge, nil),
            ("5b_pille_links_hochkant", .building(partial: partial, words: 118, started: now), 1, false, false, pillLeftEdge, nil),
        ]
        var ok = 0
        for (name, phase, prog, hover, orig, pill, illu) in shots {
            let u = d.appendingPathComponent("\(name).png")
            if APCard.renderPNG(phase, to: u, progress: prog, hovering: hover, showOriginal: orig, pill: pill ?? pillBottom, illustration: illu) { ok += 1 }
        }
        // Ohne Claude-CLI: „nach Regeln“ beim Bauen, leiser Hinweis „ohne Claude-CLI“ an der fertigen Karte
        APCardStyle.claudeAvailable = { false }
        let noClaude = rec(APRules.structure(APTestSet.fallbackDE), APTestSet.fallbackDE, source: "regeln", note: "Claude-CLI fehlt", ms: 40)
        let extra: [(String, APCardPhase)] = [
            ("7a_ohne_claude_baut", .building(partial: "", words: 74, started: now)),
            ("7b_ohne_claude_fertig", .done(noClaude)),
        ]
        for (name, phase) in extra where APCard.renderPNG(phase, to: d.appendingPathComponent("\(name).png"), pill: pillBottom) { ok += 1 }
        APCardStyle.claudeAvailable = { true }
        // Hub: Scratchpad › Agent-Prompts (eigener Test-Speicher)
        let hubDir = d.appendingPathComponent("hub-store")
        let store = APStore(dir: hubDir, load: false)
        store.add(rules); store.add(en); store.add(long)
        let pane = APPromptsPane(store: store).frame(width: 1060, height: 560).background(VF.card).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: pane)
        host.frame = NSRect(x: 0, y: 0, width: 1060, height: 560)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: d.appendingPathComponent("6_hub_prompts.png"))) != nil { ok += 1 }
        }
        try? FileManager.default.removeItem(at: hubDir)
        let total = shots.count + extra.count + 1
        print("\(ok)/\(total) Bilder nach \(dir)")
        return ok == total ? 0 : 1
    }
}

// MARK: - Selbsttest

/// Schein-Karte: merkt sich, was gezeigt wurde
final class APFakePresenter: APPresenter {
    var shown: [APCardPhase] = []
    var closed = 0
    var flashes: [APCardFlash] = []
    var onAction: (APCardAction) -> Void = { _ in }
    private(set) var isShowing = false
    func show(_ phase: APCardPhase) { shown.append(phase); isShowing = true }
    func close() { closed += 1; isShowing = false }
    func flash(_ what: APCardFlash) { flashes.append(what) }
    var last: APCardPhase? { shown.last }
}

enum APSelfTest {
    static func run(verbose: Bool) -> Int32 {
        _ = NSApplication.shared
        let t = SelfTestChecks()
        triggers(t, verbose: verbose)
        detection(t, verbose: verbose)
        rules(t, verbose: verbose)
        builder(t)
        store(t)
        flow(t)
        withoutClaude(t)
        return t.finish("Agent-Prompt")
    }

    private static func spin(_ s: Double = 10, until: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // Auslöser
    static func triggers(_ t: SelfTestChecks, verbose: Bool) {
        t.section("Auslöser (\(APTestSet.triggers.count) Sätze, inkl. Verhörer)")
        for (s, want) in APTestSet.triggers {
            let m = APTrigger.match(s)
            if let want {
                t.check(m?.body.hasPrefix(want) == true, "Auslöser: „\(VCText.short(s, 60))“", "bekommen: \(m.map { "„\($0.body)“ (\($0.phrase))" } ?? "nichts")")
            } else {
                t.check(m == nil, "kein Auslöser: „\(VCText.short(s, 60))“", "fälschlich: \(m?.phrase ?? "")")
            }
        }
    }

    // Automatische Erkennung
    static func detection(_ t: SelfTestChecks, verbose: Bool) {
        let set = APTestSet.detection
        t.section("Erkennung (\(set.count) Fälle, \(set.filter(\.offer).count) positiv)")
        var tp = 0, fp = 0, fn = 0
        for c in set {
            let d = APDetector.detect(text: c.text, duration: c.seconds, bundleID: c.bundle, title: c.title)
            if d.offer && c.offer { tp += 1 } else if d.offer { fp += 1 } else if c.offer { fn += 1 }
            t.check(d.offer == c.offer, "Erkennung \(c.offer ? "JA  " : "nein") \(c.note)", "Punkte \(d.score): \(d.reasons.joined(separator: " · "))")
            if verbose { print("          Punkte \(d.score) · \(d.reasons.joined(separator: " · "))") }
        }
        print("          Erkennung: \(tp) richtig erkannt, \(fp) falsch angeboten, \(fn) verpasst")
        t.check(set.count >= 40, "mindestens 40 Fälle", "\(set.count)")
        // Explizite Auslöser gewinnen nie gegen die Erkennung: ein „Prompt: …“ wird vorher abgefangen
        let d = APDetector.detect(text: "", duration: 0, bundleID: APTestSet.term)
        t.check(!d.offer, "leeres Diktat: nie Vorschlag")
    }

    // Regel-Rückfall
    static func rules(_ t: SelfTestChecks, verbose: Bool) {
        t.section("Regel-Rückfall (ohne Claude)")
        let p = APRules.structure(APTestSet.fallbackDE, context: APContext(appName: "Visual Studio Code", bundleID: APTestSet.vsc, windowTitle: "SettingsPanel.tsx — admin-dashboard"))
        if verbose { print(p) }
        for must in ["100", "/api/users", "users.controller.ts", "npm run test", "Lisa", "Dependencies", "Settings Page", "drei Sekunden", "limit"] {
            t.check(p.contains(must), "Rückfall behält „\(must)“", p)
        }
        t.check(p.contains("korrigiert: die ersten 100") && p.contains("User geladen werden"), "Selbstkorrektur sichtbar, ohne Details zu verlieren (50 → 100)", p)
        t.check(APRules.clean("Ruf bitte am Donnerstag an, nein warte, am Freitag.") == "Ruf bitte am Freitag an.", "eindeutige Selbstkorrektur wird aufgelöst",
                APRules.clean("Ruf bitte am Donnerstag an, nein warte, am Freitag."))
        t.check(p.contains("**Ziel:**") && p.contains("## Aufgabe") && p.contains("## Akzeptanzkriterien"), "Aufbau Ziel/Aufgabe/Akzeptanz")
        t.check(p.contains("## Regeln") && p.range(of: "Keine neuen Dependencies") != nil, "Verbot unter „Regeln“")
        t.check(p.contains("## Offene Punkte") && p.contains("Suchfilter"), "Unsicherheit unter „Offene Punkte“")
        t.check(p.contains("## Kontext") && p.contains("admin-dashboard"), "Fenstertitel als Kontext (Entwickler-App)")
        t.check(!p.lowercased().contains("ich mache jetzt mal"), "Vorrede entfernt")
        let pm = APRules.structure(APTestSet.fallbackDE, context: APContext(appName: "Mail", bundleID: APTestSet.mail, windowTitle: "Re: Gehalt"))
        t.check(!pm.contains("Gehalt"), "Mail-Betreff nie als Kontext")
        let e = APRules.structure(APTestSet.fallbackEN)
        if verbose { print(e) }
        t.check(e.contains("**Goal:**") && e.contains("## Task") && e.contains("## Rules") && e.contains("## Open questions"), "Englisch → englische Überschriften", e)
        for must in ["ReportView.swift", "CSV", "date, amount and category", "PDF", "Excel"] { t.check(e.contains(must), "EN behält „\(must)“", e) }
        t.check(APDetails.missing(from: APTestSet.fallbackDE, in: p).isEmpty, "alle Zahlen/Dateien übernommen",
                APDetails.missing(from: APTestSet.fallbackDE, in: p).joined(separator: ", "))
        let g = APGist.of(p)
        t.check(g.tasks >= 2 && !g.goal.isEmpty, "Kurzzeile: Ziel + Anzahl", g.line)
        let g2 = APGist.of(APCLI.samplePromptDE)
        t.check(g2.tasks == 5 && g2.rules == 2 && g2.open == 1 && g2.goal.hasPrefix("Die Settings Page"), "Kurzzeile aus Claude-Prompt", g2.line)
    }

    // Builder mit Schein-Claude
    static func builder(_ t: SelfTestChecks) {
        t.section("Builder (Schein-Claude)")
        func run(_ b: APBuilder, _ text: String = APTestSet.fallbackDE, cancelAfter: Double? = nil) -> (APOutcome?, [String]) {
            var out: APOutcome?; var parts: [String] = []
            let task = Task { out = await b.build(APRequest(transcript: text)) { p in DispatchQueue.main.async { parts.append(p) } } }
            if let c = cancelAfter { DispatchQueue.main.asyncAfter(deadline: .now() + c) { task.cancel() } }
            spin(10) { out != nil }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return (out, parts)
        }
        // Erfolg + Live-Text + Flags
        var seen: (String, String, String)?
        let ok = APBuilder()
        ok.available = { true }
        ok.runner = { sys, input, model, effort, _, onText in
            seen = (model, effort, input)
            onText("**Ziel:** Settings"); try await Task.sleep(nanoseconds: 50_000_000)
            onText(APCLI.samplePromptDE)
            return "Hier ist dein Prompt:\n\n" + APCLI.samplePromptDE
        }
        let (r1, parts) = run(ok)
        if case .ok(let res)? = r1 {
            t.check(res.source == "claude/sonnet/low", "Claude: Quelle claude/sonnet/low", res.source)
            t.check(res.prompt.hasPrefix("**Ziel:**"), "Einleitung „Hier ist dein Prompt“ entfernt")
        } else { t.check(false, "Claude-Erfolg", "\(String(describing: r1))") }
        t.check(seen?.0 == "sonnet" && seen?.1 == "low", "Aufruf mit --model sonnet --effort low", "\(String(describing: seen))")
        t.check(seen?.2.contains("<diktat sprache=\"de\">") == true && seen?.2.contains("3 Sekunden") == false, "Diktat unverändert als <diktat> (Sprache de)")
        t.check(parts.count >= 2, "Live-Text kommt an", "\(parts.count) Teile")
        // Zeitlimit → Regeln
        let slow = APBuilder(); slow.available = { true }; slow.timeout = 0.4
        slow.runner = { _, _, _, _, _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return "zu spät" }
        let t0 = Date()
        let (r2, _) = run(slow)
        if case .ok(let res)? = r2 {
            t.check(res.source == "regeln" && res.note.contains("Zeitlimit"), "Zeitlimit → Regel-Prompt", "\(res.source) \(res.note)")
            t.check(Date().timeIntervalSince(t0) < 3, "Zeitlimit greift schnell", String(format: "%.1f s", Date().timeIntervalSince(t0)))
            t.check(res.prompt.contains("users.controller.ts"), "Regel-Prompt behält Details")
        } else { t.check(false, "Zeitlimit → Regeln", "\(String(describing: r2))") }
        // Fehler → Regeln
        let bad = APBuilder(); bad.available = { true }
        bad.runner = { _, _, _, _, _, _ in throw ClaudeCLI.Failure(message: "Claude-CLI Fehler (1): kaputt") }
        if case .ok(let res)? = run(bad).0 { t.check(res.source == "regeln" && res.note == "Claude nicht erreichbar", "Fehler → Regel-Prompt", res.note) }
        else { t.check(false, "Fehler → Regeln") }
        // Claude fehlt → Regeln
        let none = APBuilder(); none.available = { false }
        if case .ok(let res)? = run(none).0 { t.check(res.note == "Claude-CLI fehlt", "ohne Claude-CLI → Regeln", res.note) } else { t.check(false, "ohne CLI") }
        // Unsinnige Antwort → Regeln
        let short = APBuilder(); short.available = { true }; short.runner = { _, _, _, _, _, _ in "OK." }
        if case .ok(let res)? = run(short).0 { t.check(res.source == "regeln" && res.note.contains("zu kurz"), "zu kurze Antwort → Regeln", res.note) } else { t.check(false, "zu kurz") }
        // Ohne Rückfall → Fehler
        let strict = APBuilder(); strict.available = { true }; strict.ruleFallback = false; strict.runner = bad.runner
        t.check(run(strict).0 == .failed("Claude nicht erreichbar"), "ohne Rückfall: Fehler statt Regeln")
        // Abbruch
        let cancel = APBuilder(); cancel.available = { true }
        cancel.runner = { _, _, _, _, _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return APCLI.samplePromptDE }
        t.check(run(cancel, cancelAfter: 0.15).0 == .cancelled, "Abbrechen → .cancelled (kein Regel-Prompt)")
        t.check(APBuilder.clean("```markdown\n**Ziel:** X\n## Aufgabe\n1. Y\n```") == "**Ziel:** X\n## Aufgabe\n1. Y", "Codeblock drumherum entfernt")
    }

    // Verlauf
    static func store(_ t: SelfTestChecks) {
        t.section("Verlauf (prompts/)")
        let dir = Paths.base.appendingPathComponent("prompts-test-\(UUID().uuidString.prefix(6))")
        let s = APStore(dir: dir)
        let r = APRecord(id: "abc123", created: Date(timeIntervalSince1970: 1_790_000_000), prompt: APCLI.samplePromptDE,
                         original: "Original mit\nzwei Zeilen und --- Strichen", appName: "Visual Studio Code", windowTitle: "a\nb", source: "claude/sonnet/low", buildMs: 9000)
        s.add(r)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        t.check(files.filter { $0.hasSuffix(".md") }.count == 1 && !files.contains { $0.hasPrefix(".tmp-") }, "eine .md-Datei, keine Schreib-Reste", files.joined(separator: ", "))
        let perms = (try? FileManager.default.attributesOfItem(atPath: s.fileURL(r).path)[.posixPermissions] as? Int) ?? 0
        t.check(perms == 0o600, "Rechte 0600", String(perms, radix: 8))
        let s2 = APStore(dir: dir)
        t.check(s2.records.first == r.withTitleOneLine, "gespeichert = gelesen (Prompt UND Original)", "\(String(describing: s2.records.first))")
        // Kaputte Dateien + Schreib-Rest
        try? "kein Kopf".write(to: dir.appendingPathComponent("2026-01-01_000000_kaputt.md"), atomically: true, encoding: .utf8)
        try? "---\nid: x\n".write(to: dir.appendingPathComponent("2026-01-02_000000_halb.md"), atomically: true, encoding: .utf8)
        try? "halb geschrieben".write(to: dir.appendingPathComponent(".tmp-123.md"), atomically: true, encoding: .utf8)
        let s3 = APStore(dir: dir)
        t.check(s3.records.count == 1 && s3.quarantined == 2, "kaputte Dateien übersprungen + nach defekt/ verschoben", "\(s3.records.count) gelesen, \(s3.quarantined) aussortiert")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        t.check(!left.contains { $0.hasPrefix(".tmp-") }, "Schreib-Reste aufgeräumt")
        t.check(((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("defekt").path)) ?? []).count == 2, "defekt/ enthält beide (nichts gelöscht)")
        // Überschreiben ist atomar (replaceItemAt), Höchstzahl 50
        var r2 = r; r2.prompt = "**Ziel:** neu"; s3.add(r2)
        t.check(APStore(dir: dir).records.first?.prompt == "**Ziel:** neu", "Überschreiben derselben ID")
        for i in 0..<55 {
            s3.add(APRecord(id: "n\(i)", created: Date(timeIntervalSince1970: 1_790_000_100 + Double(i)), prompt: "**Ziel:** \(i)", original: "o\(i)"))
        }
        let s4 = APStore(dir: dir)
        t.check(s4.records.count == APStore.maxCount && s4.records.first?.id == "n54", "höchstens 50, neueste zuerst", "\(s4.records.count)")
        s4.delete("n54")
        t.check(APStore(dir: dir).record("n54") == nil, "Löschen entfernt die Datei")
        try? FileManager.default.removeItem(at: dir)
    }

    // Ablauf
    static func flow(_ t: SelfTestChecks) {
        t.section("Ablauf (Original zuerst gesichert, Abbrechen/Fehler)")
        let dir = Paths.base.appendingPathComponent("prompts-flow-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        var copies: [(String, String)] = []
        var inserts: [(String, String)] = []
        var history: [String] = []
        var copiesAtBuild = -1
        let pres = APFakePresenter()
        var a = APActions()
        a.copy = { copies.append(($0, $1)) }
        a.insert = { text, src, _, done in inserts.append((text, src)); done(true) }
        a.openHub = { _ in }
        a.addHistory = { h, _ in history.append(h) }
        a.captureTarget = { _ in (nil, APContext(appName: "Terminal", bundleID: APTestSet.term, windowTitle: "claude")) }
        a.claudeAvailable = { true }
        var mode = "ok"
        let flow = APFlow(testing: APPrefs(), store: APStore(dir: dir), presenter: pres, actions: a)
        flow.makeBuilder = { _ in
            let b = APBuilder(); b.available = { true }; b.timeout = 3
            b.runner = { _, _, _, _, _, onText in
                copiesAtBuild = copies.count
                switch mode {
                case "slow": try await Task.sleep(nanoseconds: 3_000_000_000); return APCLI.samplePromptDE
                case "fail": throw ClaudeCLI.Failure(message: "Claude-CLI Fehler (1)")
                default: onText("**Ziel:**"); return APCLI.samplePromptDE
                }
            }
            if mode == "fail" { b.ruleFallback = false }
            return b
        }
        func dictate(_ s: String) -> Bool {
            var r: Bool?
            Task { r = await flow.consume(s, duration: 20, useMouse: false, finish: {}) }
            spin(5) { r != nil }
            return r ?? false
        }
        func waitEnd() { spin(6) { !flow.isBuilding }; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        // 1) Erfolg
        let said = "Prompt: bitte bau den Export um, so dass CSV und PDF gehen, und lass alle Tests laufen."
        t.check(dictate(said), "„Prompt: …“ wird abgefangen (nicht eingefügt)")
        waitEnd()
        t.check(copies.first?.1 == APFlow.sourceOriginal && copies.first?.0.hasPrefix("Bitte bau den Export") == true, "Original ZUERST als „Diktat (Original)“ gesichert (ohne Auslöser)",
                "\(copies.map { $0.1 })")
        t.check(copiesAtBuild >= 1, "Original lag schon VOR dem Bauen in der Zwischenablage", "\(copiesAtBuild)")
        t.check(history.first?.hasPrefix("Bitte bau den Export") == true, "Original im Diktat-Verlauf")
        t.check(copies.last?.1 == APFlow.sourcePrompt && copies.last?.0 == APCLI.samplePromptDE, "Prompt danach als „Agent-Prompt“ (Zwischenablage endet mit Prompt)")
        t.check(pres.shown.first.map { if case .building = $0 { return true }; return false } == true, "Karte zeigt sofort „wird gebaut“")
        guard case .done(let rec)? = pres.last else { t.check(false, "fertig-Karte", "\(String(describing: pres.last))"); return }
        t.check(rec.original.hasPrefix("Bitte bau den Export") && rec.prompt == APCLI.samplePromptDE, "Verlauf-Eintrag hat Prompt UND Original")
        t.check(APStore(dir: dir).records.count == 1, "Verlauf auf der Platte")
        pres.onAction(.copyOriginal)
        t.check(copies.last?.1 == APFlow.sourceOriginal && pres.flashes.last == .copiedOriginal, "fertig: „Original kopieren“")
        pres.onAction(.insertOriginal)
        t.check(inserts.last?.1 == APFlow.sourceOriginal && inserts.last?.0 == rec.original, "fertig: „Original einfügen“")
        pres.onAction(.insert)
        t.check(inserts.last?.1 == APFlow.sourcePrompt && inserts.last?.0 == rec.prompt, "fertig: „Einfügen“ fügt den Prompt ein")

        // 2) Abbrechen
        mode = "slow"; copies = []; inserts = []
        t.check(dictate("Agent-Prompt: recherchier die drei besten Bibliotheken für PDF-Export in Swift."), "zweiter Prompt startet")
        spin(1) { copiesAtBuild >= 0 && flow.isBuilding }
        pres.onAction(.cancel)
        guard case .stopped(.cancelled, _, let orig)? = pres.last else { t.check(false, "Abbrechen → Karte „abgebrochen“", "\(String(describing: pres.last))"); return }
        t.check(orig.hasPrefix("Recherchier die drei"), "abgebrochen: Karte hält das Original")
        t.check(copies.count == 1 && copies[0].1 == APFlow.sourceOriginal, "abgebrochen: Zwischenablage bleibt beim Original (kein Prompt)", "\(copies.map { $0.1 })")
        pres.onAction(.insertOriginal)
        t.check(inserts.last?.0 == orig && inserts.last?.1 == APFlow.sourceOriginal, "abgebrochen: „Original einfügen“")
        pres.onAction(.copyOriginal)
        t.check(copies.last?.0 == orig && copies.last?.1 == APFlow.sourceOriginal, "abgebrochen: „Original kopieren“")
        spin(4) { false }   // Schein-Claude läuft ins Leere – darf nichts mehr ändern
        t.check(pres.last.map { if case .stopped = $0 { return true }; return false } == true && APStore(dir: dir).records.count == 1,
                "späte Antwort nach Abbruch wird verworfen")

        // 3) Fehler (ohne Rückfall)
        mode = "fail"; copies = []; inserts = []
        t.check(dictate("Prompt: fix den Crash in Parser.swift bei leeren Zeilen und schreib einen Test."), "dritter Prompt startet")
        waitEnd()
        guard case .stopped(.failed, let why, let o3)? = pres.last else { t.check(false, "Fehler → Karte", "\(String(describing: pres.last))"); return }
        t.check(why == "Claude nicht erreichbar" && o3.hasPrefix("Fix den Crash"), "Fehler: Karte mit Grund + Original", why)
        t.check(copies.map(\.1) == [APFlow.sourceOriginal], "Fehler: Zwischenablage endet mit dem Original")
        pres.onAction(.insertOriginal); pres.onAction(.copyOriginal)
        t.check(inserts.last?.0 == o3 && copies.last?.0 == o3, "Fehler: beide Original-Knöpfe gehen")
        mode = "ok"
        pres.onAction(.retry); waitEnd()
        t.check(pres.last.map { if case .done = $0 { return true }; return false } == true, "„Nochmal“ baut erneut")

        // 4) Aus / Nur auf Zuruf / Vorschlag
        flow.prefs.mode = .off
        t.check(!dictate("Prompt: bau das um und prüf die Tests."), "Einstellung „Aus“: nichts abgefangen")
        flow.prefs.mode = .explicitOnly
        pres.close()
        t.check(flow.offerIfLong(text: APTestSet.longDE1, duration: 40, bundleID: APTestSet.vsc, title: "x")?.offer != true || !pres.isShowing,
                "„Nur auf Zuruf“: kein Vorschlag")
        t.check(!pres.isShowing, "„Nur auf Zuruf“: keine Karte")
        flow.prefs.mode = .on
        let d = flow.offerIfLong(text: APTestSet.longDE1, duration: 40, bundleID: APTestSet.vsc, title: "SettingsPanel.tsx")
        t.check(d?.offer == true && pres.last.map { if case .offer = $0 { return true }; return false } == true, "langer Auftrag → Vorschlags-Karte")
        copies = []
        pres.onAction(.build); waitEnd()
        t.check(copies.map(\.1) == [APFlow.sourcePrompt], "Vorschlag angenommen: Original war schon eingefügt, nur der Prompt kommt dazu", "\(copies.map(\.1))")
        pres.close()
        _ = flow.offerIfLong(text: "Ja passt, mach so.", duration: 2, bundleID: APTestSet.term)
        t.check(!pres.isShowing, "kurzes Diktat → keine Karte")
    }
}

extension APSelfTest {
    /// Öffentliche Fassung: Claude-CLI ist optional. Ohne sie: auf Zuruf Regel-Prompt, leiser Hinweis, keine Vorschläge.
    static func withoutClaude(_ t: SelfTestChecks) {
        t.section("Ohne Claude-CLI (optional)")
        let dir = Paths.base.appendingPathComponent("prompts-noclaude-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        var copies: [(String, String)] = []
        var ran = false
        let pres = APFakePresenter()
        var a = APActions()
        a.copy = { copies.append(($0, $1)) }
        a.insert = { _, _, _, done in done(true) }
        a.openHub = { _ in }
        a.addHistory = { _, _ in }
        a.captureTarget = { _ in (nil, APContext(appName: "Terminal", bundleID: APTestSet.term, windowTitle: "claude")) }
        a.claudeAvailable = { false }
        let flow = APFlow(testing: APPrefs(), store: APStore(dir: dir), presenter: pres, actions: a)
        flow.makeBuilder = { _ in
            let b = APBuilder(); b.available = { false }
            b.runner = { _, _, _, _, _, _ in ran = true; return "" }
            return b
        }
        t.check(APPrefs().mode == .on, "Standard bleibt „An“")
        let d = flow.offerIfLong(text: APTestSet.longDE1, duration: 42, bundleID: APTestSet.vsc, title: "SettingsPanel.tsx")
        t.check(d == nil && !pres.isShowing && pres.shown.isEmpty, "ohne Claude: kein automatischer Vorschlag (auch bei klarem Auftrag)")
        var r: Bool?
        Task { r = await flow.consume("Prompt: " + APTestSet.fallbackDE, duration: 30, useMouse: false, finish: {}) }
        spin(5) { r != nil }
        spin(5) { !flow.isBuilding }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        t.check(r == true, "ohne Claude: „Prompt: …“ wird trotzdem abgefangen")
        t.check(!ran, "ohne Claude: kein Claude-Aufruf")
        guard case .done(let rec)? = pres.last else { t.check(false, "ohne Claude: fertig-Karte", "\(String(describing: pres.last))"); return }
        t.check(rec.byRules && rec.note == "Claude-CLI fehlt", "ohne Claude: Regel-Prompt mit Grund", "\(rec.source) \(rec.note)")
        t.check(rec.prompt.contains("users.controller.ts") && rec.prompt.contains("## Aufgabe"), "ohne Claude: Regel-Prompt behält Details")
        t.check(copies.first?.1 == APFlow.sourceOriginal && copies.last?.1 == APFlow.sourcePrompt, "ohne Claude: erst Original, dann Prompt in die Zwischenablage",
                "\(copies.map(\.1))")
        t.check(APCardStyle.rulesLabel(rec.note) == "Regeln · ohne Claude-CLI", "Karte: leiser Hinweis „ohne Claude-CLI“", APCardStyle.rulesLabel(rec.note))
        t.check(APCardStyle.rulesLabel("Zeitlimit (45 s)") == "Regeln · Zeitlimit (45 s)", "Karte: Grund bei Claude-Fehler")
    }
}

private extension APRecord {
    /// So wie es nach dem Speichern gelesen wird (Kopfzeilen sind einzeilig)
    var withTitleOneLine: APRecord { var r = self; r.windowTitle = APStore.oneLine(r.windowTitle); return r }
}
