import AppKit

// MARK: - Pille: Datei darauf ziehen + Wasser-Fortschritt
//
// Eigenes, durchsichtiges Fenster exakt über der Pille (die Pille selbst bleibt unverändert):
//  • Zieht jemand eine Audio-/Videodatei (Finder-URL ODER Datei-Versprechen aus Sprachmemos/Mail/WhatsApp) in die Nähe
//    → zarter Lichtkranz; Ablagefläche = ganze Pille + 40 pt rundherum → Kapsel „↓ Transkribieren“, die immer zur
//    Bildschirmmitte hin wächst und nie über den Rand ragt (auch hochkant am rechten/linken Rand).
//  • Läuft eine Datei, füllt sich der ruhende Strich mit blauem „Wasser“ (`AudioWater`): hochkant und in der großen
//    Hover-Pille von unten nach oben, im flachen 9-pt-Strich von links nach rechts; nur die Oberfläche wogt leicht.
//    Der Pegel ist geglättet (`AudioProgressSmoother`: springt nie, läuft nie rückwärts). Fertig → läuft voll, blendet aus.
//    Beim Drüberfahren steht darüber „Name · 42 %“.
// Mausklicks gehen immer durch (Fenster ignoriert die Maus, außer während eine Datei gezogen wird).

final class AudioImportPillOverlay {
    static let shared = AudioImportPillOverlay()

    private weak var pill: PillController?
    private var panel: NSPanel?
    private var view: AudioImportPillView?
    private var timer: Timer?
    private var dragChange = NSPasteboard(name: .drag).changeCount
    private var dragging = false
    /// Laufende Datei, deren Wasser gerade gezeigt wird (+ letzter angezeigter Pegel)
    private var shownID: String?
    private var shownLevel = 0.0
    /// Fertig-Ausklang: Wasser läuft voll (0,45 s), steht kurz, blendet aus
    private var finish: (start: Date, from: Double)?
    static let finishFill = 0.45, finishHold = 0.30, finishFade = 0.55

    static let size = NSSize(width: 420, height: 220)
    /// So weit um die Pille herum zählt ein Ablegen
    static let dropMargin: CGFloat = 72

    func attach(_ pill: PillController) {
        guard self.pill == nil else { return }
        self.pill = pill
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        let v = AudioImportPillView(frame: NSRect(origin: .zero, size: Self.size))
        v.autoresizingMask = [.width, .height]
        p.contentView = v
        panel = p
        view = v
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() { tick() }

    /// Vom Manager: Datei `id` ist beendet. Erfolgreich → Wasser läuft sichtbar voll und blendet aus; sonst sofort weg.
    func finishedRunning(_ id: String, success: Bool) {
        guard id == shownID else { return }
        if success { finish = (Date(), shownLevel) }
        shownID = nil
    }

    /// Pegel + Deckkraft des Fertig-Ausklangs zum Zeitpunkt `e` (Sekunden seit Ende); nil = vorbei
    static func finishState(from: Double, elapsed e: Double) -> (level: Double, alpha: CGFloat)? {
        if e < finishFill {
            let x = e / finishFill
            let ease = x * x * (3 - 2 * x)   // weich an- und auslaufend (kein Tempo-Sprung beim Übergang)
            return (from + (1 - from) * ease, 1)
        }
        if e < finishFill + finishHold { return (1, 1) }
        let x = (e - finishFill - finishHold) / finishFade
        if x >= 1 { return nil }
        return (1, CGFloat(1 - x * x * (3 - 2 * x)))
    }

    private func tick() {
        guard let pill, let panel, let view else { return }
        let capsule = pill.view.capsuleRectInScreen
        guard capsule.width > 0 else { return }
        // Läuft gerade ein Datei-Zug (URL oder Versprechen)?
        let pressed = NSEvent.pressedMouseButtons & 1 == 1
        let pb = NSPasteboard(name: .drag)
        if pressed && pb.changeCount != dragChange {
            dragChange = pb.changeCount
            dragging = AudioDropReader.canAccept(pb)
        }
        if !pressed && !view.targeted { dragging = false }
        let mouse = NSEvent.mouseLocation
        let near = dragging && hypot(mouse.x - capsule.midX, mouse.y - capsule.midY) < 340
        let idle: Bool = { if case .idle = pill.view.mode { return true }; return false }()
        // Pegel: geglätteter Fortschritt der laufenden Datei, oder der Fertig-Ausklang
        let imports = AudioImport.shared
        var level: Double?
        var waterAlpha: CGFloat = 1
        if let fin = finish {
            if let st = Self.finishState(from: fin.from, elapsed: Date().timeIntervalSince(fin.start)) {
                level = st.level; waterAlpha = st.alpha
            } else { finish = nil }
        }
        if level == nil, let id = imports.runningID, let l = imports.live[id] {
            let v = AudioProgressSmoother.shared.value(id, live: l)
            shownID = id; shownLevel = v
            level = v
        }
        let fraction = level
        let showProgress = fraction != nil && idle && !pill.view.suppressed
        let wanted = near || showProgress || view.targeted
        if wanted {
            let c = NSPoint(x: capsule.midX, y: capsule.midY)
            let scr = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main
            if let scr {
                let o = PillController.panelOrigin(anchor: c, size: Self.size, screen: scr.frame)
                if panel.frame.origin != o { panel.setFrameOrigin(o) }
                // sichtbarer Bildschirmbereich in View-Koordinaten (Label bleibt darin)
                view.screenBounds = scr.visibleFrame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            }
            view.capsule = NSRect(x: capsule.minX - panel.frame.minX, y: capsule.minY - panel.frame.minY,
                                  width: capsule.width, height: capsule.height)
            view.vertical = pill.view.vertical && !pill.view.hover && capsule.height > capsule.width
            view.dragNear = near
            view.progress = showProgress ? fraction : nil
            view.waterAlpha = waterAlpha
            view.hovered = pill.view.hover
            view.hoverLabel = showProgress && pill.view.hover && finish == nil ? hoverText(fraction ?? 0) : nil
            view.needsDisplay = true
            panel.ignoresMouseEvents = !(near || view.targeted)
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
    }

    private func hoverText(_ f: Double) -> String {
        let name = AudioImport.shared.runningID.flatMap { MeetingStore.shared.meeting($0)?.title } ?? "Datei"
        let short = name.count > 26 ? String(name.prefix(24)) + "…" : name
        return "\(short) · \(Int(f * 100)) %"
    }

    // MARK: Sichtprüfung (offscreen)

    enum RenderState {
        case dragNear, dragOver
        case dragOverRightEdge      // hochkant am rechten Rand → Kapsel wächst nach links
        case progress(Double, phase: Double)
        case progressHover(Double, phase: Double)
        case progressVertical(Double, phase: Double)
    }

    /// Rendert Pille + Überlagerung auf hellem und dunklem Grund nebeneinander (Bildschirmrand = Bildkante).
    static func renderPNG(_ state: RenderState, to url: URL, size: NSSize = NSSize(width: 380, height: 150), scale: CGFloat = 1) -> Bool {
        _ = NSApplication.shared
        let img = NSImage(size: NSSize(width: size.width * 2 * scale, height: size.height * scale))
        img.lockFocus()
        drawRender(state, size: size, scale: scale, showLabel: true)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Zeichnet einen Zustand (hell + dunkel nebeneinander) in den aktuellen Kontext – `size` je Hälfte, `scale` = Lupe.
    /// `alpha`: Deckkraft des Wassers (Fertig-Ausklang).
    static func drawRender(_ state: RenderState, size: NSSize, scale: CGFloat, showLabel: Bool, alpha: CGFloat = 1,
                           origin: NSPoint = .zero) {
        for (i, bg) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.12, alpha: 1)].enumerated() {
            let off = CGFloat(i) * size.width
            bg.setFill(); NSRect(x: origin.x + off * scale, y: origin.y, width: size.width * scale, height: size.height * scale).fill()
            let v = AudioImportPillView(frame: NSRect(origin: .zero, size: size))
            v.screenBounds = NSRect(origin: .zero, size: size)
            var cap: NSRect
            switch state {
            case .progressVertical: cap = NSRect(x: size.width / 2 - 4.5, y: size.height / 2 - 22, width: 9, height: 44); v.vertical = true
            case .dragOverRightEdge: cap = NSRect(x: size.width - 14 - 9, y: size.height / 2 - 22, width: 9, height: 44); v.vertical = true
            case .progressHover: cap = NSRect(x: size.width / 2 - 48, y: min(36, size.height / 2 - 13), width: 96, height: 26)
            default: cap = NSRect(x: size.width / 2 - 22, y: min(36, size.height / 2 - 4.5), width: 44, height: 9)
            }
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform(); t.translateX(by: origin.x, yBy: origin.y); t.scale(by: scale); t.translateX(by: off, yBy: 0); t.concat()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).addClip()   // Bildkante = Bildschirmrand
            let pillPath = NSBezierPath(roundedRect: cap, xRadius: min(cap.width, cap.height) / 2, yRadius: min(cap.width, cap.height) / 2)
            // wie Pill.swift: Füllung, Rand 1 pt um 0,5 pt eingerückt
            if case .progressHover = state { NSColor.black.withAlphaComponent(0.82).setFill() } else { NSColor(white: 0.16, alpha: 0.92).setFill() }
            pillPath.fill()
            let rr = min(cap.width, cap.height) / 2 - 0.5
            let border = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: rr, yRadius: rr)
            NSColor.white.withAlphaComponent(min(cap.width, cap.height) > 12 ? 0.32 : 0.42).setStroke(); border.lineWidth = 1; border.stroke()
            if case .progressHover = state {
                // Hover-Pille: darunter Weltkugel + Sprache (wie die echte Pille; das Wasser liegt darüber)
                if let g = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
                    let tinted = NSImage(size: g.size, flipped: false) { rect in
                        g.draw(in: rect); NSColor.white.withAlphaComponent(0.92).set(); rect.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: cap.minX + 10, y: cap.midY - g.size.height / 2, width: g.size.width, height: g.size.height))
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                            .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
                let ts = ("DE+EN" as NSString).size(withAttributes: attrs)
                ("DE+EN" as NSString).draw(at: NSPoint(x: cap.minX + 28, y: cap.midY - ts.height / 2), withAttributes: attrs)
                v.hovered = true
            }
            v.capsule = cap
            switch state {
            case .dragNear: v.dragNear = true
            case .dragOver, .dragOverRightEdge: v.dragNear = true; v.targeted = true
            case .progress(let f, let ph), .progressVertical(let f, let ph): v.progress = f; v.phaseOverride = ph
            case .progressHover(let f, let ph):
                v.progress = f; v.phaseOverride = ph
                if showLabel { v.hoverLabel = "Weekly Team-Call · \(Int(f * 100)) %" }
            }
            v.waterAlpha = alpha
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

final class AudioImportPillView: NSView {
    /// Kapsel der Pille in View-Koordinaten
    var capsule = NSRect.zero
    /// Sichtbarer Bildschirmbereich in View-Koordinaten (Label darf nicht darüber hinaus)
    var screenBounds = NSRect.zero
    var vertical = false
    var dragNear = false
    private var targetedFlag = false
    var targeted: Bool { get { targetedFlag } set { targetedFlag = newValue; needsDisplay = true } }
    var progress: Double?
    /// Deckkraft des Wassers (Fertig-Ausklang blendet aus)
    var waterAlpha: CGFloat = 1
    /// Maus über der Pille (Pille ist dann groß und zeigt Weltkugel + Sprache → Wasser etwas durchsichtiger)
    var hovered = false
    var hoverLabel: String?
    /// Nur Render: feste Wellen-Phase
    var phaseOverride: Double?
    private let t0 = Date()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(AudioDropReader.draggedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// Ablagefläche: ganze Pille + 72 pt rundherum (mindestens 220×170 – großer lila Bereich)
    var dropZone: NSRect {
        var z = capsule.insetBy(dx: -AudioImportPillOverlay.dropMargin, dy: -AudioImportPillOverlay.dropMargin)
        if z.width < 220 { z = z.insetBy(dx: -(220 - z.width) / 2, dy: 0) }
        if z.height < 170 { z = z.insetBy(dx: 0, dy: -(170 - z.height) / 2) }
        return z
    }

    /// Rechteck für die gewachsene „Transkribieren“-Kapsel: um die Pille zentriert, dann zur Bildschirmmitte hin
    /// verschoben, bis sie ganz auf dem Bildschirm (und im Fenster) liegt.
    func grownRect(width w: CGFloat, height h: CGFloat) -> NSRect {
        let c = NSPoint(x: capsule.midX, y: capsule.midY)
        var r = NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        var limit = bounds.insetBy(dx: 8, dy: 8)
        if screenBounds.width > 0 { limit = limit.intersection(screenBounds.insetBy(dx: 8, dy: 8)) }
        if r.maxX > limit.maxX { r.origin.x = limit.maxX - w }
        if r.minX < limit.minX { r.origin.x = limit.minX }
        if r.maxY > limit.maxY { r.origin.y = limit.maxY - h }
        if r.minY < limit.minY { r.origin.y = limit.minY }
        return r
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: capsule.midX, y: capsule.midY)
        let t = phaseOverride ?? Date().timeIntervalSince(t0)
        if targeted {
            let label = "Transkribieren"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white]
            let ts = (label as NSString).size(withAttributes: attrs)
            let h: CGFloat = 32, w = ceil(ts.width) + 14 + 6 + 36
            var r = grownRect(width: w, height: h)
            if vertical {
                // Hochkant am Rand: Kapsel NEBEN die Pille, zur Bildschirmmitte hin (nie über den Rand, Pille bleibt sichtbar)
                let mid = screenBounds.width > 0 ? screenBounds.midX : bounds.midX
                r.origin.x = capsule.midX > mid ? capsule.minX - 10 - w : capsule.maxX + 10
                let lim = grownRect(width: w, height: h)
                r.origin.y = lim.minY
                // Pille selbst leuchtet mit
                let halo = capsule.insetBy(dx: -4, dy: -4)
                let hp = NSBezierPath(roundedRect: halo, xRadius: halo.width / 2, yRadius: halo.width / 2)
                NSColor(calibratedRed: 0.72, green: 0.58, blue: 0.95, alpha: 0.9).setStroke(); hp.lineWidth = 1.5; hp.stroke()
            }
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.80, alpha: 0.55); sh.shadowBlurRadius = 16
            sh.set()
            NSColor.black.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: h / 2 - 0.75, yRadius: h / 2 - 0.75)
            b.lineWidth = 1.5
            NSColor(calibratedRed: 0.72, green: 0.58, blue: 0.95, alpha: 0.95).setStroke(); b.stroke()
            var x = r.midX - (14 + 6 + ts.width) / 2
            if let img = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
                let tinted = img.copy() as! NSImage
                tinted.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                tinted.draw(in: NSRect(x: x, y: r.midY - 7, width: 14, height: 14))
            }
            x += 20
            (label as NSString).draw(at: NSPoint(x: x, y: r.midY - ts.height / 2), withAttributes: attrs)
            return
        }
        if dragNear {
            // zarter Lichtkranz um die Ablagefläche: „hier kannst du ablegen“
            let halo = capsule.insetBy(dx: -30, dy: -30)   // großer lila Bereich: hier ablegen
            let rr = min(halo.width, halo.height) / 2
            let p = NSBezierPath(roundedRect: halo, xRadius: rr, yRadius: rr)
            NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.80, alpha: 0.16).setFill(); p.fill()
            p.lineWidth = 1.2
            p.setLineDash([4, 3], count: 2, phase: 0)
            NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.80, alpha: 0.75).setStroke(); p.stroke()
        }
        if let f = progress, !dragNear {
            // Wasser in der Kapsel: 1,5 pt Abstand zum Rand (Rand der Pille bleibt sichtbar, nichts ragt darüber)
            let axis: AudioWaterAxis = vertical ? .up : AudioWater.axis(for: capsule.size)
            let inset: CGFloat = min(capsule.width, capsule.height) >= 20 ? 2 : 1.5
            // Hover-Pille: „Aufhellen“ (screen) – dunkler Grund wird blau, Weltkugel + Sprache bleiben rein weiß lesbar
            AudioWater.draw(in: capsule, inset: inset, fraction: f, axis: axis, t: t, alpha: waterAlpha,
                            blend: hovered ? .screen : .normal)
            if let label = hoverLabel {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                                                            .foregroundColor: NSColor.white]
                let ts = (label as NSString).size(withAttributes: attrs)
                let bw = ts.width + 36, bh: CGFloat = 24
                var br = NSRect(x: c.x - bw / 2, y: capsule.maxY + 8, width: bw, height: bh)
                let lim = grownRect(width: bw, height: bh)
                br.origin.x = lim.minX
                NSColor.black.withAlphaComponent(0.86).setFill()
                NSBezierPath(roundedRect: br, xRadius: 12, yRadius: 12).fill()
                NSColor.white.withAlphaComponent(0.25).setStroke()
                let bb = NSBezierPath(roundedRect: br.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5); bb.lineWidth = 1; bb.stroke()
                if let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                    let tinted = img.copy() as! NSImage
                    tinted.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                    tinted.draw(in: NSRect(x: br.minX + 11, y: br.midY - 5.5, width: 12, height: 11))
                }
                (label as NSString).draw(at: NSPoint(x: br.minX + 27, y: br.midY - ts.height / 2), withAttributes: attrs)
            }
        }
    }

    // MARK: Ablegen (Datei-URLs + Versprechen)

    private func inZone(_ info: NSDraggingInfo) -> Bool { dropZone.contains(convert(info.draggingLocation, from: nil)) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = inZone(sender) && AudioDropReader.canAccept(sender.draggingPasteboard)
        if ok != targeted { targeted = ok }
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { inZone(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        guard inZone(sender) else { return false }
        return AudioImport.shared.acceptDrop(sender.draggingPasteboard, openNotetaker: false)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { targeted = false }
}
