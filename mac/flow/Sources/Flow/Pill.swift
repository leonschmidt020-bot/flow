import AppKit

/// Die schwebende Pille im Flow-Stil.
/// Ruhe: kleiner dunkler Strich. Sprechen: schwarze Kapsel mit weißen Pegel-Balken.
final class PillView: NSView {
    enum Mode: Equatable {
        case idle, listening, handsFree, transcribing
        case meeting(start: Date)
        case prompt(String)
        /// Rückfrage mit „Speichern“ (z. B. gelerntes Wort)
        case question(String, String)   // Text, Knopf-Beschriftung
        /// fn + ⌃: Sprachbefehl für markierten Text / Befehl wird ausgeführt
        case command, commandWorking
        /// Agent-Prompt wird gebaut (Karte daneben zeigt den Fortschritt)
        case agentPrompt
        case loading(Double)
    }

    var mode: Mode = .idle { didSet { if mode != oldValue { modeChangedAt = Date(); wake() } } }
    var level: Float = 0
    /// Zweiter Pegel (Systemton) für den Meeting-Modus.
    var level2: Float = 0
    /// Meeting-Fenster wird mitgeschnitten → kleines Kamera-Symbol in der Meeting-Pille
    var cameraOn = false { didSet { if cameraOn != oldValue { wake() } } }
    var suppressed = false { didSet { wake() } }
    /// An der linken/rechten Bildschirmseite steht die Pille hochkant.
    var vertical = false { didSet { if vertical != oldValue { wake() } } }
    var alwaysVisible = true { didSet { wake() } }

    /// Mittelpunkt der Pille in Bildschirmkoordinaten + sichtbarer Bereich des Bildschirms.
    var anchor = NSPoint.zero { didSet { wake() } }
    var screenRect = NSRect.zero

    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onPromptAccept: (() -> Void)?
    var onPromptDismiss: (() -> Void)?
    var onQuestionAccept: (() -> Void)?
    /// Klick auf die Weltkugel (Pille in Ruhe, Maus darüber)
    var onLanguageClick: (() -> Void)?
    /// Kürzel der aktiven Sprache für die Weltkugel („DE+EN“)
    var languageShort = "DE+EN" { didSet { wake() } }
    /// Stimmfilter aus („Alle Stimmen“) → beim Drüberfahren kleines Zwei-Personen-Symbol
    var allVoices: Bool { get { !Settings.shared.onlyMyVoice } set { wake() } }
    var onQuestionDismiss: (() -> Void)?
    var onMeetingClick: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var menuProvider: (() -> NSMenu)?

    private(set) var hover = false
    private var toastText: String?
    private var toastUntil = Date.distantPast
    private var toastStart = Date.distantPast
    private var modeChangedAt = Date()

    // animierte Werte
    private var w: CGFloat = 40, h: CGFloat = 8, fillA: CGFloat = 0.55, alpha: CGFloat = 1
    private var bars = [CGFloat](repeating: 3, count: 11)
    private var smoothLevel: CGFloat = 0
    private var smoothLevel2: CGFloat = 0
    private var timer: Timer?
    private var t0 = Date()

    // Klickflächen (View-Koordinaten)
    private var cancelRect = NSRect.zero, stopRect = NSRect.zero, acceptRect = NSRect.zero, dismissRect = NSRect.zero

    // Ziehen
    private var dragStart: NSPoint?
    private var dragAnchorStart = NSPoint.zero
    private var dragging = false

    override var isFlipped: Bool { false }

    /// Hochkant zeichnen? Text-Zustände (Frage, Laden) bleiben immer waagerecht lesbar.
    private var rotated: Bool {
        guard vertical else { return false }
        switch mode {
        case .prompt, .loading, .question: return false
        case .idle: return !hover   // Weltkugel immer aufrecht
        default: return true
        }
    }
    /// Tatsächliche Breite/Höhe auf dem Bildschirm.
    private var effSize: NSSize { rotated ? NSSize(width: h, height: w) : NSSize(width: w, height: h) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func showToast(_ s: String, seconds: Double = 1.8) {
        toastText = s
        toastStart = Date()
        toastUntil = Date().addingTimeInterval(seconds)
        wake()
    }

    func setHover(_ v: Bool) { if v != hover { hover = v; wake() } }

    private func wake() {
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    // MARK: Zielgrößen

    private var targetSize: NSSize {
        switch mode {
        case .idle: return hover ? NSSize(width: textWidth(languageShort, size: 11, weight: .semibold) + 44, height: 24) : NSSize(width: 44, height: 9)
        case .listening, .transcribing: return NSSize(width: 66, height: 24)
        case .command, .commandWorking, .agentPrompt: return NSSize(width: 84, height: 24)
        case .handsFree: return NSSize(width: 112, height: 26)
        case .meeting: return NSSize(width: cameraOn ? 84 : 66, height: 24)
        case .prompt(let s): return NSSize(width: min(440, textWidth(s, size: 12, weight: .medium) + 162), height: 34)
        case .question(let s, let b): return NSSize(width: min(540, textWidth(s, size: 12, weight: .medium) + textWidth(b, size: 11.5, weight: .semibold) + 94), height: 34)
        case .loading: return NSSize(width: 176, height: 28)
        }
    }

    private var targetAlpha: CGFloat {
        if suppressed { return 0 }
        if case .idle = mode, !alwaysVisible, !hover, !dragging { return 0 }
        return 1
    }

    private var targetFill: CGFloat {
        if case .idle = mode { return hover ? 0.82 : 0.55 }
        return 0.92
    }

    func tick() {
        let ts = targetSize
        let k: CGFloat = 0.24
        w += (ts.width - w) * k
        h += (ts.height - h) * k
        fillA += (targetFill - fillA) * 0.2
        alpha += (targetAlpha - alpha) * 0.2
        smoothLevel += (CGFloat(level) - smoothLevel) * (CGFloat(level) > smoothLevel ? 0.5 : 0.15)
        smoothLevel2 += (CGFloat(level2) - smoothLevel2) * (CGFloat(level2) > smoothLevel2 ? 0.5 : 0.15)
        needsDisplay = true
        let settled = abs(ts.width - w) < 0.3 && abs(ts.height - h) < 0.3 && abs(targetAlpha - alpha) < 0.01
        let animatedMode: Bool
        switch mode {
        case .listening, .handsFree, .transcribing, .meeting, .command, .commandWorking, .agentPrompt: animatedMode = true
        default: animatedMode = false   // Ruhe, Fragen, Laden: stehen still → kein Dauer-Neuzeichnen
        }
        if settled && !animatedMode && Date() > toastUntil && !hover {
            timer?.invalidate(); timer = nil
        }
    }

    /// Mittelpunkt der Kapsel in View-Koordinaten, am Bildschirmrand eingeklemmt.
    private func capsuleCenter() -> NSPoint {
        guard let win = window else { return NSPoint(x: bounds.midX, y: bounds.midY) }
        var c = anchor
        if screenRect.width > 0 {
            let mx = effSize.width / 2 + 6, my = effSize.height / 2 + 6
            c.x = min(max(c.x, screenRect.minX + mx), screenRect.maxX - mx)
            c.y = min(max(c.y, screenRect.minY + my), screenRect.maxY - my)
        }
        return NSPoint(x: c.x - win.frame.minX, y: c.y - win.frame.minY)
    }

    var capsuleRectInScreen: NSRect {
        guard let win = window else { return .zero }
        let c = capsuleCenter()
        let e = effSize
        return NSRect(x: c.x - e.width / 2 + win.frame.minX, y: c.y - e.height / 2 + win.frame.minY, width: e.width, height: e.height)
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        guard alpha > 0.005 else { return }
        let c = capsuleCenter()
        let r = NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let t = CGFloat(Date().timeIntervalSince(t0))
        let isRotated = rotated

        // Hochkant: alles um -90° um die Mitte drehen (links → oben, rechts → unten).
        NSGraphicsContext.current?.saveGraphicsState()
        if isRotated {
            let tf = NSAffineTransform()
            tf.translateX(by: c.x, yBy: c.y); tf.rotate(byDegrees: -90); tf.translateX(by: -c.x, yBy: -c.y)
            tf.concat()
        }

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35 * alpha)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = isRotated ? NSSize(width: -2, height: 0) : NSSize(width: 0, height: -2)
        shadow.set()
        let path = NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2)
        // Ruhe-Strich leicht grau statt schwarz, damit er auch auf schwarzem Hintergrund sichtbar ist
        let isIdleStrip: Bool = { if case .idle = mode, !hover { return true }; return false }()
        (isIdleStrip ? NSColor(white: 0.16, alpha: 0.92 * alpha) : NSColor.black.withAlphaComponent(fillA * alpha)).setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2 - 0.5, yRadius: h / 2 - 0.5)
        border.lineWidth = 1
        NSColor.white.withAlphaComponent((h > 12 ? 0.32 : 0.42) * alpha).setStroke()
        border.stroke()

        let white = NSColor.white.withAlphaComponent(alpha)
        cancelRect = .zero; stopRect = .zero; acceptRect = .zero; dismissRect = .zero

        switch mode {
        case .idle:
            if hover && h > 16 {
                // 🌐 + aktive Sprache
                let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                if let g = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                    let tinted = NSImage(size: g.size, flipped: false) { rect in
                        g.draw(in: rect); NSColor.white.withAlphaComponent(0.92).set(); rect.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: r.minX + 10, y: c.y - g.size.height / 2, width: g.size.width, height: g.size.height),
                                from: .zero, operation: .sourceOver, fraction: alpha)
                }
                drawText(languageShort, at: NSPoint(x: r.minX + 28, y: c.y), size: 11, weight: .semibold, mono: false,
                         color: white.withAlphaComponent(0.92 * alpha), alignLeft: true)
                if allVoices, let p2 = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Alle Stimmen")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)) {
                    let tinted = NSImage(size: p2.size, flipped: false) { rect in
                        p2.draw(in: rect); NSColor.white.withAlphaComponent(0.85).set(); rect.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: r.maxX - 10 - p2.size.width, y: c.y - p2.size.height / 2, width: p2.size.width, height: p2.size.height),
                                from: .zero, operation: .sourceOver, fraction: alpha)
                }
            }
        case .listening:
            drawBars(center: c, count: 9, maxH: h - 9, t: t, level: smoothLevel, color: white, barW: 2.2, gap: 2.3)
        case .handsFree:
            let cx = NSPoint(x: r.minX + 14, y: c.y)
            cancelRect = NSRect(x: cx.x - 11, y: cx.y - 11, width: 22, height: 22)
            NSColor.white.withAlphaComponent(0.16 * alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx.x - 8.5, y: cx.y - 8.5, width: 17, height: 17)).fill()
            let x = NSBezierPath()
            x.move(to: NSPoint(x: cx.x - 3, y: cx.y - 3)); x.line(to: NSPoint(x: cx.x + 3, y: cx.y + 3))
            x.move(to: NSPoint(x: cx.x - 3, y: cx.y + 3)); x.line(to: NSPoint(x: cx.x + 3, y: cx.y - 3))
            x.lineWidth = 1.6; x.lineCapStyle = .round
            white.withAlphaComponent(0.9 * alpha).setStroke(); x.stroke()
            let sx = NSPoint(x: r.maxX - 14, y: c.y)
            stopRect = NSRect(x: sx.x - 11, y: sx.y - 11, width: 22, height: 22)
            NSColor.systemRed.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: sx.x - 8.5, y: sx.y - 8.5, width: 17, height: 17)).fill()
            white.setFill()
            NSBezierPath(roundedRect: NSRect(x: sx.x - 3, y: sx.y - 3, width: 6, height: 6), xRadius: 1.3, yRadius: 1.3).fill()
            drawBars(center: c, count: 9, maxH: h - 10, t: t, level: smoothLevel, color: white, barW: 2.2, gap: 2.3)
        case .transcribing:
            drawDots(center: c, count: 5, spacing: 6, radius: 1.6, color: white, wave: 1, t: t)
        case .command, .commandWorking:
            // lila Rand = Befehlsmodus
            let pulse: CGFloat = mode == .commandWorking ? 0.5 + 0.4 * (0.5 + 0.5 * sin(t * 4)) : 0.9
            let pb = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2 - 0.5, yRadius: h / 2 - 0.5)
            pb.lineWidth = 1.2
            NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.95, alpha: pulse * alpha).setStroke(); pb.stroke()
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            if let wand = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let tinted = NSImage(size: wand.size, flipped: false) { rect in
                    wand.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: r.minX + 10, y: c.y - wand.size.height / 2, width: wand.size.width, height: wand.size.height),
                            from: .zero, operation: .sourceOver, fraction: alpha)
            }
            let bc = NSPoint(x: c.x + 8, y: c.y)
            if mode == .command {
                drawBars(center: bc, count: 7, maxH: h - 9, t: t, level: smoothLevel, color: white, barW: 2.2, gap: 2.3)
            } else {
                drawDots(center: bc, count: 5, spacing: 6, radius: 1.6, color: white, wave: 1, t: t)
            }
        case .agentPrompt:
            // Agent-Prompt: lila Rand atmet, Funkeln + drei Zeilen, die sich nacheinander füllen (Text entsteht)
            let pulse: CGFloat = 0.45 + 0.45 * (0.5 + 0.5 * sin(t * 3.2))
            let pb = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2 - 0.5, yRadius: h / 2 - 0.5)
            pb.lineWidth = 1.2
            NSColor(calibratedRed: 0.74, green: 0.63, blue: 1.0, alpha: pulse * alpha).setStroke(); pb.stroke()
            let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            if let sp = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let tinted = NSImage(size: sp.size, flipped: false) { rect in
                    sp.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: r.minX + 10, y: c.y - sp.size.height / 2, width: sp.size.width, height: sp.size.height),
                            from: .zero, operation: .sourceOver, fraction: alpha)
            }
            let lx = r.minX + 32, lw = r.maxX - 12 - lx
            for i in 0..<3 {
                let y = c.y + 4.5 - CGFloat(i) * 4.5
                let ph = (t * 0.8 + CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1.4) / 1.4
                let full = [1.0, 0.8, 0.55][i] as CGFloat
                NSColor.white.withAlphaComponent(0.18 * alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: lx, y: y - 1, width: lw * full, height: 2), xRadius: 1, yRadius: 1).fill()
                white.withAlphaComponent(0.9 * alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: lx, y: y - 1, width: lw * full * min(1, ph * 1.3), height: 2), xRadius: 1, yRadius: 1).fill()
            }
        case .meeting:
            // Wie beim Diktat: nur die Wellen, keine Uhr. Pegel = lauteste Spur (du oder die anderen).
            let bc = cameraOn ? NSPoint(x: c.x - 8, y: c.y) : c
            drawBars(center: bc, count: 9, maxH: h - 9, t: t, level: max(smoothLevel, smoothLevel2), color: white, barW: 2.2, gap: 2.3)
            if cameraOn, w > 76 {
                let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                if let g = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Bildschirm wird mitgeschnitten")?.withSymbolConfiguration(cfg) {
                    let tinted = NSImage(size: g.size, flipped: false) { rect in
                        g.draw(in: rect); NSColor.white.withAlphaComponent(0.85).set(); rect.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: r.maxX - 11 - g.size.width, y: c.y - g.size.height / 2, width: g.size.width, height: g.size.height),
                                from: .zero, operation: .sourceOver, fraction: alpha)
                }
            }
        case .prompt(let s):
            drawText(s, at: NSPoint(x: r.minX + 14, y: c.y), size: 12, weight: .medium, mono: false, color: white, alignLeft: true)
            let bw: CGFloat = 100, bh: CGFloat = 22
            acceptRect = NSRect(x: r.maxX - 34 - bw, y: c.y - bh / 2, width: bw, height: bh)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: acceptRect, xRadius: bh / 2, yRadius: bh / 2).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: acceptRect.minX + 11, y: c.y - 3.5, width: 7, height: 7)).fill()
            drawText("Aufnehmen", at: NSPoint(x: acceptRect.midX + 7, y: c.y), size: 11.5, weight: .semibold, mono: false,
                     color: NSColor.black.withAlphaComponent(alpha), alignLeft: false)
            let dx = NSPoint(x: r.maxX - 17, y: c.y)
            dismissRect = NSRect(x: dx.x - 11, y: dx.y - 11, width: 22, height: 22)
            let x = NSBezierPath()
            x.move(to: NSPoint(x: dx.x - 3.5, y: dx.y - 3.5)); x.line(to: NSPoint(x: dx.x + 3.5, y: dx.y + 3.5))
            x.move(to: NSPoint(x: dx.x - 3.5, y: dx.y + 3.5)); x.line(to: NSPoint(x: dx.x + 3.5, y: dx.y - 3.5))
            x.lineWidth = 1.6; x.lineCapStyle = .round
            white.withAlphaComponent(0.8 * alpha).setStroke(); x.stroke()
        case .question(let s, let button):
            drawText(s, at: NSPoint(x: r.minX + 14, y: c.y), size: 12, weight: .medium, mono: false, color: white, alignLeft: true)
            let bw: CGFloat = textWidth(button, size: 11.5, weight: .semibold) + 28, bh: CGFloat = 22
            acceptRect = NSRect(x: r.maxX - 34 - bw, y: c.y - bh / 2, width: bw, height: bh)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: acceptRect, xRadius: bh / 2, yRadius: bh / 2).fill()
            drawText(button, at: NSPoint(x: acceptRect.midX, y: c.y), size: 11.5, weight: .semibold, mono: false,
                     color: NSColor.black.withAlphaComponent(alpha), alignLeft: false)
            let dx = NSPoint(x: r.maxX - 17, y: c.y)
            dismissRect = NSRect(x: dx.x - 11, y: dx.y - 11, width: 22, height: 22)
            let x = NSBezierPath()
            x.move(to: NSPoint(x: dx.x - 3.5, y: dx.y - 3.5)); x.line(to: NSPoint(x: dx.x + 3.5, y: dx.y + 3.5))
            x.move(to: NSPoint(x: dx.x - 3.5, y: dx.y + 3.5)); x.line(to: NSPoint(x: dx.x + 3.5, y: dx.y - 3.5))
            x.lineWidth = 1.6; x.lineCapStyle = .round
            white.withAlphaComponent(0.8 * alpha).setStroke(); x.stroke()
        case .loading(let p):
            let label = p > 0.001 && p < 0.999 ? "Sprachmodell lädt · \(Int(p * 100)) %" : "Sprachmodell startet …"
            drawText(label, at: NSPoint(x: c.x, y: c.y + 2), size: 11, weight: .medium, mono: false, color: white, alignLeft: false)
            let track = NSRect(x: r.minX + 16, y: r.minY + 5, width: r.width - 32, height: 2)
            NSColor.white.withAlphaComponent(0.2 * alpha).setFill(); NSBezierPath(rect: track).fill()
            white.setFill(); NSBezierPath(rect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(max(0.03, p)), height: 2)).fill()
        }

        NSGraphicsContext.current?.restoreGraphicsState()

        if let tt = toastText, Date() < toastUntil {
            let remaining = toastUntil.timeIntervalSinceNow
            let a = CGFloat(min(1, remaining / 0.3)) * min(1, CGFloat(Date().timeIntervalSince(toastStart)) / 0.15 + 0.2)
            let tw = textWidth(tt, size: 11.5, weight: .medium) + 22
            let e = effSize
            let tr: NSRect
            if isRotated {
                // Seitlich: Hinweis zur Bildschirmmitte hin neben die Pille.
                let toLeft = anchor.x > screenRect.midX
                let tx = toLeft ? c.x - e.width / 2 - 10 - tw : c.x + e.width / 2 + 10
                tr = NSRect(x: tx, y: c.y - 12, width: tw, height: 24)
            } else {
                let above = anchor.y < screenRect.midY || screenRect.height == 0
                let ty = above ? c.y + e.height / 2 + 8 + 12 : c.y - e.height / 2 - 8 - 12
                tr = NSRect(x: c.x - tw / 2, y: ty - 12, width: tw, height: 24)
            }
            NSColor.black.withAlphaComponent(0.86 * a).setFill()
            NSBezierPath(roundedRect: tr, xRadius: 12, yRadius: 12).fill()
            NSColor.white.withAlphaComponent(0.25 * a).setStroke()
            let b = NSBezierPath(roundedRect: tr.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5); b.lineWidth = 1; b.stroke()
            drawText(tt, at: NSPoint(x: tr.midX, y: tr.midY), size: 11.5, weight: .medium, mono: false,
                     color: NSColor.white.withAlphaComponent(a), alignLeft: false)
        }
    }

    private func drawBars(center c: NSPoint, count: Int, maxH: CGFloat, t: CGFloat, level: CGFloat, color: NSColor,
                          barW: CGFloat = 2.4, gap: CGFloat = 2.6) {
        if bars.count != count { bars = [CGFloat](repeating: barW, count: count) }
        let total = CGFloat(count) * barW + CGFloat(count - 1) * gap
        var x = c.x - total / 2
        let lv = min(1, max(0, (level - 0.04) / 0.8))
        for i in 0..<count {
            let mid = CGFloat(count - 1) / 2
            let env = 1 - pow(abs(CGFloat(i) - mid) / (mid + 1), 1.6) * 0.75
            let wobble = 0.55 + 0.45 * abs(sin(t * 7.3 + CGFloat(i) * 1.7) * cos(t * 3.1 + CGFloat(i) * 0.9))
            let target = barW + (maxH - barW) * lv * env * wobble
            bars[i] += (target - bars[i]) * 0.35
            let bh = max(barW, bars[i])
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: c.y - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
    }

    private func drawDots(center c: NSPoint, count: Int, spacing: CGFloat, radius: CGFloat, color: NSColor, wave: CGFloat, t: CGFloat) {
        let total = CGFloat(count - 1) * spacing
        for i in 0..<count {
            let x = c.x - total / 2 + CGFloat(i) * spacing
            let ph = t * 6.5 - CGFloat(i) * 0.75
            let dy = wave * sin(ph) * 3
            let a = wave > 0 ? 0.45 + 0.55 * (0.5 + 0.5 * sin(ph)) : 1
            color.withAlphaComponent(color.alphaComponent * a).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - radius, y: c.y + dy - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight, mono: Bool) -> NSFont {
        mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font(size, weight, mono: false)]).width
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, mono: Bool, color: NSColor, alignLeft: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight, mono: mono), .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        let x = alignLeft ? p.x : p.x - sz.width / 2
        (s as NSString).draw(at: NSPoint(x: x, y: p.y - sz.height / 2), withAttributes: attrs)
    }

    // MARK: Maus

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragAnchorStart = anchor
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let m = NSEvent.mouseLocation
        if !dragging && hypot(m.x - s.x, m.y - s.y) > 4 { dragging = true }
        if dragging {
            anchor = NSPoint(x: dragAnchorStart.x + (m.x - s.x), y: dragAnchorStart.y + (m.y - s.y))
            if let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) {
                screenRect = scr.visibleFrame
                let fx = (anchor.x - screenRect.minX) / max(screenRect.width, 1)
                vertical = fx < 0.08 || fx > 0.92
            }
            if let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) {
                window?.setFrameOrigin(PillController.panelOrigin(anchor: anchor, size: bounds.size, screen: scr.frame))
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragging = false }
        if dragging { onDragEnd?(anchor); return }
        var p = convert(event.locationInWindow, from: nil)
        if rotated {
            // Klickpunkt in das gedrehte Zeichen-Koordinatensystem zurückrechnen.
            let c = capsuleCenter()
            p = NSPoint(x: c.x - (p.y - c.y), y: c.y + (p.x - c.x))
        }
        switch mode {
        case .handsFree:
            if cancelRect.contains(p) { onCancel?() } else if stopRect.contains(p) { onStop?() }
        case .prompt:
            if acceptRect.contains(p) { onPromptAccept?() } else if dismissRect.contains(p) { onPromptDismiss?() }
        case .question:
            if acceptRect.contains(p) { onQuestionAccept?() } else if dismissRect.contains(p) { onQuestionDismiss?() }
        case .meeting:
            onMeetingClick?()
        case .idle:
            if hover { onLanguageClick?() } else { onClick?() }
        case .listening:
            onStop?()
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = menuProvider?() else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
}

/// Besitzt das Fenster, folgt dem Bildschirm unter der Maus und lässt Klicks außerhalb der Kapsel durch.
final class PillController {
    let view: PillView
    private let panel: NSPanel
    private var timer: Timer?
    private(set) var currentScreen: NSScreen?
    /// Solange true, bleibt die Pille auf ihrem Bildschirm (z. B. während einer Aufnahme).
    var pinnedToScreen = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        view = PillView(frame: panel.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.onDragEnd = { [weak self] p in self?.finishDrag(at: p) }
        panel.orderFrontRegardless()
        applyVisibility()
        reposition(force: true)
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.reposition(force: true) }
    }

    func applyVisibility() {
        view.alwaysVisible = Settings.shared.pillVisibility == .always
    }

    private func screenUnderMouse() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
    }

    /// Bildschirm, auf dem das Fenster liegt, in das gerade geschrieben wird (per Bedienungshilfen).
    private func screenOfFocusedWindow() -> NSScreen? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let win = w as! AXUIElement
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        // AX-Koordinaten: Ursprung oben links am Hauptbildschirm → in Cocoa (unten links) umrechnen
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let center = NSPoint(x: pos.x + size.width / 2, y: primaryH - (pos.y + size.height / 2))
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
    }

    private var lastFocusCheck = Date.distantPast
    private var cachedFocusScreen: NSScreen?

    /// Wohin die Pille gehört – je nach Einstellung aktives Fenster oder Maus.
    private func targetScreen(fresh: Bool = false) -> NSScreen? {
        if Settings.shared.pillFollow == .focusedWindow {
            if fresh || Date().timeIntervalSince(lastFocusCheck) > 0.3 {
                lastFocusCheck = Date()
                cachedFocusScreen = screenOfFocusedWindow()
            }
            if let s = cachedFocusScreen { return s }
        }
        return screenUnderMouse()
    }

    /// Pille auf den Bildschirm unter der Maus setzen (an dessen gespeicherte Position).
    func reposition(force: Bool = false) {
        guard let s = targetScreen(fresh: force) else { return }
        if !force && s == currentScreen { return }
        currentScreen = s
        let vis = s.visibleFrame
        let pl = Settings.shared.placement(for: s)
        let a = pl.center(in: vis)
        view.vertical = pl.isSide
        view.screenRect = vis
        view.anchor = a
        panel.setFrameOrigin(PillController.panelOrigin(anchor: a, size: panel.frame.size, screen: s.frame))
        panel.orderFrontRegardless()
    }

    private func poll() {
        let m = NSEvent.mouseLocation
        let hit = view.capsuleRectInScreen.insetBy(dx: -6, dy: -6).contains(m)
        let dragging = NSEvent.pressedMouseButtons & 1 == 1 && !panel.ignoresMouseEvents
        if panel.ignoresMouseEvents == hit || dragging { panel.ignoresMouseEvents = !(hit || dragging) }
        view.setHover(hit)
        // In Ruhe und während eines Meetings wandert die Pille mit auf den anderen Bildschirm.
        if !pinnedToScreen && !dragging {
            switch view.mode {
            case .idle, .meeting: reposition()
            default: break
            }
        }
    }

    private func finishDrag(at p: NSPoint) {
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? currentScreen else { return }
        let vis = s.visibleFrame
        var placement: PillPlacement
        let snap = PillPreset.allCases.first { preset in
            let c: NSPoint = preset.center(in: vis)
            return hypot(c.x - p.x, c.y - p.y) < 60
        }
        if let snap {
            placement = PillPlacement(preset: snap)
        } else {
            let fx: CGFloat = min(max((p.x - vis.minX) / vis.width, 0), 1)
            let fy: CGFloat = min(max((p.y - vis.minY) / vis.height, 0), 1)
            placement = PillPlacement(preset: nil, fx: Double(fx), fy: Double(fy))
        }
        Settings.shared.placements[Settings.key(for: s)] = placement
        currentScreen = nil
        reposition(force: true)
    }

    /// Fenster um den Anker zentrieren, aber komplett INNERHALB des Bildschirms halten.
    /// Ragt es über eine Bildschirmkante (MSI steht über dem MacBook), verschiebt macOS es sonst falsch.
    static func panelOrigin(anchor a: NSPoint, size: NSSize, screen f: NSRect) -> NSPoint {
        let x = min(max(a.x - size.width / 2, f.minX), f.maxX - size.width)
        let y = min(max(a.y - size.height / 2, f.minY), f.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    func setPlacement(_ preset: PillPreset, for screen: NSScreen) {
        Settings.shared.placements[Settings.key(for: screen)] = PillPlacement(preset: preset)
        reposition(force: true)
    }
}
