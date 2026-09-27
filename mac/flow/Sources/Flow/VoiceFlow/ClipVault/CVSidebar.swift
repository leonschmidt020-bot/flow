import AppKit
import SwiftUI

// MARK: - Seitenleiste im ClipVault-Modus (gleiche Maße wie HubSidebar)

struct CVSidebar: View {
    @ObservedObject var state = CVHubState.shared
    @ObservedObject var cv = ClipVaultClient.shared
    @ObservedObject var shared = CVShared.shared
    @State private var status = ClipVaultClient.shared.status()

    var body: some View {
        GeometryReader { g in content(tall: g.size.height > 780) }
            .onAppear { cv.start(); shared.start() }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in status = cv.status() }
    }

    private func content(tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CVAppSwitcher()
                .padding(.leading, 8).padding(.top, 14)
                .frame(height: 38, alignment: .leading)
            VStack(spacing: 4) {
                ForEach(CVSection.navigation) { s in
                    CVNavRow(title: s.title, icon: .symbol(s.symbol), count: count(s),
                             selected: state.section == s && state.openCollection == nil) { state.go(s) }
                }
                CVNavRow(title: CVSection.geteilt.title, icon: .symbol(CVSection.geteilt.symbol),
                         count: shared.items.isEmpty ? nil : shared.items.count,
                         live: shared.status.isConnected,
                         selected: state.section == .geteilt) { state.go(.geteilt) }
            }
            .padding(.top, 31)

            if !cv.collections.isEmpty {
                HubLabel("Bereiche")
                    .padding(.leading, 10).padding(.top, 26).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(cv.collections) { c in
                            CVNavRow(title: c.name, icon: .collection(c), count: cv.count(in: c.id), compact: true,
                                     selected: state.section == .bereiche && state.openCollection == c.id) {
                                state.go(.bereiche, collection: c.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(minHeight: 0, maxHeight: CGFloat(cv.collections.count) * 34)
                .layoutPriority(-1)
            }

            Spacer(minLength: 16)
            if tall {
                statusCard.padding(.bottom, 13)
                    .transition(.opacity)
            }
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.bottom, 12)
            CVNavRow(title: CVSection.einstellungen.title, icon: .symbol(CVSection.einstellungen.symbol),
                     selected: state.section == .einstellungen) { state.go(.einstellungen) }
                .padding(.bottom, 13)
        }
        .padding(.leading, 12).padding(.trailing, 14)
        .frame(maxHeight: .infinity)
    }

    private func count(_ s: CVSection) -> Int? {
        switch s {
        case .angeheftet: let n = cv.items.filter(\.pinned).count; return n > 0 ? n : nil
        default: return nil
        }
    }

    private var todayCount: Int { cv.items.filter { Calendar.current.isDateInToday($0.date) }.count }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(status.running ? Color(red: 0.30, green: 0.68, blue: 0.45) : VF.orange).frame(width: 7, height: 7)
                Text(status.running ? "ClipVault läuft" : "ClipVault ist aus")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(VF.ink)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(todayCount)").font(VF.serif(30)).foregroundStyle(VF.ink)
                Text(todayCount == 1 ? "Kopie heute" : "Kopien heute").font(.system(size: 12.5)).foregroundStyle(VF.ink)
            }
            .padding(.top, 8)
            HStack(spacing: 5) {
                HubKeycapSmall("⌘"); HubKeycapSmall("⇧"); HubKeycapSmall("V")
                Text("öffnet ClipVault überall").font(.system(size: 11.5)).foregroundStyle(VF.muted)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard(VF.card, radius: 12)
    }
}

/// Mini-Tastenkappe für die Seitenleiste
struct HubKeycapSmall: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(VF.ink)
            .frame(minWidth: 18, minHeight: 18)
            .background(VF.panel, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).stroke(VF.hairline))
    }
}

enum CVNavIcon {
    case symbol(String)
    case collection(CVCollection)
}

struct CVNavRow: View {
    let title: String
    let icon: CVNavIcon
    var count: Int? = nil
    var live = false
    var compact = false
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconView.frame(width: 20)
                Text(title).font(.system(size: compact ? 14 : 15)).lineLimit(1)
                if live {
                    Circle().fill(Color(red: 0.30, green: 0.68, blue: 0.45)).frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(VF.muted)
                }
            }
            .foregroundStyle(VF.ink)
            .padding(.leading, 8).padding(.trailing, 10)
            .frame(height: compact ? 32 : 36)
            .background(selected ? VF.selected : (hover ? VF.selected.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .symbol(let s): Image(systemName: s).font(.system(size: 16, weight: .regular))
        case .collection(let c): CVCollectionIcon(collection: c, size: compact ? 14 : 16)
        }
    }
}

/// Symbol eines Bereichs: SF-Symbol oder „img:<datei>“ aus ~/.config/flow-clipvault
struct CVCollectionIcon: View {
    let collection: CVCollection
    var size: CGFloat = 16

    var body: some View {
        if collection.isImageSymbol, let img = CVCollectionIcon.image(collection.symbol) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size + 2, height: size + 2)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            let sym = collection.isImageSymbol ? "sparkles" : collection.symbol
            Image(systemName: NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil ? sym : "folder")
                .font(.system(size: size - 1, weight: .regular))
        }
    }

    private static var cache: [String: NSImage] = [:]
    static func image(_ symbol: String) -> NSImage? {
        if let c = cache[symbol] { return c }
        let name = String(symbol.dropFirst(4))
        guard !name.contains("/"),
              let img = CVThumbs.make(ClipVaultClient.base.appendingPathComponent(name), maxPixel: 96) else { return nil }
        cache[symbol] = img
        return img
    }
}
