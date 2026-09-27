import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Fügt Text an der Cursor-Stelle der aktiven App ein (Zwischenablage + ⌘V).
/// Der Text bleibt danach in der Zwischenablage → landet automatisch in ClipVault (Quelle „Diktat“).
enum Inserter {
    enum Outcome { case pasted, copiedOnly(reason: String) }

    static let clipVaultSource = NSPasteboard.PasteboardType("app.flowdictation.clipvault.source")

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    private static var lastInsert: (text: String, app: String, at: Date)?

    static func insert(_ raw: String) -> Outcome {
        var text = raw
        // Leerzeichen davor, wenn direkt an ein Wort angehängt wird.
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let startsWord = text.first.map { $0.isLetter || $0.isNumber } ?? false
        if let prev = characterBeforeCursor() {
            if !prev.isWhitespace, !"([{„\"'/-".contains(prev), startsWord { text = " " + text }
        } else if startsWord, let last = lastInsert, last.app == app, Date().timeIntervalSince(last.at) < 120,
                  let end = last.text.last, !end.isWhitespace {
            // App verrät die Cursor-Umgebung nicht (z. B. Terminal): direkt nach dem letzten Diktat → Leerzeichen.
            text = " " + text
        }
        lastInsert = (text, app, Date())
        let pb = NSPasteboard.general
        if IsSecureEventInputEnabled() {
            // Passwortfeld: als „verborgen/vorübergehend“ markieren (ClipVault & Co. speichern das nicht), nach 30 s leeren
            pb.clearContents()
            pb.setString(text, forType: .string)
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let count = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if pb.changeCount == count { pb.clearContents() } }
            return .copiedOnly(reason: "Passwortfeld – 30 s in Zwischenablage")
        }
        let saved = Settings.shared.keepInClipboard ? nil : snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("Diktat", forType: clipVaultSource)
        guard accessibilityTrusted else {
            return .copiedOnly(reason: "Bedienungshilfen fehlen – in Zwischenablage")
        }
        let written = pb.changeCount
        pressCmdV()
        if let saved {
            // Audit 27.09.2026: nur zurücklegen, wenn seitdem niemand etwas kopiert hat (sonst überschrieb das die neue
            // Kopie des Nutzers); etwas mehr Zeit, damit langsame Apps (Electron, Terminal) wirklich schon eingefügt haben.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if pb.changeCount == written { restore(saved, into: pb) } }
        }
        return .pasted
    }

    private static func pressCmdV() {
        // Eigene Quelle + explizite Flags: noch gedrückte Modifier werden nicht mitgeschickt.
        let src = CGEventSource(stateID: .privateState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        HotkeyMonitor.markSynthetic(down); HotkeyMonitor.markSynthetic(up)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Liest per Bedienungshilfen das Zeichen vor der Einfügemarke (falls die App das unterstützt).
    private static func characterBeforeCursor() -> Character? {
        guard accessibilityTrusted else { return nil }
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let elem = el as! AXUIElement
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rr as! AXValue, .cfRange, &range), range.location > 0 else { return nil }
        var prevRange = CFRange(location: range.location - 1, length: 1)
        guard let prevVal = AXValueCreate(.cfRange, &prevRange) else { return nil }
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(elem, kAXStringForRangeParameterizedAttribute as CFString,
                                                         prevVal, &strRef) == .success,
              let s = strRef as? String, let c = s.last else { return nil }
        return c
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], into pb: NSPasteboard) {
        guard !items.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(items.map { d in
            let it = NSPasteboardItem()
            for (t, v) in d { it.setData(v, forType: t) }
            return it
        })
    }

    /// Nur kopieren (z. B. Meeting-Transkript), mit ClipVault-Quelle.
    static func copy(_ text: String, source: String = "Diktat") {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString(source, forType: clipVaultSource)
    }
}
