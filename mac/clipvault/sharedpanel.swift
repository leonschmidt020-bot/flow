// ClipVault — Panel-Bereich „Geteilt": Zeilen, Vorschau, Fortschrittsring, Laden auf Abruf, Speicherstand
//
// Geteilt werden Text/Links, Bilder und Dateien JEDER Art (bis 200 MB je Datei, Ordner als .zip).
// Grosse Eintraege (> 4 MB) liegen auf dem Server in verschluesselten Teilen: der Absender sieht einen
// Fortschrittsring beim Hochladen, der Empfaenger laedt bis 20 MB sofort, groessere per „Laden".
// Lokal liegen die Dateien in ~/.config/flow-clipvault/shared/files/<id>/<name> (Ordner 0700, Datei 0600) und
// werden als ECHTE Datei kopiert (Datei-URL in der Zwischenablage) -> Einfuegen in Finder, Mail, WhatsApp …
import Cocoa
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Kreisfoermiger Fortschritt um das Zeilen-Icon
final class RingView: NSView {
    private let track = CAShapeLayer(), bar = CAShapeLayer()
    var fraction: Double = 0 {
        didSet {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
            bar.strokeEnd = CGFloat(max(0.02, min(1, fraction)))
            CATransaction.commit()
        }
    }
    init(frame: NSRect, color: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        let r = bounds.insetBy(dx: 2, dy: 2)
        let p = CGMutablePath()
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, bar] { l.path = p; l.fillColor = NSColor.clear.cgColor; l.lineWidth = 3; layer?.addSublayer(l) }
        track.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        bar.strokeColor = color.cgColor; bar.lineCap = .round; bar.strokeEnd = 0.02
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // Klicks gehen an die Zeile
}

/// QuickLook-Vorschaubilder geteilter Dateien (klein, im Speicher)
private var cvSharedQL: [String: NSImage] = [:]

extension PanelController {
    static let compactFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "d. MMM, HH:mm"; return f }()
    // MARK: - Aufbau
    func setupSharedFileUI() {
        stylePillButton(loadBtn, "arrow.down.circle", " Laden", tip: "Datei vom Server laden", action: #selector(loadPreviewClicked))
        loadBtn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        styleIconButton(saveDlBtn, "square.and.arrow.down", tip: "In Downloads sichern", action: #selector(saveDownloadsClicked))
        for b in [loadBtn, saveDlBtn] { b.isHidden = true; effect.addSubview(b) }
        prevProgress.style = .bar; prevProgress.isIndeterminate = false; prevProgress.minValue = 0; prevProgress.maxValue = 1
        prevProgress.controlSize = .small; prevProgress.isHidden = true
        effect.addSubview(prevProgress)

        // Speicherstand unten links (nur in „Geteilt")
        storageBar.frame = NSRect(x: 12, y: 10, width: leftW - 24, height: 26)
        storageBar.isHidden = true
        storageLabel.font = .systemFont(ofSize: 11, weight: .medium); storageLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        storageTrack.frame = NSRect(x: 4, y: 10, width: 46, height: 6)
        storageLabel.frame = NSRect(x: 58, y: 5, width: 150, height: 16); storageLabel.lineBreakMode = .byTruncatingTail
        storageTrack.wantsLayer = true; storageTrack.layer?.cornerRadius = 3
        storageTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        storageFill.frame = NSRect(x: 0, y: 0, width: 0, height: 6)
        storageFill.wantsLayer = true; storageFill.layer?.cornerRadius = 3
        storageTrack.addSubview(storageFill)
        let f = NSFont.systemFont(ofSize: 11, weight: .semibold)
        cleanupBtn.isBordered = false; cleanupBtn.bezelStyle = .regularSquare; cleanupBtn.imagePosition = .imageLeading; cleanupBtn.imageHugsTitle = true
        cleanupBtn.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold))
        cleanupBtn.contentTintColor = .white
        cleanupBtn.attributedTitle = NSAttributedString(string: " Große Dateien aufräumen", attributes: [.font: f, .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
        cleanupBtn.wantsLayer = true; cleanupBtn.layer?.cornerRadius = 11
        cleanupBtn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        let bw = " Große Dateien aufräumen".size(withAttributes: [.font: f]).width + 28
        cleanupBtn.frame = NSRect(x: storageBar.frame.width - bw, y: 2, width: bw, height: 22)
        cleanupBtn.toolTip = "Große Dateien (über 20 MB, nicht angeheftet) vom Server löschen — eure geladenen Kopien bleiben"
        cleanupBtn.target = self; cleanupBtn.action = #selector(cleanupClicked)
        for v in [storageLabel, storageTrack, cleanupBtn] as [NSView] { storageBar.addSubview(v) }
        effect.addSubview(storageBar)
    }
    /// Liste in „Geteilt" etwas kuerzer: unten sitzt der Speicherstand
    func layoutForSharedView() {
        let shared = currentCollection == SHARED_CHIP && (SharedVaultHook.backend != nil || CV_READ_ONLY)
        storageBar.isHidden = !shared
        scroll.frame = shared ? NSRect(x: 8, y: 40, width: leftW - 12, height: H - 152) : NSRect(x: 8, y: 8, width: leftW - 12, height: H - 120)
        if shared { updateStorageBar() }
    }
    func storageChanged() { if !storageBar.isHidden { updateStorageBar() } }
    func updateStorageBar() {
        let cands = SharedVault.shared.cleanupCandidates
        cleanupBtn.isHidden = cands.isEmpty
        // Stand vom Server; ohne (noch) Antwort: letzter Stand aus status.txt
        let fallback: SharedStorage? = {
            guard let t = try? String(contentsOfFile: CV_DIR + "status.txt", encoding: .utf8) else { return nil }
            func v(_ k: String) -> Int64? { t.split(separator: "\n").first { $0.hasPrefix(k + "=") }.flatMap { Int64($0.dropFirst(k.count + 1)) } }
            guard let u = v("sync_used"), let q = v("sync_quota") else { return nil }
            return SharedStorage(used: u, quota: q)
        }()
        guard let st = SharedVault.shared.storage ?? fallback, st.quota > 0 else {
            storageLabel.stringValue = "Speicherstand wird geladen …"
            storageTrack.isHidden = true
            storageLabel.frame = NSRect(x: 4, y: 5, width: 200, height: 16)
            return
        }
        storageTrack.isHidden = false
        storageLabel.frame.origin.x = 58
        storageLabel.stringValue = "\(cvBytes(st.used)) von \(cvBytes(st.quota)) genutzt"
        storageLabel.frame.size.width = min(storageLabel.intrinsicContentSize.width + 4, (cleanupBtn.isHidden ? storageBar.frame.width : cleanupBtn.frame.minX) - storageLabel.frame.minX - 6)
        let fr = min(1, Double(st.used) / Double(st.quota))
        storageFill.frame = NSRect(x: 0, y: 0, width: max(fr > 0 ? 4 : 0, storageTrack.frame.width * fr), height: 6)
        storageFill.layer?.backgroundColor = (fr > 0.9 ? NSColor.systemRed : (fr > 0.7 ? NSColor.systemOrange : NSColor.systemTeal)).cgColor
        storageTrack.toolTip = String(format: "%.0f %% belegt", fr * 100)
    }

    // MARK: - Fortschritt (ohne die Liste neu zu bauen)
    func transferChanged(_ id: String, structural: Bool) {
        guard panel.isVisible || CV_READ_ONLY else { return }
        if structural { refreshAfterExternalChange(); return }
        guard let t = SharedVault.shared.transfers[id] else { return }
        if let m = transferMarkers[id] {
            m.ring.fraction = t.fraction
            if let sh = SharedVault.shared.item(id) { m.sub.attributedStringValue = sharedSublineAttr(sh) }
        }
        if previewItemId == id { updatePreviewProgress(t) }
    }
    func updatePreviewProgress(_ t: SharedTransfer) {
        prevProgress.isHidden = false; prevProgress.doubleValue = t.fraction
        ocrLabel.isHidden = false
        ocrLabel.stringValue = (t.dir == .up ? "WIRD HOCHGELADEN" : "WIRD GELADEN") + "  \(Int(t.fraction * 100)) %  ·  \(cvBytes(t.done)) von \(cvBytes(t.total))"
    }

    // MARK: - Texte
    func sharedKindLabel(_ sh: SharedItem) -> String {
        switch sh.kind {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Bild"
        case .file:
            let ext = ((sh.fileName ?? "") as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "Datei" : ext
        }
    }
    /// Zustand eines Bild-/Datei-Eintrags in Worten (nil = nichts Besonderes)
    func sharedState(_ sh: SharedItem) -> (String, NSColor)? {
        let v = SharedVault.shared
        if let t = v.transfers[sh.id] {
            return ((t.dir == .up ? "lädt hoch " : "lädt ") + "\(Int(t.fraction * 100)) %", .systemTeal)
        }
        if let e = sh.uploadError { return (e, .systemRed) }
        if v.pending.contains(sh.id) { return ("wartet auf Sync", NSColor.white.withAlphaComponent(0.48)) }
        guard sh.kind == .file || sh.kind == .image else { return nil }
        if v.isLocal(sh) { return nil }
        if sh.serverGone == true { return ("abgelaufen", .systemOrange) }
        return ("nicht geladen", NSColor.white.withAlphaComponent(0.62))
    }
    func sharedSublineAttr(_ sh: SharedItem) -> NSAttributedString {
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.white.withAlphaComponent(0.48)]
        let out = NSMutableAttributedString()
        let mine = sh.createdBy == SharedVault.shared.me
        out.append(NSAttributedString(string: (mine ? "VON DIR" : "VON \(sh.createdBy.uppercased())"), attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: NSColor.systemTeal, .kern: 0.4]))
        if let (s, c) = sharedState(sh) {   // Zustand zuerst — ist das Wichtigste
            out.append(NSAttributedString(string: "  ·  ", attributes: dim))
            out.append(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: c]))
        }
        if sh.kind == .file || sh.kind == .image, let b = SharedVault.shared.byteSize(sh) {
            out.append(NSAttributedString(string: "  ·  " + cvBytes(b) + (sh.kind == .file ? " · " + sharedKindLabel(sh) : ""), attributes: dim))
        }
        out.append(NSAttributedString(string: "  ·  " + shortTime(sh.updatedAt), attributes: dim))
        return out
    }
    /// Icon fuer eine (evtl. noch nicht geladene) Datei: echtes Finder-Icon, sonst Icon des Dateityps
    func sharedFileIcon(_ sh: SharedItem, size: CGFloat) -> NSImage {
        let ic: NSImage
        if let u = SharedVault.shared.localURL(sh) { ic = NSWorkspace.shared.icon(forFile: u.path) }
        else {
            let ext = ((sh.fileName ?? "") as NSString).pathExtension
            ic = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        ic.size = NSSize(width: size, height: size)
        return ic
    }
    func typeDescription(_ sh: SharedItem) -> String {
        let ext = ((sh.fileName ?? "") as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "Datei" : "\(ext.uppercased())-Datei")
    }

    // MARK: - Zeile
    func makeSharedRow(_ sh: SharedItem, row: Int) -> NSView {
        let rowH: CGFloat = 62
        let v = HoverRowView(frame: NSRect(x: 0, y: 0, width: leftW-24, height: rowH))
        let iconSize: CGFloat = 42
        let icon = NSImageView(frame: NSRect(x: 14, y: (rowH-iconSize)/2, width: iconSize, height: iconSize))
        icon.wantsLayer = true; icon.layer?.cornerRadius = 9; icon.layer?.masksToBounds = true; icon.imageScaling = .scaleProportionallyUpOrDown
        let vault = SharedVault.shared
        let local = vault.isLocal(sh)
        if sh.kind == .image, let th = vault.thumb(sh) { icon.image = th }
        else if sh.kind == .file { icon.image = sharedFileIcon(sh, size: 40); if !local { icon.alphaValue = 0.55 } }
        else {
            let sym = sh.kind == .link ? "globe" : (sh.kind == .image ? "photo" : "doc.text")
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 21, weight: .regular))
            icon.contentTintColor = sh.kind == .link ? .systemTeal : NSColor.white.withAlphaComponent(0.85)
        }
        v.addSubview(icon)
        // Fortschrittsring um das Icon (Hoch-/Herunterladen)
        let ring = RingView(frame: icon.frame.insetBy(dx: -4, dy: -4), color: .systemTeal)
        if let t = vault.transfers[sh.id] { ring.fraction = t.fraction } else { ring.isHidden = true }
        v.addSubview(ring)
        if !local && sh.kind == .file && vault.transfers[sh.id] == nil && sh.serverGone != true {   // kleines „Laden"-Zeichen im Icon
            let dl = NSImageView(frame: NSRect(x: 14 + iconSize - 16, y: (rowH-iconSize)/2 - 2, width: 18, height: 18))
            dl.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor])))
            v.addSubview(dl)
        }
        let textX: CGFloat = 14 + iconSize + 14
        let quick = quickIndex[sh.id]
        let actions = sharedRowActions(sh)
        let aSize: CGFloat = 26, aGap: CGFloat = 6, aPad: CGFloat = 6, pillH: CGFloat = 34
        let slots = actions.count + 2
        let pillW = CGFloat(slots) * aSize + CGFloat(slots - 1) * aGap + aPad * 2
        let pillX = (leftW-24) - pillW - 12
        // Kuerzel ⌘n: ohne Knoepfe an der gewohnten Stelle (wie im Verlauf), sonst links neben der Pille
        let hintX = actions.isEmpty ? (leftW-24) - 12 - 6 - 26 - 34 : pillX - 36
        let textW = actions.isEmpty ? (leftW-24) - textX - (quick != nil ? 92 : 64) : (quick != nil ? hintX - 14 : pillX - 8) - textX
        var title = "Bild"
        if sh.kind == .file { title = sh.fileName ?? "Datei" }
        else if sh.kind != .image { let t = (sh.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines); title = String((t.split(separator: "\n").first.map(String.init) ?? t).prefix(80)) }
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: textX, y: 32, width: textW, height: 20)
        label.font = .systemFont(ofSize: 14); label.textColor = .white
        label.usesSingleLineMode = true; label.lineBreakMode = sh.kind == .file ? .byTruncatingMiddle : .byTruncatingTail
        v.addSubview(label)
        let subA = sharedSublineAttr(sh)
        let sub = NSTextField(labelWithString: "")
        let subEnd = actions.isEmpty ? (leftW-24) - 12 - aPad - aSize - 8 : pillX - 6   // ohne Knoepfe: bis zum Pin (Hover-Pille deckt ab)
        sub.frame = NSRect(x: textX, y: 11, width: subEnd - textX, height: 16)
        sub.usesSingleLineMode = true; sub.lineBreakMode = .byTruncatingTail; sub.attributedStringValue = subA
        v.addSubview(sub)
        // Neu vom Partner: gruener Punkt (weisser Ring) am Zeilenanfang + „NEU" im Untertitel
        let dot = NSView(frame: NSRect(x: 2, y: (rowH - 10)/2, width: 10, height: 10))
        dot.wantsLayer = true; dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = CV_NEW_GREEN.cgColor
        dot.layer?.borderWidth = 1.5; dot.layer?.borderColor = NSColor.white.cgColor
        dot.toolTip = "Neu von \(sh.createdBy)"
        v.addSubview(dot)
        if SharedSeen.shared.isNew(sh) {
            let tagged = NSMutableAttributedString(string: "NEU  ", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .heavy), .foregroundColor: CV_NEW_GREEN, .kern: 0.4])
            tagged.append(subA)
            sub.attributedStringValue = tagged
        } else { dot.isHidden = true }
        newMarkers[sh.id] = (dot, sub, subA)
        if sh.kind == .file || sh.kind == .image { transferMarkers[sh.id] = (ring, sub) }
        if let q = quick {
            let hint = NSTextField(labelWithString: "⌘\(q)")
            hint.font = .systemFont(ofSize: 11, weight: .medium); hint.textColor = NSColor.white.withAlphaComponent(0.30); hint.alignment = .right
            hint.frame = NSRect(x: hintX, y: (rowH-16)/2 + 9, width: 30, height: 16)
            v.addSubview(hint)
        }
        // Pille: [Laden/Abbrechen/Erneut] (immer) · Entfernen (Hover) · Pin
        let pill = NSView(frame: NSRect(x: pillX, y: (rowH-pillH)/2, width: pillW, height: pillH))
        pill.wantsLayer = true; pill.layer?.cornerRadius = pillH/2
        var ax = aPad
        for (sym, tip, sel, tint) in actions {
            let b = FlatButton(frame: NSRect(x: ax, y: (pillH-aSize)/2, width: aSize, height: aSize)); b.payload = sh.id
            b.isBordered = false; b.title = ""; b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            b.contentTintColor = tint; b.toolTip = tip
            b.wantsLayer = true; b.layer?.cornerRadius = aSize/2; b.layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
            b.target = self; b.action = sel
            pill.addSubview(b); ax += aSize + aGap
        }
        let trash = FlatButton(frame: NSRect(x: ax, y: (pillH-aSize)/2, width: aSize, height: aSize)); trash.payload = sh.id
        trash.isBordered = false; trash.title = ""; trash.imagePosition = .imageOnly
        trash.image = NSImage(systemSymbolName: "person.2.slash", accessibilityDescription: "Nicht mehr teilen")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        trash.contentTintColor = NSColor.systemRed.withAlphaComponent(0.9); trash.toolTip = "Aus „Geteilt\" entfernen (Cmd+⌫)"
        trash.target = self; trash.action = #selector(unshareClicked(_:)); trash.isHidden = true
        pill.addSubview(trash); ax += aSize + aGap
        let pin = FlatButton(frame: NSRect(x: ax, y: (pillH-aSize)/2, width: aSize, height: aSize)); pin.payload = sh.id
        pin.isBordered = false; pin.title = ""; pin.imagePosition = .imageOnly
        pin.image = NSImage(systemSymbolName: sh.pinned ? "pin.fill" : "pin", accessibilityDescription: "Anheften")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        pin.contentTintColor = sh.pinned ? .systemYellow : NSColor.white.withAlphaComponent(0.5)
        pin.toolTip = sh.pinned ? "Lösen (Cmd+P)" : (sh.isBig ? "Anheften (Cmd+P) — große Dateien laufen dann nicht ab" : "Anheften (Cmd+P)")
        pin.target = self; pin.action = #selector(sharedPinClicked(_:))
        pill.addSubview(pin)
        v.addSubview(pill)
        func expand() { pill.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.98).cgColor; pill.layer?.borderWidth = 1; pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor; trash.isHidden = false }
        func collapse() { pill.layer?.backgroundColor = NSColor.clear.cgColor; pill.layer?.borderWidth = 0; trash.isHidden = true }
        v.onHover = { [weak self] in
            guard let self = self, self.editingId == nil else { return }
            self.expandedRowCollapse?(); self.selectRow(row); expand(); self.expandedRowCollapse = collapse
        }
        v.onExit = { collapse() }
        return v
    }
    /// sichtbare Knoepfe einer Zeile: Laden · Abbrechen · Erneut hochladen
    func sharedRowActions(_ sh: SharedItem) -> [(String, String, Selector, NSColor)] {
        let v = SharedVault.shared
        if let t = v.transfers[sh.id] {
            return [("xmark", t.dir == .up ? "Hochladen abbrechen (nimmt die Freigabe zurück)" : "Laden abbrechen", #selector(sharedCancelClicked(_:)), .systemRed)]
        }
        if sh.uploadError != nil { return [("arrow.clockwise", "Erneut hochladen", #selector(sharedRetryClicked(_:)), .systemOrange)] }
        if (sh.kind == .file || sh.kind == .image), sh.isBig, !v.isLocal(sh), sh.serverGone != true {
            return [("arrow.down", "Laden (\(cvBytes(sh.size ?? 0)))", #selector(sharedLoadClicked(_:)), .controlAccentColor)]
        }
        return []
    }

    // MARK: - Vorschau
    func showSharedPreview(_ sh: SharedItem) {
        if editingId != nil { return }
        emptyLabel.isHidden = true; resetPreviewChrome()
        copyBtn.isHidden = false; previewURL = nil; previewItemId = sh.id
        defer { layoutTopButtons() }
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let h = NSMutableAttributedString()
        h.append(symAttr("person.2.fill", color: .systemTeal))
        let who = sh.createdBy == SharedVault.shared.me ? "von dir" : "von \(sh.createdBy)"
        var kind = "Text"; if sh.kind == .link { kind = "Link" } else if sh.kind == .image { kind = "Bild" } else if sh.kind == .file { kind = sharedKindLabel(sh) }
        if sh.kind == .file || sh.kind == .image, let b = SharedVault.shared.byteSize(sh) { kind += " · " + cvBytes(b) }
        var extra = ""
        if SharedVault.shared.pending.contains(sh.id) && SharedVault.shared.transfers[sh.id] == nil { extra = "  ·  wartet auf Sync" }
        h.append(NSAttributedString(string: " \(who)  ·  ", attributes: base))
        h.append(symAttr("clock", color: NSColor.white.withAlphaComponent(0.65)))
        let when = (sh.kind == .file || sh.kind == .image) ? PanelController.compactFmt.string(from: sh.updatedAt) : timeFmt.string(from: sh.updatedAt)
        h.append(NSAttributedString(string: " " + when + "  ·  " + kind + extra, attributes: base))
        prevHeader.attributedStringValue = h
        previewPlainHeader = nil
        if SharedSeen.shared.isNew(sh) {
            // „● NEU" vorn in der Kopfzeile; nach 1,5 s in der Vorschau gilt der Eintrag als gesehen
            let tagged = NSMutableAttributedString(string: "● NEU   ", attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .heavy), .foregroundColor: CV_NEW_GREEN, .kern: 0.4])
            tagged.append(h)
            prevHeader.attributedStringValue = tagged
            previewPlainHeader = h
            let sid = sh.id
            seenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self = self, self.previewItemId == sid, self.panel.isVisible || CV_READ_ONLY else { return }
                self.seenTimer = nil
                SharedSeen.shared.markSeen([sid])
            }
        }
        prevScroll.frame = fullPrevFrame; prevImage.frame = fullPrevFrame
        let local = SharedVault.shared.localURL(sh)
        switch sh.kind {
        case .image where local != nil:
            let u = local!
            finderBtn.isHidden = false; saveDlBtn.isHidden = false; openBtn.isHidden = false
            prevImage.toolTip = "Klick: groß ansehen (Quick Look) · Leertaste: Quick Look · ← → blättert"
            if let img = loadThumb(url: u, maxPx: 1600), let src = CGImageSourceCreateWithURL(u as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                fitImage(img, pixel: NSSize(width: (p[kCGImagePropertyPixelWidth] as? Int) ?? 1, height: (p[kCGImagePropertyPixelHeight] as? Int) ?? 1), in: fullPrevFrame)
            } else { prevImage.isHidden = true; openBtn.isHidden = true }
            prevScroll.isHidden = true
            if let t = SharedVault.shared.transfers[sh.id] { layoutProgress(y: 20); updatePreviewProgress(t) }
        case .file, .image:
            showSharedFilePreview(sh, local: local)
        case .text, .link:
            prevImage.isHidden = true
            setPreviewText(cleanedForDisplay(sh.text ?? ""), links: true, query: search.stringValue)
            prevScroll.isHidden = false
        }
    }
    private func layoutProgress(y: CGFloat) {
        prevProgress.frame = NSRect(x: prevX, y: y, width: prevW, height: 12)
        ocrLabel.frame = NSRect(x: prevX + 2, y: y + 14, width: prevW - 4, height: 16)
    }
    /// Datei (oder noch nicht geladenes Bild): grosses Icon/QuickLook oben, Angaben + Zustand unten
    private func showSharedFilePreview(_ sh: SharedItem, local: URL?) {
        let v = SharedVault.shared
        let transfer = v.transfers[sh.id]
        finderBtn.isHidden = local == nil; saveDlBtn.isHidden = local == nil
        if local == nil, sh.isBig, sh.serverGone != true, sh.uploadError == nil {
            let busy = transfer != nil
            let f = NSFont.systemFont(ofSize: 12, weight: .medium)
            let t = busy ? " Abbrechen" : " Laden"
            loadBtn.attributedTitle = NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: NSColor.white])
            loadBtn.image = NSImage(systemSymbolName: busy ? "xmark" : "arrow.down.circle", accessibilityDescription: t)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            loadBtn.layer?.backgroundColor = (busy ? NSColor.white.withAlphaComponent(0.13) : NSColor.controlAccentColor.withAlphaComponent(0.85)).cgColor
            loadBtn.setFrameSize(NSSize(width: t.size(withAttributes: [.font: f]).width + 38, height: 28))
            loadBtn.isHidden = false
        }
        let dh: CGFloat = 170
        prevScroll.frame = NSRect(x: prevX, y: 14, width: prevW, height: dh)
        let imgPane = NSRect(x: prevX, y: 14 + dh + 40, width: prevW, height: fullPrevFrame.maxY - (14 + dh + 40))
        prevImage.frame = imgPane
        if sh.kind == .image {
            prevImage.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: .light).applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.35)])))
        } else if let u = local, let q = cvSharedQL[sh.id + "|" + u.path] { prevImage.image = q }
        else {
            prevImage.image = sharedFileIcon(sh, size: 180)
            if let u = local { loadSharedQL(sh.id, u) }
        }
        prevImage.alphaValue = local == nil ? 0.6 : 1
        prevImage.isHidden = false; prevScroll.isHidden = false
        layoutProgress(y: 14 + dh + 8)
        if let t = transfer { updatePreviewProgress(t) }
        // Angaben
        var lines: [String] = []
        lines.append(sh.kind == .file ? (sh.fileName ?? "Datei") : "Bild")
        var meta: [String] = []
        if let b = v.byteSize(sh) { meta.append(cvBytes(b)) }
        if sh.kind == .file { meta.append(typeDescription(sh)) }
        lines.append(meta.joined(separator: "  ·  "))
        lines.append("")
        if let e = sh.uploadError { lines.append("Nicht hochgeladen: \(e)\nRechtsklick → „Erneut hochladen\".") }
        else if let t = transfer { lines.append(t.dir == .up ? "Wird verschlüsselt hochgeladen …" : "Wird geladen und entschlüsselt …") }
        else if local != nil {
            lines.append("Liegt auf diesem Mac.\n↩︎  Enter / Klick  →  Datei in der Zwischenablage (einfügbar in Finder, Mail, WhatsApp …)\nOder aus der Liste in eine App ziehen.")
        } else if sh.serverGone == true {
            lines.append("Auf dem Server abgelaufen.\n\(sh.createdBy == v.me ? "Du" : sh.createdBy) kann sie erneut teilen — angeheftet läuft sie nicht ab.")
        } else if sh.isBig {
            lines.append("Noch nicht geladen — „Laden\" holt die Datei (\(cvBytes(sh.size ?? 0))).\nEnter / Klick lädt sie und legt sie danach in die Zwischenablage.")
        }
        if let exp = sh.expiresAt, !sh.pinned, sh.serverGone != true {
            let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"
            lines.append("\nLiegt bis \(f.string(from: Date(timeIntervalSince1970: exp))) auf dem Server — anheften, damit sie bleibt.")
        }
        setPreviewText(lines.joined(separator: "\n"), links: false, query: nil)
    }
    private func loadSharedQL(_ id: String, _ url: URL) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 300, height: 300), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep = rep else { return }
            DispatchQueue.main.async {
                if cvSharedQL.count > 24 { cvSharedQL.removeAll() }
                cvSharedQL[id + "|" + url.path] = rep.nsImage
                guard let self = self, self.previewItemId == id, self.currentCollection == SHARED_CHIP else { return }
                self.prevImage.image = rep.nsImage
            }
        }
    }

    // MARK: - Aktionen
    @objc func unshareClicked(_ s: FlatButton) { SharedVaultHook.unshare(s.payload); reload() }
    @objc func sharedPinClicked(_ s: FlatButton) {
        guard let sh = SharedVault.shared.item(s.payload) else { return }
        SharedVaultHook.setPinned(sh.id, !sh.pinned); reload()
        if let idx = display.firstIndex(where: { rowId($0) == sh.id }) { selectRow(idx) }
    }
    @objc func sharedLoadClicked(_ s: FlatButton) { SharedVaultHook.download(s.payload); Toast.shared.show("Wird geladen …") }
    @objc func sharedRetryClicked(_ s: FlatButton) { retryShared(s.payload) }
    @objc func sharedCancelClicked(_ s: FlatButton) { cancelShared(s.payload) }
    func retryShared(_ id: String) {
        if let s = SharedVault.shared.retryUpload(id: id) { SharedVaultHook.backend?.push(s); Toast.shared.show("Wird erneut hochgeladen") }
    }
    /// Abbrechen: Laden -> nur stoppen · Hochladen -> stoppen UND Freigabe zuruecknehmen (halbe Datei nuetzt keinem)
    func cancelShared(_ id: String) {
        guard let t = SharedVault.shared.transfers[id] else { return }
        if t.dir == .up { SharedVaultHook.unshare(id); Toast.shared.show("Hochladen abgebrochen") }
        else { SharedVaultHook.cancelTransfer(id); Toast.shared.show("Laden abgebrochen") }
    }
    @objc func loadPreviewClicked() {
        guard let id = previewItemId else { return }
        if SharedVault.shared.transfers[id] != nil { cancelShared(id) } else { SharedVaultHook.download(id) }
    }
    @objc func saveDownloadsClicked() { if let id = previewItemId { saveSharedToDownloads(id) } }
    func saveSharedToDownloads(_ id: String) {
        guard let dest = SharedVault.shared.saveToDownloads(id: id) else { Toast.shared.show("Datei noch nicht geladen"); return }
        Toast.shared.show("In Downloads gesichert")
        cvLog("Geteilt: in Downloads gesichert (\(dest.lastPathComponent))")
    }
    func revealShared(_ id: String) {
        guard let s = SharedVault.shared.item(id), let u = SharedVault.shared.localURL(s) else { Toast.shared.show("Datei noch nicht geladen"); return }
        hide(); NSWorkspace.shared.activateFileViewerSelecting([u])
    }
    @objc func cleanupClicked() {
        let list = SharedVault.shared.cleanupCandidates
        guard !list.isEmpty else { return }
        let bytes = list.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let a = NSAlert()
        a.messageText = "Große Dateien aufräumen?"
        a.informativeText = "\(list.count == 1 ? "1 Datei" : "\(list.count) Dateien") (\(cvBytes(bytes))) über 20 MB werden vom Server gelöscht. Wer sie schon geladen hat, behält sie. Angeheftete bleiben."
        a.addButton(withTitle: "Aufräumen"); a.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        SharedVaultHook.cleanupBig()
        Toast.shared.show("\(cvBytes(bytes)) freigegeben")
    }

    // MARK: - Rechtsklick
    func addSharedFileMenuItems(_ menu: NSMenu, _ sh: SharedItem) {
        guard sh.kind == .file || sh.kind == .image else { return }
        let v = SharedVault.shared
        if let t = v.transfers[sh.id] {
            menu.addItem(menuItem(t.dir == .up ? "Hochladen abbrechen" : "Laden abbrechen", "xmark.circle", #selector(sharedCancelAction(_:)), sh.id))
        } else if sh.uploadError != nil {
            menu.addItem(menuItem("Erneut hochladen", "arrow.clockwise", #selector(sharedRetryAction(_:)), sh.id))
        } else if !v.isLocal(sh), sh.isBig, sh.serverGone != true {
            menu.addItem(menuItem("Laden (\(cvBytes(sh.size ?? 0)))", "arrow.down.circle", #selector(sharedLoadAction(_:)), sh.id))
        }
        if v.isLocal(sh) {
            menu.addItem(menuItem("Im Finder zeigen", "folder", #selector(sharedRevealAction(_:)), sh.id))
            menu.addItem(menuItem("In Downloads sichern", "square.and.arrow.down", #selector(sharedSaveAction(_:)), sh.id))
        }
    }
    @objc func sharedCancelAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { cancelShared(id) } }
    @objc func sharedRetryAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { retryShared(id) } }
    @objc func sharedLoadAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { SharedVaultHook.download(id) } }
    @objc func sharedRevealAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { revealShared(id) } }
    @objc func sharedSaveAction(_ s: NSMenuItem) { if let id = s.representedObject as? String { saveSharedToDownloads(id) } }
}

/// „1,2 GB", „90,2 MB" (deutsch)
func cvBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: n)
}
