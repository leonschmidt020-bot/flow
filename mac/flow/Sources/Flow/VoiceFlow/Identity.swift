import Foundation

// MARK: - Wer benutzt diesen Mac – und mit wem wird geteilt?
// Keine Namen im Code: der eigene Name kommt aus den Einstellungen (Vorgabe: Vorname des macOS-Kontos),
// der Partner aus den Einstellungen oder aus der ClipVault-Kopplung (~/.config/flow-clipvault).

enum Identity {
    /// Vorname des macOS-Kontos („Alex Beispiel“ → „Alex“), sonst der Kurzname
    static let systemFirstName: String = {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        if let first = full.split(separator: " ").first, !first.isEmpty { return String(first) }
        let short = NSUserName()
        return short.prefix(1).uppercased() + short.dropFirst()
    }()

    /// Eigener Name für Oberfläche/Transkripte (Main-Thread; Hintergrund: `Settings.frozen.myName`)
    static var myName: String { name(Settings.shared.myName) }
    /// Thread-sicher für Hintergrund-Arbeit (Whisper-Hinweis, Auswertung)
    static var myNameFrozen: String { name(Settings.frozen.myName) }

    private static func name(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? systemFirstName : t
    }

    // MARK: Partner (geteilter ClipVault-Tresor)

    /// Name des Partners, falls bekannt: Einstellungen → ClipVault-Kopplung (status.txt `sync_partner=`) → shared-partner.txt
    static var partnerName: String? {
        let own = Settings.shared.partnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return clipVaultPartner
    }

    /// Nur aus ClipVault (ohne Einstellungen) – für die Anzeige „erkannt aus der Kopplung“
    static var clipVaultPartner: String? {
        let base = ClipVaultClient.base
        let status = (try? String(contentsOf: base.appendingPathComponent("status.txt"), encoding: .utf8)) ?? ""
        let paired = status.split(separator: "\n").contains { $0 == "sync=cloudflare" }
        if paired, let line = status.split(separator: "\n").first(where: { $0.hasPrefix("sync_partner=") }) {
            let v = line.dropFirst("sync_partner=".count).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        let f = (try? String(contentsOf: base.appendingPathComponent("shared-partner.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return f.isEmpty ? nil : f
    }

    enum Case { case nominative, accusative, dative }

    /// „Nico“ – oder ohne bekannten Namen „dein Partner / deinen Partner / deinem Partner“
    static func partner(_ c: Case, capitalized: Bool = false) -> String {
        if let n = partnerName { return n }
        let s: String
        switch c {
        case .nominative: s = "dein Partner"
        case .accusative: s = "deinen Partner"
        case .dative: s = "deinem Partner"
        }
        return capitalized ? s.prefix(1).uppercased() + s.dropFirst() : s
    }

    /// Name, mit dem ClipVault eigene geteilte Einträge markiert (`createdBy`): shared-me.txt → Vorname des Kontos
    static var clipVaultMe: String {
        let f = (try? String(contentsOf: ClipVaultClient.base.appendingPathComponent("shared-me.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return f.isEmpty ? systemFirstName : f
    }

    /// Stammt ein geteilter Eintrag von mir? Genau dieselbe Regel wie ClipVault selbst (createdBy = shared-me.txt / Vorname).
    static func isMe(_ createdBy: String) -> Bool {
        let c = createdBy.trimmingCharacters(in: .whitespaces).lowercased()
        let m = clipVaultMe.trimmingCharacters(in: .whitespaces).lowercased()
        return !c.isEmpty && (c == m || c.hasPrefix(m + " "))
    }
}

// MARK: - Version (build.sh schreibt VERSION + git describe in die Info.plist)

enum AppVersion {
    /// z. B. „1.1.0“
    static var short: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev" }
    /// z. B. „v1.1.0-3-gab12cd3“ oder „ed8cebb-dirty“
    static var git: String? { Bundle.main.infoDictionary?["FlowGitDescribe"] as? String }
    /// voller Commit, aus dem diese App gebaut wurde (build.sh) – der Updater vergleicht ihn mit update-failed.json
    static var commit: String? { Bundle.main.infoDictionary?["FlowGitCommit"] as? String }
    static var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    /// „Flow 1.1.0 (ed8cebb, 202609261930)“
    static var line: String {
        var extra: [String] = []
        if let g = git, !g.isEmpty { extra.append(g) }
        if let b = build, !b.isEmpty { extra.append(b) }
        return "Flow \(short)" + (extra.isEmpty ? " (Entwickler-Build)" : " (\(extra.joined(separator: ", ")))")
    }
}
