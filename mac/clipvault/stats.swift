// ClipVault — Statistik (01.11.2026)
// Der Verlauf lebt nur 3 Tage und führt gleiche Kopien zusammen – zum Zählen taugt er nicht.
// Deshalb zählt jede echte Kopie hier mit, dauerhaft, nur Zahlen (keine Inhalte):
//   ~/.config/flow-clipvault/stats.json  →  {"v":1,"since":<ts>,"days":{"2026-11-01":{n,kinds,hours,apps,sources,reused,shots}}}
// Der Hub (Flow → ClipVault → Statistik) liest die Datei nur.
import Foundation
import AppKit

final class CVStats {
    struct Day: Codable, Equatable {
        var n = 0                                          // Kopien
        var kinds: [String: Int] = [:]                     // text · link · bild · datei
        var hours = [Int](repeating: 0, count: 24)         // Kopien je Stunde
        var apps: [String: Int] = [:]                      // aus welcher App kopiert
        var sources: [String: Int] = [:]                   // KI · Diktat · iPhone
        var reused = 0                                     // aus dem Verlauf wieder geholt
        var shots = 0                                      // Screenshots (von außen über ingest-cmd aufgenommen)
    }
    struct File: Codable {
        var v = 1
        var since: Double
        var days: [String: Day] = [:]
        var backfilled: Bool? = nil
    }

    static let shared = CVStats(path: CV_DIR + "stats.json")
    let path: String
    private(set) var data: File
    private var saveWork: DispatchWorkItem?

    init(path: String) {
        self.path = path
        if let d = FileManager.default.contents(atPath: path), let f = try? JSONDecoder().decode(File.self, from: d) { data = f }
        else { data = File(since: Date().timeIntervalSince1970) }
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Art eines Eintrags für die Statistik
    static func kind(_ it: ClipItem) -> String {
        switch it.kind {
        case .image: return "bild"
        case .file: return "datei"
        case .text: return soleURL(it.text) != nil ? "link" : "text"
        }
    }

    private func mutate(_ date: Date, _ f: (inout Day) -> Void) {
        let k = Self.dayKey(date)
        var d = data.days[k] ?? Day()
        f(&d)
        data.days[k] = d
        scheduleSave()
    }

    /// Eine echte Kopie (Zwischenablage hat sich geändert, ClipVault hat sie aufgenommen)
    func recordCopy(kind: String, app: String?, source: String?, date: Date = Date()) {
        mutate(date) { d in
            d.n += 1
            d.kinds[kind, default: 0] += 1
            d.hours[Calendar.current.component(.hour, from: date)] += 1
            if let a = app?.trimmingCharacters(in: .whitespaces), !a.isEmpty { d.apps[a, default: 0] += 1 }
            if let s = source, !s.isEmpty { d.sources[s, default: 0] += 1 }
        }
    }
    /// Eintrag aus dem Verlauf wieder in die Zwischenablage geholt (n = mehrere auf einmal)
    func recordReuse(_ n: Int = 1, date: Date = Date()) { if n > 0 { mutate(date) { $0.reused += n } } }
    func recordScreenshot(date: Date = Date()) { mutate(date) { $0.shots += 1 } }

    /// Einmalig: Was schon im Verlauf liegt, als Startwert eintragen (sonst ist die Seite am ersten Tag leer).
    /// Nur die letzten 3 Tage (alte angeheftete Einträge würden „gezählt seit Juni“ vortäuschen),
    /// nur Tage, für die noch nichts gezählt wurde; App unbekannt.
    func backfillOnce(_ items: [ClipItem], now: Date = Date()) {
        guard data.backfilled != true else { return }
        let counted = Set(data.days.keys)
        let from = Calendar.current.startOfDay(for: now.addingTimeInterval(-3 * 86400))
        for it in items where it.date >= from && !counted.contains(Self.dayKey(it.date)) {
            let k = Self.kind(it)
            mutate(it.date) { d in
                d.n += 1
                d.kinds[k, default: 0] += 1
                d.hours[Calendar.current.component(.hour, from: it.date)] += 1
                if let s = it.source, ["KI", "Diktat", "iPhone"].contains(s) { d.sources[s, default: 0] += 1 }
            }
            if let first = data.days.keys.sorted().first, let t = Self.date(first)?.timeIntervalSince1970 { data.since = min(data.since, t) }
        }
        data.backfilled = true
        scheduleSave()
    }

    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
    func save() {
        saveWork?.cancel(); saveWork = nil
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - Selbsttest:  clipvault stats-test
func runStatsTest() -> Never {
    var fails = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "  ✓ " : "  ✗ ") + name); if !ok { fails += 1 } }
    let tmp = NSTemporaryDirectory() + "cvstats-\(UUID().uuidString).json"
    let s = CVStats(path: tmp)
    let cal = Calendar.current
    let t = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 14, minute: 5))!
    s.recordCopy(kind: "text", app: "Code", source: nil, date: t)
    s.recordCopy(kind: "link", app: "Google Chrome", source: nil, date: t)
    s.recordCopy(kind: "text", app: "Code", source: "KI", date: t.addingTimeInterval(3600))
    s.recordReuse(3, date: t); s.recordScreenshot(date: t)
    let d = s.data.days["2026-11-01"]
    check("3 Kopien gezählt", d?.n == 3)
    check("Arten: 2 Text, 1 Link", d?.kinds["text"] == 2 && d?.kinds["link"] == 1)
    check("Stunden 14 und 15", d?.hours[14] == 2 && d?.hours[15] == 1)
    check("Apps: Code 2, Chrome 1", d?.apps["Code"] == 2 && d?.apps["Google Chrome"] == 1)
    check("Quelle KI 1", d?.sources["KI"] == 1)
    check("3× wieder geholt, 1 Screenshot", d?.reused == 3 && d?.shots == 1)
    s.save()
    let back = CVStats(path: tmp)
    check("Datei wieder lesbar", back.data.days["2026-11-01"] == d)
    // Startwert aus dem Verlauf: nur Tage ohne Zählung, nur einmal
    let old = ClipItem(kind: .text, text: "https://example.com", date: t.addingTimeInterval(-86400))
    let same = ClipItem(kind: .text, text: "doppelt gezählt?", date: t)
    let ancient = ClipItem(kind: .text, text: "angeheftet seit Juni", date: t.addingTimeInterval(-140 * 86400), pinned: true)
    back.backfillOnce([old, same, ancient], now: t)
    check("Startwert: nichts älter als 3 Tage", back.data.days.count == 2)
    check("Startwert: Vortag 1 Link", back.data.days["2026-10-31"]?.n == 1 && back.data.days["2026-10-31"]?.kinds["link"] == 1)
    check("Startwert: gezählter Tag bleibt unverändert", back.data.days["2026-11-01"]?.n == 3)
    back.backfillOnce([old], now: t)
    check("Startwert nur einmal", back.data.days["2026-10-31"]?.n == 1)
    try? FileManager.default.removeItem(atPath: tmp)
    print(fails == 0 ? "Statistik: alles ok" : "Statistik: \(fails) Fehler")
    exit(fails == 0 ? 0 : 1)
}
