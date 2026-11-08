import AppKit
import Carbon.HIToolbox

/// „Sichere Eingabe“ (Secure Event Input) ist ein SYSTEMWEITER Schalter: IsSecureEventInputEnabled() ist true, sobald
/// irgendein Programm ihn hält – auch eines im Hintergrund, das ihn vergessen hat (Passwort-Dialog, Terminal mit
/// „Sichere Tastatureingabe“, Browser …). Vorfall 02.11.2026: Notizen galt deshalb als Passwortfeld, Diktate landeten
/// nur „30 s in der Zwischenablage“. Hier zählt sie nur, wenn sie zum Ziel-Programm gehört (oder der Halter unbekannt ist).
enum SecureInput {
    /// PID des Programms, das die sichere Eingabe gerade hält (nil = aus oder nicht ermittelbar)
    static func holderPID() -> pid_t? {
        guard IsSecureEventInputEnabled(),
              let d = CGSessionCopyCurrentDictionary() as? [String: Any],
              let n = d["kCGSSessionSecureInputPID"] as? NSNumber, n.int32Value > 0 else { return nil }
        return n.int32Value
    }

    /// Gehört die sichere Eingabe zum Programm `pid` (Standard: Vordergrund)? Halter unbekannt → vorsichtig: ja.
    static func blocks(pid: pid_t? = nil) -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        guard let holder = holderPID(),
              let target = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return true }
        if holder == target { return true }
        // Der gemeldete Halter ist nicht immer exakt (macOS ordnet ihn teils dem „verantwortlichen“ Programm zu) –
        // darum zusätzlich: Ist das fokussierte Feld im Ziel lesbar und KEIN Passwortfeld? Nur dann normal weiter.
        guard focusedIsPlainField(pid: target) else { return true }
        noteForeign(holder)
        return false
    }

    /// Für das Log: wer hält die sichere Eingabe, welches Programm ist vorne (keine Inhalte)
    static func summary() -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.localizedName ?? "?"
        guard let h = holderPID() else { return "Halter unbekannt · Ziel \(target)" }
        let name = NSRunningApplication(processIdentifier: h)?.localizedName ?? procName(h)
        return "Halter \(name) (\(h))" + (h == front?.processIdentifier ? " = Ziel" : " · Ziel \(target)")
    }

    private static func procName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "PID \(pid)"
    }

    /// Fokussiertes Element im Programm `pid` gelesen und kein AXSecureTextField (unlesbar → false = vorsichtig)
    private static func focusedIsPlainField(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        return !CorrectionLearner.isSecure(el as! AXUIElement)
    }

    /// Fremder Halter: einmal pro Halter ins Log, damit man sieht, wer sie festhält
    private static var lastForeign: pid_t = 0
    private static let lock = NSLock()
    private static func noteForeign(_ holder: pid_t) {
        lock.lock(); let isNew = holder != lastForeign; lastForeign = holder; lock.unlock()
        guard isNew else { return }
        let name = NSRunningApplication(processIdentifier: holder)?.localizedName ?? "PID \(holder)"
        log("Sichere Eingabe gehalten von \(name) (\(holder)) – nicht das Ziel, normal weiter")
    }
}
