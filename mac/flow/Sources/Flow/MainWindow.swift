import AppKit
import SwiftUI

// MARK: - Farben & Schrift (warm, ruhig, erwachsen – angelehnt an Flow)

enum Theme {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let bg = dyn(NSColor(red: 0.965, green: 0.957, blue: 0.937, alpha: 1), NSColor(red: 0.086, green: 0.086, blue: 0.082, alpha: 1))
    static let sidebar = dyn(NSColor(red: 0.937, green: 0.925, blue: 0.898, alpha: 1), NSColor(red: 0.11, green: 0.106, blue: 0.1, alpha: 1))
    static let card = dyn(.white, NSColor(red: 0.137, green: 0.133, blue: 0.125, alpha: 1))
    static let ink = dyn(NSColor(red: 0.11, green: 0.106, blue: 0.098, alpha: 1), NSColor(red: 0.95, green: 0.94, blue: 0.92, alpha: 1))
    static let muted = dyn(NSColor(red: 0.43, green: 0.41, blue: 0.39, alpha: 1), NSColor(red: 0.62, green: 0.6, blue: 0.57, alpha: 1))
    static let hairline = dyn(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.08))
    static let accent = dyn(NSColor(red: 0.16, green: 0.36, blue: 0.3, alpha: 1), NSColor(red: 0.45, green: 0.75, blue: 0.64, alpha: 1))

    static func title(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.hairline))
    }
}

// MARK: - Navigation

enum MainSection: String, CaseIterable, Identifiable {
    case start, history, meetings, dictionary, voice, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: return "Start"
        case .history: return "Verlauf"
        case .meetings: return "Meetings"
        case .dictionary: return "Wörterbuch"
        case .voice: return "Stimme"
        case .settings: return "Einstellungen"
        }
    }
    var symbol: String {
        switch self {
        case .start: return "house"
        case .history: return "clock.arrow.circlepath"
        case .meetings: return "person.2.wave.2"
        case .dictionary: return "character.book.closed"
        case .voice: return "person.wave.2"
        case .settings: return "gearshape"
        }
    }
}

final class MainNav: ObservableObject {
    static let shared = MainNav()
    @Published var section: MainSection = .start
}

final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(_ section: MainSection? = nil) {
        if let section { MainNav.shared.section = section }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Flow"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 600)
            w.contentView = NSHostingView(rootView: MainView()
                .environmentObject(MainNav.shared)
                .environmentObject(Settings.shared)
                .environmentObject(MeetingStore.shared)
                .environmentObject(DictationHistory.shared))
            w.delegate = self
            w.centerOnMouseScreen()
            w.setFrameAutosaveName("FlowMain")
            window = w
        }
        NSApp.setActivationPolicy(.regular)   // Dock-Symbol, solange das Fenster offen ist
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Hauptansicht

struct MainView: View {
    @EnvironmentObject var nav: MainNav

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            Group {
                switch nav.section {
                case .start: StartView()
                case .history: HistoryView()
                case .meetings: MeetingsPane()
                case .dictionary: DictionaryPane()
                case .voice: VoicePane()
                case .settings: SettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
        .tint(Theme.accent)
    }
}

struct Sidebar: View {
    @EnvironmentObject var nav: MainNav
    @EnvironmentObject var s: Settings
    @State private var ready = WhisperEngine.shared.ready

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("Flow").font(Theme.title(20)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 18).padding(.top, 42).padding(.bottom, 18)

            ForEach(MainSection.allCases) { sec in
                Button { nav.section = sec } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sec.symbol).frame(width: 18)
                        Text(sec.title)
                        Spacer()
                    }
                    .font(.system(size: 13.5, weight: nav.section == sec ? .semibold : .regular))
                    .foregroundStyle(nav.section == sec ? Theme.ink : Theme.muted)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(nav.section == sec ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(ready ? "Bereit · lokal" : "Startet …").font(.system(size: 11.5, weight: .medium))
                }
                HStack(spacing: 4) {
                    Keycap(text: "fn"); Text("halten zum Sprechen").font(.system(size: 11))
                }
                .foregroundStyle(Theme.muted)
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in ready = WhisperEngine.shared.ready || s.engine == .parakeet }
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.title()).foregroundStyle(Theme.ink)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted) }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Start

struct StartView: View {
    @EnvironmentObject var history: DictationHistory
    @EnvironmentObject var s: Settings

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let g = h < 11 ? "Guten Morgen" : (h < 18 ? "Hallo" : "Guten Abend")
        return "\(g), \(Identity.myName)"
    }

    var body: some View {
        let today = history.stats(since: Calendar.current.startOfDay(for: Date()))
        let week = history.stats(since: Date().addingTimeInterval(-7 * 86400))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: greeting, subtitle: dateLine)
                HStack(spacing: 12) {
                    stat("Wörter heute", "\(today.words)", "\(week.words) in 7 Tagen")
                    stat("Diktate heute", "\(today.dictations)", "\(week.dictations) in 7 Tagen")
                    stat("Tempo", today.wpm > 0 ? "\(today.wpm)" : "–", "Wörter pro Minute")
                    stat("Gespart", "\(week.minutesSaved) min", "gegenüber Tippen, 7 Tage")
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("So geht’s").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        hint([Keycap(text: "fn")], "halten, sprechen, loslassen – Text erscheint, wo dein Cursor ist")
                        hint([Keycap(text: "fn"), Keycap(text: "fn")], "doppelt tippen – freihändig sprechen, nochmal tippen zum Beenden")
                        hint([Keycap(text: "⌃"), Keycap(text: "⌥"), Keycap(text: "M")], "Meeting aufnehmen oder beenden")
                        hint([Keycap(text: "🌐")], "Maus über die Pille – Sprache wählen (\(s.languageMode.short))")
                    }
                }
                HStack {
                    Text("Zuletzt").font(Theme.title(20)).foregroundStyle(Theme.ink)
                    Spacer()
                    if !history.records.isEmpty {
                        Button("Alle ansehen") { MainNav.shared.section = .history }.buttonStyle(.link)
                    }
                }
                .padding(.top, 4)
                if history.records.isEmpty {
                    Card { Text("Noch keine Diktate. Halte fn und sprich los.").foregroundStyle(Theme.muted) }
                }
                ForEach(history.records.prefix(6)) { r in RecordRow(record: r) }
            }
            .padding(.horizontal, 36).padding(.vertical, 34)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var dateLine: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"
        return f.string(from: Date())
    }

    private func stat(_ label: String, _ value: String, _ sub: String) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                Text(value).font(.system(size: 28, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    private func hint(_ keys: [Keycap], _ text: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) { ForEach(Array(keys.enumerated()), id: \.offset) { $0.element } }
                .frame(width: 96, alignment: .leading)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink)
        }
    }
}

struct RecordRow: View {
    let record: DictationRecord
    @EnvironmentObject var history: DictationHistory
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(time).monospacedDigit()
                        Text("·")
                        Text(record.app)
                        Text("·")
                        Text("\(record.words) Wörter")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    Text(record.text).font(.system(size: 14)).foregroundStyle(Theme.ink)
                        .textSelection(.enabled).lineLimit(hover ? nil : 3)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Button { Inserter.copy(record.text); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .help("Kopieren")
                    Button { history.delete(record.id) } label: { Image(systemName: "trash") }.help("Löschen")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.muted)
                .opacity(hover || copied ? 1 : 0.35)
            }
        }
        .onHover { hover = $0 }
    }

    private var time: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(record.date) ? "HH:mm" : "d. MMM, HH:mm"
        return f.string(from: record.date)
    }
}

// MARK: - Verlauf

struct HistoryView: View {
    @EnvironmentObject var history: DictationHistory
    @EnvironmentObject var s: Settings
    @State private var query = ""

    var body: some View {
        let items = query.isEmpty ? history.records : history.records.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.app.localizedCaseInsensitiveContains(query) }
        let groups = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Verlauf",
                           subtitle: s.retentionDays > 0 ? "Deine Diktate der letzten \(s.retentionDays) Tage – danach löschen sie sich von selbst." : "Deine Diktate.")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Suchen …", text: $query).textFieldStyle(.plain)
                }
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
                if items.isEmpty {
                    Text(query.isEmpty ? "Noch nichts diktiert." : "Nichts gefunden.").foregroundStyle(Theme.muted).padding(.top, 10)
                }
                ForEach(groups, id: \.key) { day, recs in
                    Text(dayLabel(day)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).padding(.top, 8)
                    ForEach(recs) { RecordRow(record: $0) }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 34)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "HEUTE" }
        if Calendar.current.isDateInYesterday(d) { return "GESTERN" }
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"
        return f.string(from: d).uppercased()
    }
}

// MARK: - Meetings

struct MeetingsPane: View {
    @EnvironmentObject var store: MeetingStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Meetings").font(Theme.title(22)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 36).padding(.bottom, 10)
                ScrollView {
                    VStack(spacing: 6) {
                        if store.meetings.isEmpty {
                            Text("Noch keine Meetings.\n⌃⌥M startet eine Aufnahme.").font(.system(size: 12.5))
                                .foregroundStyle(Theme.muted).padding(.top, 12)
                        }
                        ForEach(store.meetings) { m in meetingRow(m) }
                    }
                    .padding(.horizontal, 10)
                }
                Button {
                    AppDelegate.shared.meeting.toggle()
                } label: {
                    Label(isRecording ? "Meeting beenden" : "Meeting aufnehmen",
                          systemImage: isRecording ? "stop.circle.fill" : "record.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : Theme.accent)
                .padding(12)
            }
            .frame(width: 270)
            .background(Theme.bg)
            Divider()
            Group {
                if let id = store.selectedID, let m = store.meeting(id) {
                    MeetingDetail(meeting: m, controller: AppDelegate.shared.meeting).id(m.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2.wave.2").font(.system(size: 34)).foregroundStyle(Theme.muted)
                        Text("Wähle links ein Meeting").foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if store.selectedID == nil { store.selectedID = store.meetings.first?.id } }
    }

    private var isRecording: Bool { store.meetings.contains { $0.status == .recording } }

    private func meetingRow(_ m: Meeting) -> some View {
        let selected = store.selectedID == m.id
        return Button { store.selectedID = m.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if m.status == .recording { Circle().fill(.red).frame(width: 7, height: 7) }
                    if m.keep == true { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
                    Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(Theme.ink)
                }
                Text(sub(m)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(selected ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
            Button(m.keep == true ? "Nicht mehr behalten" : "Behalten (nicht automatisch löschen)") { store.setKeep(m.id, !(m.keep == true)) }
            Button("Neu auswerten") { AppDelegate.shared.meeting.reprocess(meetingID: m.id) }.disabled(m.status == .recording)
            Divider()
            Button("Löschen", role: .destructive) { store.delete(m.id) }.disabled(m.status == .recording)
        }
    }

    private func sub(_ m: Meeting) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "d. MMM, HH:mm"
        switch m.status {
        case .recording: return "Läuft …"
        case .processing: return m.progressNote ?? "Wird ausgewertet …"
        case .failed: return m.progressNote ?? "Fehler"
        case .done: return "\(f.string(from: m.date)) · \(Meeting.stamp(m.duration)) · \(m.speakerKeys.count) Sprecher"
        }
    }
}

// MARK: - Wörterbuch, Stimme, Einstellungen

struct DictionaryPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Wörterbuch", subtitle: "Namen und Wörter, die Flow richtig schreiben soll. Korrigierst du ein Diktat, fragt die Pille, ob sie es sich merken soll.")
            DictionaryTab()
        }
        .padding(.horizontal, 36).padding(.vertical, 34)
        .frame(maxWidth: 900, alignment: .leading)
    }
}

struct VoicePane: View {
    @EnvironmentObject var s: Settings
    @State private var enrolled = VoiceID.isEnrolled
    @State private var voices = VoiceStore.all()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Deine Stimme", subtitle: "Damit nur zählt, was du sagst – nicht Videos, Musik oder Leute neben dir.")
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: enrolled ? "checkmark.seal.fill" : "waveform.badge.plus")
                            .font(.system(size: 28)).foregroundStyle(enrolled ? Theme.accent : Theme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(enrolled ? "Stimmprofil eingelernt" : "Noch kein Stimmprofil").font(.system(size: 15, weight: .semibold))
                            Text(enrolled ? "Flow lernt bei jedem eindeutigen Diktat ein wenig dazu." : "Einmal 22 Sekunden vorlesen – dann erkennt Flow deine Stimme.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button(enrolled ? "Neu einlernen" : "Stimme einlernen") { VoiceEnrollController.shared.show() }
                            .controlSize(.large)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Nur meine Stimme behalten", isOn: $s.onlyMyVoice).disabled(!enrolled)
                        Toggle("Ton vom Mac herausfiltern (Musik, YouTube, Meeting-Teilnehmer)", isOn: $s.filterMacAudio)
                    }
                }
                Text("Gemerkte Stimmen aus Meetings").font(Theme.title(18)).padding(.top, 6)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        if voices.isEmpty {
                            Text("Noch keine. Im Meeting-Transkript auf einen Sprecher klicken und benennen.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        ForEach(voices, id: \.name) { v in
                            HStack {
                                Image(systemName: "person.crop.circle").foregroundStyle(Theme.muted)
                                Text(v.name)
                                Text("\(v.samples)× gehört").font(.caption).foregroundStyle(Theme.muted)
                                Spacer()
                                Button("Vergessen") { VoiceStore.forget(name: v.name); voices = VoiceStore.all() }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 34)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in enrolled = VoiceID.isEnrolled }
    }
}

struct SettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageHeader(title: "Einstellungen")
            SettingsView(tabs: SettingsTabModel(), embedded: true)
        }
        .padding(.horizontal, 36).padding(.top, 34)
        .frame(maxWidth: 900, alignment: .leading)
    }
}
