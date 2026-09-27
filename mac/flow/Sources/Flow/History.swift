import AppKit
import Combine

/// Verlauf der Diktate (für Start-Übersicht, Statistik, „nochmal kopieren“).
/// Liegt lokal in ~/.config/flow/verlauf.json und löscht sich mit der normalen Frist (Standard 3 Tage).
struct DictationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var app: String
    var bundleID: String
    /// Sprechdauer in Sekunden
    var duration: Double
    var words: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()
    @Published private(set) var records: [DictationRecord] = []
    private let url = Paths.base.appendingPathComponent("verlauf.json")
    private let queue = DispatchQueue(label: "flow.history")

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let r = try? dec.decode([DictationRecord].self, from: d) {
            records = r.sorted { $0.date > $1.date }
        }
    }

    func add(text: String, duration: Double) {
        let app = NSWorkspace.shared.frontmostApplication
        let r = DictationRecord(date: Date(), text: text, app: app?.localizedName ?? "–",
                                bundleID: app?.bundleIdentifier ?? "", duration: duration)
        records.insert(r, at: 0)
        if records.count > 2000 { records.removeLast(records.count - 2000) }
        save()
    }

    func delete(_ id: UUID) { records.removeAll { $0.id == id }; save() }
    func clear() { records = []; save() }

    /// Gleiche Frist wie Meetings und Log
    func prune() {
        let days = Settings.shared.retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let before = records.count
        records.removeAll { $0.date < cutoff }
        if records.count != before { save() }
    }

    private func save() {
        let snapshot = records
        let url = self.url
        queue.async {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            if let d = try? enc.encode(snapshot) { try? d.write(to: url, options: [.atomic]) }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: Statistik

    struct Stats { let words: Int; let dictations: Int; let wpm: Int; let minutesSaved: Int }

    /// Tippen ~40 Wörter/Minute – Differenz zur Sprechzeit = gesparte Zeit.
    func stats(since: Date) -> Stats {
        let r = records.filter { $0.date >= since }
        let words = r.reduce(0) { $0 + $1.words }
        let speak = r.reduce(0) { $0 + $1.duration }
        let wpm = speak > 5 ? Int(Double(words) / (speak / 60)) : 0
        let typingMinutes = Double(words) / 40
        let saved = max(0, Int((typingMinutes - speak / 60).rounded()))
        return Stats(words: words, dictations: r.count, wpm: wpm, minutesSaved: saved)
    }
}
