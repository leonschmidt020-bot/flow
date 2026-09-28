import AppKit
import SwiftUI

// MARK: - Flow: illustrierte Meldungs-Karten, die aus der Pille wachsen (wie Dynamic Island)
//
// Die Karte startet als dunkle Kapsel exakt auf der Pille und federt dann in die volle Karte auf
// (Größe + Eckenradius + Lage), der Inhalt blendet kurz danach ein. Beim Schließen schrumpft sie
// zurück in die Pille und blendet aus. Karte liegt immer auf der Seite der Pille, die zur
// Bildschirmmitte zeigt (Pille unten → Karte darüber, Pille rechts → Karte links daneben …)
// und bleibt komplett auf EINEM Bildschirm.
// Immer nur EINE Karte sichtbar – weitere warten in einer Schlange.
//
// Einrichten (AppDelegate):  VFNotify.shared.pillAnchor = { [weak self] in self?.pill.view.capsuleRectInScreen }
// Aufruf:                    VFNotify.shared.show(.meetingDetected(app: "Zoom", accept: { … }, dismiss: { … }))
//                            VFNotify.shared.show(id:title:text:illustration:primary:secondary:timeout:anchor:)
//                            VFNotify.shared.dismiss(id: "meeting_erkannt")

/// Eine Meldung (Inhalt + Aktionen). Voreinstellungen siehe `extension VFNotice` unten.
struct VFNotice {
    var id: String
    var title: String
    var text: String
    /// Asset-Name ohne Endung (`VFAsset.image`), z. B. „illu_meeting_erkannt“
    var illustration: String
    /// SF-Symbol, falls die Illustration fehlt
    var fallbackSymbol: String = "sparkles"
    var primary: (String, () -> Void)? = nil
    var secondary: (String, () -> Void)? = nil
    /// nil = bleibt stehen, bis geklickt wird. Solange die Maus darauf ist, läuft die Zeit nicht ab.
    var timeout: TimeInterval? = 12
    /// Bildschirm-Rechteck, aus dem die Karte wächst. nil = `VFNotify.shared.pillAnchor()` (die Pille).
    var anchor: NSRect? = nil
    /// Wird bei ✕ und bei Zeitablauf aufgerufen (NICHT nach einem Knopf-Klick).
    var onClose: (() -> Void)? = nil
    /// Auswahl-Chips (z. B. Schreibweisen beim Wort-Lernen). Der erste ist vorgewählt; `VFNotify.shared.chosen` liefert die Wahl.
    var choices: [String] = []
    /// Art-Marke über dem Text (z. B. „Auftrag für deinen Agent“ beim Geteilten) – Text ist dann die Kernaussage
    var chip: VFNoticeChip? = nil
}

/// Kleine farbige Marke in der Karte (Symbol + Wort)
struct VFNoticeChip {
    var label: String
    var symbol: String
    var tint: Color
}

final class VFNotify {
    static let shared = VFNotify()

    /// Liefert die Pille (Kapsel) in Bildschirmkoordinaten – vom AppDelegate zu setzen.
    var pillAnchor: (() -> NSRect?)?

    /// Bildquelle (für Tests austauschbar). Standard: Resources/Assets über VFAsset.
    static var imageProvider: (String) -> NSImage? = { VFAsset.image($0) }

    // Maße
    static let cardHeight: CGFloat = 140
    /// Zusatzhöhe für die Auswahl-Chips
    static let chipRow: CGFloat = 40
    /// Zusatzhöhe für die Art-Marke (VFNotice.chip)
    static let kindRow: CGFloat = 26
    static let minCardWidth: CGFloat = 432
    static let maxCardWidth: CGFloat = 540
    static let tileSize: CGFloat = 140
    /// So weit ragt die Illustration oben über die Karte hinaus
    static let tileOverlap: CGFloat = 16
    static let cornerRadius: CGFloat = 22
    /// Abstand Pille ↔ Karte
    static let gap: CGFloat = 12
    /// Platz um die Karte im Fenster (Schatten, Überstand, Feder-Überschwingen)
    static let windowMargin: CGFloat = 30
    /// Mindestabstand der Karte zum Rand des sichtbaren Bildschirmbereichs
    static let screenInset: CGFloat = 10

    private var queue: [VFNotice] = []
    private var current: VFNotice?
    private var panel: VFNotifyPanel?
    private var model: VFNotifyModel?
    private var timer: Timer?
    private var hitTimer: Timer?
    private var closing = false

    var isShowing: Bool { current != nil }
    var currentID: String? { current?.id }

    // MARK: Öffentliche Schnittstelle

    func show(id: String, title: String, text: String, illustration: String,
              primary: (String, () -> Void)? = nil, secondary: (String, () -> Void)? = nil,
              timeout: TimeInterval? = 12, anchor: NSRect? = nil, onClose: (() -> Void)? = nil) {
        show(VFNotice(id: id, title: title, text: text, illustration: illustration,
                      fallbackSymbol: VFNotify.symbol(for: illustration),
                      primary: primary, secondary: secondary, timeout: timeout, anchor: anchor, onClose: onClose))
    }

    /// Abwechslung: gibt es zu einem Bild Varianten (illu_x_2, illu_x_3 …), wird zufällig eine gezeigt – nie zweimal hintereinander dieselbe.
    private var lastVariant: [String: String] = [:]
    func pickVariant(_ name: String) -> String {
        guard name.range(of: #"_\d+$"#, options: .regularExpression) == nil else { return name }   // schon eine feste Variante
        let all = [name] + (2...9).map { "\(name)_\($0)" }.filter { VFAsset.image($0) != nil }
        guard all.count > 1 else { return name }
        let pick = all.filter { $0 != lastVariant[name] }.randomElement() ?? name
        lastVariant[name] = pick
        return pick
    }

    func show(_ n: VFNotice) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.show(n) }; return }
        var n = n
        if current?.id == n.id, let cur = current { n.illustration = cur.illustration }   // gleiche Karte aktualisiert: Bild behalten
        else { n.illustration = pickVariant(n.illustration) }
        // Gleiche ID sichtbar → Inhalt austauschen statt doppelt zeigen
        if current?.id == n.id, !closing, let m = model {
            if m.notice.choices != n.choices { m.selected = 0 }
            current = n
            let lay = VFNotify.layout(for: n, pill: resolvePill(n))
            m.notice = n
            m.layout = lay
            panel?.setFrame(lay.windowFrame, display: true)
            restartTimer()
            return
        }
        if let i = queue.firstIndex(where: { $0.id == n.id }) { queue[i] = n; return }
        queue.append(n)
        if current == nil { next() }
    }

    func dismiss(id: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.dismiss(id: id) }; return }
        queue.removeAll { $0.id == id }
        if current?.id == id { close(reason: .programmatic) }
    }

    /// Alles schließen (Schlange leeren), ohne Rückrufe.
    func dismissAll() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.dismissAll() }; return }
        queue.removeAll()
        if current != nil { close(reason: .programmatic) }
    }

    // MARK: Ablauf

    private enum CloseReason { case button, xOrTimeout, programmatic }

    private func resolvePill(_ n: VFNotice) -> NSRect {
        if let a = n.anchor, a.width > 0 { return a }
        if let a = pillAnchor?(), a.width > 0, a.height > 0 { return a }
        // Keine Pille bekannt: gedachte Pille unten mittig auf dem Bildschirm unter der Maus
        let s = VFNotify.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        let vis = s?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: vis.midX - 22, y: vis.minY + 14, width: 44, height: 9)
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        let n = queue.removeFirst()
        current = n
        closing = false
        let lay = VFNotify.layout(for: n, pill: resolvePill(n))
        let m = VFNotifyModel(notice: n, layout: lay)
        m.onPrimary = { [weak self] in self?.fire(\.primary) }
        m.onSecondary = { [weak self] in self?.fire(\.secondary) }
        m.onClose = { [weak self] in self?.close(reason: .xOrTimeout) }
        model = m

        let p = panel ?? VFNotifyPanel()
        panel = p
        let host = VFNotifyHostingView(rootView: VFNotifyStage(model: m))
        host.frame = NSRect(origin: .zero, size: lay.windowFrame.size)
        p.contentView = host
        p.setFrame(lay.windowFrame, display: false)
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        // Nächster Durchlauf: erst dann federn (Startbild = Kapsel auf der Pille ist schon gezeichnet)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.76)) { m.progress = 1 }
        }
        startHitTesting()
        restartTimer()
    }

    /// Zuletzt gewählter Chip (gesetzt direkt bevor die Knopf-Aktion läuft)
    private(set) var chosen: String?

    private func fire(_ kp: KeyPath<VFNotice, (String, () -> Void)?>) {
        guard let n = current, !closing else { return }
        chosen = n.choices.indices.contains(model?.selected ?? 0) ? n.choices[model?.selected ?? 0] : nil
        let action = n[keyPath: kp]?.1
        close(reason: .button)
        action?()
    }

    private func restartTimer() {
        timer?.invalidate(); timer = nil
        guard let t = current?.timeout, t > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.timeoutFired() }
    }

    private func timeoutFired() {
        guard current != nil, !closing else { return }
        if model?.hovering == true {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.timeoutFired() }
            return
        }
        close(reason: .xOrTimeout)
    }

    /// Klicks nur auf der Karte annehmen – der Rest des Fensters (Rand, Pille) bleibt durchklickbar.
    private func startHitTesting() {
        hitTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.panel, let m = self.model else { return }
            let hot = m.layout.hitRectsInScreen.contains { $0.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) }
            let active = hot && m.progress > 0.9 && !self.closing
            if p.ignoresMouseEvents == active { p.ignoresMouseEvents = !active }
            if m.hovering != hot { m.hovering = hot }
        }
        RunLoop.main.add(t, forMode: .common)
        hitTimer = t
    }

    private func close(reason: CloseReason) {
        guard let n = current, !closing, let m = model else { return }
        closing = true
        timer?.invalidate(); timer = nil
        hitTimer?.invalidate(); hitTimer = nil
        panel?.ignoresMouseEvents = true
        if reason == .xOrTimeout { n.onClose?() }
        // Zurück in die Pille schrumpfen und ausblenden
        withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) { m.progress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel?.contentView = nil
            self.model = nil
            self.current = nil
            self.closing = false
            if !self.queue.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.next() }
            }
        }
    }

    // MARK: Geometrie

    enum Side { case above, below, left, right }

    /// Alle Rechtecke für eine Karte. Fenster in Bildschirmkoordinaten, pill/card in Fensterkoordinaten (oben links = 0,0).
    struct Layout {
        var windowFrame: NSRect
        var pill: CGRect
        var card: CGRect
        var side: Side
        /// Karte + überstehende Illustration in Bildschirmkoordinaten (für Klicks/Hover)
        var hitRectsInScreen: [NSRect]
    }

    static func screen(containing p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    /// Kartenbreite so, dass beide Knöpfe ungekürzt passen (Text darf 2 Zeilen umbrechen)
    static func cardSize(for n: VFNotice) -> NSSize {
        func w(_ s: String, _ weight: NSFont.Weight) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight)]).width)
        }
        var buttons: CGFloat = 0
        if let p = n.primary { buttons += w(p.0, .semibold) + 32 }
        if let s = n.secondary { buttons += w(s.0, .medium) + 24 + (n.primary != nil ? 6 : 0) }
        let chrome: CGFloat = 22 + 18 + tileSize + 14 + 4   // links + Abstand + Kachel + rechts + Luft
        var chips: CGFloat = 0
        if n.choices.count > 1 { chips = n.choices.map { min(w($0, .medium), 180) + 26 }.reduce(0, +) + CGFloat(n.choices.count - 1) * 6 }
        let width = min(maxCardWidth, max(minCardWidth, max(buttons, chips) + chrome))
        return NSSize(width: width, height: cardHeight + (n.choices.count > 1 ? chipRow : 0) + (n.chip != nil ? kindRow : 0))
    }

    static func layout(for n: VFNotice, pill: NSRect) -> Layout {
        let scr = screen(containing: NSPoint(x: pill.midX, y: pill.midY)) ?? screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        return layout(for: n, pill: pill, visible: scr?.visibleFrame ?? pill.insetBy(dx: -800, dy: -600),
                      frame: scr?.frame ?? pill.insetBy(dx: -800, dy: -600))
    }

    /// Reine Berechnung (testbar ohne echte Bildschirme). Alle Eingaben in Bildschirmkoordinaten (Cocoa, unten links).
    static func layout(for n: VFNotice, pill: NSRect, visible vis: NSRect, frame sf: NSRect) -> Layout {
        let cs = cardSize(for: n)
        let side: Side
        let fx = (pill.midX - vis.minX) / max(vis.width, 1)
        if pill.height > pill.width * 1.5 {
            side = fx > 0.5 ? .left : .right                   // Pille hochkant am Rand → zur Mitte hin daneben
        } else {
            side = pill.midY < vis.midY ? .above : .below
        }
        var card: NSRect
        switch side {
        case .above: card = NSRect(x: pill.midX - cs.width / 2, y: pill.maxY + gap, width: cs.width, height: cs.height)
        case .below: card = NSRect(x: pill.midX - cs.width / 2, y: pill.minY - gap - tileOverlap - cs.height, width: cs.width, height: cs.height)
        case .left: card = NSRect(x: pill.minX - gap - cs.width, y: pill.midY - cs.height / 2, width: cs.width, height: cs.height)
        case .right: card = NSRect(x: pill.maxX + gap, y: pill.midY - cs.height / 2, width: cs.width, height: cs.height)
        }
        // Karte (inkl. Überstand oben) in den sichtbaren Bereich klemmen
        let i = screenInset
        card.origin.x = min(max(card.minX, vis.minX + i), vis.maxX - i - cs.width)
        card.origin.y = min(max(card.minY, vis.minY + i), vis.maxY - i - tileOverlap - cs.height)
        // Fenster = Karte ∪ Pille + Rand, komplett innerhalb EINES Bildschirms
        var win = card.union(pill).insetBy(dx: -windowMargin, dy: -windowMargin)
        win.origin.x = max(win.minX, sf.minX); win.origin.y = max(win.minY, sf.minY)
        win.size.width = min(win.maxX, sf.maxX) - win.minX
        win.size.height = min(win.maxY, sf.maxY) - win.minY
        win = win.integral
        func toWin(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX - win.minX, y: win.maxY - r.maxY, width: r.width, height: r.height)
        }
        let tileScreen = NSRect(x: card.maxX - 14 - tileSize, y: card.maxY + tileOverlap - tileSize, width: tileSize, height: tileSize)
        return Layout(windowFrame: win, pill: toWin(pill), card: toWin(card), side: side, hitRectsInScreen: [card, tileScreen])
    }

    /// Ersatz-Symbol je Illustration, solange die Bilder fehlen
    static func symbol(for illustration: String) -> String {
        switch illustration {
        case "illu_meeting_erkannt": return "person.2.wave.2.fill"
        case "illu_meeting_vorbei": return "stop.circle.fill"
        case "illu_wort_gelernt": return "character.book.closed.fill"
        case "illu_mikrofon": return "mic.slash.fill"
        case "illu_willkommen": return "hand.wave.fill"
        case "illu_stimme": return "waveform"
        case "illu_insights": return "chart.bar.fill"
        case "illu_scratchpad": return "doc.text.fill"
        case "illu_snippet": return "text.badge.plus"
        case "illu_transforms": return "wand.and.stars"
        default: return "sparkles"
        }
    }

    // MARK: Offscreen-Bilder (Sichtprüfung / Tests)

    /// Rendert eine Karte bei Fortschritt `progress` (0 = Kapsel auf der Pille, 1 = volle Karte) als PNG.
    /// Zeichnet einen Schreibtisch-Hintergrund + die Pille darunter, damit das Wachsen sichtbar ist.
    @discardableResult
    static func renderPNG(_ n: VFNotice, to url: URL, progress: CGFloat = 1,
                          pill: NSRect = NSRect(x: 700, y: 30, width: 66, height: 24),
                          screen: NSRect = NSRect(x: 0, y: 0, width: 1512, height: 949),
                          background: NSColor = NSColor(white: 0.90, alpha: 1)) -> Bool {
        _ = NSApplication.shared
        let lay = layout(for: n, pill: pill, visible: screen, frame: screen)
        let m = VFNotifyModel(notice: n, layout: lay)
        m.progress = progress
        let root = ZStack(alignment: .topLeading) {
            Color(nsColor: background)
            // die echte Pille (Sprechen-Zustand) darunter
            Capsule().fill(Color.black.opacity(0.92))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.32), lineWidth: 1))
                .frame(width: lay.pill.width, height: lay.pill.height)
                .offset(x: lay.pill.minX, y: lay.pill.minY)
            VFNotifyStage(model: m)
        }
        .frame(width: lay.windowFrame.width, height: lay.windowFrame.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: lay.windowFrame.size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

// MARK: - Voreinstellungen (deutsch)

extension VFNotice {
    /// Eine App nutzt das Mikrofon → mitschreiben?
    static func meetingDetected(app: String, accept: @escaping () -> Void, dismiss: @escaping () -> Void,
                                anchor: NSRect? = nil) -> VFNotice {
        VFNotice(id: "meeting_erkannt", title: "Meeting erkannt",
                 text: "\(app) nutzt das Mikrofon. Soll Flow mitschreiben?",
                 illustration: "illu_meeting_erkannt", fallbackSymbol: VFNotify.symbol(for: "illu_meeting_erkannt"),
                 primary: ("Aufnehmen", accept), secondary: ("Nicht jetzt", dismiss),
                 timeout: 20, anchor: anchor, onClose: dismiss)
    }

    /// Mikrofon der Meeting-App ist aus → beenden?
    /// 28.09.2026: Schließen, Ablaufen oder Verdrängen (neues Diktat) zählte als „Weiter aufnehmen“ und schaltete das
    /// automatische Beenden ab – nach einem WhatsApp-Anruf lief die Aufnahme endlos weiter. Jetzt: nur der Knopf
    /// „Weiter aufnehmen“ hält die Aufnahme; alles andere meldet `dismissed`, der Controller beendet dann selbst.
    static func meetingOver(app: String, end: @escaping () -> Void, keep: @escaping () -> Void,
                            dismissed: @escaping () -> Void = {}, anchor: NSRect? = nil) -> VFNotice {
        VFNotice(id: "meeting_vorbei", title: "Meeting abgeschlossen?",
                 text: "\(app) nutzt das Mikrofon nicht mehr.",
                 illustration: "illu_meeting_vorbei", fallbackSymbol: VFNotify.symbol(for: "illu_meeting_vorbei"),
                 primary: ("Ja, beenden", end), secondary: ("Weiter aufnehmen", keep),
                 timeout: 45, anchor: anchor, onClose: dismissed)
    }

    /// Korrektur im Textfeld erkannt → ins Wörterbuch?
    static func wordLearned(old: String, new: String, save: @escaping () -> Void, skip: @escaping () -> Void,
                            anchor: NSRect? = nil) -> VFNotice {
        VFNotice(id: "wort_gelernt", title: "Neues Wort?",
                 text: "„\(old)“ → „\(new)“ – soll ich mir das merken?",
                 illustration: "illu_wort_gelernt", fallbackSymbol: VFNotify.symbol(for: "illu_wort_gelernt"),
                 primary: ("Speichern", save), secondary: ("Nein", skip),
                 timeout: 15, anchor: anchor, onClose: skip)
    }

    /// Mit mehreren Vorschlägen: du wählst die richtige Schreibweise per Chip.
    static func wordLearned(old: String, options: [String], save: @escaping (String) -> Void, skip: @escaping () -> Void,
                            anchor: NSRect? = nil) -> VFNotice {
        guard options.count > 1 else {
            let only = options.first ?? old
            return wordLearned(old: old, new: only, save: { save(only) }, skip: skip, anchor: anchor)
        }
        return VFNotice(id: "wort_gelernt", title: "Neues Wort?",
                        text: "„\(old)“ – was hast du gemeint?",
                        illustration: "illu_wort_gelernt", fallbackSymbol: VFNotify.symbol(for: "illu_wort_gelernt"),
                        primary: ("Speichern", { save(VFNotify.shared.chosen ?? options[0]) }), secondary: ("Nein", skip),
                        timeout: 20, anchor: anchor, onClose: skip, choices: options)
    }

    /// Mikrofon-Zugriff fehlt / kein Mikrofon
    static func micMissing(open: @escaping () -> Void) -> VFNotice {
        VFNotice(id: "mikrofon_fehlt", title: "Mikrofon fehlt",
                 text: "Kein Mikrofon-Zugriff. Gib ihn in den Systemeinstellungen frei.",
                 illustration: "illu_mikrofon", fallbackSymbol: VFNotify.symbol(for: "illu_mikrofon"),
                 primary: ("Einstellungen öffnen", open), secondary: nil, timeout: nil)
    }

    /// Erster Start
    static func welcome(open: @escaping () -> Void) -> VFNotice {
        VFNotice(id: "willkommen", title: "Willkommen bei Flow",
                 text: "Halte fn und sprich – der Text landet dort, wo dein Cursor steht.",
                 illustration: "illu_willkommen", fallbackSymbol: VFNotify.symbol(for: "illu_willkommen"),
                 primary: ("Los geht’s", open), secondary: ("Später", {}), timeout: 30)
    }

    /// Stimme noch nicht eingelernt
    static func voiceEnroll(open: @escaping () -> Void) -> VFNotice {
        VFNotice(id: "stimme_einlernen", title: "Stimme einlernen",
                 text: "30 Sekunden vorlesen – dann schreibt Flow nur noch deine Stimme mit.",
                 illustration: "illu_stimme", fallbackSymbol: VFNotify.symbol(for: "illu_stimme"),
                 primary: ("Jetzt einlernen", open), secondary: ("Später", {}), timeout: 20)
    }

    /// Meeting-Transkript / Zusammenfassung fertig
    static func transcriptReady(title: String, open: @escaping () -> Void, illustration: String = "illu_insights") -> VFNotice {
        VFNotice(id: "transkript_fertig", title: "Transkript fertig",
                 text: "„\(title)“ – Zusammenfassung und Transkript sind bereit.",
                 illustration: illustration, fallbackSymbol: VFNotify.symbol(for: illustration),
                 primary: ("Öffnen", open), secondary: nil, timeout: 15)
    }
}

/// Bequeme Kurzformen: `VFNotify.shared.meetingDetected(app:accept:dismiss:)` usw.
extension VFNotify {
    func meetingDetected(app: String, accept: @escaping () -> Void, dismiss: @escaping () -> Void, anchor: NSRect? = nil) {
        show(.meetingDetected(app: app, accept: accept, dismiss: dismiss, anchor: anchor))
    }
    func meetingOver(app: String, end: @escaping () -> Void, keep: @escaping () -> Void,
                     dismissed: @escaping () -> Void = {}, anchor: NSRect? = nil) {
        show(.meetingOver(app: app, end: end, keep: keep, dismissed: dismissed, anchor: anchor))
    }
    func wordLearned(old: String, new: String, save: @escaping () -> Void, skip: @escaping () -> Void, anchor: NSRect? = nil) {
        show(.wordLearned(old: old, new: new, save: save, skip: skip, anchor: anchor))
    }
    func wordLearned(old: String, options: [String], save: @escaping (String) -> Void, skip: @escaping () -> Void, anchor: NSRect? = nil) {
        show(.wordLearned(old: old, options: options, save: save, skip: skip, anchor: anchor))
    }
    func micMissing(open: @escaping () -> Void) { show(.micMissing(open: open)) }
    func welcome(open: @escaping () -> Void) { show(.welcome(open: open)) }
    func voiceEnroll(open: @escaping () -> Void) { show(.voiceEnroll(open: open)) }
    func transcriptReady(title: String, open: @escaping () -> Void) { show(.transcriptReady(title: title, open: open)) }
}

// MARK: - Fenster

/// Randloses Panel, das nie Fokus nimmt (Diktat-Ziel bleibt aktiv), aber Klicks annimmt.
final class VFNotifyPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false             // Schatten zeichnet die Karte selbst
        level = .statusBar
        // NIE .moveToActiveSpace zusammen mit .canJoinAllSpaces (stürzt ab)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Erster Klick zählt sofort (Panel ist nie aktiv).
final class VFNotifyHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI

final class VFNotifyModel: ObservableObject {
    @Published var notice: VFNotice
    @Published var layout: VFNotify.Layout
    /// 0 = Kapsel exakt auf der Pille, 1 = volle Karte (Feder darf kurz über 1 schwingen)
    @Published var progress: CGFloat = 0
    @Published var hovering = false
    /// Gewählter Chip (Index in `notice.choices`)
    @Published var selected = 0
    var onPrimary: () -> Void = {}
    var onSecondary: () -> Void = {}
    var onClose: () -> Void = {}
    init(notice: VFNotice, layout: VFNotify.Layout) { self.notice = notice; self.layout = layout }
}

enum VFNotifyStyle {
    static let card = Color(red: 0.067, green: 0.067, blue: 0.067)          // #111
    /// Pastellgrund + Symbolfarbe, falls die Illustration fehlt
    static func fallbackColors(_ illustration: String) -> (Color, Color) {
        switch illustration {
        case "illu_meeting_erkannt", "illu_mikrofon", "illu_scratchpad":
            return (Color(red: 0.98, green: 0.89, blue: 0.83), Color(red: 0.72, green: 0.40, blue: 0.25))   // Pfirsich
        case "illu_meeting_vorbei", "illu_insights":
            return (Color(red: 0.85, green: 0.94, blue: 0.93), Color(red: 0.22, green: 0.50, blue: 0.47))   // Mint
        case "illu_wort_gelernt", "illu_snippet":
            return (Color(red: 0.99, green: 0.94, blue: 0.80), Color(red: 0.66, green: 0.50, blue: 0.12))   // Butter
        default:
            return (Color(red: 0.92, green: 0.86, blue: 0.98), Color(red: 0.45, green: 0.30, blue: 0.66))   // Lila
        }
    }
}

/// Ganze Fensterfläche; die Karte wird per Fortschritt aus der Pille gemorpht.
struct VFNotifyStage: View {
    @ObservedObject var model: VFNotifyModel

    var body: some View {
        Color.clear
            .frame(width: model.layout.windowFrame.width, height: model.layout.windowFrame.height)
            .modifier(VFMorph(progress: model.progress, layout: model.layout, content: AnyView(VFNotifyCardContent(model: model))))
            .environment(\.colorScheme, .dark)
    }
}

/// Animierbarer Übergang Pille → Karte: Rechteck, Eckenradius, Farbe, Rand, Inhalt.
struct VFMorph: ViewModifier, Animatable {
    var progress: CGFloat
    let layout: VFNotify.Layout
    let content: AnyView

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    func body(content base: Content) -> some View {
        let p = progress                       // darf beim Federn leicht > 1 sein
        let c = min(1, max(0, p))
        let a = layout.pill, b = layout.card
        // Rechteck um die Mittelpunkte interpolieren (Überschwingen wächst symmetrisch)
        let cx = Self.lerp(a.midX, b.midX, c), cy = Self.lerp(a.midY, b.midY, c)
        let w = max(a.width, Self.lerp(a.width, b.width, p)), h = max(a.height, Self.lerp(a.height, b.height, p))
        let radius = Self.lerp(min(a.width, a.height) / 2, VFNotify.cornerRadius, c)
        let shapeAlpha = Self.smooth(0, 0.1, p)        // Anfang/Ende: verschmilzt mit der Pille
        let contentAlpha = Self.smooth(0.45, 0.92, p)  // Inhalt kommt ~120 ms nach dem Start
        let border = Self.lerp(0.32, 0.08, c)          // Pillen-Rand → feiner Kartenrand
        let fill = Color(white: Self.lerp(0, 0.067, c))
        // Inhalt wächst mit der Form mit und bleibt in ihr (Dynamic-Island-Gefühl)
        let scale = min(1, max(0.7, min(w / b.width, h / b.height)))
        let ov = VFNotify.tileOverlap * c              // Platz für die überstehende Illustration
        let release = 40 * Self.smooth(0.9, 1.0, p)    // am Ende Maske öffnen (Schatten nicht abschneiden)
        let W = layout.windowFrame.width, H = layout.windowFrame.height

        return base.overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(border), lineWidth: 1))
                    .shadow(color: .black.opacity(0.28 * c), radius: 18, x: 0, y: 8)
                    .shadow(color: .black.opacity(0.18 * c), radius: 3, x: 0, y: 1)
                    .frame(width: w, height: h)
                    .offset(x: cx - w / 2, y: cy - h / 2)
                    .opacity(shapeAlpha)
                ZStack(alignment: .topLeading) {
                    content
                        .frame(width: b.width, height: b.height)
                        .scaleEffect(scale, anchor: .center)
                        .offset(x: cx - b.width / 2, y: cy - b.height / 2)
                }
                .frame(width: W, height: H, alignment: .topLeading)
                .mask(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: radius + release, style: .continuous)
                        .frame(width: w + 2 * release, height: h + ov + 2 * release)
                        .offset(x: cx - w / 2 - release, y: cy - h / 2 - ov - release)
                }
                .opacity(contentAlpha)
                .allowsHitTesting(contentAlpha > 0.95)
            }
        }
    }
}

/// Inhalt der Karte (ohne Hintergrund – den zeichnet VFMorph).
struct VFNotifyCardContent: View {
    @ObservedObject var model: VFNotifyModel

    var body: some View {
        let n = model.notice
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(n.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let chip = n.chip {
                    HStack(spacing: 4) {
                        Image(systemName: chip.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(chip.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(chip.tint)
                    .padding(.horizontal, 8).frame(height: 21)
                    .background(Capsule().fill(chip.tint.opacity(0.15)))
                    .fixedSize()
                    .padding(.top, 8)
                    Text(n.text)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } else {
                    Text(n.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(2)
                        .lineLimit(3)   // 28.09.: „… ist zusammengefasst un…“ wurde nach 2 Zeilen abgeschnitten
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
                if n.choices.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(Array(n.choices.enumerated()), id: \.offset) { i, c in
                            let on = model.selected == i
                            Button { model.selected = i } label: {
                                Text(c.count > 24 ? String(c.prefix(23)) + "…" : c)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(on ? .white : .white.opacity(0.66))
                                    .lineLimit(1).fixedSize()
                                    .padding(.horizontal, 12)
                                    .frame(height: 28)
                                    .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0.06)))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.55 : 0.12), lineWidth: 1))
                                    .clipShape(Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 10)
                }
                Spacer(minLength: 8)
                if n.primary != nil || n.secondary != nil {
                    HStack(spacing: 6) {
                        if let p = n.primary {
                            Button(action: model.onPrimary) {
                                Text(p.0)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .lineLimit(1).fixedSize()
                                    .padding(.horizontal, 16)
                                    .frame(height: 30)
                                    .background(Capsule().fill(Color.white))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(VFPressStyle())
                        }
                        if let s = n.secondary {
                            Button(action: model.onSecondary) {
                                Text(s.0)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(1).fixedSize()
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(VFPressStyle(hoverFill: true))
                        }
                    }
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            illustrationTile(n)
                .offset(y: -VFNotify.tileOverlap)
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
    }

    @ViewBuilder private func illustrationTile(_ n: VFNotice) -> some View {
        let s = VFNotify.tileSize
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = VFNotify.imageProvider(n.illustration) {
                    ZStack {
                        VFNotifyStyle.fallbackColors(n.illustration).0
                        Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    }
                } else {
                    let (bg, ink) = VFNotifyStyle.fallbackColors(n.illustration)
                    ZStack {
                        bg
                        Image(systemName: n.fallbackSymbol)
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(ink)
                    }
                }
            }
            .frame(width: s, height: s)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)

            Button(action: model.onClose) {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.white.opacity(0.55))
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(VFPressStyle())
            .padding(8)
            .help("Schließen")
        }
        .frame(width: s, height: s)
    }
}

private struct VFPressStyle: ButtonStyle {
    var hoverFill = false
    func makeBody(configuration: Configuration) -> some View {
        VFPressBody(configuration: configuration, hoverFill: hoverFill)
    }
    struct VFPressBody: View {
        let configuration: ButtonStyleConfiguration
        let hoverFill: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(Capsule().fill(Color.white.opacity(hoverFill && hover ? 0.10 : 0)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hover = $0 }
        }
    }
}
