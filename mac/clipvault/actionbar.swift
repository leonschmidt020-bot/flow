// ClipVault — Aktions-Leiste rechts in jeder Zeile (Bereiche · Teilen · Löschen · Pin) (01.10.2026, Fassung 2)
//
// Beim Hovern sieht man nur EINEN kleinen Griff (•••) am rechten Rand (plus Pin-Status, falls
// angeheftet). Ein kurzer Klick darauf wackelt nur und zeigt „Gedrückt halten". Erst ~0,4 s
// gedrueckt halten (Ring fuellt sich) laesst die Icons nacheinander links aus dem Griff
// herausgleiten. Auswahl: weiter gedrueckt halten, auf ein Icon ziehen, loslassen — oder danach
// normal anklicken. Einfahren nach einer Aktion, nach 4 s ohne Bedienung, mit Esc, Klick auf den
// Griff oder wenn die Maus die Zeile verlaesst. Logik: actionbar_state.swift (ohne AppKit pruefbar).
//
// Bewusst EINE View, die alles selbst zeichnet (keine NSButtons darin): klickbar ist nur, was man
// sieht — zu: nur der Griff, offen: die Pille (hitTest). Der Rest der Zeile bleibt Zeile (= Kopieren).
import Cocoa
import QuartzCore

struct ActionBarItem {
    var image: NSImage?
    var tint: NSColor                 // Farbe des Symbols
    var restTint: NSColor? = nil      // Farbe ohne Hover (z. B. Pin gedimmt); nil = tint
    var fill: NSColor? = nil          // Hinterlegung (z. B. „liegt in diesem Bereich", „geteilt")
    var tip: String
    var showAtRest = false            // ohne Hover sichtbar (Pin wie bisher, Laden …) — nur Anzeige
    var badge = false                 // beim Hovern als kleiner Status neben dem Griff (angeheftet, Laden …) — nur Anzeige
    var action: () -> Void
}

final class ActionBar: NSView, NSViewToolTipOwner {
    // Masse (Punkte)
    static let slot: CGFloat = 26, pillH: CGFloat = 34, step: CGFloat = 32, pad: CGFloat = 6
    static let handleR: CGFloat = 11, overshootRoom: CGFloat = 14
    static func armedWidth(_ n: Int) -> CGFloat { pad * 2 + slot + CGFloat(max(0, n - 1)) * step }
    static func frameWidth(_ n: Int) -> CGFloat { armedWidth(n + 1) + overshootRoom }   // n Icons + Griff

    /// die gerade aktive (haltende/offene) Leiste — fuer Esc
    static weak var active: ActionBar?

    let items: [ActionBarItem]
    private(set) var machine = ActionBarMachine()
    private var tinted: [NSImage?] = [], restTinted: [NSImage?] = []
    private let dots = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Aktionen")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
    private let xmark = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Schließen")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold))

    // Anzeige-Zustand
    private var rowHovered = false
    private var overHandle = false
    private var hoverTarget: ActionBarTarget = .none
    private var hoverAmt: [CGFloat] = []          // 0…1 je Icon (weich nachgefuehrt: Vergroessern beim Drueberziehen)
    private var downPoint: NSPoint = .zero
    // Icons: Fortschritt je Icon (0 = im Griff, 1 = draussen), gestaffelt
    private var iconFrom: [CGFloat] = [], iconTo: CGFloat = 0, iconT0: CFTimeInterval = 0, opening = false
    private var posFrom: CGFloat = 0
    private var presFrom: CGFloat = 0, presTo: CGFloat = 0, presT0: CFTimeInterval = 0
    private var nudgeT0: CFTimeInterval = -100
    private static let presDur = 0.14, stagger = 0.032, collapseStagger = 0.014
    private static let nudgeDur = 0.38, hintDur = 1.7
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var tipTexts: [NSView.ToolTipTag: String] = [:]

    init(frame: NSRect, items: [ActionBarItem]) {
        self.items = items
        super.init(frame: frame)
        tinted = items.map { ActionBar.tint($0.image, $0.tint) }
        restTinted = items.map { ActionBar.tint($0.image, $0.restTint ?? $0.tint) }
        hoverAmt = Array(repeating: 0, count: items.count)
        iconFrom = Array(repeating: 0, count: items.count)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Aktionen – gedrückt halten zum Öffnen")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private static func tint(_ img: NSImage?, _ c: NSColor) -> NSImage? {
        guard let img = img else { return nil }
        guard img.isTemplate else { return img }   // echte Logos (Bereich „KI") bleiben farbig
        return NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r); c.set(); r.fill(using: .sourceAtop); return true
        }
    }

    // MARK: Geometrie
    private func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
    private var handleC: NSPoint { NSPoint(x: bounds.maxX - ActionBar.pad - ActionBar.slot / 2, y: bounds.midY) }
    /// Icon i sitzt k = n - i Plaetze links vom Griff (das letzte Icon direkt daneben)
    private func k(_ i: Int) -> Int { items.count - i }
    private func finalCenter(_ i: Int) -> NSPoint { NSPoint(x: handleC.x - CGFloat(k(i)) * ActionBar.step, y: bounds.midY) }
    private func center(_ i: Int, _ p: CGFloat) -> NSPoint { NSPoint(x: handleC.x - CGFloat(k(i)) * ActionBar.step * p, y: bounds.midY) }
    private func disc(_ c: NSPoint, _ r: CGFloat = ActionBar.slot / 2) -> NSRect { NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
    private var fullPill: NSRect {
        let w = ActionBar.armedWidth(items.count + 1)
        return NSRect(x: bounds.maxX - w, y: (bounds.height - ActionBar.pillH) / 2, width: w, height: ActionBar.pillH)
    }
    /// klickbar = was man sieht: zu nur der Griff, offen die ganze Pille
    private func activeRect() -> NSRect {
        guard rowHovered || machine.isActive else { return .null }
        return machine.isArmed ? fullPill : disc(handleC, ActionBar.slot / 2 + 2)
    }
    private func target(at p: NSPoint) -> ActionBarTarget {
        if hypot(handleC.x - p.x, handleC.y - p.y) <= ActionBar.slot / 2 + 2 { return .handle }
        if machine.isArmed, let i = items.indices.first(where: { abs(finalCenter($0).x - p.x) <= ActionBar.step / 2 && abs(p.y - bounds.midY) <= ActionBar.pillH / 2 + 4 }) {
            return .icon(i)
        }
        return .none
    }

    // MARK: Animationswerte
    private var now: CFTimeInterval { CACurrentMediaTime() }
    private func iconProgress(_ i: Int, _ t: CFTimeInterval) -> CGFloat {
        guard i < iconFrom.count else { return 0 }
        let kk = Double(k(i))
        let delay = opening ? (kk - 1) * ActionBar.stagger : (Double(items.count) - kk) * ActionBar.collapseStagger
        let local = t - iconT0 - delay
        let s = CGFloat(opening ? cvSpring(local, period: 0.34, damping: 0.62) : cvSpring(local, period: 0.22, damping: 1))
        return iconFrom[i] + (iconTo - iconFrom[i]) * s
    }
    /// Position: alle Icons auf EINER Feder (so ueberholen sie sich nie); die Staffel steckt im Wachsen
    private func posProgress(_ t: CFTimeInterval) -> CGFloat {
        let s = CGFloat(opening ? cvSpring(t - iconT0, period: 0.40, damping: 0.70) : cvSpring(t - iconT0, period: 0.26, damping: 1))
        return posFrom + (iconTo - posFrom) * s
    }
    private func presenceValue(_ t: CFTimeInterval) -> CGFloat {
        let q = clamp01(CGFloat((t - presT0) / ActionBar.presDur)); let e = 1 - (1 - q) * (1 - q)
        return presFrom + (presTo - presFrom) * e
    }
    private var animating: Bool {
        let t = now
        let iconsMoving = t - iconT0 < 1.0 + Double(items.count) * ActionBar.stagger && (iconFrom.contains { $0 != iconTo } || posFrom != iconTo)
        return iconsMoving || t - presT0 < ActionBar.presDur || t - nudgeT0 < ActionBar.hintDur || hoverAmt.contains { $0 > 0.001 && $0 < 0.999 }
    }
    private func moveIcons(open: Bool) {
        let t = now
        iconFrom = items.indices.map { iconProgress($0, t) }; posFrom = posProgress(t)
        iconTo = open ? 1 : 0; opening = open; iconT0 = t
        ensureTimer()
    }
    private func ensureTimer() {
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common); timer = tm
    }
    private func tick() {
        handle(machine.tick(now))
        for i in hoverAmt.indices {   // Vergroessern beim Drueberziehen weich nachfuehren
            let goal: CGFloat = (machine.isArmed && hoverTarget == .icon(i)) ? 1 : 0
            hoverAmt[i] += (goal - hoverAmt[i]) * 0.32
            if abs(goal - hoverAmt[i]) < 0.002 { hoverAmt[i] = goal }
        }
        needsDisplay = true
        if !machine.isActive && !animating { timer?.invalidate(); timer = nil }
    }

    // MARK: Zustandswechsel
    private func handle(_ e: ActionBarEffect) {
        switch e {
        case .none: return
        case .armed:
            ActionBar.active = self
            moveIcons(open: true)
            hoverTarget = target(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        case .collapsed:
            if ActionBar.active === self { ActionBar.active = nil }
            moveIcons(open: false); hoverTarget = .none
        case .nudge:
            if ActionBar.active === self { ActionBar.active = nil }
            nudgeT0 = now; ensureTimer()
        case .perform(let i):
            if ActionBar.active === self { ActionBar.active = nil }
            moveIcons(open: false); hoverTarget = .none
            updateToolTips(); needsDisplay = true
            if i < items.count { items[i].action() }   // darf die Zeile neu bauen (reload) — daher zuletzt
            return
        }
        updateToolTips(); needsDisplay = true
    }
    /// Maus betritt / verlaesst die Zeile (vom Panel gerufen)
    func setRowHovered(_ h: Bool) {
        guard h != rowHovered else { return }
        rowHovered = h
        let t = now
        presFrom = presenceValue(t); presTo = h ? 1 : 0; presT0 = t
        let e = machine.hover(h)
        if !h { overHandle = false; if !machine.isActive { hoverTarget = .none } }
        if e != .none { handle(e) } else { updateToolTips() }
        ensureTimer(); needsDisplay = true
    }
    /// Esc im Panel: true = eine Leiste war offen und ist jetzt zu
    @discardableResult static func collapseActive() -> Bool {
        guard let b = active else { return false }
        guard b.machine.escape() else { active = nil; return false }
        b.handle(.collapsed); return true
    }

    // MARK: Maus
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sv = superview else { return nil }
        return activeRect().contains(convert(point, from: sv)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        // Zeile nicht gehovert (z. B. beim Bearbeiten): Klick gehoert der Liste
        guard rowHovered || machine.isActive else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil); downPoint = p
        handle(machine.press(at: now, target: target(at: p)))
        if machine.phase == .holding { ActionBar.active = self; ensureTimer() }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard machine.isActive else { super.mouseDragged(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let wasHolding = machine.phase == .holding
        handle(machine.dragged(distance: Double(hypot(p.x - downPoint.x, p.y - downPoint.y)), at: now))
        if wasHolding && machine.phase != .holding, ActionBar.active === self { ActionBar.active = nil }
        let tg = machine.isArmed ? target(at: p) : .none
        if tg != hoverTarget { hoverTarget = tg; ensureTimer() }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard machine.isActive else { super.mouseUp(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        handle(machine.release(at: now, target: target(at: p)))
        if machine.phase == .rest { setRowHoveredAfterLeave() }
        needsDisplay = true
    }
    /// beim Ziehen aus der Zeile heraus losgelassen: Anzeige wie „Maus weg"
    private func setRowHoveredAfterLeave() {
        guard rowHovered else { return }
        rowHovered = false; let t = now
        presFrom = presenceValue(t); presTo = 0; presT0 = t; overHandle = false
        updateToolTips(); ensureTimer()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let oh = rowHovered && target(at: p) == .handle
        let tg = machine.isArmed ? target(at: p) : .none
        if oh != overHandle || tg != hoverTarget { overHandle = oh; hoverTarget = tg; ensureTimer(); needsDisplay = true }
        machine.interaction(now)
    }
    override func mouseExited(with event: NSEvent) {
        if overHandle || hoverTarget != .none { overHandle = false; hoverTarget = .none; ensureTimer(); needsDisplay = true }
    }
    /// Rechtsklick auf die Leiste = Rechtsklick auf die Zeile (Kontextmenue der Liste)
    override func menu(for event: NSEvent) -> NSMenu? {
        var v: NSView? = superview
        while let x = v, !(x is NSTableView) { v = x.superview }
        return (v as? NSTableView)?.menu(for: event)
    }

    // MARK: Tooltips
    private func updateToolTips() {
        removeAllToolTips(); tipTexts = [:]
        guard rowHovered else { return }
        if machine.isArmed {
            for i in items.indices { tipTexts[addToolTip(disc(finalCenter(i)), owner: self, userData: nil)] = items[i].tip }
            tipTexts[addToolTip(disc(handleC), owner: self, userData: nil)] = "Schließen (Esc)"
        } else {
            tipTexts[addToolTip(disc(handleC), owner: self, userData: nil)] = "Gedrückt halten für Aktionen"
        }
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tipTexts[tag] ?? ""
    }

    // MARK: Zeichnen
    private static let pillFill = NSColor(white: 0.16, alpha: 0.98)
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = now
        let pres = presenceValue(t)
        let prog = items.indices.map { iconProgress($0, t) }   // Wachsen, gestaffelt (das Icon am Griff zuerst)
        let pos = posProgress(t)                                // Position, gemeinsam
        let near = max(prog.last ?? 0, pos)
        let open = clamp01(near * 1.6)                    // 0 = zu, 1 = Leiste steht
        let hold = CGFloat(machine.holdProgress(t))

        // Ohne Hover: nur der Pin-Status (bzw. Laden …) wie bisher, rechtsbuendig
        if pres < 1 {
            ctx.saveGState(); ctx.setAlpha(1 - pres)
            let rest = items.indices.filter { items[$0].showAtRest }
            for (j, i) in rest.reversed().enumerated() {
                drawIcon(restTinted[i], at: NSPoint(x: handleC.x - CGFloat(j) * ActionBar.step, y: handleC.y), alpha: 1)
            }
            ctx.restoreGState()
        }
        guard pres > 0 || machine.isActive else { return }
        ctx.saveGState(); ctx.setAlpha(max(pres, machine.isActive ? 1 : 0))

        // Pille waechst mit dem aeussersten Icon nach links
        if open > 0.001 {
            // linker Rand = das am weitesten links stehende Icon (die Staffel laesst die nahen zuerst heraus)
            let leftmost = items.indices.map { center($0, pos).x - ActionBar.slot / 2 * (0.35 + 0.65 * clamp01(prog[$0])) }.min() ?? handleC.x
            let minX = min(handleC.x - ActionBar.slot / 2, leftmost) - ActionBar.pad
            let pr = NSRect(x: minX, y: (bounds.height - ActionBar.pillH) / 2, width: bounds.maxX - minX, height: ActionBar.pillH)
            let pill = NSBezierPath(roundedRect: pr, xRadius: pr.height / 2, yRadius: pr.height / 2)
            ctx.saveGState(); ctx.setAlpha(open)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 12, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ActionBar.pillFill.setFill(); pill.fill()
            ctx.restoreGState()
            ctx.saveGState(); pill.addClip()   // dezenter Glanz oben
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0)])?
                .draw(in: NSRect(x: pr.minX, y: pr.midY, width: pr.width, height: pr.height / 2), angle: -90)
            ctx.restoreGState()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            let bp = NSBezierPath(roundedRect: pr.insetBy(dx: 0.5, dy: 0.5), xRadius: pr.height / 2 - 0.5, yRadius: pr.height / 2 - 0.5)
            bp.lineWidth = 1; bp.stroke()
            ctx.restoreGState()
        }

        // Status neben dem Griff (angeheftet, Laden …), solange die Icons drin sind
        let badges = items.indices.filter { items[$0].badge }
        if open < 1 {
            for (j, i) in badges.reversed().enumerated() {
                drawIcon(restTinted[i], at: NSPoint(x: handleC.x - 26 - CGFloat(j) * 22, y: handleC.y), alpha: 0.9 * (1 - open), scale: 0.8)
            }
        }

        // Icons: gleiten aus dem Griff nach links, wachsen von klein auf volle Groesse
        for i in items.indices {
            let p = prog[i]; guard p > 0.001 else { continue }
            let c = center(i, pos)
            let grow = 0.35 + 0.65 * clamp01(p)
            let hv = hoverAmt.indices.contains(i) ? hoverAmt[i] : 0
            let sc = grow * (1 + 0.16 * hv)
            let al = clamp01(p * 1.8)
            if let f = items[i].fill { f.withAlphaComponent(f.alphaComponent * al).setFill(); NSBezierPath(ovalIn: disc(c, ActionBar.slot / 2 * grow)).fill() }
            if hv > 0.01 {
                NSColor.white.withAlphaComponent(0.15 * hv).setFill(); NSBezierPath(ovalIn: disc(c, ActionBar.slot / 2 * sc)).fill()
            }
            drawIcon(tinted[i], at: c, alpha: al, scale: sc)
        }

        // Griff: kleine Scheibe mit •••, offen wird daraus ein ×; kurzer Klick = Wackeln
        let nd = t - nudgeT0
        let wobble = nd < ActionBar.nudgeDur ? CGFloat(3 * sin(nd * 2 * .pi * 7) * (1 - nd / ActionBar.nudgeDur)) : 0
        let hc = NSPoint(x: handleC.x + wobble, y: handleC.y)
        let lit = max(overHandle ? 1 : 0, hold, open)
        NSColor.white.withAlphaComponent(0.07 + 0.07 * lit).setFill()
        NSBezierPath(ovalIn: disc(hc, ActionBar.handleR)).fill()
        // das gehaltene Icon „fuellt sich"
        if machine.phase == .holding {
            let fr = ActionBar.handleR * (1 - (1 - hold) * (1 - hold))
            NSColor.white.withAlphaComponent(0.14).setFill(); NSBezierPath(ovalIn: disc(hc, fr)).fill()
        }
        let ring = NSBezierPath(ovalIn: disc(hc, ActionBar.handleR)); ring.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12 + 0.08 * lit).setStroke(); ring.stroke()
        let glyphA: CGFloat = 0.62 + 0.33 * lit
        drawIcon(ActionBar.tint(dots, .white), at: hc, alpha: glyphA * (1 - open))
        if open > 0 { drawIcon(ActionBar.tint(xmark, .white), at: hc, alpha: 0.85 * open) }
        // Halte-Ring: fuellt sich in 0,4 s
        if machine.phase == .holding {
            let r = ActionBar.handleR + 2.5
            let track = NSBezierPath(ovalIn: disc(hc, r)); track.lineWidth = 2
            NSColor.white.withAlphaComponent(0.14).setStroke(); track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: hc, radius: r, startAngle: 90, endAngle: 90 - 360 * max(0.001, hold), clockwise: true)
            arc.lineWidth = 2; arc.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.92).setStroke(); arc.stroke()
        }
        // Hinweis nach kurzem Klick: „Gedrückt halten" links neben dem Griff
        if nd < ActionBar.hintDur && open < 0.01 {
            let fade = CGFloat(min(1, nd / 0.12, (ActionBar.hintDur - nd) / 0.35))
            let s = NSAttributedString(string: "Gedrückt halten", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85 * fade)])
            let sz = s.size()
            let lr = NSRect(x: handleC.x - ActionBar.handleR - 8 - sz.width - 16, y: handleC.y - 10, width: sz.width + 16, height: 20)
            NSColor(white: 0.12, alpha: 0.96 * fade).setFill()
            NSBezierPath(roundedRect: lr, xRadius: 10, yRadius: 10).fill()
            NSColor.white.withAlphaComponent(0.12 * fade).setStroke()
            NSBezierPath(roundedRect: lr.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5).stroke()
            s.draw(at: NSPoint(x: lr.minX + 8, y: lr.midY - sz.height / 2))
        }
        ctx.restoreGState()
    }
    private func drawIcon(_ img: NSImage?, at c: NSPoint, alpha: CGFloat, scale: CGFloat = 1) {
        guard let img = img, alpha > 0.001 else { return }
        let sz = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let r = NSRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    // MARK: Render-Szenen (clipvault panel-render <png> leiste-…), nichts wird ausgeloest
    func debugScene(_ name: String) {
        timer?.invalidate(); timer = nil
        let t = now, past = t - 5
        machine = ActionBarMachine()
        rowHovered = name != "ruhe"
        _ = machine.hover(rowHovered)
        presFrom = rowHovered ? 1 : 0; presTo = presFrom; presT0 = past
        iconFrom = Array(repeating: 0, count: items.count); posFrom = 0; iconTo = 0; iconT0 = past; opening = false
        let trash = max(0, items.count - 2)          // Papierkorb (vorletzter: … Teilen, Papierkorb, Pin)
        switch name {
        case "halten":                               // 60 % gehalten
            _ = machine.press(at: t - ActionBarMachine.holdDuration * 0.6, target: .handle); overHandle = true
        case "hinweis":                              // kurz nach einem kurzen Klick
            nudgeT0 = t - 0.5; overHandle = true
        case "aufgehen", "offen", "ziehen", "zu":
            _ = machine.press(at: past, target: .handle); _ = machine.tick(past + ActionBarMachine.holdDuration)
            if name != "ziehen" { _ = machine.release(at: past + 0.5, target: .handle) }
            opening = true; iconTo = 1; iconT0 = name == "aufgehen" ? t - 0.11 : past
            if name == "ziehen" { hoverTarget = .icon(trash); hoverAmt[trash] = 1 }
            if name == "zu" { _ = machine.escape(); iconFrom = Array(repeating: 1, count: items.count); posFrom = 1; iconTo = 0; opening = false }
        default: break                               // kompakt / ruhe
        }
        updateToolTips(); needsDisplay = true
    }
}
