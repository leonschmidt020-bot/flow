import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bilder groß ansehen (ClipVault im Hub)
//
//  • Klick aufs Vorschaubild (rechte Spalte, Bilder-Kachel doppelt, Bild im „Geteilt“-Verlauf) → Leuchtkasten über der Seite:
//    Bild groß, zoombar (Trackpad-Zoom, Doppelklick = 100 % ↔ eingepasst, +/−), ← → = voriges/nächstes Bild, Esc = zu.
//    Knöpfe: „Öffnen“ (Standard-App, z. B. Vorschau) · „Im Finder zeigen“ · „Sichern unter …“ · Quick Look.
//  • Leertaste auf einem gewählten Bild in der Liste = Quick Look (wie im Finder), ← → blättert.
// Die Bilder bleiben, wo sie sind (~/.config/flow-clipvault/<id>.png bzw. shared/<id>.png) – es wird nichts kopiert.

struct CVViewerEntry: Identifiable, Equatable {
    let id: String
    let url: URL
    var title: String
    var subtitle: String
    /// Vorgeschlagener Dateiname für „Sichern unter …“ (ohne Endung)
    var saveName: String
}

extension CVViewerEntry {
    /// Eintrag aus dem eigenen Verlauf (nil = kein Bild / Datei fehlt)
    static func from(_ item: CVItem) -> CVViewerEntry? {
        guard item.kind == .image, let u = ClipVaultClient.shared.imageURL(item), FileManager.default.fileExists(atPath: u.path) else { return nil }
        var sub = CVFormat.relative(item.date)
        if let s = CVThumbs.pixelSize(u) { sub += " · \(Int(s.width)) × \(Int(s.height)) px" }
        return CVViewerEntry(id: item.id, url: u, title: item.title ?? "Bild", subtitle: sub,
                             saveName: "Bild " + HubFormat.date(item.date, "yyyy-MM-dd 'um' HH.mm.ss"))
    }

    /// Geteiltes Bild (nil = noch nicht geladen)
    static func from(_ item: SharedVaultItem) -> CVViewerEntry? {
        guard item.kind == .image, let u = item.image, FileManager.default.fileExists(atPath: u.path) else { return nil }
        var sub = (item.fromMe ? "Du hast geteilt" : "\(item.createdBy) hat geteilt") + " · " + CVFormat.relative(item.createdAt)
        if let s = CVThumbs.pixelSize(u) { sub += " · \(Int(s.width)) × \(Int(s.height)) px" }
        return CVViewerEntry(id: item.id, url: u, title: "Bild von \(item.fromMe ? "dir" : item.createdBy)", subtitle: sub,
                             saveName: "Bild " + HubFormat.date(item.createdAt, "yyyy-MM-dd 'um' HH.mm.ss"))
    }
}

/// Aktionen für ein Bild (Leuchtkasten, Vorschau-Spalte)
enum CVImageActions {
    static func open(_ e: CVViewerEntry) { NSWorkspace.shared.open(e.url) }
    static func reveal(_ e: CVViewerEntry) { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }

    static func saveAs(_ e: CVViewerEntry) {
        let p = NSSavePanel()
        let ext = e.url.pathExtension.isEmpty ? "png" : e.url.pathExtension
        p.nameFieldStringValue = e.saveName + "." + ext
        p.allowedContentTypes = [UTType(filenameExtension: ext) ?? .png]
        p.canCreateDirectories = true
        p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let go: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, let dest = p.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: e.url, to: dest)
                chmod(dest.path, 0o644)   // Kopie für den Benutzer normal lesbar (Original bleibt 0600)
            } catch {
                let a = NSAlert(); a.messageText = "Bild nicht gesichert"; a.informativeText = error.localizedDescription; a.runModal()
            }
        }
        if let w = NSApp.keyWindow { p.beginSheetModal(for: w, completionHandler: go) } else { go(p.runModal()) }
    }
}

// MARK: - Zustand

final class CVImageViewer: ObservableObject {
    static let shared = CVImageViewer()
    @Published private(set) var entries: [CVViewerEntry] = []
    @Published var index: Int?
    /// Beim Blättern: Auswahl in der Liste mitführen (Verlauf/Bilder)
    var onShow: ((CVViewerEntry) -> Void)?

    var isOpen: Bool { index != nil }
    var current: CVViewerEntry? { index.flatMap { entries.indices.contains($0) ? entries[$0] : nil } }

    func open(_ list: [CVViewerEntry], id: String, onShow: ((CVViewerEntry) -> Void)? = nil) {
        guard !list.isEmpty else { return }
        entries = list
        self.onShow = onShow
        withAnimation(.easeOut(duration: 0.18)) { index = list.firstIndex { $0.id == id } ?? 0 }
    }

    func close() { withAnimation(.easeOut(duration: 0.15)) { index = nil }; onShow = nil }

    func step(_ d: Int) {
        guard let i = index, !entries.isEmpty else { return }
        let n = max(0, min(entries.count - 1, i + d))
        guard n != i else { return }
        index = n
        onShow?(entries[n])
    }
}

// MARK: - Leuchtkasten

struct CVImageViewerOverlay: View {
    @ObservedObject var viewer = CVImageViewer.shared
    /// Nur Render: fester Zoom
    var renderZoom: CGFloat?

    var body: some View {
        if let e = viewer.current {
            CVImageViewerBody(entry: e, position: (viewer.index ?? 0) + 1, count: viewer.entries.count, renderZoom: renderZoom)
                .id(e.id)
                .transition(.opacity)
        }
    }
}

private struct CVImageViewerBody: View {
    let entry: CVViewerEntry
    let position: Int
    let count: Int
    var renderZoom: CGFloat?
    @ObservedObject var viewer = CVImageViewer.shared
    @State private var image: NSImage?
    @State private var zoom: CGFloat = 1        // 1 = eingepasst
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero
    @FocusState private var focused: Bool

    private var effectiveZoom: CGFloat { max(1, min(8, (renderZoom ?? zoom) * pinch)) }

    var body: some View {
        ZStack {
            Color(white: 0.06)   // deckend: kein Verlaufstext scheint durch
                .contentShape(Rectangle())
                .onTapGesture { viewer.close() }
            GeometryReader { g in
                let area = CGSize(width: g.size.width - 140, height: g.size.height - 150)
                let fit = fitted(area)
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                            .clipShape(RoundedRectangle(cornerRadius: effectiveZoom > 1.01 ? 0 : 6, style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                            .scaleEffect(effectiveZoom)
                            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                            .gesture(DragGesture()
                                .onChanged { v in if effectiveZoom > 1.01 { drag = v.translation } }
                                .onEnded { v in if effectiveZoom > 1.01 { offset.width += v.translation.width; offset.height += v.translation.height }; drag = .zero })
                            .simultaneousGesture(MagnifyGesture()
                                .onChanged { v in pinch = v.magnification }
                                .onEnded { v in setZoom(zoom * v.magnification); pinch = 1 })
                            .onTapGesture(count: 2) { setZoom(zoom > 1.01 ? 1 : actualSizeZoom(fit)) }
                    } else {
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
                .offset(y: 4)
            }
            .clipped()
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            HStack {
                navButton("chevron.left", enabled: position > 1) { viewer.step(-1) }
                Spacer()
                navButton("chevron.right", enabled: position < count) { viewer.step(1) }
            }
            .padding(.horizontal, 18)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) { viewer.close(); return .handled }
        .onKeyPress(.space) { viewer.close(); return .handled }
        .onKeyPress(.leftArrow) { viewer.step(-1); return .handled }
        .onKeyPress(.rightArrow) { viewer.step(1); return .handled }
        .onKeyPress(.upArrow) { viewer.step(-1); return .handled }
        .onKeyPress(.downArrow) { viewer.step(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-0")) { k in
            switch k.characters {
            case "+", "=": setZoom(zoom * 1.5)
            case "-": setZoom(zoom / 1.5)
            default: setZoom(1)
            }
            return .handled
        }
        .onAppear { focused = true; load() }
    }

    // MARK: Leisten

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(verbatim: entry.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if count > 1 {
                Text("\(position) von \(count)").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button { viewer.close() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain).help("Schließen (Esc)")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                zoomButton("minus.magnifyingglass", "Verkleinern (−)") { setZoom(zoom / 1.5) }
                Button { setZoom(1) } label: {
                    Text(effectiveZoom <= 1.01 ? "Eingepasst" : "\(Int((effectiveZoom * 100).rounded())) %")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                        .frame(minWidth: 78).frame(height: 32)
                }
                .buttonStyle(.plain).help("Einpassen (0) · Doppelklick aufs Bild = 100 %")
                zoomButton("plus.magnifyingglass", "Vergrößern (+)") { setZoom(zoom * 1.5) }
            }
            .padding(.horizontal, 4)
            .background(.white.opacity(0.12), in: Capsule())
            Spacer(minLength: 12)
            // schmales Fenster: nur „Öffnen“ mit Text, der Rest als Symbole (nie umbrechen)
            ViewThatFits(in: .horizontal) {
                actionPills(compact: false)
                actionPills(compact: true)
            }
        }
    }

    private func actionPills(compact: Bool) -> some View {
        HStack(spacing: 8) {
            pill("arrow.up.forward.app", "Öffnen", primary: true) { CVImageActions.open(entry) }
                .help("Im Standardprogramm öffnen (z. B. Vorschau)")
            pill("folder", compact ? nil : "Im Finder zeigen") { CVImageActions.reveal(entry) }.help("Im Finder zeigen")
            pill("square.and.arrow.down", compact ? nil : "Sichern unter …") { CVImageActions.saveAs(entry) }.help("Sichern unter …")
            pill("eye", compact ? nil : "Quick Look") { CVQuickLook.shared.show(viewer.entries, id: entry.id) }
                .help("Quick Look (wie im Finder)")
        }
        .fixedSize()
    }

    private func pill(_ s: String, _ t: String?, primary: Bool = false, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack(spacing: 7) {
                Image(systemName: s).font(.system(size: 12.5, weight: .semibold))
                if let t { Text(t).font(.system(size: 13, weight: .medium)).lineLimit(1) }
            }
            .foregroundStyle(primary ? .black : .white)
            .padding(.horizontal, t == nil ? 11 : 14).frame(height: 34)
            .background(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func zoomButton(_ s: String, _ help: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func navButton(_ s: String, enabled: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(count > 1 ? (enabled ? 1 : 0.25) : 0)
        .disabled(!enabled || count <= 1)
        .help(s == "chevron.left" ? "Voriges Bild (←)" : "Nächstes Bild (→)")
    }

    // MARK: Zoom + Laden

    private func fitted(_ area: CGSize) -> CGSize {
        let px = CVThumbs.pixelSize(entry.url) ?? image?.size ?? CGSize(width: 4, height: 3)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // nie über 100 % (Punkt = Pixel/Retina-Faktor) hinaus aufblasen – kleine Bilder bleiben scharf
        let natural = CGSize(width: px.width / scale, height: px.height / scale)
        let s = min(1, min(max(area.width, 50) / max(natural.width, 1), max(area.height, 50) / max(natural.height, 1)))
        return CGSize(width: natural.width * s, height: natural.height * s)
    }

    private func actualSizeZoom(_ fit: CGSize) -> CGFloat {
        let px = CVThumbs.pixelSize(entry.url) ?? CGSize(width: fit.width, height: fit.height)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return max(2, px.width / scale / max(fit.width, 1))
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            zoom = max(1, min(8, z))
            if zoom <= 1.01 { offset = .zero }
        }
    }

    private func load() {
        if let c = CVThumbs.shared.cached(entry.url, 3200) { image = c; return }
        // erst das kleine (sofort da), dann groß nachladen
        if let small = CVThumbs.shared.cached(entry.url, 1200) ?? CVThumbs.shared.cached(entry.url, 320) { image = small }
        CVThumbs.shared.load(entry.url, maxPixel: 3200) { img in if let img { image = img } }
    }
}

// MARK: - Quick Look (Leertaste, wie im Finder)
//
// Das Hub-Fenster (`VoiceFlowWindow` = Fenster-Delegate, steht in der Responder-Kette) übernimmt die Steuerung
// des Quick-Look-Fensters und reicht sie hierher weiter.

final class CVQuickLookItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String
    init(_ e: CVViewerEntry) { url = e.url; title = e.title + " · " + e.subtitle }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

final class CVQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = CVQuickLook()
    private(set) var entries: [CVViewerEntry] = []
    private var items: [CVQuickLookItem] = []
    private var startIndex = 0
    private var indexObs: NSKeyValueObservation?
    /// Beim Blättern mitgeführt (Auswahl in der Liste)
    var onShow: ((CVViewerEntry) -> Void)?

    var hasItems: Bool { !items.isEmpty }
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ list: [CVViewerEntry], id: String, onShow: ((CVViewerEntry) -> Void)? = nil) {
        guard !list.isEmpty else { return }
        entries = list
        items = list.map(CVQuickLookItem.init)
        startIndex = list.firstIndex { $0.id == id } ?? 0
        self.onShow = onShow
        let p = QLPreviewPanel.shared()!
        if p.isVisible {
            p.reloadData(); p.currentPreviewItemIndex = startIndex
        } else {
            p.makeKeyAndOrderFront(nil)
        }
    }

    /// Leertaste: offen → zu, sonst öffnen
    func toggle(_ list: [CVViewerEntry], id: String, onShow: ((CVViewerEntry) -> Void)? = nil) {
        if isVisible { QLPreviewPanel.shared().orderOut(nil); return }
        show(list, id: id, onShow: onShow)
    }

    // Vom Controller in der Responder-Kette
    func begin(_ p: QLPreviewPanel) {
        p.dataSource = self; p.delegate = self
        p.reloadData()
        p.currentPreviewItemIndex = startIndex
        indexObs = p.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] p, _ in
            guard let self, self.entries.indices.contains(p.currentPreviewItemIndex) else { return }
            let e = self.entries[p.currentPreviewItemIndex]
            DispatchQueue.main.async { self.onShow?(e) }
        }
    }

    func end(_ p: QLPreviewPanel) {
        indexObs = nil
        p.dataSource = nil; p.delegate = nil
        items = []; entries = []; onShow = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] }

    /// ← → ↑ ↓ blättern, Leertaste schließt (wie im Finder)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 123, 126: if panel.currentPreviewItemIndex > 0 { panel.currentPreviewItemIndex -= 1 }; return true
        case 124, 125: if panel.currentPreviewItemIndex < items.count - 1 { panel.currentPreviewItemIndex += 1 }; return true
        case 49: panel.orderOut(nil); return true
        default: return false
        }
    }
}
