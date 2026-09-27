import AppKit
import SwiftUI

// MARK: - Notiz-Detail im Hub (Notetaker-Stil): Serif-Titel, Reiter „Meine Notizen · Transkript · ✦ Zusammenfassung“,
// Sprechblasen, Lesezeit-Leiste, schwebende Frage-Leiste mit „Stopp“ und „Was hab ich verpasst?“

struct HubNoteDetail: View {
    enum Tab: Hashable { case notizen, transkript, zusammenfassung, bilder }

    let meetingID: String
    var onBack: () -> Void = {}

    /// Nur für Render/Tests: Start-Reiter und offenes Antwort-Panel erzwingen
    static var renderTab: Tab?
    static var renderAskOpen = false
    /// Einmalig: mit diesem Reiter öffnen (z. B. „Transkript öffnen“)
    static var pendingTab: Tab?

    @ObservedObject private var store = MeetingStore.shared
    @State private var tab: Tab
    @State private var question = ""
    @State private var askOpen: Bool
    @State private var copied = false
    @State private var confirmDelete = false

    init(meetingID: String, onBack: @escaping () -> Void = {}) {
        self.meetingID = meetingID
        self.onBack = onBack
        let m = MeetingStore.shared.meeting(meetingID)
        let initial: Tab
        if let t = HubNoteDetail.pendingTab { initial = t; HubNoteDetail.pendingTab = nil }
        else if let t = HubNoteDetail.renderTab { initial = t }
        else if let m, m.status == .done, !(m.summary ?? "").isEmpty { initial = .zusammenfassung }
        else { initial = .transkript }
        _tab = State(initialValue: initial)
        _askOpen = State(initialValue: HubNoteDetail.renderAskOpen)
    }

    private var controller: MeetingController { AppDelegate.shared.meeting }

    var body: some View {
        Group {
            if let m = store.meeting(meetingID) {
                content(m)
            } else {
                Color.clear.onAppear(perform: onBack)
            }
        }
        .environment(\.colorScheme, .light)
    }

    private func content(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow(m)
                .padding(.horizontal, 48).padding(.top, 22)
            VStack(alignment: .leading, spacing: 0) {
                header(m).padding(.top, 22).padding(.bottom, 26)
                HubTabs(tabs: [(Tab.notizen, "Meine Notizen"), (Tab.transkript, "Transkript"), (Tab.zusammenfassung, "✦ Zusammenfassung"), (Tab.bilder, "Bilder")],
                        selection: $tab, spacing: 28)
            }
            .frame(maxWidth: HubNoteDetail.column, alignment: .leading)
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity)
            Group {
                switch tab {
                case .notizen: HubNoteThoughts(meetingID: m.id)
                case .transkript: HubNoteTranscript(meeting: m)
                case .zusammenfassung: HubNoteSummary(meeting: m)
                case .bilder: HubNoteFrames(meeting: m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) { bottom(m) }
        .confirmationDialog("„\(m.title)“ endgültig löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { MeetingStore.shared.delete(m.id); HubNotesStore.delete(m.id); onBack() }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Transkript, Aufnahme, Bilder und Notizen werden gelöscht.") }
    }

    static let column: CGFloat = 860

    // MARK: Kopfzeile

    private func topRow(_ m: Meeting) -> some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Alle Notizen")
                }
                .font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                .padding(.horizontal, 10).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.leading, -10)
            Spacer()
            MCAgentButton(meeting: m)
            if m.status != .recording {
                Button {
                    Inserter.copy(m.transcriptText(), source: "Meeting")
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12.5, weight: .medium))
                        Text(copied ? "Kopiert" : "Transkript kopieren")
                    }
                    .font(.system(size: 13.5, weight: .medium))
                }
                .buttonStyle(HubSoftButton(height: 30))
                .disabled(m.segments.isEmpty)
            }
            moreMenu(m)
        }
    }

    private func moreMenu(_ m: Meeting) -> some View {
        Menu {
            Button("Zusammenfassung kopieren") { if let s = m.summary { Inserter.copy(s, source: "Meeting") } }
                .disabled((m.summary ?? "").isEmpty)
            Button("Als Markdown sichern …") { exportMarkdown(m) }
            Button(NoteExport.Kind.text.menuTitle) { NoteExport.save(m, .text) }.disabled(m.segments.isEmpty)
            Button(NoteExport.Kind.srt.menuTitle) { NoteExport.save(m, .srt) }.disabled(m.segments.isEmpty)
            if AudioImport.isFileNote(m.id), let src = AudioImportFiles.loadJob(m.id)?.sourceURL {
                Button("Originaldatei im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([src]) }
                    .disabled(!FileManager.default.fileExists(atPath: src.path))
            }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
            Divider()
            Button("Zusammenfassung neu schreiben") { controller.summarize(meetingID: m.id) }
                .disabled(m.status != .done || m.segments.isEmpty)
            Button("Neu auswerten") { controller.reprocess(meetingID: m.id) }.disabled(m.status == .recording)
            Button(m.keep == true ? "Nicht mehr behalten" : "Behalten (nicht automatisch löschen)") {
                MeetingStore.shared.setKeep(m.id, !(m.keep == true))
            }
            Divider()
            Button("Löschen …", role: .destructive) { confirmDelete = true }.disabled(m.status == .recording)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(VF.ink)
                .frame(width: 30, height: 30)
                .background(VF.buttonSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mehr")
    }

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.title)
                .font(VF.serif(38)).foregroundStyle(VF.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if m.status == .recording {
                    HubRecordingDot()
                    Text("Läuft seit \(HubFormat.time(m.date))").foregroundStyle(Color(red: 0.78, green: 0.16, blue: 0.13))
                    Text("·")
                }
                Text(metaLine(m)).lineLimit(1).truncationMode(.tail)
                if let note = m.progressNote, m.status != .recording {
                    Text("·")
                    ProgressView().controlSize(.mini)
                    Text(note).lineLimit(1)
                }
            }
            .font(.system(size: 13)).foregroundStyle(VF.muted)
            if !m.speakerKeys.isEmpty {
                HStack(spacing: 6) {
                    ForEach(m.speakerKeys, id: \.self) { k in HubSpeakerChip(meeting: m, key: k) }
                }
                .padding(.top, 2)
            }
        }
    }

    private func metaLine(_ m: Meeting) -> String {
        var parts = [HubFormat.date(m.date, "EEEE, d. MMMM yyyy · HH:mm")]
        if m.status != .recording, m.duration > 0 { parts.append(HubNoteDetail.duration(m.duration)) }
        if let a = m.app, !a.isEmpty { parts.append(a) }
        if m.keep == true { parts.append("📌 wird behalten") }
        else if let d = m.deletionDate { parts.append("löscht sich \(HubFormat.date(d, "EEEE, HH:mm"))") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) Sek." }
        if t < 3600 { return "\(t / 60) Min." }
        return "\(t / 3600) Std. \(t / 60 % 60) Min."
    }

    // MARK: Frage-Leiste + Antworten

    private func bottom(_ m: Meeting) -> some View {
        VStack(spacing: 12) {
            if askOpen, !m.chat.isEmpty {
                HubAskPanel(meeting: m) { withAnimation(.easeOut(duration: 0.15)) { askOpen = false } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            askBar(m)
        }
        .frame(maxWidth: 780)
        .padding(.horizontal, 32).padding(.bottom, 24)
    }

    private func askBar(_ m: Meeting) -> some View {
        HStack(spacing: 10) {
            if m.status == .recording {
                Button { controller.stop() } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.86, green: 0.2, blue: 0.16)).frame(width: 9, height: 9)
                        Text("Stopp").font(.system(size: 13.5, weight: .medium)).foregroundStyle(VF.ink)
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(VF.card, in: Capsule())
                    .overlay(Capsule().stroke(VF.hairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Aufnahme beenden (⌃⌥M)")
            }
            ZStack(alignment: .leading) {
                if question.isEmpty {
                    Text("Frag etwas …").font(HubFont.body).foregroundStyle(VF.muted.opacity(0.75)).allowsHitTesting(false)
                }
                TextField("", text: $question)
                    .textFieldStyle(.plain).font(HubFont.body)
                    .onSubmit { send(m) }
            }
            .padding(.leading, m.status == .recording ? 4 : 12)
            if !m.chat.isEmpty && !askOpen {
                HubIconButton(symbol: "bubble.left.and.text.bubble.right", size: 13, color: VF.muted, help: "Bisherige Fragen") {
                    withAnimation(.easeOut(duration: 0.15)) { askOpen = true }
                }
            }
            Button {
                controller.whatDidIMiss(meetingID: m.id)
                withAnimation(.easeOut(duration: 0.18)) { askOpen = true }
            } label: {
                Text("Was hab ich verpasst?")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(VF.ink)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(VF.cardSoft, in: Capsule())
                    .overlay(Capsule().stroke(VF.hairline))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(m.segments.isEmpty)
        }
        .padding(.leading, 10).padding(.trailing, 10)
        .frame(height: 52)
        .background(VF.card, in: Capsule())
        .overlay(Capsule().stroke(VF.hairline))
        .shadow(color: .black.opacity(0.09), radius: 16, y: 5)
    }

    private func send(_ m: Meeting) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        controller.ask(meetingID: m.id, question: q)
        question = ""
        withAnimation(.easeOut(duration: 0.18)) { askOpen = true }
    }

    private func exportMarkdown(_ m: Meeting) {
        let p = NSSavePanel()
        p.nameFieldStringValue = m.title.replacingOccurrences(of: "/", with: "-") + ".md"
        p.allowedContentTypes = [.init(filenameExtension: "md")!]
        var md = m.markdown()
        let notes = HubNotesStore.load(m.id).trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { md += "\n## Meine Notizen\n\n\(notes)\n" }
        if p.runModal() == .OK, let u = p.url { try? md.write(to: u, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Sprecher: Farben, Chips, Umbenennen

enum HubSpeaker {
    static let palette: [Color] = [
        VF.purple,
        Color(red: 0.55, green: 0.13, blue: 0.22),   // Weinrot
        VF.teal1,
        Color(red: 0.72, green: 0.40, blue: 0.08),
        Color(red: 0.14, green: 0.38, blue: 0.72),
        Color(red: 0.42, green: 0.45, blue: 0.10),
    ]

    static func color(_ key: String, in m: Meeting) -> Color {
        if key == "me" { return VF.ink }
        let others = m.speakerKeys.filter { $0 != "me" }
        return palette[(others.firstIndex(of: key) ?? 0) % palette.count]
    }

    static func initial(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Sprecher "), let n = t.split(separator: " ").last { return String(n.prefix(2)) }
        return String(t.prefix(1)).uppercased()
    }
}

struct HubSpeakerChip: View {
    let meeting: Meeting
    let key: String
    @State private var open = false
    @State private var name = ""
    @State private var remember = true

    var body: some View {
        let c = HubSpeaker.color(key, in: meeting)
        Button { name = meeting.speakerNames[key] ?? ""; remember = true; open = true } label: {
            HStack(spacing: 6) {
                Circle().fill(c).frame(width: 7, height: 7)
                Text(meeting.name(for: key)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(c)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(c.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Klicken zum Umbenennen")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wer ist das?").font(.system(size: 14, weight: .semibold))
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 230).onSubmit(commit)
                if meeting.speakerEmbeddings[key] != nil {
                    Toggle("Stimme merken – in künftigen Meetings automatisch erkennen", isOn: $remember)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true).frame(width: 230, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Abbrechen") { open = false }
                    Button("Sichern", action: commit).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .environment(\.colorScheme, .light)
        }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { AppDelegate.shared.meeting.rename(meetingID: meeting.id, speaker: key, to: n, remember: remember) }
        open = false
    }
}

struct HubRecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color(red: 0.86, green: 0.2, blue: 0.16)).frame(width: 7, height: 7)
            .opacity(on ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
    }
}

// MARK: - Reiter „Transkript“: Name + Zeit, darunter weiche Sprechblasen, Avatar mit Initiale

struct HubNoteTranscript: View {
    let meeting: Meeting

    private struct Turn: Identifiable {
        let id: UUID
        let speaker: String
        let start: Double
        let lines: [Segment]
    }

    private var turns: [Turn] {
        var out: [Turn] = []
        for s in meeting.segments {
            if let last = out.last, last.speaker == s.speaker {
                out[out.count - 1] = Turn(id: last.id, speaker: last.speaker, start: last.start, lines: last.lines + [s])
            } else {
                out.append(Turn(id: s.id, speaker: s.speaker, start: s.start, lines: [s]))
            }
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if meeting.segments.isEmpty {
                        HStack(spacing: 10) {
                            if meeting.status == .recording { HubRecordingDot() }
                            Text(meeting.status == .recording ? "Hört zu … die Mitschrift erscheint hier live." : "Kein Text erkannt.")
                                .font(HubFont.body).foregroundStyle(VF.muted)
                        }
                        .padding(.top, 8)
                    }
                    ForEach(turns) { t in turn(t).id(t.id) }
                    Color.clear.frame(height: 1).id("ende")
                }
                .padding(.top, 30).padding(.bottom, 130)
                .frame(maxWidth: HubNoteDetail.column, alignment: .leading)
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity)
            }
            .onAppear { if meeting.status == .recording { proxy.scrollTo("ende", anchor: .bottom) } }
            .onChange(of: meeting.segments.count) {
                if meeting.status == .recording { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("ende", anchor: .bottom) } }
            }
        }
    }

    private func turn(_ t: Turn) -> some View {
        let name = meeting.name(for: t.speaker)
        let c = HubSpeaker.color(t.speaker, in: meeting)
        return HStack(alignment: .top, spacing: 14) {
            Text(HubSpeaker.initial(name))
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(c)
                .frame(width: 32, height: 32)
                .background(c.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.system(size: 15, weight: .medium)).foregroundStyle(c)
                    Text(Meeting.stamp(t.start)).font(.system(size: 12).monospacedDigit()).foregroundStyle(VF.muted.opacity(0.8))
                }
                .padding(.top, 6)
                ForEach(t.lines) { s in
                    HStack(spacing: 0) {
                        Text(s.text)
                            .font(.system(size: 15)).foregroundStyle(VF.ink)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 15).padding(.vertical, 10)
                            .background(MCMomentMarks.marked(meeting.id, s) ? MCMomentMarks.tint.opacity(0.13) : VF.cardSoft,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if MCMomentMarks.marked(meeting.id, s) { Text("★").font(.system(size: 11, weight: .bold)).foregroundStyle(MCMomentMarks.tint).offset(x: 6, y: -6) }
                            }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Reiter „✦ Zusammenfassung“

struct HubNoteSummary: View {
    let meeting: Meeting
    @State private var searching = false
    @State private var query = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, 26).padding(.bottom, 130)
            .frame(maxWidth: HubNoteDetail.column, alignment: .leading)
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var content: some View {
        if let s = meeting.summary, !s.isEmpty {
            readBar(s).padding(.bottom, 24)
            HubMarkdownView(text: s, size: 15, highlight: searching ? query : "")
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
            if meeting.status == .processing, let note = meeting.progressNote {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(note).font(HubFont.small).foregroundStyle(VF.muted) }
                    .padding(.top, 20)
            }
        } else {
            empty
        }
    }

    private func readBar(_ s: String) -> some View {
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        let minutes = max(1, Int((Double(words) / 200).rounded(.up)))
        return HStack(spacing: 10) {
            Image(systemName: "lightbulb").font(.system(size: 13)).foregroundStyle(VF.muted)
            if searching {
                TextField("In der Zusammenfassung suchen …", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13.5))
            } else {
                Text("\(minutes) MIN. LESEZEIT").font(.system(size: 12, weight: .medium)).tracking(1.2).foregroundStyle(VF.ink)
            }
            Spacer()
            HubIconButton(symbol: searching ? "xmark" : "magnifyingglass", size: 13, color: VF.muted, help: searching ? "Suche schließen" : "Suchen") {
                searching.toggle(); if !searching { query = "" }
            }
            HubIconButton(symbol: copied ? "checkmark" : "doc.on.doc", size: 13, color: VF.muted, help: "Zusammenfassung kopieren") {
                Inserter.copy(s, source: "Meeting")
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            }
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .frame(height: 42)
        .background(VF.cardSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 14) {
            HubIllustration(name: "illu_leer", fallback: "sparkles", size: 130)
            switch meeting.status {
            case .recording:
                Text("Die Zusammenfassung kommt nach dem Meeting").font(.system(size: 17, weight: .medium)).foregroundStyle(VF.ink)
                Text("Frag unten „Was hab ich verpasst?“, wenn du kurz weg warst.").font(HubFont.small).foregroundStyle(VF.muted)
            case .processing:
                Text("Wird ausgewertet …").font(.system(size: 17, weight: .medium)).foregroundStyle(VF.ink)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(meeting.progressNote ?? "Einen Moment").font(HubFont.small).foregroundStyle(VF.muted)
                }
            case .failed:
                Text("Auswertung fehlgeschlagen").font(.system(size: 17, weight: .medium)).foregroundStyle(VF.ink)
                Text(meeting.progressNote ?? "").font(HubFont.small).foregroundStyle(VF.muted)
                Button("Neu auswerten") { AppDelegate.shared.meeting.reprocess(meetingID: meeting.id) }.buttonStyle(HubBlackButton())
            case .done:
                Text("Noch keine Zusammenfassung").font(.system(size: 17, weight: .medium)).foregroundStyle(VF.ink)
                Text("Claude liest das Transkript und schreibt Kurzfassung, Entscheidungen und Aufgaben.")
                    .font(HubFont.small).foregroundStyle(VF.muted)
                Button("Jetzt zusammenfassen") { AppDelegate.shared.meeting.summarize(meetingID: meeting.id) }
                    .buttonStyle(HubBlackButton())
                    .disabled(meeting.segments.isEmpty)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
}

// MARK: - Reiter „Meine Notizen“ (freier Text, speichert automatisch)

enum HubNotesStore {
    static let dir: URL = Paths.base.appendingPathComponent("notizen")

    static func url(_ id: String) -> URL {
        dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".txt")
    }

    static func load(_ id: String) -> String { (try? String(contentsOf: url(id), encoding: .utf8)) ?? "" }

    static func save(_ id: String, _ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let u = url(id)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fm.removeItem(at: u)
            return
        }
        try? text.write(to: u, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    static func delete(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }

    /// Notizen zu Meetings, die es nicht mehr gibt, entfernen (gleiche Frist wie die Transkripte)
    static func cleanup(keeping ids: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "txt" && !ids.contains(f.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

struct HubNoteThoughts: View {
    let meetingID: String
    @State private var text = ""
    @State private var loaded = false
    @State private var pending: DispatchWorkItem?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Deine Gedanken zum Meeting – Ideen, To-dos, was dir wichtig war …")
                        .font(.system(size: 15)).foregroundStyle(VF.muted.opacity(0.7))
                        .padding(.top, 1).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .foregroundStyle(VF.ink)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
            }
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10))
                Text(saved ? "Gespeichert · nur auf diesem Mac" : "Speichert automatisch · nur auf diesem Mac")
            }
            .font(.system(size: 11.5)).foregroundStyle(VF.muted.opacity(0.8))
            .padding(.top, 8)
        }
        .padding(.top, 26).padding(.bottom, 100)
        .frame(maxWidth: HubNoteDetail.column, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            text = HubNotesStore.load(meetingID)
            DispatchQueue.main.async { loaded = true }
        }
        .onChange(of: text) {
            guard loaded else { return }
            saved = false
            pending?.cancel()
            let id = meetingID, t = text
            let w = DispatchWorkItem { HubNotesStore.save(id, t); saved = true }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        .onDisappear {
            if loaded { pending?.cancel(); HubNotesStore.save(meetingID, text) }
        }
    }
}

// MARK: - Kleiner Markdown-Renderer (Überschriften, **fett**-Zeilen, Aufzählungen, Nummern, fett/kursiv; Links NICHT klickbar)

struct HubMarkdownView: View {
    let text: String
    var size: CGFloat = 15
    var highlight: String = ""

    enum Block {
        case heading(String, level: Int)
        case bullet(String, level: Int)
        case numbered(String, String, level: Int)
        case paragraph(String)
        case gap
    }

    static func parse(_ s: String) -> [Block] {
        var out: [Block] = []
        for raw in s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = (line.prefix { $0 == " " }.count) / 2
            if trimmed.isEmpty {
                if let last = out.last, case .gap = last {} else if !out.isEmpty { out.append(.gap) }
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let t = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                out.append(.heading(t, level: min(level, 3)))
                continue
            }
            if trimmed == "---" || trimmed == "***" { out.append(.gap); continue }
            if let r = trimmed.range(of: #"^[-*•–]\s+"#, options: .regularExpression) {
                out.append(.bullet(String(trimmed[r.upperBound...]), level: indent))
                continue
            }
            if let r = trimmed.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                let num = trimmed[..<r.upperBound].trimmingCharacters(in: .whitespaces)
                out.append(.numbered(num, String(trimmed[r.upperBound...]), level: indent))
                continue
            }
            // Zeile nur aus **Fett** (optional mit „:“) → Abschnitts-Überschrift
            if let r = trimmed.range(of: #"^\*\*[^*]+\*\*:?$"#, options: .regularExpression), r.lowerBound == trimmed.startIndex {
                let t = trimmed.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                out.append(.heading(t, level: 3))
                continue
            }
            if case .paragraph(let p)? = out.last {
                out[out.count - 1] = .paragraph(p + "\n" + trimmed)
            } else {
                out.append(.paragraph(trimmed))
            }
        }
        while let last = out.last, case .gap = last { out.removeLast() }
        return out
    }

    func inline(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in a.runs where run.link != nil { a[run.range].link = nil }
        let q = highlight.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].backgroundColor = Color(red: 1.0, green: 0.87, blue: 0.45)
                from = r.upperBound
            }
        }
        return a
    }

    var body: some View {
        let blocks = HubMarkdownView.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { i in
                block(blocks[i], first: i == 0, prev: i > 0 ? blocks[i - 1] : nil)
            }
        }
    }

    @ViewBuilder private func block(_ b: Block, first: Bool, prev: Block?) -> some View {
        switch b {
        case .heading(let t, let level):
            Text(inline(t))
                .font(.system(size: level == 1 ? size + 5 : (level == 2 ? size + 2 : size), weight: .semibold))
                .foregroundStyle(VF.ink)
                .padding(.top, first ? 0 : (isGap(prev) ? 4 : 14))
                .padding(.bottom, 6)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let t, let level):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(level > 0 ? "◦" : "•").font(.system(size: size)).foregroundStyle(VF.muted)
                Text(inline(t)).font(.system(size: size)).foregroundStyle(VF.ink).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 6 + CGFloat(level) * 18)
            .padding(.vertical, 3)
        case .numbered(let n, let t, let level):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n).font(.system(size: size).monospacedDigit()).foregroundStyle(VF.muted).frame(minWidth: 18, alignment: .trailing)
                Text(inline(t)).font(.system(size: size)).foregroundStyle(VF.ink).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 18)
            .padding(.vertical, 3)
        case .paragraph(let t):
            Text(inline(t)).font(.system(size: size)).foregroundStyle(VF.ink).lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        case .gap:
            Color.clear.frame(height: 12)
        }
    }

    private func isGap(_ b: Block?) -> Bool { if case .gap? = b { return true } else { return false } }
}
