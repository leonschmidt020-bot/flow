import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Lernt aus deinen Korrekturen: Nach dem Einfügen liest Flow (per Bedienungshilfen) das Textfeld mit.
/// Tauschst du darin ein, zwei Wörter aus (z. B. „ID“ → „Lidl“), wird das ins Wörterbuch übernommen
/// und Whisper bekommt es künftig als Hinweis.
///
/// Ablauf (1.7.15):
/// 1. Nach dem Einfügen die Stelle merken (`Anchor`): im Textfeld, in der Eingabebox von Claude Code oder in den
///    Terminal-Zeilen (xterm.js in VS Code & Co. – `TerminalPrompt`).
/// 2. Alle 1,5 s nachlesen und vergleichen (`reading`), entscheiden in `Tracker.step`.
/// 3. Fragen, wenn dieselbe Änderung drei Runden steht – oder sofort, wenn die Bearbeitung vorbei ist: Nachricht
///    abgeschickt (Claude Code: der Text steht jetzt als „❯ …“ im Verlauf), neues Diktat (`finish`), Text weg, 3 Min. um.
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    /// Wird mit erkannten Korrekturen aufgerufen → Pille fragt „merken?“.
    /// Ein erkannter Verhörer mit Vorschlägen (erster = was du zuletzt geschrieben hast)
    struct Suggestion { let old: String; var options: [String] }
    var onCandidate: (([Suggestion]) -> Void)?
    /// In dieser Sitzung abgelehnte Paare nicht nochmal fragen
    var rejected: Set<String> = []

    typealias Pair = (old: String, new: String)

    /// Wo der diktierte Text beim Einfügen stand
    enum Place: String { case field = "Textfeld", input = "Claude-Code-Eingabe", screen = "Terminal-Zeilen" }

    /// Was beim Einfügen gemerkt wird
    struct Anchor {
        let inserted: String
        let place: Place
        /// Je 3 Wörter, die beim Einfügen direkt vor/nach dem Text standen (im Feld, in der Box bzw. auf dem Bildschirm)
        let pre: [String]
        let post: [String]
        /// Nachrichten, die beim Einfügen schon im Verlauf standen – die neu abgeschickte ist keine davon
        var sentBefore: Set<String> = []
    }

    enum AnchorResult { case found(Anchor), sentAlready, notFound(score: Int) }

    /// Ein Vergleich mit dem eingefügten Text: welche Wörter sind ersetzt, steht er schon im Verlauf (abgeschickt)?
    struct Reading { var pairs: [Pair]; var sent: Bool }

    private enum Source { case field, xterm, window }

    private struct Session {
        let pid: pid_t
        /// Textfeld · Zeilen-Liste des xterm-Terminals · App (ganzer Fensterinhalt)
        var element: AXUIElement
        let source: Source
        let anchor: Anchor
        let appName: String
        let bundle: String
        let started: Date
        /// zu welchem watch() die Sitzung gehört (Audit 27.09.2026)
        var gen = 0
        var tracker = Tracker()
        var asked = false
    }

    private var session: Session?          // nur auf learnQueue lesen/schreiben
    private var timer: Timer?
    /// Audit 27.09.2026: zählt jedes stop()/watch() hoch (nur Main-Thread). Alte attempt()-Ketten aus einem früheren
    /// watch() liefen weiter und legten einen zweiten 1,5-s-Timer an, der nie mehr gestoppt wurde.
    private var generation = 0
    /// Mitlesen & Vergleichen im Hintergrund – der Main-Thread (Fn-Taste, Pille) bleibt frei
    private let learnQueue = DispatchQueue(label: "flow.learn", qos: .utility)

    /// Terminals: Text steht in den sichtbaren Zeilen, nicht im Eingabefeld
    static let terminalApps: Set<String> = ["com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2",
                                            "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.todesktop.230313mzl4w4u92",
                                            "com.exafunction.windsurf", "com.google.antigravity", "com.microsoft.VSCodeInsiders",
                                            "com.vscodium"]
    /// Hier wird nie mitgelesen (Passwörter)
    static let blockedApps: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                                           "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal"]

    /// Direkt nach dem Einfügen aufrufen.
    func watch(inserted: String) {
        stop()
        let gen = generation
        guard AXIsProcessTrusted() else { log("Lernen: aus – Bedienungshilfen fehlen (Systemeinstellungen › Datenschutz › Bedienungshilfen)"); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { log("Lernen: keine App im Vordergrund"); return }
        let bundle = app.bundleIdentifier ?? ""
        if CorrectionLearner.blockedApps.contains(bundle) { log("Lernen: übersprungen (Passwort-App)"); return }
        if IsSecureEventInputEnabled() { log("Lernen: übersprungen (sichere Eingabe aktiv)"); return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"
        // Audit 27.09.2026 (Lerner-Fix): Chromium/Electron-Baum NUR über ScreenContext an-/ausschalten. Vorher schaltete der
        // Lerner ihn beim nächsten Fn-Druck selbst aus und ScreenContext 60 s nach dem Fn-Druck – mitten in der
        // 3-Minuten-Beobachtung. Danach lieferte VS Code 0 Fenster/0 Knoten → „keine Änderung gesehen“.
        ScreenContext.shared.enableAX(pid)
        // Chrome & Co. (kein Electron): Webseiten-Felder erst mit AXEnhancedUserInterface (wie beim Maus-Ziel, 60 s, dann zurück)
        MouseTarget.shared.enableWebAX(pid: pid, bundle: bundle)
        let ins = CorrectionLearner.norm(inserted)
        let insWords = CorrectionLearner.words(ins)
        // Auch einzelne Wörter: dann wird die Stelle über die Wörter davor/danach wiedergefunden
        guard !insWords.isEmpty else { log("Lernen: übersprungen (kein Wort)"); return }
        let isTerminal = CorrectionLearner.terminalApps.contains(bundle)
        var tries = 0
        var sawElement = false
        // Bis zu 4 s nachsehen – Terminals (Claude Code) zeichnen den eingefügten Text erst verzögert
        func attempt() {
            guard gen == self.generation else { return }   // inzwischen neues Diktat/stop() → diese Kette beenden
            tries += 1
            let el = CorrectionLearner.focusedElement()
            // Passwortfelder nie lesen
            if let el, CorrectionLearner.isSecure(el) { log("Lernen: Passwortfeld – übersprungen"); return }
            if el != nil { sawElement = true }
            // Lesen im Hintergrund (ein Terminal sind ~200 Bedienungshilfen-Abfragen)
            learnQueue.async {
                let found = CorrectionLearner.locateInsert(ins, pid: pid, focused: el, terminal: isTerminal)
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    switch found.result {
                    case .found(let a):
                        log("Lernen: beobachte \(name)\(a.place == .field ? "" : " (\(a.place.rawValue))")")
                        let s = Session(pid: pid, element: found.element ?? AXUIElementCreateApplication(pid), source: found.source,
                                        anchor: a, appName: name, bundle: bundle, started: Date(), gen: gen)
                        self.learnQueue.async { self.session = s }
                        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                            guard let self else { return }
                            self.learnQueue.async { self.poll() }
                        }
                        self.timer?.invalidate()
                        RunLoop.main.add(t, forMode: .common)
                        self.timer = t
                    case .sentAlready:
                        log("Lernen: Text schon abgeschickt – nichts zu beobachten")
                    case .notFound(let score):
                        if tries < 8 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt); return }
                        if !sawElement && found.source == .field { log("Lernen: kein Textfeld lesbar in \(name) (\(bundle))"); return }
                        log("Lernen: Text nicht gefunden in \(name) (bester Treffer \(score)/\(insWords.count) Wörter)"
                            + (found.collapsed ? " – Claude Code zeigt ihn eingeklappt („[Pasted text …]“), dort nicht lesbar" : ""))
                        if bundle == VSCodeAccessibility.bundleID, score == 0, found.chars < 20 { VSCodeAccessibility.offerIfNeeded() }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: attempt)
    }

    /// Wo steht der eingefügte Text? Erst im fokussierten Feld, im Terminal dann in den xterm-Zeilen (Claude-Code-Box),
    /// sonst im ganzen Fensterinhalt. (learnQueue)
    private static func locateInsert(_ ins: String, pid: pid_t, focused el: AXUIElement?, terminal: Bool)
        -> (result: AnchorResult, source: Source, element: AXUIElement?, collapsed: Bool, chars: Int) {
        let field = TerminalPrompt.Screen(all: norm(el.flatMap { value(of: $0) } ?? ""))
        let inField = anchor(inserted: ins, in: field, fieldMode: true)
        if case .found = inField { return (inField, .field, el, false, field.all.count) }
        // Chromium-contenteditable: fokussiert ist oft nur ein Absatz darin → das ganze bearbeitbare Feld nehmen
        if let el, let root = editableRoot(el), !isSecure(root), let v = value(of: root) {
            let r = anchor(inserted: ins, in: TerminalPrompt.Screen(all: norm(v)), fieldMode: true)
            if case .found = r { return (r, .field, root, false, v.count) }
        }
        guard terminal else { return (inField, .field, el, false, field.all.count) }
        let known = Set(words(ins).map { bare($0).lowercased() })
        if let t = TerminalPrompt.read(pid: pid, from: el) {
            let s = TerminalPrompt.parse(t.rows, known: known)
            return (anchor(inserted: ins, in: s, fieldMode: false), .xterm, t.tree, s.collapsed, s.all.count)
        }
        // Andere Terminals (Warp, Ghostty …): alle sichtbaren Texte des Fensters wie bisher
        let s = TerminalPrompt.Screen(all: norm(screenText(pid: pid)))
        return (anchor(inserted: ins, in: s, fieldMode: false), .window, AXUIElementCreateApplication(pid), false, s.all.count)
    }

    /// Wörter (Original-Schreibweise) ohne reine Satzzeichen-/Symbol-Tokens wie „❯“ oder „│“.
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    // MARK: Stelle merken & vergleichen (reine Logik, im Selbsttest geprüft)

    /// Sucht das Diktat vollständig in einem gelesenen Stand und merkt die Grenzen.
    /// Mit Claude-Code-Box zählt nur die Box; steht der Text dort nicht, aber im Verlauf, ist er schon abgeschickt.
    static func anchor(inserted: String, in s: TerminalPrompt.Screen, fieldMode: Bool) -> AnchorResult {
        let insW = words(inserted)
        func exact(_ text: String) -> (lo: Int, hi: Int, w: [String])? {
            let w = words(text)
            guard let f = locate(insW, in: w), f.score == insW.count else { return nil }
            return (f.lo, f.hi, w)
        }
        func bounds(_ e: (lo: Int, hi: Int, w: [String])) -> (pre: [String], post: [String]) {
            let l = e.w.map { bare($0).lowercased() }
            return (Array(l[max(0, e.lo - 3)..<e.lo]), Array(l[e.hi..<min(l.count, e.hi + 3)]))
        }
        if let inp = s.input {
            if let e = exact(inp) {
                let b = bounds(e)
                return .found(Anchor(inserted: inserted, place: .input, pre: b.pre, post: b.post, sentBefore: Set(s.sent)))
            }
            if s.sent.contains(where: { exact($0) != nil }) { return .sentAlready }
            return .notFound(score: locate(insW, in: words(inp))?.score ?? 0)
        }
        if let e = exact(s.all) {
            let b = bounds(e)
            return .found(Anchor(inserted: inserted, place: fieldMode ? .field : .screen, pre: b.pre, post: b.post))
        }
        return .notFound(score: locate(insW, in: words(s.all))?.score ?? 0)
    }

    /// Ersetzte Wörter im Stand `s` gegenüber dem Eingefügten. nil = Text (so) nicht mehr zu sehen.
    /// Claude Code: erst die Box; ist sie leer, die NEU abgeschickte Nachricht im Verlauf (dann `sent`).
    static func reading(_ a: Anchor, _ s: TerminalPrompt.Screen) -> Reading? {
        switch a.place {
        case .input:
            if let inp = s.input, let p = pairs(a, in: inp) { return Reading(pairs: p, sent: false) }
            for m in s.sent.reversed() where !a.sentBefore.contains(m) {
                if let p = pairs(a, in: m) { return Reading(pairs: p, sent: true) }
            }
            return nil
        case .field, .screen:
            return pairs(a, in: s.all).map { Reading(pairs: $0, sent: false) }
        }
    }

    static func pairs(_ a: Anchor, in text: String) -> [Pair]? {
        let insW = words(a.inserted), w = words(text)
        // Ein einzelnes Wort findet sich nach dem Ändern nicht mehr selbst → über die Nachbarwörter verankern
        let region: [String]? = insW.count == 1
            ? regionBetween(pre: a.pre, post: a.post, in: w)
            : locate(insW, in: w, pre: a.pre, post: a.post)?.words
        guard let region else { return nil }
        return replacements(from: a.inserted, to: region.joined(separator: " "))
    }

    /// Entscheidet über eine Folge von Lesungen, wann gefragt wird (reine Logik).
    /// Stabil = DIESELBE Änderung drei Runden hintereinander (der restliche Bildschirm darf sich ändern). Ist die
    /// Bearbeitung vorbei (abgeschickt, neues Diktat, Zeit um), zählt der letzte Stand sofort.
    struct Tracker {
        private(set) var candidate: [String] = []   // „alt\u{1}neu“
        private(set) var stable = 0
        private(set) var learned: Set<String> = []
        /// Alle Schreibweisen, die für ein Wort unterwegs zu sehen waren (Zwischenstände beim Tippen)
        private(set) var seen: [String: [String]] = [:]
        private(set) var everSaw = false
        private(set) var reads = 0, unreadable = 0, gone = 0
        /// Protokollzeilen dieses Schritts (ohne Inhalt)
        private(set) var notes: [String] = []

        struct Step {
            var ask: [Pair] = []
            var grammarOnly = false
            /// Grund, die Beobachtung zu beenden (nil = weiter beobachten)
            var end: String?
        }

        /// `r` nil = Text nicht gefunden · `readable` false = gar nichts lesbar · `final` = Bearbeitung ist vorbei
        mutating func step(_ r: Reading?, readable: Bool = true, final: Bool = false) -> Step {
            notes = []
            reads += 1
            guard readable else {
                unreadable += 1
                if final { var out = emit(); out.end = "vorbei"; return out }
                return Step()
            }
            guard let r else {
                gone += 1
                // Text weg (Chat abgeschickt, Box geleert, weggescrollt): eine Änderung, die schon stand, gilt
                if !candidate.isEmpty, stable >= 1 || final { var out = emit(); out.end = "Text nicht mehr da"; return out }
                var out = Step()
                if final { out.end = "vorbei" } else if gone >= 20 { out.end = "Text nicht mehr da" }
                return out
            }
            gone = 0
            let now = r.pairs.map { "\($0.old)\u{1}\($0.new)" }
            if !now.isEmpty { everSaw = true }
            for c in now {
                let p = c.components(separatedBy: "\u{1}")
                var v = seen[p[0], default: []]
                v.removeAll { $0 == p[1] }; v.insert(p[1], at: 0)
                seen[p[0]] = v
            }
            if !now.isEmpty && now == candidate { stable += 1 }
            else {
                if now != candidate && !now.isEmpty && !now.allSatisfy({ learned.contains($0) }) { notes.append("Änderung gesehen (\(now.count))") }
                candidate = now; stable = 0
            }
            var out = Step()
            if !candidate.isEmpty, r.sent || final || stable >= 2 { out = emit() }
            if r.sent { out.end = "abgeschickt" } else if final { out.end = "vorbei" }
            return out
        }

        private mutating func emit() -> Step {
            var out = Step()
            let fresh = candidate.filter { !learned.contains($0) }
            candidate = []; stable = 0
            guard !fresh.isEmpty else { return out }
            fresh.forEach { learned.insert($0) }
            out.ask = fresh.map { c -> Pair in
                let p = c.components(separatedBy: "\u{1}"); return (p[0], p[1])
            }.filter { CorrectionLearner.shouldLearn(old: $0.old, new: $0.new) }
            out.grammarOnly = out.ask.isEmpty
            return out
        }
    }

    /// Sucht im Bildschirm-/Feldtext die Stelle, die dem eingefügten Text am besten entspricht (wortweise, von hinten).
    /// Gibt die passenden Wörter zurück – inkl. geänderter Wörter am Anfang/Ende – und wie viele Wörter unverändert sind.
    static func locate(_ ins: [String], in scr: [String], pre: [String] = [], post: [String] = []) -> (words: [String], score: Int, lo: Int, hi: Int)? {
        let m = ins.count
        guard m > 0, !scr.isEmpty else { return nil }
        let a = ins.map { bare($0).lowercased() }, b = scr.map { bare($0).lowercased() }
        let heads = Set(a.prefix(3))
        var best: (score: Int, lo: Int, hi: Int)?
        var i = b.count - 1
        var checked = 0
        while i >= 0 && checked < 400 {
            if heads.contains(b[i]) {
                checked += 1
                let hi = min(b.count, i + m + 6)
                let win = Array(b[i..<hi])
                // LCS mit Rückverfolgung: erster/letzter Treffer (Index in a und in win)
                var dp = [[Int]](repeating: [Int](repeating: 0, count: win.count + 1), count: m + 1)
                for x in stride(from: m - 1, through: 0, by: -1) {
                    for y in stride(from: win.count - 1, through: 0, by: -1) {
                        dp[x][y] = a[x] == win[y] ? dp[x + 1][y + 1] + 1 : max(dp[x + 1][y], dp[x][y + 1])
                    }
                }
                let score = dp[0][0]
                if score > 0, best == nil || score > best!.score {
                    var x = 0, y = 0
                    var firstA = -1, firstW = -1, lastA = -1, lastW = -1
                    while x < m && y < win.count {
                        if a[x] == win[y] { if firstA < 0 { firstA = x; firstW = y }; lastA = x; lastW = y; x += 1; y += 1 }
                        else if dp[x + 1][y] >= dp[x][y + 1] { x += 1 } else { y += 1 }
                    }
                    // Geänderte Wörter vor dem ersten / nach dem letzten Treffer mitnehmen –
                    // aber nie über den Text hinaus, der beim Einfügen davor/danach stand
                    // (sonst wird aus „West gelöscht“ fälschlich „West → Modell“ aus der Statuszeile).
                    var lo = i + firstW
                    for _ in 0..<firstA {
                        guard lo - 1 >= 0 else { break }
                        if let p = pre.last, b[lo - 1] == p { break }
                        lo -= 1
                    }
                    var hiIdx = i + lastW + 1
                    for _ in 0..<(m - 1 - lastA) {
                        guard hiIdx < b.count else { break }
                        if let p = post.first, b[hiIdx] == p { break }
                        hiIdx += 1
                    }
                    best = (score, lo, hiIdx)
                    if score == m { break }
                }
            }
            i -= 1
        }
        guard let bb = best, Double(bb.score) >= Double(m) * 0.6, bb.lo < bb.hi else { return nil }
        return (Array(scr[bb.lo..<bb.hi]), bb.score, bb.lo, bb.hi)
    }

    /// Beobachtung abbrechen (ohne letzten Vergleich)
    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        learnQueue.async { self.session = nil }
    }

    /// Neues Diktat beginnt: du bist mit dem Korrigieren fertig → ein letztes Mal lesen und vergleichen, dann beenden.
    /// (Vorher wurde die Sitzung hier einfach verworfen – eine Korrektur kurz vor dem nächsten Diktat ging verloren.)
    func finish() {
        generation += 1
        timer?.invalidate(); timer = nil
        learnQueue.async {
            guard self.session != nil else { return }
            self.poll(final: true)
            self.session = nil
        }
    }

    /// learnQueue. `final` = Bearbeitung ist vorbei (neues Diktat).
    private func poll(final: Bool = false) {
        // Audit 27.09.2026: poll() läuft auf learnQueue – stop() (Timer) gehört auf den Main-Thread,
        // und nur, wenn noch dieselbe Sitzung aktiv ist (sonst würde eine NEUE Sitzung beendet).
        guard var s = session else { return }
        let timeUp = Date().timeIntervalSince(s.started) > 180
        if !final && !timeUp {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == s.pid else { return }  // kurz woanders → abwarten
            if IsSecureEventInputEnabled() { return }                                                // Passwort-Eingabe → nicht lesen
        }
        ScreenContext.shared.enableAX(s.pid)   // Baum an lassen, solange beobachtet wird (ScreenContext stellt 60 s danach zurück)
        MouseTarget.shared.enableWebAX(pid: s.pid, bundle: s.bundle)
        let (screen, readable) = read(&s)
        let r = readable ? CorrectionLearner.reading(s.anchor, screen) : nil
        let step = s.tracker.step(r, readable: readable, final: final || timeUp)
        for n in s.tracker.notes { log("Lernen: \(n)") }
        if step.grammarOnly { log("Lernen: Änderung ist nur Grammatik/Groß-klein – nicht gefragt") }
        if !step.ask.isEmpty {
            s.asked = true
            let pairs = step.ask, seen = s.tracker.seen
            DispatchQueue.main.async {
                let open = pairs.filter { !self.rejected.contains("\($0.old)\u{1}\($0.new)") }
                guard !open.isEmpty else { return }
                log("Lernen: erkannt \(open.count) Korrektur(en)")
                self.onCandidate?(open.map { Suggestion(old: $0.old, options: CorrectionLearner.options(old: $0.old, new: $0.new, seen: seen[$0.old] ?? [])) })
            }
        }
        guard let end = step.end else { session = s; return }
        let t = s.tracker
        let what = s.asked ? "gefragt" : (t.everSaw ? "Änderung gesehen, aber nicht stabil" : "keine Änderung gesehen")
        let stats = " (\(t.reads) Lesungen\(t.unreadable > 0 ? ", \(t.unreadable) ohne Text – Bedienungshilfen aus?" : ""))"
        switch end {
        case "abgeschickt": log("Lernen: abgeschickt – gesendete Fassung verglichen, \(what)")
        case "Text nicht mehr da": log("Lernen: Text nicht mehr da – \(what)\(stats)")
        default: log("Lernen: Sitzung beendet \(timeUp && !final ? "nach 3 Min." : "(neues Diktat)") – \(what)\(stats)")
        }
        session = nil
        if !final {
            let g = s.gen
            DispatchQueue.main.async { if g == self.generation { self.stop() } }
        }
    }

    /// Aktuellen Stand lesen (learnQueue). readable = false, wenn gar nichts kam (Bedienungshilfen aus, Fenster weg).
    private func read(_ s: inout Session) -> (TerminalPrompt.Screen, Bool) {
        switch s.source {
        case .xterm:
            let known = Set(CorrectionLearner.words(s.anchor.inserted).map { CorrectionLearner.bare($0).lowercased() })
            var rows = TerminalPrompt.rows(of: s.element)
            if rows?.isEmpty ?? true, let t = TerminalPrompt.read(pid: s.pid, from: nil) { s.element = t.tree; rows = t.rows }   // Baum neu aufgebaut
            guard let rows, rows.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return (TerminalPrompt.Screen(), false) }
            return (TerminalPrompt.parse(rows, known: known), true)
        case .window:
            let t = CorrectionLearner.norm(CorrectionLearner.screenText(pid: s.pid))
            return (TerminalPrompt.Screen(all: t), !t.isEmpty)
        case .field:
            var v = CorrectionLearner.value(of: s.element)
            // Chromium/React bauen das Feld beim Tippen manchmal neu → dann das jetzt fokussierte Feld derselben App
            if v == nil, let f0 = CorrectionLearner.focusedElement(pid: s.pid) {
                let f = CorrectionLearner.editableRoot(f0) ?? f0
                if !CorrectionLearner.isSecure(f0), !CorrectionLearner.isSecure(f), let fv = CorrectionLearner.value(of: f) { s.element = f; v = fv }
            }
            return (TerminalPrompt.Screen(all: CorrectionLearner.norm(v ?? "")), v != nil)
        }
    }


    /// Wörter zwischen dem Text davor (pre) und danach (post) – für Diktate aus einem einzigen Wort.
    /// Liefert 1–3 Wörter oder nil, wenn die Stelle nicht eindeutig ist.
    static func regionBetween(pre: [String], post: [String], in scr: [String]) -> [String]? {
        let b = scr.map { bare($0).lowercased() }
        let p = Array(pre.suffix(2)), q = Array(post.prefix(2))
        guard !p.isEmpty || !q.isEmpty else { return scr.count <= 3 && !scr.isEmpty ? scr : nil }
        var start = 0
        if !p.isEmpty {
            guard b.count >= p.count, let j = stride(from: b.count - p.count, through: 0, by: -1)
                .first(where: { Array(b[$0..<$0 + p.count]) == p }) else { return nil }
            start = j + p.count
        }
        var end = b.count
        if !q.isEmpty {
            guard let k = (start..<max(start, b.count - q.count + 1)).first(where: { Array(b[$0..<$0 + q.count]) == q }) else { return nil }
            end = k
        } else {
            end = min(b.count, start + 2)       // Wort stand am Ende: höchstens 2 Wörter anschauen (z. B. „auch fixen“)
        }
        guard end > start, end - start <= 3 else { return nil }
        return Array(scr[start..<end])
    }

    // MARK: Vorschläge

    /// Bis zu 3 Vorschläge: zuletzt Geschriebenes, dann Zwischenstände, dann Rechtschreib-Vorschläge
    /// (z. B. „auffixen“ → „auch fixen“ · „auch“ · „auf fixen“).
    static func options(old: String, new: String, seen: [String]) -> [String] {
        var out = [new]
        func add(_ o: String) {
            let t = o.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.lowercased() != old.lowercased(), !out.contains(where: { $0.lowercased() == t.lowercased() }),
                  t.contains(where: { $0.isLetter }) else { return }
            out.append(t)
        }
        for v in seen where v != new {
            // Halb getippte Zwischenstände („auch f“) nicht anbieten
            if new.lowercased().hasPrefix(v.lowercased()) && v.count < new.count && !new.lowercased().hasPrefix(v.lowercased() + " ") { continue }
            add(v)
        }
        if out.count < 3, !old.contains(" ") {
            let checker = NSSpellChecker.shared
            let r = NSRange(location: 0, length: (old as NSString).length)
            for lang in ["de", "en"] {
                for g in checker.guesses(forWordRange: r, in: old, language: lang, inSpellDocumentWithTag: 0) ?? [] { add(g) }
            }
        }
        return Array(out.prefix(3))
    }

    // MARK: Wörterbuch

    static func remember(old: String, new: String) {
        let st = Settings.shared
        // Echtes Wort (z. B. „ID“, „Legal“) → nur als Hinweis für Whisper, nicht blind ersetzen.
        let single = !old.contains(" ")
        let vocabOnly = single && isRealWord(old)
        if let i = st.dictionary.firstIndex(where: { $0.heard.lowercased() == old.lowercased() }) {
            st.dictionary[i].write = new
            st.dictionary[i].learned = true
            st.dictionary[i].vocabOnly = vocabOnly
        } else {
            st.dictionary.append(DictEntry(heard: old, write: new, learned: true, vocabOnly: vocabOnly))
        }
        log("Gelernt: „\(old)“ → „\(new)“\(vocabOnly ? " (nur Hinweis)" : "")")
        PartnerVocab.shared.learned(new, source: .correction)   // nur das Wort, nie der Verhörer
    }

    /// Grammatik-Korrekturen („zur“ → „zu“, „ich“ → „Ich“, „gehe“ → „gehen“) sind keine Hörfehler → nicht lernen.
    /// Echtes Wort durch ein ANDERES echtes Wort („sehen“ → „gehen“, „Zeilen“ → „Teilen“) ist ein Verhörer → fragen.
    /// (Bis 1.7.14 galt jedes kleingeschriebene echte Ersatzwort als Grammatik – so wurden am 26.09. alle drei im Terminal
    /// gesehenen Korrekturen verworfen: „Änderung ist nur Grammatik/Groß-klein“.)
    static func shouldLearn(old: String, new: String) -> Bool {
        // Nur Groß/klein: am Wortanfang = Grammatik („ich“ → „Ich“), im Wort = Schreibweise eines Namens („Github“ → „GitHub“)
        if old.lowercased() == new.lowercased() { return old.dropFirst() != new.dropFirst() }
        let oneWord = !old.contains(" ") && !new.contains(" ")
        guard oneWord, isRealWord(old), isRealWord(new) else { return true }
        let o = old.lowercased(), n = new.lowercased()
        // Artikel, Präpositionen, Pronomen … untereinander getauscht („zur“ → „zu“, „das“ → „dass“, „den“ → „dem“)
        if functionWords.contains(o) && functionWords.contains(n) { return false }
        // Gleicher Wortstamm, nur die Endung anders („gehe“ → „gehen“, „Haus“ → „Hause“)
        if sameStem(o, n) { return false }
        return true
    }

    /// Kleine Wörter, die beim Korrigieren meist nur grammatisch getauscht werden
    static let functionWords = Set<String>([   // Array → Set: doppelte Einträge (DE/EN) sind erlaubt
        "der", "die", "das", "dass", "dem", "den", "des", "ein", "eine", "einer", "einem", "einen", "eines", "kein", "keine", "keinen",
        "zu", "zur", "zum", "im", "in", "ins", "am", "an", "ans", "auf", "aus", "bei", "beim", "mit", "nach", "von", "vom", "vor", "für",
        "über", "unter", "um", "ob", "wenn", "als", "wie", "so", "und", "oder", "aber", "doch", "ja", "nein", "nicht", "noch", "schon",
        "auch", "nur", "mal", "da", "dann", "denn", "ich", "du", "er", "sie", "es", "wir", "ihr", "mich", "mir", "dich", "dir", "sich",
        "uns", "euch", "ihn", "ihm", "ihnen", "sein", "seine", "seinen", "ihre", "ihren", "mein", "meine", "meinen", "dein", "deine",
        "ist", "sind", "war", "bin", "bist", "hat", "habe", "hast", "haben", "wird", "werden", "kann", "können", "muss", "müssen",
        "soll", "will", "wo", "was", "wer", "hier", "dort", "the", "a", "an", "to", "of", "on", "at", "for", "is", "are", "was", "it",
        "this", "that", "and", "or", "but", "in", "i", "you", "he", "she", "we", "they", "be", "have", "has", "do", "does"])

    /// Gleicher Anfang (≥ 3 Buchstaben), Rest nur eine übliche Endung
    static func sameStem(_ a: String, _ b: String) -> Bool {
        let p = zip(a, b).prefix(while: { $0 == $1 }).count
        guard p >= 3 else { return false }
        let endings: Set<String> = ["", "e", "en", "er", "es", "em", "n", "s", "st", "t", "et", "est", "ern", "ens", "te", "ten", "d", "ed", "ing"]
        return endings.contains(String(a.dropFirst(p))) && endings.contains(String(b.dropFirst(p)))
    }

    private static func isRealWord(_ w: String) -> Bool {
        let checker = NSSpellChecker.shared
        for lang in ["de", "en"] {
            let r = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound { return true }
        }
        return false
    }

    // MARK: Textvergleich

    /// Bereich im neuen Feldinhalt, der dem eingefügten Text entspricht (über den Text davor/danach verankert).
    static func region(in value: String, pre: String, post: String) -> String? {
        var start = value.startIndex
        if !pre.isEmpty {
            guard let r = value.range(of: pre, options: .backwards) ?? value.range(of: String(pre.suffix(10)), options: .backwards) else { return nil }
            start = r.upperBound
        }
        var end = value.endIndex
        if !post.isEmpty {
            guard let r = value.range(of: post, range: start..<value.endIndex) ?? value.range(of: String(post.prefix(10)), range: start..<value.endIndex) else { return nil }
            end = r.lowerBound
        }
        return String(value[start..<end])
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    static func bare(_ w: String) -> String { w.trimmingCharacters(in: .punctuationCharacters) }

    /// Wort-Diff: welche 1–3 Wörter wurden durch welche 1–3 Wörter ersetzt?
    static func replacements(from a: String, to b: String) -> [(old: String, new: String)] {
        let x = tokens(a).map(bare), y = tokens(b).map(bare)
        guard !x.isEmpty, !y.isEmpty else { return [] }
        // LCS-Tabelle (auf Kleinbuchstaben, damit reine Groß/klein-Änderungen als Ersetzung erkannt werden)
        let xl = x.map { $0.lowercased() }, yl = y.map { $0.lowercased() }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                dp[i][j] = (x[i] == y[j]) ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        _ = xl; _ = yl
        var i = 0, j = 0
        var out: [(String, String)] = []
        var delBuf: [String] = [], insBuf: [String] = []
        var changed = 0
        func flush() {
            if !delBuf.isEmpty && !insBuf.isEmpty && delBuf.count <= 3 && insBuf.count <= 3 {
                // Gleich viele Wörter → einzeln zuordnen („zur Legal“ → „zu Lidl“ = zwei Paare)
                // Gleich viele Wörter: nur aufteilen, wenn ein Teil bloß Grammatik ist („zur Legal“ → „zu Lidl“).
                // Sonst als Ganzes lernen („Whisper Floor“ → „Flow“ ist ein Name).
                let whole = [(delBuf.joined(separator: " "), insBuf.joined(separator: " "))]
                var pairs: [(String, String)] = whole
                if delBuf.count == insBuf.count && delBuf.count > 1 {
                    let split = Array(zip(delBuf, insBuf))
                    if split.contains(where: { !CorrectionLearner.shouldLearn(old: $0.0, new: $0.1) || $0.0 == $0.1 }) { pairs = split }
                }
                for (o, n) in pairs where o != n && n.contains(where: { $0.isLetter }) && !o.isEmpty { out.append((o, n)) }
            }
            changed += max(delBuf.count, insBuf.count)
            delBuf = []; insBuf = []
        }
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { flush(); i += 1; j += 1 }
            else if j < y.count, (i >= x.count || dp[i][j + 1] >= dp[i + 1][j]) { insBuf.append(y[j]); j += 1 }
            else { delBuf.append(x[i]); i += 1 }
        }
        flush()
        // Großer Umbau statt Korrektur → nichts lernen
        if Double(changed) > max(3, Double(x.count) * 0.4) { return [] }
        return out
    }


    // MARK: Bedienungshilfen

    static func isSecure(_ el: AXUIElement) -> Bool {
        var r: CFTypeRef?, sr: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sr)
        return (r as? String) == "AXSecureTextField" || (sr as? String) == "AXSecureTextField"
    }


    /// Leerzeichen/Zeilenumbrüche vereinheitlichen (Terminal bricht Zeilen um)
    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "[\\s\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Alle sichtbaren Textzeilen im aktiven Fenster (so zeigt VS Code sein Terminal für Screenreader).
    static func screenText(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w else { return "" }
        var out: [String] = []
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 50, visited < 1500 else { return }
            visited += 1
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success, (r as? String) == "AXStaticText" {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let s = v as? String, !s.isEmpty { out.append(s) }
            }
            var k: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &k) == .success, let kids = k as? [AXUIElement] {
                for c in kids { walk(c, depth + 1) }
            }
        }
        walk(win as! AXUIElement, 0)
        return out.joined(separator: " ")
    }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    /// Fokussiertes Element einer bestimmten App (auch, wenn die Pille gerade den systemweiten Fokus hält)
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    /// Chromium: oberstes bearbeitbares Element (contenteditable-Wurzel), falls es nicht das Element selbst ist
    static func editableRoot(_ el: AXUIElement) -> AXUIElement? {
        for a in ["AXHighestEditableAncestor", "AXEditableAncestor"] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success, let r = v, CFGetTypeID(r) == AXUIElementGetTypeID() {
                let e = r as! AXUIElement
                return CFEqual(e, el) ? nil : e
            }
        }
        return nil
    }

    static func value(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let s = v as? String else { return nil }
        return s
    }
}
