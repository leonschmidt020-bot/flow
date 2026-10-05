// ClipVault — Panel (Liste, Chips, Vorschau)
import Cocoa
import Carbon.HIToolbox
import QuartzCore
import Quartz
import QuickLookThumbnailing
import WebKit
import CryptoKit

// MARK: - Hover Row
final class HoverRowView: NSView {
    var onHover: (() -> Void)?
    var onExit: (() -> Void)?
    private var ta: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = ta { removeTrackingArea(ta) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); ta = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

enum Row { case header(String); case item(ClipItem); case shared(SharedItem) }

/// Maus-Beobachter ohne eigene View (fuer die Vorschau: Passwort beim Drueberfahren zeigen)
final class HoverTracker: NSResponder {
    var onEnter: (() -> Void)?; var onExit: (() -> Void)?
    override init() { super.init() }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
/// Waagerecht scrollende Leiste: auch das normale Mausrad (senkrecht) schiebt seitlich
final class HScrollView: NSScrollView {
    override func scrollWheel(with e: NSEvent) {
        guard let doc = documentView else { return }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        let step = e.hasPreciseScrollingDeltas ? d : d * 12
        var o = contentView.bounds.origin
        o.x = max(0, min(doc.frame.width - contentView.bounds.width, o.x - step))
        contentView.scroll(to: o); reflectScrolledClipView(contentView)
    }
}
/// Typ-Filter unter dem Suchfeld
enum TypeFilter: Int, CaseIterable {
    case all, text, images, links, files
    var label: String { switch self { case .all: return "Alle"; case .text: return "Text"; case .images: return "Bilder"; case .links: return "Links"; case .files: return "Dateien" } }
}
let SHARED_CHIP = "__shared__"
/// „Neu vom Partner": Gruen (#34C759, systemGreen hell) — bewusst NICHT das Lila der KI-Markierung
let CV_NEW_GREEN = NSColor(srgbRed: 0x34/255.0, green: 0xC7/255.0, blue: 0x59/255.0, alpha: 1)
/// Zaehler-Plakette wie ein App-Badge: gruene Kapsel mit weissem Ring und weisser Zahl
func newBadgeImage(_ n: Int, height h: CGFloat = 17) -> NSImage {
    let txt = n > 99 ? "99+" : "\(n)"
    let f = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    let tw = txt.size(withAttributes: [.font: f]).width
    let w = max(h, tw + 10)
    return NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
        NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: h/2, yRadius: h/2).fill()
        let inner = r.insetBy(dx: 1.5, dy: 1.5)
        CV_NEW_GREEN.setFill(); NSBezierPath(roundedRect: inner, xRadius: inner.height/2, yRadius: inner.height/2).fill()
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white]
        let s = txt.size(withAttributes: a)
        txt.draw(at: NSPoint(x: (r.width - s.width)/2, y: (r.height - s.height)/2 + 0.5), withAttributes: a)
        return true
    }
}

// MARK: - Panel
final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Quick Look (quicklook.swift): das Panel steuert das Quick-Look-Fenster
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { CVQuickLook.shared.hasItems }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { CVQuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { CVQuickLook.shared.end(panel) }
}
final class ChipButton: NSButton { var chipId: String = "" }
final class FlatButton: NSButton { var payload: String = "" }

final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    static var shared: PanelController?
    let panel: ClipPanel
    let effect = NSVisualEffectView()
    let table = NSTableView(); let scroll = NSScrollView(); let search = NSSearchField()
    // preview
    let prevHeader = NSTextField(labelWithString: "")
    let prevText = NSTextView(); let prevScroll = NSScrollView(); let prevImage = NSImageView()
    let copyBtn = NSButton()
    let emptyLabel = NSTextField(labelWithString: "Bewege die Maus über einen Eintrag")
    let pairBtn = NSButton(title: "Koppeln …", target: nil, action: nil)   // Geteilt: mit dem Partner koppeln (sync.swift)
    var filtered: [ClipItem] = []; var display: [Row] = []
    let W: CGFloat = 900, H: CGFloat = 660, leftW: CGFloat = 450
    var prevX: CGFloat = 0; var prevW: CGFloat = 0; var fullPrevFrame: NSRect = .zero
    var currentCollection: String? = nil   // nil = Verlauf
    let chipBar = NSView()
    let chipScroll = HScrollView()
    let filterBar = NSView()
    let countLabel = NSTextField(labelWithString: "")
    var typeFilter: TypeFilter = .all
    var quickIndex: [String: Int] = [:]      // Eintrags-id -> 1…9 (Cmd+Zahl)
    var revealSecrets = false                // Wahltaste (⌥) gehalten -> Passwoerter zeigen
    var previewHover = false                 // Maus ueber der Vorschau -> Passwort zeigen
    let previewTracker = HoverTracker()
    var flagsMonitor: Any?
    var previewItemId: String? = nil         // welcher Eintrag steht gerade in der Vorschau
    var editingId: String? = nil             // Text-Eintrag wird gerade bearbeitet
    let finderBtn = NSButton(), editBtn = NSButton(), saveBtn = NSButton(), cancelBtn = NSButton()
    let shareBtn = NSButton()                // Vorschau: „Teilen" mit dem Partner (Umschalter, Cmd+J)
    let openBtn = NSButton()                 // Vorschau (Bild): „Öffnen" in der Standard-App (z. B. Vorschau)
    let ocrLabel = NSTextField(labelWithString: "")
    let ocrCopyBtn = NSButton()
    var expandedRowCollapse: (() -> Void)?   // schließt die aktuell offene Hover-Pille (nur EINE gleichzeitig)
    var previewURL: URL? = nil               // Link des aktuellen Vorschau-Eintrags (Klick aufs Bild öffnet ihn)
    // „Neu vom Partner": Markierung je Zeile (Punkt + NEU im Untertitel) und Verweil-Zeitgeber der Vorschau
    var newMarkers: [String: (dot: NSView, sub: NSTextField, plain: NSAttributedString)] = [:]
    var seenTimer: Timer?
    var previewPlainHeader: NSAttributedString?   // Kopfzeile der Vorschau ohne „● NEU"
    let seenAllBtn = FlatButton()
    // Geteilt: Dateien (Fortschrittsring, Laden, Speicherstand) — Logik in sharedpanel.swift
    var transferMarkers: [String: (ring: RingView, sub: NSTextField)] = [:]
    let loadBtn = NSButton()                 // Vorschau: „Laden" / „Abbrechen"
    let saveDlBtn = NSButton()               // Vorschau: „In Downloads sichern"
    let prevProgress = NSProgressIndicator()
    let storageBar = NSView()
    let storageLabel = NSTextField(labelWithString: "")
    let storageTrack = NSView(), storageFill = NSView()
    let cleanupBtn = FlatButton()
    // Mehrfachauswahl (multiselect.swift / multiselect_panel.swift)
    var multi = MultiSelection()
    let selBar = SelectionBarView()
    let selCount = NSTextField(labelWithString: "")
    let selCopyBtn = NSButton(), selClearBtn = NSButton()
    lazy var globePlaceholder: NSImage? = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 56, weight: .light).applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.35)])))

    override init() {
        panel = ClipPanel(contentRect: NSRect(x:0,y:0,width:W,height:H), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(); setup(); PanelController.shared = self
    }
    func setup() {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        effect.frame = NSRect(x:0,y:0,width:W,height:H)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)   // immer dunkel rendern (nicht hell auf weissem BG)
        effect.wantsLayer = true; effect.layer?.cornerRadius = 16; effect.layer?.masksToBounds = true
        panel.contentView = effect
        // Dunkler Tint ueber dem Blur -> Panel bleibt dunkel, auch ueber weissem Hintergrund
        let darkTint = NSView(frame: effect.bounds); darkTint.autoresizingMask = [.width, .height]
        darkTint.wantsLayer = true; darkTint.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.42).cgColor
        effect.addSubview(darkTint)

        // Bereiche-Leiste oben
        // Bereiche-Leiste scrollt seitlich, wenn es mehr Bereiche gibt als Platz (sonst wurden sie abgeschnitten)
        chipScroll.frame = NSRect(x: 8, y: H-42, width: leftW-12, height: 34)
        chipScroll.drawsBackground = false; chipScroll.hasHorizontalScroller = false; chipScroll.hasVerticalScroller = false
        chipScroll.horizontalScrollElasticity = .allowed; chipScroll.verticalScrollElasticity = .none
        chipBar.frame = NSRect(x: 0, y: 0, width: leftW-12, height: 34)
        chipScroll.documentView = chipBar
        chipScroll.wantsLayer = true
        effect.addSubview(chipScroll)

        search.frame = NSRect(x: 12, y: H-80, width: leftW-24, height: 28)
        search.delegate = self; search.placeholderString = "Suchen…"; search.focusRingType = .none
        effect.addSubview(search)

        // Typ-Filter: Alle · Text · Bilder · Links · Dateien  (+ Anzahl rechts)
        filterBar.frame = NSRect(x: 12, y: H-110, width: leftW-24, height: 24)
        effect.addSubview(filterBar)
        countLabel.font = .systemFont(ofSize: 11, weight: .medium); countLabel.textColor = NSColor.white.withAlphaComponent(0.38)
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: filterBar.frame.width - 110, y: 4, width: 106, height: 16)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")); col.width = leftW-24
        table.addTableColumn(col); table.headerView = nil
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .noColumnAutoresizing  // Zeilenbreite deterministisch -> Pin überlappt nie
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(rowClicked)
        table.setDraggingSourceOperationMask([.copy], forLocal: false)  // Drag-out in andere Apps
        let cmenu = NSMenu(); cmenu.delegate = self; table.menu = cmenu  // Rechtsklick: In Bereich legen / Anheften / Löschen
        scroll.frame = NSRect(x: 8, y: 8, width: leftW-12, height: H-120)
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        effect.addSubview(scroll)

        // divider
        let div = NSView(frame: NSRect(x: leftW+2, y: 10, width: 1, height: H-20))
        div.wantsLayer = true; div.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        effect.addSubview(div)

        // preview pane
        let px = leftW + 12, pw = W - leftW - 24
        prevHeader.frame = NSRect(x: px, y: H-58, width: pw-108, height: 40)
        prevHeader.font = .systemFont(ofSize: 13, weight: .medium); prevHeader.textColor = NSColor.white.withAlphaComponent(0.85)
        prevHeader.lineBreakMode = .byWordWrapping; prevHeader.maximumNumberOfLines = 2
        effect.addSubview(prevHeader)

        // Kopieren-Button oben rechts: Auswahl ODER ganzen Eintrag kopieren, Panel bleibt offen
        copyBtn.isBordered = false; copyBtn.imagePosition = .imageLeading; copyBtn.imageHugsTitle = true
        copyBtn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Kopieren")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        copyBtn.contentTintColor = .white
        copyBtn.attributedTitle = NSAttributedString(string: " Kopieren", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        copyBtn.wantsLayer = true; copyBtn.layer?.cornerRadius = 14
        copyBtn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        copyBtn.frame = NSRect(x: px + pw - 100, y: H-49, width: 100, height: 28)
        copyBtn.toolTip = "Auswahl oder ganzen Eintrag kopieren (Cmd+C) — Panel bleibt offen"
        copyBtn.target = self; copyBtn.action = #selector(copyPreviewClicked)
        copyBtn.isHidden = true
        effect.addSubview(copyBtn)
        // weitere Knoepfe oben rechts (werden je nach Eintrag ein-/ausgeblendet, layoutTopButtons ordnet sie)
        styleIconButton(finderBtn, "folder", tip: "Im Finder zeigen", action: #selector(finderClicked))
        styleIconButton(editBtn, "pencil", tip: "Bearbeiten (Cmd+E)", action: #selector(editClicked))
        styleIconButton(cancelBtn, "xmark", tip: "Abbrechen (Esc)", action: #selector(cancelEditClicked))
        stylePillButton(saveBtn, "checkmark", " Speichern", tip: "Speichern (Cmd+S) · Cmd+Enter = speichern und kopieren", action: #selector(saveEditClicked))
        saveBtn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        stylePillButton(shareBtn, "person.2.fill", " Teilen", tip: "Mit \(SharedVault.shared.partner) teilen (Cmd+J)", action: #selector(sharePreviewClicked))
        stylePillButton(openBtn, "arrow.up.forward.app", " Öffnen", tip: "Im Standardprogramm öffnen (z. B. Vorschau) · Klick aufs Bild / Leertaste = Quick Look", action: #selector(openPreviewClicked))
        for b in [finderBtn, editBtn, cancelBtn, saveBtn, shareBtn] { b.isHidden = true; effect.addSubview(b) }

        prevText.isEditable = false; prevText.isSelectable = true; prevText.drawsBackground = false
        prevText.font = .monospacedSystemFont(ofSize: 13, weight: .regular); prevText.textColor = .white
        prevText.textContainerInset = NSSize(width: 6, height: 6)
        prevText.selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.55), .foregroundColor: NSColor.white]
        prevText.insertionPointColor = .white
        prevText.linkTextAttributes = [.foregroundColor: NSColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        prevScroll.frame = NSRect(x: px, y: 14, width: pw, height: H-58-20)
        prevScroll.documentView = prevText; prevScroll.drawsBackground = false; prevScroll.hasVerticalScroller = true
        effect.addSubview(prevScroll)

        prevImage.frame = prevScroll.frame; prevImage.imageScaling = .scaleProportionallyUpOrDown
        prevImage.wantsLayer = true; prevImage.layer?.cornerRadius = 10; prevImage.layer?.masksToBounds = true
        prevImage.layer?.borderWidth = 1; prevImage.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        prevImage.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.5).cgColor
        prevImage.isHidden = true
        prevImage.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(previewImageClicked)))
        effect.addSubview(prevImage)
        // „Öffnen" schwebt unten rechts auf dem Bild (oben rechts ist kein Platz mehr, die Kopfzeile würde abgeschnitten)
        openBtn.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        openBtn.layer?.borderWidth = 1; openBtn.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        openBtn.isHidden = true
        effect.addSubview(openBtn, positioned: .above, relativeTo: prevImage)
        prevX = px; prevW = pw; fullPrevFrame = NSRect(x: px, y: 14, width: pw, height: H-58-20)

        // Texterkennung: Zeile zwischen Bild und erkanntem Text
        ocrLabel.font = .systemFont(ofSize: 10.5, weight: .semibold); ocrLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        ocrLabel.isHidden = true; effect.addSubview(ocrLabel)
        stylePillButton(ocrCopyBtn, "text.viewfinder", " Text kopieren", tip: "Erkannten Text kopieren — Panel bleibt offen", action: #selector(ocrCopyClicked))
        ocrCopyBtn.isHidden = true; effect.addSubview(ocrCopyBtn)

        // Passwoerter: Maus ueber der Vorschau zeigt den Inhalt
        previewTracker.onEnter = { [weak self] in self?.setPreviewHover(true) }
        previewTracker.onExit = { [weak self] in self?.setPreviewHover(false) }
        effect.addTrackingArea(NSTrackingArea(rect: NSRect(x: px - 6, y: 8, width: pw + 12, height: H - 16), options: [.mouseEnteredAndExited, .activeAlways], owner: previewTracker, userInfo: nil))
        NotificationCenter.default.addObserver(forName: OCR.doneNote, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let id = n.object as? String, id == self.previewItemId, self.editingId == nil,
                  let it = Store.shared.item(id) else { return }
            self.showPreview(it)
            if let ridx = self.display.firstIndex(where: { if case .item(let x) = $0 { return x.id == id }; return false }) {
                self.table.reloadData(forRowIndexes: IndexSet(integer: ridx), columnIndexes: IndexSet(integer: 0))
            }
        }

        emptyLabel.frame = NSRect(x: px, y: H/2, width: pw, height: 60); emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        emptyLabel.maximumNumberOfLines = 3; emptyLabel.lineBreakMode = .byWordWrapping
        effect.addSubview(emptyLabel)
        pairBtn.bezelStyle = .rounded; pairBtn.controlSize = .regular; pairBtn.target = self; pairBtn.action = #selector(pairClicked)
        pairBtn.sizeToFit(); pairBtn.frame.origin = NSPoint(x: px + (pw - pairBtn.frame.width) / 2, y: H/2 - 36)
        pairBtn.isHidden = true; effect.addSubview(pairBtn)
        setupSharedFileUI()
        setupSelectionBar()
        buildChips(); buildFilters()
    }
    func styleIconButton(_ b: NSButton, _ sym: String, tip: String, action: Selector) {
        b.isBordered = false; b.title = ""; b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        b.contentTintColor = .white
        b.wantsLayer = true; b.layer?.cornerRadius = 14
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        b.frame = NSRect(x: 0, y: H-49, width: 32, height: 28)
        b.toolTip = tip; b.target = self; b.action = action
    }
    func stylePillButton(_ b: NSButton, _ sym: String, _ title: String, tip: String, action: Selector) {
        b.isBordered = false; b.imagePosition = .imageLeading; b.imageHugsTitle = true
        b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        b.contentTintColor = .white
        let f = NSFont.systemFont(ofSize: 12, weight: .medium)
        b.attributedTitle = NSAttributedString(string: title, attributes: [.font: f, .foregroundColor: NSColor.white])
        b.wantsLayer = true; b.layer?.cornerRadius = 13
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        b.frame = NSRect(x: 0, y: H-49, width: title.size(withAttributes: [.font: f]).width + 38, height: 28)
        b.toolTip = tip; b.target = self; b.action = action
    }
    /// Knoepfe oben rechts von rechts nach links anordnen; Kopfzeile bekommt den Rest
    func layoutTopButtons() {
        let order: [NSButton] = editingId != nil ? [saveBtn, cancelBtn] : [copyBtn, loadBtn, shareBtn, editBtn, saveDlBtn, finderBtn]
        var x = prevX + prevW
        for b in order where !b.isHidden {
            x -= b.frame.width; b.setFrameOrigin(NSPoint(x: x, y: H-49)); x -= 6
        }
        prevHeader.frame = NSRect(x: prevX, y: H-58, width: max(120, x - prevX - 4), height: 40)
    }
    // ===== Bereiche (Chip-Leiste) =====
    func buildChips() {
        chipBar.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        func add(_ name: String, _ symbol: String, id: String, selected: Bool, badge: Int = 0) {
            let c = makeChip(name, symbol, selected: selected, id: id, badge: badge)
            c.setFrameOrigin(NSPoint(x: x, y: (chipBar.bounds.height - c.frame.height)/2))
            chipBar.addSubview(c); x += c.frame.width + 6
        }
        add("Verlauf", "clock", id: "", selected: currentCollection == nil)
        add("Geteilt", "person.2.fill", id: SHARED_CHIP, selected: currentCollection == SHARED_CHIP, badge: SharedSeen.shared.newCount)
        for col in Store.shared.collections { add(col.name, col.symbol, id: col.id, selected: currentCollection == col.id) }
        add("", "plus", id: "__new__", selected: false)
        chipBar.setFrameSize(NSSize(width: max(chipScroll.bounds.width, x), height: 34))
        // weicher Rand rechts, wenn es mehr Bereiche gibt als Platz
        if x > chipScroll.bounds.width + 1 {
            let m = CAGradientLayer(); m.frame = chipScroll.bounds
            m.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            m.locations = [0, 0.92, 1]; m.startPoint = CGPoint(x: 0, y: 0.5); m.endPoint = CGPoint(x: 1, y: 0.5)
            chipScroll.layer?.mask = m
        } else { chipScroll.layer?.mask = nil }
        // gewaehlten Chip in Sicht holen
        if let sel = chipBar.subviews.compactMap({ $0 as? ChipButton }).first(where: { $0.chipId == (currentCollection ?? "") }) {
            chipBar.scrollToVisible(sel.frame.insetBy(dx: -8, dy: 0))
        }
    }
    func buildFilters() {
        filterBar.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        let f = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        for tf in TypeFilter.allCases {
            let sel = tf == typeFilter
            let b = FlatButton(); b.payload = String(tf.rawValue)
            b.isBordered = false; b.bezelStyle = .regularSquare
            b.attributedTitle = NSAttributedString(string: tf.label, attributes: [.font: f, .foregroundColor: sel ? NSColor.white : NSColor.white.withAlphaComponent(0.55)])
            b.wantsLayer = true; b.layer?.cornerRadius = 11
            b.layer?.backgroundColor = sel ? NSColor.white.withAlphaComponent(0.20).cgColor : NSColor.clear.cgColor
            let w = tf.label.size(withAttributes: [.font: f]).width + 20
            b.frame = NSRect(x: x, y: 1, width: w, height: 22)
            b.target = self; b.action = #selector(filterClicked(_:))
            filterBar.addSubview(b); x += w + 2
        }
        filterBar.addSubview(countLabel)
        // Geteilt: „Alle gesehen" rechts (statt der Anzahl), solange es Neues vom Partner gibt
        let gf = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        seenAllBtn.isBordered = false; seenAllBtn.bezelStyle = .regularSquare; seenAllBtn.imagePosition = .imageLeading; seenAllBtn.imageHugsTitle = true
        seenAllBtn.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        seenAllBtn.contentTintColor = CV_NEW_GREEN
        seenAllBtn.attributedTitle = NSAttributedString(string: " Alle gesehen", attributes: [.font: gf, .foregroundColor: CV_NEW_GREEN])
        seenAllBtn.wantsLayer = true; seenAllBtn.layer?.cornerRadius = 11
        seenAllBtn.layer?.backgroundColor = CV_NEW_GREEN.withAlphaComponent(0.16).cgColor
        let bw = " Alle gesehen".size(withAttributes: [.font: gf]).width + 34
        seenAllBtn.frame = NSRect(x: filterBar.frame.width - bw, y: 1, width: bw, height: 22)
        seenAllBtn.toolTip = "Alles Neue von \(SharedVault.shared.partner) als gesehen markieren"
        seenAllBtn.target = self; seenAllBtn.action = #selector(markAllSeenClicked)
        filterBar.addSubview(seenAllBtn)
        updateSeenControls()
    }
    /// Zaehler rechts in der Filterleiste bzw. „Alle gesehen" (nur in „Geteilt" mit Neuem)
    func updateSeenControls() {
        let show = currentCollection == SHARED_CHIP && SharedSeen.shared.newCount > 0
        seenAllBtn.isHidden = !show; countLabel.isHidden = show
    }
    @objc func markAllSeenClicked() { SharedSeen.shared.markAllSeen() }
    /// Gesehen-Stand hat sich geaendert (hier, per Befehl oder von einem anderen Programm) -> Punkte/Zaehler anpassen,
    /// ohne die Liste neu zu bauen (Auswahl + Hover-Pille bleiben stehen)
    func seenStateChanged() {
        guard panel.isVisible || CV_READ_ONLY else { return }
        let seen = SharedSeen.shared
        var appeared = false
        for (id, m) in newMarkers {
            let isNew = seen.isNew(id: id)
            if !isNew && !m.dot.isHidden { m.dot.isHidden = true; m.sub.attributedStringValue = m.plain }
            if isNew && m.dot.isHidden { appeared = true }
        }
        if appeared { refreshAfterExternalChange(); return }   // wieder „neu" (z. B. Stand zurueckgesetzt) -> sauber neu bauen
        if let id = previewItemId, let p = previewPlainHeader, !seen.isNew(id: id) { prevHeader.attributedStringValue = p; previewPlainHeader = nil }
        let off = chipScroll.contentView.bounds.origin
        buildChips()
        chipScroll.contentView.scroll(to: off); chipScroll.reflectScrolledClipView(chipScroll.contentView)
        updateSeenControls()
    }
    @objc func filterClicked(_ sender: FlatButton) {
        typeFilter = TypeFilter(rawValue: Int(sender.payload) ?? 0) ?? .all
        buildFilters(); reload()
    }
    func passesType(_ it: ClipItem) -> Bool {
        switch typeFilter {
        case .all: return true
        case .text: return it.kind == .text && soleURL(it.text) == nil
        case .images: return it.kind == .image
        case .links: return it.kind == .text && it.badges.contains(.link)
        case .files: return it.kind == .file
        }
    }
    func passesType(_ s: SharedItem) -> Bool {
        switch typeFilter {
        case .all: return true
        case .text: return s.kind == .text
        case .images: return s.kind == .image
        case .links: return s.kind == .link || (s.kind == .text && detectBadges(s.text ?? "").contains(.link))
        case .files: return s.kind == .file
        }
    }
    /// Von aussen geaendert (Hub-Befehl, OCR, Sync) -> Ansicht auffrischen, Auswahl moeglichst halten
    func refreshAfterExternalChange() {
        guard panel.isVisible, editingId == nil else { return }
        let keep = previewItemId
        if let c = currentCollection, c != SHARED_CHIP, Store.shared.collection(c) == nil { currentCollection = nil }
        buildChips(); reload()
        if let k = keep, let idx = display.firstIndex(where: { rowId($0) == k }) { selectRow(idx) }
    }
    func open(collection: String) {
        currentCollection = (collection == SHARED_CHIP || Store.shared.collection(collection) != nil) ? collection : nil
        buildChips(); reload()
    }
    func rowId(_ r: Row) -> String? {
        switch r { case .item(let it): return it.id; case .shared(let s): return s.id; case .header: return nil }
    }
    // Bereich-Icon: SF-Symbol ODER echtes Bild-Logo ("img:<datei>" in ~/.config/flow-clipvault/)
    func colIcon(_ symbol: String, sf: CGFloat, img imgSize: CGFloat) -> NSImage? {
        if symbol.hasPrefix("img:") {
            let im = NSImage(contentsOf: Store.shared.dir.appendingPathComponent(String(symbol.dropFirst(4))))
            im?.size = NSSize(width: imgSize, height: imgSize); return im
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: sf, weight: .semibold))
    }
    func makeChip(_ name: String, _ symbol: String, selected: Bool, id: String, badge: Int = 0) -> ChipButton {
        let b = ChipButton(); b.chipId = id
        b.isBordered = false; b.bezelStyle = .regularSquare; b.imagePosition = name.isEmpty ? .imageOnly : .imageLeading
        b.imageHugsTitle = true
        b.image = colIcon(symbol, sf: 12, img: 16)
        let titleColor: NSColor = selected ? .white : NSColor.white.withAlphaComponent(0.82)
        let f = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let title = NSMutableAttributedString(string: name.isEmpty ? "" : "  " + name, attributes: [.font: f, .foregroundColor: titleColor])
        var badgeW: CGFloat = 0
        if badge > 0 {   // gruene Zaehler-Plakette hinter dem Namen (neu vom Partner)
            let img = newBadgeImage(badge)
            let att = NSTextAttachment(); att.image = img
            att.bounds = NSRect(x: 0, y: -4, width: img.size.width, height: img.size.height)
            title.append(NSAttributedString(string: "  ", attributes: [.font: f]))
            title.append(NSAttributedString(attachment: att))
            badgeW = img.size.width + "  ".size(withAttributes: [.font: f]).width
            b.toolTip = badge == 1 ? "1 neuer Eintrag von \(SharedVault.shared.partner)" : "\(badge) neue Einträge von \(SharedVault.shared.partner)"
        }
        b.attributedTitle = title
        b.contentTintColor = titleColor
        b.wantsLayer = true; b.layer?.cornerRadius = 14
        b.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.white.withAlphaComponent(0.10).cgColor
        let tw = name.isEmpty ? 0 : name.size(withAttributes: [.font: f]).width
        b.frame = NSRect(x: 0, y: 0, width: name.isEmpty ? 36 : (tw + 50 + badgeW), height: 28)
        b.target = self; b.action = #selector(chipClicked(_:))
        return b
    }
    @objc func chipClicked(_ sender: ChipButton) {
        if sender.chipId == "__new__" { promptNewCollection(assignItemId: nil); return }
        currentCollection = sender.chipId.isEmpty ? nil : sender.chipId
        reload(); buildChips()
    }
    @discardableResult func promptNewCollection(assignItemId: String?) -> Collection? {
        let alert = NSAlert()
        alert.messageText = "Neuer Bereich"
        alert.informativeText = "Name und Icon wählen."
        let acc = NSView(frame: NSRect(x:0,y:0,width:270,height:62))
        let nameField = NSTextField(frame: NSRect(x:0,y:32,width:270,height:24))
        nameField.placeholderString = "z.B. Arbeit, Cursor, AI, Passwörter…"
        let popup = NSPopUpButton(frame: NSRect(x:0,y:0,width:270,height:26))
        let symbols = ["img:ki_logo.png","sparkles","brain.head.profile","briefcase.fill","lock.fill","key.fill","terminal.fill","chevron.left.forwardslash.chevron.right","cursorarrow.rays","folder.fill","star.fill","bolt.fill","doc.text.fill","tag.fill","person.fill","heart.fill","flag.fill"]
        for s in symbols {
            let mi = NSMenuItem(title: s.hasPrefix("img:") ? "KI-Logo" : s, action: nil, keyEquivalent: "")
            mi.image = colIcon(s, sf: 14, img: 16)
            popup.menu?.addItem(mi)
        }
        acc.addSubview(nameField); acc.addSubview(popup)
        alert.accessoryView = acc
        alert.addButton(withTitle: "Erstellen"); alert.addButton(withTitle: "Abbrechen")
        panel.makeKeyAndOrderFront(nil)
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let symbol = symbols[max(0, popup.indexOfSelectedItem)]
        let c = Store.shared.addCollection(name: name, symbol: symbol)
        if let iid = assignItemId { Store.shared.setCollection(itemId: iid, collectionId: c.id) }
        else { currentCollection = c.id }
        reload(); buildChips()
        return c
    }

    func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Heute" }
        if cal.isDateInYesterday(d) { return "Gestern" }
        return dayFmt.string(from: d)
    }
    func buildDisplay() {
        display = []
        defer {
            quickIndex = [:]
            var n = 0
            for r in display { if let id = rowId(r), n < 9 { n += 1; quickIndex[id] = n } }
            let count = display.filter { rowId($0) != nil }.count
            countLabel.stringValue = count == 1 ? "1 Eintrag" : "\(count) Einträge"
            updateSeenControls()
        }
        if currentCollection == SHARED_CHIP {  // Geteilt: Eintraege aus dem geteilten Tresor
            let q = search.stringValue.lowercased()
            let list = SharedVault.shared.visible.filter { s in
                passesType(s) && (q.isEmpty || (s.text ?? "").lowercased().contains(q) || (s.fileName ?? "").lowercased().contains(q))
            }
            let pinned = list.filter { $0.pinned }
            if !pinned.isEmpty { display.append(.header("Angeheftet")); pinned.forEach { display.append(.shared($0)) } }
            var lastKey = ""
            for s in list where !s.pinned {
                let key = String(Int(Calendar.current.startOfDay(for: s.updatedAt).timeIntervalSince1970))
                if key != lastKey { display.append(.header(dayLabel(s.updatedAt))); lastKey = key }
                display.append(.shared(s))
            }
            return
        }
        if let cc = currentCollection {  // Bereich-Ansicht: nur Items dieses Bereichs
            var lastKey = ""
            for it in filtered where it.collection == cc {
                let key = String(Int(Calendar.current.startOfDay(for: it.date).timeIntervalSince1970))
                if key != lastKey { display.append(.header(dayLabel(it.date))); lastKey = key }
                display.append(.item(it))
            }
            return
        }
        // Verlauf: nur Items OHNE Bereich; angeheftete oben
        let hist = filtered.filter { $0.collection == nil }
        let pinned = hist.filter { $0.pinned }
        if !pinned.isEmpty {
            display.append(.header("Angeheftet"))
            for it in pinned { display.append(.item(it)) }
        }
        var lastKey = ""
        for it in hist where !it.pinned {
            let key = String(Int(Calendar.current.startOfDay(for: it.date).timeIntervalSince1970))
            if key != lastKey { display.append(.header(dayLabel(it.date))); lastKey = key }
            display.append(.item(it))
        }
    }
    func reload() {
        expandedRowCollapse = nil   // alte Zeilen-Views werden neu gebaut -> Hover-Referenz zurücksetzen
        newMarkers = [:]; transferMarkers = [:]
        layoutForSharedView()
        if editingId != nil { finishEditUI() }
        let q = search.stringValue.lowercased()
        filtered = Store.shared.items.filter { it in
            passesType(it) && (q.isEmpty
                || (it.text ?? "").lowercased().contains(q)
                || (it.ocrText ?? "").lowercased().contains(q)
                || ((it.files?.contains { $0.name.lowercased().contains(q) }) ?? false))
        }
        buildDisplay(); pruneSelection(); table.reloadData()
        if let first = firstItemRow() { selectRow(first) } else { showEmpty() }
    }
    func reloadIfVisible() { if panel.isVisible { reload() } }
    func toggle(on s: NSScreen) { if panel.isVisible { hide() } else { show(on: s) } }
    var clickMonitor: Any?
    var keyMonitor: Any?
    func show(on s: NSScreen) {
        let f = s.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - W/2, y: f.midY - H/2 + f.height*0.10))
        search.stringValue = ""; currentCollection = nil; typeFilter = .all; revealSecrets = false; previewHover = false
        multi.clear(); updateSelectionBar()
        SharedSeen.shared.reload()   // andere Programme markieren ebenfalls als gesehen
        buildChips(); buildFilters(); reload()
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hide() }
        // Wahltaste (⌥) halten = Passwoerter zeigen
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            guard let self = self else { return e }
            let alt = e.modifierFlags.contains(.option)
            if alt != self.revealSecrets { self.revealSecrets = alt; self.secretRevealChanged() }
            return e
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self = self else { return e }
            let cmd = e.modifierFlags.contains(.command)
            let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
            // ---- Bearbeiten-Modus: Tasten gehoeren dem Textfeld ----
            if self.editingId != nil, self.panel.isKeyWindow {
                if e.keyCode == 53 { self.endEdit(save: false); return nil }                              // Esc
                if cmd, e.keyCode == 36 || e.keyCode == 76 { self.endEdit(save: true, copyAfter: true); return nil }  // Cmd+Enter
                if cmd, ch == "s" { self.endEdit(save: true); return nil }
                if cmd, let tv = self.panel.firstResponder as? NSTextView {
                    switch ch {
                    case "c": if tv.selectedRange().length > 0 { self.copyPlain((tv.string as NSString).substring(with: tv.selectedRange())) }; return nil
                    case "x": if tv.selectedRange().length > 0 { self.copyPlain((tv.string as NSString).substring(with: tv.selectedRange())); tv.delete(nil) }; return nil
                    case "v": tv.pasteAsPlainText(nil); return nil
                    case "a": tv.selectAll(nil); return nil
                    case "z": if e.modifierFlags.contains(.shift) { tv.undoManager?.redo() } else { tv.undoManager?.undo() }; return nil
                    default: break
                    }
                }
                return e
            }
            if cmd, ch == "p" { self.togglePinSelected(); return nil }
            if cmd, ch == "j" { self.toggleShareSelected(); return nil }   // Cmd+J: mit dem Partner teilen / zuruecknehmen
            if cmd, e.keyCode == 51 { self.deleteSelected(); return nil }  // Cmd+⌫ löschen
            if self.panel.isKeyWindow {   // nicht während NSAlert (Neuer Bereich) abfangen
                // Mehrfachauswahl: ⌘A = alle im aktuellen Filter (ausser im Vorschautext), ⌘C/Enter = alle kopieren, Esc = aufheben
                let plain = e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                if cmd, ch == "a", !(self.panel.firstResponder === self.prevText) { self.selectAllVisible(); return nil }
                if self.multi.isActive {
                    if cmd, ch == "c" { self.copyAllSelected(close: false); return nil }
                    if plain, e.keyCode == 36 || e.keyCode == 76 { self.copyAllSelected(close: true); return nil }
                    if e.keyCode == 53 { if !ActionBar.collapseActive() { self.clearSelection() }; return nil }   // offene Leiste zuerst zu
                }
                // Cmd+1…9: n-ten Eintrag kopieren und schliessen
                if cmd, !e.modifierFlags.contains(.shift), let n = Int(ch), (1...9).contains(n) { self.quickPaste(n); return nil }
                // Cmd+E: Text-Eintrag bearbeiten
                if cmd, ch == "e", let it = self.selectedClip(), it.kind == .text { self.beginEdit(it); return nil }
                // Cmd+V im Suchfeld: einfuegen (App hat kein Bearbeiten-Menue)
                if cmd, ch == "v", let tv = self.panel.firstResponder as? NSTextView, tv.isEditable { tv.pasteAsPlainText(nil); return nil }
                // Cmd+C: markierten Text-Bereich kopieren, sonst ganzen Eintrag — Panel bleibt offen
                if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "c" { self.copySelectionOrItem(); return nil }
                // Cmd+A: alles markieren (Vorschau oder Suchfeld — je nach Fokus)
                if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "a" {
                    if let tv = self.panel.firstResponder as? NSTextView { tv.selectAll(nil); return nil }
                }
                if e.keyCode == 53, ActionBar.collapseActive() { return nil }   // Esc: offene Aktions-Leiste zuerst zuklappen
                if e.keyCode == 53 { self.hide(); return nil }  // Esc überall, auch mit Fokus in der Vorschau
                // Leertaste auf einem Bild = Quick Look (wie im Finder) – nicht, während im Suchfeld getippt wird
                if e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                   self.search.stringValue.isEmpty || !(self.panel.firstResponder === self.search.currentEditor()),
                   self.previewImageFile() != nil, self.quickLookPreview(toggle: true) { return nil }
            }
            return e
        }
    }
    func hide() {
        if editingId != nil { finishEditUI() }   // ungespeicherte Bearbeitung verwerfen
        clearSelection(refresh: false)           // Auswahl gilt nur, solange das Panel offen ist
        CVQuickLook.shared.close()
        panel.orderOut(nil)
        seenTimer?.invalidate(); seenTimer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        revealSecrets = false; previewHover = false
    }
    func selectedClip() -> ClipItem? {
        let r = table.selectedRow
        guard r >= 0, r < display.count, case .item(let it) = display[r] else { return nil }
        return it
    }
    func quickPaste(_ n: Int) {
        let rows = itemRows(); guard n - 1 < rows.count else { return }
        switch display[rows[n - 1]] {
        case .item(let it): choose(it)
        case .shared(let s): chooseShared(s)
        case .header: break
        }
    }
    // ===== Passwoerter: verborgen bis Maus ueber Vorschau / ⌥ =====
    func isMasked(_ it: ClipItem) -> Bool { Store.shared.isSecret(it.collection) && !revealSecrets }
    func secretRevealChanged() {
        let rows = IndexSet(display.indices.filter { if case .item(let it) = display[$0] { return Store.shared.isSecret(it.collection) }; return false })
        if !rows.isEmpty { expandedRowCollapse = nil; table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
        refreshPreviewIfSecret()
    }
    func setPreviewHover(_ h: Bool) {
        guard previewHover != h else { return }
        previewHover = h; refreshPreviewIfSecret()
    }
    func refreshPreviewIfSecret() {
        guard editingId == nil, let id = previewItemId, let it = Store.shared.item(id), Store.shared.isSecret(it.collection) else { return }
        showPreview(it)
    }

    // rows
    func itemRows() -> [Int] { display.indices.filter { rowId(display[$0]) != nil } }
    func firstItemRow() -> Int? { itemRows().first }
    func numberOfRows(in t: NSTableView) -> Int { display.count }
    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { if case .header = display[row] { return 32 }; return 62 }
    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool { if case .header = display[row] { return true }; return false }
    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { rowId(display[row]) != nil }
    // ===== Drag-out: Eintrag aus ClipVault in andere Apps ziehen =====
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < display.count else { return nil }
        if case .shared(let sh) = display[row] {
            switch sh.kind {
            case .text, .link: return (sh.text ?? "") as NSString
            case .image, .file: return SharedVault.shared.localURL(sh).map { $0 as NSURL }   // echte Datei (Finder, Mail, WhatsApp …)
            }
        }
        guard case .item(let it) = display[row] else { return nil }
        switch it.kind {
        case .text:
            return (it.text ?? "") as NSString
        case .image:
            if let f = it.imageFile {
                let url = Store.shared.dir.appendingPathComponent(f)
                if FileManager.default.fileExists(atPath: url.path) { return url as NSURL }
            }
            return it.thumb
        case .file:
            if let r = it.files?.first {
                if FileManager.default.fileExists(atPath: r.orig) { return NSURL(fileURLWithPath: r.orig) }
                if let st = r.stored { let p = Store.shared.dir.appendingPathComponent(st).path; if FileManager.default.fileExists(atPath: p) { return NSURL(fileURLWithPath: p) } }
            }
            return nil
        }
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { hide() }  // erfolgreich rausgezogen -> Panel schliessen
    }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        switch display[row] {
        case .header(let title): return makeHeader(title)
        case .item(let it): let v = makeItemRow(it, row: row); decorateForSelection(v, id: it.id); return v
        case .shared(let sh): let v = makeSharedRow(sh, row: row); decorateForSelection(v, id: sh.id); return v
        }
    }
    func makeHeader(_ title: String) -> NSView {
        let v = NSView(frame: NSRect(x:0,y:0,width: leftW-24, height: 32))
        let pinned = (title == "Angeheftet")
        var lx: CGFloat = 16
        if pinned {
            let pv = NSImageView(frame: NSRect(x: 16, y: 10, width: 12, height: 12))
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            pv.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            pv.contentTintColor = NSColor.systemYellow
            v.addSubview(pv); lx = 34
        }
        let l = NSTextField(labelWithString: title.uppercased())
        l.frame = NSRect(x: lx, y: 9, width: leftW-44-lx, height: 16)
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = pinned ? NSColor.systemYellow.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.45)
        v.addSubview(l); return v
    }
    func makeItemRow(_ item: ClipItem, row: Int) -> NSView {
        let rowH: CGFloat = 62
        let v = HoverRowView(frame: NSRect(x:0,y:0,width: leftW-24, height: rowH))
        let isKI = (item.source == "KI")
        let isPhone = (item.source == "iPhone")
        let isVoice = (item.source == "Diktat" || item.source == "Meeting")
        // Thumbnail / Icon links
        let iconSize: CGFloat = 42
        let icon = NSImageView(frame: NSRect(x: 14, y: (rowH-iconSize)/2, width: iconSize, height: iconSize))
        icon.wantsLayer = true; icon.layer?.cornerRadius = 9; icon.layer?.masksToBounds = true; icon.imageScaling = .scaleProportionallyUpOrDown
        let masked = isMasked(item)
        let badges = masked ? [] : item.badges
        let swatch = badges.contains(.color) ? parseColor(item.text ?? "") : nil
        if masked {
            let cfg = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            icon.contentTintColor = NSColor.systemYellow.withAlphaComponent(0.9)
        }
        else if let c = swatch { icon.image = colorSwatch(c, size: NSSize(width: 42, height: 42), radius: 9) }
        else if item.kind == .image, let th = item.thumb { icon.image = th }
        else if item.kind == .file, let th = item.thumb { icon.image = th }
        else if item.kind == .text, let u = soleURL(item.text), let snap = LinkPreview.shared.cachedImage(u) {
            icon.image = snap   // Mini-Screenshot der Website
        }
        else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
            let isLink = (item.kind == .text && soleURL(item.text) != nil)
            // Quelle (Diktat/iPhone/KI) zuerst, dann erkannte Sorte (E-Mail/Telefon/Code), sonst Text
            let smart = badges.first(where: { $0 == .email || $0 == .phone || $0 == .code })
            let sym = isVoice ? (item.source == "Meeting" ? "person.2.wave.2" : "waveform") : (isPhone ? "iphone" : (isKI ? "sparkles" : (isLink ? "globe" : (smart?.symbol ?? "doc.text"))))
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            icon.contentTintColor = isVoice ? NSColor.systemOrange : (isPhone ? NSColor.systemBlue : (isKI ? NSColor.systemPurple : (isLink ? NSColor.systemTeal : (smart?.tint ?? NSColor.white.withAlphaComponent(0.85)))))
        }
        v.addSubview(icon)
        // Titel + Untertitel
        let textX: CGFloat = 14 + iconSize + 14
        let quick = quickIndex[item.id]
        let pinReserve: CGFloat = quick != nil ? 92 : 64  // klarer Abstand, Text läuft nie in Pin/Kürzel
        let textW = (leftW-24) - textX - pinReserve
        let label = NSTextField(labelWithString: masked ? "••••••••••••" : preview1(item))
        label.frame = NSRect(x: textX, y: 32, width: textW, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .regular); label.textColor = .white
        label.usesSingleLineMode = true; label.maximumNumberOfLines = 1
        label.lineBreakMode = (item.kind == .file) ? .byTruncatingMiddle : .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        v.addSubview(label)
        let sub = NSTextField(labelWithString: "")
        sub.frame = NSRect(x: textX, y: 11, width: textW, height: 16)
        sub.usesSingleLineMode = true; sub.maximumNumberOfLines = 1; sub.lineBreakMode = .byTruncatingTail
        sub.attributedStringValue = sublineAttr(item, badges: badges, masked: masked)
        v.addSubview(sub)
        // Kuerzel Cmd+1…9 (dezent, links neben dem Pin; beim Hovern ausgeblendet)
        var quickHint: NSTextField?
        if let q = quick {
            let hint = NSTextField(labelWithString: "⌘\(q)"); quickHint = hint
            hint.font = .systemFont(ofSize: 11, weight: .medium); hint.textColor = NSColor.white.withAlphaComponent(0.30)
            hint.alignment = .right
            hint.frame = NSRect(x: (leftW-24) - 12 - 6 - 26 - 34, y: (rowH-16)/2, width: 30, height: 16)
            hint.autoresizingMask = [.minXMargin]   // wandert mit der Pille, wenn die Zeile schmaler wird
            v.addSubview(hint)
        }
        // ===== Aktionen rechts: EIN Griff (•••) — Bereiche · Teilen · Papierkorb · Pin erst nach langem Druecken (actionbar.swift) =====
        let iid = item.id
        var acts: [ActionBarItem] = []
        for c in Store.shared.collections.prefix(6) {
            let inThis = (item.collection == c.id), cid = c.id
            acts.append(ActionBarItem(image: colIcon(c.symbol, sf: 12, img: 19),
                tint: inThis ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.9),
                fill: inThis ? NSColor.controlAccentColor.withAlphaComponent(0.28) : nil,
                tip: inThis ? "Aus „\(c.name)\" entfernen" : "In „\(c.name)\" legen",
                action: { [weak self] in self?.quickAssign(itemId: iid, collectionId: cid) }))
        }
        // Mit dem Partner teilen (geteilt = Tuerkis wie das Etikett „GETEILT"; Klick nimmt die Freigabe zurueck)
        acts.append(ActionBarItem(image: NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Teilen")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)),
            tint: item.shared ? NSColor.systemTeal : NSColor.white.withAlphaComponent(0.9),
            fill: item.shared ? NSColor.systemTeal.withAlphaComponent(0.26) : nil,
            tip: item.shared ? "Nicht mehr mit \(SharedVault.shared.partner) teilen (Cmd+J)" : "Mit \(SharedVault.shared.partner) teilen (Cmd+J)",
            action: { [weak self] in self?.toggleShare(iid) }))
        acts.append(ActionBarItem(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Löschen")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)),
            tint: NSColor.systemRed.withAlphaComponent(0.9), tip: "Löschen (Cmd+⌫)",
            action: { [weak self] in self?.deleteItem(iid) }))
        // Pin: auch ohne Hover sichtbar (Status), letzter Platz ganz rechts
        acts.append(ActionBarItem(image: NSImage(systemSymbolName: item.pinned ? "pin.fill" : "pin", accessibilityDescription: "Anheften")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)),
            tint: item.pinned ? NSColor.systemYellow : .white,
            restTint: item.pinned ? NSColor.systemYellow : NSColor.white.withAlphaComponent(0.5),
            tip: item.pinned ? "Lösen (Cmd+P)" : "Anheften (Cmd+P)", showAtRest: true, badge: item.pinned,
            action: { [weak self] in self?.togglePin(iid) }))
        let bar = makeActionBar(acts, rowH: rowH, row: row)
        v.addSubview(bar)
        v.onHover = { [weak self] in
            guard let self = self, self.editingId == nil else { return }   // beim Bearbeiten Auswahl festhalten
            self.expandedRowCollapse?()        // vorher offene Leiste IMMER zuerst schließen -> nie zwei offen
            self.selectRow(row)
            // ⌘n-Kuerzel beim Hovern ausblenden (frueher deckte es die Pille ab; jetzt sitzt dort der Pin-Status)
            bar.setRowHovered(true); quickHint?.isHidden = true
            self.expandedRowCollapse = { [weak bar, weak quickHint] in bar?.setRowHovered(false); quickHint?.isHidden = false }
        }
        v.onExit = { [weak bar, weak quickHint] in bar?.setRowHovered(false); quickHint?.isHidden = false }
        return v
    }
    /// Aktions-Leiste rechtsbuendig in der Zeile (gleiche Stelle wie die alte Pille)
    func makeActionBar(_ acts: [ActionBarItem], rowH: CGFloat, row: Int) -> ActionBar {
        let w = ActionBar.frameWidth(acts.count)
        let bar = ActionBar(frame: NSRect(x: (leftW-24) - 12 - w, y: (rowH - ActionBar.pillH)/2, width: w, height: ActionBar.pillH), items: acts)
        bar.autoresizingMask = [.minXMargin]
        return bar
    }
    // ===== Mit dem Partner teilen (Pille, Vorschau, Cmd+J, Rechtsklick) =====
    /// Umschalter: nicht geteilt -> teilen, geteilt -> Freigabe zuruecknehmen. Ohne Kopplung bleibt es „wartet auf Sync".
    func toggleShare(_ id: String) {
        guard let it = Store.shared.item(id) else { return }
        if it.shared {
            SharedVaultHook.unshare(id); Toast.shared.show("Nicht mehr geteilt")
        } else {
            switch SharedVaultHook.share(it) {
            case .success: Toast.shared.show("Mit \(SharedVault.shared.partner) geteilt")
            case .failure(let e): Toast.shared.show(e.message)
            }
        }
        reload()
        if let idx = display.firstIndex(where: { if case .item(let x) = $0 { return x.id == id }; return false }) { selectRow(idx) }
    }
    @objc func sharePreviewClicked() { if let id = previewItemId, Store.shared.item(id) != nil { toggleShare(id) } }
    func toggleShareSelected() {
        let r = table.selectedRow
        guard r >= 0, r < display.count else { return }
        if case .shared(let sh) = display[r] { SharedVaultHook.unshare(sh.id); Toast.shared.show("Nicht mehr geteilt"); reload(); return }
        if case .item(let it) = display[r] { toggleShare(it.id) }
    }
    /// Vorschau-Knopf: „Teilen" bzw. hervorgehoben „Geteilt"
    func updateShareButton(_ item: ClipItem) {
        let on = item.shared
        let f = NSFont.systemFont(ofSize: 12, weight: .medium)
        let title = on ? " Geteilt" : " Teilen"
        shareBtn.attributedTitle = NSAttributedString(string: title, attributes: [.font: f, .foregroundColor: NSColor.white])
        shareBtn.layer?.backgroundColor = (on ? NSColor.systemTeal.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.13)).cgColor
        shareBtn.image = NSImage(systemSymbolName: on ? "person.2.fill" : "person.2", accessibilityDescription: title)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        shareBtn.toolTip = on ? "Geteilt mit \(SharedVault.shared.partner) — klicken zum Zuruecknehmen (Cmd+J)" : "Mit \(SharedVault.shared.partner) teilen (Cmd+J)"
        shareBtn.setFrameSize(NSSize(width: title.size(withAttributes: [.font: f]).width + 38, height: 28))
        shareBtn.isHidden = false
    }
    func deleteItem(_ iid: String) {
        Store.shared.delete(id: iid); reload(); buildChips()
    }
    func deleteSelected() {
        let r = table.selectedRow
        guard r >= 0, r < display.count else { return }
        if case .shared(let sh) = display[r] { SharedVaultHook.unshare(sh.id); reload(); return }
        guard case .item(let it) = display[r] else { return }
        Store.shared.delete(id: it.id); reload(); buildChips()
    }
    func quickAssign(itemId iid: String, collectionId cid: String) {
        let cur = Store.shared.items.first(where: { $0.id == iid })?.collection
        if cur == cid { Store.shared.setCollection(itemId: iid, collectionId: nil) }   // schon drin -> raus
        else { Store.shared.setCollection(itemId: iid, collectionId: cid); Toast.shared.show("In Bereich gelegt") }
        reload(); buildChips()
    }
    func togglePin(_ id: String) {
        guard let it = Store.shared.items.first(where: { $0.id == id }) else { return }
        Store.shared.togglePin(it); reload()
        if let idx = display.firstIndex(where: { if case .item(let x) = $0 { return x.id == id }; return false }) { selectRow(idx) }
    }
    func togglePinSelected() {
        let r = table.selectedRow
        guard r >= 0, r < display.count else { return }
        if case .shared(let sh) = display[r] { SharedVaultHook.setPinned(sh.id, !sh.pinned); reload(); return }
        guard case .item(let it) = display[r] else { return }
        Store.shared.togglePin(it); reload()
        if let idx = display.firstIndex(where: { if case .item(let x) = $0 { return x.id == it.id }; return false }) { selectRow(idx, scroll: true) }
    }
    /// Untertitel: [Sorte-Badges] · [Geteilt] · Zeit   (Passwort: verborgen · Ablauf)
    func sublineAttr(_ item: ClipItem, badges: [Badge], masked: Bool) -> NSAttributedString {
        let f = NSFont.systemFont(ofSize: 11.5), fb = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let dim: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white.withAlphaComponent(0.48)]
        let out = NSMutableAttributedString()
        func tag(_ s: String, _ c: NSColor) {
            out.append(NSAttributedString(string: s.uppercased(), attributes: [.font: fb, .foregroundColor: c, .kern: 0.4]))
            out.append(NSAttributedString(string: "  ·  ", attributes: dim))
        }
        if Store.shared.isSecret(item.collection) {
            tag(masked ? "Verborgen" : "Sichtbar", NSColor.systemYellow.withAlphaComponent(0.85))
            if let exp = Store.shared.secretExpiry(item) {
                let h = max(0, Int(ceil(exp.timeIntervalSinceNow / 3600)))
                out.append(NSAttributedString(string: h <= 1 ? "läuft in < 1 Std ab" : "läuft in \(h) Std ab", attributes: dim))
            } else { out.append(NSAttributedString(string: "angeheftet · läuft nicht ab", attributes: dim)) }
            return out
        }
        for b in badges.prefix(2) where !(b == .link && soleURL(item.text) != nil) { tag(b.label, b.tint) }
        if item.kind == .image, let o = item.ocrText, !o.isEmpty { tag("Text", NSColor.white.withAlphaComponent(0.62)) }
        if item.shared { tag("Geteilt", .systemTeal) }
        if item.edited != nil { tag("Bearbeitet", NSColor.white.withAlphaComponent(0.62)) }
        out.append(NSAttributedString(string: subline(item), attributes: dim))
        return out
    }
    func preview1(_ item: ClipItem) -> String {
        if item.kind == .image {
            // erkannter Text macht Bilder in der Liste unterscheidbar ("Bild · Rechnung Mai 2026")
            if let o = item.ocrText?.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).count >= 3 }) {
                return "Bild · " + String(o.prefix(70))
            }
            return "Bild"
        }
        if item.kind == .file, let fs = item.files { return fs.count == 1 ? fs[0].name : "\(fs.count) Dateien" }
        let t = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Link mit bekanntem Seitentitel -> Titel statt kryptischer URL
        if let u = soleURL(t), let title = LinkPreview.shared.title(u), !title.isEmpty { return String(title.prefix(80)) }
        return String((t.split(separator: "\n").first.map(String.init) ?? t).prefix(80))
    }
    func subline(_ item: ClipItem) -> String {
        if item.kind == .file, let fs = item.files {
            let ext = (fs[0].name as NSString).pathExtension.uppercased()
            let kind = fs.count > 1 ? "\(fs.count) Dateien" : (ext.isEmpty ? "Datei" : ext)
            return "\(kind)  ·  \(shortTime(item.date))"
        }
        if item.kind == .text, let u = soleURL(item.text) { return "\(u.host ?? "Link")  ·  \(shortTime(item.date))" }
        return shortTime(item.date)
    }
    func shortTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "gerade eben" }; if s < 3600 { return "vor \(s/60) Min" }
        if Calendar.current.isDateInToday(d) { return "vor \(s/3600) Std" }
        let f = DateFormatter(); f.locale = Locale(identifier:"de_DE"); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    func selectRow(_ displayIndex: Int, scroll: Bool = false) {
        guard displayIndex >= 0 && displayIndex < display.count, rowId(display[displayIndex]) != nil else { return }
        table.selectRowIndexes(IndexSet(integer: displayIndex), byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(displayIndex) }
        switch display[displayIndex] {
        case .item(let it): showPreview(it)
        case .shared(let sh): showSharedPreview(sh)
        case .header: break
        }
    }
    func showEmpty() {
        if currentCollection == SHARED_CHIP {
            if let ui = SharedVaultHook.backend as? SharedVaultPanelUI {
                emptyLabel.stringValue = "Noch nichts geteilt.\n\(ui.panelStatusText)\nRechtsklick auf einen Eintrag → „Mit \(SharedVault.shared.partner) teilen\"."
            } else {
            emptyLabel.stringValue = SharedVaultHook.backend == nil
                ? "Noch nichts geteilt.\nRechtsklick auf einen Eintrag → „Mit \(SharedVault.shared.partner) teilen\".\n(Die Synchronisierung wird noch eingerichtet.)"
                : "Noch nichts geteilt.\nRechtsklick auf einen Eintrag → „Mit \(SharedVault.shared.partner) teilen\"."
            }
        } else if typeFilter != .all || !search.stringValue.isEmpty {
            emptyLabel.stringValue = "Keine Treffer."
        } else {
            emptyLabel.stringValue = currentCollection != nil
                ? "Bereich noch leer.\nEinträge per Rechtsklick → „In Bereich legen\" hinzufügen."
                : "Noch nichts kopiert."
        }
        resetPreviewChrome()
        emptyLabel.isHidden = false; prevHeader.stringValue = ""; prevScroll.isHidden = true; prevImage.isHidden = true
        copyBtn.isHidden = true; previewURL = nil; previewItemId = nil
        if currentCollection == SHARED_CHIP, let ui = SharedVaultHook.backend as? SharedVaultPanelUI { pairBtn.isHidden = !ui.wantsPairButton }
    }
    /// Alles Zusaetzliche der Vorschau ausblenden (jede Vorschau blendet dann ein, was sie braucht)
    @objc func pairClicked() { (SharedVaultHook.backend as? SharedVaultPanelUI)?.presentPairingDialog() }
    func resetPreviewChrome() {
        seenTimer?.invalidate(); seenTimer = nil      // Vorschau wechselt -> Verweilen beginnt neu
        pairBtn.isHidden = true; shareBtn.isHidden = true
        loadBtn.isHidden = true; saveDlBtn.isHidden = true; prevProgress.isHidden = true
        finderBtn.isHidden = true; editBtn.isHidden = true; saveBtn.isHidden = true; cancelBtn.isHidden = true; openBtn.isHidden = true
        prevImage.toolTip = nil
        ocrLabel.isHidden = true; ocrCopyBtn.isHidden = true
        prevText.isSelectable = true
    }
    func showPreview(_ item: ClipItem) {
        if editingId != nil && editingId != item.id { return }
        emptyLabel.isHidden = true
        resetPreviewChrome()
        copyBtn.isHidden = false
        updateShareButton(item)
        previewURL = nil
        previewItemId = item.id
        defer { layoutTopButtons() }
        if item.kind == .text && Store.shared.isSecret(item.collection) && !(revealSecrets || previewHover) { showMaskedPreview(item); return }
        if item.kind == .text, let u = soleURL(item.text) { showLinkPreview(item, url: u); return }
        if item.kind == .text, let c = parseColor(item.text ?? "") { showColorPreview(item, color: c); return }
        if item.kind == .image { showImagePreview(item); return }
        if item.kind == .file, let refs = item.files {
            finderBtn.isHidden = Store.shared.fileURL(item) == nil
            prevHeader.attributedStringValue = headerAttr(item, kindStr: fileKindLabel(refs))
            let dh: CGFloat = 96
            prevScroll.frame = NSRect(x: prevX, y: 14, width: prevW, height: dh)
            prevImage.frame = NSRect(x: prevX, y: 14 + dh + 8, width: prevW, height: fullPrevFrame.height - dh - 8)
            prevImage.image = item.bigThumb ?? item.thumb
            prevImage.isHidden = false; prevScroll.isHidden = false
            setPreviewText(fileDetails(refs), links: false, query: nil)
            if item.bigThumb == nil { loadBigThumb(item) }
        } else {
            prevScroll.frame = fullPrevFrame; prevImage.frame = fullPrevFrame
            do {   // Text
                editBtn.isHidden = item.kind != .text
                let t = cleanedForDisplay(item.text ?? "")
                var extra = ""
                if !t.isEmpty {
                    let words = t.split(whereSeparator: { $0.isWhitespace }).count
                    extra = "  ·  " + (numFmt.string(from: NSNumber(value: t.count)) ?? String(t.count)) + " Zeichen"
                    if words > 1 { extra += " · " + (numFmt.string(from: NSNumber(value: words)) ?? String(words)) + " Wörter" }
                }
                prevHeader.attributedStringValue = headerAttr(item, kindStr: "Text", extra: extra)
                setPreviewText(t, links: true, query: search.stringValue)
                prevScroll.isHidden = false; prevImage.isHidden = true
            }
        }
    }
    /// Bild passgenau (Seitenverhältnis) in einen Bereich setzen -> Rahmen umschließt das Bild,
    /// weiße Bilder sind klar abgegrenzt statt in grauer Fläche zu verschwimmen
    func fitImage(_ img: NSImage, pixel s: NSSize, in pane: NSRect) {
        let sc = min(pane.width / max(s.width, 1), pane.height / max(s.height, 1))
        let w = max(1, s.width * sc), h = max(1, s.height * sc)
        prevImage.frame = NSRect(x: pane.minX + (pane.width - w) / 2, y: pane.minY + (pane.height - h) / 2, width: w, height: h)
        prevImage.image = img; prevImage.isHidden = false
        placeOpenButton()
    }
    /// „Öffnen" unten rechts ins Bild (bei sehr kleinen Bildern darunter)
    func placeOpenButton() {
        let f = prevImage.frame, b = openBtn.frame.size
        if f.width >= b.width + 24 && f.height >= b.height + 24 {
            openBtn.setFrameOrigin(NSPoint(x: f.maxX - b.width - 10, y: f.minY + 10))
        } else {
            openBtn.setFrameOrigin(NSPoint(x: f.maxX - b.width, y: max(14, f.minY - b.height - 6)))
        }
    }
    // ===== Bild: Vorschau + erkannter Text (OCR) =====
    func showImagePreview(_ item: ClipItem) {
        finderBtn.isHidden = Store.shared.imageURL(item) == nil
        openBtn.isHidden = finderBtn.isHidden
        prevImage.toolTip = "Klick: groß ansehen (Quick Look) · Leertaste: Quick Look · ← → blättert"
        guard let url = Store.shared.imageURL(item), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            prevHeader.attributedStringValue = headerAttr(item, kindStr: "Bild", extra: "  ·  Datei fehlt")
            prevImage.isHidden = true; prevScroll.isHidden = true; return
        }
        // Pixelmaße ohne das Bild zu dekodieren; Anzeige über ImageIO-Thumb (max. 1600 px) statt Vollbild im RAM
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0, ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let img = loadThumb(url: url, maxPx: 1600) ?? NSImage()
        if item.ocrText == nil { OCR.shared.enqueue(item) }
        let busy = OCR.shared.isBusy(item.id)
        let text = item.ocrText ?? ""
        var extra = "  ·  \(pw)×\(ph) px"
        if !busy && item.ocrText != nil && text.isEmpty { extra += "  ·  kein Text erkannt" }
        prevHeader.attributedStringValue = headerAttr(item, kindStr: "Bild", extra: extra)
        let pxs = NSSize(width: pw, height: ph)
        if busy || !text.isEmpty {
            // oben Bild, darunter "ERKANNTER TEXT" + Knopf, darunter der Text (markierbar, Cmd+C kopiert Auswahl)
            let textH: CGFloat = 150, barH: CGFloat = 26
            prevScroll.frame = NSRect(x: prevX, y: 14, width: prevW, height: textH)
            let barY = 14 + textH + 6
            ocrLabel.frame = NSRect(x: prevX + 4, y: barY + 5, width: 200, height: 16)
            ocrLabel.stringValue = busy ? "TEXT WIRD ERKANNT …" : "ERKANNTER TEXT"
            ocrLabel.isHidden = false
            ocrCopyBtn.setFrameOrigin(NSPoint(x: prevX + prevW - ocrCopyBtn.frame.width, y: barY))
            ocrCopyBtn.isHidden = busy
            let imgPane = NSRect(x: prevX, y: barY + barH + 8, width: prevW, height: fullPrevFrame.maxY - (barY + barH + 8))
            fitImage(img, pixel: pxs, in: imgPane)
            setPreviewText(busy ? "" : text, links: true, query: search.stringValue)
            prevScroll.isHidden = false
        } else {
            fitImage(img, pixel: pxs, in: fullPrevFrame)
            prevScroll.isHidden = true
        }
    }
    @objc func ocrCopyClicked() {
        guard let id = previewItemId, let t = Store.shared.item(id)?.ocrText, !t.isEmpty else { return }
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(t, forType: .string)
        AppState.shared.lastChange = pb.changeCount
        Toast.shared.show("Text kopiert")
    }
    // ===== Farbe: großes Farbfeld + HEX/RGB/HSL =====
    func showColorPreview(_ item: ClipItem, color: NSColor) {
        editBtn.isHidden = false
        prevHeader.attributedStringValue = headerAttr(item, kindStr: "Farbe")
        let swH: CGFloat = 220
        prevImage.frame = NSRect(x: prevX, y: fullPrevFrame.maxY - swH, width: prevW, height: swH)
        prevImage.image = colorSwatch(color, size: NSSize(width: prevW, height: swH), radius: 0)
        prevImage.isHidden = false
        prevScroll.frame = NSRect(x: prevX, y: 14, width: prevW, height: fullPrevFrame.height - swH - 12)
        setPreviewText((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + colorDescription(color) + "\n\nWert markieren + Cmd+C kopiert nur diesen Teil", links: false, query: nil)
        prevScroll.isHidden = false
    }
    // ===== Passwort: verborgen, bis die Maus über der Vorschau ist oder ⌥ gehalten wird =====
    func showMaskedPreview(_ item: ClipItem) {
        prevHeader.attributedStringValue = headerAttr(item, kindStr: "Passwort", extra: "  ·  verborgen")
        prevScroll.frame = fullPrevFrame; prevImage.isHidden = true
        let n = min(24, max(8, (item.text ?? "").count))
        setPreviewText(String(repeating: "•", count: n) + "\n\nMaus hierher bewegen oder ⌥ halten, um den Inhalt zu zeigen.\nKlick / Enter / Cmd+C kopiert trotzdem.", links: false, query: nil)
        prevText.isSelectable = false
        prevScroll.isHidden = false
    }
    // ===== Bearbeiten vor dem Kopieren =====
    func beginEdit(_ it: ClipItem) {
        guard it.kind == .text, editingId == nil else { return }
        if let idx = display.firstIndex(where: { rowId($0) == it.id }) { selectRow(idx) }
        editingId = it.id
        expandedRowCollapse?(); expandedRowCollapse = nil
        resetPreviewChrome(); copyBtn.isHidden = true; prevImage.isHidden = true
        prevScroll.frame = fullPrevFrame; prevScroll.isHidden = false
        setPreviewText(it.text ?? "", links: false, query: nil)   // Original bearbeiten (nicht die bereinigte Anzeige)
        prevText.isEditable = true; prevText.allowsUndo = true
        prevText.drawsBackground = true; prevText.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        prevScroll.wantsLayer = true; prevScroll.layer?.cornerRadius = 8
        prevScroll.layer?.borderWidth = 1; prevScroll.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let h = NSMutableAttributedString(attributedString: symAttr("pencil", color: .controlAccentColor))
        h.append(NSAttributedString(string: " Bearbeiten  ·  Cmd+Enter speichern + kopieren  ·  Esc abbrechen", attributes: base))
        prevHeader.attributedStringValue = h
        saveBtn.isHidden = false; cancelBtn.isHidden = false
        layoutTopButtons()
        panel.makeFirstResponder(prevText)
        prevText.setSelectedRange(NSRange(location: (prevText.string as NSString).length, length: 0))
    }
    /// Bearbeiten-Optik zuruecksetzen (ohne zu speichern, ohne neu zu laden)
    func finishEditUI() {
        editingId = nil
        prevText.isEditable = false; prevText.drawsBackground = false
        prevScroll.layer?.borderWidth = 0
        saveBtn.isHidden = true; cancelBtn.isHidden = true
    }
    func endEdit(save: Bool, copyAfter: Bool = false) {
        guard let id = editingId else { return }
        let newText = prevText.string
        finishEditUI()
        if save, let it = Store.shared.item(id), it.text != newText {
            if Store.shared.edit(id: id, text: newText) { if !copyAfter { Toast.shared.show("Gespeichert") } }
        }
        if copyAfter, let it = Store.shared.item(id) { choose(it); return }
        panel.makeFirstResponder(search)
        reload()
        if let idx = display.firstIndex(where: { rowId($0) == id }) { selectRow(idx, scroll: true) }
    }
    @objc func editClicked() { if let id = previewItemId, let it = Store.shared.item(id) { beginEdit(it) } }
    @objc func saveEditClicked() { endEdit(save: true) }
    @objc func cancelEditClicked() { endEdit(save: false) }
    // ===== Im Finder zeigen =====
    @objc func finderClicked() {
        if currentCollection == SHARED_CHIP, let id = previewItemId, SharedVault.shared.item(id) != nil { revealShared(id); return }
        if let id = previewItemId, let it = Store.shared.item(id) { revealInFinder(it) }
    }
    func revealInFinder(_ it: ClipItem) {
        let u: URL? = it.kind == .image ? Store.shared.imageURL(it) : Store.shared.fileURL(it)
        guard let url = u, FileManager.default.fileExists(atPath: url.path) else { Toast.shared.show("Datei nicht mehr da"); return }
        hide(); NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    // ===== Website-Vorschau fuer Link-Eintraege =====
    func showLinkPreview(_ item: ClipItem, url: URL) {
        previewURL = url
        let imgH: CGFloat = 320
        prevImage.frame = NSRect(x: prevX, y: fullPrevFrame.maxY - imgH, width: prevW, height: imgH)
        prevScroll.frame = NSRect(x: prevX, y: 14, width: prevW, height: fullPrevFrame.height - imgH - 12)
        prevHeader.attributedStringValue = headerAttr(item, kindStr: "Link", extra: url.host.map { "  ·  \($0)" } ?? "")
        let cached = LinkPreview.shared.cachedImage(url)
        prevImage.image = cached ?? globePlaceholder
        prevImage.isHidden = false; prevScroll.isHidden = false
        setPreviewText(linkText(url, title: LinkPreview.shared.title(url), loading: cached == nil), links: true, query: search.stringValue)
        guard cached == nil else { return }
        let iid = item.id
        LinkPreview.shared.fetch(url) { [weak self] img, tt in
            guard let self = self else { return }
            // Listen-Zeile aktualisieren (Mini-Thumb + Seitentitel), Auswahl bleibt unberuehrt
            if let ridx = self.display.firstIndex(where: { if case .item(let x) = $0 { return x.id == iid }; return false }) {
                self.table.reloadData(forRowIndexes: IndexSet(integer: ridx), columnIndexes: IndexSet(integer: 0))
            }
            // Vorschau nur tauschen, wenn noch derselbe Eintrag gewaehlt ist
            let r = self.table.selectedRow
            guard r >= 0, r < self.display.count, case .item(let cur) = self.display[r], cur.id == iid else { return }
            if let img = img { self.prevImage.image = img }
            self.setPreviewText(self.linkText(url, title: tt, loading: false, failed: img == nil), links: true, query: self.search.stringValue)
        }
    }
    func linkText(_ url: URL, title: String?, loading: Bool, failed: Bool = false) -> String {
        var s = ""
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { s += t + "\n\n" }
        s += url.absoluteString
        if loading { s += "\n\nLade Website-Vorschau…" }
        if failed { s += "\n\nKeine Vorschau möglich (Seite blockt oder offline)" }
        s += "\n\nKlick aufs Bild öffnet den Link im Browser"
        return s
    }
    @objc func previewImageClicked() {
        if let u = previewURL { NSWorkspace.shared.open(u); hide(); return }   // Link: Website öffnen
        quickLookPreview()                                                     // Bild: Quick Look (quicklook.swift)
    }
    // Header mit SF-Symbolen statt Emojis (🕒/✨/📱 raus)
    func symAttr(_ name: String, color: NSColor) -> NSAttributedString {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let att = NSTextAttachment()
        att.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        att.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
        return NSAttributedString(attachment: att)
    }
    func headerAttr(_ item: ClipItem, kindStr: String, extra: String = "") -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let out = NSMutableAttributedString()
        if item.source == "KI" { out.append(symAttr("sparkles", color: .systemPurple)); out.append(NSAttributedString(string: " von KI  ·  ", attributes: base)) }
        else if item.source == "iPhone" { out.append(symAttr("iphone", color: .systemBlue)); out.append(NSAttributedString(string: " von iPhone  ·  ", attributes: base)) }
        else if item.source == "Diktat" { out.append(symAttr("waveform", color: .systemOrange)); out.append(NSAttributedString(string: " Diktat  ·  ", attributes: base)) }
        else if item.source == "Meeting" { out.append(symAttr("person.2.wave.2", color: .systemOrange)); out.append(NSAttributedString(string: " Meeting  ·  ", attributes: base)) }
        if item.shared { out.append(symAttr("person.2.fill", color: .systemTeal)); out.append(NSAttributedString(string: " geteilt  ·  ", attributes: base)) }
        out.append(symAttr("clock", color: NSColor.white.withAlphaComponent(0.65)))
        out.append(NSAttributedString(string: " " + timeFmt.string(from: item.date) + "  ·  " + kindStr + extra, attributes: base))
        return out
    }
    // Nicht darstellbare Platzhalter aus App-Copys entfernen (Private-Use-Glyphen/U+FFFC -> "?"-Kästchen)
    func cleanedForDisplay(_ t: String) -> String {
        let bad: (Unicode.Scalar) -> Bool = { $0.value == 0xFFFC || (0xE000...0xF8FF).contains($0.value) }
        guard t.unicodeScalars.contains(where: bad) else { return t }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: t.unicodeScalars.filter { !bad($0) })
        return String(v)
    }
    // Vorschautext setzen: Links klickbar machen + Suchtreffer gelb markieren
    func setPreviewText(_ s: String, links: Bool, query: String?) {
        prevText.string = s
        if let storage = prevText.textStorage {
            let full = NSRange(location: 0, length: (s as NSString).length)
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.white], range: full)
            if links, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                det.enumerateMatches(in: s, options: [], range: full) { m, _, _ in
                    if let m = m, let url = m.url { storage.addAttribute(.link, value: url, range: m.range) }
                }
            }
            if let q = query, !q.isEmpty {
                let ns = s as NSString
                var rest = NSRange(location: 0, length: ns.length)
                while true {
                    let f = ns.range(of: q, options: [.caseInsensitive], range: rest)
                    if f.location == NSNotFound { break }
                    storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.30), range: f)
                    let next = f.location + max(f.length, 1)
                    if next >= ns.length { break }
                    rest = NSRange(location: next, length: ns.length - next)
                }
            }
        }
        prevText.scroll(NSPoint(x: 0, y: 0))
    }
    // ===== Kopieren ohne Panel zu schließen: Auswahl > ganzer Eintrag =====
    @objc func copyPreviewClicked() { copySelectionOrItem() }
    func copySelectionOrItem() {
        if table.selectedRow >= 0, table.selectedRow < display.count, case .shared(let sh) = display[table.selectedRow] {
            SharedSeen.shared.markSeen([sh.id])   // auch ein kopierter Ausschnitt zaehlt als gesehen
        }
        // 1) fokussiertes Textfeld mit Auswahl (Vorschau ODER Suchfeld-Editor)
        if let tv = panel.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
            copyPlain((tv.string as NSString).substring(with: tv.selectedRange())); return
        }
        // 2) Auswahl in der Vorschau, auch wenn der Fokus woanders liegt
        if !prevScroll.isHidden, prevText.selectedRange().length > 0 {
            copyPlain((prevText.string as NSString).substring(with: prevText.selectedRange())); return
        }
        // 3) sonst: ganzen Eintrag kopieren
        let r = table.selectedRow
        guard r >= 0, r < display.count else { return }
        if case .shared(let sh) = display[r] { SharedVault.shared.copyToPasteboard(id: sh.id); return }
        guard case .item(let it) = display[r] else { return }
        copyItemStay(it)
    }
    func copyPlain(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(s, forType: .string)
        AppState.shared.lastChange = pb.changeCount   // Fragment nicht als neuer Verlaufseintrag erfassen
        Toast.shared.show("Auswahl kopiert")
    }
    func copyItemStay(_ it: ClipItem) {
        let pb = NSPasteboard.general; pb.clearContents()
        switch it.kind {
        case .text: pb.setString(it.text ?? "", forType: .string)
        case .file:
            let urls: [NSURL] = (it.files ?? []).compactMap { r in
                if FileManager.default.fileExists(atPath: r.orig) { return NSURL(fileURLWithPath: r.orig) }
                if let st = r.stored { let p = Store.shared.dir.appendingPathComponent(st).path; if FileManager.default.fileExists(atPath: p) { return NSURL(fileURLWithPath: p) } }
                return nil
            }
            if !urls.isEmpty { pb.writeObjects(urls) }
        case .image: if let d = Store.shared.dataFor(it) { pb.setData(d, forType: .png) }
        }
        AppState.shared.lastChange = pb.changeCount   // Reihenfolge/Ansicht bleibt stabil
        Toast.shared.show(it.kind == .file ? "Datei in Zwischenablage" : (it.kind == .image ? "Bild in Zwischenablage" : "In Zwischenablage"))
    }
    func fileKindLabel(_ refs: [FileRef]) -> String {
        if refs.count > 1 { return "\(refs.count) Dateien" }
        let ext = (refs[0].name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "Datei" : "\(ext)-Datei"
    }
    func fileDetails(_ refs: [FileRef]) -> String {
        var lines: [String] = []
        for r in refs {
            let path = FileManager.default.fileExists(atPath: r.orig) ? r.orig : (r.stored.map { Store.shared.dir.appendingPathComponent($0).path } ?? r.orig)
            var size = ""
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let sz = attrs[.size] as? Int64 {
                size = "  ·  " + ByteCountFormatter.string(fromByteCount: sz, countStyle: .file)
            }
            let loc = (r.orig as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            let gone = FileManager.default.fileExists(atPath: r.orig) ? "" : "  (Original verschoben - im Verlauf gesichert)"
            lines.append("\(r.name)\(size)\n     \(loc)\(gone)")
        }
        lines.append("\n↩︎  Enter / Klick  →  Datei in Zwischenablage")
        return lines.joined(separator: "\n")
    }
    func loadBigThumb(_ item: ClipItem) {
        guard let r = item.files?.first else { return }
        let path = FileManager.default.fileExists(atPath: r.orig) ? r.orig : (r.stored.map { Store.shared.dir.appendingPathComponent($0).path } ?? r.orig)
        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 260, height: 260), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep = rep else { return }
            DispatchQueue.main.async {
                item.bigThumb = rep.nsImage
                guard let self = self else { return }
                let row = self.table.selectedRow
                if row >= 0, row < self.display.count, case .item(let cur) = self.display[row], cur.id == item.id {
                    self.prevImage.image = item.bigThumb
                }
            }
        }
    }

    @objc func rowClicked() {
        let r = table.clickedRow
        // Klick auf die Aktions-Leiste kommt hier nie an (die Leiste behandelt ihn selbst); zur Sicherheit:
        // landet ein Klick doch auf einem Knopf oder der scharfen Leiste, ist er KEIN Kopieren
        if r >= 0, let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false), let sup = cell.superview {
            let p = sup.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
            let hit = cell.hitTest(p)
            if hit is NSButton || ((hit as? ActionBar)?.machine.isArmed ?? false) { return }
        }
        // Mehrfachauswahl: ⌘-Klick schaltet um, ⇧-Klick nimmt einen Bereich, bei aktiver Auswahl schaltet jeder Klick um
        if handleSelectionClick(row: r, flags: NSApp.currentEvent?.modifierFlags ?? []) { return }
        activateRow(r)
    }
    /// Zeile „waehlen" = kopieren + einfuegen
    func activateRow(_ r: Int) {
        guard editingId == nil, r >= 0 && r < display.count, rowId(display[r]) != nil else { return }
        switch display[r] {
        case .item(let it): choose(it)
        case .shared(let sh): chooseShared(sh)
        case .header: break
        }
    }
    func choose(_ item: ClipItem) {
        hide(); AppState.shared.copyAndPaste(item)
        Toast.shared.show(item.kind == .file ? "Datei in Zwischenablage" : "In Zwischenablage")
    }
    func chooseShared(_ sh: SharedItem) { hide(); SharedVault.shared.copyToPasteboard(id: sh.id) }
    // ===== Rechtsklick-Menü =====
    func menuItem(_ title: String, _ sym: String, _ action: Selector, _ obj: Any?, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        mi.representedObject = obj; mi.target = self
        return mi
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard editingId == nil, r >= 0, r < display.count else { return }
        if let rid = rowId(display[r]) {   // Mehrfachauswahl
            let on = multi.contains(rid)
            menu.addItem(menuItem(on ? "Abwählen" : (multi.isActive ? "Zur Auswahl hinzufügen" : "Auswählen (mehrere kopieren)"), on ? "checkmark.circle" : "checkmark.circle.fill", #selector(selectToggleAction(_:)), rid))
            if multi.isActive { menu.addItem(menuItem("Alle \(multi.count) kopieren", "doc.on.doc.fill", #selector(selCopyClicked), nil)) }
            menu.addItem(.separator())
        }
        if case .shared(let sh) = display[r] {
            menu.addItem(menuItem("Kopieren", "doc.on.doc", #selector(sharedCopyAction(_:)), sh.id))
            addSharedFileMenuItems(menu, sh)
            menu.addItem(menuItem(sh.pinned ? "Lösen" : "Anheften", sh.pinned ? "pin.slash" : "pin", #selector(sharedPinAction(_:)), sh.id))
            if SharedSeen.shared.isNew(sh) { menu.addItem(menuItem("Als gesehen markieren", "checkmark.circle", #selector(markSeenAction(_:)), sh.id)) }
            if SharedSeen.shared.newCount > 0 { menu.addItem(menuItem("Alle als gesehen markieren", "checkmark.circle.fill", #selector(markAllSeenClicked), nil)) }
            menu.addItem(.separator())
            menu.addItem(menuItem("Aus „Geteilt\" entfernen", "person.2.slash", #selector(unshareAction(_:)), sh.id))
            return
        }
        guard case .item(let it) = display[r] else { return }
        let sub = NSMenu()
        for c in Store.shared.collections {
            let mi = NSMenuItem(title: c.name, action: #selector(assignToCollection(_:)), keyEquivalent: "")
            mi.image = colIcon(c.symbol, sf: 14, img: 16)
            mi.representedObject = [it.id, c.id]; mi.target = self
            mi.state = (it.collection == c.id) ? .on : .off
            sub.addItem(mi)
        }
        if !Store.shared.collections.isEmpty { sub.addItem(.separator()) }
        let newC = NSMenuItem(title: "Neuer Bereich…", action: #selector(assignNew(_:)), keyEquivalent: "")
        newC.representedObject = it.id; newC.target = self; sub.addItem(newC)
        let inItem = NSMenuItem(title: "In Bereich legen", action: nil, keyEquivalent: "")
        inItem.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
        menu.addItem(inItem); menu.setSubmenu(sub, for: inItem)
        if it.collection != nil {
            let rem = NSMenuItem(title: "Aus Bereich entfernen", action: #selector(removeFromCollectionAction(_:)), keyEquivalent: "")
            rem.image = NSImage(systemSymbolName: "tray.and.arrow.up", accessibilityDescription: nil)
            rem.representedObject = it.id; rem.target = self; menu.addItem(rem)
        }
        // Bearbeiten / Texterkennung / Finder
        menu.addItem(.separator())
        if it.kind == .text { menu.addItem(menuItem("Bearbeiten …", "pencil", #selector(editAction(_:)), it.id)) }
        if it.kind == .image {
            if let o = it.ocrText, !o.isEmpty { menu.addItem(menuItem("Erkannten Text kopieren", "text.viewfinder", #selector(ocrCopyAction(_:)), it.id)) }
            menu.addItem(menuItem(it.ocrText == nil ? "Text erkennen" : "Text erneut erkennen", "text.magnifyingglass", #selector(ocrAction(_:)), it.id))
        }
        if it.kind == .image || it.kind == .file { menu.addItem(menuItem("Im Finder zeigen", "folder", #selector(finderAction(_:)), it.id)) }
        // Geteilter Tresor
        let partner = SharedVault.shared.partner
        if it.shared { menu.addItem(menuItem("Nicht mehr mit \(partner) teilen", "person.2.slash", #selector(unshareAction(_:)), it.id)) }
        else { menu.addItem(menuItem("Mit \(partner) teilen", "person.2.fill", #selector(shareAction(_:)), it.id)) }
        menu.addItem(.separator())
        let pinItem = NSMenuItem(title: it.pinned ? "Lösen" : "Anheften", action: #selector(togglePinAction(_:)), keyEquivalent: "")
        pinItem.image = NSImage(systemSymbolName: it.pinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = it.id; pinItem.target = self; menu.addItem(pinItem)
        let del = NSMenuItem(title: "Löschen", action: #selector(deleteAction(_:)), keyEquivalent: "")
        del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        del.representedObject = it.id; del.target = self; menu.addItem(del)
    }
    @objc func selectToggleAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { toggleSelection(id) } }
    @objc func editAction(_ s: NSMenuItem) { if let id = s.representedObject as? String, let it = Store.shared.item(id) { beginEdit(it) } }
    @objc func ocrAction(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let it = Store.shared.item(id) else { return }
        OCR.shared.enqueue(it, force: true)
        if let idx = display.firstIndex(where: { rowId($0) == id }) { selectRow(idx) }
    }
    @objc func ocrCopyAction(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let t = Store.shared.item(id)?.ocrText, !t.isEmpty else { return }
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(t, forType: .string)
        AppState.shared.lastChange = pb.changeCount; Toast.shared.show("Text kopiert")
    }
    @objc func finderAction(_ s: NSMenuItem) { if let id = s.representedObject as? String, let it = Store.shared.item(id) { revealInFinder(it) } }
    @objc func shareAction(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let it = Store.shared.item(id) else { return }
        switch SharedVaultHook.share(it) {
        case .success: Toast.shared.show("Mit \(SharedVault.shared.partner) geteilt")
        case .failure(let e): Toast.shared.show(e.message)
        }
        reload()
    }
    @objc func unshareAction(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        SharedVaultHook.unshare(id); Toast.shared.show("Nicht mehr geteilt"); reload()
    }
    @objc func markSeenAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { SharedSeen.shared.markSeen([id]) } }
    @objc func sharedCopyAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { SharedVault.shared.copyToPasteboard(id: id) } }
    @objc func sharedPinAction(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let sh = SharedVault.shared.item(id) else { return }
        SharedVaultHook.setPinned(id, !sh.pinned); reload()
    }
    @objc func assignToCollection(_ s: NSMenuItem) {
        guard let a = s.representedObject as? [String], a.count == 2 else { return }
        Store.shared.setCollection(itemId: a[0], collectionId: a[1]); reload(); buildChips()
        Toast.shared.show("In Bereich gelegt")
    }
    @objc func assignNew(_ s: NSMenuItem) {
        guard let iid = s.representedObject as? String else { return }
        promptNewCollection(assignItemId: iid)
    }
    @objc func removeFromCollectionAction(_ s: NSMenuItem) {
        guard let iid = s.representedObject as? String else { return }
        Store.shared.setCollection(itemId: iid, collectionId: nil); reload(); buildChips()
    }
    @objc func togglePinAction(_ s: NSMenuItem) {
        guard let iid = s.representedObject as? String, let it = Store.shared.items.first(where: { $0.id == iid }) else { return }
        Store.shared.togglePin(it); reload()
    }
    @objc func deleteAction(_ s: NSMenuItem) {
        guard let iid = s.representedObject as? String else { return }
        Store.shared.delete(id: iid); reload(); buildChips()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let rows = itemRows(); guard !rows.isEmpty else { if sel == #selector(NSResponder.cancelOperation(_:)) { hide(); return true }; return false }
        let cur = table.selectedRow
        switch sel {
        case #selector(NSResponder.moveDown(_:)): selectRow(rows.first(where: { $0 > cur }) ?? rows.last!, scroll: true); return true
        case #selector(NSResponder.moveUp(_:)): selectRow(rows.last(where: { $0 < cur }) ?? rows.first!, scroll: true); return true
        case #selector(NSResponder.insertNewline(_:)):
            if multi.isActive { copyAllSelected(close: true); return true }
            if cur >= 0, cur < display.count {
                if case .item(let it) = display[cur] { choose(it) } else if case .shared(let sh) = display[cur] { chooseShared(sh) }
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)): if multi.isActive { clearSelection() } else { hide() }; return true
        default: return false
        }
    }
}
