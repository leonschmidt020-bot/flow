import AppKit
import ApplicationServices

/// Terminal-Text für den Wort-Lerner.
///
/// VS Code, Cursor, Windsurf & Co. zeichnen ihr Terminal mit xterm.js. Das Eingabefeld dort („xterm-helper-textarea“)
/// ist immer leer – der Text steht nur in den Zeilen, die xterm.js für Bedienungshilfen als Liste
/// („xterm-accessibility-tree“, eine Gruppe je sichtbarer Zeile) bereitstellt. Gemessen 27.09.2026 an VS Code:
/// 61–75 Zeilen, nur der sichtbare Ausschnitt, Zeilen mit Leerzeichen auf volle Breite aufgefüllt.
///
/// Claude Code zeichnet darin seine Eingabebox so (Stand 09/2026):
///
///     ────────────────────────────  (Trennlinie)
///     ❯ erster Teil des Textes …
///       Fortsetzung, 2 Leerzeichen eingerückt
///     ────────────────────────────  (Trennlinie)
///       Statuszeilen …
///
/// Ältere Fassungen: `╭──╮ / │ > Text │ / ╰──╯`. Abgeschickte Nachrichten stehen danach im Verlauf als `❯ Text`
/// (Fortsetzung wieder eingerückt). `parse` zerlegt die Zeilen in: Eingabe, abgeschickte Nachrichten, Gesamttext.
enum TerminalPrompt {
    struct Screen: Equatable {
        /// Text in der Claude-Code-Eingabebox (ohne Rahmen/Prompt). nil = keine Box erkannt (normale Shell usw.)
        var input: String?
        /// Abgeschickte Nachrichten im sichtbaren Verlauf (oben → unten)
        var sent: [String] = []
        /// Alle Zeilen zusammen (Zeilenumbrüche zu Leerzeichen, umbrochene Wörter wieder zusammengesetzt)
        var all: String = ""
        /// Claude Code hat eingefügten Text eingeklappt („[Pasted text #1 +12 lines]“)
        var collapsed = false
        var hasBox: Bool { input != nil }
    }

    // MARK: Zerlegen (reine Logik, im Selbsttest geprüft)

    private static let ruleChars: Set<Character> = ["─", "━", "═", "╌", "┄", "┈", "-", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"]
    private static let frameChars: Set<Character> = ["│", "┃", "║"]
    private static let promptChars: Set<Character> = ["❯", ">", "›"]
    /// Zeichen, mit denen Claude Code Ausgaben einleitet – dort endet eine abgeschickte Nachricht
    private static let markers: Set<Character> = ["⎿", "⏺", "●", "✻", "✽", "✶", "✳", "✢", "·", "※", "◯", "⏵", "⧉", "▐", "▛", "▜", "▝", "▘"]

    /// Trennlinie (─────) bzw. Ober-/Unterkante einer Box
    static func isRule(_ row: String) -> Bool {
        let t = row.trimmingCharacters(in: .whitespaces)
        guard t.count >= 8 else { return false }
        return t.allSatisfy { ruleChars.contains($0) }
    }

    /// Rahmen „│ … │“ ab, Leerzeichen am Ende ab. Liefert Inhalt + ob die Zeile bis an den rechten Rand reicht.
    static func content(_ row: String, width: Int) -> (text: String, full: Bool) {
        let c = Array(row)
        var lo = 0, hi = c.count
        var right = width                       // Spalte, bis zu der Text reichen kann
        if let last = c.lastIndex(where: { !$0.isWhitespace }), frameChars.contains(c[last]) { hi = last; right = last }
        if let first = c.firstIndex(where: { !$0.isWhitespace }), first < hi, frameChars.contains(c[first]) { lo = first + 1 }
        var end = hi
        while end > lo, c[end - 1].isWhitespace { end -= 1 }
        // „voll“ = das letzte Zeichen steht (fast) am rechten Rand – dann kann ein Wort mitten drin umbrochen sein
        return (String(c[lo..<end]), end > lo && end >= right - 1)
    }

    /// Beginnt die Zeile (nach Rahmen, höchstens 2 Leerzeichen) mit einem Prompt „❯ “ / „> “?
    static func isPromptStart(_ text: String) -> Bool {
        let lead = text.prefix(while: { $0 == " " }).count
        guard lead <= 2 else { return false }
        let t = text.dropFirst(lead)
        guard let f = t.first, promptChars.contains(f) else { return false }
        let next = t.dropFirst().first
        return next == nil || next == " "
    }

    /// Prompt-Zeichen am Anfang weg („❯ ❯ Text“ → „Text“)
    static func dropPrompt(_ text: String) -> String {
        var t = Substring(text).drop(while: { $0 == " " })
        while let f = t.first, promptChars.contains(f) { t = t.dropFirst().drop(while: { $0 == " " }) }
        return String(t)
    }

    static func lowerBare(_ w: Substring) -> String { w.trimmingCharacters(in: .punctuationCharacters).lowercased() }

    /// Zeilen zu einem Text verbinden. Reicht eine Zeile bis an den Rand und geht die nächste mit einem Buchstaben weiter,
    /// kann ein Wort mitten drin umbrochen sein (Shells, lange Wörter): dann zusammensetzen, wenn das zusammengesetzte
    /// Wort bekannt ist (aus dem Diktat) – oder keiner der beiden Teile.
    static func join(_ parts: [(text: String, full: Bool)], known: Set<String>) -> String {
        var out = ""
        var prevFull = false
        for p in parts {
            let t = p.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { prevFull = false; if !out.isEmpty, !out.hasSuffix(" ") { out += " " }; continue }
            if out.isEmpty { out = t; prevFull = p.full; continue }
            var glue = " "
            if prevFull, let lc = out.last, lc.isLetter || lc.isNumber, let fc = t.first, fc.isLetter || fc.isNumber {
                let a = out.split(separator: " ").last ?? ""
                let b = t.split(separator: " ").first ?? ""
                let whole = lowerBare(Substring(String(a) + String(b)))
                if known.contains(whole) || (!known.contains(lowerBare(a)) && !known.contains(lowerBare(b))) { glue = "" }
            }
            if out.hasSuffix(" ") { glue = "" }
            out += glue + t
            prevFull = p.full
        }
        return CorrectionLearner.norm(out)
    }

    /// Zeilen des Terminals → Eingabebox, abgeschickte Nachrichten, Gesamttext.
    /// `known` = Wörter des Diktats (klein, ohne Satzzeichen) für umbrochene Wörter.
    static func parse(_ raw: [String], known: Set<String> = []) -> Screen {
        // Gemessen 27.09.: in der Eingabezeile steht „❯“ + geschütztes Leerzeichen (U+00A0), im Verlauf „❯ “
        let rows = raw.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        let width = rows.map { $0.count }.max() ?? 0
        let parts = rows.map { content($0, width: width) }
        var screen = Screen()
        screen.all = join(parts, known: known)

        // Eingabebox von unten suchen: Linie – 1…40 Zeilen – Linie, erste Zeile mit Prompt
        var box: Range<Int>?
        var i = rows.count - 1
        while i > 0, box == nil {
            if isRule(rows[i]) {
                var j = i - 1
                while j >= 0, !isRule(rows[j]), i - j <= 41 { j -= 1 }
                if j >= 0, isRule(rows[j]), j + 1 < i, isPromptStart(parts[j + 1].text) { box = (j + 1)..<i }
            }
            i -= 1
        }
        guard let box else { return screen }

        var boxParts = Array(parts[box])
        boxParts[0].text = dropPrompt(boxParts[0].text)
        let input = join(boxParts, known: known)
        screen.input = input
        screen.collapsed = input.contains("[Pasted text")

        // Verlauf über der Box: „❯ Text“ + eingerückte Fortsetzungszeilen bis zur Leerzeile oder Ausgabe-Markierung
        var r = 0
        let end = box.lowerBound - 1
        while r < end {
            guard isPromptStart(parts[r].text), !isRule(rows[r]) else { r += 1; continue }
            var block = [parts[r]]
            block[0].text = dropPrompt(block[0].text)
            var k = r + 1
            while k < end {
                let raw = parts[k].text
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || isRule(rows[k]) || isPromptStart(raw) { break }
                if let f = trimmed.first, markers.contains(f) { break }
                guard raw.hasPrefix("  ") else { break }   // Fortsetzung ist eingerückt
                block.append(parts[k]); k += 1
            }
            let text = join(block, known: known)
            if !text.isEmpty { screen.sent.append(text) }
            r = k
        }
        return screen
    }

    // MARK: Lesen (Bedienungshilfen)

    private static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private static func classes(_ e: AXUIElement) -> [String] { (attr(e, "AXDOMClassList") as? [String]) ?? [] }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    /// Die Zeilen-Liste von xterm.js zu einem Element im Terminal (z. B. dem fokussierten Eingabefeld).
    static func tree(near el: AXUIElement) -> AXUIElement? {
        if classes(el).contains("xterm-accessibility-tree") { return el }
        // hoch bis zum Terminal-Knoten („terminal xterm …“)
        var cur: AXUIElement? = el
        var root: AXUIElement?
        for _ in 0..<14 {
            guard let c = cur else { break }
            if classes(c).contains("xterm") { root = c; break }
            cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        guard let root else { return nil }
        // runter bis zur Liste (Breitensuche, begrenzt)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 80 {
            let (e, d) = queue.removeFirst(); seen += 1
            if classes(e).contains("xterm-accessibility-tree") { return e }
            if d < 4 { queue += children(e).prefix(12).map { ($0, d + 1) } }
        }
        return nil
    }

    /// Sichtbare Zeilen der Liste (je Gruppe die Texte zusammen). nil = nicht (mehr) lesbar.
    static func rows(of list: AXUIElement) -> [String]? {
        var k: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &k) == .success, let groups = k as? [AXUIElement] else { return nil }
        var out: [String] = []
        out.reserveCapacity(groups.count)
        for g in groups.prefix(400) {
            // Gruppe selbst hat meist AXValue "" (gemessen) → dann die Texte darunter
            if let v = attr(g, kAXValueAttribute) as? String, !v.isEmpty { out.append(v); continue }
            var s = ""
            for c in children(g).prefix(20) {
                if let v = attr(c, kAXValueAttribute) as? String { s += v }
                else { for cc in children(c).prefix(20) { s += (attr(cc, kAXValueAttribute) as? String) ?? "" } }
            }
            out.append(s)
        }
        return out
    }

    /// Terminal des fokussierten Elements der App lesen: (Liste, Zeilen) oder nil (kein xterm.js-Terminal)
    static func read(pid: pid_t, from el: AXUIElement?) -> (tree: AXUIElement, rows: [String])? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var start = el
        if start == nil, let f = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            start = (f as! AXUIElement)
        }
        guard let s = start, let t = tree(near: s), let r = rows(of: t) else { return nil }
        return (t, r)
    }
}
