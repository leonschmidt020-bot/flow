import CoreGraphics
import Foundation

// MARK: - „Text dorthin, wo die Maus ist“ – reine Regeln (ohne Bildschirm, ohne Bedienungshilfen, testbar)
//
// Alles hier ist reine Logik: Koordinaten umrechnen, Fensterliste filtern, Fenster zuordnen, Textfeld erkennen,
// Klick erlaubt?, Enter erlaubt?. Die Selbsttests (`--selftest-mouse-target`) prüfen genau diese Funktionen.
// Der Teil, der wirklich Fenster nach vorne holt und einfügt, steht in MouseTarget.swift.

/// Koordinaten: Cocoa (NSScreen/NSEvent) zählt von UNTEN links, CG/AX (Fensterliste, Bedienungshilfen, Maus-Ereignisse)
/// von OBEN links. Beide haben ihren Ursprung am Hauptbildschirm (dem mit der Menüleiste, Cocoa-Rahmen bei 0,0) –
/// deshalb genügt für ALLE Bildschirme die Höhe des Hauptbildschirms, auch für Monitore links davon (x < 0)
/// oder darüber (Cocoa y > Höhe → CG y < 0).
enum MTGeometry {
    /// Höhe des Hauptbildschirms (Cocoa-Rahmen mit Ursprung 0,0; sonst der erste)
    static func primaryHeight(_ cocoaFrames: [CGRect]) -> CGFloat {
        (cocoaFrames.first { $0.origin == .zero } ?? cocoaFrames.first)?.height ?? 0
    }
    static func cocoaToCG(_ p: CGPoint, primaryHeight h: CGFloat) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
    static func cgToCocoa(_ p: CGPoint, primaryHeight h: CGFloat) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
    static func cocoaRectToCG(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
    /// Bildschirm (Index in `cocoaFrames`), auf dem der CG-Punkt liegt. Rand: oben/links gehört dazu, unten/rechts nicht.
    static func screenIndex(cg p: CGPoint, cocoaFrames: [CGRect]) -> Int? {
        let h = primaryHeight(cocoaFrames)
        return cocoaFrames.firstIndex { cocoaRectToCG($0, primaryHeight: h).contains(p) }
    }
}

/// Ein Eintrag aus CGWindowListCopyWindowInfo (vorne → hinten)
struct MTWindowInfo: Equatable {
    var id: CGWindowID
    var pid: pid_t
    var owner: String
    var bundle: String = ""
    var layer: Int = 0
    var alpha: Double = 1
    /// CG-Koordinaten (oben links)
    var bounds: CGRect
    /// Nur mit Bildschirmaufnahme-Recht gefüllt – sonst leer
    var title: String = ""

    init(id: CGWindowID, pid: pid_t, owner: String, bundle: String = "", layer: Int = 0, alpha: Double = 1, bounds: CGRect, title: String = "") {
        self.id = id; self.pid = pid; self.owner = owner; self.bundle = bundle; self.layer = layer; self.alpha = alpha; self.bounds = bounds; self.title = title
    }

    init?(_ d: [String: Any], bundle: (pid_t) -> String = { _ in "" }) {
        guard let n = d[kCGWindowNumber as String] as? Int, let pid = d[kCGWindowOwnerPID as String] as? Int,
              let b = d[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        id = CGWindowID(n); self.pid = pid_t(pid)
        owner = d[kCGWindowOwnerName as String] as? String ?? ""
        layer = d[kCGWindowLayer as String] as? Int ?? 0
        alpha = d[kCGWindowAlpha as String] as? Double ?? 1
        bounds = r
        title = d[kCGWindowName as String] as? String ?? ""
        self.bundle = bundle(self.pid)
    }
}

enum MTRules {
    // MARK: Fensterliste

    /// Durchsichtige Helfer-Fenster, durch die hindurch gezielt wird (nie selbst Ziel): ClipVault, DimAll/Hammerspoon.
    /// Eigene Fenster (Pille, Karten, Hub) fallen über die eigene PID heraus.
    static let passThroughBundles: Set<String> = ["app.flowdictation.clipvault", "org.hammerspoon.Hammerspoon", "app.flowdictation.flow"]
    static let passThroughOwners: Set<String> = ["ClipVault", "clipvault", "Hammerspoon", "dimctl", "dimosd", "Flow", "Flow"]
    /// Systemteile auf Ebene 0, die nie Ziel sind
    static let systemOwners: Set<String> = ["Window Server", "Dock", "WindowManager", "Control Center", "Notification Center",
                                            "Screenshot", "screencaptureui", "Spotlight", "SystemUIServer", "loginwindow"]
    static let minSize: CGFloat = 40

    enum Pick: Equatable {
        /// Fenster-Kandidaten (vorne → hinten, höchstens 4), `covered` = etwas Sichtbares liegt an dem Punkt darüber
        /// (dann kein Klick – er könnte die Pille oder ein fremdes Fenster treffen)
        case windows([MTWindowInfo], covered: Bool)
        /// Maus zeigt auf Dock, Menüleiste, Spotlight … → normales Verhalten
        case blocked(owner: String, layer: Int)
        case none
    }

    static func isPassThrough(_ w: MTWindowInfo, ownPID: pid_t) -> Bool {
        w.pid == ownPID || passThroughBundles.contains(w.bundle) || passThroughOwners.contains(w.owner)
    }

    /// Wählt aus der Fensterliste (vorne → hinten) die normalen Fenster unter dem Punkt (CG-Koordinaten).
    static func pick(_ list: [MTWindowInfo], at p: CGPoint, ownPID: pid_t) -> Pick {
        var covered = false
        var out: [MTWindowInfo] = []
        for w in list where w.bounds.contains(p) && w.alpha > 0.01 {
            if isPassThrough(w, ownPID: ownPID) { covered = true; continue }   // eigene/ClipVault-Fenster: hindurch, aber kein Klick
            if w.layer != 0 {
                // Dock, Menüleiste, Mitteilungen, Spotlight … liegt oben → die Maus zeigt NICHT auf ein Fenster
                if out.isEmpty { return .blocked(owner: w.owner, layer: w.layer) }
                continue
            }
            if systemOwners.contains(w.owner) || w.bounds.width < minSize || w.bounds.height < minSize {
                if out.isEmpty { covered = true }
                continue
            }
            out.append(w)
            if out.count >= 4 { break }
        }
        return out.isEmpty ? .none : .windows(out, covered: covered)
    }

    // MARK: Fenster ↔ Bedienungshilfen-Fenster

    /// Bestes AX-Fenster zum CG-Fenster: zuerst exakte Fenster-Nummer, sonst Rahmen (±3 pt) und – falls bekannt – Titel.
    static func matchWindow(target: MTWindowInfo, candidates: [(id: CGWindowID?, frame: CGRect?, title: String?)]) -> Int? {
        if let i = candidates.firstIndex(where: { $0.id == target.id }) { return i }
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3 && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
        }
        let byFrame = candidates.indices.filter { i in candidates[i].frame.map { close($0, target.bounds) } ?? false }
        if byFrame.count == 1 { return byFrame[0] }
        if !target.title.isEmpty, let i = byFrame.first(where: { candidates[$0].title == target.title }) { return i }
        if byFrame.count > 1 { return byFrame[0] }
        // Rahmen weicht ab (z. B. Schatten, Vollbild-Übergang): gleicher Titel reicht, wenn er eindeutig ist
        if !target.title.isEmpty {
            let byTitle = candidates.indices.filter { candidates[$0].title == target.title }
            if byTitle.count == 1 { return byTitle[0] }
        }
        return nil
    }

    // MARK: Textfeld erkennen

    /// Ein Knoten des Bedienungshilfen-Baums, nur die Eigenschaften, die die Regeln brauchen
    struct Node: Equatable {
        var role: String
        var subrole: String = ""
        /// Chromium/Electron: AXDOMClassList (z. B. „xterm“, „monaco-editor“)
        var classes: [String] = []
        /// AXEditable (WebKit) bzw. „hat eine Einfügemarke“ (AXInsertionPointLineNumber)
        var editableFlag = false
        var hasInsertionPoint = false
        /// Chromium: liegt in einem contenteditable (AXEditableAncestor)
        var hasEditableAncestor = false
        init(role: String, subrole: String = "", classes: [String] = [], editableFlag: Bool = false, hasInsertionPoint: Bool = false, hasEditableAncestor: Bool = false) {
            self.role = role; self.subrole = subrole; self.classes = classes; self.editableFlag = editableFlag
            self.hasInsertionPoint = hasInsertionPoint; self.hasEditableAncestor = hasEditableAncestor
        }
    }

    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    static func isSecure(_ n: Node) -> Bool { n.role == "AXSecureTextField" || n.subrole == "AXSecureTextField" }

    /// Gemessen 27.09. (VS Code): Chromium meldet AXInsertionPointLineNumber an JEDEM Vorfahren der Einfügemarke
    /// (alle Gruppen bis zum Fenster) – das allein heißt also nicht „Textfeld“. Zählt nur zusammen mit contenteditable.
    static func isEditable(_ n: Node) -> Bool {
        if isSecure(n) { return false }
        return textRoles.contains(n.role) || n.subrole == "AXSearchField" || n.editableFlag || n.hasEditableAncestor
    }

    enum EditablePick: Equatable { case at(Int), secure, none }

    /// Element unter der Maus + Vorfahren (Index 0 = Element selbst): erstes Textfeld in höchstens `maxUp` Ebenen.
    /// Passwortfeld auf dem Weg → nie Ziel.
    static func pickEditable(_ chain: [Node], maxUp: Int = 4) -> EditablePick {
        for (i, n) in chain.prefix(maxUp + 1).enumerated() {
            if isSecure(n) { return .secure }
            if isEditable(n) { return .at(i) }
            if n.role == "AXWindow" || n.role == "AXApplication" { break }
        }
        return .none
    }

    // MARK: Apps

    /// Terminals, in denen ein Klick nur den Fokus setzt
    static let nativeTerminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                               "dev.warp.Warp", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
                                               "co.zeit.hyper", "org.tabby"]
    /// Editoren mit eingebautem Terminal (xterm.js) – Klick nur, wenn die Maus wirklich über dem Terminal steht
    static let xtermEditors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
                                            "com.exafunction.windsurf", "com.google.antigravity"]
    /// Chat-Apps: Enter = Senden
    static let chatApps: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
                                        "desktop.WhatsApp", "WhatsApp", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram", "org.telegram.desktop",
                                        "com.hnc.Discord", "org.whispersystems.signal-desktop", "com.microsoft.teams2"]
    static let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.brave.Browser",
                                        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.apple.Safari", "com.vivaldi.Vivaldi",
                                        "org.mozilla.firefox", "com.operasoftware.Opera"]
    /// Chromium-Browser: Web-Inhalt erscheint in den Bedienungshilfen erst mit AXEnhancedUserInterface
    /// (AXManualAccessibility kennt nur Electron – Chrome antwortet darauf mit -25205, gemessen 27.09.)
    static let chromiumBrowsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.brave.Browser",
                                                "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
    /// Web-Chats im Browser (Host bzw. Host-Endung)
    static let chatHosts: [String] = ["chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "web.whatsapp.com",
                                      "messages.google.com", "app.slack.com", "discord.com", "web.telegram.org", "perplexity.ai",
                                      "chat.mistral.ai", "copilot.microsoft.com", "chat.deepseek.com", "grok.com", "teams.microsoft.com"]

    static func hasClass(_ chain: [Node], _ needle: String) -> Bool {
        chain.contains { n in n.classes.contains { $0.lowercased().contains(needle) } }
    }

    // MARK: Klick erlaubt? (Methode c)

    /// Rollen, die man nie blind anklickt (Knöpfe, Links, Reiter, Menüs, Trenner, Schieber …)
    static let clickableRoles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                              "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXTabGroup", "AXToolbar", "AXSlider",
                                              "AXIncrementor", "AXDisclosureTriangle", "AXScrollBar", "AXSplitter", "AXColorWell",
                                              "AXSegmentedControl", "AXImage", "AXCell", "AXRow", "AXOutline", "AXList", "AXTable",
                                              "AXDateField", "AXTimeField", "AXValueIndicator", "AXHandle", "AXLevelIndicator"]
    /// In nativen Terminals: nur auf der Terminal-Fläche selbst
    static let terminalSurfaceRoles: Set<String> = ["AXTextArea", "AXScrollArea", "AXGroup", "AXStaticText", "AXUnknown", "AXLayoutArea", "AXWindow"]

    /// Darf an dem Punkt ein einzelner Linksklick den Fokus setzen?
    /// Nur Terminals, nur wenn nichts darüber liegt, nur auf der Terminal-Fläche, nie auf Knöpfen/Links/Reitern.
    static func clickAllowed(bundle: String, chain: [Node], covered: Bool) -> Bool {
        guard !covered, let first = chain.first else { return false }
        if chain.contains(where: isSecure) { return false }
        if chain.prefix(4).contains(where: { clickableRoles.contains($0.role) }) { return false }
        if nativeTerminals.contains(bundle) { return terminalSurfaceRoles.contains(first.role) }
        if xtermEditors.contains(bundle) {
            // xterm.js: Klick setzt nur den Fokus ins Terminal. Editor (Monaco), Seitenleiste, Reiter: nie.
            return hasClass(chain, "xterm") && !hasClass(chain, "monaco-editor")
        }
        return false
    }

    // MARK: Enter erlaubt? (Danach automatisch abschicken)

    enum SendDecision: Equatable {
        case send
        case no(String)
        var allowed: Bool { self == .send }
    }

    /// Wann „Danach automatisch abschicken“ wirklich Enter drückt. `chain` = fokussiertes Element + Vorfahren NACH dem Einfügen.
    ///
    /// Regel (Enter heißt dort „senden“, nicht „neue Zeile“):
    ///   • Terminals (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm, Hyper, Tabby) – immer
    ///   • VS Code / Cursor / Windsurf / Antigravity – nur im Terminal (xterm, z. B. Claude Code), in Webview-Chats (Claude-Code-
    ///     Erweiterung) und in Chat-Eingaben (Copilot); NIE im Code-Editor (Monaco), dort wäre Enter nur eine neue Zeile
    ///   • Chat-Apps: Claude, ChatGPT, Nachrichten, WhatsApp, Slack, Telegram, Discord, Signal, Teams
    ///   • Browser: nur Textfelder INNERHALB einer Webseite mit Chat-Adresse (chatgpt.com, claude.ai, gemini, WhatsApp Web, …),
    ///     nie die Adressleiste, nie andere Seiten (Formulare, Google Docs, Mail)
    ///   • alles andere (Mail, Notizen, Pages, Word, TextEdit, Xcode, Suchfelder …): nie
    static func autoSend(bundle: String, chain: [Node], webHost: String?) -> SendDecision {
        if chain.contains(where: isSecure) { return .no("Passwortfeld") }
        if nativeTerminals.contains(bundle) { return .send }
        if xtermEditors.contains(bundle) {
            if hasClass(chain, "xterm") { return .send }
            if hasClass(chain, "monaco-editor") {
                return hasClass(chain, "interactive-input") || hasClass(chain, "chat-input") || hasClass(chain, "chat-editor")
                    ? .send : .no("Code-Editor – Enter wäre eine neue Zeile")
            }
            // Webview (Erweiterung wie Claude Code): zweite Webseite im Fenster
            if chain.filter({ $0.role == "AXWebArea" }).count >= 2, chain.first.map(isEditable) ?? false { return .send }
            return .no("kein Terminal/Chat im Editor")
        }
        if chatApps.contains(bundle) { return .send }
        if browsers.contains(bundle) {
            guard chain.contains(where: { $0.role == "AXWebArea" }) else { return .no("Browser außerhalb der Seite (Adressleiste?)") }
            guard let first = chain.first, isEditable(first) || first.hasEditableAncestor else { return .no("kein Textfeld") }
            guard let host = webHost?.lowercased(), isChatHost(host) else { return .no("keine Chat-Seite") }
            return .send
        }
        return .no("App nicht auf der Enter-Liste")
    }

    static func isChatHost(_ host: String) -> Bool {
        chatHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Hat das Einfügen wirklich geklappt? Lesbarer Feldinhalt muss den Text (Ende, normalisiert) enthalten.
    /// Leeres/unlesbares Feld (Terminals, xterm-Hilfsfeld) → nur die Fokus-Prüfung zählt.
    static func pasteConfirmed(inserted: String, fieldValue: String?, valueBefore: String?) -> Bool? {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "[\\s\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        guard let v = fieldValue, !norm(v).isEmpty else { return nil }
        if let b = valueBefore, norm(b) == norm(v) { return false }   // unverändert → nicht angekommen
        let tail = String(norm(inserted).suffix(24))
        return tail.isEmpty ? nil : norm(v).contains(tail)
    }

    /// Fenstertitel für das Protokoll: kurz, ohne Zeilenumbrüche
    static func shortTitle(_ t: String, max: Int = 18) -> String {
        let s = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }
}
