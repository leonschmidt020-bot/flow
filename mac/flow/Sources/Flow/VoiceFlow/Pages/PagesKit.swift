import AppKit
import SwiftUI

// MARK: - Gemeinsame Bausteine der Voice-Flow-Seiten (Wörterbuch, Snippets, Stil, Transforms, Scratchpad, Einstellungen)
// Präfix „PG“, damit nichts mit Bausteinen anderer Bereiche kollidiert.

/// JSON-Dateien unter ~/.config/flow, nur für dich lesbar (0600).
enum PGFile {
    static func url(_ name: String) -> URL { Paths.base.appendingPathComponent(name) }

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder.pg.decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(value) else { return }
        let u = url(name)
        do {
            try d.write(to: u, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        } catch { log("\(name) speichern fehlgeschlagen: \(error)") }
    }
}

extension JSONDecoder {
    static let pg: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

enum PG {
    /// „Flow schreibt, wie *du* schreibst.“ → Serif-Überschrift, das Wort zwischen * kursiv.
    static func headline(_ s: String, size: CGFloat) -> Text {
        var result = Text(verbatim: "")
        for (i, part) in s.components(separatedBy: "*").enumerated() where !part.isEmpty {
            let t = Text(verbatim: part).font(VF.serif(size, italic: i % 2 == 1))
            result = Text("\(result)\(t)")
        }
        return result
    }

    /// „so, dass **Namen** stimmen“ → Fließtext mit fetten Stellen.
    static func richBody(_ s: String, size: CGFloat = 18) -> Text {
        var result = Text(verbatim: "")
        for (i, part) in s.components(separatedBy: "**").enumerated() where !part.isEmpty {
            let t = Text(verbatim: part).font(.system(size: size, weight: i % 2 == 1 ? .semibold : .regular))
            result = Text("\(result)\(t)")
        }
        return result
    }

    static let tabFont = Font.system(size: 18.5, weight: .regular)
    static let body = Font.system(size: 18)
    static let rowFont = Font.system(size: 18.5)
    static let sparkle = Color(red: 0.98, green: 0.80, blue: 0.35)
}

// MARK: Seitengerüst

/// Mittige Inhaltsspalte (max. 1060) mit Titel links und Knopf/Steuerung rechts – wie jede Hub-Seite.
struct PGPage<Trailing: View, Content: View>: View {
    let title: String
    var badge: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Text(title).font(VF.pageTitle).foregroundStyle(VF.ink)
                    if let badge {
                        Text(badge).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(VF.black))
                    }
                    Spacer(minLength: 20)
                    trailing()
                }
                .frame(height: 47)
                content()
            }
            .frame(maxWidth: VF.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.top, 54)
            .padding(.bottom, 70)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(VF.panel)
    }
}

// MARK: Knöpfe

struct PGPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 21)
            .frame(height: 47)
            .background(RoundedRectangle(cornerRadius: VF.buttonRadius).fill(VF.black.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

struct PGSoftButtonStyle: ButtonStyle {
    var height: CGFloat = 47
    var minWidth: CGFloat = 0
    var fill: Color = VF.buttonSoft
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(VF.ink)
            .padding(.horizontal, 20)
            .frame(minWidth: minWidth, minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: VF.buttonRadius).fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Rectangle())
    }
}

struct PGPrimaryButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View { Button(title, action: action).buttonStyle(PGPrimaryButtonStyle()) }
}

/// Kleines Symbol, das beim Überfahren einen Hintergrund bekommt (Bearbeiten, Löschen, Suche …)
struct PGIconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 17
    var tint: Color = VF.muted
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(hover ? VF.ink : tint)
                .frame(width: size + 17, height: size + 17)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? VF.buttonSoft : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

// MARK: Reiter

struct PGTab: Identifiable, Equatable {
    let id: String
    let title: String
    var badge: String? = nil
}

/// Reiterzeile mit Unterstrich unter dem aktiven Reiter, rechts optional Symbole.
struct PGTabBar<Trailing: View>: View {
    let tabs: [PGTab]
    @Binding var selection: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 32) {
            ForEach(tabs) { tab in
                let active = tab.id == selection
                Button { selection = tab.id } label: {
                    HStack(spacing: 10) {
                        Text(tab.title)
                            .font(.system(size: 18.5, weight: active ? .medium : .regular))
                            .foregroundStyle(active ? VF.ink : VF.ink.opacity(0.72))
                        if let b = tab.badge {
                            Text(b).font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(VF.purple)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 7).fill(VF.purple.opacity(0.11)))
                        }
                    }
                    .padding(.bottom, 16)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(active ? VF.ink : .clear).frame(height: 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) { trailing() }.padding(.bottom, 12)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(VF.hairline).frame(height: 1) }
        .padding(.top, 70)
    }
}

extension PGTabBar where Trailing == EmptyView {
    init(tabs: [PGTab], selection: Binding<String>) {
        self.tabs = tabs; self._selection = selection; self.trailing = { EmptyView() }
    }
}

/// Suchfeld, das sich unter der Reiterzeile öffnet.
struct PGSearchField: View {
    @Binding var text: String
    var prompt = "Suchen …"
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(VF.muted)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 17))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(VF.muted) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(VF.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(VF.hairline))
        .padding(.top, 20)
    }
}

// MARK: Banner

/// Foto-Banner (VFAsset) mit weißer Schrift; ohne Bild ein warmer, weichgezeichneter Verlauf.
struct PGBanner<Content: View>: View {
    let image: String
    var palette: [Color] = PGBannerPalette.warm
    var onClose: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .foregroundStyle(.white)
            .padding(.horizontal, 43)
            .padding(.top, 44)
            .padding(.bottom, 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PGBannerBackground(image: image, palette: palette))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.white.opacity(0.82)))
                    }
                    .buttonStyle(.plain).help("Ausblenden")
                    .padding(.top, 21).padding(.trailing, 21)
                }
            }
    }
}

enum PGBannerPalette {
    // Warmes Holz / Kerzenlicht (Wörterbuch)
    static let warm: [Color] = [Color(red: 0.36, green: 0.22, blue: 0.14), Color(red: 0.62, green: 0.42, blue: 0.24),
                                Color(red: 0.20, green: 0.24, blue: 0.22), Color(red: 0.78, green: 0.55, blue: 0.30), Color(red: 0.25, green: 0.12, blue: 0.08)]
    // Abend-Café, bläulich-bunt (Snippets)
    static let dusk: [Color] = [Color(red: 0.12, green: 0.16, blue: 0.24), Color(red: 0.28, green: 0.38, blue: 0.55),
                                Color(red: 0.55, green: 0.40, blue: 0.28), Color(red: 0.75, green: 0.70, blue: 0.60), Color(red: 0.10, green: 0.10, blue: 0.12)]
    // Kühles Grau-Blau mit warmem Licht (Stil)
    static let slate: [Color] = [Color(red: 0.16, green: 0.22, blue: 0.28), Color(red: 0.36, green: 0.44, blue: 0.52),
                                 Color(red: 0.42, green: 0.30, blue: 0.24), Color(red: 0.60, green: 0.56, blue: 0.50), Color(red: 0.12, green: 0.12, blue: 0.12)]
    // Waldgrün (Transforms)
    static let forest: [Color] = [Color(red: 0.12, green: 0.20, blue: 0.16), Color(red: 0.26, green: 0.40, blue: 0.30),
                                  Color(red: 0.62, green: 0.58, blue: 0.40), Color(red: 0.40, green: 0.52, blue: 0.46), Color(red: 0.08, green: 0.10, blue: 0.09)]
    // Sonnenuntergang am Schreibtisch (Scratchpad)
    static let sunset: [Color] = [Color(red: 0.30, green: 0.16, blue: 0.10), Color(red: 0.80, green: 0.46, blue: 0.22),
                                  Color(red: 0.40, green: 0.26, blue: 0.30), Color(red: 0.95, green: 0.70, blue: 0.42), Color(red: 0.16, green: 0.08, blue: 0.06)]
}

struct PGBannerBackground: View {
    let image: String
    let palette: [Color]

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let img = VFAsset.image(image) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    fallback(g.size)
                }
                // Lesbarkeit: links dunkler, wo der Text steht
                LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .black.opacity(0.32), location: 0.45),
                                      .init(color: .black.opacity(0.06), location: 0.8)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
    }

    private func fallback(_ s: CGSize) -> some View {
        let p = palette + palette
        return ZStack {
            LinearGradient(colors: [p[0], p[4]], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(p[1]).frame(width: s.width * 0.55).offset(x: s.width * 0.28, y: -s.height * 0.35).blur(radius: 70)
            Circle().fill(p[2]).frame(width: s.width * 0.35).offset(x: -s.width * 0.05, y: s.height * 0.45).blur(radius: 60)
            Circle().fill(p[3]).frame(width: s.width * 0.28).offset(x: s.width * 0.42, y: s.height * 0.25).blur(radius: 55).opacity(0.85)
            Circle().fill(p[1].opacity(0.7)).frame(width: s.width * 0.22).offset(x: -s.width * 0.38, y: -s.height * 0.4).blur(radius: 50)
        }
        .frame(width: s.width, height: s.height)
        .clipped()
    }
}

/// Halb-transparenter Chip auf dem Banner („Samir“, „Sara“ …) bzw. heller Aktions-Chip („Neues Wort“).
struct PGBannerChip: View {
    let title: String
    var prominent = false
    var italic = false
    var action: (() -> Void)? = nil

    var body: some View {
        let label = Text(title)
            .font(.system(size: 18, weight: .semibold).italic(italic))
            .foregroundStyle(VF.ink.opacity(prominent ? 1 : 0.82))
            .lineLimit(1)
            .padding(.horizontal, 21)
            .frame(height: 47)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(prominent ? 0.92 : 0.58)))
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

// MARK: Liste

/// Weiße Karte mit Haarlinien zwischen den Zeilen.
struct PGListCard<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                row(item)
                if idx < items.count - 1 { Rectangle().fill(VF.hairline).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.card))
        .clipShape(RoundedRectangle(cornerRadius: VF.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline, lineWidth: 1))
    }
}

/// Eine Listenzeile (70 hoch) mit Hover-Hintergrund und Aktionen rechts, die erst beim Überfahren erscheinen.
struct PGRow<Content: View, Actions: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    var onTap: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 12)
            HStack(spacing: 4) { actions() }.opacity(hover ? 1 : 0)
        }
        .padding(.leading, 22).padding(.trailing, 14)
        .frame(minHeight: 70)
        .background(hover ? VF.panel : VF.card)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onTap?() }
    }
}

/// Leerer Zustand in einer Karte.
struct PGEmptyState: View {
    let illustration: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            if let img = VFAsset.image(illustration) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(VF.ink)
            Text(text).font(.system(size: 16)).foregroundStyle(VF.muted).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .padding(.vertical, 50)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.card))
        .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
    }
}

// MARK: Dialoge (Sheets)

/// Einheitlicher Dialog: Titel, Felder, „Abbrechen“ / Hauptknopf.
struct PGSheet<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let confirm: String
    var canConfirm = true
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(VF.serif(32)).foregroundStyle(VF.ink)
                if let subtitle { Text(subtitle).font(.system(size: 15)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true) }
            }
            content()
            HStack(spacing: 10) {
                Spacer()
                Button("Abbrechen", action: onCancel).buttonStyle(PGSoftButtonStyle(height: 40)).keyboardShortcut(.cancelAction)
                Button(confirm, action: onConfirm).buttonStyle(PGPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm).opacity(canConfirm ? 1 : 0.4)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 520)
        .background(VF.panel)
        .environment(\.colorScheme, .light)
    }
}

/// Beschriftetes Eingabefeld im Dialog.
struct PGField: View {
    let label: String
    var hint: String? = nil
    @Binding var text: String
    var placeholder = ""
    var multiline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink)
            if multiline {
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 110)
                    .background(RoundedRectangle(cornerRadius: 10).fill(VF.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(VF.hairline))
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(VF.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(VF.hairline))
            }
            if let hint { Text(hint).font(.system(size: 12.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: Hilfen

extension String {
    /// Für Vergleiche: klein, nur Buchstaben und Ziffern (Leerzeichen/Satzzeichen weg).
    var pgKey: String { lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined() }
    var pgTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Einfache Fließ-Anordnung (Chips, die umbrechen).
struct PGFlow: Layout {
    var spacing: CGFloat = 11
    var lineSpacing: CGFloat = 11

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}
