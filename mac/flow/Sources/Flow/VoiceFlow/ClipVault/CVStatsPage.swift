import AppKit
import SwiftUI

// MARK: - ClipVault-Statistik (01.11.2026)
// ClipVault zählt jede echte Kopie dauerhaft in ~/.config/flow-clipvault/stats.json (clipvault/stats.swift) –
// nur Zahlen, keine Inhalte. Der Verlauf selbst lebt nur 3 Tage und führt gleiche Kopien zusammen.

struct CVStatDay: Codable, Equatable {
    var n = 0
    var kinds: [String: Int] = [:]
    var hours = [Int](repeating: 0, count: 24)
    var apps: [String: Int] = [:]
    var sources: [String: Int] = [:]
    var reused = 0
    var shots = 0
}

struct CVStatFile: Codable {
    var v = 1
    var since: Double = Date().timeIntervalSince1970
    var days: [String: CVStatDay] = [:]
}

final class CVStatsModel: ObservableObject {
    static let shared = CVStatsModel()
    @Published private(set) var file = CVStatFile()
    @Published private(set) var storageBytes: Int64?
    private var stamp: Date?

    var url: URL { ClipVaultClient.base.appendingPathComponent("stats.json") }

    func reload() {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard mod != stamp else { return }
        stamp = mod
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(CVStatFile.self, from: d) { file = f }
    }

    func measureStorage() {
        let dir = ClipVaultClient.base
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            while let u = e?.nextObject() as? URL {
                let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
            }
            DispatchQueue.main.async { self.storageBytes = total }
        }
    }

    // MARK: Auswertung (auch für den Selbsttest)

    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func day(_ d: Date) -> CVStatDay { file.days[Self.key(d)] ?? CVStatDay() }
    /// Die letzten n Tage (ältester zuerst, heute zuletzt)
    func lastDays(_ n: Int, now: Date = Date()) -> [(date: Date, day: CVStatDay)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<n).reversed().compactMap { off in
            cal.date(byAdding: .day, value: -off, to: today).map { ($0, day($0)) }
        }
    }
    var all: [CVStatDay] { Array(file.days.values) }
    var total: Int { all.reduce(0) { $0 + $1.n } }
    var reusedTotal: Int { all.reduce(0) { $0 + $1.reused } }
    var shotsTotal: Int { all.reduce(0) { $0 + $1.shots } }
    func sum(_ f: (CVStatDay) -> [String: Int]) -> [String: Int] {
        all.reduce(into: [:]) { acc, d in for (k, v) in f(d) { acc[k, default: 0] += v } }
    }
    var hours: [Int] { all.reduce(into: [Int](repeating: 0, count: 24)) { acc, d in for (i, v) in d.hours.prefix(24).enumerated() { acc[i] += v } } }
    /// Tage am Stück mit mindestens einer Kopie (heute zählt mit, wenn schon kopiert wurde)
    func streak(now: Date = Date()) -> Int {
        let cal = Calendar.current
        var d = cal.startOfDay(for: now)
        if day(d).n == 0 { d = cal.date(byAdding: .day, value: -1, to: d)! }
        var n = 0
        while day(d).n > 0 { n += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return n
    }
    var activeDays: Int { all.filter { $0.n > 0 }.count }
}

struct CVStatsPage: View {
    @ObservedObject var model = CVStatsModel.shared
    @ObservedObject var cv = ClipVaultClient.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Statistik").font(HubFont.title).foregroundStyle(VF.ink)
                Text(subtitle).font(.system(size: 13.5)).foregroundStyle(VF.muted).padding(.top, 6).padding(.bottom, 30)
                VStack(spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        numberCard(model.day(Date()).n, "Kopien heute", note: todayNote)
                        numberCard(model.lastDays(7).reduce(0) { $0 + $1.day.n }, "Letzte 7 Tage",
                                   note: "\(model.streak()) \(model.streak() == 1 ? "Tag" : "Tage") am Stück")
                        numberCard(model.total, "Kopien insgesamt",
                                   note: "\(HubFormat.number(model.reusedTotal))× aus dem Verlauf wieder geholt")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    daysCard
                    HStack(alignment: .top, spacing: 24) {
                        kindsCard
                        appsCard
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 24) {
                        hoursCard
                        nowCard
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .hubPage()
        }
        .onAppear { model.reload(); model.measureStorage() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in model.reload() }
    }

    private var subtitle: String {
        let since = Date(timeIntervalSince1970: model.file.since)
        return "Gezählt seit \(HubFormat.date(since, "d. MMMM yyyy")) · nur Zahlen, keine Inhalte"
    }

    private var todayNote: String {
        // nur Tage, seit denen gezählt wird (sonst drücken leere Tage vor dem Start den Schnitt)
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: model.file.since))
        let past = model.lastDays(8).dropLast().filter { $0.date >= start }.map(\.day.n)
        guard !past.isEmpty else { return "Ab morgen siehst du hier deinen Schnitt" }
        let avg = Double(past.reduce(0, +)) / Double(past.count)
        return "Ø \(Int(avg.rounded())) pro Tag " + (past.count == 1 ? "am Tag davor" : "in den \(past.count) Tagen davor")
    }

    // MARK: Karten

    private func numberCard(_ n: Int, _ label: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HubFormat.number(n)).font(HubFont.bigNumber).foregroundStyle(VF.ink).monospacedDigit()
            HubLabel(label).padding(.top, 8)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.vertical, 16)
            Text(note).font(.system(size: 14)).foregroundStyle(VF.ink).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    private var daysCard: some View {
        let days = model.lastDays(14)
        let maxN = max(1, days.map(\.day.n).max() ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Letzte 14 Tage").font(.system(size: 22, weight: .medium)).foregroundStyle(VF.ink)
                Spacer()
                HubLabel("Kopien pro Tag", color: VF.ink)
            }
            .padding(.bottom, 22)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days.indices, id: \.self) { i in
                    let (date, d) = days[i]
                    let isToday = i == days.count - 1
                    VStack(spacing: 6) {
                        Text(d.n > 0 ? "\(d.n)" : "").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(isToday ? VF.teal1 : VF.muted)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isToday ? VF.teal1 : (d.n > 0 ? VF.teal2 : VF.teal4))
                            .frame(height: max(4, 120 * CGFloat(d.n) / CGFloat(maxN)))
                        Text(isToday ? "Heute" : HubFormat.date(date, "EEEEEE"))
                            .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? VF.ink : VF.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(HubFormat.date(date, "EEEE, d. MMMM")): \(d.n) \(d.n == 1 ? "Kopie" : "Kopien")")
                }
            }
            .frame(height: 160, alignment: .bottom)
        }
        .padding(.horizontal, 17).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    private static let kindOrder: [(key: String, label: String, symbol: String)] = [
        ("text", "Text", "text.alignleft"), ("link", "Links", "link"), ("bild", "Bilder", "photo"), ("datei", "Dateien", "doc"),
    ]

    private var kindsCard: some View {
        let kinds = model.sum(\.kinds)
        let total = max(1, kinds.values.reduce(0, +))
        let top = kinds.max { $0.value < $1.value }?.key
        let sources = model.sum(\.sources)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Was du kopierst").font(.system(size: 22, weight: .medium)).foregroundStyle(VF.ink).padding(.bottom, 22)
            GeometryReader { g in
                let maxBar = max(80, (g.size.width - 34) * 0.62)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.kindOrder, id: \.key) { k in
                        let n = kinds[k.key] ?? 0
                        let pct = Double(n) / Double(total)
                        HStack(spacing: 12) {
                            Image(systemName: k.symbol).font(.system(size: 14)).foregroundStyle(VF.ink).frame(width: 22)
                            Text(HubFormat.percent(pct * 100))
                                .font(.system(size: 12.5, weight: .semibold)).tracking(0.8).foregroundStyle(.white)
                                .frame(width: max(46, 46 + (maxBar - 46) * pct), height: 26)
                                .background(k.key == top && n > 0 ? VF.teal1 : VF.teal2, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Text("\(HubFormat.number(n)) \(k.label)".uppercased(with: Locale(identifier: "de_DE")))
                                .font(HubFont.label).tracking(1.3).foregroundStyle(VF.ink).lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                }
            }
            .frame(height: 4 * 26 + 3 * 14)
            if !sources.isEmpty {
                HStack(spacing: 8) {
                    ForEach(["KI", "Diktat", "iPhone"].filter { (sources[$0] ?? 0) > 0 }, id: \.self) { s in
                        chip(s == "KI" ? "sparkles" : s == "Diktat" ? "waveform" : "iphone", "\(HubFormat.number(sources[s] ?? 0)) \(s == "KI" ? "von KI" : s == "Diktat" ? "Diktat" : "vom iPhone")")
                    }
                }
                .padding(.top, 20)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(VF.teal1)
        .padding(.horizontal, 9).frame(height: 25)
        .background(VF.teal4, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var appsCard: some View {
        let apps = model.sum(\.apps).sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let top = Array(apps.prefix(6))
        let maxN = max(1, top.first?.value ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Aus welchen Apps").font(.system(size: 22, weight: .medium)).foregroundStyle(VF.ink)
                Spacer()
                HubLabel("\(apps.count) Apps", color: VF.ink)
            }
            .padding(.bottom, 22)
            if top.isEmpty {
                Text("Ab jetzt zählt ClipVault mit, aus welcher App du kopierst.")
                    .font(.system(size: 14)).foregroundStyle(VF.muted)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(top, id: \.key) { a in
                    HStack(spacing: 10) {
                        appIcon(a.key).frame(width: 20, height: 20)
                        Text(a.key).font(.system(size: 14)).foregroundStyle(VF.ink).lineLimit(1).frame(width: 130, alignment: .leading)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(a.key == top.first?.key ? VF.teal1 : VF.teal3)
                                .frame(width: max(6, g.size.width * CGFloat(a.value) / CGFloat(maxN)), height: 10)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        Text(HubFormat.number(a.value)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(VF.ink).frame(width: 44, alignment: .trailing)
                    }
                    .frame(height: 22)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    @ViewBuilder private func appIcon(_ name: String) -> some View {
        if name == "iPhone" {
            Image(systemName: "iphone").font(.system(size: 13)).foregroundStyle(VF.ink)
        } else if let img = Self.icon(for: name) {
            Image(nsImage: img).resizable().interpolation(.high)
        } else {
            Image(systemName: "app").font(.system(size: 13)).foregroundStyle(VF.muted)
        }
    }

    private static var iconCache: [String: NSImage] = [:]
    static func icon(for appName: String) -> NSImage? {
        if let i = iconCache[appName] { return i }
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }
        var url = running?.bundleURL
        if url == nil {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                let u = URL(fileURLWithPath: dir).appendingPathComponent(appName + ".app")
                if FileManager.default.fileExists(atPath: u.path) { url = u; break }
            }
        }
        guard let u = url else { return nil }
        let img = NSWorkspace.shared.icon(forFile: u.path)
        iconCache[appName] = img
        return img
    }

    private var hoursCard: some View {
        let h = model.hours
        let maxN = max(1, h.max() ?? 1)
        let peak = h.firstIndex(of: h.max() ?? 0) ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wann du kopierst").font(.system(size: 22, weight: .medium)).foregroundStyle(VF.ink)
                Spacer()
                if (h.max() ?? 0) > 0 { HubLabel("Am meisten um \(peak) Uhr", color: VF.ink) }
            }
            .padding(.bottom, 22)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i == peak && h[i] > 0 ? VF.teal1 : (h[i] > 0 ? VF.teal2 : VF.teal4))
                        .frame(height: max(3, 96 * CGFloat(h[i]) / CGFloat(maxN)))
                        .frame(maxWidth: .infinity)
                        .help("\(i)–\(i + 1) Uhr: \(h[i])")
                }
            }
            .frame(height: 96, alignment: .bottom)
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { t in
                    Text("\(t) Uhr").font(.system(size: 11)).foregroundStyle(VF.muted)
                    if t != 18 { Spacer() }
                }
                Spacer()
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    private var nowCard: some View {
        let inHistory = cv.items.filter { !$0.pinned && $0.collection == nil }.count
        let pinned = cv.items.filter(\.pinned).count
        let inCollections = cv.items.filter { $0.collection != nil }.count
        return VStack(alignment: .leading, spacing: 0) {
            Text("Gerade gespeichert").font(.system(size: 22, weight: .medium)).foregroundStyle(VF.ink).padding(.bottom, 18)
            row("clock.arrow.circlepath", "Im Verlauf", "\(inHistory)", "wird nach 3 Tagen gelöscht")
            row("pin", "Angeheftet", "\(pinned)", "bleibt")
            row("square.stack.3d.up", "In Bereichen", "\(inCollections)", "bleibt")
            row("camera.viewfinder", "Screenshots aufgenommen", HubFormat.number(model.shotsTotal), "seit Beginn")
            row("internaldrive", "Speicher auf dem Mac", model.storageBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "…", "")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    private func row(_ symbol: String, _ title: String, _ value: String, _ note: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(VF.ink).frame(width: 20)
            Text(title).font(.system(size: 14)).foregroundStyle(VF.ink)
            if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(VF.muted) }
            Spacer(minLength: 6)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(VF.ink)
        }
        .frame(height: 30)
    }
}
