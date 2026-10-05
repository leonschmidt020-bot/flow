// ClipVault — Mehrfachauswahl (05.10.2026)
// Mehrere Einträge wählen (⌘-Klick, ⇧-Klick, ⌘A, Kreis links) und alle auf einmal kopieren.
//
// Was auf der Zwischenablage landet (geprüft gegen Claude Code 2.1.289, siehe README):
//  • je Bild/Datei EIN NSPasteboardItem mit Datei-URL (+ PNG-Daten bei Bildern)
//    -> Finder, Mail, Notizen, Slack bekommen jedes Bild einzeln
//  • auf dem ERSTEN Item zusätzlich Klartext: alle Pfade mit Leerzeichen getrennt, im Stil von
//    Drag & Drop ins Terminal maskiert (`a\ b.png`), danach Texte durch Leerzeilen getrennt.
//    Claude Code zerlegt eingefügten Text an „Leerzeichen + /" und Zeilenumbrüchen, entfernt die
//    Backslash-Maskierung und macht aus jedem absoluten .png/.jpg/.gif/.webp-Pfad ein [Image #n].
//    In '…' gesetzte Pfade würde es NICHT trennen — deshalb Backslash statt Anführungszeichen.
//  • Bilder werden vorher nach ~/Library/Caches/flow-clipvault/export/<id>.png gelegt (stabil, 24 h),
//    damit der Pfad auch dann noch stimmt, wenn der Eintrag aus dem Verlauf fällt.
import Cocoa

// MARK: - Auswahl-Automat (reine Logik)
struct MultiSelection {
    private(set) var ids: [String] = []      // in Wahl-Reihenfolge
    private(set) var anchor: String?         // Ausgangspunkt für ⇧-Klick
    var isActive: Bool { !ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    enum ClickResult: Equatable { case activate, changed }
    /// Klick auf eine Zeile. `order` = sichtbare Einträge von oben nach unten.
    /// Ohne Auswahl und ohne Taste: .activate (wie bisher kopieren). Sonst ändert der Klick die Auswahl.
    mutating func click(_ id: String, command: Bool, shift: Bool, order: [String]) -> ClickResult {
        if shift { extend(to: id, order: order); return .changed }
        if command || isActive { toggle(id); return .changed }
        return .activate
    }
    mutating func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        anchor = id
        if ids.isEmpty { anchor = nil }
    }
    /// ⇧-Klick: alles zwischen Anker und Ziel dazunehmen (wie im Finder); ohne Anker nur das Ziel
    mutating func extend(to id: String, order: [String]) {
        guard let a = anchor, let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: id) else {
            if !ids.contains(id) { ids.append(id) }
            anchor = id; return
        }
        for x in order[min(ia, ib)...max(ia, ib)] where !ids.contains(x) { ids.append(x) }
    }
    /// ⌘A: genau die Einträge der aktuellen Ansicht/des Filters
    mutating func selectAll(_ order: [String]) { ids = order; anchor = order.first }
    mutating func clear() { ids = []; anchor = nil }
    /// gelöschte / verschwundene Einträge herausnehmen
    mutating func prune(keep: Set<String>) {
        ids.removeAll { !keep.contains($0) }
        if let a = anchor, !keep.contains(a) { anchor = ids.last }
        if ids.isEmpty { anchor = nil }
    }
    /// Auswahl in Listen-Reihenfolge (so entstehen [Image #1], #2 … von oben nach unten)
    func ordered(by order: [String]) -> [String] {
        let pos = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated().sorted { l, r in
            let a = pos[l.element] ?? Int.max, b = pos[r.element] ?? Int.max
            return a != b ? a < b : l.offset < r.offset
        }.map(\.element)
    }
}

// MARK: - Zwischenablage-Inhalt (reine Logik + Dateiexport)
enum MultiEntry {
    case image(id: String, source: URL)
    case text(String)
    case files([URL])
}
struct PasteItemPlan: Equatable { var fileURL: URL?; var pngFile: URL?; var string: String? }
struct PastePlan {
    var items: [PasteItemPlan] = []
    var text = ""
    var images = 0, texts = 0, files = 0, skipped = 0
}

/// Pfad so maskieren, wie das Terminal ihn beim Hineinziehen schreibt (`a\ b.png`).
/// Claude Code entfernt genau diese Maskierung; eine Shell versteht sie ebenfalls.
func cvShellEscape(_ path: String) -> String {
    let special = Set(" \t!\"#$&'()*,;<>?[\\]^`{|}~=%")
    var out = ""
    for ch in path { if special.contains(ch) { out.append("\\") }; out.append(ch) }
    return out
}

enum MultiCopy {
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    static let keepFor: TimeInterval = 24 * 3600
    /// Exportordner: ~/Library/Caches/flow-clipvault/export (Test mit CLIPVAULT_HOME: <home>/cache/export)
    static var exportDir: URL {
        if CV_HOME_OVERRIDE != nil { return URL(fileURLWithPath: CV_DIR + "cache/export", isDirectory: true) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return caches.appendingPathComponent("flow-clipvault/export", isDirectory: true)
    }
    /// Alles älter als 24 h aus dem Exportordner entfernen
    static func cleanExport(_ dir: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in list {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(d) > keepFor { try? fm.removeItem(at: u) }
        }
    }
    /// Bild als <id>.png in den Exportordner legen (PNG direkt kopieren, sonst umwandeln)
    static func export(id: String, source: URL, to dir: URL) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let dest = dir.appendingPathComponent((safe.isEmpty ? UUID().uuidString : safe) + ".png")
        if fm.fileExists(atPath: dest.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)   // 24 h ab jetzt
            return dest
        }
        guard let data = try? Data(contentsOf: source) else { return nil }
        let isPNG = data.count >= 8 && data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var png = isPNG ? data : nil
        if png == nil, let rep = NSBitmapImageRep(data: data) { png = rep.representation(using: .png, properties: [:]) }
        guard let out = png, (try? out.write(to: dest, options: .atomic)) != nil else { return nil }
        return dest
    }
    /// Aus den gewählten Einträgen den Zwischenablage-Plan bauen (Bilder werden dabei exportiert)
    static func plan(_ entries: [MultiEntry], exportDir dir: URL = MultiCopy.exportDir) -> PastePlan {
        cleanExport(dir)
        var p = PastePlan()
        var paths: [String] = [], texts: [String] = []
        for e in entries {
            switch e {
            case .image(let id, let src):
                guard let u = export(id: id, source: src, to: dir) else { p.skipped += 1; continue }
                p.items.append(PasteItemPlan(fileURL: u, pngFile: u, string: nil))
                paths.append(cvShellEscape(u.path)); p.images += 1
            case .files(let urls):
                let ok = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                if ok.isEmpty { p.skipped += 1; continue }
                for u in ok {
                    let img = imageExts.contains(u.pathExtension.lowercased())
                    p.items.append(PasteItemPlan(fileURL: u, pngFile: nil, string: nil))
                    paths.append(cvShellEscape(u.path))
                    if img { p.images += 1 } else { p.files += 1 }
                }
            case .text(let t):
                guard !t.isEmpty else { p.skipped += 1; continue }
                texts.append(t); p.texts += 1
            }
        }
        var parts: [String] = []
        if !paths.isEmpty { parts.append(paths.joined(separator: " ")) }
        parts.append(contentsOf: texts)
        p.text = parts.joined(separator: "\n\n")
        if p.items.isEmpty { if !p.text.isEmpty { p.items = [PasteItemPlan(fileURL: nil, pngFile: nil, string: p.text)] } }
        else { p.items[0].string = p.text }
        return p
    }
    /// Plan auf eine Zwischenablage schreiben (allgemeine ODER eigene Test-Zwischenablage)
    @discardableResult static func write(_ plan: PastePlan, to pb: NSPasteboard) -> Bool {
        guard !plan.items.isEmpty else { return false }
        let items: [NSPasteboardItem] = plan.items.map { pi in
            let it = NSPasteboardItem()
            if let u = pi.fileURL { it.setString(u.absoluteString, forType: .fileURL) }
            if let f = pi.pngFile, let d = try? Data(contentsOf: f) { it.setData(d, forType: .png) }
            if let s = pi.string { it.setString(s, forType: .string) }
            return it
        }
        pb.clearContents()
        return pb.writeObjects(items)
    }
    /// „3 Bilder kopiert – in Claude Code mit ⌘V einfügen"
    static func toastText(_ p: PastePlan) -> String {
        func n(_ c: Int, _ one: String, _ many: String) -> String? { c == 0 ? nil : "\(c) \(c == 1 ? one : many)" }
        let parts = [n(p.images, "Bild", "Bilder"), n(p.files, "Datei", "Dateien"), n(p.texts, "Text", "Texte")].compactMap { $0 }
        if parts.isEmpty { return "Nichts zum Kopieren" }
        var s = parts.joined(separator: " + ") + " kopiert"
        if p.images > 0 { s += " – in Claude Code mit ⌘V einfügen" }
        return s
    }
}

// MARK: - Auswahl-Leiste unten in der Liste (Hintergrund selbst gezeichnet: deckt die Liste auch im Render sicher ab)
final class SelectionBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13)
        NSColor(white: 0.135, alpha: 1).setFill(); p.fill()
        NSColor.white.withAlphaComponent(0.13).setStroke(); p.lineWidth = 1; p.stroke()
    }
}

// MARK: - Auswahl-Kreis (links in jeder Zeile, solange etwas gewählt ist; beim Hovern am Vorschaubild)
final class SelectCircle: NSButton {
    var checked = false { didSet { needsDisplay = true } }
    var compact = false   // kleiner Kreis über dem Vorschaubild (Hover, noch nichts gewählt)
    var onToggle: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; title = ""; setButtonType(.momentaryChange)
        target = self; action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { onToggle?() }
    override var isFlipped: Bool { false }   // Haken in normalen Koordinaten zeichnen (NSButton ist sonst gespiegelt)
    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height) - 2
        let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: r)
        if checked {
            // weiss gefuellt, dunkler Haken: klar sichtbar, egal welche Akzentfarbe (z. B. Graphit)
            NSColor.white.setFill(); path.fill()
            let ck = NSBezierPath()
            ck.move(to: NSPoint(x: r.minX + d * 0.27, y: r.minY + d * 0.50))
            ck.line(to: NSPoint(x: r.minX + d * 0.43, y: r.minY + d * 0.34))
            ck.line(to: NSPoint(x: r.minX + d * 0.74, y: r.minY + d * 0.66))
            ck.lineWidth = max(1.6, d * 0.11); ck.lineCapStyle = .round; ck.lineJoinStyle = .round
            NSColor(white: 0.08, alpha: 1).setStroke(); ck.stroke()
        } else {
            NSColor(white: compact ? 0.10 : 0.0, alpha: compact ? 0.92 : 0.22).setFill(); path.fill()
            NSColor.white.withAlphaComponent(compact ? 0.92 : 0.42).setStroke(); path.lineWidth = compact ? 1.5 : 1.4; path.stroke()
        }
    }
}

// MARK: - Selbsttest: clipvault multiselect-test (fasst weder Verlauf noch die allgemeine Zwischenablage an)
func runMultiSelectTest() -> Never {
    var fails = 0, n = 0
    func check(_ name: String, _ ok: Bool) {
        n += 1; print((ok ? "ok    " : "FEHLER ") + name); if !ok { fails += 1 }
    }
    let order = ["a", "b", "c", "d", "e", "f"]
    // 1) Klick ohne Auswahl = wie bisher kopieren
    do {
        var m = MultiSelection()
        check("Start: keine Auswahl", !m.isActive)
        check("normaler Klick ohne Auswahl -> activate", m.click("b", command: false, shift: false, order: order) == .activate)
        check("…und waehlt nichts", !m.isActive)
    }
    // 2) ⌘-Klick schaltet um, danach schaltet auch ein normaler Klick um
    do {
        var m = MultiSelection()
        check("⌘-Klick -> changed", m.click("b", command: true, shift: false, order: order) == .changed)
        check("b gewaehlt", m.contains("b") && m.count == 1)
        check("normaler Klick bei Auswahl -> changed", m.click("d", command: false, shift: false, order: order) == .changed)
        check("b + d", m.ids == ["b", "d"])
        _ = m.click("b", command: true, shift: false, order: order)
        check("⌘-Klick auf b nimmt b heraus", m.ids == ["d"])
        _ = m.click("d", command: false, shift: false, order: order)
        check("letzten herausnehmen -> leer", !m.isActive && m.anchor == nil)
        check("danach wieder activate", m.click("a", command: false, shift: false, order: order) == .activate)
    }
    // 3) ⇧-Klick: Bereich ab Anker, in beide Richtungen, vereinigt mit Bestehendem
    do {
        var m = MultiSelection()
        _ = m.click("b", command: true, shift: false, order: order)
        _ = m.click("e", command: false, shift: true, order: order)
        check("⇧-Klick b..e", Set(m.ids) == ["b", "c", "d", "e"])
        _ = m.click("a", command: false, shift: true, order: order)
        check("⇧-Klick zurueck bis a (Anker bleibt b)", Set(m.ids) == ["a", "b", "c", "d", "e"])
        var m2 = MultiSelection()
        _ = m2.click("d", command: false, shift: true, order: order)
        check("⇧-Klick ohne Anker waehlt nur das Ziel", m2.ids == ["d"])
        _ = m2.click("f", command: false, shift: true, order: order)
        check("…und ist dann Anker", Set(m2.ids) == ["d", "e", "f"])
        var m3 = MultiSelection()
        _ = m3.click("b", command: true, shift: false, order: order)
        _ = m3.click("zz", command: false, shift: true, order: order)
        check("⇧-Klick auf unbekannte Zeile: nur dazunehmen", m3.ids == ["b", "zz"])
    }
    // 4) ⌘A, Leeren, Aufraeumen, Reihenfolge
    do {
        var m = MultiSelection()
        m.selectAll(["c", "e"])
        check("⌘A = genau der aktuelle Filter", m.ids == ["c", "e"])
        m.clear()
        check("Esc leert", !m.isActive)
        _ = m.click("e", command: true, shift: false, order: order)
        _ = m.click("a", command: true, shift: false, order: order)
        _ = m.click("c", command: true, shift: false, order: order)
        check("Reihenfolge = Liste (oben nach unten)", m.ordered(by: order) == ["a", "c", "e"])
        check("Unbekannte ans Ende", { var x = m; x.toggle("q"); return x.ordered(by: order) == ["a", "c", "e", "q"] }())
        m.prune(keep: ["a", "e"])
        check("geloeschte fallen raus", m.ids == ["e", "a"])
        m.prune(keep: [])
        check("alles geloescht -> inaktiv", !m.isActive && m.anchor == nil)
    }
    // 5) Maskierung
    check("Shell-Maskierung Leerzeichen", cvShellEscape("/tmp/a b/c d.png") == "/tmp/a\\ b/c\\ d.png")
    check("Shell-Maskierung Sonderzeichen", cvShellEscape("/x/it's (1).png") == "/x/it\\'s\\ \\(1\\).png")
    check("normaler Pfad bleibt", cvShellEscape("/Users/x/Library/Caches/flow-clipvault/export/AB-12.png") == "/Users/x/Library/Caches/flow-clipvault/export/AB-12.png")

    // 6) Plan + echte Zwischenablage (EIGENE, nie die allgemeine) mit Bildern in einem Ordner MIT Leerzeichen
    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cv multi test \(UUID().uuidString.prefix(6))", isDirectory: true)
    let src = base.appendingPathComponent("quelle"), exp = base.appendingPathComponent("export ordner")
    try? fm.createDirectory(at: src, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    func makeImage(_ name: String, _ color: NSColor, tiff: Bool = false) -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); NSGraphicsContext.restoreGraphicsState()
        let u = src.appendingPathComponent(name)
        try? (tiff ? rep.tiffRepresentation! : rep.representation(using: .png, properties: [:])!).write(to: u)
        return u
    }
    let i1 = makeImage("eins.png", .systemRed), i2 = makeImage("zwei.png", .systemBlue), i3 = makeImage("drei.tiff", .systemGreen, tiff: true)
    let doc = src.appendingPathComponent("Notiz (final).txt"); try? "x".write(to: doc, atomically: true, encoding: .utf8)
    let plan = MultiCopy.plan([.image(id: "ID-1", source: i1), .image(id: "ID-2", source: i2), .image(id: "ID-3", source: i3)], exportDir: exp)
    check("3 Bilder -> 3 Items", plan.items.count == 3 && plan.images == 3)
    check("Exportdateien <id>.png", plan.items.map { $0.fileURL?.lastPathComponent } == ["ID-1.png", "ID-2.png", "ID-3.png"])
    check("TIFF wurde zu PNG", (try? Data(contentsOf: plan.items[2].pngFile!))?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    let expected = plan.items.map { cvShellEscape($0.fileURL!.path) }.joined(separator: " ")
    check("Text = maskierte Pfade, Leerzeichen-getrennt", plan.text == expected && plan.text.contains("export\\ ordner/ID-1.png"))
    check("nur das erste Item traegt den Text", plan.items[0].string == plan.text && plan.items[1].string == nil)
    check("Hinweis", MultiCopy.toastText(plan) == "3 Bilder kopiert – in Claude Code mit ⌘V einfügen")

    let pb = NSPasteboard(name: NSPasteboard.Name("app.flowdictation.clipvault.multitest." + UUID().uuidString))
    defer { pb.releaseGlobally() }
    check("auf eigene Zwischenablage geschrieben", MultiCopy.write(plan, to: pb))
    check("3 Pasteboard-Items", pb.pasteboardItems?.count == 3)
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    check("3 Datei-URLs (Finder/Mail)", urls.count == 3 && urls.allSatisfy { fm.fileExists(atPath: $0.path) })
    check("jedes Item hat PNG-Daten", pb.pasteboardItems?.allSatisfy { $0.data(forType: .png) != nil } == true)
    let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
    check("3 Bilder lesbar", imgs.count == 3)
    let str = pb.string(forType: .string) ?? ""
    check("Klartext = alle Pfade", str == plan.text)
    // So zerlegt Claude Code eingefügten Text (2.1.289): an " /" und Zeilenumbrüchen, Backslash-Maskierung weg
    func claudeCodeSplit(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: " (?=/|[A-Za-z]:\\\\)")
        let marked = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\u{1}")
        return marked.split(separator: "\u{1}").flatMap { $0.split(separator: "\n") }.map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    func claudeCodeUnescape(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) { t = String(t.dropFirst().dropLast()) }
        var out = "", esc = false
        for ch in t { if esc { out.append(ch); esc = false } else if ch == "\\" { esc = true } else { out.append(ch) } }
        return out
    }
    let pieces = claudeCodeSplit(str).map(claudeCodeUnescape)
    check("Claude-Code-Zerlegung: 3 Stuecke", pieces.count == 3)
    check("…jedes ein existierendes Bild", pieces.allSatisfy { fm.fileExists(atPath: $0) && MultiCopy.imageExts.contains(($0 as NSString).pathExtension.lowercased()) })
    // Gegenprobe: mit '…' maskierte Pfade würde Claude Code NICHT trennen
    let quoted = plan.items.map { "'" + $0.fileURL!.path + "'" }.joined(separator: " ")
    check("Gegenprobe: '…'-Pfade bleiben ein Stueck (darum Backslash)", claudeCodeSplit(quoted).count == 1)

    // 7) Gemischt: Bild + Text + Datei; nur Text
    let mixed = MultiCopy.plan([.image(id: "ID-1", source: i1), .text("Hallo Welt"), .files([doc]), .text("Zweiter\nAbsatz")], exportDir: exp)
    check("gemischt: Items = Bild + Datei", mixed.items.count == 2 && mixed.images == 1 && mixed.files == 1 && mixed.texts == 2)
    check("gemischt: Text = Pfade, Leerzeile, Texte", mixed.text == cvShellEscape(mixed.items[0].fileURL!.path) + " " + cvShellEscape(doc.path) + "\n\nHallo Welt\n\nZweiter\nAbsatz")
    check("gemischt: Datei mit Klammern/Leerzeichen maskiert", mixed.text.contains("Notiz\\ \\(final\\).txt"))
    check("gemischt: Hinweis", MultiCopy.toastText(mixed) == "1 Bild + 1 Datei + 2 Texte kopiert – in Claude Code mit ⌘V einfügen")
    let onlyText = MultiCopy.plan([.text("eins"), .text("zwei")], exportDir: exp)
    check("nur Text: 1 Item, Leerzeile dazwischen", onlyText.items.count == 1 && onlyText.items[0].string == "eins\n\nzwei" && onlyText.items[0].fileURL == nil)
    check("nur Text: Hinweis ohne Claude-Satz", MultiCopy.toastText(onlyText) == "2 Texte kopiert")
    MultiCopy.write(onlyText, to: pb)
    check("nur Text: Zwischenablage liest 'eins\\n\\nzwei'", pb.string(forType: .string) == "eins\n\nzwei" && pb.pasteboardItems?.count == 1)
    let missing = MultiCopy.plan([.image(id: "X", source: src.appendingPathComponent("fehlt.png")), .text("t")], exportDir: exp)
    check("fehlendes Bild wird uebersprungen", missing.skipped == 1 && missing.images == 0 && missing.text == "t")

    // 8) Export: wiederverwendet, 24-h-Aufraeumen
    let again = MultiCopy.export(id: "ID-1", source: i1, to: exp)
    check("Export stabil (gleicher Pfad)", again == plan.items[0].fileURL)
    let old = exp.appendingPathComponent("alt.png"); try? Data([1]).write(to: old)
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: old.path)
    MultiCopy.cleanExport(exp)
    check("aelter als 24 h wird entfernt", !fm.fileExists(atPath: old.path) && fm.fileExists(atPath: plan.items[0].fileURL!.path))

    print(String(repeating: "-", count: 40))
    print(fails == 0 ? "ALLE \(n) PRUEFUNGEN OK" : "\(fails) VON \(n) FEHLGESCHLAGEN")
    exit(fails == 0 ? 0 : 1)
}
