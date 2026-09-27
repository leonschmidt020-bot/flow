// ClipVault — Bilder groß ansehen: Quick Look (wie im Finder)
//
//  • Klick aufs Vorschaubild rechts   → Quick Look mit allen Bildern der Liste (← → blättert, Leertaste/Esc schließt)
//  • Leertaste auf einem Bild-Eintrag → dasselbe (Suchfeld leer), wie im Finder
//  • Knopf „Öffnen“ oben rechts       → Standard-App (z. B. Vorschau)
// Gezeigt werden die vorhandenen Dateien (~/.config/flow-clipvault/<id>.png bzw. shared/<id>.png) – nichts wird kopiert.
// Das Panel (ClipPanel) steht in der Responder-Kette und übernimmt die Steuerung des Quick-Look-Fensters.
import Cocoa
import Quartz

final class CVQLItem: NSObject, QLPreviewItem {
    let id: String
    let url: URL
    let title: String
    init(id: String, url: URL, title: String) { self.id = id; self.url = url; self.title = title }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

final class CVQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = CVQuickLook()
    private(set) var items: [CVQLItem] = []
    private var startIndex = 0
    private var indexObs: NSKeyValueObservation?
    /// Beim Blättern: Auswahl/Vorschau im Panel mitführen
    var onShow: ((String) -> Void)?
    /// Fenster, das nach dem Schließen wieder Tastatur bekommt
    weak var returnTo: NSWindow?

    var hasItems: Bool { !items.isEmpty }
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ list: [CVQLItem], id: String, from window: NSWindow?, onShow: ((String) -> Void)? = nil) {
        guard !list.isEmpty else { return }
        items = list
        startIndex = list.firstIndex { $0.id == id } ?? 0
        self.onShow = onShow
        returnTo = window
        NSApp.activate(ignoringOtherApps: true)   // Panel ist „nonactivating“ – Quick Look braucht eine aktive App für die Tasten
        window?.makeKey()
        let p = QLPreviewPanel.shared()!
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)   // über dem ClipVault-Panel
        if p.isVisible && p.dataSource === self {
            p.reloadData(); p.currentPreviewItemIndex = startIndex
        } else {
            p.makeKeyAndOrderFront(nil)
        }
    }

    /// Leertaste: offen → zu, sonst öffnen
    func toggle(_ list: [CVQLItem], id: String, from window: NSWindow?, onShow: ((String) -> Void)? = nil) {
        if isVisible { QLPreviewPanel.shared().orderOut(nil); return }
        show(list, id: id, from: window, onShow: onShow)
    }

    func close() { if isVisible { QLPreviewPanel.shared().orderOut(nil) } }

    // Vom ClipPanel (Responder-Kette)
    func begin(_ p: QLPreviewPanel) {
        p.dataSource = self; p.delegate = self
        p.reloadData()
        p.currentPreviewItemIndex = startIndex
        indexObs = p.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] p, _ in
            guard let self = self, self.items.indices.contains(p.currentPreviewItemIndex) else { return }
            let id = self.items[p.currentPreviewItemIndex].id
            DispatchQueue.main.async { self.onShow?(id) }
        }
    }

    func end(_ p: QLPreviewPanel) {
        indexObs = nil
        p.dataSource = nil; p.delegate = nil
        items = []; onShow = nil
        if let w = returnTo, w.isVisible { w.makeKey() }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] }

    /// ← → ↑ ↓ blättern, Leertaste schließt (wie im Finder); Esc schließt Quick Look selbst
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 123, 126: if panel.currentPreviewItemIndex > 0 { panel.currentPreviewItemIndex -= 1 }; return true
        case 124, 125: if panel.currentPreviewItemIndex < items.count - 1 { panel.currentPreviewItemIndex += 1 }; return true
        case 49: panel.orderOut(nil); return true
        default: return false
        }
    }

    /// Zoom-Animation aus dem Vorschaubild heraus
    var sourceFrame: (() -> NSRect)?
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let f = sourceFrame, let it = item as? CVQLItem, items.firstIndex(of: it) == startIndex else { return .zero }
        return f()
    }
}

extension PanelController {
    /// Alle Bilder der aktuellen Liste in Anzeige-Reihenfolge (eigene + geteilte, nur vorhandene Dateien, keine Passwort-Einträge)
    func quickLookItems() -> [CVQLItem] {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateFormat = "d. MMM, HH:mm"
        var out: [CVQLItem] = []
        for r in display {
            switch r {
            case .item(let it):
                guard it.kind == .image, !Store.shared.isSecret(it.collection), let u = Store.shared.imageURL(it),
                      FileManager.default.fileExists(atPath: u.path) else { continue }
                out.append(CVQLItem(id: it.id, url: u, title: "Bild · \(df.string(from: it.date))"))
            case .shared(let sh):
                guard sh.kind == .image, let u = SharedVault.shared.localURL(sh) else { continue }
                let who = sh.createdBy == SharedVault.shared.me ? "von dir" : "von \(sh.createdBy)"
                out.append(CVQLItem(id: sh.id, url: u, title: "Geteiltes Bild \(who)"))
            case .header: continue
            }
        }
        return out
    }

    /// Bild des Eintrags in der Vorschau (nil = kein Bild / Datei fehlt)
    func previewImageFile() -> URL? {
        guard let id = previewItemId else { return nil }
        if let it = Store.shared.item(id), it.kind == .image, let u = Store.shared.imageURL(it), FileManager.default.fileExists(atPath: u.path) { return u }
        if let sh = SharedVault.shared.item(id), sh.kind == .image { return SharedVault.shared.localURL(sh) }
        return nil
    }

    /// Quick Look für den Eintrag in der Vorschau (toggle = Leertaste)
    @discardableResult func quickLookPreview(toggle: Bool = false) -> Bool {
        guard let id = previewItemId, let u = previewImageFile() else { return false }
        var list = quickLookItems()
        if !list.contains(where: { $0.id == id }) { list = [CVQLItem(id: id, url: u, title: "Bild")] }   // z. B. Passwort-Bereich: nur dieses
        let img = prevImage
        CVQuickLook.shared.sourceFrame = { [weak img] in
            guard let v = img, let w = v.window, !v.isHidden else { return .zero }
            return w.convertToScreen(v.convert(v.bounds, to: nil))
        }
        let sync: (String) -> Void = { [weak self] id in
            guard let self = self, let idx = self.display.firstIndex(where: { self.rowId($0) == id }) else { return }
            self.selectRow(idx, scroll: true)
        }
        if toggle { CVQuickLook.shared.toggle(list, id: id, from: panel, onShow: sync) }
        else { CVQuickLook.shared.show(list, id: id, from: panel, onShow: sync) }
        return true
    }

    @objc func openPreviewClicked() {
        guard let u = previewImageFile() else { Toast.shared.show("Datei nicht mehr da"); return }
        CVQuickLook.shared.close()
        hide(); NSWorkspace.shared.open(u)
    }
}
