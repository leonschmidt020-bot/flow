import AppKit
import SwiftUI

// MARK: - Hub-Seite „Gelernt“: was Flow gelernt hat, offene Vorschläge, Schalter, „Alles vergessen“
//
// Registrieren (AppDelegate.registerHubPages):  case .gelernt: return AnyView(SmartLearnedPage())
// Ohne neuen Seitenleisten-Eintrag: SmartInsightsCard() auf Insights zeigen (führt hierher).

struct SmartLearnedPage: View {
    @ObservedObject var flow = SmartFlow.shared
    @State private var phraseTab: String = ""
    @State private var confirmForget = false
    @State private var showPayload = false

    var body: some View {
        let w = flow.snapshot
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    banner(w, proxy: proxy)
                        .padding(.bottom, 28)
                    statsRow(w)
                        .padding(.bottom, 38)
                    suggestionsSection
                        .id("vorschlaege")
                        .padding(.bottom, 38)
                    HStack(alignment: .top, spacing: 24) {
                        namesCard(w)
                        greetingsCard(w)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
                    phrasesCard(w)
                        .padding(.bottom, 24)
                    HStack(alignment: .top, spacing: 24) {
                        meetingsCard(w)
                        timesCard(w)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
                    if !w.corrections.isEmpty {
                        correctionsCard(w).padding(.bottom, 24)
                    }
                    kindsSection
                        .padding(.top, 14)
                        .padding(.bottom, 30)
                    digestSection(w)
                        .padding(.bottom, 30)
                    privacyFooter
                }
                .hubPage()
            }
        }
        .background(VF.panel)
        .alert("Alles vergessen?", isPresented: $confirmForget) {
            Button("Abbrechen", role: .cancel) {}
            Button("Alles vergessen", role: .destructive) { flow.forgetAll() }
        } message: {
            Text("Flow löscht alles Gelernte (Formulierungen, Namen, Grüße, Meeting-Themen, Zeiten, offene Vorschläge). Wörterbuch, Snippets und Stil bleiben, wie sie sind.")
        }
    }

    // MARK: Kopf + Banner

    private var header: some View {
        HStack(alignment: .center) {
            Text("Gelernt").font(HubFont.title).foregroundStyle(VF.ink)
            Spacer()
            HStack(spacing: 10) {
                Text(flow.prefs.enabled ? "Flow lernt mit" : "Lernen pausiert").font(HubFont.bodyMedium)
                    .foregroundStyle(flow.prefs.enabled ? VF.ink : VF.muted)
                Toggle("", isOn: Binding(get: { flow.prefs.enabled }, set: { flow.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(VF.black)
            }
        }
        .padding(.bottom, 30)
    }

    private func banner(_ w: SmartWissen, proxy: ScrollViewProxy) -> some View {
        HubBanner(image: "banner_gelernt",
                  headline: PG.headline("Flow lernt *mit* dir.", size: 33),
                  sub: "Aus Diktaten und Meetings – nur Zähler und Muster, nie ganze Texte. Alles bleibt auf diesem Mac.") {
            Button(flow.visiblePending.isEmpty ? "Keine offenen Vorschläge" : "Vorschläge ansehen (\(flow.visiblePending.count))") {
                withAnimation { proxy.scrollTo("vorschlaege", anchor: .top) }
            }
            .buttonStyle(HubBannerButton())
            .disabled(flow.visiblePending.isEmpty)
        }
    }

    // MARK: Zahlen

    private func statsRow(_ w: SmartWissen) -> some View {
        let names = visibleTerms(w).count
        let phrases = w.phrases.values.reduce(0) { $0 + $1.values.filter { $0.n >= 3 }.count }
        let greets = w.signOffs.values.reduce(0) { $0 + $1.count } + w.greetings.values.reduce(0) { $0 + $1.count }
        return HStack(alignment: .top, spacing: 24) {
            statCard(HubFormat.number(w.dictations), "Diktate ausgewertet",
                     w.dictations == 0 ? "Sobald du diktierst, lernt Flow mit." : "\(HubFormat.number(w.words)) Wörter · seit \(HubFormat.date(w.createdAt, "d. MMMM"))")
            statCard(HubFormat.number(names), "Namen & Begriffe",
                     "\(flow.prefs.stat(.dictionary).accepted) davon ins Wörterbuch übernommen")
            statCard(HubFormat.number(phrases), "Wiederkehrende Formulierungen",
                     "\(greets) Grüße & Abschiede · \(w.meetings) \(w.meetings == 1 ? "Meeting" : "Meetings")")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statCard(_ number: String, _ label: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(number).font(HubFont.bigNumber).foregroundStyle(VF.ink)
            HubLabel(label).lineLimit(1).minimumScaleFactor(0.8).padding(.top, 8)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.top, 19).padding(.bottom, 14)
            Text(sub).font(.system(size: 14)).foregroundStyle(VF.muted).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }

    // MARK: Offene Vorschläge

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HubLabel("Offene Vorschläge")
                Spacer()
                if !flow.visiblePending.isEmpty {
                    Text("Höchstens eine Karte pro 30 Minuten – der Rest wartet hier und am Punkt der Pille.")
                        .font(.system(size: 12.5)).foregroundStyle(VF.muted)
                }
            }
            if flow.visiblePending.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(VF.purple.opacity(0.8))
                    Text(flow.prefs.enabled ? "Gerade nichts offen. Flow meldet sich, wenn es etwas wirklich Hilfreiches entdeckt."
                                            : "Lernen ist pausiert – oben rechts wieder einschalten.")
                        .font(HubFont.body).foregroundStyle(VF.muted)
                }
                .padding(.horizontal, 22).frame(height: 68).frame(maxWidth: .infinity, alignment: .leading)
                .hubCard(VF.card)
            } else {
                VStack(spacing: 0) {
                    ForEach(flow.visiblePending) { s in
                        SmartPageSuggestionRow(s: s)
                        if s.id != flow.visiblePending.last?.id { Rectangle().fill(VF.hairline).frame(height: 1) }
                    }
                }
                .hubCard(VF.card)
                .clipShape(RoundedRectangle(cornerRadius: VF.cardRadius, style: .continuous))
            }
        }
    }

    // MARK: Namen & Begriffe

    private func visibleTerms(_ w: SmartWissen) -> [SmartTerm] {
        w.terms.values.filter { t in
            (t.n + t.fromMeetings) >= 2 && (t.spellKnown == false || t.kind == .person || t.fromMeetings > 0)
        }.sorted { ($0.n + $0.fromMeetings, $1.form) > ($1.n + $1.fromMeetings, $0.form) }
    }

    private func namesCard(_ w: SmartWissen) -> some View {
        let terms = Array(visibleTerms(w).prefix(24))
        let known = Set(Settings.shared.dictionary.map { $0.write.lowercased() })
        return SmartCard(title: "Namen & Begriffe", trailing: terms.isEmpty ? nil : "\(visibleTerms(w).count) ERKANNT") {
            if terms.isEmpty {
                SmartEmptyLine("Namen, Firmen und Fachwörter, die öfter vorkommen, erscheinen hier.")
            } else {
                PGFlow(spacing: 8, lineSpacing: 8) {
                    ForEach(terms, id: \.form) { t in
                        SmartChip(text: t.form, count: t.n + t.fromMeetings, symbol: symbol(t.kind),
                                  sparkle: known.contains(t.form.lowercased()))
                    }
                }
                Text("✨ = steht schon im Wörterbuch. Unbekannte Wörter schlägt Flow ab 3× fürs Wörterbuch vor.")
                    .font(.system(size: 12.5)).foregroundStyle(VF.muted).padding(.top, 14)
            }
        }
    }

    private func symbol(_ k: SmartTermKind) -> String {
        switch k {
        case .person: return "person.fill"
        case .place: return "mappin"
        case .org: return "building.2.fill"
        case .term: return "textformat"
        }
    }

    // MARK: Grüße & Abschiede

    private func greetingsCard(_ w: SmartWissen) -> some View {
        let cats = AppCategory.allCases.filter { (w.signOffs[$0.rawValue]?.isEmpty == false) || (w.greetings[$0.rawValue]?.isEmpty == false) }
        return SmartCard(title: "Grüße & Abschiede", trailing: nil) {
            if cats.isEmpty {
                SmartEmptyLine("Wie du Nachrichten beginnst und beendest – je App-Art.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(cats) { c in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: catSymbol(c)).font(.system(size: 14)).foregroundStyle(VF.ink).frame(width: 20).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(SmartLearner.shortLabel(c).uppercased()).font(HubFont.label).tracking(1.2).foregroundStyle(VF.muted)
                                if let g = top(w.greetings[c.rawValue]) {
                                    Text("Beginnst mit „\(g.form) …“ · \(g.n)×").font(.system(size: 14.5)).foregroundStyle(VF.ink)
                                }
                                if let s = top(w.signOffs[c.rawValue]) {
                                    Text("Endest mit „\(s.form)“ · \(s.n)×").font(.system(size: 14.5)).foregroundStyle(VF.ink)
                                }
                                if let r = w.register[c.rawValue], r.total >= 3 {
                                    SmartRegisterBar(formal: r.formal, casual: r.casual)
                                        .padding(.top, 3)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func top(_ d: [String: SmartCount]?) -> SmartCount? { d?.values.max { $0.n < $1.n } }

    private func catSymbol(_ c: AppCategory) -> String {
        switch c {
        case .ai: return "cpu"
        case .other: return "infinity"
        case .personal: return "ellipsis.bubble"
        case .email: return "envelope"
        case .work: return "text.bubble"
        }
    }

    // MARK: Formulierungen

    private func phrasesCard(_ w: SmartWissen) -> some View {
        let cats = AppCategory.allCases.filter { c in (w.phrases[c.rawValue]?.values.contains { $0.n >= 3 }) == true }
        let sel = cats.contains { $0.rawValue == phraseTab } ? phraseTab : (cats.first?.rawValue ?? "")
        let list = maximalPhrases(w.phrases[sel] ?? [:])
        return SmartCard(title: "Häufige Formulierungen", trailing: nil) {
            if cats.isEmpty {
                SmartEmptyLine("Sätze, die du immer wieder sagst (ab 3×), je App-Art. Einmalige Sätze merkt sich Flow nicht.")
            } else {
                HubTabs(tabs: cats.map { ($0.rawValue, SmartLearner.shortLabel($0)) },
                        selection: Binding(get: { sel }, set: { phraseTab = $0 }), spacing: 26)
                    .padding(.bottom, 10)
                VStack(spacing: 0) {
                    ForEach(Array(list.prefix(8).enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 12) {
                            Text("„\(c.form)“").font(.system(size: 15)).foregroundStyle(VF.ink).lineLimit(1)
                            Spacer(minLength: 10)
                            Text("\(c.n)× · \(c.days) \(c.days == 1 ? "Tag" : "Tage")").font(.system(size: 13, weight: .medium))
                                .foregroundStyle(VF.muted).monospacedDigit()
                        }
                        .frame(height: 40)
                        if i < min(list.count, 8) - 1 { Rectangle().fill(VF.hairline).frame(height: 1) }
                    }
                }
            }
        }
    }

    /// Nur die längste Fassung zeigen (Teilstücke mit gleicher Häufigkeit weglassen)
    private func maximalPhrases(_ d: [String: SmartCount]) -> [SmartCount] {
        let good = d.filter { $0.value.n >= 3 }
        let keys = good.keys.sorted { $0.count > $1.count }
        var kept: [(String, SmartCount)] = []
        for k in keys {
            let c = good[k]!
            if kept.contains(where: { $0.0.contains(k) && $0.1.n >= c.n - 1 }) { continue }
            kept.append((k, c))
        }
        return kept.map(\.1).sorted { ($0.n, $0.form.count) > ($1.n, $1.form.count) }
    }

    // MARK: Meetings

    private func meetingsCard(_ w: SmartWissen) -> some View {
        let people = w.meetingPeople.values.sorted { ($0.n, $1.form) > ($1.n, $0.form) }.prefix(10)
        let topics = w.meetingTopics.values.sorted { ($0.n, $1.form) > ($1.n, $0.form) }.prefix(10)
        return SmartCard(title: "Aus Meetings", trailing: w.meetings > 0 ? "\(w.meetings) AUSGEWERTET" : nil) {
            if w.meetings == 0 {
                SmartEmptyLine("Nach jedem Meeting liest Flow nur die Zusammenfassung: wer dabei war, worum es ging, welche Aufgaben du hast.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if !people.isEmpty {
                        HubLabel("Personen")
                        PGFlow(spacing: 8, lineSpacing: 8) {
                            ForEach(Array(people), id: \.form) { SmartChip(text: $0.form, count: $0.n, symbol: "person.fill") }
                        }
                    }
                    if !topics.isEmpty {
                        HubLabel("Themen").padding(.top, 4)
                        PGFlow(spacing: 8, lineSpacing: 8) {
                            ForEach(Array(topics), id: \.form) { SmartChip(text: $0.form, count: $0.n, symbol: "number") }
                        }
                    }
                    if let last = w.meetingDigests.first {
                        Rectangle().fill(VF.hairline).frame(height: 1).padding(.vertical, 4)
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle").foregroundStyle(VF.muted)
                            Text(last.title).font(HubFont.bodyMedium).foregroundStyle(VF.ink).lineLimit(1)
                            Spacer()
                            Text(HubFormat.date(last.date, "d. MMM, HH:mm")).font(.system(size: 13)).foregroundStyle(VF.muted)
                        }
                        if last.tasks > 0 {
                            Text("\(last.tasks) \(last.tasks == 1 ? "Aufgabe" : "Aufgaben") erkannt").font(.system(size: 13)).foregroundStyle(VF.muted)
                        }
                    }
                }
            }
        }
    }

    // MARK: Zeiten

    private func timesCard(_ w: SmartWissen) -> some View {
        let hours = w.hours.count == 24 ? w.hours : [Int](repeating: 0, count: 24)
        let peak = hours.enumerated().max { $0.element < $1.element }
        let days = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        let wd = w.weekdays.count == 7 ? w.weekdays : [Int](repeating: 0, count: 7)
        let topDay = wd.enumerated().max { $0.element < $1.element }
        return SmartCard(title: "Wann du sprichst",
                         trailing: (peak?.element ?? 0) > 0 ? "MEIST UM \(peak!.offset) UHR" : nil) {
            if w.dictations == 0 {
                SmartEmptyLine("Uhrzeiten und Wochentage deiner Diktate – nur als Zähler.")
            } else {
                SmartHourBars(hours: hours).frame(height: 96)
                HStack {
                    ForEach([0, 6, 12, 18, 23], id: \.self) { h in
                        Text("\(h)").font(.system(size: 11)).foregroundStyle(VF.muted)
                        if h != 23 { Spacer() }
                    }
                }
                .padding(.top, 4)
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { i in
                        let v = wd[i], mx = max(1, wd.max() ?? 1)
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(v == 0 ? VF.teal4 : (i == topDay?.offset ? VF.teal1 : VF.teal3.opacity(0.4 + 0.6 * Double(v) / Double(mx))))
                                .frame(height: 22)
                            Text(days[i]).font(.system(size: 11, weight: .medium)).foregroundStyle(VF.muted)
                        }
                    }
                }
                .padding(.top, 16)
            }
        }
    }

    // MARK: Korrekturen

    private func correctionsCard(_ w: SmartWissen) -> some View {
        let list = w.corrections.values.sorted { ($0.n, $0.last) > ($1.n, $1.last) }.prefix(8)
        return SmartCard(title: "Wiederkehrende Korrekturen", trailing: nil) {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                    HStack(spacing: 10) {
                        Text(c.old).font(.system(size: 15)).foregroundStyle(VF.muted).strikethrough(color: VF.muted.opacity(0.6))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.muted)
                        Text(c.new).font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                        Spacer()
                        if c.saved { Text("im Wörterbuch").font(.system(size: 12, weight: .medium)).foregroundStyle(VF.teal1)
                            .padding(.horizontal, 8).frame(height: 22).background(VF.teal4, in: RoundedRectangle(cornerRadius: 6)) }
                        Text("\(c.n)×").font(.system(size: 13, weight: .medium)).foregroundStyle(VF.muted).monospacedDigit()
                    }
                    .frame(height: 40)
                    if i < list.count - 1 { Rectangle().fill(VF.hairline).frame(height: 1) }
                }
            }
        }
    }

    // MARK: Vorschlagsarten

    private var kindsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HubLabel("Vorschläge")
            VStack(spacing: 0) {
                SmartToggleRow(title: "Karten aus der Pille",
                               detail: "Aus: Flow zeigt nur einen kleinen Punkt an der Pille – die Liste öffnet sich beim Darüberfahren.",
                               isOn: Binding(get: { flow.prefs.cards }, set: { flow.setCards($0) }))
                ForEach(SmartKind.allCases) { k in
                    Rectangle().fill(VF.hairline).frame(height: 1)
                    let st = flow.prefs.stat(k)
                    SmartToggleRow(title: k.label, detail: k.detail, status: status(st), stopped: st.stopped, symbol: k.symbol,
                                   isOn: Binding(get: { flow.prefs.isOn(k) && !st.stopped }, set: { flow.setKind(k, on: $0) }))
                }
            }
            .padding(.horizontal, 22)
            .hubCard(VF.cardSoft, radius: 12)
            .disabled(!flow.prefs.enabled)
            .opacity(flow.prefs.enabled ? 1 : 0.55)
        }
    }

    private func status(_ st: SmartKindStat) -> String? {
        if st.stopped { return "Gestoppt nach \(SmartPolicy.stopAfter)× Nein – einschalten, um es wieder zu erlauben" }
        var parts: [String] = []
        if st.accepted > 0 { parts.append("\(st.accepted)× angenommen") }
        if st.dismissed > 0 { parts.append("\(st.dismissed)× Nein – kommt seltener") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Claude-Überblick

    private func digestSection(_ w: SmartWissen) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HubLabel("Abend-Überblick mit Claude")
            VStack(alignment: .leading, spacing: 0) {
                SmartToggleRow(title: "Einmal am Abend drei Tipps",
                               detail: "Schickt nach 21 Uhr nur Zähler, deine häufigsten Formulierungen und Namen (je ≥ 3×) an Claude – über dein Abo, ohne Werkzeuge. Nie Diktate oder Transkripte. Aus = nichts verlässt den Mac.",
                               symbol: "moon.stars",
                               isOn: Binding(get: { flow.prefs.nightlyDigest }, set: { flow.setNightlyDigest($0) }))
                if let d = w.digest {
                    Rectangle().fill(VF.hairline).frame(height: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Letzter Überblick · \(HubFormat.date(d.date, "EEEE, d. MMM"))").font(.system(size: 13, weight: .medium)).foregroundStyle(VF.muted)
                        Text(d.text).font(.system(size: 15)).foregroundStyle(VF.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 16)
                }
                Rectangle().fill(VF.hairline).frame(height: 1)
                HStack(spacing: 10) {
                    Button(showPayload ? "Ausblenden" : "Was würde geschickt?") { withAnimation { showPayload.toggle() } }
                        .buttonStyle(HubOutlineButton())
                    if flow.prefs.nightlyDigest && ClaudeCLI.isAvailable {
                        Button("Jetzt erstellen") { SmartDigest.run() }.buttonStyle(HubBlackButton(height: 34))
                    }
                    Spacer()
                }
                .padding(.vertical, 14)
                if showPayload {
                    ScrollView {
                        Text(SmartDigest.payload(w, prefs: flow.prefs, styles: StyleStore.shared.styles))
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(VF.ink)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .frame(height: 220)
                    .background(VF.card, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 16)
                }
            }
            .padding(.horizontal, 22)
            .hubCard(VF.cardSoft, radius: 12)
            .disabled(!flow.prefs.enabled)
            .opacity(flow.prefs.enabled ? 1 : 0.55)
        }
    }

    // MARK: Datenschutz + Vergessen

    private var privacyFooter: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 22)).foregroundStyle(VF.teal1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Privat & lokal").font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                Text("Gespeichert in ~/.config/flow/wissen.json (nur für dich lesbar). Einmalige Sätze verfallen mit der Löschfrist (\(Settings.shared.retentionDays == 0 ? "nie" : "\(Settings.shared.retentionDays) Tage")). Passwortfelder und Passwort-Apps werden nie ausgewertet.")
                    .font(.system(size: 13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button { confirmForget = true } label: {
                Label("Alles vergessen", systemImage: "trash").font(HubFont.bodyMedium).foregroundStyle(Color(red: 0.72, green: 0.18, blue: 0.15))
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(Color(red: 0.98, green: 0.92, blue: 0.91), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
    }
}

// MARK: - Bausteine

/// Karte mit großem Titel (wie „Nutzung nach App-Art“ in Insights)
struct SmartCard<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 22, weight: .medium)).foregroundStyle(VF.ink).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 10)
                if let trailing { Text(trailing).font(HubFont.label).tracking(1.3).foregroundStyle(VF.ink).lineLimit(1).fixedSize() }
            }
            .padding(.bottom, 18)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(VF.cardSoft, radius: 10)
    }
}

struct SmartEmptyLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 14.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
    }
}

struct SmartChip: View {
    let text: String
    var count: Int? = nil
    var symbol: String? = nil
    var sparkle = false
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(VF.muted) }
            Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(VF.ink).lineLimit(1)
            if sparkle { Text("✨").font(.system(size: 11)) }
            if let count { Text("\(count)×").font(.system(size: 12, weight: .medium)).foregroundStyle(VF.muted).monospacedDigit() }
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(VF.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VF.hairline))
    }
}

/// Anteil formell (Petrol) vs. locker (hell)
struct SmartRegisterBar: View {
    let formal: Int
    let casual: Int
    var body: some View {
        let total = max(1, formal + casual)
        let f = Double(formal) / Double(total)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3).fill(VF.teal1).frame(width: max(4, (g.size.width - 2) * f))
                    RoundedRectangle(cornerRadius: 3).fill(VF.teal3)
                }
            }
            .frame(height: 8)
            Text("\(Int((f * 100).rounded())) % formell (Sie) · \(100 - Int((f * 100).rounded())) % locker (du)")
                .font(.system(size: 11.5)).foregroundStyle(VF.muted)
        }
        .frame(maxWidth: 260)
    }
}

struct SmartHourBars: View {
    let hours: [Int]
    var body: some View {
        let mx = max(1, hours.max() ?? 1)
        let peak = hours.firstIndex(of: mx)
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { h in
                    let v = hours[h]
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(v == 0 ? VF.teal4 : (h == peak ? VF.teal1 : VF.teal2.opacity(0.45 + 0.55 * Double(v) / Double(mx))))
                        .frame(height: max(4, g.size.height * CGFloat(v) / CGFloat(mx)))
                        .help("\(h)–\(h + 1) Uhr: \(v) Diktate")
                }
            }
        }
    }
}

struct SmartToggleRow: View {
    let title: String
    var detail: String? = nil
    var status: String? = nil
    var stopped = false
    var symbol: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(VF.ink).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15.5, weight: .medium)).foregroundStyle(VF.ink)
                if let detail { Text(detail).font(.system(size: 13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true) }
                if let status {
                    Text(status).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(stopped ? Color(red: 0.72, green: 0.35, blue: 0.12) : VF.teal1)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(VF.black)
        }
        .padding(.vertical, 15)
    }
}

/// Zeile in „Offene Vorschläge“ (hell)
struct SmartPageSuggestionRow: View {
    let s: SmartSuggestion
    @State private var hover = false
    @State private var chosen: String?

    var body: some View {
        let (bg, ink) = VFNotifyStyle.fallbackColors(s.kind.illustration)
        let options = s.payload.triggerOptions ?? []
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg)
                Image(systemName: s.kind.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(s.title).font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                    SmartConfidenceDots(value: s.confidence, dark: false)
                }
                Text(s.text).font(.system(size: 14)).foregroundStyle(VF.muted).lineLimit(2)
                if s.kind == .snippet, options.count > 1 {
                    HStack(spacing: 6) {
                        Text("Kürzel:").font(.system(size: 12.5)).foregroundStyle(VF.muted)
                        ForEach(options, id: \.self) { o in
                            let on = (chosen ?? options[0]) == o
                            Button { chosen = o } label: {
                                Text(o).font(.system(size: 12.5, weight: .medium)).foregroundStyle(on ? VF.ink : VF.muted)
                                    .padding(.horizontal, 9).frame(height: 24)
                                    .background(on ? VF.selected : VF.card, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? VF.ink.opacity(0.5) : VF.hairline))
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            Button("Nein") { SmartFlow.shared.dismiss(s.id) }.buttonStyle(HubSoftButton(height: 32))
                .help("Nein – solche Vorschläge kommen seltener (nach 3× gar nicht mehr)")
            Button(SmartFlow.primaryLabel(s.kind)) { SmartFlow.shared.accept(s.id, choice: chosen ?? options.first) }
                .buttonStyle(HubBlackButton(height: 32))
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(hover ? VF.panel : VF.card)
        .onHover { hover = $0 }
    }
}

// MARK: - Für andere Seiten

/// Kleine Karte für Insights (führt zur Seite „Gelernt“)
struct SmartInsightsCard: View {
    @ObservedObject var flow = SmartFlow.shared
    var body: some View {
        let w = flow.snapshot
        HStack(spacing: 18) {
            HubIllustration(name: "illu_insights", fallback: "sparkles", size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Flow lernt mit").font(.system(size: 19, weight: .medium)).foregroundStyle(VF.ink)
                Text("\(HubFormat.number(w.dictations)) Diktate ausgewertet · \(w.terms.values.filter { $0.n >= 2 && $0.spellKnown == false }.count) Namen · \(flow.visiblePending.count) offene Vorschläge")
                    .font(.system(size: 14)).foregroundStyle(VF.muted)
            }
            Spacer()
            Button("Ansehen") { VFHub.shared.go(VFSection(rawValue: "gelernt") ?? .insights) }.buttonStyle(HubOutlineButton())
        }
        .padding(18)
        .hubCard(VF.cardSoft, radius: 10)
    }
}

/// Zeilen fürs Einstellungs-Modal (z. B. unter „Daten & Datenschutz“)
struct SmartSettingsRows: View {
    @ObservedObject var flow = SmartFlow.shared
    @State private var confirm = false
    var body: some View {
        VStack(spacing: 0) {
            PGSettingRow(title: "Flow lernt mit",
                         detail: "Wertet Diktate und Meeting-Zusammenfassungen lokal aus und macht ab und zu einen Vorschlag an der Pille. Speichert nur Zähler und Muster.") {
                Toggle("", isOn: Binding(get: { flow.prefs.enabled }, set: { flow.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(VF.black)
            }
            Rectangle().fill(VF.hairline).frame(height: 1)
            PGSettingRow(title: "Gelerntes vergessen", detail: "Löscht wissen.json und alle offenen Vorschläge.") {
                Button("Alles vergessen") { confirm = true }
                    .buttonStyle(PGSoftButtonStyle(minWidth: 216, fill: Color(red: 0.925, green: 0.918, blue: 0.898)))
            }
        }
        .alert("Alles vergessen?", isPresented: $confirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Alles vergessen", role: .destructive) { flow.forgetAll() }
        }
    }
}
