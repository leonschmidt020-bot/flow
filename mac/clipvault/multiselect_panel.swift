// ClipVault — Mehrfachauswahl im Panel (Kreise links, Auswahl-Leiste unten, Klicks/Tasten, „Alle kopieren")
// Logik + Zwischenablage-Inhalt: multiselect.swift
import Cocoa

extension PanelController {
    static let selShift: CGFloat = 28          // so weit rückt der Zeileninhalt nach rechts, solange gewählt wird
    static let selBarH: CGFloat = 44

    // MARK: Aufbau
    func setupSelectionBar() {
        let w = leftW - 28
        selBar.frame = NSRect(x: 14, y: 14, width: w, height: PanelController.selBarH)
        selBar.wantsLayer = true
        selBar.shadow = { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.45); s.shadowBlurRadius = 14; s.shadowOffset = NSSize(width: 0, height: -3); return s }()
        selBar.isHidden = true

        selCount.font = .systemFont(ofSize: 13, weight: .semibold); selCount.textColor = .white
        selCount.frame = NSRect(x: 14, y: (PanelController.selBarH - 18) / 2, width: 120, height: 18)
        selBar.addSubview(selCount)

        // „Alle kopieren" — Akzentfarbe wie der gewählte Bereich-Chip
        let f = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        selCopyBtn.isBordered = false; selCopyBtn.imagePosition = .imageLeading; selCopyBtn.imageHugsTitle = true
        selCopyBtn.image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "Alle kopieren")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        let ink = NSColor(white: 0.08, alpha: 1)    // Hauptknopf weiss mit dunkler Schrift (wie der gewaehlte Kreis)
        selCopyBtn.contentTintColor = ink
        selCopyBtn.attributedTitle = NSAttributedString(string: " Alle kopieren", attributes: [.font: f, .foregroundColor: ink])
        selCopyBtn.wantsLayer = true; selCopyBtn.layer?.cornerRadius = 14
        selCopyBtn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        let cw = " Alle kopieren".size(withAttributes: [.font: f]).width + 40
        selCopyBtn.frame = NSRect(x: w - cw - 8, y: (PanelController.selBarH - 28) / 2, width: cw, height: 28)
        selCopyBtn.toolTip = "Alle gewählten Einträge kopieren (⌘C) · Enter = kopieren und schließen"
        selCopyBtn.target = self; selCopyBtn.action = #selector(selCopyClicked)
        selBar.addSubview(selCopyBtn)

        let g = NSFont.systemFont(ofSize: 12, weight: .medium)
        selClearBtn.isBordered = false; selClearBtn.bezelStyle = .regularSquare
        selClearBtn.attributedTitle = NSAttributedString(string: "Auswahl aufheben", attributes: [.font: g, .foregroundColor: NSColor.white.withAlphaComponent(0.62)])
        let xw = "Auswahl aufheben".size(withAttributes: [.font: g]).width + 20
        selClearBtn.frame = NSRect(x: selCopyBtn.frame.minX - xw - 4, y: (PanelController.selBarH - 26) / 2, width: xw, height: 26)
        selClearBtn.wantsLayer = true; selClearBtn.layer?.cornerRadius = 13
        selClearBtn.toolTip = "Auswahl aufheben (Esc)"
        selClearBtn.target = self; selClearBtn.action = #selector(selClearClicked)
        selBar.addSubview(selClearBtn)


        effect.addSubview(selBar, positioned: .above, relativeTo: scroll)
        scroll.automaticallyAdjustsContentInsets = false
    }

    // MARK: Zeilen schmücken
    /// Wird für jede Eintrags-Zeile aufgerufen: Kreis links (Auswahl aktiv) bzw. kleiner Kreis am Vorschaubild beim Hovern
    func decorateForSelection(_ v: NSView, id: String) {
        guard let row = v as? HoverRowView else { return }
        if multi.isActive {
            let s = PanelController.selShift
            for sv in row.subviews where sv.frame.minX < 100 {
                sv.frame.origin.x += s
                if sv is NSTextField { sv.frame.size.width = max(40, sv.frame.width - s) }
            }
            let on = multi.contains(id)
            let c = SelectCircle(frame: NSRect(x: 9, y: (row.bounds.height - 22) / 2, width: 22, height: 22))
            c.checked = on
            c.toolTip = on ? "Abwählen" : "Auswählen"
            c.onToggle = { [weak self] in self?.toggleSelection(id) }
            row.addSubview(c)
            if on {   // gewählte Zeile: ruhige Akzentfläche
                row.wantsLayer = true
                row.layer?.cornerRadius = 10
                row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
                row.layer?.borderWidth = 1
                row.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
            }
        } else {
            // Entdeckbar: beim Hovern erscheint oben links am Vorschaubild ein kleiner Kreis
            let c = SelectCircle(frame: NSRect(x: 6, y: row.bounds.height - 10 - 13, width: 19, height: 19))   // auf der Ecke des Vorschaubilds
            c.compact = true; c.isHidden = true
            c.toolTip = "Auswählen – mehrere Einträge zusammen kopieren (auch ⌘-Klick, ⇧-Klick, ⌘A)"
            c.onToggle = { [weak self] in self?.toggleSelection(id) }
            row.addSubview(c)
            let enter = row.onHover, exit = row.onExit
            row.onHover = { [weak c] in enter?(); c?.isHidden = false }
            row.onExit = { [weak c] in exit?(); c?.isHidden = true }
        }
    }

    // MARK: Auswahl ändern
    /// sichtbare Eintrags-IDs von oben nach unten
    func visibleIds() -> [String] { display.compactMap { rowId($0) } }

    func toggleSelection(_ id: String) {
        let was = multi.isActive
        multi.toggle(id)
        selectionChanged(modeChanged: was != multi.isActive, touched: [id])
    }
    /// Klick mit ⌘/⇧ oder bei aktiver Auswahl. true = behandelt (nicht kopieren)
    func handleSelectionClick(row r: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard editingId == nil, r >= 0, r < display.count, let id = rowId(display[r]) else { return false }
        let was = multi.isActive, before = Set(multi.ids)
        let res = multi.click(id, command: flags.contains(.command), shift: flags.contains(.shift), order: visibleIds())
        guard res == .changed else { return false }
        selectionChanged(modeChanged: was != multi.isActive, touched: before.symmetricDifference(multi.ids))
        if table.selectedRow != r { selectRow(r) }   // ⌘-Klick im Tisch hebt sonst die Hover-Markierung auf
        return true
    }
    func selectAllVisible() {
        let was = multi.isActive
        multi.selectAll(visibleIds())
        selectionChanged(modeChanged: was != multi.isActive, touched: nil)
    }
    func clearSelection(refresh: Bool = true) {
        guard multi.isActive else { return }
        multi.clear()
        if refresh { selectionChanged(modeChanged: true, touched: nil) } else { updateSelectionBar() }
    }
    @objc func selClearClicked() { clearSelection() }
    @objc func selCopyClicked() { copyAllSelected(close: false) }

    /// Nach jeder Änderung: Zeilen neu zeichnen (alle beim Moduswechsel, sonst nur die betroffenen), Leiste anpassen
    func selectionChanged(modeChanged: Bool, touched: Set<String>?) {
        let keepSel = table.selectedRow
        let clip = scroll.contentView.bounds.origin
        expandedRowCollapse = nil
        if modeChanged || touched == nil {
            table.reloadData()
        } else if let t = touched {
            let rows = IndexSet(display.indices.filter { rowId(display[$0]).map(t.contains) ?? false })
            if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
        }
        if keepSel >= 0, keepSel < display.count { table.selectRowIndexes(IndexSet(integer: keepSel), byExtendingSelection: false) }
        scroll.contentView.scroll(to: clip); scroll.reflectScrolledClipView(scroll.contentView)
        updateSelectionBar()
    }
    func updateSelectionBar() {
        let on = multi.isActive
        selBar.isHidden = !on
        selBar.frame.origin.y = scroll.frame.minY + 2   // bündig am Listenende (in „Geteilt" über dem Speicherstand)
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: on ? PanelController.selBarH + 12 : 0, right: 0)
        guard on else { return }
        let n = multi.count
        let imgs = multi.ids.filter { id in Store.shared.item(id)?.kind == .image || SharedVault.shared.item(id)?.kind == .image }.count
        selCount.stringValue = "\(n) ausgewählt"
        selCount.toolTip = imgs == n ? (n == 1 ? "1 Bild" : "\(n) Bilder") : "\(imgs) Bilder · \(n - imgs) andere"
        selCount.sizeToFit()
        selCount.frame.origin = NSPoint(x: 14, y: (PanelController.selBarH - selCount.frame.height) / 2)
    }
    /// Gewählte Einträge, die es nicht mehr gibt (gelöscht, abgelaufen), herausnehmen
    func pruneSelection() {
        guard multi.isActive else { return }
        var keep = Set(Store.shared.items.map(\.id))
        for s in SharedVault.shared.visible { keep.insert(s.id) }
        multi.prune(keep: keep)
        updateSelectionBar()
    }

    // MARK: Kopieren
    /// alle Einträge in Verlaufs-Reihenfolge (Verlauf, dann Geteilt)
    func globalOrder() -> [String] {
        let vis = visibleIds()
        var seen = Set(vis), out = vis
        for it in Store.shared.items where !seen.contains(it.id) { out.append(it.id); seen.insert(it.id) }
        for s in SharedVault.shared.visible where !seen.contains(s.id) { out.append(s.id); seen.insert(s.id) }
        return out
    }
    func selectionEntries() -> [MultiEntry] { cvSelectionEntries(multi.ordered(by: globalOrder())) }
    /// „Alle kopieren" / ⌘C / Enter. close = Panel danach schließen (Enter, wie beim Einzel-Eintrag)
    func copyAllSelected(close: Bool) {
        guard multi.isActive else { return }
        let sharedIds = multi.ids.filter { SharedVault.shared.item($0) != nil }
        let plan = MultiCopy.plan(selectionEntries())
        let pb = NSPasteboard.general
        guard MultiCopy.write(plan, to: pb) else { Toast.shared.show(plan.skipped > 0 ? "Nicht verfügbar (noch nicht geladen?)" : "Nichts zum Kopieren"); return }
        AppState.shared.lastChange = pb.changeCount     // nicht als neuer Verlaufs-Eintrag erfassen
        if !sharedIds.isEmpty { SharedSeen.shared.markSeen(sharedIds) }
        var msg = MultiCopy.toastText(plan)
        if plan.skipped > 0 { msg += " (\(plan.skipped) nicht verfügbar)" }
        if close { hide() }
        Toast.shared.show(msg)
    }
}

/// Einträge (Verlauf oder Geteilt) in Zwischenablage-Bausteine übersetzen
func cvSelectionEntries(_ ids: [String]) -> [MultiEntry] {
    var out: [MultiEntry] = []
    for id in ids {
        if let it = Store.shared.item(id) {
            switch it.kind {
            case .image: if let u = Store.shared.imageURL(it) { out.append(.image(id: it.id, source: u)) }
            case .text: out.append(.text(it.text ?? ""))
            case .file:
                let urls: [URL] = (it.files ?? []).compactMap { r in
                    if FileManager.default.fileExists(atPath: r.orig) { return URL(fileURLWithPath: r.orig) }
                    if let st = r.stored { let u = Store.shared.dir.appendingPathComponent(st); if FileManager.default.fileExists(atPath: u.path) { return u } }
                    return nil
                }
                out.append(.files(urls))
            }
        } else if let s = SharedVault.shared.item(id) {
            switch s.kind {
            case .text, .link: out.append(.text(s.text ?? ""))
            case .image: if let u = SharedVault.shared.localURL(s) { out.append(.image(id: s.id, source: u)) } else { out.append(.files([])) }
            case .file: out.append(.files(SharedVault.shared.localURL(s).map { [$0] } ?? []))
            }
        }
    }
    return out
}
