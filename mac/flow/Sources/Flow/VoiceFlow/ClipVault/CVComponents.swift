import AppKit
import SwiftUI

// MARK: - Bausteine der ClipVault-Seiten (Flow-Designsprache: helle Fläche, Serif-Banner, Listenkarten, schwarze Knöpfe)

enum CVPalette {
    /// Banner-Verlauf (Tinte → Pflaume → warmes Licht), falls kein Bild banner_clipvault vorhanden ist
    static let vault: [Color] = [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.36, green: 0.30, blue: 0.52),
                                 Color(red: 0.62, green: 0.38, blue: 0.30), Color(red: 0.90, green: 0.68, blue: 0.46), Color(red: 0.07, green: 0.07, blue: 0.10)]
    static let shared: [Color] = [Color(red: 0.08, green: 0.18, blue: 0.20), Color(red: 0.25, green: 0.47, blue: 0.47),
                                  Color(red: 0.55, green: 0.42, blue: 0.62), Color(red: 0.93, green: 0.74, blue: 0.52), Color(red: 0.06, green: 0.09, blue: 0.10)]
    static let ai = Color(red: 0.55, green: 0.36, blue: 0.80)
    static let voice = Color(red: 0.90, green: 0.52, blue: 0.16)
    static let phone = Color(red: 0.20, green: 0.48, blue: 0.90)
    static let link = Color(red: 0.16, green: 0.52, blue: 0.55)
    static let green = Color(red: 0.30, green: 0.68, blue: 0.45)
    static let danger = Color(red: 0.78, green: 0.22, blue: 0.18)
    static let rowSelected = Color(red: 0.945, green: 0.937, blue: 0.918)
}

/// Banner wie auf den Hub-Seiten (179 hoch, Serif-Überschrift, ein Wort kursiv)
struct CVBanner<Actions: View>: View {
    var image = "banner_clipvault"
    var palette: [Color] = CVPalette.vault
    let headline: String
    let sub: String
    var height: CGFloat = 179
    var onClose: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ZStack(alignment: .topLeading) {
            PGBannerBackground(image: image, palette: palette)
            VStack(alignment: .leading, spacing: 0) {
                PG.headline(headline, size: 33)
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(sub)
                    .font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2).padding(.top, 6)
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions() }
            }
            .padding(.leading, 32).padding(.trailing, 70).padding(.top, 30).padding(.bottom, 30)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 23, height: 23).background(.black.opacity(0.35), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Ausblenden")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 16).padding(.trailing, 16)
            }
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Filter-Chip (aktiv schwarz, sonst weiche Fläche)
struct CVChip: View {
    let title: String
    var symbol: String? = nil
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)) }
                Text(title).font(.system(size: 13, weight: .medium))
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .opacity(selected ? 0.7 : 0.55)
                }
            }
            .foregroundStyle(selected ? .white : VF.ink)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(selected ? VF.black : (hover ? VF.selected : VF.buttonSoft)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Kompaktes Suchfeld (Hub-Stil)
struct CVSearchField: View {
    @Binding var text: String
    var prompt = "Durchsuchen …"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(VF.muted)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 14.5)).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(VF.muted.opacity(0.7)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(VF.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(focused ? VF.ink.opacity(0.25) : VF.hairline))
        .background {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0)
        }
    }
}

/// Kleines Etikett (Quelle, Bereich …)
struct CVTag: View {
    let text: String
    var symbol: String? = nil
    var color: Color = VF.muted
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).frame(height: 20)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Quadratisches Symbolfeld links in der Zeile (Bild, Link-Vorschau, Datei-Icon oder Art-Symbol)
struct CVItemVisual: View {
    let item: CVItem
    var size: CGFloat = 40
    @ObservedObject var cv = ClipVaultClient.shared

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                // Bilder im Passwörter-Bereich nur als grobe Pixel-Vorschau
                CVThumb(url: cv.imageURL(item), maxPixel: cv.isSecret(item) ? 8 : 160)
            case .link:
                if let u = item.url, let p = cv.linkPreviewImageURL(u) {
                    CVThumb(url: p, maxPixel: 160)
                } else {
                    symbol("globe", CVPalette.link)
                }
            case .file:
                if let f = item.files.first {
                    Image(nsImage: CVFileIcon.icon(cv.fileURL(f))).resizable().aspectRatio(contentMode: .fit).padding(3)
                        .background(VF.cardSoft)
                } else { symbol("doc", VF.muted) }
            case .text:
                if cv.isSecret(item) { symbol("lock.fill", VF.ink) }
                else if item.isAI { symbol("sparkles", CVPalette.ai) }
                else if item.isVoice { symbol(item.source == "Meeting" ? "person.2.wave.2" : "waveform", CVPalette.voice) }
                else if item.isPhone { symbol("iphone", CVPalette.phone) }
                else { symbol("text.alignleft", VF.muted) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VF.hairline.opacity(0.9), lineWidth: 1))
    }

    private func symbol(_ s: String, _ c: Color) -> some View {
        ZStack {
            (c == VF.muted || c == VF.ink ? VF.cardSoft : c.opacity(0.1))
            Image(systemName: s).font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(c == VF.muted ? VF.ink.opacity(0.7) : c)
        }
    }
}

enum CVFileIcon {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ url: URL) -> NSImage {
        if let c = cache[url.path] { return c }
        let ic = NSWorkspace.shared.icon(forFile: url.path)
        ic.size = NSSize(width: 64, height: 64)
        cache[url.path] = ic
        return ic
    }
    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }
}

/// Unterzeile einer Zeile: „Link · github.com“, „Bild · 1920 × 1080“ …
enum CVDescribe {
    static func subline(_ item: CVItem, cv: ClipVaultClient) -> String {
        var parts: [String] = []
        switch item.kind {
        case .text:
            parts.append(cv.isSecret(item) ? "Geschützt · zum Anzeigen drüberfahren" : CVFormat.wordsLabel(item.text ?? ""))
        case .link:
            parts.append(item.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link")
        case .image:
            if let u = cv.imageURL(item), let s = CVThumbs.pixelSize(u) { parts.append("Bild · \(Int(s.width)) × \(Int(s.height))") } else { parts.append("Bild") }
            if item.ocr != nil { parts.append("Text erkannt") }
        case .file:
            let n = item.files.count
            parts.append(n > 1 ? "\(n) Dateien" : (item.files.first.map { ($0.name as NSString).pathExtension.uppercased() } ?? "Datei"))
        }
        if item.isAI { parts.append("von KI") } else if let s = item.source, !s.isEmpty { parts.append(s) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Eine Zeile im Verlauf (Zeit links, Inhalt rechts – wie der Diktat-Verlauf im Hub)

struct CVItemRow: View {
    let item: CVItem
    let selected: Bool
    var showCollection = true
    var fresh = false
    let onSelect: () -> Void
    @ObservedObject var cv = ClipVaultClient.shared
    @State private var hover = false

    var body: some View {
        let secret = cv.isSecret(item)
        HStack(alignment: .center, spacing: 0) {
            Text(HubFormat.time(item.date))
                .font(.system(size: 13.5)).foregroundStyle(VF.muted).monospacedDigit()
                .frame(width: 62, alignment: .leading)
            CVItemVisual(item: item)
                .padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind == .link ? (cv.linkTitle(item.url!) ?? item.headline) : item.headline)
                    .font(.system(size: 14.5)).foregroundStyle(VF.ink)
                    .lineLimit(item.kind == .text ? 2 : 1)
                    .cvHidden(secret && !hover && item.kind == .text)
                HStack(spacing: 6) {
                    Text(CVDescribe.subline(item, cv: cv)).font(.system(size: 12)).foregroundStyle(VF.muted).lineLimit(1)
                    if showCollection, let c = cv.collection(item.collection) {
                        HStack(spacing: 4) {
                            CVCollectionIcon(collection: c, size: 10)
                            Text(c.name).font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(VF.ink.opacity(0.75))
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(VF.buttonSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    if item.shared {
                        Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(CVPalette.link).help("Mit \(Identity.partner(.dative)) geteilt")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if hover {
                    HubIconButton(symbol: "doc.on.doc", size: 13, color: VF.muted, help: "Kopieren") { cv.copy(item) }
                    HubIconButton(symbol: item.pinned ? "pin.slash" : "pin", size: 13, color: VF.muted,
                                  help: item.pinned ? "Lösen" : "Anheften") { cv.setPinned(item, !item.pinned) }
                } else if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(VF.ink.opacity(0.55))
                        .frame(width: 27, height: 27)
                }
            }
            .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.leading, 17).padding(.trailing, 10)
        .padding(.vertical, 11)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu { CVItemMenu(item: item) }
    }

    private var background: Color {
        if fresh { return VF.teal4 }
        if selected { return CVPalette.rowSelected }
        return hover ? VF.panel : VF.card
    }
}

/// Kontextmenü (Rechtsklick) für einen Eintrag
struct CVItemMenu: View {
    let item: CVItem
    @ObservedObject var cv = ClipVaultClient.shared

    var body: some View {
        Button("Kopieren") { cv.copy(item) }
        Button(item.pinned ? "Lösen" : "Anheften") { cv.setPinned(item, !item.pinned) }
        Menu("In Bereich legen") {
            ForEach(cv.collections) { c in
                Button { cv.setCollection(item, c.id) } label: {
                    if item.collection == c.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            if item.collection != nil {
                Divider()
                Button("Aus Bereich nehmen") { cv.setCollection(item, nil) }
            }
        }
        if item.shared { Button("Nicht mehr teilen") { cv.unshare(item) } } else { Button("Mit \(Identity.partner(.dative)) teilen") { cv.share(item) } }
        if item.kind == .image { Button("Text erkennen") { cv.requestOCR(item) } }
        if item.kind == .link, let u = item.url { Button("Im Browser öffnen") { NSWorkspace.shared.open(u) } }
        if item.kind == .file, let f = item.files.first {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([cv.fileURL(f)]) }
        }
        Divider()
        Button("Löschen", role: .destructive) { cv.delete(item) }
    }
}

/// Rückmeldung unten mittig („Kopiert“ …)
struct CVToastView: View {
    let toast: CVToast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).font(.system(size: 12.5, weight: .semibold))
            Text(toast.text).font(.system(size: 13.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).frame(height: 38)
        .background(Capsule().fill(toast.isError ? CVPalette.danger : VF.black))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}

/// Neuer Text-Eintrag
struct CVAddTextSheet: View {
    @Binding var isPresented: Bool
    var collection: String? = nil
    @State private var text = ""
    @State private var target: String?
    @ObservedObject var cv = ClipVaultClient.shared

    var body: some View {
        PGSheet(title: "Neuer Eintrag", subtitle: "Landet in ClipVault, als hättest du ihn kopiert.", confirm: "Hinzufügen",
                canConfirm: !text.pgTrimmed.isEmpty,
                onCancel: { isPresented = false },
                onConfirm: { cv.addText(text, collection: target); isPresented = false }) {
            PGField(label: "Text", text: $text, multiline: true)
            if !cv.collections.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Bereich").font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink)
                    PGFlow(spacing: 8, lineSpacing: 8) {
                        CVChip(title: "Keiner", selected: target == nil) { target = nil }
                        ForEach(cv.collections) { c in
                            CVChip(title: c.name, selected: target == c.id) { target = c.id }
                        }
                    }
                }
            }
        }
        .onAppear { target = collection }
    }
}
