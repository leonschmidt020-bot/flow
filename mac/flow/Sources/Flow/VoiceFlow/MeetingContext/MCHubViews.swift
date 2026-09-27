import AppKit
import SwiftUI

// MARK: - Reiter „Bilder“ im Notiz-Detail (Stil wie HubNoteDetail): Zeitleiste aus Schlüsselbildern mit
// Zeitstempel, erkanntem Text und dem Gesprochenen drumherum; Klick = Großansicht; „Im Finder zeigen“.

struct HubNoteFrames: View {
    let meeting: Meeting
    @ObservedObject private var store = MCStore.shared
    @ObservedObject private var ctx = MeetingContext.shared
    @State private var query = ""
    @State private var open: String?

    /// Nur für Render/Tests: Großansicht offen
    static var renderOpenFrame: String?

    init(meeting: Meeting) {
        self.meeting = meeting
        _open = State(initialValue: HubNoteFrames.renderOpenFrame)
    }

    private var mc: MCLog { _ = store.revision; return store.log(meeting.id) }
    private var live: Bool { meeting.status == .recording && ctx.meetingID == meeting.id }

    private var shown: [MCFrame] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = mc.frames
        guard !q.isEmpty else { return all }
        return all.enumerated().filter { i, f in
            let (a, b) = MCText.visibleRange(all, i, meetingEnd: meeting.duration)
            return (f.ocr ?? "").localizedCaseInsensitiveContains(q) || (f.window ?? "").localizedCaseInsensitiveContains(q)
                || MCText.spoken(meeting, from: a, to: b, maxChars: 5000).localizedCaseInsensitiveContains(q)
        }.map(\.1)
    }

    var body: some View {
        let log = mc
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if live { MCLiveBar(meetingID: meeting.id).padding(.bottom, 22) }
                    if !log.frames.isEmpty { toolbar(log).padding(.bottom, 22) }
                    if log.frames.isEmpty && log.moments.isEmpty {
                        empty
                    } else {
                        let momentsOnly = log.moments.filter { $0.frame == nil }
                        if !momentsOnly.isEmpty && query.isEmpty {
                            ForEach(momentsOnly) { mo in MCMomentRow(meeting: meeting, moment: mo).padding(.bottom, 14) }
                        }
                        let list = shown
                        if list.isEmpty && !query.isEmpty {
                            Text("Kein Bild mit „\(query)“.").font(HubFont.body).foregroundStyle(VF.muted).padding(.top, 10)
                        }
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(list) { f in
                                let i = log.frames.firstIndex(of: f) ?? 0
                                MCFrameRow(meeting: meeting, frame: f, index: i, frames: log.frames, highlight: query) {
                                    withAnimation(.easeOut(duration: 0.16)) { open = f.id }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 26).padding(.bottom, 130)
                .frame(maxWidth: HubNoteDetail.column, alignment: .leading)
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                // nach einem Absturz/Beenden mitten im Meeting: fehlenden Text nachlesen
                if meeting.status != .recording, log.frames.contains(where: { $0.ocr == nil }) { MCOCR.shared.backfill(meetingID: meeting.id) }
            }
            if let id = open, let i = log.frames.firstIndex(where: { $0.id == id }) {
                // (Großansicht über allem)
                MCLightbox(meeting: meeting, frames: log.frames, index: i, close: { withAnimation(.easeOut(duration: 0.14)) { open = nil } },
                           go: { j in open = log.frames[j].id })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
    }

    private func toolbar(_ log: MCLog) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(VF.muted)
            TextField("Text auf den Bildern oder Gesprochenes suchen …", text: $query)
                .textFieldStyle(.plain).font(.system(size: 13.5))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(VF.muted.opacity(0.7)) }.buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Text(summaryLine(log)).font(.system(size: 12, weight: .medium)).tracking(0.3).foregroundStyle(VF.muted).lineLimit(1)
            HubIconButton(symbol: "folder", size: 13, color: VF.muted, help: "Im Finder zeigen") {
                let dir = MCStore.folder(meeting.id).appendingPathComponent("bilder")
                NSWorkspace.shared.activateFileViewerSelecting([log.frames.first.map { MCStore.shared.url(meeting.id, $0) } ?? dir])
            }
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .frame(height: 42)
        .background(VF.cardSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func summaryLine(_ log: MCLog) -> String {
        var p = ["\(log.frames.count) BILD\(log.frames.count == 1 ? "" : "ER")"]
        if !log.moments.isEmpty { p.append("\(log.moments.count) ★") }
        let pending = log.frames.filter { $0.ocr == nil }.count
        if pending > 0 { p.append("TEXT WIRD GELESEN (\(pending))") }
        if log.video != nil { p.append("VIDEO") }
        return p.joined(separator: " · ")
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 14) {
            HubIllustration(name: "illu_leer", fallback: "rectangle.on.rectangle", size: 130)
            if live {
                Text(ctx.capturing ? "Noch keine Bild-Wechsel" : "Bildschirm wird nicht mitgeschnitten")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(VF.ink)
                Text(ctx.capturing ? "Sobald eine Folie oder ein geteilter Bildschirm wechselt, erscheint das Bild hier – mit erkanntem Text."
                                   : "Schalte oben „Bildschirm mitschneiden“ ein, dann sieht Flow Folien, Code und Designs.")
                    .font(HubFont.small).foregroundStyle(VF.muted)
            } else {
                Text("Keine Bilder in diesem Meeting").font(.system(size: 17, weight: .medium)).foregroundStyle(VF.ink)
                Text("Mit „Bildschirm mitschneiden“ merkt sich Flow Folien und geteilte Bildschirme – nur das Meeting-Fenster, alles bleibt auf dem Mac.")
                    .font(HubFont.small).foregroundStyle(VF.muted).frame(maxWidth: 460)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
}

// MARK: Zeile: Bild + Zeit + Text + Gesprochenes

struct MCFrameRow: View {
    let meeting: Meeting
    let frame: MCFrame
    let index: Int
    let frames: [MCFrame]
    var highlight = ""
    let openAction: () -> Void
    @State private var hover = false

    var body: some View {
        let (a, b) = MCText.visibleRange(frames, index, meetingEnd: max(meeting.duration, frame.tLast + 30))
        let said = MCText.spoken(meeting, from: a, to: b, maxChars: 420)
        let ocr = (frame.ocr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .top, spacing: 20) {
            Button(action: openAction) {
                MCThumbView(url: MCStore.shared.url(meeting.id, frame), maxPixel: 640)
                    .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
                    .frame(width: 286)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(VF.hairline))
                    .overlay(alignment: .topLeading) {
                        if frame.isMoment {
                            Text("★ Moment").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).frame(height: 20)
                                .background(Color(red: 0.86, green: 0.52, blue: 0.10), in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(.black.opacity(0.55), in: Circle())
                            .padding(8).opacity(hover ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(hover ? 0.10 : 0.04), radius: hover ? 10 : 4, y: 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Groß ansehen")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Meeting.stamp(frame.t)).font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(VF.ink)
                    if frame.tLast - frame.t > 20 {
                        Text("bis \(Meeting.stamp(frame.tLast))").font(.system(size: 12).monospacedDigit()).foregroundStyle(VF.muted.opacity(0.8))
                    }
                    if let w = frame.window {
                        Text(w).font(.system(size: 12)).foregroundStyle(VF.muted.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    menu(ocr)
                }
                if frame.ocr == nil {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Text wird gelesen …") }
                        .font(.system(size: 12.5)).foregroundStyle(VF.muted)
                } else if !ocr.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HubLabel("Auf dem Bild")
                        Text(MCHighlight.attr(ocr, highlight))
                            .font(.system(size: 13)).foregroundStyle(VF.ink).lineSpacing(3)
                            .lineLimit(5).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !said.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HubLabel("Gesprochen")
                        Text(MCHighlight.attr(said, highlight))
                            .font(.system(size: 13.5)).foregroundStyle(VF.muted).lineSpacing(3)
                            .lineLimit(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(VF.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(frame.isMoment ? Color(red: 0.86, green: 0.52, blue: 0.10).opacity(0.55) : VF.hairline))
    }

    private func menu(_ ocr: String) -> some View {
        Menu {
            Button("Groß ansehen", action: openAction)
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([MCStore.shared.url(meeting.id, frame)]) }
            Button("Text kopieren") { Inserter.copy(ocr, source: "Meeting") }.disabled(ocr.isEmpty)
            Button("Bild kopieren") { MCPasteboard.copyImage(MCStore.shared.url(meeting.id, frame)) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(VF.muted)
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// Gemerkter Moment ohne Bild (Bildschirm war aus)
struct MCMomentRow: View {
    let meeting: Meeting
    let moment: MCMoment
    var body: some View {
        let said = MCText.spoken(meeting, from: moment.t - 30, to: moment.t + 3, maxChars: 600)
        HStack(alignment: .top, spacing: 14) {
            Text("★").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(red: 0.86, green: 0.52, blue: 0.10))
                .frame(width: 32, height: 32).background(Color(red: 0.86, green: 0.52, blue: 0.10).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text("Moment · \(Meeting.stamp(moment.t))").font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                Text(said.isEmpty ? (moment.liveText.isEmpty ? "(noch kein Text)" : moment.liveText) : said)
                    .font(.system(size: 13.5)).foregroundStyle(VF.muted).lineSpacing(3).lineLimit(5).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(VF.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(red: 0.86, green: 0.52, blue: 0.10).opacity(0.55)))
    }
}

// MARK: Leiste während der Aufnahme: Schalter, Fenster wählen, Moment merken

struct MCLiveBar: View {
    let meetingID: String
    @ObservedObject private var ctx = MeetingContext.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ctx.capturing ? "video.fill" : "video.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ctx.capturing ? Color(red: 0.78, green: 0.16, blue: 0.13) : VF.muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bildschirm mitschneiden").font(.system(size: 14, weight: .medium)).foregroundStyle(VF.ink)
                Text(ctx.status.isEmpty ? "Nur das Meeting-Fenster · bleibt auf dem Mac" : ctx.status)
                    .font(.system(size: 12)).foregroundStyle(VF.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if ctx.permissionMissing {
                Button("Freigeben") { MeetingContext.requestPermission() }.buttonStyle(HubBlackButton(height: 28))
            }
            windowMenu
            Button { ctx.markMoment() } label: {
                HStack(spacing: 6) {
                    Text("★").font(.system(size: 12.5, weight: .semibold))
                    Text("Moment merken").font(.system(size: 12.5, weight: .medium))
                    Text("⌃⌥S").font(.system(size: 11, weight: .medium)).foregroundStyle(VF.muted)
                }
                .foregroundStyle(VF.ink)
                .padding(.horizontal, 12).frame(height: 28)
                .background(VF.card, in: Capsule()).overlay(Capsule().stroke(VF.hairline))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Bildschirmfoto + die letzten 30 s als wichtig markieren")
            Toggle("", isOn: Binding(get: { ctx.enabled }, set: { ctx.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden().tint(VF.black).controlSize(.small)
                .help("Bildschirm mitschneiden an/aus (pausiert sofort)")
        }
        .padding(.horizontal, 14).frame(height: 54)
        .background(VF.cardSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var windowMenu: some View {
        Menu {
            let meet = ctx.candidates.filter(\.matchesMeetingApp)
            let other = ctx.candidates.filter { !$0.matchesMeetingApp }
            if !meet.isEmpty {
                Section("Meeting-App") { ForEach(meet) { c in Button(c.label) { ctx.choose(windowID: c.id) } } }
            }
            if !other.isEmpty {
                Section("Anderes Fenster (nur auf Wunsch)") { ForEach(other.prefix(15)) { c in Button(c.label) { ctx.choose(windowID: c.id) } } }
            }
            if ctx.candidates.isEmpty { Text("Keine Fenster gefunden") }
        } label: {
            Text("Fenster").font(.system(size: 12.5, weight: .medium)).foregroundStyle(VF.ink)
                .padding(.horizontal, 12).frame(height: 28)
                .background(VF.card, in: Capsule()).overlay(Capsule().stroke(VF.hairline))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Welches Fenster mitgeschnitten wird")
    }
}

// MARK: Großansicht

struct MCLightbox: View {
    let meeting: Meeting
    let frames: [MCFrame]
    let index: Int
    let close: () -> Void
    let go: (Int) -> Void
    @State private var showText = true

    var body: some View {
        let f = frames[index]
        let ocr = (f.ocr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ZStack {
            Color.black.opacity(0.86).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Text(Meeting.stamp(f.t)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    if f.isMoment { Text("★ Moment").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.72, blue: 0.3)) }
                    Text("Bild \(index + 1) von \(frames.count)").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                    if let w = f.window { Text(w).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                    Spacer()
                    lbButton("doc.on.doc", "Text kopieren") { Inserter.copy(ocr, source: "Meeting") }.disabled(ocr.isEmpty)
                    lbButton("photo.on.rectangle", "Bild kopieren") { MCPasteboard.copyImage(MCStore.shared.url(meeting.id, f)) }
                    lbButton("folder", "Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([MCStore.shared.url(meeting.id, f)]) }
                    lbButton("text.alignleft", showText ? "Text ausblenden" : "Text zeigen") { showText.toggle() }
                    lbButton("xmark", "Schließen (esc)", action: close)
                }
                .foregroundStyle(.white)
                HStack(spacing: 14) {
                    arrow("chevron.left", enabled: index > 0) { go(index - 1) }
                    MCThumbView(url: MCStore.shared.url(meeting.id, f), maxPixel: 2400, placeholder: Color.white.opacity(0.06))
                        .aspectRatio(CGFloat(f.width) / CGFloat(max(f.height, 1)), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    arrow("chevron.right", enabled: index < frames.count - 1) { go(index + 1) }
                }
                if showText && !ocr.isEmpty {
                    ScrollView {
                        Text(ocr).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88)).lineSpacing(3)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 24).padding(.top, 24)
            .padding(.bottom, 96)   // Platz für die schwebende Frage-Leiste
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { if index > 0 { go(index - 1) }; return .handled }
        .onKeyPress(.rightArrow) { if index < frames.count - 1 { go(index + 1) }; return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func lbButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30).background(Color.white.opacity(0.12), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(Color.white.opacity(enabled ? 0.14 : 0.04), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}

// MARK: Bild laden (verkleinert, im Hintergrund, mit Zwischenspeicher)

final class MCThumbCache {
    static let shared = MCThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private let q = DispatchQueue(label: "flow.meetingkontext.thumbs", qos: .userInitiated, attributes: .concurrent)
    init() { cache.countLimit = 120 }

    func cached(_ url: URL, _ px: Int) -> NSImage? {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        return cache.object(forKey: "\(px)|\(mod)|\(url.path)" as NSString)
    }

    func load(_ url: URL, _ px: Int, done: @escaping (NSImage?) -> Void) {
        q.async {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
            let key = "\(px)|\(mod)|\(url.path)" as NSString
            var img = self.cache.object(forKey: key)
            if img == nil, let cg = MCImageIO.thumbnail(url, maxPixel: px) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.cache.setObject(img!, forKey: key)
            }
            DispatchQueue.main.async { done(img) }
        }
    }
}

struct MCThumbView: View {
    let url: URL
    var maxPixel = 640
    var placeholder: Color = VF.cardSoft
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { placeholder }
        }
        .onAppear(perform: load)
        .onChange(of: url) { image = nil; load() }
    }

    private func load() {
        if let c = MCThumbCache.shared.cached(url, maxPixel) { image = c; return }
        MCThumbCache.shared.load(url, maxPixel) { image = $0 }
    }
}

enum MCHighlight {
    static func attr(_ s: String, _ q: String) -> AttributedString {
        var a = AttributedString(s)
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Color(red: 1.0, green: 0.87, blue: 0.45)
            from = r.upperBound
        }
        return a
    }
}

enum MCPasteboard {
    /// Bild in die Zwischenablage (nur auf Klick des Nutzers)
    static func copyImage(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }
}

/// Transkript-Zeilen in den 30 s vor einem gemerkten Moment (⌃⌥S) – im Reiter „Transkript“ hervorgehoben
enum MCMomentMarks {
    static let tint = Color(red: 0.86, green: 0.52, blue: 0.10)
    static func marked(_ meetingID: String, _ s: Segment) -> Bool {
        MCStore.shared.log(meetingID).moments.contains { s.end >= $0.t - 30 && s.start <= $0.t }
    }
}

/// Suche in der Notetaker-Liste: erkannter Text der Bilder
enum MCSearch {
    static func matches(_ meetingID: String, _ q: String) -> Bool {
        MCStore.shared.log(meetingID).frames.contains { ($0.ocr ?? "").localizedCaseInsensitiveContains(q) }
    }
}

// MARK: - Knopf „Prompt für Agent“ (Kopfzeile des Notiz-Details + Zeile in der Notizen-Liste beim Drüberfahren)
// Ein Klick: Paket neu bauen, fertigen Prompt (Meeting-Infos + absolute Pfade zu meeting.md und bilder/) kopieren,
// Pille zeigt „Prompt kopiert ✓“. Für Claude Code, Codex … – kein Menü, kein Terminal.

struct MCAgentButton: View {
    let meeting: Meeting
    /// kleine Fassung für die Listenzeile
    var compact = false
    @State private var state: Int = 0   // 0 bereit, 1 baut, 2 kopiert

    var body: some View {
        Button {
            guard state != 1 else { return }
            state = 1
            MeetingContextPackage.copyAgentPrompt(meeting) { ok in
                state = ok ? 2 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if state == 2 { state = 0 } }
            }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if state == 1 { ProgressView().controlSize(.mini).frame(width: 13, height: 13) }
                    else { Image(systemName: state == 2 ? "checkmark" : "sparkles").font(.system(size: compact ? 11.5 : 12.5, weight: .medium)) }
                }
                Text(state == 2 ? "Kopiert" : "Prompt für Agent")
            }
            .font(.system(size: compact ? 12.5 : 13.5, weight: .medium))
        }
        .buttonStyle(MCAgentButtonStyle(height: compact ? 28 : 30, outline: compact))
        .help("Kopiert einen Prompt mit den Pfaden zu Transkript (meeting.md) und Bildern – zum Einfügen in Claude Code, Codex …")
    }
}

struct MCAgentButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    var outline = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(VF.ink)
            .padding(.horizontal, outline ? 12 : 14).frame(height: height)
            .background(outline ? (configuration.isPressed ? VF.buttonSoft : VF.card) : VF.buttonSoft.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(outline ? VF.hairline : .clear))
            .contentShape(Rectangle())
    }
}

// MARK: - Einstellungen → Notetaker (Zeilen für das Einstellungs-Modal)

private struct MCSwitch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(VF.black) }
}

struct MCSettingsCaptureRow: View {
    @ObservedObject var s = MCSettings.shared
    var body: some View {
        PGSettingRow(title: "Bildschirm mitschneiden",
                     detail: "Nur das Meeting-Fenster: Folien, geteilte Bildschirme, Code. Nur Bild-Wechsel (30–80 Bilder/Std.) + erkannter Text. Bleibt auf dem Mac, niemand sonst sieht etwas.") {
            MCSwitch(isOn: $s.captureScreen)
        }
    }
}

struct MCSettingsVideoRow: View {
    @ObservedObject var s = MCSettings.shared
    var body: some View {
        PGSettingRow(title: "Zusätzlich Video (1 Bild/s)", detail: "Ruckel-Video des Meeting-Fensters, ~50 MB pro Stunde. Wird mit dem Meeting gelöscht.") {
            MCSwitch(isOn: $s.saveVideo)
        }
    }
}

struct MCSettingsSummaryRow: View {
    @ObservedObject var s = MCSettings.shared
    var body: some View {
        PGSettingRow(title: "Zusammenfassung sieht die Bilder", detail: "Claude liest bis zu 20 Schlüsselbilder mit (nur Lesen, nur dieser Ordner).") {
            MCSwitch(isOn: $s.summaryWithImages)
        }
    }
}

struct MCSettingsPermissionRow: View {
    @State private var ok = CGPreflightScreenCaptureAccess()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        PGSettingRow(title: "Freigabe „Bildschirmaufnahme“",
                     detail: ok ? "Erteilt." : "Fehlt – wird erst gefragt, wenn ein Meeting mit Bildschirm startet. Nach dem Erteilen Flow neu starten.") {
            if ok {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(VF.teal2)
            } else {
                Button("Freigeben") { MeetingContext.requestPermission() }
                    .buttonStyle(PGSoftButtonStyle(minWidth: 216, fill: Color(red: 0.925, green: 0.918, blue: 0.898)))
            }
        }
        .onReceive(refresh) { _ in ok = CGPreflightScreenCaptureAccess() }
    }
}

// MARK: - „Meeting erkannt“-Karte mit Wahl „Mit Bildschirm“ / „Nur Ton“

extension VFNotice {
    static let chipScreen = "Mit Bildschirm"
    static let chipAudio = "Nur Ton"

    static func meetingDetectedWithScreen(app: String, accept: @escaping (_ screen: Bool) -> Void, dismiss: @escaping () -> Void,
                                          anchor: NSRect? = nil) -> VFNotice {
        let on = MCSettings.shared.captureScreen
        return VFNotice(id: "meeting_erkannt", title: "Meeting erkannt",
                        text: "\(app) nutzt das Mikrofon. Soll Flow mitschreiben?",
                        illustration: "illu_meeting_erkannt", fallbackSymbol: VFNotify.symbol(for: "illu_meeting_erkannt"),
                        primary: ("Aufnehmen", { accept((VFNotify.shared.chosen ?? (on ? chipScreen : chipAudio)) == chipScreen) }),
                        secondary: ("Nicht jetzt", dismiss),
                        timeout: 20, anchor: anchor, onClose: dismiss,
                        choices: on ? [chipScreen, chipAudio] : [chipAudio, chipScreen])
    }
}
