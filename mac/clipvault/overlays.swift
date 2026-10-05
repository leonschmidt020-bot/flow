// ClipVault — Overlays: Kopier-Toast, PhoneDrop-Animation, UCKiller
import Cocoa
import Carbon.HIToolbox
import QuartzCore
import QuickLookThumbnailing
import WebKit
import CryptoKit

// MARK: - Toast (Kopier-Bestätigung)
final class Toast {
    static let shared = Toast()
    let panel: NSPanel
    let effect = NSVisualEffectView()
    let label = NSTextField(labelWithString: "In Zwischenablage")
    var timer: Timer?
    let baseW: CGFloat = 234, H: CGFloat = 52
    var W: CGFloat = 234   // waechst mit langen Meldungen („3 Bilder kopiert – in Claude Code …")
    init() {
        panel = NSPanel(contentRect: NSRect(x:0,y:0,width:W,height:H), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .screenSaver; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.alphaValue = 0
        effect.frame = NSRect(x:0,y:0,width:W,height:H)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = roundMask(H/2)
        panel.contentView = effect
        let icon = NSImageView(frame: NSRect(x: 19, y: (H-26)/2, width: 26, height: 26))
        let cfg = NSImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = .systemGreen
        icon.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(icon)
        label.frame = NSRect(x: 55, y: (H-22)/2, width: W-66, height: 22)
        label.font = .systemFont(ofSize: 14, weight: .medium); label.textColor = .white
        label.isBezeled = false; label.drawsBackground = false; label.isEditable = false
        effect.addSubview(label)
    }
    func show(_ text: String = "In Zwischenablage") {
        label.stringValue = text
        timer?.invalidate()
        let tw = ceil(text.size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 14, weight: .medium)]).width)
        W = min(560, max(baseW, tw + 55 + 22))
        panel.setContentSize(NSSize(width: W, height: H))
        effect.frame = NSRect(x: 0, y: 0, width: W, height: H)
        label.frame = NSRect(x: 55, y: (H-22)/2, width: W-66, height: 22)
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main
        let f = screen?.frame ?? NSRect(x:0,y:0,width:1440,height:900)
        panel.setFrameOrigin(NSPoint(x: f.midX - W/2, y: f.minY + f.height*0.13))
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if let layer = effect.layer {
            let cx = W/2, cy = H/2
            func t(_ sc: CGFloat) -> NSValue {
                var mt = CATransform3DMakeTranslation(cx, cy, 0); mt = CATransform3DScale(mt, sc, sc, 1); mt = CATransform3DTranslate(mt, -cx, -cy, 0); return NSValue(caTransform3D: mt)
            }
            let a = CAKeyframeAnimation(keyPath: "transform")
            a.values = [t(0.82), t(1.04), t(1.0)]; a.keyTimes = [0, 0.62, 1.0]; a.duration = 0.36
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.6, 1.0)]
            layer.add(a, forKey: "pop")
        }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.16; c.timingFunction = CAMediaTimingFunction(name: .easeOut); panel.animator().alphaValue = 1 }
        timer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; self?.panel.animator().alphaValue = 0 }
        }
    }
}

// MARK: - PhoneDrop (Universal-Clipboard vom iPhone — NameDrop-Style Animation)
final class PhoneDrop {
    static let shared = PhoneDrop()
    let panel: NSPanel
    let root = NSView()
    let effect = NSVisualEffectView()   // Karte
    let scrim = NSView()
    let glassBorder = CAShapeLayer()    // dezente Glas-Kante (kein dicker Farbsaum)
    let topSheen = CAGradientLayer()    // weicher Lichtschein oben (Glas)
    let phone = NSImageView()
    let mac = NSImageView()
    let title = NSTextField(labelWithString: "Vom iPhone")
    let caption = NSTextField(labelWithString: "Datei in Zwischenablage")
    var dots: [CALayer] = []
    let track = NSView()
    let fill = CAGradientLayer()
    let fillHead = CALayer()             // heller Glow-Kopf am Balken-Ende
    var timer: Timer?

    let W: CGFloat = 640, H: CGFloat = 290
    let cardW: CGFloat = 560, cardH: CGFloat = 210, corner: CGFloat = 34
    var cardX: CGFloat { (W - cardW)/2 }
    var cardY: CGFloat { (H - cardH)/2 }
    let cdir = NSHomeDirectory() + "/.config/flow-clipvault/"
    func col(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> NSColor { NSColor(srgbRed:r/255,green:g/255,blue:b/255,alpha:a) }
    lazy var cBlue   = col(141,159,255)
    lazy var cViolet = col(170,110,238)
    lazy var cPink   = col(245,185,234)

    init() {
        panel = NSPanel(contentRect: NSRect(x:0,y:0,width:W,height:H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .screenSaver; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0; panel.animationBehavior = .none
        root.frame = NSRect(x:0,y:0,width:W,height:H); root.wantsLayer = true; root.layer?.masksToBounds = false
        panel.contentView = root

        // Lila Flow komplett entfernt (Lena-Wunsch) — nur die Karte bleibt

        // ---- Karte (Frosted Glass, Squircle) ----
        effect.frame = NSRect(x: cardX, y: cardY, width: cardW, height: cardH)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.maskImage = roundMask(corner)
        root.addSubview(effect)
        scrim.frame = effect.bounds; scrim.autoresizingMask = [.width,.height]; scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor(white:0.04, alpha:0.66).cgColor
        scrim.layer?.cornerRadius = corner; scrim.layer?.cornerCurve = .continuous; scrim.layer?.masksToBounds = true
        effect.addSubview(scrim)
        // weicher Top-Sheen (Glas-Reflexion oben)
        topSheen.frame = CGRect(x: 0, y: cardH-70, width: cardW, height: 70)
        topSheen.colors = [NSColor.white.withAlphaComponent(0.0).cgColor, NSColor.white.withAlphaComponent(0.10).cgColor]
        topSheen.startPoint = CGPoint(x:0.5,y:0); topSheen.endPoint = CGPoint(x:0.5,y:1)
        scrim.layer?.addSublayer(topSheen)
        // hauchdünne Glas-Kante
        glassBorder.path = CGPath(roundedRect: effect.bounds.insetBy(dx:0.5,dy:0.5), cornerWidth: corner, cornerHeight: corner, transform: nil)
        glassBorder.fillColor = NSColor.clear.cgColor
        glassBorder.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor; glassBorder.lineWidth = 1
        effect.layer?.addSublayer(glassBorder)

        // iPhone links, MacBook rechts
        phone.image = NSImage(contentsOfFile: cdir+"phone_mock.png"); phone.imageScaling = .scaleProportionallyUpOrDown
        phone.frame = NSRect(x: 58, y: 64, width: 48, height: 100)
        effect.addSubview(phone)
        mac.image = NSImage(contentsOfFile: cdir+"mac_mock.png"); mac.imageScaling = .scaleProportionallyUpOrDown
        mac.frame = NSRect(x: cardW-58-152, y: 60, width: 152, height: 112)
        effect.addSubview(mac)
        // Titel oben
        title.frame = NSRect(x: 0, y: cardH-44, width: cardW, height: 26); title.alignment = .center
        title.font = .systemFont(ofSize: 20, weight: .bold); title.textColor = .white
        title.isBezeled=false; title.drawsBackground=false; title.isEditable=false; title.isSelectable=false
        effect.addSubview(title)
        // Caption unten
        caption.frame = NSRect(x: 0, y: 18, width: cardW, height: 18); caption.alignment = .center
        caption.font = .systemFont(ofSize: 13, weight: .medium); caption.textColor = NSColor.white.withAlphaComponent(0.55)
        caption.isBezeled=false; caption.drawsBackground=false; caption.isEditable=false; caption.isSelectable=false
        effect.addSubview(caption)
        // Punkte (erster leuchtet, Rest dim)
        let dN=5, dd:CGFloat=8, gap:CGFloat=17
        let total = CGFloat(dN)*dd + CGFloat(dN-1)*gap
        let sx = cardW/2 - total/2
        for i in 0..<dN {
            let d = CALayer(); d.frame = CGRect(x: sx+CGFloat(i)*(dd+gap), y: 112, width: dd, height: dd)
            d.cornerRadius = dd/2; d.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            d.shadowColor = NSColor.white.cgColor; d.shadowRadius = 5; d.shadowOffset = .zero; d.shadowOpacity = 0
            effect.layer?.addSublayer(d); dots.append(d)
        }
        // leuchtender Fortschrittsbalken (blau→violett→pink) mit Glow + hellem Kopf
        track.frame = NSRect(x: 70, y: 44, width: cardW-140, height: 5); track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        track.layer?.cornerRadius = 2.5; track.layer?.masksToBounds = false
        effect.addSubview(track)
        fill.frame = CGRect(x:0,y:0,width: track.bounds.width, height: 5)
        fill.startPoint = CGPoint(x:0,y:0.5); fill.endPoint = CGPoint(x:1,y:0.5)
        fill.colors = [cBlue.cgColor, cViolet.cgColor, cPink.cgColor]
        fill.cornerRadius = 2.5; fill.anchorPoint = CGPoint(x:0,y:0.5); fill.position = CGPoint(x:0, y:2.5)
        fill.shadowColor = cViolet.cgColor; fill.shadowRadius = 7; fill.shadowOpacity = 1.0; fill.shadowOffset = .zero
        track.layer?.addSublayer(fill)
        fillHead.frame = CGRect(x:0,y:-1,width:7,height:7); fillHead.cornerRadius = 3.5
        fillHead.backgroundColor = NSColor.white.cgColor
        fillHead.shadowColor = cPink.cgColor; fillHead.shadowRadius = 6; fillHead.shadowOpacity = 1.0; fillHead.shadowOffset = .zero
        fillHead.anchorPoint = CGPoint(x:0.5,y:0.5); fillHead.position = CGPoint(x:0,y:2.5)
        track.layer?.addSublayer(fillHead)
    }

    func renderState(mid: CGFloat = 0.6) {
        let w = track.bounds.width * mid
        fill.frame = CGRect(x:0,y:0,width: w, height:5); fillHead.position = CGPoint(x: w, y:2.5)
        for (i,d) in dots.enumerated() {
            let lit = CGFloat(i) <= mid*CGFloat(dots.count)
            d.backgroundColor = (lit ? NSColor.white : NSColor.white.withAlphaComponent(0.16)).cgColor
            d.shadowOpacity = lit ? 0.9 : 0
        }
    }

    func show(_ kind: String = "Datei in Zwischenablage") {
        timer?.invalidate()
        title.stringValue = "Vom iPhone"; caption.stringValue = kind
        for d in dots { d.removeAllAnimations(); d.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor; d.shadowOpacity = 0 }
        fill.removeAllAnimations(); fill.frame = CGRect(x:0,y:0,width:0,height:5)
        fillHead.removeAllAnimations(); fillHead.position = CGPoint(x:0,y:2.5)

        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main
        let f = screen?.frame ?? NSRect(x:0,y:0,width:1440,height:900)
        panel.setFrameOrigin(NSPoint(x: f.midX - W/2, y: f.minY + f.height * 0.10))
        panel.alphaValue = 0; panel.orderFrontRegardless()
        // Karte sanft rein
        if let cl = effect.layer {
            let s = CABasicAnimation(keyPath:"transform.scale"); s.fromValue = 0.97; s.toValue = 1.0; s.duration = 0.45
            s.timingFunction = CAMediaTimingFunction(controlPoints:0.2,0.8,0.2,1); cl.add(s, forKey:"in")
        }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; panel.animator().alphaValue = 1 }

        let t0 = CACurrentMediaTime()
        // Punkte leuchten nacheinander (Welle)
        for (i,d) in dots.enumerated() {
            let bg = CABasicAnimation(keyPath:"backgroundColor")
            bg.fromValue = NSColor.white.withAlphaComponent(0.16).cgColor; bg.toValue = NSColor.white.cgColor
            let sh = CABasicAnimation(keyPath:"shadowOpacity"); sh.fromValue = 0; sh.toValue = 0.9
            let pop = CAKeyframeAnimation(keyPath:"transform.scale"); pop.values=[1.0,1.5,1.0]; pop.keyTimes=[0,0.5,1]
            let grp = CAAnimationGroup(); grp.animations=[bg,sh,pop]; grp.duration = 0.5
            grp.beginTime = t0 + 0.5 + Double(i)*0.22; grp.fillMode = .both; grp.isRemovedOnCompletion = false
            d.add(grp, forKey:"lite"); d.backgroundColor = NSColor.white.cgColor; d.shadowOpacity = 0.9
        }
        // Balken füllt sich + Kopf wandert
        let grow = CABasicAnimation(keyPath:"bounds.size.width"); grow.fromValue = 0; grow.toValue = track.bounds.width
        grow.duration = 1.7; grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        grow.beginTime = t0 + 0.5; grow.fillMode = .both; grow.isRemovedOnCompletion = false
        fill.add(grow, forKey:"grow"); fill.frame = CGRect(x:0,y:0,width: track.bounds.width, height:5)
        let head = CABasicAnimation(keyPath:"position.x"); head.fromValue = 0; head.toValue = track.bounds.width
        head.duration = 1.7; head.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
        head.beginTime = t0 + 0.5; head.fillMode = .both; head.isRemovedOnCompletion = false
        fillHead.add(head, forKey:"head"); fillHead.position = CGPoint(x: track.bounds.width, y:2.5)

        timer = Timer.scheduledTimer(withTimeInterval: 4.4, repeats: false) { [weak self] _ in
            guard let s = self else { return }
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.6; c.timingFunction = CAMediaTimingFunction(name:.easeIn)
                s.panel.animator().alphaValue = 0
            }, completionHandler: { s.fill.removeAllAnimations() })
        }
    }
}

// MARK: - UCKiller — Apples iPhone-Ladefenster (UASharedPasteboardProgressUI) sofort entfernen
// CGWindowList SIEHT das Fenster (bewiesen): owner=UASharedPasteboardProgressUI + PID.
// Wir killen den Prozess direkt per PID (kein Shell-pkill -> keine 16-Zeichen-comm-Kuerzung).
// Nur die Anzeige stirbt; useractivityd uebertraegt weiter -> Einfuegen funktioniert normal.
final class UCKiller {
    static let shared = UCKiller()
    private let q = DispatchQueue(label: "app.flowdictation.clipvault.uckiller", qos: .userInteractive)
    private var src: DispatchSourceTimer?
    private var known = Set<Int32>()
    private var tickCount = 0
    private let target = "UASharedPasteboardProgressUI"

    // Audit 27.09.2026: der Takt lief 33×/s mit neuem 32-KB-Array + zwei Sets (~800 PIDs) pro Takt
    // und war mit ~1,2 % Dauer-CPU der groesste Leerlauf-Verbraucher von ClipVault. Jetzt: ein fester
    // Puffer, Nachschlagen im bekannten Set ohne Neuaufbau (nur wenn wirklich ein neuer Prozess da ist).
    private var pidBuf = [Int32](repeating: 0, count: 8192)

    func start() {
        // EIGENER Hintergrund-Thread -> wird NICHT von der Bildverarbeitung im Main-Thread blockiert.
        q.sync {
            known = Set(currentPids())   // bekannte PIDs vormerken, damit wir nur NEUE prüfen
            for pid in known where isTarget(pid) { kill(pid, SIGKILL) }   // lief schon vor ClipVault
        }
        let s = DispatchSource.makeTimerSource(queue: q)
        s.schedule(deadline: .now() + 0.1, repeating: 0.03, leeway: .milliseconds(8))
        s.setEventHandler { [weak self] in self?.tick() }
        s.resume(); src = s
    }

    /// PIDs in den festen Puffer lesen (kein neues Array pro Takt)
    private func currentPids() -> ArraySlice<Int32> {
        let cap = pidBuf.count
        let r = pidBuf.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32(cap * MemoryLayout<Int32>.size)) }
        if r <= 0 { return [] }
        let count = r > Int32(cap) ? Int(r) / MemoryLayout<Int32>.size : Int(r)
        return pidBuf[0..<min(count, cap)]
    }

    private func tick() {
        // 1) Prozess schon beim START killen (voller Pfad via proc_pidpath -> keine 16-Zeichen-Kürzung),
        //    SIGKILL bevor er sein Fenster malt.
        let cur = currentPids()
        var sawNew = false
        for pid in cur where !known.contains(pid) {
            sawNew = true
            if isTarget(pid) { kill(pid, SIGKILL) }
        }
        // Menge nur neu aufbauen, wenn ein neuer Prozess kam (sonst bleibt sie gleich; beendete PIDs
        // stoeren nicht, sie fallen beim naechsten Neuaufbau heraus)
        if sawNew { known = Set(cur) }
        // 2) Backup (gedrosselt ~1 Hz; die Fensterliste kostet so viel wie der ganze PID-Takt):
        //    falls der Prozess doch durchgerutscht ist, per Fensterliste+PID killen.
        tickCount &+= 1
        if tickCount % 33 == 0, let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for w in infos where (w[kCGWindowOwnerName as String] as? String) == target {
                if let p = w[kCGWindowOwnerPID as String] as? Int { kill(pid_t(p), SIGKILL) }
            }
        }
    }

    private func isTarget(_ pid: Int32) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let path = String(validatingUTF8: buf) else { return false }
        return path.contains(target)
    }

    static func allPids() -> [Int32] {
        let cap = 8192
        var pids = [Int32](repeating: 0, count: cap)
        let r = proc_listallpids(&pids, Int32(cap * MemoryLayout<Int32>.size))
        if r <= 0 { return [] }
        let count = r > Int32(cap) ? Int(r)/MemoryLayout<Int32>.size : Int(r)
        return Array(pids.prefix(min(count, cap)))
    }
}
