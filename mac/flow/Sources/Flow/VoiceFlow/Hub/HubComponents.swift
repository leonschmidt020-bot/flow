import AppKit
import SwiftUI

// MARK: - Kleine Bausteine, die nur die Hub-Seiten (Diktat, Notetaker, Insights, Hilfe) nutzen

enum HubFont {
    /// Seitentitel („Welcome back, Alex“, „Notetaker“, „Insights“)
    static let title = Font.system(size: 24, weight: .semibold)
    static let body = Font.system(size: 15)
    static let bodyMedium = Font.system(size: 15, weight: .medium)
    static let small = Font.system(size: 13)
    /// GROSSBUCHSTABEN-Label (mit .tracking(1.3))
    static let label = Font.system(size: 12, weight: .semibold)
    /// große Zahlen in Insights-Karten (sans, nicht serif)
    static let bigNumber = Font.system(size: 29, weight: .medium)
}

enum HubFormat {
    private static let de = Locale(identifier: "de_DE")

    static func number(_ n: Int) -> String {
        let f = NumberFormatter(); f.locale = de; f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Kurz: 1.589 · 41.063 · 419.239 · 1,2 Mio.
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            let f = NumberFormatter(); f.locale = de; f.numberStyle = .decimal; f.maximumFractionDigits = 1
            return (f.string(from: NSNumber(value: Double(n) / 1_000_000)) ?? "") + " Mio."
        }
        return number(n)
    }

    static func percent(_ v: Double, digits: Int = 0) -> String {
        let f = NumberFormatter(); f.locale = de; f.numberStyle = .decimal
        f.maximumFractionDigits = digits; f.minimumFractionDigits = 0
        return (f.string(from: NSNumber(value: v)) ?? "0") + " %"
    }

    static func date(_ d: Date, _ format: String) -> String {
        let f = DateFormatter(); f.locale = de; f.dateFormat = format
        return f.string(from: d)
    }

    static func time(_ d: Date) -> String { date(d, "HH:mm") }
}

/// GROSSBUCHSTABEN mit Sperrung – „26. SEPTEMBER 2026“, „HEUTE“, „ÜBERSICHT“
struct HubLabel: View {
    let text: String
    var color: Color = VF.muted
    init(_ text: String, color: Color = VF.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "de_DE")))
            .font(HubFont.label).tracking(1.3).foregroundStyle(color)
    }
}

/// Reiterleiste: aktiver Reiter schwarz + 2 pt Strich, darunter Haarlinie über die ganze Breite
struct HubTabs<T: Hashable>: View {
    let tabs: [(T, String)]
    @Binding var selection: T
    var spacing: CGFloat = 32
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(tabs.indices, id: \.self) { i in
                let (tag, title) = tabs[i]
                let on = tag == selection
                Button { selection = tag } label: {
                    VStack(spacing: 9) {
                        Text(title).font(on ? HubFont.bodyMedium : HubFont.body)
                            .foregroundStyle(on ? VF.ink : VF.muted)
                        Rectangle().fill(on ? VF.ink : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let trailing { trailing.padding(.bottom, 10) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(VF.hairline).frame(height: 1) }
    }
}

/// Knöpfe
struct HubSoftButton: ButtonStyle {
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubFont.bodyMedium).foregroundStyle(VF.ink)
            .padding(.horizontal, 14).frame(height: height)
            .background(VF.buttonSoft.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct HubBlackButton: ButtonStyle {
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubFont.bodyMedium).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: height)
            .background(VF.black.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct HubOutlineButton: ButtonStyle {
    var height: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubFont.bodyMedium).foregroundStyle(VF.ink)
            .padding(.horizontal, 16).frame(height: height)
            .background(configuration.isPressed ? VF.buttonSoft : VF.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VF.hairline))
            .contentShape(Rectangle())
    }
}

/// Symbol-Knopf mit Hover-Fläche
struct HubIconButton: View {
    let symbol: String
    var size: CGFloat = 16
    var color: Color = VF.ink
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(color)
                .frame(width: size + 14, height: size + 14)
                .background(hover ? VF.selected.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Tastenkappe (Hilfe-Seite)
struct HubKeycap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(VF.ink)
            .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 24)
            .background(VF.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(VF.hairline))
            .shadow(color: .black.opacity(0.05), radius: 0, y: 1)
    }
}

/// Karte (weiß oder „soft“) mit Haarlinie
struct HubCardBackground: ViewModifier {
    var fill: Color = VF.card
    var radius: CGFloat = VF.cardRadius
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(VF.hairline, lineWidth: 1))
    }
}

extension View {
    func hubCard(_ fill: Color = VF.card, radius: CGFloat = VF.cardRadius) -> some View {
        modifier(HubCardBackground(fill: fill, radius: radius))
    }

    /// Seiten-Rahmen: Inhalt max. 1046 pt breit, mittig, ≥ 48 pt Rand
    func hubPage(maxWidth: CGFloat = 1046, top: CGFloat = 42) -> some View {
        self.frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, top).padding(.bottom, 48)
            .frame(maxWidth: .infinity)
    }
}

/// Foto-Banner mit Serif-Überschrift (Bild aus Resources/Assets, sonst warmer Verlauf)
struct HubBanner<Actions: View>: View {
    let image: String
    let headline: Text
    let sub: String
    var height: CGFloat = 179
    var onClose: (() -> Void)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                headline
                    .font(VF.serif(33))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(sub)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .padding(.top, 6)
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions }
            }
            .padding(.leading, 32).padding(.trailing, 70).padding(.top, 30).padding(.bottom, 32)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 23, height: 23)
                        .background(.black.opacity(0.35), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Ausblenden")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 16).padding(.trailing, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background { Color.clear.overlay { background }.clipped() }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var background: some View {
        if let img = VFAsset.image(image) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.20, blue: 0.27), Color(red: 0.16, green: 0.30, blue: 0.33),
                                        Color(red: 0.62, green: 0.40, blue: 0.20), Color(red: 0.86, green: 0.62, blue: 0.33)],
                               startPoint: .leading, endPoint: .trailing)
                RadialGradient(colors: [Color(red: 1, green: 0.8, blue: 0.5).opacity(0.55), .clear], center: .init(x: 0.78, y: 0.55),
                               startRadius: 5, endRadius: 260)
            }
        }
    }
}

/// Weißer halbtransparenter Knopf im Banner („Zeig mir wie“)
struct HubBannerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
            .padding(.horizontal, 16).frame(height: 36)
            .background(Color(red: 0.95, green: 0.94, blue: 0.92).opacity(configuration.isPressed ? 0.8 : 0.96),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Illustration aus Assets (quadratisch) mit Fallback-Symbol
struct HubIllustration: View {
    let name: String
    let fallback: String
    var size: CGFloat = 120
    var body: some View {
        if let img = VFAsset.image(name) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.80, green: 0.74, blue: 0.93), Color(red: 0.66, green: 0.58, blue: 0.86)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(Image(systemName: fallback).font(.system(size: size * 0.34, weight: .light)).foregroundStyle(.white))
        }
    }
}

/// Kleines ⓘ mit Tooltip
struct HubInfo: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(VF.muted.opacity(0.8)).help(text)
    }
}
