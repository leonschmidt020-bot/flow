import AppKit
import SwiftUI

// MARK: - Agent-Prompt: Test-Befehle ohne Oberfläche
//
//   FLOW_HOME=<leer> Flow --selftest-agent-prompt [-v]   Auslöser (+ Verhörer), Erkennung (≥40 Fälle), Regel-Rückfall,
//                                                           Builder mit Schein-Claude (Zeitlimit, Fehler, Abbruch), Verlauf
//                                                           (atomar, kaputte Dateien), Ablauf (Original zuerst gesichert,
//                                                           Abbrechen/Fehler → Original einfügen/kopieren). Kein Claude, keine Zwischenablage.
//   FLOW_HOME=<leer> Flow --agent-prompt-render <ordner>  alle Karten-Zustände + Hub-Ansicht als PNG
//                                                           + Ersetzen beim „Einfügen“ (Schein-Box/Schein-Feld), „abgeschickt?“
//   FLOW_HOME=<leer> Flow --agent-prompt-latency          Einfügen → Vorschlags-Karte: vorher/nachher (ms), offscreen
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
        case "--agent-prompt-latency": return SelfTestCLI.guardedHome { latency() }
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
            ("3f_fertig_abgeschickt", .done(long, sent: true), 1, false, false, nil, "illu_prompt_fertig"),
            ("4a_abgebrochen", .stopped(.cancelled, reason: "Abgebrochen", original: sampleOriginalDE), 1, false, false, nil, nil),
            ("4b_fehlgeschlagen", .stopped(.failed, reason: "Claude nicht erreichbar", original: sampleOriginalDE), 1, false, false, nil, nil),
            ("5a_pille_rechts_hochkant", .done(long), 1, false, false, pillRightEdge, nil),
            ("5b_pille_links_hochkant", .building(partial: partial, words: 118, started: now), 1, false, false, pillLeftEdge, nil),
        ]
        var ok = 0
        // Leises Ausblenden (Original abgeschickt): Zwischenbild bei halber Deckkraft
        if APCard.renderPNG(.offer(det), to: d.appendingPathComponent("1b_vorschlag_verblasst.png"), opacity: 0.45) { ok += 1 }
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
        let total = shots.count + extra.count + 2
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
    var faded = 0
    private(set) var isShowing = false
    func show(_ phase: APCardPhase) { shown.append(phase); isShowing = true }
    func close() { closed += 1; isShowing = false }
    func fadeOut() { faded += 1; isShowing = false }
    func flash(_ what: APCardFlash) { flashes.append(what) }
    var last: APCardPhase? { shown.last }
    var phase: APCardPhase? { isShowing ? shown.last : nil }
}

/// Schein-Ziel für das Ersetzen: Claude-Code-Box (gezeichnet wie im Terminal, umbrochen) oder Textfeld – mit Schreibmarke
final class APFakeIO: APReplaceIO {
    var buffer: [Character]
    var cursor: Int
    var sent: [String] = []
    var field = false
    var secure = false
    var canSelect = true
    var selection: NSRange?
    /// Claude Code löscht einen Platzhalter mit EINER Rücktaste (sonst Zeichen für Zeichen)
    var unitPlaceholders = false
    var width = 58
    /// Träges Terminal: Rücktasten kommen erst beim Lesen an (höchstens so viele je Lesung) – 0 = sofort
    var lagPerRead = 0
    private var pending = 0
    private(set) var backspaces = 0
    private(set) var typed: [Character] = []
    private(set) var reads = 0

    init(_ text: String, cursor: Int? = nil) { buffer = Array(text); self.cursor = cursor ?? text.count }
    var text: String { String(buffer) }

    func isSecure() -> Bool { secure }

    /// Zeilen wie Claude Code: Verlauf („❯ …“ + Antwort), Trennlinie, „❯ “ + umbrochener Text, Trennlinie, Statuszeile
    func rows() -> [String] {
        var r: [String] = []
        for m in sent { r.append("❯ " + m); r.append("⏺ Erledigt."); r.append("") }
        let rule = String(repeating: "─", count: width + 4)
        r.append(rule)
        var lines: [String] = []
        var cur = ""
        for w in text.split(separator: " ", omittingEmptySubsequences: false) {
            if cur.count + w.count + 1 > width, !cur.isEmpty { lines.append(cur); cur = String(w) }
            else { cur = cur.isEmpty ? String(w) : cur + " " + w }
        }
        lines.append(cur)
        r.append("❯\u{00A0}" + lines[0])
        for l in lines.dropFirst() { r.append("  " + l) }
        r.append(rule)
        r.append("  ⏵⏵ accept edits on")
        return r
    }

    func readBox() -> TerminalPrompt.Screen? {
        reads += 1
        if pending > 0 { let n = min(pending, lagPerRead); pending -= n; apply(n) }
        return field ? nil : TerminalPrompt.parse(rows())
    }
    func readField() -> (value: String, selection: NSRange?)? {
        reads += 1
        guard field else { return nil }
        return (text, selection ?? NSRange(location: String(buffer[..<cursor]).utf16.count, length: 0))
    }
    func select(_ r: NSRange) -> Bool { guard canSelect else { return false }; selection = r; return true }
    func backspace(_ n: Int) {
        backspaces += n
        if lagPerRead > 0 { pending += n } else { apply(n) }
    }
    private func apply(_ n: Int) {
        for _ in 0..<n {
            selection = nil
            if unitPlaceholders {
                let before = String(buffer[..<cursor])
                if let ph = APReplace.placeholders(before).last, ph.range.upperBound == before.endIndex {
                    let len = before[ph.range].count
                    buffer.removeSubrange((cursor - len)..<cursor); cursor -= len; continue
                }
            }
            if cursor > 0 { buffer.remove(at: cursor - 1); cursor -= 1 }
        }
    }
    func type(_ c: Character) { typed.append(c); buffer.insert(c, at: cursor); cursor += 1 }
    func sleep(_ s: Double) { usleep(1_000) }
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
        replace(t)
        replaceRun(t)
        sentFlow(t)
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
        a.snapshot = { _, _, _, done in done(.unknown("Test"), nil, nil, nil) }
        a.probe = { _, done in done(.intact) }
        a.preRead = { _ in }
        var replaced: [String] = []
        a.replace = { prompt, _, done in replaced.append(prompt); done(.cleared, true) }
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
        guard case .done(let rec, _)? = pres.last else { t.check(false, "fertig-Karte", "\(String(describing: pres.last))"); return }
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
        inserts = []
        pres.onAction(.insert)
        t.check(replaced == [APCLI.samplePromptDE] && inserts.isEmpty, "Vorschlag: „Einfügen“ ersetzt das Original (nicht nur einfügen)", "\(replaced.count) ersetzt, \(inserts.count) eingefügt")
        pres.onAction(.insert)
        t.check(replaced.count == 1 && inserts.count == 1, "zweites „Einfügen“ fügt nur noch ein (Original ist schon ersetzt)")
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
        a.preRead = { _ in }
        a.snapshot = { _, _, _, done in done(.unknown("Test"), nil, nil, nil) }
        a.probe = { _, done in done(.intact) }
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
        guard case .done(let rec, _)? = pres.last else { t.check(false, "ohne Claude: fertig-Karte", "\(String(describing: pres.last))"); return }
        t.check(rec.byRules && rec.note == "Claude-CLI fehlt", "ohne Claude: Regel-Prompt mit Grund", "\(rec.source) \(rec.note)")
        t.check(rec.prompt.contains("users.controller.ts") && rec.prompt.contains("## Aufgabe"), "ohne Claude: Regel-Prompt behält Details")
        t.check(copies.first?.1 == APFlow.sourceOriginal && copies.last?.1 == APFlow.sourcePrompt, "ohne Claude: erst Original, dann Prompt in die Zwischenablage",
                "\(copies.map(\.1))")
        t.check(APCardStyle.rulesLabel(rec.note) == "Regeln · ohne Claude-CLI", "Karte: leiser Hinweis „ohne Claude-CLI“", APCardStyle.rulesLabel(rec.note))
        t.check(APCardStyle.rulesLabel("Zeitlimit (45 s)") == "Regeln · Zeitlimit (45 s)", "Karte: Grund bei Claude-Fehler")
    }

    static let ins = " Bau bitte den Export so um, dass CSV und PDF gehen, und lass danach alle Tests laufen."

    static func box(_ input: String, sent: [String] = []) -> TerminalPrompt.Screen {
        let io = APFakeIO(input); io.sent = sent
        return TerminalPrompt.parse(io.rows())
    }

    // Reine Logik: Stelle merken + entscheiden
    static func replace(_ t: SelfTestChecks) {
        t.section("Ersetzen: Stelle merken + entscheiden (reine Logik)")
        let x = ins.trimmingCharacters(in: .whitespaces)
        // Box: Text ausgeschrieben (umbrochen über mehrere Zeilen)
        let m1 = APReplace.markBox(inserted: ins, screen: box("Hallo Claude," + ins), pre: nil)
        guard case .found(let mb)? = m1, case .box(let b1, _, let a1, _) = mb else { t.check(false, "Box: Text gefunden", "\(String(describing: m1))"); return }
        t.check(APReplace.squash(b1) == "HalloClaude," && a1.isEmpty, "Box: Text davor bleibt Text davor, umbrochen gefunden", "„\(b1)“ / „\(a1)“")
        t.check(APReplace.judgeBox(mb, now: box("Hallo Claude," + ins)) == .intact, "Box unverändert → intakt")
        t.check(APReplace.judgeBox(mb, now: box("")) == .sent, "Box leer → abgeschickt")
        t.check(APReplace.judgeBox(mb, now: box("", sent: ["Hallo Claude," + ins])) == .sent, "neuer ❯-Block im Verlauf → abgeschickt")
        t.check(APReplace.judgeBox(mb, now: box("Hallo Claude, Bau bitte den Import so um, dass CSV und PDF gehen, und lass danach alle Tests laufen.")) == .edited,
                "ein Wort im Original geändert → geändert (nichts löschen)")
        t.check(APReplace.judgeBox(mb, now: box("Hallo Claude," + ins + " Und schnell!")) == .edited, "danach weitergetippt → geändert (Schreibmarke unbekannt)")
        t.check(APReplace.judgeBox(mb, now: TerminalPrompt.parse(["~ % ls", "datei.txt"])) == .unreadable("keine Claude-Code-Eingabebox"), "keine Box → nicht prüfbar")
        t.check(APReplace.judgeBox(mb, now: nil) == .unreadable("Terminal nicht lesbar"), "nicht lesbar → nicht prüfbar")
        // Schon vor dem Nachlesen abgeschickt
        t.check(APReplace.markBox(inserted: ins, screen: box("", sent: [x]), pre: box("")) == .sentAlready, "beim Nachlesen schon im Verlauf → „schon abgeschickt“")
        t.check(APReplace.markBox(inserted: ins, screen: box("Hallo"), pre: nil) == nil, "noch nicht gezeichnet → weiter nachlesen")
        // Eingeklappt („[Pasted text #2 +12 lines]“): nur mit Stand vor dem Diktat
        let ph = "[Pasted text #2 +12 lines]"
        let pre = box("Kurz vorweg: [Pasted text #1 +3 lines] ")
        let mc = APReplace.markBox(inserted: ins, screen: box("Kurz vorweg: [Pasted text #1 +3 lines] " + ph), pre: pre)
        if case .found(.box(_, let shown, _, _))? = mc { t.check(shown == ph, "eingeklappt: NEUER Platzhalter ist unserer (alter #1 bleibt)", shown) }
        else { t.check(false, "eingeklappt erkannt", "\(String(describing: mc))") }
        if case .unknown? = APReplace.markBox(inserted: ins, screen: box(ph), pre: nil) { t.check(true, "eingeklappt ohne Stand vorher → nie löschen") }
        else { t.check(false, "eingeklappt ohne Stand vorher → nie löschen") }
        t.check(APReplace.markBox(inserted: ins, screen: box("[Pasted text #1 +3 lines]"), pre: box("[Pasted text #1 +3 lines]")) == nil,
                "nur der alte Platzhalter (vom Nutzer) → nicht unserer")
        if case .unknown? = APReplace.markBox(inserted: ins, screen: box("Anders " + ph), pre: box("Kurz")) { t.check(true, "eingeklappt, aber Box sonst auch geändert → nie löschen") }
        else { t.check(false, "eingeklappt + Box geändert → nie löschen") }
        // Textfeld
        let v = "Hi," + ins
        guard case .found(let mf)? = APReplace.markField(inserted: ins, value: v, cursor: (v as NSString).length) else { t.check(false, "Feld: Text gefunden"); return }
        let (fv, fr) = APReplace.judgeField(mf, value: v)
        t.check(fv == .intact && fr == NSRange(location: 3, length: (ins as NSString).length), "Feld unverändert → intakt, genauer Bereich", "\(fv) \(String(describing: fr))")
        let (ev, er) = APReplace.judgeField(mf, value: "Moin! Hi," + ins + " PS")
        t.check(ev == .intact && er?.location == 9, "Feld: drumherum getippt, Original unversehrt → Bereich verschoben gefunden", "\(ev) \(String(describing: er))")
        t.check(APReplace.judgeField(mf, value: "Hi, Bau bitte den Export so um").0 == .edited, "Feld: Original verändert → geändert")
        t.check(APReplace.judgeField(mf, value: "").0 == .sent, "Feld geleert → abgeschickt")
        t.check(APReplace.judgeField(mf, value: "Hi,").0 == .sent, "Feld wieder wie vorher → abgeschickt")
        let twice = APReplace.judgeField(mf, value: "Hi," + ins + ins)
        t.check(twice.0 == .intact && twice.1?.location == 3, "Original zweimal da, eines an der alten Stelle → genau das alte", "\(twice)")
        t.check(APReplace.judgeField(mf, value: "Moin" + ins + ins).0 == .edited, "Original zweimal da, keines an der alten Stelle → geändert (nichts löschen)")
        // Wie viel steht noch?
        let m = APMark.box(before: "Hallo ", shown: "ab cd", after: "", sentBefore: [])
        t.check(APReplace.remaining(m, now: "Hallo ab cd") == 5 && APReplace.remaining(m, now: "Hallo ab c") == 4 && APReplace.remaining(m, now: "Hallo ab") == 2
                && APReplace.remaining(m, now: "Hallo ") == 0 && APReplace.remaining(m, now: "Hall ab cd") == nil,
                "Rest unseres Textes: kleinstes k, fremde Änderung → nil")
        t.check(APReplace.deletedChar(before: "Hallo ab cd", after: "Halo ab cd") == "l", "falsch gelöschtes Zeichen erkannt")
    }

    // Ablauf „Einfügen“ mit Schein-Box / Schein-Feld
    static func replaceRun(_ t: SelfTestChecks) {
        t.section("Ersetzen: „Einfügen“ mit Schein-Box / Schein-Feld")
        APReplaceRun.stepTimeout = 0.05; APReplaceRun.quiet = 0.02
        func pasted(_ io: APFakeIO, pre: TerminalPrompt.Screen? = nil) -> APPasted {
            let p = APPasted(text: ins)
            p.state = io.field ? (APReplace.markField(inserted: ins, value: io.text, cursor: String(io.buffer[..<io.cursor]).utf16.count) ?? .pending)
                               : (APReplace.markBox(inserted: ins, screen: TerminalPrompt.parse(io.rows()), pre: pre) ?? .pending)
            return p
        }
        // 1) noch da → gelöscht, Text davor bleibt
        let a = APFakeIO("Kontext von vorhin:" + ins)
        let pa = pasted(a)
        t.check(APReplaceRun.run(pa.state, io: a) == .cleared && a.text == "Kontext von vorhin:", "Box: Original noch da → gelöscht, eigener Text davor bleibt", "„\(a.text)“")
        t.check(a.backspaces == ins.count, "genau so viele Rücktasten wie eingefügte Zeichen", "\(a.backspaces) / \(ins.count)")
        // 2) schon abgeschickt → nichts löschen
        let b = APFakeIO(ins); let pb = pasted(b)
        b.sent = [ins.trimmingCharacters(in: .whitespaces)]; b.buffer = []; b.cursor = 0
        t.check(APReplaceRun.run(pb.state, io: b) == .insertNew(hint: APReplaceOutcome.hintSent, why: "abgeschickt") && b.backspaces == 0,
                "abgeschickt → nichts gelöscht, neu einfügen + „Original war schon abgeschickt“")
        // 3) im Original korrigiert → nichts löschen
        let c = APFakeIO(ins); let pc = pasted(c)
        c.buffer = Array(ins.replacingOccurrences(of: "Export", with: "Import")); c.cursor = c.buffer.count
        if case .insertNew(let h, _) = APReplaceRun.run(pc.state, io: c) { t.check(h == APReplaceOutcome.hintEdited && c.backspaces == 0, "im Original geändert → nichts gelöscht, Hinweis") }
        else { t.check(false, "im Original geändert → nichts gelöscht") }
        // 4) danach weitergetippt → nichts löschen
        let d = APFakeIO(ins); let pd = pasted(d)
        d.buffer += Array(" Danke!"); d.cursor = d.buffer.count
        t.check(APReplaceRun.run(pd.state, io: d) == .insertNew(hint: APReplaceOutcome.hintEdited, why: "seit dem Einfügen geändert") && d.backspaces == 0 && d.text.hasSuffix("Danke!"),
                "danach weitergetippt → eigener Text bleibt, nichts gelöscht")
        // 5) Schreibmarke woanders (Text gleich) → erste Rücktaste trifft fremdes Zeichen → sofort zurückgeschrieben, Schluss
        let e = APFakeIO("Hallo Welt." + ins); let pe = pasted(e)
        e.cursor = 5
        let re = APReplaceRun.run(pe.state, io: e)
        t.check(e.text == "Hallo Welt." + ins && e.backspaces == 1 && e.typed == ["o"], "Schreibmarke woanders → 1 Zeichen, sofort zurückgeschrieben, Text unverändert",
                "„\(e.text.prefix(20))…“ \(e.backspaces) Rücktasten, \(e.typed)")
        if case .insertNew(let h, _) = re { t.check(h == APReplaceOutcome.hintEdited, "… und Prompt nur neu eingefügt (Hinweis)") } else { t.check(false, "Schreibmarke woanders → kein Löschen") }
        // 6) eingeklappt: Platzhalter mit einer Rücktaste bzw. Zeichen für Zeichen
        for unit in [true, false] {
            let ph = "[Pasted text #4 +9 lines]"
            let f = APFakeIO("Bitte: " + ph); f.unitPlaceholders = unit
            let pf = pasted(f, pre: box("Bitte: "))
            t.check(APReplaceRun.run(pf.state, io: f) == .cleared && f.text == "Bitte: ", "eingeklappt (\(unit ? "eine Rücktaste" : "Zeichen für Zeichen")) → nur der Platzhalter weg", "„\(f.text)“, \(f.backspaces) Rücktasten")
        }
        // 6b) träges Terminal (Claude Code zeichnet verzögert): nie mehr löschen als unser Text
        let lag = APFakeIO("Erst das hier." + ins); lag.lagPerRead = 7
        let pl0 = pasted(lag)
        t.check(APReplaceRun.run(pl0.state, io: lag) == .cleared && lag.text == "Erst das hier." && lag.backspaces == ins.count,
                "träges Terminal → genau unser Text gelöscht, kein Zeichen mehr", "„\(lag.text)“, \(lag.backspaces) Rücktasten")
        // 7) Passwortfeld / sichere Eingabe → nichts gelesen, nichts gelöscht
        let g = APFakeIO(ins); let pg = pasted(g); g.secure = true
        let readsBefore = g.reads
        t.check(APReplaceRun.run(pg.state, io: g) == .insertNew(hint: nil, why: "Passwortfeld/sichere Eingabe – nichts gelesen") && g.backspaces == 0 && g.reads == readsBefore,
                "sichere Eingabe → nichts gelesen, nichts gelöscht")
        // 8) Stelle nie gefunden → nichts löschen
        let h = APFakeIO(ins); let ph = APPasted(text: ins)
        t.check(APReplaceRun.run(ph.state, io: h) == .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Stelle beim Einfügen noch nicht gefunden") && h.backspaces == 0,
                "Stelle unbekannt → nichts gelöscht")
        // 9) Textfeld: markieren + darüber einfügen
        let i = APFakeIO("Hi," + ins); i.field = true
        let pi = pasted(i)
        t.check(APReplaceRun.run(pi.state, io: i) == .selected && i.selection == NSRange(location: 3, length: (ins as NSString).length) && i.backspaces == 0,
                "Feld: genau das Original markiert (Prompt ersetzt es beim Einfügen)", "\(String(describing: i.selection))")
        // 10) Feld lässt sich nicht markieren, Schreibmarke am Ende → Rücktaste
        let j = APFakeIO("Hi," + ins); j.field = true; j.canSelect = false
        let pj = pasted(j)
        t.check(APReplaceRun.run(pj.state, io: j) == .cleared && j.text == "Hi,", "Feld ohne Markieren, Schreibmarke am Ende → Rücktaste, „Hi,“ bleibt", "„\(j.text)“")
        // 11) … Schreibmarke woanders → nichts löschen
        let k = APFakeIO("Hi," + ins); k.field = true; k.canSelect = false
        let pk = pasted(k); k.cursor = 2
        if case .insertNew = APReplaceRun.run(pk.state, io: k) { t.check(k.backspaces == 0, "Feld ohne Markieren, Schreibmarke woanders → nichts gelöscht") }
        else { t.check(false, "Feld ohne Markieren, Schreibmarke woanders → nichts gelöscht") }
        // 12) Feld: drumherum getippt, Original unversehrt → trotzdem genau markiert
        let l = APFakeIO("Hi," + ins); l.field = true
        let pl = pasted(l); l.buffer = Array("Moin! Hi," + ins + " PS"); l.cursor = l.buffer.count
        t.check(APReplaceRun.run(pl.state, io: l) == .selected && l.selection?.location == 9, "Feld: drumherum geändert, Original unversehrt → nur das Original markiert")
        // 13) Feld geleert (abgeschickt)
        let n = APFakeIO("Hi," + ins); n.field = true
        let pn = pasted(n); n.buffer = []; n.cursor = 0
        t.check(APReplaceRun.run(pn.state, io: n) == .insertNew(hint: APReplaceOutcome.hintSent, why: "abgeschickt"), "Feld geleert → „Original war schon abgeschickt“")
        APReplaceRun.stepTimeout = 1.5; APReplaceRun.quiet = 0.35
    }

    // Ablauf: Vorschlag sofort, „abgeschickt?“, Enter, neues Diktat, Bauen während abgeschickt wird
    static func sentFlow(_ t: SelfTestChecks) {
        t.section("Vorschlag: sofort, abgeschickt → leise weg, Enter, neues Diktat")
        let dir = Paths.base.appendingPathComponent("prompts-sent-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pres = APFakePresenter()
        var a = APActions()
        var inserts: [String] = [], replaced: [String] = [], toasts: [String] = [], probes = 0, snaps = 0
        var verdict: APVerdict = .intact
        var front: pid_t = 4242
        a.copy = { _, _ in }
        a.insert = { text, _, _, done in inserts.append(text); done(true) }
        a.addHistory = { _, _ in }
        a.openHub = { _ in }
        a.toast = { toasts.append($0) }
        a.preRead = { done in done(4242, nil) }
        a.snapshot = { p, _, _, done in
            snaps += 1
            done(.found(.box(before: "", shown: p.text, after: "", sentBefore: [])),
                 APTarget(pid: 4242, windowID: nil, window: nil, bundleID: APTestSet.vsc, appName: "Code", title: "x"), nil, nil)
        }
        a.probe = { _, done in probes += 1; done(verdict) }
        var outcome: APReplaceOutcome = .cleared
        a.replace = { prompt, _, done in replaced.append(prompt); done(outcome, true) }
        a.frontPID = { front }
        a.claudeAvailable = { true }
        let oldPoll = (APFlow.pollOffer, APFlow.pollBuilding)
        APFlow.pollOffer = 0.03; APFlow.pollBuilding = 0.06
        defer { APFlow.pollOffer = oldPoll.0; APFlow.pollBuilding = oldPoll.1 }
        let flow = APFlow(testing: APPrefs(), store: APStore(dir: dir), presenter: pres, actions: a)
        var buildMs: UInt64 = 50_000_000
        flow.makeBuilder = { _ in
            let b = APBuilder(); b.available = { true }; b.timeout = 3
            b.runner = { _, _, _, _, _, _ in try await Task.sleep(nanoseconds: buildMs); return APCLI.samplePromptDE }
            return b
        }
        func paste(_ text: String = APTestSet.longDE1) -> APDetection? {
            let det = APFlow.precheck(text: text, duration: 40, bundleID: APTestSet.vsc, title: "SettingsPanel.tsx")
            return flow.afterPaste(text: text, inserted: " " + text, duration: 40, bundleID: APTestSet.vsc, detection: det, pastedAt: Date())
        }
        func isOffer(_ p: APCardPhase?) -> Bool { if case .offer? = p { return true }; return false }

        // Sofort: Karte im selben Durchlauf, ohne Verzögerung
        let t0 = Date()
        _ = paste()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        t.check(isOffer(pres.phase) && ms < 100, "Vorschlag erscheint sofort nach dem Einfügen (ohne 0,7-s-Pause)", "\(ms) ms")
        t.check((flow.lastOfferMs ?? 9999) < 1000, "gemessen: Einfügen → Karte lesbar < 1 s", "\(flow.lastOfferMs ?? -1) ms")
        t.check(snaps == 1 && flow.offer?.pasted.text.hasPrefix(" Okay") == true, "Stelle wird gemerkt (genau eingefügter Text inkl. Leerzeichen)")
        // Box bleibt → Karte bleibt
        spin(0.15) { false }
        t.check(isOffer(pres.phase) && probes >= 2, "Original noch da → Karte bleibt (alle 250 ms nachgelesen)", "\(probes) Lesungen")
        // Abgeschickt (Box leer / neuer ❯-Block) → leise weg
        verdict = .sent
        spin(1) { !pres.isShowing }
        t.check(!pres.isShowing && pres.faded == 1 && flow.offer == nil, "abgeschickt → Vorschlag leise ausgeblendet (kein Toast)", "verblasst \(pres.faded)×, \(toasts)")
        t.check(toasts.isEmpty, "kein Toast beim Ausblenden")
        let p1 = probes
        spin(0.12) { false }
        t.check(probes == p1, "nach dem Ausblenden wird nicht mehr nachgelesen", "\(probes - p1) weitere")

        // Enter, während die Karte steht
        verdict = .intact
        _ = paste()
        front = 99   // andere App vorne → Enter zählt nicht
        flow.returnPressed()
        spin(0.3) { false }
        t.check(isOffer(pres.phase), "Enter in einer ANDEREN App → Karte bleibt")
        front = 4242
        flow.returnPressed()
        spin(0.6) { false }
        t.check(isOffer(pres.phase), "Enter, Box aber unverändert (z. B. Zeilenumbruch im Editor) → Karte bleibt")
        verdict = .unreadable("Test")
        flow.returnPressed()
        spin(1) { !pres.isShowing }
        t.check(!pres.isShowing && flow.offer == nil, "Enter in der Ziel-App + nicht lesbar → zählt als abgeschickt, Karte weg")
        verdict = .sent
        _ = paste()
        flow.returnPressed()
        spin(1) { !pres.isShowing }
        t.check(!pres.isShowing, "Enter in der Ziel-App + Box leer → Karte weg")

        // Neues Diktat → alter Vorschlag weg (nie zwei übereinander)
        verdict = .intact
        _ = paste()
        let fadedBefore = pres.faded
        flow.dictationStarted()
        t.check(!pres.isShowing && flow.offer == nil && pres.faded == fadedBefore + 1, "neues Diktat → offener Vorschlag leise weg")
        // Zwei Diktate schnell hintereinander: der neue Vorschlag ersetzt den alten
        _ = paste()
        let firstPasted = flow.offer?.pasted
        _ = paste(APTestSet.longDE2)
        t.check(flow.offer?.pasted !== firstPasted && flow.offer?.text == APTestSet.longDE2 && isOffer(pres.phase), "zweiter Vorschlag ersetzt den ersten (eigene Stelle)")

        // Bauen, währenddessen abgeschickt → fertige Karte nur „Kopieren“ + „Als neue Nachricht einfügen“
        buildMs = 400_000_000
        pres.onAction(.build)
        t.check(flow.isBuilding && paste() != nil && flow.offer == nil, "während des Bauens: kein neuer Vorschlag (Bau läuft weiter)")
        verdict = .sent
        spin(3) { !flow.isBuilding }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if case .done(_, let sent)? = pres.last { t.check(sent, "Original während des Bauens abgeschickt → fertige Karte „Als neue Nachricht einfügen“") }
        else { t.check(false, "fertige Karte", "\(String(describing: pres.last))") }
        replaced = []; inserts = []; toasts = []
        pres.onAction(.insert)
        t.check(replaced.isEmpty && inserts == [APCLI.samplePromptDE] && toasts.isEmpty, "… „Einfügen“ fügt nur ein, löscht nichts, kein Hinweis")

        // Bauen, Original bleibt → „Einfügen“ ersetzt; Ergebnis „schon abgeschickt“ → leiser Hinweis
        verdict = .intact
        buildMs = 30_000_000
        pres.close()
        _ = paste()
        pres.onAction(.build)
        spin(3) { !flow.isBuilding }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if case .done(_, let sent)? = pres.last { t.check(!sent, "Original noch da → normale fertige Karte (Einfügen = Ersetzen)") } else { t.check(false, "fertige Karte 2") }
        replaced = []; inserts = []; toasts = []
        outcome = .insertNew(hint: APReplaceOutcome.hintSent, why: "abgeschickt")
        pres.onAction(.insert)
        t.check(replaced.count == 1 && toasts == [APReplaceOutcome.hintSent], "Ersetzen fand das Original abgeschickt → Prompt neu + „Original war schon abgeschickt – Prompt neu eingefügt“", "\(toasts)")
        // Doppelklick auf „Einfügen“ ersetzt nie zweimal
        let flow2Replaced = replaced.count
        var later: ((APReplaceOutcome, Bool) -> Void)?
        flow.actions.replace = { prompt, _, done in replaced.append(prompt); later = done }
        pres.close(); _ = paste(); pres.onAction(.build); spin(3) { !flow.isBuilding }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        pres.onAction(.insert); pres.onAction(.insert)
        t.check(replaced.count == flow2Replaced + 1, "Doppelklick auf „Einfügen“ → nur EIN Ersetzen", "\(replaced.count - flow2Replaced)")
        later?(.cleared, true)
        // Federzeit des Vorschlags
        t.check(APCard.offerRevealMs < 200 && APCard.offerRevealMs < Int(APCard.springReach(response: 0.5, damping: 0.78, target: 0.8) * 1000),
                "Vorschlag federt schneller auf (lesbar nach \(APCard.offerRevealMs) ms statt \(Int(APCard.springReach(response: 0.5, damping: 0.78, target: 0.8) * 1000)) ms)")
        flow.dictationStarted()
    }
}

// MARK: - Tempo: Einfügen → Vorschlags-Karte (offscreen gemessen)

extension APCLI {
    static func latency() -> Int32 {
        _ = NSApplication.shared
        func ms(_ block: () -> Void) -> Double { let t0 = Date(); block(); return Date().timeIntervalSince(t0) * 1000 }
        let texts = [APTestSet.longDE1, APTestSet.longDE2, APTestSet.longDE3, APTestSet.longDE4]
        let long = Array(repeating: APTestSet.longDE1, count: 5).joined(separator: " ")
        var det: [Double] = []
        for _ in 0..<5 { for s in texts + [long] { det.append(ms { _ = APDetector.detect(text: s, duration: 40, bundleID: APTestSet.vsc, title: "x") }) } }
        det.sort()
        // Karte aufbauen wie APCard.show (Modell, Illustration, SwiftUI-Host, Layout, erstes Bild) – unsichtbar
        func build() -> Double {
            ms {
                let d = APDetector.detect(text: APTestSet.longDE1, duration: 40, bundleID: APTestSet.vsc)
                let pill = NSRect(x: 560, y: 30, width: 66, height: 24), scr = NSRect(x: 0, y: 0, width: 1512, height: 949)
                let m = APCardModel(phase: .offer(d), geo: APGeo.make(pill: pill, visible: scr, frame: scr))
                m.ensureIllustration(.offer(d))
                let host = NSHostingView(rootView: APCardStage(model: m))
                host.frame = NSRect(origin: .zero, size: m.geo.windowFrame.size)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
            }
        }
        let cold = build()
        var warm: [Double] = []
        for _ in 0..<8 { warm.append(build()) }
        warm.sort()
        let oldReveal = APCard.springReach(response: APCard.cardSpring.response, damping: APCard.cardSpring.damping, target: 0.8) * 1000
        let oldClick = APCard.springReach(response: APCard.cardSpring.response, damping: APCard.cardSpring.damping, target: 0.9) * 1000
        let newReveal = Double(APCard.offerRevealMs), newClick = Double(APCard.offerClickableMs)
        let detMed = det[det.count / 2], detMax = det.last ?? 0, warmMed = warm[warm.count / 2]
        print(String(format: "Erkennung (APDetector, %d Läufe): Median %.1f ms, max %.1f ms (bis ~600 Wörter)", det.count, detMed, detMax))
        print(String(format: "Karte aufbauen offscreen: kalt %.0f ms, warm Median %.1f ms", cold, warmMed))
        print(String(format: "Einblenden bis lesbar (Feder): vorher %.0f ms (klickbar %.0f) · jetzt %.0f ms (klickbar %.0f)", oldReveal, oldClick, newReveal, newClick))
        let before = 700 + detMed + cold + oldReveal
        let after = warmMed + newReveal
        print(String(format: "VORHER  Einfügen → lesbar ≈ 700 (feste Pause) + Ziel/Markierung lesen (AX, Main) + %.0f Erkennung + %.0f Karte (kalt) + %.0f Einblenden ≈ %.0f ms + AX", detMed, cold, oldReveal, before))
        print(String(format: "NACHHER Einfügen → lesbar ≈ 0 Pause + 0 Erkennung (vorab im Hintergrund) + %.0f Karte (vorgeladen) + %.0f Einblenden ≈ %.0f ms", warmMed, newReveal, after))
        return after < 1000 ? 0 : 1
    }
}

private extension APRecord {
    /// So wie es nach dem Speichern gelesen wird (Kopfzeilen sind einzeilig)
    var withTitleOneLine: APRecord { var r = self; r.windowTitle = APStore.oneLine(r.windowTitle); return r }
}
