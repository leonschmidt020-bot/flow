import AppKit

/// VS Code gibt seinen Text (auch das Terminal) nur an Bedienungshilfen heraus, wenn
/// "editor.accessibilitySupport": "on" gesetzt ist – sonst kann der Wort-Lerner dort nichts sehen
/// (gemessen: 517 AX-Knoten, 0 Zeichen). Einmal nachfragen, auf Wunsch die Einstellung selbst setzen (mit Sicherung).
enum VSCodeAccessibility {
    static let bundleID = "com.microsoft.VSCode"
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Code/User/settings.json")
    }
    private static let askedKey = "vf.vscodeA11yAsked"

    static var isOn: Bool {
        guard let s = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return s.range(of: #""editor\.accessibilitySupport"\s*:\s*"on""#, options: .regularExpression) != nil
    }

    /// Vom Wort-Lerner aufrufen, wenn VS Code 0 Zeichen geliefert hat
    static func offerIfNeeded() {
        DispatchQueue.main.async {
            guard !isOn, !UserDefaults.standard.bool(forKey: askedKey) else { return }
            UserDefaults.standard.set(true, forKey: askedKey)
            log("Lernen: VS Code gibt keinen Text heraus → Hinweis „accessibilitySupport“")
            VFNotify.shared.show(VFNotice(
                id: "vscode_a11y", title: "VS Code: Text nicht lesbar",
                text: "Damit Flow aus deinen Korrekturen in VS Code lernt, muss VS Code seinen Text freigeben. Einschalten?",
                illustration: "illu_wort_gelernt", fallbackSymbol: "chevron.left.forwardslash.chevron.right",
                primary: ("Einschalten", { enable() }), secondary: ("Nein", {}), timeout: 25))
        }
    }

    static func enable() {
        let url = settingsURL
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty { try? text.write(to: url.appendingPathExtension("vor-flow"), atomically: true, encoding: .utf8) }
        if text.range(of: #""editor\.accessibilitySupport"\s*:\s*"[a-z]+""#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: #""editor\.accessibilitySupport"\s*:\s*"[a-z]+""#,
                                             with: #""editor.accessibilitySupport": "on""#, options: .regularExpression)
        } else if let brace = text.firstIndex(of: "{") {
            let rest = text[text.index(after: brace)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = "\n    \"editor.accessibilitySupport\": \"on\"" + (rest.hasPrefix("}") ? "\n" : ",")
            text.insert(contentsOf: entry, at: text.index(after: brace))
        } else {
            text = "{\n    \"editor.accessibilitySupport\": \"on\"\n}\n"
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            log("VS Code: editor.accessibilitySupport = on gesetzt (Sicherung: settings.json.vor-flow)")
            AppDelegate.shared.pill.view.showToast("VS Code gibt seinen Text jetzt frei", seconds: 3)
        } catch {
            log("VS Code: Einstellung nicht geschrieben: \(error.localizedDescription)")
            AppDelegate.shared.pill.view.showToast("Konnte VS Code nicht umstellen – bitte selbst: Einstellungen › Accessibility Support › on", seconds: 5)
        }
    }
}
