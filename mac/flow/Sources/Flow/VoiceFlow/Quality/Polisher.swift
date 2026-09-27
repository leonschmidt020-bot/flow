import Foundation
import NaturalLanguage

/// KI-Feinschliff-Ablauf (ersetzt den Rumpf von `TextCleaner.polish`):
///   Aus       → nur Schreibweisen vom Bildschirm (kein KI, keine Umformung)
///   Schnell   → Regeln (QuickPolish); braucht der Text mehr (Selbstkorrektur, Liste, Fehlstart), Apple Intelligence
///               mit 1,2 s Zeitlimit – sonst/danach gilt das Regel-Ergebnis. Standard.
///   Gründlich → wie Schnell, aber lange Texte (> 120 Wörter) oder ohne Apple Intelligence: Claude (~3–6 s).
/// Jede KI-Antwort muss den Wächter (`Polisher.accept`) passieren: keine neuen Wörter, nichts Wesentliches weg,
/// gleiche Sprache, Namen aus Wörterbuch/Bildschirm exakt erhalten. Sonst wird sie verworfen.
enum Polisher {
    struct Outcome: Sendable { let text: String; let engine: String; let ms: Int }

    /// Für Tests: Modus/Verfügbarkeit/Claude austauschbar
    nonisolated(unsafe) static var modeOverride: AIPolish?
    nonisolated(unsafe) static var fm: @Sendable (String, [String]) async -> (text: String, ms: Int)? = { await FMPolish.polish($0, terms: $1) }
    nonisolated(unsafe) static var fmAvailable: @Sendable () -> Bool = { FMPolish.available }
    nonisolated(unsafe) static var claude: @Sendable (String) async -> String? = { text in
        guard ClaudeCLI.isAvailable else { return nil }
        return try? await ClaudeCLI.run(system: FMPolish.instructions + "\nGib ausschließlich den bereinigten Text aus, ohne Anführungszeichen, ohne Tags, ohne Kommentar.",
                                        input: "<diktat>\(text)</diktat>", model: "haiku", timeout: 10)
    }
    static var longWords = 120

    /// Beschreibung für die Einstellungen (Aus / Schnell / Gründlich + ob Apple Intelligence da ist)
    static func statusLine(_ mode: AIPolish, short: Bool = false) -> String {
        let fm = FMPolish.available
        switch mode {
        case .off:
            return short ? "nur Regeln" : "Nur Füllwörter und Wörterbuch. Namen vom Bildschirm werden trotzdem richtig geschrieben."
        case .fast:
            if fm { return short ? "Apple Intelligence, unter 1 s" : "Apple Intelligence auf dem Mac: Selbstkorrekturen, Listen, Satzzeichen – unter 1 s, nichts verlässt den Mac." }
            return short ? "schnelle Regeln (Apple Intelligence ist aus)"
                : "Schnelle Regeln auf dem Mac: Selbstkorrekturen, Listen, Wiederholungen. Mit Apple Intelligence (Systemeinstellungen) geht mehr."
        case .thorough:
            if fm { return short ? "Claude ab 120 Wörtern" : "Lange Diktate (ab 120 Wörtern) prüft Claude (~3–6 s), kürzere Apple Intelligence." }
            return short ? "Claude, ~3–6 s" : "Claude prüft Diktate mit Selbstkorrektur, Liste oder Fehlstart (~3–6 s). Alles andere bleibt sofort."
        }
    }

    static func prewarm() {
        // Wortarten-Tagger für die Listen-Erkennung laden (erster Aufruf je Sprache ~60 ms)
        DispatchQueue.global(qos: .userInitiated).async { SmartLists.prewarm() }
        let mode = modeOverride ?? Settings.frozen.aiPolish
        guard mode != .off, fmAvailable() else { return }
        DispatchQueue.global(qos: .userInitiated).async { FMPolish.prewarm() }
    }

    /// Hook für TextCleaner.polish: nil = Text bleibt wie nach den Regeln
    static func polish(_ text: String) async -> String? {
        let o = await run(text, snapshot: ContextBoost.source())
        if o.engine != "unverändert" {
            log("Feinschliff: \(o.engine) in \(o.ms) ms" + (Settings.frozen.logTexts ? ": \(o.text)" : ""))
        }
        return o.text == text ? nil : o.text
    }

    /// `app` = Bundle-ID der Ziel-App (Listen-Form); nil = Bildschirm-Kontext bzw. App beim Fn-Druck
    static func run(_ text: String, snapshot: ScreenContext.Snapshot?, mode m: AIPolish? = nil, app: String? = nil) async -> Outcome {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        let mode = m ?? modeOverride ?? Settings.frozen.aiPolish
        guard !text.isEmpty else { return Outcome(text: text, engine: "unverändert", ms: 0) }
        let target = SmartLists.target(bundleID: app ?? SmartLists.currentBundle(snapshot))
        if mode == .off {
            // Keine Umformung – nur ausdrücklich gesagtes „als Liste“ / „keine Liste“ gilt
            let lp = SmartLists.pass(text, target: target, auto: false)
            let s = ContextBoost.fixTerms(lp.text, snapshot: snapshot)
            return Outcome(text: s, engine: s == text ? "unverändert" : (lp.hintUsed ? "liste" : "schreibweise"), ms: ms())
        }
        let rules = QuickPolish.apply(text, snapshot: snapshot, app: app)
        let needs = QuickPolish.needsAI(text)
        guard needs else {
            return Outcome(text: rules.text, engine: rules.report.changed ? "regeln" : "unverändert", ms: ms())
        }
        // Sprach-Hinweis („als Liste“) geht nicht an die KI – er gilt danach für deren Ergebnis
        let prep = SmartLists.stripHint(text)
        let hint: SmartLists.Hint = rules.report.listHints > 0 ? prep.hint : .none
        let aiText = rules.report.listHints > 0 ? prep.text : text
        let protected = ContextBoost.protectedTerms(snapshot).filter { t in text.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let fmOK = fmAvailable()
        if mode == .thorough, words > longWords || !fmOK {
            if let out = await claude(aiText) {
                let c = clean(out)
                if accept(input: aiText, output: c, protected: protected) {
                    return Outcome(text: finish(c, snapshot, target: target, hint: hint), engine: "claude", ms: ms())
                }
                log("Feinschliff: Claude-Antwort verworfen (Wächter)")
            }
        }
        if fmOK, words <= 900 {
            if let r = await fm(aiText, protected) {
                let c = clean(r.text)
                if accept(input: aiText, output: c, protected: protected) {
                    return Outcome(text: finish(c, snapshot, target: target, hint: hint), engine: "apple", ms: ms())
                }
                log("Feinschliff: Apple-Intelligence-Antwort verworfen (Wächter)")
            } else {
                log("Feinschliff: Apple Intelligence zu langsam/fehlgeschlagen → Regeln")
            }
        }
        return Outcome(text: rules.text, engine: rules.report.changed ? "regeln" : "unverändert", ms: ms())
    }

    /// KI-Ergebnis nachbearbeiten: Schreibweisen vom Bildschirm, Abstände/Großschreibung
    private static func finish(_ s: String, _ snap: ScreenContext.Snapshot?, target: SmartLists.Target, hint: SmartLists.Hint) -> String {
        // Hat die KI eine Aufzählung nicht als Liste gesetzt, machen es die Regeln (in der Form der Ziel-App)
        var listed = s
        if hint != .suppress {
            let (a, n) = QuickPolish.formatLists(s)
            listed = n > 0 ? a : SmartLists.format(s, hint: hint, target: target).0
        }
        return TextCleaner.tidy(ContextBoost.fixTerms(listed, snapshot: snap))
    }

    static func clean(_ out: String) -> String {
        var s = out.replacingOccurrences(of: "</?diktat>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        for (a, b) in [("\"", "\""), ("„", "“"), ("“", "”"), ("«", "»")] where s.hasPrefix(a) && s.hasSuffix(b) && s.count > 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: Wächter

    private static func contentWords(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_@")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Darf die KI-Fassung den Text ersetzen?
    static func accept(input: String, output: String, protected: [String]) -> Bool {
        guard !output.isEmpty else { return false }
        let ratio = Double(output.count) / Double(max(1, input.count))
        if ratio > 1.35 || ratio < 0.3 { return false }
        let inW = contentWords(input), outW = contentWords(output)
        let inSet = Set(inW)
        // Neue Wörter? (Zahlen für Listen „1.“ und Ziffern statt Zahlwort erlaubt; leichte Abwandlung erlaubt)
        let novel = outW.filter { w in
            if inSet.contains(w) || w.allSatisfy(\.isNumber) { return false }
            if w.count >= 4, inSet.contains(where: { $0.count >= 4 && ($0.hasPrefix(w) || w.hasPrefix($0) || VocabTrigger.levenshtein(Array($0), Array(w)) <= 1) }) { return false }
            return true
        }
        if novel.count > (inW.count >= 25 ? 1 : 0) { return false }
        // Wörter weg: nur so viele, wie Selbstkorrektur/Wiederholung/Liste erklären (+1 Füllwort)
        let dropped = max(0, inW.count - outW.filter { inSet.contains($0) }.count)
        if dropped > removable(input) { return false }
        // Namen exakt
        for p in protected where input.contains(p) && !output.contains(p) { return false }
        // Sprache gleich
        if inW.count >= 6, let a = dominant(input), let b = dominant(output), a != b { return false }
        return true
    }

    /// Höchstens so viele Wörter darf eine KI-Fassung weglassen: was die Regeln selbst streichen, plus je Korrektur-Stelle
    /// alles vom Satzanfang bis zum Marker (bei „streich das“ der ganze Satz davor), plus Listen-Wörter.
    static func removable(_ input: String) -> Int {
        let rulesOut = QuickPolish.apply(input).text
        var n = max(0, contentWords(input).count - contentWords(rulesOut).count)
        let t = QuickPolish.tokens(input)
        var from = 1
        while let mk = QuickPolish.findMarker(t, from: from) {
            var start = mk.lo - 1
            var sentences = mk.kind == .deletePrevious ? 2 : 1
            while start > 0 {
                if let c = t[start - 1].text.last, ".!?".contains(c) { sentences -= 1; if sentences == 0 { break } }
                start -= 1
            }
            n = max(n, mk.hi - max(0, start))
            from = mk.hi
        }
        // kein Freibetrag: Füllwörter hat TextCleaner.applyRules schon vorher entfernt („Nein, warte kurz …“ darf nicht zu „Warte kurz …“ werden)
        return n + QuickPolish.listMarkers(input).count * 2
    }

    private static func dominant(_ s: String) -> NLLanguage? {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english]
        r.processString(s)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.8 else { return nil }
        return lang
    }
}
