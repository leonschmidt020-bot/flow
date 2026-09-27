import AppKit
import AVFoundation

/// Fehlerbericht: alles, was man braucht, um ein Problem auf einem anderen Mac zu finden –
/// Version, Freigaben, Einstellungen, Whisper, ClipVault-Sync und die letzten Protokollzeilen.
/// Diktierte Texte werden NICHT mitgeschickt (Diktat-Zeilen werden gekürzt).
/// Versand: in den geteilten ClipVault-Tresor (Ende-zu-Ende verschlüsselt) + Zwischenablage.
enum Diagnose {
    static func report() -> String {
        var r: [String] = []
        let fz = Settings.shared
        r.append("# Flow-Fehlerbericht")
        r.append("Von: \(Identity.myName) · \(ISO8601DateFormatter().string(from: Date()))")
        r.append("Version: \(AppVersion.line) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        r.append("App: \(Bundle.main.bundlePath) · Quelle: \(Updater.sourceDir ?? "–")")
        r.append("")
        r.append("## Freigaben")
        r.append("Mikrofon: \(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "ja" : "NEIN")")
        r.append("Bedienungshilfen: \(AXIsProcessTrusted() ? "ja" : "NEIN")")
        r.append("Eingabeüberwachung: \(CGPreflightListenEventAccess() ? "ja" : "NEIN")")
        r.append("fn auf „Nichts tun“: \(FnKeySetting.isNothing ? "ja" : "NEIN")")
        r.append("")
        r.append("## Einstellungen")
        r.append("Motor: \(fz.engine.rawValue) · Sprache: \(fz.languageMode.rawValue) · Nur meine Stimme: \(fz.onlyMyVoice) · Mac-Ton filtern: \(fz.filterMacAudio)")
        r.append("Aus Korrekturen lernen: \(Settings.shared.learnFromEdits) · Wörterbuch: \(fz.dictionary.count) Einträge · Stimme eingelernt: \(VoiceID.isEnrolled)")
        r.append("Whisper bereit: \(WhisperEngine.shared.ready) · Auto-Update: \(Updater.enabled)")
        r.append("")
        r.append("## ClipVault / geteilter Tresor")
        r.append(clipvault(["sync", "status"]).trimmingCharacters(in: .whitespacesAndNewlines))
        if let st = try? String(contentsOf: ClipVaultClient.base.appendingPathComponent("status.txt"), encoding: .utf8) {
            r.append(st.split(separator: "\n").filter { $0.hasPrefix("sync") || $0.hasPrefix("shared") || $0.hasPrefix("version") }.joined(separator: "\n"))
        }
        let cvLog = tail(ClipVaultClient.base.appendingPathComponent("clipvault.log"), lines: 25)
            .filter { $0.contains("Sync") || $0.contains("Geteilt") || $0.contains("Befehl") || $0.contains("gestartet") }
        if !cvLog.isEmpty { r.append("ClipVault-Log:"); r += cvLog }
        r.append("")
        r.append("## Flow-Protokoll (letzte Zeilen, ohne diktierte Texte)")
        r += tail(Paths.base.appendingPathComponent("flow.log"), lines: 160).map(scrub)
        return r.joined(separator: "\n")
    }

    /// Diktat-Zeilen enthalten (bei „Texte protokollieren“) den Text → nach der Zeitangabe abschneiden
    static func scrub(_ line: String) -> String {
        if line.contains(" Diktat "), let r = line.range(of: "gesamt ") {
            let rest = line[r.upperBound...]
            let t = rest.prefix { $0 != ":" }
            return String(line[..<r.upperBound]) + t + " [Text entfernt]"
        }
        // Audit 27.09.2026: auch alle anderen Zeilen tragen Text in „…“ (gelernte Wörter, Verhörer, Fenstertitel im Meeting,
        // Bildschirm-Ende, bei „Texte protokollieren“ ganze Diktate) – der Bericht geht an den Partner, also alles Zitierte raus.
        if line.contains("„") {
            return line.replacingOccurrences(of: "„[^“]*“?", with: "„…“", options: .regularExpression)
        }
        return line
    }

    static func tail(_ url: URL, lines n: Int) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(s.split(separator: "\n", omittingEmptySubsequences: true).suffix(n)).map(String.init)
    }

    @discardableResult
    static func clipvault(_ args: [String]) -> String {
        let bin = ClipVaultClient.base.appendingPathComponent("clipvault").path
        guard FileManager.default.isExecutableFile(atPath: bin) else { return "ClipVault nicht installiert" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return "ClipVault startet nicht: \(error.localizedDescription)" }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Bericht erstellen, in die Zwischenablage legen und an den Partner teilen. Antwort auf dem Main-Thread.
    static func send(done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = report()
            var msg = "Fehlerbericht kopiert"
            let add = clipvault(["send", "addText", "text=\(text)"])
            if let d = add.split(separator: "\n").last.flatMap({ $0.data(using: .utf8) }),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["id"] as? String {
                let sh = clipvault(["send", "share", "id=\(id)"])
                if sh.contains("\"ok\":true") || sh.contains("\"ok\" : true") { msg = "Fehlerbericht an \(Identity.partner(.accusative)) geschickt" }
            }
            log("Fehlerbericht erstellt (\(text.count) Zeichen) – \(msg)")
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(text, forType: .string)
                done(msg)
            }
        }
    }
}
