import Foundation
import Combine

// MARK: - Flow: Langzeit-Statistik (ohne Text!)
//
// Der Diktat-Verlauf löscht sich nach `retentionDays`. Für Insights („Wörter gesamt“, Streak, WPM)
// braucht es Lebenszeit-Zahlen – deshalb hier nur Zähler pro Tag, niemals Text.
// Datei: ~/.config/flow/statistik.json (0600)

struct VFDayStats: Codable, Equatable {
    var words = 0
    var dictations = 0
    var speakSeconds = 0.0
    /// AppCategory.rawValue → Anzahl Diktate
    var categories: [String: Int] = [:]
    /// Bundle-ID → Anzahl Diktate (nur für „Apps genutzt“)
    var apps: [String: Int] = [:]
    var dictionaryFixes = 0
    var wordsCorrected = 0
}

final class VFStats: ObservableObject {
    static let shared = VFStats()

    /// Nur für Tests/Offscreen-Render umbiegen – VOR dem ersten Zugriff auf `shared` setzen.
    static var fileURL = Paths.base.appendingPathComponent("statistik.json")

    /// Schlüssel "yyyy-MM-dd" (lokale Zeit)
    @Published private(set) var days: [String: VFDayStats] = [:]
    private(set) var seededAt: Date?

    private let queue = DispatchQueue(label: "voiceflow.stats")
    private var saveScheduled = false

    private struct Stored: Codable {
        var version = 1
        var seededAt: Date?
        var days: [String: VFDayStats]
    }

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: VFStats.fileURL), let s = try? dec.decode(Stored.self, from: d) {
            days = s.days
            seededAt = s.seededAt
        } else {
            seedFromHistory()
        }
    }

    // MARK: Öffentliche Schnittstelle (aus der Diktat-Pipeline aufrufen)

    /// Nach jedem eingefügten Diktat. Threadsicher.
    func recordDictation(words: Int, seconds: Double, bundleID: String) {
        let date = Date()
        onMain {
            self.mutate(date) { d in
                d.words += max(0, words)
                d.dictations += 1
                d.speakSeconds += max(0, seconds)
                let cat = AppCategory.of(bundleID: bundleID).rawValue
                d.categories[cat, default: 0] += 1
                let key = bundleID.isEmpty ? "?" : bundleID.lowercased()
                d.apps[key, default: 0] += 1
            }
        }
    }

    /// Wenn Flow etwas korrigiert hat: `dictionary` = Wörterbuch-Ersetzungen, `corrected` = sonst korrigierte Wörter.
    func recordFix(dictionary: Int, corrected: Int) {
        guard dictionary > 0 || corrected > 0 else { return }
        let date = Date()
        onMain {
            self.mutate(date) { d in
                d.dictionaryFixes += max(0, dictionary)
                d.wordsCorrected += max(0, corrected)
            }
        }
    }

    // MARK: Auswertungen

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalDictations: Int { days.values.reduce(0) { $0 + $1.dictations } }
    var totalSeconds: Double { days.values.reduce(0) { $0 + $1.speakSeconds } }
    var dictionaryFixes: Int { days.values.reduce(0) { $0 + $1.dictionaryFixes } }
    var wordsCorrected: Int { days.values.reduce(0) { $0 + $1.wordsCorrected } }
    var totalFixes: Int { dictionaryFixes + wordsCorrected }

    /// Wörter pro Minute über die ganze Nutzung (0 = noch zu wenig Daten)
    var wpm: Int {
        let s = totalSeconds
        return s > 5 ? Int((Double(totalWords) / (s / 60)).rounded()) : 0
    }

    var appsUsed: Int { Set(days.values.flatMap { $0.apps.keys }.filter { $0 != "?" }).count }

    var categoryCounts: [AppCategory: Int] {
        var out: [AppCategory: Int] = [:]
        for d in days.values {
            for (k, v) in d.categories { out[AppCategory(rawValue: k) ?? .other, default: 0] += v }
        }
        return out
    }

    func day(_ date: Date) -> VFDayStats? { days[VFStats.key(date)] }

    func words(since: Date) -> Int {
        let k = VFStats.key(since)
        return days.filter { $0.key >= k }.reduce(0) { $0 + $1.value.words }
    }

    /// Tage am Stück bis heute (zählt auch, wenn heute noch nichts diktiert wurde, gestern aber schon)
    var currentStreak: Int {
        let cal = Calendar.current
        var d = cal.startOfDay(for: Date())
        if (day(d)?.dictations ?? 0) == 0 { d = cal.date(byAdding: .day, value: -1, to: d)! }
        var n = 0
        while (day(d)?.dictations ?? 0) > 0 {
            n += 1
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return n
    }

    var longestStreak: Int {
        let active = days.filter { $0.value.dictations > 0 }.keys.compactMap { VFStats.date($0) }.sorted()
        guard !active.isEmpty else { return 0 }
        let cal = Calendar.current
        var best = 1, run = 1
        for i in 1..<active.count {
            let diff = cal.dateComponents([.day], from: active[i - 1], to: active[i]).day ?? 0
            if diff == 1 { run += 1; best = max(best, run) } else if diff > 1 { run = 1 }
        }
        return best
    }

    /// Durchschnittliche WPM je Kalenderwoche (älteste zuerst), `weeks` Wochen bis heute. nil = keine Daten
    func weeklyWPM(weeks: Int) -> [(start: Date, wpm: Int?)] {
        let cal = Calendar(identifier: .iso8601)
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return (0..<weeks).reversed().map { back in
            let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek)!
            var w = 0, s = 0.0
            for i in 0..<7 {
                if let d = day(cal.date(byAdding: .day, value: i, to: start)!) { w += d.words; s += d.speakSeconds }
            }
            return (start, s > 5 ? Int((Double(w) / (s / 60)).rounded()) : nil)
        }
    }

    // MARK: Intern

    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }

    private func mutate(_ date: Date, _ f: (inout VFDayStats) -> Void) {
        let k = VFStats.key(date)
        var d = days[k] ?? VFDayStats()
        f(&d)
        days[k] = d
        scheduleSave()
    }

    /// Erster Start: aus dem (noch vorhandenen) Diktat-Verlauf befüllen.
    private func seedFromHistory() {
        var out: [String: VFDayStats] = [:]
        for r in DictationHistory.shared.records {
            let k = VFStats.key(r.date)
            var d = out[k] ?? VFDayStats()
            d.words += r.words
            d.dictations += 1
            d.speakSeconds += max(0, r.duration)
            d.categories[AppCategory.of(bundleID: r.bundleID).rawValue, default: 0] += 1
            d.apps[r.bundleID.isEmpty ? "?" : r.bundleID.lowercased(), default: 0] += 1
            out[k] = d
        }
        days = out
        seededAt = Date()
        saveNow()
    }

    /// Nur für Vorschau/Render: Daten komplett ersetzen (wird NICHT gespeichert).
    func replaceForPreview(_ d: [String: VFDayStats]) { days = d }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    private func saveNow() {
        let s = Stored(seededAt: seededAt, days: days)
        let url = VFStats.fileURL
        queue.async {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
            guard let d = try? enc.encode(s) else { return }
            try? d.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func key(_ d: Date) -> String { keyFormatter.string(from: d) }
    static func date(_ key: String) -> Date? { keyFormatter.date(from: key) }
}
