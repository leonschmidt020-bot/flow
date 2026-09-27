import AppKit
import SwiftUI

// MARK: - App-Umschalter Flow ↔ ClipVault
// Der Hub zeigt entweder Flow (Diktat, Notetaker …) oder ClipVault (Verlauf, Bereiche, Geteilt …).
// Gleiche Hülle (Fensterrahmen, obere Leiste), aber eigene Seitenleiste + eigener Inhalt – fühlt sich an wie eine zweite App.
//
// Verdrahtung in HubWindow.swift (siehe Bericht):
//   Seitenleiste:  CVModeSidebar { HubSidebar() }
//   Inhalt:        CVModePanel { page(hub.section).id(hub.section) }
//   Logo:          in HubSidebar `logo` durch `CVAppSwitcher()` ersetzen

enum CVAppMode: String, CaseIterable, Identifiable {
    case flow, clipvault
    var id: String { rawValue }
    var title: String { self == .flow ? "Flow" : "ClipVault" }
}

enum CVSection: String, CaseIterable, Identifiable {
    case verlauf, angeheftet, bereiche, bilder, links, dateien, geteilt, einstellungen
    var id: String { rawValue }

    var title: String {
        switch self {
        case .verlauf: return "Verlauf"
        case .angeheftet: return "Angeheftet"
        case .bereiche: return "Bereiche"
        case .bilder: return "Bilder"
        case .links: return "Links"
        case .dateien: return "Dateien"
        case .geteilt: return Identity.partnerName.map { "Geteilt mit \($0)" } ?? "Geteilt"
        case .einstellungen: return "Einstellungen"
        }
    }

    var symbol: String {
        switch self {
        case .verlauf: return "clock.arrow.circlepath"
        case .angeheftet: return "pin"
        case .bereiche: return "square.stack.3d.up"
        case .bilder: return "photo"
        case .links: return "link"
        case .dateien: return "doc"
        case .geteilt: return "person.2"
        case .einstellungen: return "gearshape"
        }
    }

    static let navigation: [CVSection] = [.verlauf, .angeheftet, .bereiche, .bilder, .links, .dateien]
}

/// Zustand des ClipVault-Modus (Modus wird gespeichert, Seite auch)
final class CVHubState: ObservableObject {
    static let shared = CVHubState()
    private static let modeKey = "vf.hub.mode"
    private static let sectionKey = "vf.cv.section"

    @Published var mode: CVAppMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            VFHub.shared.objectWillChange.send()
            if mode == .clipvault { ClipVaultClient.shared.start(); CVShared.shared.start() }
        }
    }
    @Published var section: CVSection {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
    }
    /// Offener Bereich (Liste eines Bereichs statt der Bereiche-Übersicht)
    @Published var openCollection: String?
    /// Ausgewählter Eintrag (Vorschau rechts)
    @Published var selectedID: String?

    private init() {
        mode = CVAppMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .flow
        section = CVSection(rawValue: UserDefaults.standard.string(forKey: Self.sectionKey) ?? "") ?? .verlauf
        if mode == .clipvault { DispatchQueue.main.async { ClipVaultClient.shared.start(); CVShared.shared.start() } }
    }

    func switchTo(_ m: CVAppMode) {
        guard m != mode else { return }
        if VFHub.shared.showSettings { VFHub.shared.closeSettings() }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { mode = m }
    }

    func toggle() { switchTo(mode == .flow ? .clipvault : .flow) }

    func go(_ s: CVSection, collection: String? = nil) {
        withAnimation(.easeOut(duration: 0.15)) {
            section = s
            openCollection = collection
        }
    }
}

extension VFHub {
    /// Aktive „App“ im Hub (Flow oder ClipVault). Gespeichert in UserDefaults „vf.hub.mode“.
    var mode: CVAppMode {
        get { CVHubState.shared.mode }
        set { CVHubState.shared.switchTo(newValue) }
    }
}

// MARK: - Hüllen für HubWindow.swift

/// Zeigt je nach Modus die Flow-Seitenleiste (vom Aufrufer) oder die ClipVault-Seitenleiste – mit Übergang.
struct CVModeSidebar<Flow: View>: View {
    @ObservedObject var state = CVHubState.shared
    @ViewBuilder var flow: () -> Flow

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.mode == .flow {
                flow()
                    .transition(.asymmetric(insertion: .offset(x: -24).combined(with: .opacity), removal: .opacity))
            } else {
                CVSidebar()
                    .transition(.asymmetric(insertion: .offset(x: 24).combined(with: .opacity), removal: .opacity))
            }
        }
        .clipped()
    }
}

/// Inhaltsfläche: Flow-Seite (vom Aufrufer) oder ClipVault-Seite.
struct CVModePanel<Flow: View>: View {
    @ObservedObject var state = CVHubState.shared
    @ViewBuilder var flow: () -> Flow

    var body: some View {
        ZStack {
            if state.mode == .flow {
                flow()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                CVRootPage()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
    }
}

// MARK: - Umschalter (ersetzt das Flow-Logo oben in der Seitenleiste)

struct CVAppSwitcher: View {
    @ObservedObject var state = CVHubState.shared
    @State private var hoverWord = false

    var body: some View {
        HStack(spacing: 0) {
            Button { state.toggle() } label: {
                ZStack(alignment: .leading) {
                    if state.mode == .flow {
                        CVWordmark(mode: .flow).transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                                       removal: .move(edge: .top).combined(with: .opacity)))
                    } else {
                        CVWordmark(mode: .clipvault).transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                                            removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .frame(height: 26, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.mode == .flow ? "Zu ClipVault wechseln (⌥⌘2)" : "Zu Flow wechseln (⌥⌘1)")
            Spacer(minLength: 8)
            toggle
        }
        .background {
            // Tastenkürzel ⌥⌘1 / ⌥⌘2
            Button("") { state.switchTo(.flow) }.keyboardShortcut("1", modifiers: [.command, .option]).opacity(0)
            Button("") { state.switchTo(.clipvault) }.keyboardShortcut("2", modifiers: [.command, .option]).opacity(0)
        }
    }

    /// Zwei Logo-Reiter in einer kleinen Kapsel (wie ein Workspace-Umschalter)
    private var toggle: some View {
        HStack(spacing: 2) {
            ForEach(CVAppMode.allCases) { m in
                CVModeTab(mode: m, selected: state.mode == m) { state.switchTo(m) }
            }
        }
        .padding(2.5)
        .background(Capsule().fill(VF.selected.opacity(0.75)))
        .overlay(Capsule().stroke(VF.hairline, lineWidth: 1))
    }
}

private struct CVModeTab: View {
    let mode: CVAppMode
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if mode == .flow { CVFlowGlyph() } else { CVClipGlyph() }
            }
            .foregroundStyle(selected ? VF.ink : VF.muted.opacity(hover ? 1 : 0.75))
            .frame(width: 15, height: 15)
            .frame(width: 30, height: 24)
            .background {
                if selected {
                    Capsule().fill(VF.card).shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode.title)
        .onHover { hover = $0 }
    }
}

/// Wortmarke der aktiven App (Bild aus Assets, sonst gezeichnet)
struct CVWordmark: View {
    let mode: CVAppMode
    var height: CGFloat = 23

    var body: some View {
        if mode == .flow {
            if let img = HubSidebar.trimmedLogo {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: height)
            } else {
                drawn(CVFlowGlyph(), "Flow")
            }
        } else {
            if let img = CVWordmark.trimmedClipVault {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: height)
            } else {
                drawn(CVClipGlyph(), "ClipVault")
            }
        }
    }

    private func drawn<G: View>(_ glyph: G, _ text: String) -> some View {
        HStack(spacing: height * 0.2) {
            glyph.frame(width: height * 0.95, height: height)
            Text(text).font(.system(size: height * 0.9, weight: .semibold)).tracking(-0.3)
        }
        .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.11))
    }

    /// clipvault_wordmark ohne transparenten Rand (einmal berechnet) – gleiche Logik wie beim Flow-Logo
    static let trimmedClipVault: NSImage? = {
        guard let img = VFAsset.image("clipvault_wordmark"),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
        guard maxX >= minX, maxY >= minY,
              let crop = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return img }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }()
}

// MARK: - Gezeichnete Marken (scharf in jeder Größe, färbbar)

/// Flow: fünf senkrechte Pillen (außen voll, innen kürzer) – wie logo_wordmark
struct CVFlowGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let bw = w * 0.15
            let gap = (w - 5 * bw) / 4
            // (oben, unten) relativ zur Höhe
            let bars: [(CGFloat, CGFloat)] = [(0, 1), (0.40, 0.84), (0.15, 0.77), (0.40, 0.84), (0, 1)]
            for (i, b) in bars.enumerated() {
                let r = CGRect(x: CGFloat(i) * (bw + gap), y: b.0 * h, width: bw, height: (b.1 - b.0) * h)
                ctx.fill(Path(roundedRect: r, cornerRadius: bw / 2), with: .foreground)
            }
        }
    }
}

/// ClipVault: zwei gestapelte Karten, vorne zwei liegende Pillen – wie clipvault_mark
struct CVClipGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let u = min(size.width, size.height)
            let ox = (size.width - u) / 2, oy = (size.height - u) / 2
            func R(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
                CGRect(x: ox + x0 * u, y: oy + y0 * u, width: (x1 - x0) * u, height: (y1 - y0) * u)
            }
            let t: CGFloat = 0.13, r: CGFloat = 0.2, gap: CGFloat = 0.08
            // hintere Karte minus Lücke
            var back = Path(roundedRect: R(0.26, 0.02, 0.98, 0.80), cornerRadius: r * u)
            let hole = Path(roundedRect: R(0.02 - gap, 0.20 - gap, 0.76 + gap, 0.98 + gap), cornerRadius: (r + gap) * u)
            back = back.subtracting(hole)
            ctx.fill(back, with: .foreground)
            // vordere Karte als Rahmen
            let outer = Path(roundedRect: R(0.02, 0.20, 0.76, 0.98), cornerRadius: r * u)
            let inner = Path(roundedRect: R(0.02 + t, 0.20 + t, 0.76 - t, 0.98 - t), cornerRadius: (r - t * 0.55) * u)
            ctx.fill(outer.subtracting(inner), with: .foreground)
            // Text-Pillen
            let ph: CGFloat = 0.11
            let lx: CGFloat = 0.02 + t + 0.09
            for (y, w) in [(0.52, 0.30), (0.73, 0.18)] as [(CGFloat, CGFloat)] {
                ctx.fill(Path(roundedRect: R(lx, y - ph / 2, lx + w, y + ph / 2), cornerRadius: ph / 2 * u), with: .foreground)
            }
        }
    }
}
