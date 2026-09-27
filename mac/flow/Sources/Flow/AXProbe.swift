#if DEBUG
import AppKit
import ApplicationServices

/// Diagnose: schreibt ins Log, was per Bedienungshilfen im aktiven Fenster lesbar ist.
enum AXProbe {
    static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    static func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }

    static func run() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        log("AXProbe: App \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? ""))")
        guard let f = CorrectionLearner.focusedElement() else { log("AXProbe: kein fokussiertes Element"); return }
        var e: AXUIElement? = f
        for level in 0..<4 {
            guard let el = e else { break }
            let v = str(el, kAXValueAttribute) ?? ""
            log("AXProbe: Ebene \(level) Rolle=\(str(el, kAXRoleAttribute) ?? "-") Sub=\(str(el, kAXSubroleAttribute) ?? "-") Wert(\(v.count))=„\(String(v.suffix(120)).replacingOccurrences(of: "\n", with: "⏎"))“ Beschr=\(str(el, kAXDescriptionAttribute) ?? "-")")
            e = attr(el, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        // Texte im Fenster einsammeln (begrenzt)
        guard let win = attr(axApp, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return }
        var texts: [String] = []
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 40, visited < 6000 else { return }
            visited += 1
            let role = str(el, kAXRoleAttribute) ?? ""
            if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" {
                let v = str(el, kAXValueAttribute) ?? str(el, kAXTitleAttribute) ?? ""
                if v.count > 3 { texts.append(v) }
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, depth + 1) } }
        }
        walk(win, 0)
        // Wo steht Terminal-Text? Alle Attribute nach typischen Zeilen durchsuchen
        var hits: [String] = []
        var seen = 0
        func find(_ el: AXUIElement, _ depth: Int, _ path: String) {
            guard depth < 45, seen < 12000, hits.count < 8 else { return }
            seen += 1
            let role = str(el, kAXRoleAttribute) ?? "?"
            for a in [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
                if let v = str(el, a), v.contains("Modell") || v.contains("bypass") || v.contains("Kontext") {
                    hits.append("\(path)/\(role) [\(a)] (\(v.count) Z.) „\(String(v.suffix(100)).replacingOccurrences(of: "\n", with: "⏎"))“")
                }
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
                for (i, k) in kids.enumerated() { find(k, depth + 1, path + "/\(i)") }
            }
        }
        find(win, 0, "")
        log("AXProbe: Suche in \(seen) Elementen → \(hits.count) Treffer")
        for h in hits { log("AXProbe: Treffer \(h)") }
        log("AXProbe: \(visited) Elemente, \(texts.count) Texte. Letzte: " + texts.suffix(6).map { "„\(String($0.suffix(90)).replacingOccurrences(of: "\n", with: "⏎"))“" }.joined(separator: " | "))
    }
}

#endif
