import AppKit
import EventKit
import SwiftUI

// MARK: - Notetaker: Hinweis-Karte, HEUTE-Kalender, vergangene Notizen, Übersicht rechts, Frage-Leiste unten

/// Heutige Termine aus dem Kalender. Zugriff wird NUR angefragt, wenn du auf „Kalender verbinden“ klickt.
final class HubCalendar: ObservableObject {
    static let shared = HubCalendar()
    private let store = EKEventStore()
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [EKEvent] = []
    private var observer: NSObjectProtocol?

    var connected: Bool { status == .fullAccess }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard connected else { events = []; return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: pred)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    func connect() {
        switch status {
        case .denied, .restricted:
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(u) }
        default:
            store.requestFullAccessToEvents { [weak self] granted, error in
                DispatchQueue.main.async {
                    if let error { log("Kalender: \(error.localizedDescription)") }
                    log("Kalender-Zugriff: \(granted)")
                    self?.refresh()
                }
            }
        }
    }
}

struct HubNotetakerPage: View {
    @ObservedObject var store = MeetingStore.shared
    @ObservedObject var calendar = HubCalendar.shared
    @ObservedObject var hub = VFHub.shared
    @AppStorage("vf.hub.notetaker.intro.hidden") private var introHidden = false
    @State private var tab = 0
    @State private var searching = false
    @State private var query = ""
    /// Nur für Render/Tests: direkt eine Notiz geöffnet zeigen
    static var renderOpenedID: String?
    /// Programmatisch eine Notiz öffnen (z. B. „Transkript öffnen“ aus einer Meldung): beim Erscheinen oder per Benachrichtigung
    static var pendingOpen: String?
    static let openNoteRequest = Notification.Name("vf.hub.openNote")
    @State private var openedID: String? = HubNotetakerPage.renderOpenedID
    @State private var openNonce = 0
    @State private var question = ""
    @State private var askPanelID: String?

    private var isRecording: Bool { store.meetings.contains { $0.status == .recording } }

    var body: some View {
        Group {
            if let id = openedID, let m = store.meeting(id) {
                fullDetail(m)
            } else {
                HStack(spacing: 0) {
                    mainColumn
                    Rectangle().fill(VF.hairline).frame(width: 1)
                    HubMeetingOverview(meeting: selected, onOpen: { openedID = $0 })
                        .frame(width: 280)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HubNotetakerPage.openNoteRequest)) { n in
            guard let id = n.object as? String else { return }
            HubNotetakerPage.pendingOpen = nil
            openedID = id; openNonce += 1
        }
        .onAppear {
            if let id = HubNotetakerPage.pendingOpen { HubNotetakerPage.pendingOpen = nil; openedID = id; openNonce += 1 }
            if store.selectedID == nil { store.selectedID = store.meetings.first?.id }
            calendar.refresh()
        }
    }

    private var selected: Meeting? { store.selectedID.flatMap { store.meeting($0) } ?? store.meetings.first }

    // MARK: Hauptspalte

    private var mainColumn: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 26)
                    if !introHidden { introCard.padding(.bottom, 32) }
                    AudioImportCard().padding(.bottom, 32)
                    todayCard.padding(.bottom, 44)
                    HubTabs(tabs: [(0, "Vergangene Notizen"), (1, "Behalten")], selection: $tab, spacing: 32,
                            trailing: AnyView(searchButton))
                    if searching { searchField.padding(.top, 14) }
                    notesList.padding(.top, 26)
                }
                .padding(.horizontal, 40).padding(.top, 42).padding(.bottom, 110)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
            if let id = askPanelID, let m = store.meeting(id) {
                HubAskPanel(meeting: m) { withAnimation(.easeOut(duration: 0.15)) { askPanelID = nil } }
                    .padding(.horizontal, 25).padding(.bottom, 86)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            askBar.padding(.horizontal, 25).padding(.bottom, 26)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Notetaker").font(HubFont.title).foregroundStyle(VF.ink)
            Spacer()
            HubIconButton(symbol: "gearshape", size: 16, help: "Notetaker-Einstellungen") { hub.openSettings("notetaker") }
            Button { AppDelegate.shared.meeting.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isRecording ? "stop.fill" : "plus").font(.system(size: 13, weight: .medium))
                    Text(isRecording ? "Aufnahme beenden" : "Neue Notiz")
                }
                .foregroundStyle(isRecording ? Color(red: 0.75, green: 0.15, blue: 0.12) : VF.ink)
            }
            .buttonStyle(HubSoftButton(height: 32))
            .help("Meeting-Aufnahme starten/beenden (⌃⌥M)")
        }
    }

    private var introCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                .frame(width: 38, height: 38)
                .background(VF.card, in: Circle()).overlay(Circle().stroke(VF.hairline))
            VStack(alignment: .leading, spacing: 3) {
                Text("Meetings werden automatisch erkannt").font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                Text("Startet Zoom, Teams oder Meet, fragt Flow, ob es mitschreiben soll – alles lokal.")
                    .font(HubFont.body).foregroundStyle(VF.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 12)
            Button("Überspringen") { withAnimation { introHidden = true } }
                .buttonStyle(.plain).font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                .padding(.trailing, 6)
            Button("Einrichten") { hub.openSettings("notetaker") }.buttonStyle(HubOutlineButton())
        }
        .padding(.leading, 16).padding(.trailing, 16)
        .frame(height: 77)
        .hubCard(VF.card, radius: 14)
    }

    // MARK: HEUTE

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubLabel("Heute", color: VF.ink)
            if calendar.connected && !calendar.events.isEmpty {
                VStack(spacing: 6) {
                    ForEach(calendar.events, id: \.eventIdentifier) { e in HubEventRow(event: e, isRecording: isRecording) }
                }
                .padding(.top, 16)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 27, weight: .light)).foregroundStyle(VF.muted)
                    Text(calendar.connected ? "Heute keine Meetings" : "Keine Meetings gefunden")
                        .font(.system(size: 18)).foregroundStyle(VF.muted)
                    if !calendar.connected {
                        Button(calendar.status == .denied ? "Kalender-Zugriff erlauben" : "Kalender verbinden") { calendar.connect() }
                            .buttonStyle(HubBlackButton(height: 32))
                            .padding(.top, 2)
                    } else {
                        Text("Kalender ist verbunden").font(.system(size: 13)).foregroundStyle(VF.muted.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 38).padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 20)
        .frame(maxWidth: .infinity, minHeight: 235, alignment: .topLeading)
        .background(VF.cardSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Liste

    private var searchButton: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { searching.toggle(); if !searching { query = "" } } } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(VF.muted)
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Notizen durchsuchen")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VF.muted)
            TextField("Titel, Zusammenfassung oder Transkript …", text: $query).textFieldStyle(.plain).font(HubFont.body)
            Button { query = ""; searching = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(VF.muted.opacity(0.7)) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).frame(height: 38)
        .hubCard(VF.card, radius: 10)
    }

    private var listed: [Meeting] {
        var list = store.meetings
        if tab == 1 { list = list.filter { $0.keep == true } }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(q) || ($0.summary ?? "").localizedCaseInsensitiveContains(q)
                    || $0.segments.contains { $0.text.localizedCaseInsensitiveContains(q) }
                    || MCSearch.matches($0.id, q)
            }
        }
        return list
    }

    private var groups: [(day: Date, meetings: [Meeting])] {
        let cal = Calendar.current
        var order: [Date] = []
        var map: [Date: [Meeting]] = [:]
        for m in listed {
            let d = cal.startOfDay(for: m.date)
            if map[d] == nil { order.append(d) }
            map[d, default: []].append(m)
        }
        return order.sorted(by: >).map { ($0, map[$0]!) }
    }

    private func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Heute" }
        if Calendar.current.isDateInYesterday(d) { return "Gestern" }
        return HubFormat.date(d, "EEE, d. MMMM")
    }

    @ViewBuilder private var notesList: some View {
        let gs = groups
        if gs.isEmpty {
            VStack(spacing: 12) {
                HubIllustration(name: "illu_meeting_erkannt", fallback: "waveform", size: 90)
                Text(tab == 1 ? "Noch nichts behalten" : (query.isEmpty ? "Noch keine Notizen" : "Nichts gefunden"))
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(VF.ink)
                Text(tab == 1 ? "Rechtsklick auf eine Notiz → „Behalten“ – dann löscht sie sich nie automatisch."
                              : "„+ Neue Notiz“ oder ⌃⌥M startet eine Aufnahme.")
                    .font(HubFont.small).foregroundStyle(VF.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(gs.enumerated()), id: \.element.day) { i, g in
                HubLabel(dayLabel(g.day)).padding(.leading, 5).padding(.top, i == 0 ? 0 : 22).padding(.bottom, 14)
                VStack(spacing: 4) {
                    ForEach(g.meetings) { m in
                        HubMeetingRow(meeting: m, selected: selected?.id == m.id,
                                      select: { store.selectedID = m.id },
                                      open: { openedID = m.id })
                    }
                }
            }
        }
    }

    // MARK: Frage-Leiste

    private var askTarget: Meeting? { selected }

    private var askPlaceholder: String {
        guard let m = askTarget else { return "Noch kein Meeting zum Fragen" }
        if m.id == store.meetings.first?.id { return "Welche Fragen blieben im letzten Meeting offen?" }
        return "Frag etwas zu „\(m.title)“ …"
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if question.isEmpty {
                    Text(askPlaceholder).font(HubFont.body).foregroundStyle(VF.muted.opacity(0.75))
                        .lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: $question)
                    .textFieldStyle(.plain).font(HubFont.body)
                    .onSubmit(send)
                    .disabled(askTarget == nil)
            }
            if let m = askTarget, !m.chat.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { askPanelID = askPanelID == m.id ? nil : m.id } } label: {
                    HStack(spacing: 4) {
                        Text("Bisherige Fragen")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(VF.ink)
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(VF.cardSoft, in: Capsule()).overlay(Capsule().stroke(VF.hairline))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 24).padding(.trailing, 10)
        .frame(height: 48)
        .background(VF.card, in: Capsule())
        .overlay(Capsule().stroke(VF.hairline))
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
    }

    private func send() {
        guard let m = askTarget else { return }
        var q = question.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { q = m.id == store.meetings.first?.id ? "Welche Fragen blieben im letzten Meeting offen?" : "" }
        guard !q.isEmpty else { return }
        AppDelegate.shared.meeting.ask(meetingID: m.id, question: q)
        question = ""
        withAnimation(.easeOut(duration: 0.15)) { askPanelID = m.id }
    }

    // MARK: Vollansicht

    private func fullDetail(_ m: Meeting) -> some View {
        HubNoteDetail(meetingID: m.id) { withAnimation(.easeOut(duration: 0.15)) { openedID = nil } }
            .id("\(m.id)#\(openNonce)")
    }
}

// MARK: - Zeile „vergangene Notiz“

struct HubMeetingRow: View {
    let meeting: Meeting
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    @State private var hover = false

    private var subtitle: String {
        switch meeting.status {
        case .recording: return "Läuft … seit \(HubFormat.time(meeting.date))"
        case .processing: return meeting.progressNote ?? "Wird ausgewertet …"
        case .failed: return meeting.progressNote ?? "Fehler"
        case .done:
            let mins = Int((meeting.duration / 60).rounded())
            return "\(HubFormat.time(meeting.date))" + (mins > 0 ? " · \(mins) Min." : "") + (meeting.app.map { " · \($0)" } ?? "")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VF.buttonSoft)
                AudioImportTileWater(meetingID: meeting.id)   // Audiodatei läuft: füllt sich von oben mit Wasser
                Image(systemName: meeting.status == .recording ? "waveform" : (meeting.app == "Datei" ? "waveform.badge.plus" : "doc.text"))
                    .font(.system(size: 14)).foregroundStyle(meeting.status == .recording ? .red : VF.muted)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(meeting.title).font(.system(size: 15)).foregroundStyle(selected ? VF.ink : VF.ink.opacity(0.72)).lineLimit(1)
                    if meeting.keep == true { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(VF.muted) }
                }
                Text(subtitle).font(.system(size: 13)).foregroundStyle(VF.muted).lineLimit(1)
                AudioImportRowProgress(meetingID: meeting.id)
            }
            Spacer(minLength: 8)
            AudioImportRowCancel(meetingID: meeting.id)
            if hover && AudioImport.shared.live[meeting.id] == nil {
                MCAgentButton(meeting: meeting, compact: true)
                Button("Öffnen", action: open).buttonStyle(HubOutlineButton(height: 28)).font(.system(size: 12.5, weight: .medium))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 66)
        .background(selected ? VF.cardSoft : (hover ? VF.cardSoft.opacity(0.55) : .clear),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded(open))
        .contextMenu {
            Button("Öffnen", action: open)
            Button(meeting.keep == true ? "Nicht mehr behalten" : "Behalten (nicht automatisch löschen)") {
                MeetingStore.shared.setKeep(meeting.id, !(meeting.keep == true))
            }
            Button("Neu auswerten") { AppDelegate.shared.meeting.reprocess(meetingID: meeting.id) }.disabled(meeting.status == .recording)
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
            Divider()
            Button("Löschen", role: .destructive) { MeetingStore.shared.delete(meeting.id) }.disabled(meeting.status == .recording)
        }
    }
}

// MARK: - Termin aus dem Kalender

struct HubEventRow: View {
    let event: EKEvent
    let isRecording: Bool

    var body: some View {
        let now = Date()
        let live = event.startDate <= now.addingTimeInterval(600) && event.endDate > now
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.calendar?.color ?? .systemTeal)).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? "Termin").font(HubFont.bodyMedium).foregroundStyle(VF.ink).lineLimit(1)
                Text("\(HubFormat.time(event.startDate)) – \(HubFormat.time(event.endDate))" + (event.location.map { " · \($0)" } ?? ""))
                    .font(.system(size: 13)).foregroundStyle(VF.muted).lineLimit(1)
            }
            Spacer()
            if live && !isRecording {
                Button("Aufnehmen") { AppDelegate.shared.meeting.toggle() }.buttonStyle(HubBlackButton(height: 28))
            } else if event.endDate < now {
                Text("vorbei").font(.system(size: 12)).foregroundStyle(VF.muted)
            }
        }
        .padding(.horizontal, 12).frame(height: 54)
        .background(VF.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(event.endDate < now ? 0.6 : 1)
    }
}

// MARK: - Rechte Spalte: Titel, Datum, ÜBERSICHT

struct HubMeetingOverview: View {
    let meeting: Meeting?
    let onOpen: (String) -> Void

    var body: some View {
        if let m = meeting {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(m.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(VF.ink)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(HubFormat.date(m.date, "EEEE") + "  •  " + HubFormat.time(m.date))
                        .font(.system(size: 15)).foregroundStyle(VF.muted)
                    Button("Öffnen") { onOpen(m.id) }
                        .buttonStyle(HubSoftButton(height: 28)).font(.system(size: 12.5, weight: .medium))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 25).padding(.top, 38).padding(.bottom, 22)
                Rectangle().fill(VF.hairline).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HubLabel("Übersicht")
                        overview(m)
                    }
                    .padding(.horizontal, 25).padding(.top, 34).padding(.bottom, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 12) {
                HubIllustration(name: "illu_meeting_vorbei", fallback: "doc.text", size: 90)
                Text("Wähle eine Notiz").font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                Text("Die Übersicht erscheint hier.").font(HubFont.small).foregroundStyle(VF.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func overview(_ m: Meeting) -> some View {
        switch m.status {
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("Läuft … die Übersicht kommt nach dem Meeting.").font(.system(size: 15)).foregroundStyle(VF.muted)
            }
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(m.progressNote ?? "Wird ausgewertet …").font(.system(size: 15)).foregroundStyle(VF.muted)
            }
        case .failed:
            Text(m.progressNote ?? "Auswertung fehlgeschlagen.").font(.system(size: 15)).foregroundStyle(VF.muted)
        case .done:
            if let s = m.summary, !s.isEmpty {
                HubMarkdownView(text: s, size: 14.5).textSelection(.enabled)
            } else {
                Text("Noch keine Zusammenfassung.").font(.system(size: 15)).foregroundStyle(VF.muted)
            }
        }
    }
}

enum HubMarkdown {
    static func render(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        // Links aus KI-Antworten nicht klickbar (Inhalt stammt aus fremden Meeting-Beiträgen)
        for run in a.runs where run.link != nil { a[run.range].link = nil }
        return a
    }
}

// MARK: - Antworten auf Fragen (über der Frage-Leiste)

struct HubAskPanel: View {
    let meeting: Meeting
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(VF.purple)
                Text("Fragen zu „\(meeting.title)“").font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink).lineLimit(1)
                Spacer()
                HubIconButton(symbol: "xmark", size: 11, color: VF.muted, help: "Schließen", action: close)
            }
            .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 10)
            Rectangle().fill(VF.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(meeting.chat) { c in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Spacer(minLength: 60)
                                    Text(c.question).font(.system(size: 14)).foregroundStyle(VF.ink)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(VF.cardSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                if let a = c.answer {
                                    HubMarkdownView(text: a, size: 14).textSelection(.enabled)
                                    HStack {
                                        Spacer()
                                        HubIconButton(symbol: "doc.on.doc", size: 12, color: VF.muted, help: "Antwort kopieren") {
                                            Inserter.copy(a)
                                        }
                                    }
                                } else {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Claude denkt …").font(.system(size: 13)).foregroundStyle(VF.muted)
                                    }
                                }
                            }
                            .id(c.id)
                        }
                    }
                    .padding(20)
                }
                .frame(height: 300)
                .onAppear { if let l = meeting.chat.last { proxy.scrollTo(l.id, anchor: .bottom) } }
                .onChange(of: meeting.chat) { if let l = meeting.chat.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
            }
        }
        .background(VF.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(VF.hairline))
        .shadow(color: .black.opacity(0.10), radius: 20, y: 6)
    }
}
