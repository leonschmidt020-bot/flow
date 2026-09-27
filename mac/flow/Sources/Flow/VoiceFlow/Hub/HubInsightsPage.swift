import AppKit
import SwiftUI

// MARK: - Insights: WPM-Tacho, Korrekturen, Wörter gesamt, Nutzung nach App-Art, Streak-Kalender

struct HubInsightsPage: View {
    enum Tab: Hashable { case nutzung, stimme }
    @ObservedObject var stats = VFStats.shared
    /// Start-Reiter (nur für Render/Tests umstellen)
    static var defaultTab: Tab = .nutzung
    @State private var tab: Tab = HubInsightsPage.defaultTab
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Insights").font(HubFont.title).foregroundStyle(VF.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) { HubShareBadge(copied: copied) { share() } }
                    .padding(.bottom, 34)
                HubTabs(tabs: [(Tab.nutzung, "Deine Nutzung"), (Tab.stimme, "Deine Stimme")], selection: $tab)
                    .padding(.bottom, 54)
                switch tab {
                case .nutzung: HubUsageTab()
                case .stimme: HubVoiceTab()
                }
            }
            .hubPage()
        }
    }

    private func share() {
        let s = stats
        let text = """
        Meine Voice-Flow-Statistik
        \(HubFormat.number(s.totalWords)) Wörter diktiert · \(s.wpm) WPM · \(s.currentStreak) Tage am Stück (längste Serie \(s.longestStreak))
        \(HubFormat.number(s.totalFixes)) Korrekturen durch Flow
        """
        Inserter.copy(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }
}

/// Runder „TEILEN“-Stempel oben rechts
struct HubShareBadge: View {
    let copied: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(VF.card).overlay(Circle().stroke(VF.hairline))
                HubCircularText(text: "TEILEN • TEILEN • TEILEN • ", radius: 26, size: 8.5)
                    .foregroundStyle(VF.teal1)
                    .rotationEffect(.degrees(hover ? 30 : 0))
                Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                    .offset(y: copied ? 0 : -1)
            }
            .frame(width: 70, height: 70)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Kopiert" : "Statistik kopieren")
        .onHover { h in withAnimation(.easeInOut(duration: 0.6)) { hover = h } }
    }
}

struct HubCircularText: View {
    let text: String
    let radius: CGFloat
    var size: CGFloat = 9
    var body: some View {
        let chars = Array(text)
        ZStack {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i]))
                    .font(.system(size: size, weight: .semibold))
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) / Double(chars.count) * 360))
            }
        }
    }
}

// MARK: - Reiter „Deine Nutzung“

struct HubUsageTab: View {
    @ObservedObject var stats = VFStats.shared

    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    wpmCard.frame(maxWidth: .infinity)
                    fixesCard.frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                wordsCard.frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 24) {
                HubCategoryCard()
                HubStreakCard()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // WPM-Tacho
    private var topPercent: Int? {
        let w = stats.wpm
        guard w > 0 else { return nil }
        if w >= 150 { return 1 }
        if w >= 120 { return 5 }
        if w >= 100 { return 15 }
        return 40
    }

    private var wpmCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stats.wpm > 0 ? "\(stats.wpm)" : "–").font(HubFont.bigNumber).foregroundStyle(VF.ink)
            HStack(spacing: 6) {
                HubLabel("Wörter pro Minute")
                HubInfo(text: "Durchschnitt über alle Diktate: gesprochene Wörter geteilt durch Sprechzeit.")
            }
            .padding(.top, 8)
            ZStack(alignment: .bottom) {
                HubGauge(fraction: topPercent.map { 1 - Double($0) / 100 } ?? 0)
                    .frame(width: 156, height: 78)
                VStack(spacing: 2) {
                    Text("Top").font(.system(size: 16)).foregroundStyle(VF.muted)
                    Text(topPercent.map { "\($0) %" } ?? "–").font(.system(size: 19, weight: .medium)).foregroundStyle(VF.ink)
                }
                .padding(.bottom, 2)
            }
            .frame(width: 156)
            .padding(.top, 20)
        }
        .padding(.horizontal, 17).padding(.top, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    // Korrekturen
    private var fixesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HubFormat.number(stats.totalFixes)).font(HubFont.bigNumber).foregroundStyle(VF.ink)
            HubLabel("Automatische Korrekturen").lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 8)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.top, 19).padding(.bottom, 18)
            fixRow("\(HubFormat.number(stats.wordsCorrected)) Wörter korrigiert",
                   "Füllwörter, Selbstkorrekturen („nein, warte …“) und Satzzeichen, die Flow bereinigt hat.")
            fixRow("\(HubFormat.number(stats.dictionaryFixes)) Wörterbuch-Korrekturen",
                   "Wörter, die dein Wörterbuch richtig geschrieben hat.")
                .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.top, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    private func fixRow(_ t: String, _ help: String) -> some View {
        HStack {
            Text(t).font(.system(size: 15)).foregroundStyle(VF.ink).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            HubInfo(text: help)
        }
    }

    // Wörter gesamt
    private var monthGrowth: Int? {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let month = stats.words(since: start)
        let before = stats.totalWords - month
        guard month > 0, before > 0 else { return nil }
        return Int((Double(month) / Double(before) * 100).rounded())
    }

    private var booksLine: String {
        let books = Double(stats.totalWords) / 90_000
        if stats.totalWords == 0 { return "Dein erstes Buch wartet." }
        if books < 1 { return "Das sind \(HubFormat.percent(books * 100)) eines Buches." }
        let n = Int(books)
        return n == 1 ? "Das ist ein ganzes Buch!" : "Das sind \(n) ganze Bücher!"
    }

    private var wordsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(HubFormat.number(stats.totalWords)).font(HubFont.bigNumber).foregroundStyle(VF.ink)
                Spacer()
                if let g = monthGrowth {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        Text("\(g) % diesen Monat").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(VF.teal1)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(VF.teal4, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.top, 4)
                }
            }
            HubLabel("Wörter gesamt diktiert").padding(.top, 8)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.top, 19).padding(.bottom, 18)
            Text(booksLine).font(.system(size: 15)).foregroundStyle(VF.ink)
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").font(.system(size: 12))
                Text("Mac").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("100 %").font(.system(size: 12, weight: .semibold)).tracking(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 21)
            .background(VF.teal1, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.top, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }
}

/// Halbkreis-Tacho (Hintergrund hell, Anteil in Petrol, runde Enden)
struct HubGauge: View {
    let fraction: Double
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            HubSemicircle().stroke(VF.teal4, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            HubSemicircle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(VF.teal1, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .padding(lineWidth / 2)
        .padding(.bottom, -lineWidth / 2)
    }
}

struct HubSemicircle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width / 2, rect.height)
        p.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        return p
    }
}

// MARK: - Nutzung nach App-Art

struct HubCategoryCard: View {
    @ObservedObject var stats = VFStats.shared

    private func symbol(_ c: AppCategory) -> String {
        switch c {
        case .ai: return "cpu"
        case .other: return "infinity"
        case .personal: return "ellipsis.bubble"
        case .email: return "envelope"
        case .work: return "text.bubble"
        }
    }

    private func label(_ c: AppCategory) -> String {
        switch c {
        case .ai: return "KI-Prompts"
        case .other: return "Sonstiges"
        case .personal: return "Persönliche Nachrichten"
        case .email: return "E-Mails"
        case .work: return "Arbeitsnachrichten"
        }
    }

    var body: some View {
        let counts = stats.categoryCounts
        let total = max(1, counts.values.reduce(0, +))
        let order = AppCategory.allCases.sorted { (counts[$0] ?? 0, $1.rawValue) > (counts[$1] ?? 0, $0.rawValue) }
        let top = order.first
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nutzung nach App-Art").font(.system(size: 29, weight: .medium)).foregroundStyle(VF.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 10)
                Text("APPS GENUTZT | \(stats.appsUsed)").font(HubFont.label).tracking(1.3).foregroundStyle(VF.ink)
                    .lineLimit(1).fixedSize()
            }
            .padding(.bottom, 28)
            GeometryReader { g in
                let maxBar = max(80, (g.size.width - 34) * 0.68)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(order) { c in
                        let n = counts[c] ?? 0
                        let pct = Double(n) / Double(total)
                        HStack(spacing: 12) {
                            Image(systemName: symbol(c)).font(.system(size: 15)).foregroundStyle(VF.ink)
                                .frame(width: 22)
                            Text(HubFormat.percent(pct * 100))
                                .font(.system(size: 12.5, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(.white)
                                .frame(width: max(46, 46 + (maxBar - 46) * pct), height: 28)
                                .background(c == top && n > 0 ? VF.teal1 : VF.teal2, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Text("\(HubFormat.number(n)) \(label(c))".uppercased(with: Locale(identifier: "de_DE")))
                                .font(HubFont.label).tracking(1.3).foregroundStyle(VF.ink)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                }
            }
            .frame(height: 5 * 28 + 4 * 16)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.top, 20).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }
}

// MARK: - Streak-Kalender

struct HubStreakCard: View {
    @ObservedObject var stats = VFStats.shared
    /// 0 = aktuelle Seite (endet mit dieser Woche), 1 = eine Seite zurück …
    @State private var page = 0

    private let cell: CGFloat = 16.5
    private let pitch: CGFloat = 24
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.locale = Locale(identifier: "de_DE"); return c
    }()

    var body: some View {
        let streak = stats.currentStreak
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(streak) \(streak == 1 ? "Tag" : "Tage") am Stück").font(.system(size: 29, weight: .medium)).foregroundStyle(VF.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 10)
                let l = stats.longestStreak
                Text("LÄNGSTE SERIE | \(l) \(l == 1 ? "TAG" : "TAGE")").font(HubFont.label).tracking(1.3).foregroundStyle(VF.ink)
                    .lineLimit(1).fixedSize()
            }
            .padding(.bottom, 26)
            GeometryReader { g in
                let weeks = max(6, Int((g.size.width - 38 + (pitch - cell)) / pitch))
                grid(weeks: weeks)
            }
            .frame(height: 22 + 7 * pitch)
            HStack(spacing: 8) {
                Text("Mehr").font(.system(size: 12.5)).foregroundStyle(VF.muted)
                ForEach([VF.teal1, VF.teal2, VF.teal3, VF.teal4], id: \.self) { c in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(c).frame(width: 15, height: 15)
                }
                Text("Weniger").font(.system(size: 12.5)).foregroundStyle(VF.muted)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 17).padding(.top, 20).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    /// Schwellen aus den eigenen Daten (Viertel der aktiven Tage) → Farbstufe
    private var thresholds: [Int] {
        let v = stats.days.values.map(\.words).filter { $0 > 0 }.sorted()
        guard !v.isEmpty else { return [1, 2, 3] }
        func q(_ p: Double) -> Int { v[min(v.count - 1, Int(Double(v.count - 1) * p))] }
        return [q(0.25), q(0.5), q(0.75)]
    }

    private func color(words: Int, future: Bool) -> Color {
        if future { return .clear }
        guard words > 0 else { return VF.beige.opacity(0.75) }
        let t = thresholds
        if words >= t[2] { return VF.teal1 }
        if words >= t[1] { return VF.teal2 }
        if words >= t[0] { return VF.teal3 }
        return VF.teal4
    }

    private func grid(weeks: Int) -> some View {
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let lastWeek = cal.date(byAdding: .weekOfYear, value: -page * weeks, to: thisWeek)!
        let firstWeek = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: lastWeek)!
        let weekStarts = (0..<weeks).map { cal.date(byAdding: .weekOfYear, value: $0, to: firstWeek)! }
        let dayNames = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        let earliest = stats.days.keys.min().flatMap { VFStats.date($0) }
        let canGoBack = earliest.map { $0 < firstWeek } ?? false

        return VStack(alignment: .leading, spacing: 0) {
            // Monatszeile mit Blättern
            ZStack(alignment: .topLeading) {
                Button { page += 1 } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(canGoBack ? VF.muted : VF.muted.opacity(0.3)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!canGoBack)
                ForEach(weekStarts.indices, id: \.self) { i in
                    let ws = weekStarts[i]
                    let prev = i > 0 ? weekStarts[i - 1] : nil
                    if let label = monthLabel(ws, prev: prev, first: i == 0) {
                        Text(label).font(.system(size: 11.5)).foregroundStyle(VF.muted).fixedSize()
                            .offset(x: 38 + CGFloat(i) * pitch, y: 1)
                    }
                }
                Button { page = max(0, page - 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(page > 0 ? VF.muted : VF.muted.opacity(0.3)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(page == 0)
                .offset(x: 38 + CGFloat(weeks) * pitch - cell)
            }
            .frame(height: 22, alignment: .topLeading)
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: 0) {
                    Text(dayNames[row]).font(.system(size: 11.5)).foregroundStyle(VF.muted)
                        .frame(width: 38, alignment: .leading)
                    HStack(spacing: pitch - cell) {
                        ForEach(weekStarts.indices, id: \.self) { i in
                            let d = cal.date(byAdding: .day, value: row, to: weekStarts[i])!
                            let w = stats.day(d)?.words ?? 0
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color(words: w, future: d > today))
                                .frame(width: cell, height: cell)
                                .help(d > today ? "" : "\(HubFormat.date(d, "EEEE, d. MMM")): \(HubFormat.number(w)) Wörter")
                        }
                    }
                }
                .frame(height: pitch)
            }
        }
    }

    private func monthLabel(_ ws: Date, prev: Date?, first: Bool) -> String? {
        // Monatsname an der ersten Woche, die in einem neuen Monat beginnt (die erste Spalte nur, wenn sie am Monatsanfang liegt)
        let m = cal.component(.month, from: ws)
        if let prev, cal.component(.month, from: prev) == m { return nil }
        if first, cal.component(.day, from: ws) > 7 { return nil }
        return HubFormat.date(ws, "MMM").replacingOccurrences(of: ".", with: "")
    }
}

// MARK: - Reiter „Deine Stimme“

struct HubVoiceTab: View {
    @ObservedObject var stats = VFStats.shared
    @ObservedObject var settings = Settings.shared
    @State private var enrolled = VoiceID.isEnrolled
    @State private var voices = VoiceStore.all()

    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                profileCard.frame(maxWidth: .infinity)
                languageCard.frame(maxWidth: .infinity)
                engineCard.frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            sparklineCard
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if enrolled != VoiceID.isEnrolled { enrolled = VoiceID.isEnrolled; voices = VoiceStore.all() }
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { c(); Spacer(minLength: 0) }
            .padding(.horizontal, 17).padding(.top, 16).padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .hubCard(VF.cardSoft, radius: 10)
    }

    private var profileCard: some View {
        card {
            Text(enrolled ? "Eingelernt" : "Offen").font(HubFont.bigNumber).foregroundStyle(enrolled ? VF.teal1 : VF.ink)
            HubLabel("Stimmprofil").padding(.top, 8)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.top, 19).padding(.bottom, 18)
            Text(enrolled ? "Nur deine Stimme zählt – Videos, Musik und Leute neben dir werden ignoriert."
                          : "Einmal 22 Sekunden vorlesen, dann erkennt Flow deine Stimme.")
                .font(.system(size: 14)).foregroundStyle(VF.ink).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Button(enrolled ? "Neu einlernen" : "Stimme einlernen") { VoiceEnrollController.shared.show() }
                .buttonStyle(enrolled ? HubAnyButtonStyle(HubSoftButton()) : HubAnyButtonStyle(HubBlackButton()))
                .padding(.top, 14)
        }
    }

    private var languageCard: some View {
        card {
            Text(settings.languageMode.short).font(HubFont.bigNumber).foregroundStyle(VF.ink)
            HubLabel("Sprache").padding(.top, 8)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.top, 19).padding(.bottom, 18)
            Text(settings.languageMode.label).font(.system(size: 14)).foregroundStyle(VF.ink)
            Text("Umschalten: über die Weltkugel an der Pille.").font(.system(size: 13)).foregroundStyle(VF.muted).padding(.top, 6)
        }
    }

    private var engineCard: some View {
        card {
            Text(settings.engine == .whisper ? "Whisper" : "Parakeet").font(HubFont.bigNumber).foregroundStyle(VF.ink)
            HubLabel("Spracherkennung").padding(.top, 8)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.top, 19).padding(.bottom, 18)
            Text(settings.engine.label).font(.system(size: 14)).foregroundStyle(VF.ink).fixedSize(horizontal: false, vertical: true)
            Text("\(voices.count) gemerkte \(voices.count == 1 ? "Stimme" : "Stimmen") aus Meetings")
                .font(.system(size: 13)).foregroundStyle(VF.muted).padding(.top, 6)
        }
    }

    private var sparklineCard: some View {
        let series = stats.weeklyWPM(weeks: 12)
        let values = series.compactMap(\.wpm)
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / values.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tempo pro Woche").font(.system(size: 29, weight: .medium)).foregroundStyle(VF.ink)
                Spacer()
                Text("Ø \(avg > 0 ? "\(avg)" : "–") WPM · 12 WOCHEN").font(HubFont.label).tracking(1.3).foregroundStyle(VF.ink)
            }
            .padding(.bottom, 24)
            HubSparkline(values: series.map { $0.wpm.map(Double.init) })
                .frame(height: 150)
            HStack {
                ForEach(series.indices, id: \.self) { i in
                    Text(i % 2 == 0 ? HubFormat.date(series[i].start, "d.M.") : "")
                        .font(.system(size: 11)).foregroundStyle(VF.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 17).padding(.vertical, 20)
        .hubCard(VF.cardSoft, radius: 10)
    }
}

struct HubAnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Linie mit Punkten; nil = Woche ohne Diktat (Lücke)
struct HubSparkline: View {
    let values: [Double?]
    var body: some View {
        GeometryReader { g in
            let present = values.compactMap { $0 }
            let hi = max(present.max() ?? 1, 1) * 1.15
            let lo = max(0, (present.min() ?? 0) * 0.7)
            let step = values.count > 1 ? g.size.width / CGFloat(values.count - 1) : 0
            let pts: [CGPoint?] = values.enumerated().map { i, v in
                v.map { CGPoint(x: CGFloat(i) * step, y: g.size.height * (1 - CGFloat(($0 - lo) / max(1, hi - lo)))) }
            }
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Path { p in
                        let y = g.size.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                    }
                    .stroke(VF.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                Path { p in
                    var started = false
                    for pt in pts {
                        guard let pt else { started = false; continue }
                        if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
                    }
                }
                .stroke(VF.teal1, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ForEach(pts.indices, id: \.self) { i in
                    if let pt = pts[i] {
                        Circle().fill(VF.card).overlay(Circle().stroke(VF.teal1, lineWidth: 2))
                            .frame(width: 9, height: 9).position(pt)
                    }
                }
                if present.isEmpty {
                    Text("Noch keine Diktate mit Sprechzeit").font(.system(size: 13)).foregroundStyle(VF.muted)
                }
            }
        }
    }
}
