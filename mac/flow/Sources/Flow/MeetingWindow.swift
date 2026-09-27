import AppKit
import SwiftUI

final class MeetingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var controller: MeetingController?

    init(controller: MeetingController) { self.controller = controller }

    func show() {
        if window == nil, let c = controller {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Flow – Meetings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.contentView = NSHostingView(rootView: MeetingsView(controller: c).environmentObject(MeetingStore.shared))
            w.delegate = self
            window = w
        }
        if let w = window, !w.isVisible { w.centerOnMouseScreen() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

private let speakerColors: [Color] = [
    Color(red: 0.36, green: 0.29, blue: 0.85), Color(red: 0.05, green: 0.55, blue: 0.47), Color(red: 0.80, green: 0.35, blue: 0.10),
    Color(red: 0.75, green: 0.18, blue: 0.42), Color(red: 0.12, green: 0.45, blue: 0.80), Color(red: 0.50, green: 0.45, blue: 0.10),
]

private func color(for key: String, in m: Meeting) -> Color {
    if key == "me" { return Color(red: 0.12, green: 0.12, blue: 0.14) }
    let keys = m.speakerKeys.filter { $0 != "me" }
    let i = keys.firstIndex(of: key) ?? 0
    return speakerColors[i % speakerColors.count]
}

struct MeetingsView: View {
    let controller: MeetingController
    @EnvironmentObject var store: MeetingStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedID) {
                ForEach(store.meetings) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if m.status == .recording { Circle().fill(.red).frame(width: 7, height: 7) }
                            if m.keep == true { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
                            Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        Text(subtitle(m)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .tag(m.id)
                    .contextMenu {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
                        Button("Neu auswerten") { controller.reprocess(meetingID: m.id) }.disabled(m.status == .recording)
                        Button(m.keep == true ? "Nicht mehr behalten" : "Behalten (nicht automatisch löschen)") {
                            store.setKeep(m.id, !(m.keep == true))
                        }
                        Divider()
                        Button("Löschen", role: .destructive) { store.delete(m.id) }.disabled(m.status == .recording)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                Button {
                    controller.toggle()
                } label: {
                    Label(isRecording ? "Meeting beenden" : "Meeting aufnehmen",
                          systemImage: isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .accentColor)
                .padding(12)
            }
        } detail: {
            if let id = store.selectedID, let m = store.meeting(id) {
                MeetingDetail(meeting: m, controller: controller)
                    .id(m.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Noch kein Meeting ausgewählt").foregroundStyle(.secondary)
                    Text("⌃⌥M startet eine Aufnahme").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { if store.selectedID == nil { store.selectedID = store.meetings.first?.id } }
    }

    private var isRecording: Bool { store.meetings.contains { $0.status == .recording } }

    private func subtitle(_ m: Meeting) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateFormat = "d. MMM yyyy, HH:mm"
        switch m.status {
        case .recording: return "Läuft …"
        case .processing: return m.progressNote ?? "Wird ausgewertet …"
        case .failed: return m.progressNote ?? "Fehler"
        case .done: return "\(df.string(from: m.date)) · \(Meeting.stamp(m.duration)) · \(m.speakerKeys.count) Sprecher"
        }
    }
}

struct MeetingDetail: View {
    let meeting: Meeting
    let controller: MeetingController
    @State private var tab = 0
    @State private var question = ""
    @State private var copied = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text("Transkript").tag(0)
                Text("Zusammenfassung").tag(1)
                Text("Fragen").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .padding(.horizontal, 28).padding(.bottom, 10)
            Divider()
            switch tab {
            case 0: transcript
            case 1: summary
            default: chat
            }
        }
        .background(Theme.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title).font(.system(size: 26, weight: .semibold, design: .serif)).lineLimit(2)
                Spacer()
                if meeting.status == .recording {
                    Button { controller.whatDidIMiss(meetingID: meeting.id); tab = 2 } label: {
                        Label("Was hab ich verpasst?", systemImage: "sparkles")
                    }
                    Button(role: .destructive) { controller.stop() } label: { Label("Beenden", systemImage: "stop.fill") }
                        .tint(.red).buttonStyle(.borderedProminent)
                } else {
                    Button { copyTranscript() } label: {
                        Label(copied ? "Kopiert" : "Transkript kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Menu {
                        Button("Zusammenfassung kopieren") { if let s = meeting.summary { Inserter.copy(s, source: "Meeting") } }
                            .disabled(meeting.summary == nil)
                        Button("Alles als Markdown kopieren") { Inserter.copy(meeting.markdown(), source: "Meeting") }
                        Button("Als Datei sichern …") { exportMarkdown() }
                        Divider()
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
                        Button(meeting.keep == true ? "Nicht mehr behalten" : "Behalten (nicht automatisch löschen)") {
                            MeetingStore.shared.setKeep(meeting.id, !(meeting.keep == true))
                        }
                        Button("Zusammenfassung neu schreiben") { controller.summarize(meetingID: meeting.id) }
                        Button("Neu auswerten") { controller.reprocess(meetingID: meeting.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            HStack(spacing: 8) {
                Text(dateLine).foregroundStyle(.secondary)
                if let note = meeting.progressNote {
                    ProgressView().controlSize(.small)
                    Text(note).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            if !meeting.speakerKeys.isEmpty {
                HStack(spacing: 6) {
                    ForEach(meeting.speakerKeys, id: \.self) { k in
                        Button { startRename(k) } label: {
                            Text(meeting.name(for: k))
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(color(for: k, in: meeting).opacity(0.12), in: Capsule())
                                .foregroundStyle(color(for: k, in: meeting))
                        }
                        .buttonStyle(.plain)
                        .help("Klicken zum Umbenennen")
                        .popover(isPresented: Binding(get: { renaming == k }, set: { if !$0 { renaming = nil } })) {
                            renamePopover(k)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 14)
    }

    private func renamePopover(_ k: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wer ist das?").font(.headline)
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit { commitRename(k) }
            if meeting.speakerEmbeddings[k] != nil {
                Toggle("Stimme für künftige Meetings merken", isOn: $remember).font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("Abbrechen") { renaming = nil }
                Button("Sichern") { commitRename(k) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func startRename(_ k: String) {
        newName = meeting.speakerNames[k] ?? ""
        remember = true
        renaming = k
    }

    private func commitRename(_ k: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { controller.rename(meetingID: meeting.id, speaker: k, to: n, remember: remember) }
        renaming = nil
    }

    private var dateLine: String {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateFormat = "EEEE, d. MMMM yyyy · HH:mm"
        var s = df.string(from: meeting.date)
        if meeting.status != .recording { s += " · \(Meeting.stamp(meeting.duration))" }
        if let a = meeting.app { s += " · \(a)" }
        if meeting.keep == true { s += " · 📌 wird behalten" }
        else if let d = meeting.deletionDate {
            let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, HH:mm"
            s += " · löscht sich \(f.string(from: d))"
        }
        return s
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if meeting.segments.isEmpty {
                        Text(meeting.status == .recording ? "Hört zu … die Mitschrift erscheint hier live." : "Kein Text erkannt.")
                            .foregroundStyle(.secondary).padding(.top, 20)
                    }
                    ForEach(Array(meeting.segments.enumerated()), id: \.element.id) { i, s in
                        let showName = i == 0 || meeting.segments[i - 1].speaker != s.speaker
                        VStack(alignment: .leading, spacing: 5) {
                            if showName {
                                HStack(spacing: 8) {
                                    Text(meeting.name(for: s.speaker))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(color(for: s.speaker, in: meeting))
                                        .onTapGesture { startRename(s.speaker) }
                                    Text(Meeting.stamp(s.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                                }
                            }
                            Text(s.text)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .id(s.id)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .onChange(of: meeting.segments.count) {
                if meeting.status == .recording, let last = meeting.segments.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let s = meeting.summary, !s.isEmpty {
                    HStack {
                        Label("Zusammenfassung", systemImage: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { Inserter.copy(s, source: "Meeting") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }
                    Text(markdown(s)).font(.system(size: 14)).textSelection(.enabled).lineSpacing(3)
                } else if meeting.status == .done {
                    Text("Noch keine Zusammenfassung.").foregroundStyle(.secondary)
                    Button("Jetzt mit Claude zusammenfassen") { controller.summarize(meetingID: meeting.id) }
                } else {
                    Text("Die Zusammenfassung kommt, sobald das Meeting ausgewertet ist.").foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if meeting.chat.isEmpty {
                        Text("Frag etwas über dieses Meeting – z. B. „Welche Aufgaben habe ich bekommen?“")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(meeting.chat) { c in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Spacer(); Text(c.question).padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12)) }
                            if let a = c.answer {
                                Text(markdown(a)).textSelection(.enabled).font(.system(size: 14))
                            } else {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Claude denkt …").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Frag etwas …", text: $question)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .onSubmit(send)
                Button("Was hab ich verpasst?") { controller.whatDidIMiss(meetingID: meeting.id) }
                    .disabled(meeting.segments.isEmpty)
            }
            .padding(14)
        }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        controller.ask(meetingID: meeting.id, question: q)
        question = ""
    }

    private func markdown(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        // Links aus KI-Antworten nicht klickbar machen (Inhalt kommt aus fremden Meeting-Beiträgen)
        for run in a.runs where run.link != nil { a[run.range].link = nil }
        return a
    }

    private func copyTranscript() {
        Inserter.copy(meeting.transcriptText(), source: "Meeting")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func exportMarkdown() {
        let p = NSSavePanel()
        p.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        p.allowedContentTypes = [.init(filenameExtension: "md")!]
        if p.runModal() == .OK, let u = p.url { try? meeting.markdown().write(to: u, atomically: true, encoding: .utf8) }
    }
}
