import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Agent-Prompt: „Einfügen“ ERSETZT das eingefügte Diktat durch den Prompt
//
// 1. Beim Einfügen eines Diktats (Dictation → APFlow.afterPaste) wird gemerkt, WO der Text steht (`APPasted`):
//    · Claude Code im Terminal (VS Code & Co. über die xterm-Zeilen, Terminal/iTerm über AXValue): die Eingabebox
//      – Text davor, unser Text (so wie die Box ihn zeigt, auch eingeklappt „[Pasted text #3 +12 lines]“), Text danach,
//      die schon abgeschickten Nachrichten.
//    · Textfeld (Bedienungshilfen): Wert davor/danach + Stelle.
//    Vor dem Diktat wird die Box einmal gelesen (`pre`) – nur so ist ein eingeklappter Text sicher UNSERER.
// 2. Bei „Einfügen“ (APReplaceRun.run): Ziel nach vorne, nachlesen, entscheiden (`APReplace.judgeBox/judgeField`):
//    · unverändert da → Textfeld: genau den Bereich markieren und darüber einfügen; Terminal: Rücktaste, erst EINE,
//      nachlesen (stand die Schreibmarke wirklich am Ende unseres Textes?), dann den Rest – nach jedem Schritt muss die
//      Box „davor + Anfang unseres Textes + danach“ zeigen, sonst sofort Schluss.
//    · abgeschickt / geändert / nicht lesbar → NICHTS löschen, Prompt neu einfügen + leiser Hinweis an der Pille.
// Nie: Text löschen, den wir nicht eingefügt haben · in Passwortfeldern / bei sicherer Eingabe / in Passwort-Apps lesen
// oder löschen · die Zwischenablage anders als beim normalen Einfügen benutzen.

/// Wo unser Text nach dem Einfügen steht. Vergleiche immer ohne Leerraum (Terminal bricht Zeilen um, Felder melden \r/\n).
enum APMark: Equatable {
    /// Claude-Code-Eingabebox. `shown` = unser Text, wie er in der Box steht (Text oder Platzhalter, roh – zählt die Rücktasten)
    case box(before: String, shown: String, after: String, sentBefore: [String])
    /// Textfeld. `location` = UTF-16-Stelle von `shown` im Wert beim Einfügen
    case field(before: String, shown: String, after: String, location: Int)

    var shown: String {
        switch self { case .box(_, let s, _, _), .field(_, let s, _, _): return s }
    }
    var parts: (before: String, shown: String, after: String) {
        switch self {
        case .box(let b, let s, let a, _), .field(let b, let s, let a, _): return (b, s, a)
        }
    }
}

/// Ergebnis des Nachlesens direkt nach dem Einfügen
enum APPasteState: Equatable {
    case pending
    case found(APMark)
    /// Text stand schon im Verlauf (Enter kam vor dem Nachlesen)
    case sentAlready
    /// Grund fürs Protokoll (nie der Text)
    case unknown(String)
}

/// Ein eingefügtes Diktat (eine Instanz je Diktat, Main-Thread)
final class APPasted {
    let id = String(UUID().uuidString.prefix(6))
    /// Genau so eingefügt (inkl. Leerzeichen davor, das der Inserter evtl. ergänzt hat)
    let text: String
    let at: Date
    var target: APTarget?
    var context: APContext?
    /// Fokussiertes Element beim Einfügen (Textfeld bzw. xterm-Eingabe) – vor dem Ersetzen wieder fokussieren
    var element: AXUIElement?
    var state: APPasteState = .pending
    init(text: String, at: Date = Date(), target: APTarget? = nil) { self.text = text; self.at = at; self.target = target }
}

/// Was bei „Einfügen“ herauskam
enum APReplaceOutcome: Equatable {
    /// Original entfernt (Terminal) bzw. markiert (Textfeld) – jetzt den Prompt einfügen
    case cleared, selected
    /// Nichts gelöscht – Prompt neu einfügen, Hinweis zeigen (nil = kein Hinweis, z. B. „Prompt: …“ ohne eingefügtes Original)
    case insertNew(hint: String?, why: String)

    static let hintSent = "Original war schon abgeschickt – Prompt neu eingefügt"
    static let hintEdited = "Original wurde geändert – Prompt neu eingefügt"
    static let hintUnknown = "Original nicht gefunden – Prompt neu eingefügt"
}

enum APVerdict: Equatable {
    case intact
    case sent
    case edited
    case unreadable(String)
}

// MARK: - Reine Logik (im Selbsttest geprüft)

enum APReplace {
    /// Ohne jeden Leerraum (auch U+00A0) – Zeilenumbruch, Einrückung und Rahmen spielen keine Rolle
    static func squash(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{00A0}" }))
    }

    /// Claude-Code-Platzhalter für eingefügten Text: „[Pasted text #3 +12 lines]“ (Nummer, Range im String)
    static func placeholders(_ s: String) -> [(number: Int, range: Range<String.Index>)] {
        let re = APText.regex(#"\[Pasted text #(\d+)(?: \+\d+ lines?)?\]"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range, in: s), let nr = Range(m.range(at: 1), in: s), let n = Int(s[nr]) else { return nil }
            return (n, r)
        }
    }

    /// Nach dem Einfügen: steht unser Text in der Box? `pre` = Box vor dem Diktat (nur damit gilt ein Platzhalter als unserer).
    /// nil = noch nicht zu sehen (weiter nachlesen).
    static func markBox(inserted: String, screen s: TerminalPrompt.Screen, pre: TerminalPrompt.Screen?) -> APPasteState? {
        guard let input = s.input else { return nil }
        let x = squash(inserted)
        guard !x.isEmpty else { return .unknown("leerer Text") }
        // 1) Text steht ausgeschrieben in der Box (letztes Vorkommen – dort steht die Schreibmarke)
        if let r = input.range(of: inserted.trimmingCharacters(in: .whitespacesAndNewlines), options: .backwards) {
            // Box-Text ist normalisiert (Leerzeichen zusammengefasst) – unser Text kann intern anders umbrochen sein
            let shown = inserted.hasPrefix(" ") ? " " + String(input[r]) : String(input[r])
            return .found(.box(before: String(input[..<r.lowerBound]), shown: shown, after: String(input[r.upperBound...]), sentBefore: s.sent))
        }
        let sq = squash(input)
        if let r = sq.range(of: x, options: .backwards) {
            // Nur ohne Leerraum gefunden (umbrochene Wörter) – Teile ohne Leerraum merken, Rücktasten nach dem Original zählen
            return .found(.box(before: String(sq[..<r.lowerBound]), shown: inserted, after: String(sq[r.upperBound...]), sentBefore: s.sent))
        }
        // 2) Eingeklappt: ein NEUER Platzhalter gegenüber dem Stand vor dem Diktat – und ohne ihn ist die Box wie vorher
        let now = placeholders(input)
        if let last = now.max(by: { $0.number < $1.number }) {
            guard let pre, let preInput = pre.input else { return .unknown("eingeklappt, Stand vor dem Diktat fehlt") }
            let preNums = Set(placeholders(preInput).map(\.number))
            guard !preNums.contains(last.number) else { return nil }
            let before = String(input[..<last.range.lowerBound]), after = String(input[last.range.upperBound...])
            guard squash(before + after) == squash(preInput) else { return .unknown("eingeklappt, Box hat sich sonst auch geändert") }
            return .found(.box(before: before, shown: String(input[last.range]), after: after, sentBefore: s.sent))
        }
        // 3) Schon abgeschickt (Enter kam vor dem Nachlesen): neu im Verlauf
        let old = Set(pre?.sent ?? [])
        if s.sent.contains(where: { !old.contains($0) && squash($0).contains(x) }) { return .sentAlready }
        return nil
    }

    /// Nach dem Einfügen in ein Textfeld: Text direkt vor der Schreibmarke (sonst letztes Vorkommen). nil = noch nicht da.
    static func markField(inserted: String, value: String, cursor: Int?) -> APPasteState? {
        let v = value as NSString
        let candidates = [inserted, inserted.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }
        for c in candidates {
            let len = (c as NSString).length
            if let cur = cursor, cur >= len, cur <= v.length, v.substring(with: NSRange(location: cur - len, length: len)) == c {
                return .found(.field(before: v.substring(to: cur - len), shown: c, after: v.substring(from: cur), location: cur - len))
            }
        }
        for c in candidates {
            let r = v.range(of: c, options: .backwards)
            if r.location != NSNotFound {
                return .found(.field(before: v.substring(to: r.location), shown: c, after: v.substring(from: NSMaxRange(r)), location: r.location))
            }
        }
        return nil
    }

    /// Box JETZT gegen die Box beim Einfügen
    static func judgeBox(_ m: APMark, now s: TerminalPrompt.Screen?) -> APVerdict {
        guard case .box(let before, let shown, let after, let sentBefore) = m else { return .unreadable("kein Box-Anker") }
        guard let s else { return .unreadable("Terminal nicht lesbar") }
        guard let input = s.input else { return .unreadable("keine Claude-Code-Eingabebox") }
        let cur = squash(input), x = squash(shown)
        if cur == squash(before + shown + after) { return .intact }
        let newSent = s.sent.filter { !sentBefore.contains($0) }
        if !cur.contains(x) {
            if cur.isEmpty || newSent.contains(where: { squash($0).contains(x) || squash($0).contains(squash(shown)) }) { return .sent }
            return .edited
        }
        // Unser Text steht noch, drumherum hat sich etwas geändert: Schreibmarke unbekannt → nicht löschen
        return .edited
    }

    /// Feld JETZT gegen das Feld beim Einfügen. Steht unser Text unverändert (genau einmal bzw. an alter Stelle) → Bereich.
    static func judgeField(_ m: APMark, value: String?) -> (APVerdict, NSRange?) {
        guard case .field(let before, let shown, let after, let loc) = m else { return (.unreadable("kein Feld-Anker"), nil) }
        guard let value else { return (.unreadable("Feld nicht lesbar"), nil) }
        let v = value as NSString, len = (shown as NSString).length
        if v.length >= loc + len, v.substring(with: NSRange(location: loc, length: len)) == shown,
           squash(value) == squash(before + shown + after) {
            return (.intact, NSRange(location: loc, length: len))
        }
        // Drumherum geändert, unser Text aber unversehrt: nur wenn er eindeutig ist
        let first = v.range(of: shown)
        if first.location != NSNotFound {
            let last = v.range(of: shown, options: .backwards)
            if first.location == last.location { return (.intact, first) }
            if v.length >= loc + len, v.substring(with: NSRange(location: loc, length: len)) == shown { return (.intact, NSRange(location: loc, length: len)) }
            return (.edited, nil)
        }
        if squash(value).isEmpty || squash(value) == squash(before + after) { return (.sent, nil) }
        return (.edited, nil)
    }

    /// Wie viele Zeichen unseres Textes stehen noch? Box/Feld muss genau „davor + Anfang(k) + danach“ zeigen (ohne
    /// Leerraum). Bei Mehrdeutigkeit (Leerzeichen) das KLEINSTE k – dann wird nie zu viel gelöscht. nil = passt nicht.
    static func remaining(_ m: APMark, now: String) -> Int? {
        let (before, shown, after) = m.parts
        let cur = squash(now), b = squash(before), a = squash(after)
        guard cur.hasPrefix(b), cur.hasSuffix(a), cur.count >= b.count + a.count else { return nil }
        let mid = String(cur.dropFirst(b.count).dropLast(a.count))
        let chars = Array(shown)
        // Kleinstes k, dessen Anfang (ohne Leerraum) genau `mid` ist
        var sq = ""
        if mid.isEmpty { return 0 }
        for k in 1...chars.count {
            let c = chars[k - 1]
            if !c.isWhitespace && c != "\u{00A0}" { sq.append(c) }
            if sq == mid { return k }
            if sq.count > mid.count { return nil }
        }
        return nil
    }

    /// Erste Rücktaste traf NICHT unser Ende: welches Zeichen ist verschwunden (zum Zurückschreiben)? Nur ohne Leerraum eindeutig.
    static func deletedChar(before old: String, after new: String) -> Character? {
        let a = Array(squash(old)), b = Array(squash(new))
        guard a.count == b.count + 1 else { return nil }
        var i = 0
        while i < b.count, a[i] == b[i] { i += 1 }
        guard Array(a[(i + 1)...]) == Array(b[i...]) else { return nil }
        return a[i]
    }
}

// MARK: - Ablauf beim Klick auf „Einfügen“ (ohne echte Tasten – über `APReplaceIO`, im Selbsttest mit Schein-Feldern)

/// Alles, was das Ersetzen am Ziel tut (Hintergrund-Thread)
protocol APReplaceIO: AnyObject {
    /// Passwortfeld / sichere Eingabe / Passwort-App → nie lesen oder löschen
    func isSecure() -> Bool
    /// Claude-Code-Box lesen (nil = nicht lesbar)
    func readBox() -> TerminalPrompt.Screen?
    /// Textfeld lesen: Wert + Markierung (UTF-16)
    func readField() -> (value: String, selection: NSRange?)?
    /// Bereich markieren (true = per Rücklesen bestätigt)
    func select(_ r: NSRange) -> Bool
    func backspace(_ n: Int)
    /// Reparatur: ein Zeichen zurückschreiben
    func type(_ c: Character)
    func sleep(_ s: Double)
}

enum APReplaceRun {
    /// Höchstzeit, bis eine Rücktaste in der Box sichtbar wird (Claude Code zeichnet verzögert)
    static var stepTimeout: Double = 1.5

    /// Hintergrund. `state` = gemerkte Stelle (auf dem Main-Thread kopiert). Entscheidet und löscht ggf. – danach fügt der Aufrufer den Prompt ein (ersetzt die Markierung bzw.
    /// steht an der Stelle des gelöschten Originals).
    static func run(_ state: APPasteState, io: APReplaceIO) -> APReplaceOutcome {
        if io.isSecure() { return .insertNew(hint: nil, why: "Passwortfeld/sichere Eingabe – nichts gelesen") }
        switch state {
        case .pending: return .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Stelle beim Einfügen noch nicht gefunden")
        case .unknown(let why): return .insertNew(hint: APReplaceOutcome.hintUnknown, why: why)
        case .sentAlready: return .insertNew(hint: APReplaceOutcome.hintSent, why: "schon beim Einfügen abgeschickt")
        case .found(let m):
            switch m {
            case .box: return runBox(m, io: io)
            case .field: return runField(m, io: io)
            }
        }
    }

    private static func verdictOutcome(_ v: APVerdict) -> APReplaceOutcome {
        switch v {
        case .intact: return .cleared
        case .sent: return .insertNew(hint: APReplaceOutcome.hintSent, why: "abgeschickt")
        case .edited: return .insertNew(hint: APReplaceOutcome.hintEdited, why: "seit dem Einfügen geändert")
        case .unreadable(let why): return .insertNew(hint: APReplaceOutcome.hintUnknown, why: why)
        }
    }

    private static func runBox(_ m: APMark, io: APReplaceIO) -> APReplaceOutcome {
        let first = io.readBox()
        let v = APReplace.judgeBox(m, now: first)
        guard v == .intact, let start = first?.input else { return verdictOutcome(v) }
        return erase(m, start: start, io: io, read: { io.readBox()?.input })
    }

    private static func runField(_ m: APMark, io: APReplaceIO) -> APReplaceOutcome {
        let f = io.readField()
        let (v, range) = APReplace.judgeField(m, value: f?.value)
        guard v == .intact, let range, let f else { return verdictOutcome(v) }
        // a) Bereich markieren → der Prompt ersetzt ihn beim Einfügen
        if io.select(range) { return .selected }
        // b) Markieren geht nicht (manche Web-Felder): nur wenn die Schreibmarke direkt hinter unserem Text steht → Rücktaste
        guard let sel = f.selection, sel.length == 0, sel.location == NSMaxRange(range) else {
            return .insertNew(hint: APReplaceOutcome.hintEdited, why: "Feld lässt sich nicht markieren, Schreibmarke woanders")
        }
        let (_, shown, _) = m.parts
        let ns = f.value as NSString
        let mark = APMark.field(before: ns.substring(to: range.location), shown: shown, after: ns.substring(from: NSMaxRange(range)), location: range.location)
        return erase(mark, start: f.value, io: io, read: { io.readField()?.value })
    }

    /// Rücktasten mit Nachlesen: erst EINE (stand die Schreibmarke am Ende unseres Textes?), dann der Rest auf einmal.
    /// Vor jedem weiteren Schritt muss der Stand RUHIG sein (alle Tasten verarbeitet) und genau „davor + Anfang unseres
    /// Textes + danach“ zeigen – sonst Schluss. So wird nie mehr gelöscht, als von unserem Text noch da ist.
    static func erase(_ m: APMark, start: String, io: APReplaceIO, read: () -> String?) -> APReplaceOutcome {
        guard var k = APReplace.remaining(m, now: start) else { return .insertNew(hint: APReplaceOutcome.hintEdited, why: "Stand passt nicht") }
        if k == 0 { return .cleared }
        // 1) Eine Rücktaste
        io.backspace(1)
        let s1 = settle(from: start, io: io, read: read, timeout: stepTimeout) { APReplace.remaining(m, now: $0) ?? -1 <= k - 1 }
        guard APReplace.squash(s1) != APReplace.squash(start) else {
            return .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Rücktaste ohne sichtbare Wirkung")
        }
        guard let r1 = APReplace.remaining(m, now: s1), r1 < k else {
            if let c = APReplace.deletedChar(before: start, after: s1) {
                io.type(c)   // Schreibmarke stand nicht am Ende unseres Textes → Zeichen zurück
                return .insertNew(hint: APReplaceOutcome.hintEdited, why: "Schreibmarke stand woanders – ein Zeichen zurückgeschrieben")
            }
            return .insertNew(hint: APReplaceOutcome.hintEdited, why: "Stand nach der ersten Rücktaste passt nicht")
        }
        k = r1
        // 2) Rest auf einmal – höchstens dreimal nachfassen, immer erst, wenn der Stand ruhig ist
        var last = s1
        var rounds = 0
        while k > 0, rounds < 3 {
            rounds += 1
            io.backspace(k)
            last = settle(from: last, io: io, read: read, timeout: stepTimeout + Double(k) * 0.004) { APReplace.remaining(m, now: $0) == 0 }
            guard let r = APReplace.remaining(m, now: last), r < k else {
                return .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Stand nach den Rücktasten passt nicht")
            }
            k = r
        }
        return k == 0 ? .cleared : .insertNew(hint: APReplaceOutcome.hintUnknown, why: "Original nur teilweise gelöscht")
    }

    /// Ruhe abwarten: bis `done` stimmt oder sich der Stand `quiet` Sekunden nicht mehr geändert hat (nach mindestens einer
    /// Änderung) bzw. die Zeit um ist. Gibt den letzten gelesenen Stand zurück.
    static var quiet: Double = 0.35
    private static func settle(from start: String, io: APReplaceIO, read: () -> String?, timeout: Double, done: (String) -> Bool) -> String {
        var last = start
        var changedAt: Date?
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            io.sleep(0.04)
            if let cur = read() {
                if APReplace.squash(cur) != APReplace.squash(last) { last = cur; changedAt = Date() }
                if changedAt != nil, done(last) { return last }
            }
            if let c = changedAt, Date().timeIntervalSince(c) >= quiet { return last }
        } while Date() < deadline
        return last
    }
}

// MARK: - Echte Umgebung (Bedienungshilfen + Tasten)

enum APReplaceLive {
    static let queue = DispatchQueue(label: "flow.agentprompt.replace", qos: .userInitiated)

    static func isTerminal(_ bundle: String) -> Bool {
        CorrectionLearner.terminalApps.contains(bundle) || MTRules.nativeTerminals.contains(bundle) || MTRules.xtermEditors.contains(bundle)
    }

    /// Box lesen: xterm-Zeilen (VS Code & Co.), sonst AXValue des Terminals in Zeilen (Terminal, iTerm)
    static func readBox(pid: pid_t, element: AXUIElement?, known: Set<String>) -> TerminalPrompt.Screen? {
        if let t = TerminalPrompt.read(pid: pid, from: element) { return TerminalPrompt.parse(t.rows, known: known) }
        // Terminal/iTerm: nur das Ende des Puffers (der ganze Verlauf kann riesig sein)
        if let el = element ?? CorrectionLearner.focusedElement(pid: pid), let v = tail(el, chars: 12_000), !v.isEmpty {
            let rows = v.components(separatedBy: .newlines).suffix(120)
            let s = TerminalPrompt.parse(Array(rows), known: known)
            return s.hasBox ? s : nil
        }
        return nil
    }

    /// Letzte `chars` Zeichen eines Textbereichs (AXStringForRange) – nie den ganzen Wert
    static func tail(_ el: AXUIElement, chars: Int) -> String? {
        var n: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &n) == .success, let count = n as? Int else { return nil }
        var r = CFRange(location: max(0, count - chars), length: min(count, chars))
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success else { return nil }
        return out as? String
    }

    static func known(_ text: String) -> Set<String> { Set(CorrectionLearner.words(text).map { CorrectionLearner.bare($0).lowercased() }) }

    static func secure(_ el: AXUIElement?, bundle: String) -> Bool {
        IsSecureEventInputEnabled() || CorrectionLearner.blockedApps.contains(bundle) || (el.map(CorrectionLearner.isSecure) ?? false)
    }

    /// Vor dem Diktat (Hintergrund): Box der vorderen App, wenn es ein Terminal ist – nur für eingeklappte Texte nötig
    static func preRead(done: @escaping (pid_t, TerminalPrompt.Screen?) -> Void) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              isTerminal(app.bundleIdentifier ?? ""), !IsSecureEventInputEnabled() else { return }
        let pid = app.processIdentifier
        queue.asyncAfter(deadline: .now() + 0.3) {
            let s = readBox(pid: pid, element: nil, known: [])
            DispatchQueue.main.async { done(pid, s) }
        }
    }

    /// Nach dem Einfügen (Hintergrund): Ziel + Stelle merken. Bis ~3 s nachlesen (Terminals zeichnen verzögert).
    static func snapshot(_ p: APPasted, pre: (pid: pid_t, screen: TerminalPrompt.Screen?)?, mouseTarget: APTarget?,
                         done: @escaping (APPasteState, APTarget?, APContext?, AXUIElement?) -> Void) {
        let text = p.text
        queue.async {
            guard AXIsProcessTrusted() else {
                let t = NSWorkspace.shared.frontmostApplication.map { APTarget(pid: $0.processIdentifier, windowID: nil, window: nil, bundleID: $0.bundleIdentifier ?? "", appName: $0.localizedName ?? "", title: "") }
                DispatchQueue.main.async { done(.unknown("Bedienungshilfen fehlen"), t, t.map { APContext(appName: $0.appName, bundleID: $0.bundleID, windowTitle: "") }, nil) }
                return
            }
            var target = mouseTarget
            if target == nil {
                let f = MouseTarget.frontmost()
                if f.pid != 0, f.pid != ProcessInfo.processInfo.processIdentifier {
                    let app = NSRunningApplication(processIdentifier: f.pid)
                    target = APTarget(pid: f.pid, windowID: f.windowID, window: f.window, bundleID: app?.bundleIdentifier ?? "",
                                      appName: app?.localizedName ?? "", title: f.window.flatMap { MTAX.string($0, kAXTitleAttribute) } ?? "")
                }
            }
            let ctx = target.map { APContext(appName: $0.appName, bundleID: $0.bundleID, windowTitle: $0.title) }
            guard let t = target else { DispatchQueue.main.async { done(.unknown("kein Ziel-Fenster"), nil, nil, nil) }; return }
            // Electron/Chrome: Bedienungshilfen-Baum an (wie Wort-Lerner/Maus-Ziel, geht nach 60 s von selbst wieder aus)
            ScreenContext.shared.enableAX(t.pid)
            MouseTarget.shared.enableWebAX(pid: t.pid, bundle: t.bundleID)
            let el = CorrectionLearner.focusedElement(pid: t.pid)
            if secure(el, bundle: t.bundleID) { DispatchQueue.main.async { done(.unknown("Passwortfeld/sichere Eingabe"), t, ctx, nil) }; return }
            let terminal = isTerminal(t.bundleID)
            let known = known(text)
            let preScreen = pre?.pid == t.pid ? pre?.screen : nil
            var state: APPasteState?
            var why = "Text nicht gefunden"
            let deadline = Date().addingTimeInterval(3)
            usleep(120_000)
            var inBox = false
            repeat {
                inBox = false
                // Terminal (auch VS Code & Co.): erst die Claude-Code-Box; Editoren ohne Box (Chat-Ansicht, Datei) wie ein Textfeld
                if terminal, let s = readBox(pid: t.pid, element: el, known: known) {
                    inBox = true
                    state = APReplace.markBox(inserted: text, screen: s, pre: preScreen)
                } else if terminal, MTRules.nativeTerminals.contains(t.bundleID) {
                    why = "Terminal ohne Claude-Code-Box"
                } else if let e = el {
                    // contenteditable (Chromium): fokussiert ist oft nur ein Absatz → das ganze bearbeitbare Feld
                    let field = CorrectionLearner.editableRoot(e) ?? e
                    if let v = CorrectionLearner.value(of: field) {
                        state = APReplace.markField(inserted: text, value: v, cursor: selection(field).map { $0.location + $0.length })
                    } else { why = "Feld nicht lesbar" }
                } else { why = "kein fokussiertes Feld" }
                if state != nil { break }
                usleep(200_000)
            } while Date() < deadline
            let final = state ?? .unknown(why)
            let field: AXUIElement? = inBox ? el : el.map { CorrectionLearner.editableRoot($0) ?? $0 }
            DispatchQueue.main.async { done(final, t, ctx, field) }
        }
    }

    static func selection(_ el: AXUIElement) -> NSRange? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let v = r,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var cr = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &cr) else { return nil }
        return NSRange(location: cr.location, length: cr.length)
    }

    static func postKey(_ code: Int, count: Int) {
        let src = CGEventSource(stateID: .privateState)
        for i in 0..<count {
            let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)
            d?.flags = []; u?.flags = []
            HotkeyMonitor.markSynthetic(d); HotkeyMonitor.markSynthetic(u)
            d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
            if i % 20 == 19 { usleep(3_000) } else { usleep(1_200) }
        }
    }

    /// Echte Umgebung für `APReplaceRun`
    final class IO: APReplaceIO {
        let pid: pid_t
        let bundle: String
        let element: AXUIElement?
        let known: Set<String>
        init(pid: pid_t, bundle: String, element: AXUIElement?, known: Set<String>) {
            self.pid = pid; self.bundle = bundle; self.element = element; self.known = known
        }
        private var focused: AXUIElement? { CorrectionLearner.focusedElement(pid: pid) }
        func isSecure() -> Bool { APReplaceLive.secure(focused, bundle: bundle) }
        /// Gemerkte xterm-Eingabe zuerst (auch wenn der Fokus gerade woanders im Fenster ist)
        func readBox() -> TerminalPrompt.Screen? { APReplaceLive.readBox(pid: pid, element: element ?? focused, known: known) }
        func readField() -> (value: String, selection: NSRange?)? {
            guard let el = element ?? focused, let v = CorrectionLearner.value(of: el) else { return nil }
            return (v, APReplaceLive.selection(el))
        }
        func select(_ r: NSRange) -> Bool {
            guard let el = element ?? focused else { return false }
            var cr = CFRange(location: r.location, length: r.length)
            guard let v = AXValueCreate(.cfRange, &cr),
                  AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success else { return false }
            // Rücklesen: wirklich genau dieser Bereich markiert?
            var ok = false
            MTFocus.poll(0.15) { ok = APReplaceLive.selection(el) == r; return ok }
            return ok
        }
        func backspace(_ n: Int) { APReplaceLive.postKey(kVK_Delete, count: n) }
        func type(_ c: Character) {
            let src = CGEventSource(stateID: .privateState)
            let utf16 = Array(String(c).utf16)
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            d?.flags = []; u?.flags = []
            d?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            u?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            HotkeyMonitor.markSynthetic(d); HotkeyMonitor.markSynthetic(u)
            d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
        }
        func sleep(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
    }
}
