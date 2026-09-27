import AppKit

/// Dünner blauer Rahmen um das Fenster, in das der Text beim Loslassen kommt (nur, wenn es NICHT das aktive Fenster ist),
/// oben mittig ein kleines Schild „Text kommt hierher“. Lässt alle Klicks durch und wird von der Fenstersuche übersprungen.
final class MTHighlight {
    /// Fensternummern der Markierung – `MouseTarget.windowList` lässt sie aus (sonst gälte das Ziel als „verdeckt“)
    nonisolated(unsafe) static var windowNumbers: Set<Int> = []

    private var panel: NSPanel?
    private var shownFor: CGWindowID?

    /// Main-Thread
    func show(_ c: MTCapture) {
        guard Settings.shared.mouseTargetHighlight, case .target(let t) = c, !t.alreadyFocused, t.bounds.width > 40, t.bounds.height > 40 else { hide(); return }
        let h = MTGeometry.primaryHeight(NSScreen.screens.map(\.frame))
        let r = MTGeometry.cocoaRectToCG(t.bounds, primaryHeight: h)   // gleiche Formel in beide Richtungen
        let p = panel ?? make()
        panel = p
        (p.contentView as? MTHighlightView)?.label = "Text kommt hierher"
        p.setFrame(r.insetBy(dx: -2, dy: -2), display: true)
        if shownFor != t.windowID || !p.isVisible {
            shownFor = t.windowID
            p.alphaValue = 0
            p.orderFrontRegardless()
            MTHighlight.windowNumbers.insert(p.windowNumber)
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; p.animator().alphaValue = 1 }
        }
    }

    /// Main-Thread
    func hide() {
        shownFor = nil
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; p.animator().alphaValue = 0 },
                                             completionHandler: { if self.shownFor == nil { p.orderOut(nil) } })
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.contentView = MTHighlightView()
        return p
    }
}

final class MTHighlightView: NSView {
    var label = "Text kommt hierher" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor(calibratedRed: 0.33, green: 0.56, blue: 1.0, alpha: 1)
        let frame = bounds.insetBy(dx: 2, dy: 2)
        // weiches Leuchten + scharfer Rahmen
        let glow = NSBezierPath(roundedRect: frame, xRadius: 11, yRadius: 11)
        glow.lineWidth = 5
        blue.withAlphaComponent(0.18).setStroke(); glow.stroke()
        let line = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        line.lineWidth = 2
        blue.withAlphaComponent(0.9).setStroke(); line.stroke()
        // Schild oben mittig
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: label, attributes: attrs)
        let ts = text.size()
        let chip = NSRect(x: bounds.midX - ts.width / 2 - 12, y: bounds.maxY - ts.height - 16, width: ts.width + 24, height: ts.height + 8)
        let cp = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
        blue.withAlphaComponent(0.95).setFill(); cp.fill()
        text.draw(at: NSPoint(x: chip.minX + 12, y: chip.minY + 4))
    }
}
