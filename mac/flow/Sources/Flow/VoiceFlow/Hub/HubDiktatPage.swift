import AppKit
import SwiftUI

// MARK: - Diktat (Start): Begrüßung, Foto-Banner, Statistik-Karte rechts, Verlauf nach Datum

struct HubDiktatPage: View {
    @ObservedObject var history = DictationHistory.shared
    @ObservedObject var stats = VFStats.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var hub = VFHub.shared
    @AppStorage("vf.hub.banner.diktat.hidden") private var bannerHidden = false
    @State private var searching = false
    @State private var query = ""
    @State private var enrolled = VoiceID.isEnrolled

    private var name: String { _ = settings.myName; return Identity.myName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(history.records.isEmpty && stats.totalDictations == 0 ? "Willkommen, \(name)" : "Willkommen zurück, \(name)")
                    .font(HubFont.title).foregroundStyle(VF.ink)
                    .padding(.bottom, 25)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !bannerHidden {
                            banner.padding(.bottom, 44)
                        }
                        historySection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statsCard.frame(width: 250)
                }
            }
            .hubPage()
        }
        .scrollIndicators(.automatic)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if enrolled != VoiceID.isEnrolled { enrolled = VoiceID.isEnrolled }
        }
    }

    // MARK: Banner

    private var banner: some View {
        HubBanner(image: "banner_diktat",
                  headline: Text("Sprich, statt zu \(Text("tippen.").font(VF.serif(33, italic: true)))"),
                  sub: "Halte fn, sprich, lass los – der Text steht da, wo dein Cursor ist.",
                  onClose: { withAnimation { bannerHidden = true } }) {
            Button("Zeig mir wie") { hub.go(.hilfe) }.buttonStyle(HubBannerButton())
        }
    }

    // MARK: Verlauf

    private var filtered: [DictationRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history.records }
        return history.records.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
    }

    private var groups: [(day: Date, records: [DictationRecord])] {
        let cal = Calendar.current
        var order: [Date] = []
        var map: [Date: [DictationRecord]] = [:]
        for r in filtered {
            let d = cal.startOfDay(for: r.date)
            if map[d] == nil { order.append(d) }
            map[d, default: []].append(r)
        }
        return order.sorted(by: >).map { ($0, map[$0]!) }
    }

    @ViewBuilder private var historySection: some View {
        let gs = groups
        if searching {
            searchField.padding(.bottom, 15)
        }
        if gs.isEmpty {
            if !searching { header(HubFormat.date(Date(), "d. MMMM yyyy"), showSearch: !history.records.isEmpty) }
            emptyCard
        }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(gs.enumerated()), id: \.element.day) { i, g in
                header(HubFormat.date(g.day, "d. MMMM yyyy"), showSearch: i == 0 && !searching)
                    .padding(.top, i == 0 ? 0 : 34)
                VStack(spacing: 0) {
                    ForEach(Array(g.records.enumerated()), id: \.element.id) { j, r in
                        if j > 0 { Rectangle().fill(VF.hairline).frame(height: 1) }
                        HubHistoryRow(record: r)
                    }
                }
                .hubCard(VF.card, radius: 12)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func header(_ title: String, showSearch: Bool) -> some View {
        HStack {
            HubLabel(title)
            Spacer()
            if showSearch {
                Button { withAnimation(.easeOut(duration: 0.15)) { searching = true } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(VF.muted)
                        .frame(width: 28, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Verlauf durchsuchen")
            }
        }
        .frame(height: 22)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VF.muted)
            TextField("Verlauf durchsuchen …", text: $query)
                .textFieldStyle(.plain).font(HubFont.body)
            Button { withAnimation(.easeOut(duration: 0.15)) { query = ""; searching = false } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(VF.muted.opacity(0.7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).frame(height: 38)
        .hubCard(VF.card, radius: 10)
    }

    private var emptyCard: some View {
        HStack(spacing: 18) {
            HubIllustration(name: "illu_mikrofon", fallback: "mic", size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(searching ? "Nichts gefunden" : "Noch keine Diktate").font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                Text(searching ? "Versuch ein anderes Wort." : "Halte fn und sprich los – deine Diktate erscheinen hier.")
                    .font(HubFont.small).foregroundStyle(VF.muted)
            }
            Spacer()
        }
        .padding(18)
        .hubCard(VF.card, radius: 12)
    }

    // MARK: Statistik-Karte (rechts)

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                statLine(HubFormat.compact(stats.totalWords), stats.totalWords == 1 ? "Wort gesamt" : "Wörter gesamt")
                statLine(stats.wpm > 0 ? "\(stats.wpm)" : "–", "WPM")
                let s = stats.currentStreak
                statLine("\(s)", s == 1 ? "Tag am Stück" : "Tage am Stück")
            }
            .padding(.horizontal, 25).padding(.top, 24).padding(.bottom, 24)

            Rectangle().fill(VF.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Unbegrenzt").foregroundStyle(VF.purple)
                    Text("· alles lokal").foregroundStyle(VF.ink)
                }
                .font(.system(size: 16, weight: .semibold))
                Text("Kein Wortlimit, kein Abo. Deine Stimme verlässt nie deinen Mac.")
                    .font(.system(size: 13)).foregroundStyle(VF.ink.opacity(0.85))
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 25).padding(.vertical, 24)

            Rectangle().fill(VF.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Text("Dein Stimmprofil").font(.system(size: 16, weight: .semibold)).foregroundStyle(VF.ink)
                if enrolled {
                    Text("Flow erkennt deine Stimme und lernt bei jedem Diktat dazu.")
                        .font(.system(size: 13)).foregroundStyle(VF.ink.opacity(0.85))
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Capsule().fill(VF.purple).frame(width: 92, height: 5)
                        Spacer(minLength: 0)
                        Text("Eingelernt").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.ink)
                    }
                    .padding(.top, 8)
                } else {
                    Text("Einmal 22 Sekunden vorlesen – dann zählt nur deine Stimme, nicht Videos oder Leute neben dir.")
                        .font(.system(size: 13)).foregroundStyle(VF.ink.opacity(0.85))
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(VF.hairline)
                            Capsule().fill(VF.purple).frame(width: 8)
                        }
                        .frame(width: 92, height: 5)
                        Spacer(minLength: 0)
                        Button("Stimme einlernen") { VoiceFlowWindow.shared.show(.training) }
                            .buttonStyle(HubSoftButton(height: 28))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 25).padding(.top, 24).padding(.bottom, 28)
        }
        .hubCard(VF.cardSoft, radius: 14)
    }

    private func statLine(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(VF.serif(33)).foregroundStyle(VF.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 15)).foregroundStyle(VF.ink)
        }
    }
}

// MARK: - Eine Zeile im Verlauf (Zeit links, Text rechts, beim Überfahren Kopieren/Löschen)

struct HubHistoryRow: View {
    let record: DictationRecord
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(HubFormat.time(record.date))
                .font(.system(size: 14)).foregroundStyle(VF.muted).monospacedDigit()
                .frame(width: 98, alignment: .leading)
            Text(record.text)
                .font(.system(size: 15)).foregroundStyle(VF.ink)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: 500, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            HStack(spacing: 2) {
                HubIconButton(symbol: copied ? "checkmark" : "doc.on.doc", size: 13, color: VF.muted, help: "Kopieren") {
                    Inserter.copy(record.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
                }
                HubIconButton(symbol: "trash", size: 13, color: VF.muted, help: "Löschen") {
                    withAnimation(.easeOut(duration: 0.15)) { DictationHistory.shared.delete(record.id) }
                }
            }
            .opacity(hover || copied ? 1 : 0)
        }
        .padding(.leading, 17).padding(.trailing, 12)
        .padding(.vertical, 17)
        .background(hover ? VF.panel : VF.card)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(record.app.isEmpty || record.app == "–" ? "" : "In \(record.app) diktiert")
    }
}
