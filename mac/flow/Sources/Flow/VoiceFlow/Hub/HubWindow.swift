import AppKit
import Quartz
import SwiftUI

// MARK: - Flow Hub: Fenster, Navigation, Seitenleiste, Einstellungs-Modal (1:1 nach Flow)

enum VFSection: String, CaseIterable, Identifiable {
    case diktat, notetaker, insights, gelernt, training, woerterbuch, snippets, stil, transforms, scratchpad, einstellungen, hilfe
    var id: String { rawValue }

    var title: String {
        switch self {
        case .diktat: return "Diktat"
        case .notetaker: return "Notetaker"
        case .insights: return "Insights"
        case .gelernt: return "Gelernt"
        case .training: return "Training"
        case .woerterbuch: return "Wörterbuch"
        case .snippets: return "Snippets"
        case .stil: return "Stil"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        case .einstellungen: return "Einstellungen"
        case .hilfe: return "Hilfe"
        }
    }

    var symbol: String {
        switch self {
        case .diktat: return "mic"
        case .notetaker: return "record.circle"
        case .insights: return "chart.bar.xaxis"
        case .gelernt: return "sparkles"
        case .training: return "waveform.badge.mic"
        case .woerterbuch: return "text.book.closed"
        case .snippets: return "scissors"
        case .stil: return "textformat.size"
        case .transforms: return "wand.and.stars"
        case .scratchpad: return "note.text"
        case .einstellungen: return "gearshape"
        case .hilfe: return "questionmark.circle"
        }
    }

    /// Seiten in der Hauptnavigation (oben)
    static let navigation: [VFSection] = [.diktat, .notetaker, .insights, .gelernt, .training, .woerterbuch, .snippets, .stil, .transforms, .scratchpad]
}

/// Zustand des Hubs. Andere Seiten bekommen über `pageProvider` ihren Platz.
final class VFHub: ObservableObject {
    static let shared = VFHub()

    /// Registrierung für Seiten anderer Bereiche (Wörterbuch, Snippets, Stil, Transforms, Scratchpad, Einstellungen).
    /// nil zurückgeben → Platzhalter. `.einstellungen` wird als Modal über dem Hub gezeigt.
    static var pageProvider: ((VFSection) -> AnyView?)?

    @Published var section: VFSection = .diktat
    /// Einstellungen als Modal
    @Published var showSettings = false
    /// Optionaler Sprung in eine Einstellungs-Unterseite (z. B. "notetaker", "stimme") – liest die Einstellungs-Seite.
    @Published var settingsTarget: String?
    @Published var sidebarVisible = true
    @Published var isFullScreen = false

    /// Zu einer Seite springen (Einstellungen → Modal)
    func go(_ s: VFSection) {
        if s == .einstellungen { openSettings() } else { withAnimation(.easeOut(duration: 0.15)) { section = s } }
    }

    func openSettings(_ target: String? = nil) {
        settingsTarget = target
        withAnimation(.easeOut(duration: 0.16)) { showSettings = true }
    }

    func closeSettings() {
        withAnimation(.easeOut(duration: 0.14)) { showSettings = false }
    }
}

// MARK: - Fenster

final class VoiceFlowWindow: NSObject, NSWindowDelegate {
    static let shared = VoiceFlowWindow()
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ section: VFSection? = nil) {
        if let section { VFHub.shared.mode = .flow; VFHub.shared.go(section) }
        if window == nil { window = makeWindow() }
        HubSetupState.shared.refresh()
        NSApp.setActivationPolicy(.regular)   // Dock-Symbol, solange der Hub offen ist
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        placeTrafficLights()
    }

    /// Ampel (Schließen/Minimieren/Zoomen) mittig in die 53 pt hohe obere Leiste setzen – auf Höhe von Glocke/Profil.
    /// (Eine NSToolbar würde das auch tun, fängt unter macOS 26 aber die Klicks auf Glocke/Profil ab.)
    private func placeTrafficLights() {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let bar = HubMetrics.topBar
        var f = container.frame
        if f.height != bar || f.minY != w.frame.height - bar {
            f.size.height = bar
            f.origin.y = w.frame.height - bar
            container.frame = f
        }
        for (i, t) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(t) else { continue }
            b.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 23, y: ((bar - b.frame.height) / 2).rounded()))
        }
    }

    func windowDidResize(_ notification: Notification) { placeTrafficLights() }

    // Quick Look (Leertaste auf einem Bild in ClipVault): das Hub-Fenster steuert das Quick-Look-Fenster
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { CVQuickLook.shared.hasItems }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { CVQuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { CVQuickLook.shared.end(panel) }
    func windowDidEndLiveResize(_ notification: Notification) { placeTrafficLights() }

    func close() { window?.performClose(nil) }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Flow"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.appearance = NSAppearance(named: .aqua)   // Hub gibt es nur hell
        w.backgroundColor = NSColor(VF.chrome)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 1000, height: 680)
        w.contentView = NSHostingView(rootView: VFHubView())
        w.delegate = self
        if !w.setFrameUsingName("VoiceFlowHub") { w.centerOnMouseScreen() }
        w.setFrameAutosaveName("VoiceFlowHub")
        VFHub.shared.isFullScreen = w.styleMask.contains(.fullScreen)
        return w
    }

    func windowWillClose(_ notification: Notification) {
        VFHub.shared.showSettings = false
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Andere Fenster (z. B. Stimme einlernen) setzen beim Schließen .accessory – solange der Hub offen ist, Dock behalten
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        HubSetupState.shared.refresh()
        placeTrafficLights()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { VFHub.shared.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        VFHub.shared.isFullScreen = false
        placeTrafficLights()
    }
}

// MARK: - Hülle

enum HubMetrics {
    static let topBar: CGFloat = 53
    static let sidebarWidth: CGFloat = 257
    static let panelInset: CGFloat = 9
}

struct VFHubView: View {
    @ObservedObject var hub = VFHub.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        ZStack {
            VF.chrome
            VStack(spacing: 0) {
                HubTopBar()
                    .frame(height: HubMetrics.topBar)
                HStack(spacing: 0) {
                    if hub.sidebarVisible {
                        CVModeSidebar { HubSidebar() }
                            .frame(width: HubMetrics.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    panel
                        .padding(.leading, hub.sidebarVisible ? 0 : HubMetrics.panelInset)
                        .padding(.trailing, HubMetrics.panelInset)
                        .padding(.bottom, HubMetrics.panelInset)
                }
            }
            if hub.showSettings {
                HubSettingsModal()
                    .transition(.opacity)
                    .zIndex(10)
            }
            // Erster Start (keine settings.json): Willkommen über allem
            if OnboardingState.shouldShow(settings) {
                OnboardingOverlay()
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .ignoresSafeArea()
        .audioImportDropTarget()   // Audio-/Videodatei aufs Fenster ziehen → transkribieren
        .environment(\.colorScheme, .light)
        .frame(minWidth: 1000, minHeight: 680)
    }

    private var panel: some View {
        ZStack {
            VF.panel
            CVModePanel { page(hub.section).id(hub.section) }
        }
        .clipShape(RoundedRectangle(cornerRadius: VF.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VF.panelRadius, style: .continuous).stroke(VF.hairline.opacity(0.9), lineWidth: 1))
    }

    @ViewBuilder private func page(_ s: VFSection) -> some View {
        switch s {
        case .diktat: HubDiktatPage()
        case .notetaker: HubNotetakerPage()
        case .insights: HubInsightsPage()
        case .training: VFTrainingPage()
        case .hilfe: HubHilfePage()
        default:
            if let v = VFHub.pageProvider?(s) { v } else { HubPlaceholderPage(section: s) }
        }
    }
}

// MARK: - Obere Leiste (Seitenleiste ein/aus · Glocke · Profil)

struct HubTopBar: View {
    @ObservedObject var hub = VFHub.shared
    @ObservedObject var settings = Settings.shared
    @State private var showBell = false
    @State private var showProfile = false

    var body: some View {
        HStack(spacing: 10) {
            HubIconButton(symbol: "sidebar.left", size: 16, help: hub.sidebarVisible ? "Seitenleiste ausblenden" : "Seitenleiste einblenden") {
                withAnimation(.easeInOut(duration: 0.2)) { hub.sidebarVisible.toggle() }
            }
            Spacer()
            HubIconButton(symbol: "bell", size: 16, help: "Mitteilungen") { showBell.toggle() }
                .popover(isPresented: $showBell, arrowEdge: .bottom) {
                    VStack(spacing: 8) {
                        Image(systemName: "bell.slash").font(.system(size: 22, weight: .light)).foregroundStyle(VF.muted)
                        Text("Keine neuen Mitteilungen").font(.system(size: 13, weight: .medium)).foregroundStyle(VF.ink)
                    }
                    .padding(.horizontal, 26).padding(.vertical, 18)
                    .environment(\.colorScheme, .light)
                }
            HubIconButton(symbol: "person.crop.circle", size: 17, help: "Profil") { showProfile.toggle() }
                .popover(isPresented: $showProfile, arrowEdge: .bottom) { profile }
        }
        // Ampel links frei lassen (im Vollbild gibt es keine)
        .padding(.leading, hub.isFullScreen ? 17 : 84)
        .padding(.trailing, 11)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String(Identity.myName.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(VF.purple, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(Identity.myName).font(.system(size: 14, weight: .semibold))
                    Text("Unbegrenzt · alles lokal").font(.system(size: 12)).foregroundStyle(VF.muted)
                }
            }
            Divider()
            Button { showProfile = false; hub.openSettings() } label: {
                Label("Einstellungen", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { showProfile = false; hub.go(.hilfe) } label: {
                Label("Hilfe", systemImage: "questionmark.circle").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(16).frame(width: 230)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Seitenleiste

struct HubSidebar: View {
    @ObservedObject var hub = VFHub.shared
    @ObservedObject var setup = HubSetupState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CVAppSwitcher()
                .padding(.leading, 8).padding(.top, 14)
                .frame(height: 38, alignment: .leading)
            VStack(spacing: 4) {
                ForEach(VFSection.navigation) { s in
                    HubNavRow(section: s, selected: hub.section == s && !hub.showSettings) { hub.go(s) }
                }
            }
            .padding(.top, 31)
            Spacer(minLength: 16)
            if !setup.complete {
                HubSetupCard()
                    .padding(.bottom, 13)
                Rectangle().fill(VF.hairline).frame(height: 1).padding(.bottom, 12)
            }
            VStack(spacing: 4) {
                HubNavRow(section: .einstellungen, selected: hub.showSettings) { hub.openSettings() }
                HubNavRow(section: .hilfe, selected: hub.section == .hilfe && !hub.showSettings) { hub.go(.hilfe) }
            }
            .padding(.bottom, 13)
        }
        .padding(.leading, 12).padding(.trailing, 14)
        .frame(maxHeight: .infinity)
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in setup.refresh() }
    }

    @ViewBuilder private var logo: some View {
        if let img = HubSidebar.trimmedLogo {
            // Auf den sichtbaren Inhalt zugeschnitten → gleiche Größe/Position, egal wie viel Rand das Bild hat
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 23)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "waveform").font(.system(size: 20, weight: .bold))
                Text("Flow").font(.system(size: 21, weight: .semibold)).tracking(-0.3)
            }
            .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.23))
        }
    }
}

extension HubSidebar {
    /// logo_wordmark ohne transparenten Rand (einmal berechnet)
    static let trimmedLogo: NSImage? = {
        guard let img = VFAsset.image("logo_wordmark"),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // In einen eigenen RGBA-Puffer zeichnen und den Alphakanal durchsuchen (schnell, unabhängig vom Bildformat)
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where buf[row + x * 4 + 3] > 12 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        // Puffer-Zeile 0 = oben (CGContext mit Daten ist hier top-down wie das Bild)
        guard maxX >= minX, maxY >= minY,
              let crop = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return img }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }()
}

struct HubNavRow: View {
    let section: VFSection
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                Text(section.title).font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundStyle(VF.ink)
            .padding(.leading, 8).padding(.trailing, 10)
            .frame(height: 36)
            .background(selected ? VF.selected : (hover ? VF.selected.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Einrichtungs-Karte („Flow einrichten“)

final class HubSetupState: ObservableObject {
    static let shared = HubSetupState()
    @Published private(set) var voice = false
    @Published private(set) var dictation = false
    @Published private(set) var meeting = false
    @Published private(set) var word = false
    @Published private(set) var snippet = false

    static let snippetsURL = Paths.base.appendingPathComponent("snippets.json")

    private init() { refresh() }

    var done: Int { [voice, dictation, meeting, word, snippet].filter { $0 }.count }
    var complete: Bool { done == 5 }

    func refresh() {
        let v = VoiceID.isEnrolled || VoiceTrainer.shared.levelsDone > 0
        let d = !DictationHistory.shared.records.isEmpty || VFStats.shared.totalDictations > 0
        let m = !MeetingStore.shared.meetings.isEmpty
        // gelernt ✨ oder selbst eingetragen (die mitgelieferten Start-Einträge zählen nicht)
        let starter = Set(Settings.defaultDictionary.map { $0.heard.lowercased() })
        let w = Settings.shared.dictionary.contains { $0.learned == true || !starter.contains($0.heard.lowercased()) }
        let s = HubSetupState.snippetsExist()
        if v != voice { voice = v }
        if d != dictation { dictation = d }
        if m != meeting { meeting = m }
        if w != word { word = w }
        if s != snippet { snippet = s }
    }

    /// snippets.json enthält ein selbst angelegtes Snippet (der mitgelieferte Startbestand zählt nicht)
    static func snippetsExist() -> Bool {
        guard let data = try? Data(contentsOf: snippetsURL), !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) else { return false }
        let seeded = Set(SnippetStore.seed.map { $0.trigger.lowercased() })
        if let a = obj as? [Any] {
            return a.contains { e in
                guard let d = e as? [String: Any], let t = d["trigger"] as? String else { return true }
                return !seeded.contains(t.lowercased())
            }
        }
        if let d = obj as? [String: Any] {
            if d.isEmpty { return false }
            let arrays = d.values.compactMap { $0 as? [Any] }
            return arrays.isEmpty ? true : arrays.contains { !$0.isEmpty }
        }
        return false
    }
}

struct HubSetupCard: View {
    @ObservedObject var setup = HubSetupState.shared
    @ObservedObject var hub = VFHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Flow einrichten")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(VF.ink)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0.93, green: 0.92, blue: 0.90))
                    Capsule().fill(VF.teal1).frame(width: max(6, g.size.width * CGFloat(setup.done) / 5))
                }
            }
            .frame(height: 5)
            .padding(.top, 10).padding(.bottom, 10)
            item("Stimme einlernen", setup.voice) { VoiceFlowWindow.shared.show(.training) }
            item("Erstes Diktat", setup.dictation) { hub.go(.hilfe) }
            item("Meeting ausprobieren", setup.meeting) { hub.go(.notetaker) }
            item("Wort ins Wörterbuch", setup.word) { hub.go(.woerterbuch) }
            item("Snippet anlegen", setup.snippet) { hub.go(.snippets) }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard(VF.card, radius: 12)
    }

    private func item(_ title: String, _ done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if done {
                        Circle().fill(VF.teal4)
                        Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(VF.teal1)
                    } else {
                        Circle().stroke(VF.muted.opacity(0.75), lineWidth: 1.4)
                    }
                }
                .frame(width: 18, height: 18)
                Text(title).font(.system(size: 11.5))
                    .foregroundStyle(done ? VF.muted : VF.ink)
                Spacer(minLength: 0)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
    }
}

// MARK: - Einstellungen als Modal

struct HubSettingsModal: View {
    @ObservedObject var hub = VFHub.shared

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black.opacity(0.24)
                    .contentShape(Rectangle())
                    .onTapGesture { hub.closeSettings() }
                content
                    .frame(width: min(961, g.size.width - 80), height: min(643, g.size.height - 80))
                    .background(VF.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                // Esc schließt
                Button("") { hub.closeSettings() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let v = VFHub.pageProvider?(.einstellungen) {
            v
        } else {
            VStack(spacing: 14) {
                HubIllustration(name: "illu_leer", fallback: "gearshape", size: 110)
                Text("Einstellungen").font(VF.serif(34)).foregroundStyle(VF.ink)
                Text("Die neuen Einstellungen werden gerade eingebaut.").font(HubFont.body).foregroundStyle(VF.muted)
                Button("Schließen") { hub.closeSettings() }.buttonStyle(HubSoftButton())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Platzhalter für Seiten anderer Bereiche

struct HubPlaceholderPage: View {
    let section: VFSection
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title).font(HubFont.title).foregroundStyle(VF.ink)
            Spacer()
            VStack(spacing: 14) {
                HubIllustration(name: "illu_leer", fallback: section.symbol, size: 120)
                Text("\(section.title) kommt gleich").font(VF.serif(30)).foregroundStyle(VF.ink)
                Text("Diese Seite wird gerade gebaut.").font(HubFont.body).foregroundStyle(VF.muted)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .hubPage()
    }
}
