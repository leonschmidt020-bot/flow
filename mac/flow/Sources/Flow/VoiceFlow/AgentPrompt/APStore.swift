import Foundation
import SwiftUI

// MARK: - Agent-Prompts: Einstellungen + Verlauf (~/.config/flow/prompts/, je Prompt eine .md-Datei)
//
// Jede Datei: Kopf (--- … ---) mit id/Datum/App/Quelle, dann der Prompt, dann nach der Marke das Original-Diktat.
// Schreiben immer atomar (temporäre Datei + Umbenennen), Rechte 0600, Ordner 0700. Höchstens 50 Stück.
// Kaputte Dateien werden beim Laden nicht gelöscht, sondern nach prompts/defekt/ verschoben (und übersprungen).

enum APMode: String, Codable, CaseIterable, Identifiable {
    /// Auf Zuruf + automatischer Vorschlag bei langen Aufträgen
    case on
    /// Nur „Prompt: …“ / „Ich mache jetzt einen Prompt …“
    case explicitOnly
    case off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .on: return "An"
        case .explicitOnly: return "Nur auf Zuruf"
        case .off: return "Aus"
        }
    }
    var detail: String {
        switch self {
        case .on: return "„Prompt: …“ baut sofort einen Prompt. Lange Aufträge an einen Agenten erkennt Flow selbst und bietet es gleich nach dem Einfügen an – „Einfügen“ ersetzt dann dein Diktat durch den Prompt (nur mit Claude-CLI)."
        case .explicitOnly: return "Nur wenn du „Prompt: …“ oder „Ich mache jetzt einen Prompt …“ sagst."
        case .off: return "Nie – „Prompt …“ wird normal eingefügt."
        }
    }
}

struct APPrefs: Codable, Equatable {
    var mode: APMode = .on
    /// Claude-Modell für den Umbau (Sonnet: gemessen ~9–16 s; Haiku war im Test mit 43–64 s viel langsamer)
    var model = "sonnet"
    /// `claude --effort` (Standard: low)
    var effort = "low"
    var timeout: Double = 45
    /// Ohne Claude (fehlt/Fehler/Zeitlimit): Regel-Prompt bauen statt aufgeben
    var ruleFallback = true

    static let file = "agent-prompts.json"
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(APMode.self, forKey: .mode)) ?? .on
        model = (try? c.decode(String.self, forKey: .model)) ?? "sonnet"
        effort = (try? c.decode(String.self, forKey: .effort)) ?? "low"
        timeout = (try? c.decode(Double.self, forKey: .timeout)) ?? 45
        ruleFallback = (try? c.decode(Bool.self, forKey: .ruleFallback)) ?? true
    }
}

/// Ein gespeicherter Prompt – immer mit dem Original-Diktat
struct APRecord: Identifiable, Equatable {
    var id: String
    var created: Date
    var prompt: String
    var original: String
    var appName: String = ""
    var windowTitle: String = ""
    /// „claude/sonnet“, „regeln“ – und warum (z. B. „Claude nicht erreichbar“)
    var source: String = ""
    var note: String = ""
    /// „zuruf“ oder „vorschlag“
    var trigger: String = "zuruf"
    var buildMs: Int = 0

    var gist: APGist { APGist.of(prompt) }
    var title: String { let g = gist.goal; return g.isEmpty ? "Agent-Prompt" : g }
    var byRules: Bool { source.hasPrefix("regeln") }
}

final class APStore: ObservableObject {
    static let shared = APStore(dir: Paths.base.appendingPathComponent("prompts"))
    static let maxCount = 50
    static let originalMark = "<!-- flow:original -->"

    let dir: URL
    @Published private(set) var records: [APRecord] = []
    @Published var selectedID: String?
    /// Reiter auf der Scratchpad-Seite („notizen“ | „prompts“) – „Ansehen“ an der Karte springt hierher
    @Published var hubTab = "notizen"
    /// Anzahl der beim letzten Laden aussortierten Dateien (Tests/Protokoll)
    private(set) var quarantined = 0
    private let io = DispatchQueue(label: "flow.agentprompt.store")

    init(dir: URL, load: Bool = true) {
        self.dir = dir
        if load { reload() }
    }

    // MARK: Lesen

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var out: [APRecord] = []
        var bad = 0
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
        for f in files {
            let u = dir.appendingPathComponent(f)
            if let s = try? String(contentsOf: u, encoding: .utf8), let r = APStore.parse(s) { out.append(r) }
            else { bad += 1; quarantine(u) }
        }
        // Übrig gebliebene Schreib-Reste (Absturz mitten im Schreiben) aufräumen
        for f in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []) where f.hasPrefix(".tmp-") {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }
        quarantined = bad
        if bad > 0 { log("Agent-Prompts: \(bad) kaputte Datei(en) nach prompts/defekt/ verschoben") }
        records = out.sorted { $0.created > $1.created }
        if selectedID == nil || !records.contains(where: { $0.id == selectedID }) { selectedID = records.first?.id }
    }

    func record(_ id: String?) -> APRecord? { records.first { $0.id == id } }

    private func quarantine(_ u: URL) {
        let d = dir.appendingPathComponent("defekt")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = d.appendingPathComponent(u.lastPathComponent + "-" + String(Int(Date().timeIntervalSince1970)))
        try? FileManager.default.moveItem(at: u, to: target)
    }

    // MARK: Schreiben

    @discardableResult
    func add(_ r: APRecord) -> APRecord {
        write(r)
        records.removeAll { $0.id == r.id }
        records.insert(r, at: 0)
        selectedID = r.id
        trim()
        return r
    }

    func delete(_ id: String) {
        let fm = FileManager.default
        if let r = record(id) { try? fm.removeItem(at: fileURL(r)) }
        records.removeAll { $0.id == id }
        if selectedID == id { selectedID = records.first?.id }
    }

    private func trim() {
        guard records.count > APStore.maxCount else { return }
        for r in records.dropFirst(APStore.maxCount) { try? FileManager.default.removeItem(at: fileURL(r)) }
        records = Array(records.prefix(APStore.maxCount))
    }

    func fileURL(_ r: APRecord) -> URL {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd_HHmmss"
        return dir.appendingPathComponent("\(df.string(from: r.created))_\(r.id.prefix(8)).md")
    }

    /// Atomar: in eine temporäre Datei im selben Ordner schreiben, dann umbenennen (nie eine halbe Datei)
    func write(_ r: APRecord) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let final = fileURL(r)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).md")
        do {
            try Data(APStore.serialize(r).utf8).write(to: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: final.path) { _ = try fm.replaceItemAt(final, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: final) }
        } catch {
            try? fm.removeItem(at: tmp)
            log("Agent-Prompt speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: Format

    static func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }

    static func serialize(_ r: APRecord) -> String {
        let iso = ISO8601DateFormatter()
        var s = "---\n"
        s += "id: \(r.id)\n"
        s += "created: \(iso.string(from: r.created))\n"
        s += "app: \(oneLine(r.appName))\n"
        s += "window: \(oneLine(r.windowTitle))\n"
        s += "source: \(oneLine(r.source))\n"
        s += "note: \(oneLine(r.note))\n"
        s += "trigger: \(oneLine(r.trigger))\n"
        s += "build_ms: \(r.buildMs)\n"
        s += "---\n\n"
        s += r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "\n\n\(originalMark)\n\n"
        s += r.original.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "\n"
        return s
    }

    static func parse(_ s: String) -> APRecord? {
        guard s.hasPrefix("---\n") else { return nil }
        let body = s.dropFirst(4)
        guard let end = body.range(of: "\n---\n") else { return nil }
        var meta: [String: String] = [:]
        for line in body[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: true) {
            guard let c = line.firstIndex(of: ":") else { return nil }
            meta[String(line[..<c]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        }
        let rest = String(body[end.upperBound...])
        guard let id = meta["id"], !id.isEmpty, let cs = meta["created"], let created = ISO8601DateFormatter().date(from: cs),
              let mark = rest.range(of: "\n\(originalMark)\n") ?? rest.range(of: originalMark) else { return nil }
        let prompt = rest[..<mark.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let original = rest[mark.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return APRecord(id: id, created: created, prompt: prompt, original: original, appName: meta["app"] ?? "",
                        windowTitle: meta["window"] ?? "", source: meta["source"] ?? "", note: meta["note"] ?? "",
                        trigger: meta["trigger"] ?? "zuruf", buildMs: Int(meta["build_ms"] ?? "") ?? 0)
    }
}
