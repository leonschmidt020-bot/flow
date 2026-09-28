import AppKit
import SwiftUI

// MARK: - Agent-Prompt-Karte: wächst rechts aus der Pille (wie die VFNotify-Karten, gleiches Fenster + gleicher Look)
//
// Zustände: Vorschlag („Daraus einen Agent-Prompt machen?“) → wird gebaut (Live-Text) → fertig (Vorschau, Kopieren/
// Einfügen/Ansehen, Original) · oder abgebrochen/fehlgeschlagen (Original einfügen/kopieren).
// Zustandswechsel ändern nur die Höhe (federnd) – die Karte bleibt dieselbe. Maus drauf = bleibt offen und die Vorschau
// wird größer; das Mausrad scrollt in der Vorschau. Esc/✕ schließen (beim Bauen: abbrechen). Nichts geht verloren –
// jeder fertige Prompt steht im Verlauf (Hub › Scratchpad › Agent-Prompts), das Original in ClipVault.

enum APStopKind: Equatable { case cancelled, failed }

enum APCardPhase: Equatable {
    case offer(APDetection)
    case building(partial: String, words: Int, started: Date)
    case done(APRecord)
    case stopped(APStopKind, reason: String, original: String)

    var key: String {
        switch self {
        case .offer: return "offer"
        case .building: return "building"
        case .done: return "done"
        case .stopped: return "stopped"
        }
    }
}

enum APCardAction: Equatable {
    case build, dismissOffer, cancel, copy, insert, open, copyOriginal, insertOriginal, retry, close
}

/// Wer die Karte zeigt (für Tests austauschbar)
protocol APPresenter: AnyObject {
    func show(_ phase: APCardPhase)
    func close()
    var isShowing: Bool { get }
    var onAction: (APCardAction) -> Void { get set }
    /// Kurz „Kopiert ✓“ / „Eingefügt ✓“ anzeigen
    func flash(_ what: APCardFlash)
}

enum APCardFlash { case copied, copiedOriginal, inserted }

// MARK: - Maße + Lage

enum APCardMetrics {
    static let width: CGFloat = 476
    static let tile: CGFloat = 96
    static let tileOverlap: CGFloat = 14
    static let corner: CGFloat = 22
    static let gap: CGFloat = 12
    static let margin: CGFloat = 32
    static let inset: CGFloat = 10

    static let offerH: CGFloat = 148
    static let buildingH: CGFloat = 272
    static let doneH: CGFloat = 338
    static let doneExpandedH: CGFloat = 500
    static let stoppedH: CGFloat = 264
    static let maxH: CGFloat = doneExpandedH

    static func height(_ p: APCardPhase, hovering: Bool) -> CGFloat {
        switch p {
        case .offer: return offerH
        case .building: return buildingH
        case .done: return hovering ? doneExpandedH : doneH
        case .stopped: return stoppedH
        }
    }
}

/// Geometrie: Fenster in Bildschirmkoordinaten, alles andere in Fensterkoordinaten (oben links = 0,0)
struct APGeo: Equatable {
    var windowFrame: NSRect
    var pill: CGRect
    var cardX: CGFloat
    /// Unterkante (wächst nach oben) bzw. Oberkante (wächst nach unten) der Karte
    var anchorY: CGFloat
    var growsUp: Bool
    var side: String

    func card(_ h: CGFloat) -> CGRect {
        growsUp ? CGRect(x: cardX, y: anchorY - h, width: APCardMetrics.width, height: h)
                : CGRect(x: cardX, y: anchorY, width: APCardMetrics.width, height: h)
    }

    func toScreen(_ r: CGRect) -> NSRect {
        NSRect(x: windowFrame.minX + r.minX, y: windowFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Karte + überstehende Illustration (Bildschirm) – für Klicks/Hover
    func hitRects(_ h: CGFloat) -> [NSRect] {
        let c = card(h)
        let tile = CGRect(x: c.maxX - 14 - APCardMetrics.tile, y: c.minY - APCardMetrics.tileOverlap, width: APCardMetrics.tile, height: APCardMetrics.tile)
        return [toScreen(c), toScreen(tile)]
    }

    /// Reine Berechnung (testbar). Bevorzugt RECHTS neben der Pille; ist dort kein Platz (oder steht die Pille hochkant am
    /// rechten Rand), links. Unten auf dem Bildschirm wächst die Karte nach oben, oben nach unten.
    static func make(pill: NSRect, visible vis: NSRect, frame sf: NSRect) -> APGeo {
        let W = APCardMetrics.width, H = APCardMetrics.maxH, g = APCardMetrics.gap, i = APCardMetrics.inset, ov = APCardMetrics.tileOverlap
        let vertical = pill.height > pill.width * 1.5
        let roomRight = vis.maxX - pill.maxX - g - i >= W
        let roomLeft = pill.minX - vis.minX - g - i >= W
        let right: Bool
        if vertical { right = (pill.midX - vis.minX) / max(vis.width, 1) < 0.5 || !roomLeft }
        else { right = roomRight || !roomLeft }
        var x = right ? pill.maxX + g : pill.minX - g - W
        x = min(max(x, vis.minX + i), vis.maxX - i - W)
        // Cocoa-Koordinaten (unten links): Unterkante bzw. Oberkante der Karte
        var growsUp: Bool
        var edge: CGFloat
        if vertical {
            growsUp = false
            edge = min(pill.midY + 90, vis.maxY - i - ov)
            edge = max(edge, vis.minY + i + H)
        } else if pill.midY < vis.midY {
            growsUp = true
            edge = max(pill.minY - 2, vis.minY + i)
            edge = min(edge, vis.maxY - i - ov - H)
        } else {
            growsUp = false
            edge = min(pill.maxY + 2, vis.maxY - i - ov)
            edge = max(edge, vis.minY + i + H)
        }
        let big = growsUp ? NSRect(x: x, y: edge, width: W, height: H + ov) : NSRect(x: x, y: edge - H, width: W, height: H + ov)
        var win = big.union(pill).insetBy(dx: -APCardMetrics.margin, dy: -APCardMetrics.margin)
        win.origin.x = max(win.minX, sf.minX); win.origin.y = max(win.minY, sf.minY)
        win.size.width = min(win.maxX, sf.maxX) - win.minX
        win.size.height = min(win.maxY, sf.maxY) - win.minY
        win = win.integral
        let pillWin = CGRect(x: pill.minX - win.minX, y: win.maxY - pill.maxY, width: pill.width, height: pill.height)
        let anchorWin = win.maxY - edge   // Cocoa-y → Fenster-y
        return APGeo(windowFrame: win, pill: pillWin, cardX: x - win.minX, anchorY: anchorWin, growsUp: growsUp,
                     side: right ? "rechts" : "links")
    }
}

// MARK: - Modell

final class APCardModel: ObservableObject {
    @Published var phase: APCardPhase
    @Published var geo: APGeo
    @Published var progress: CGFloat = 0
    @Published var hovering = false
    @Published var showOriginal = false
    @Published var copied = false
    @Published var copiedOriginal = false
    @Published var inserted = false
    /// Illustration je Zustand (Variante einmal gewählt, dann fest)
    @Published var illustrations: [String: String] = [:]
    var act: (APCardAction) -> Void = { _ in }

    init(phase: APCardPhase, geo: APGeo) { self.phase = phase; self.geo = geo }

    var height: CGFloat { APCardMetrics.height(phase, hovering: hovering) }

    static func baseIllustration(_ p: APCardPhase) -> String {
        switch p {
        case .offer: return "illu_prompt_vorschlag"
        case .building: return "illu_prompt_baut"
        case .done: return "illu_prompt_fertig"
        case .stopped: return "illu_prompt_vorschlag"
        }
    }

    /// Variante einmal pro Zustand wählen (außerhalb des Zeichnens aufrufen)
    func ensureIllustration(_ p: APCardPhase, random: Bool = true) {
        guard illustrations[p.key] == nil else { return }
        let base = APCardModel.baseIllustration(p)
        illustrations[p.key] = random ? VFNotify.shared.pickVariant(base) : base
    }

    func illustration(for p: APCardPhase) -> String { illustrations[p.key] ?? APCardModel.baseIllustration(p) }
}

enum APCardStyle {
    static let card = VFNotifyStyle.card
    static let lilac = Color(red: 0.74, green: 0.63, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.42)
    static let mint = Color(red: 0.45, green: 0.86, blue: 0.66)
    static let previewFill = Color.white.opacity(0.045)
    static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    /// Claude-CLI da? (Texte „Claude schreibt …“ vs. „nach Regeln“) – für Bilder/Tests austauschbar
    static var claudeAvailable: () -> Bool = { ClaudeCLI.isAvailable }

    /// Fußzeile eines Regel-Prompts: leise, ohne Alarm („Regeln · ohne Claude-CLI“)
    static func rulesLabel(_ note: String) -> String {
        if note.isEmpty || note == "Claude-CLI fehlt" { return "Regeln · ohne Claude-CLI" }
        return "Regeln · \(note)"
    }

    /// „claude/sonnet/low“ → „Sonnet · low“
    static func sourceLabel(_ s: String) -> String {
        let p = s.split(separator: "/").map(String.init)
        guard p.first == "claude", p.count >= 2 else { return s }
        return p[1].capitalized + (p.count > 2 ? " · \(p[2])" : "")
    }

    /// Illustration mit Rückfall: fehlt `illu_prompt_*`, eine vorhandene Illustration, sonst Symbol
    static func image(_ name: String) -> NSImage? {
        if let i = VFNotify.imageProvider(name) { return i }
        let fallback = name.hasPrefix("illu_prompt_baut") ? "illu_transforms" : name.hasPrefix("illu_prompt_fertig") ? "illu_scratchpad" : "illu_transforms"
        return VFNotify.imageProvider(fallback)
    }
}

// MARK: - Controller (Fenster, Hover, Zeit, Esc)

final class APCard: APPresenter {
    static let shared = APCard()

    var pillAnchor: () -> NSRect? = { VFNotify.shared.pillAnchor?() }
    var onAction: (APCardAction) -> Void = { _ in }

    private var panel: VFNotifyPanel?
    private var model: APCardModel?
    private var hitTimer: Timer?
    private var dismissTimer: Timer?
    private var closing = false

    var isShowing: Bool { model != nil && !closing }
    var phase: APCardPhase? { model?.phase }

    static func timeout(_ p: APCardPhase) -> TimeInterval? {
        switch p {
        case .offer: return 12
        case .building: return nil
        case .done: return 30
        case .stopped: return 45
        }
    }

    private func resolvePill() -> NSRect {
        if let a = pillAnchor(), a.width > 0, a.height > 0 { return a }
        let s = VFNotify.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        let vis = s?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: vis.midX - 22, y: vis.minY + 14, width: 44, height: 9)
    }

    func show(_ phase: APCardPhase) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.show(phase) }; return }
        if let m = model, !closing {
            let sameKind = m.phase.key == phase.key
            if sameKind { m.phase = phase }   // Live-Text: ohne Animation
            else {
                m.ensureIllustration(phase)
                if case .done = phase { m.copied = true; m.showOriginal = false }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { m.phase = phase }
            }
            if !sameKind { restartTimer() }
            return
        }
        if closing { finishClose() }
        let pill = resolvePill()
        let scr = VFNotify.screen(containing: NSPoint(x: pill.midX, y: pill.midY)) ?? NSScreen.main
        let geo = APGeo.make(pill: pill, visible: scr?.visibleFrame ?? pill.insetBy(dx: -800, dy: -600), frame: scr?.frame ?? pill.insetBy(dx: -800, dy: -600))
        let m = APCardModel(phase: phase, geo: geo)
        m.ensureIllustration(phase)
        if case .done = phase { m.copied = true }
        m.act = { [weak self] a in self?.handle(a) }
        model = m
        closing = false
        let p = panel ?? VFNotifyPanel()
        panel = p
        let host = VFNotifyHostingView(rootView: APCardStage(model: m))
        host.frame = NSRect(origin: .zero, size: geo.windowFrame.size)
        p.contentView = host
        p.setFrame(geo.windowFrame, display: false)
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { m.progress = 1 }
        }
        startHitTesting()
        restartTimer()
    }

    func flash(_ what: APCardFlash) {
        guard let m = model else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            switch what {
            case .copied: m.copied = true
            case .copiedOriginal: m.copiedOriginal = true
            case .inserted: m.inserted = true
            }
        }
        if what == .copiedOriginal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak m] in withAnimation { m?.copiedOriginal = false } }
        }
        restartTimer()
    }

    private func handle(_ a: APCardAction) {
        if a == .close { onAction(.close); return }
        onAction(a)
    }

    func close() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.close() }; return }
        guard let m = model, !closing else { return }
        closing = true
        dismissTimer?.invalidate(); dismissTimer = nil
        hitTimer?.invalidate(); hitTimer = nil
        panel?.ignoresMouseEvents = true
        withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) { m.progress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            guard let self, self.closing, self.model === m else { return }
            self.finishClose()
        }
    }

    private func finishClose() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        model = nil
        closing = false
    }

    private func restartTimer() {
        dismissTimer?.invalidate(); dismissTimer = nil
        guard let m = model, let t = APCard.timeout(m.phase) else { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.timeoutFired() }
    }

    private func timeoutFired() {
        guard let m = model, !closing else { return }
        if m.hovering {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.timeoutFired() }
            return
        }
        if case .offer = m.phase { onAction(.dismissOffer) } else { onAction(.close) }
    }

    /// Klicks/Scrollen nur auf der Karte – Rest des Fensters bleibt durchklickbar
    private func startHitTesting() {
        hitTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.panel, let m = self.model else { return }
            let mouse = NSEvent.mouseLocation
            let rects = m.geo.hitRects(m.height)
            let hot = rects.contains { $0.insetBy(dx: -3, dy: -3).contains(mouse) }
            let active = hot && m.progress > 0.9 && !self.closing
            if p.ignoresMouseEvents == active { p.ignoresMouseEvents = !active }
            if m.hovering != hot {
                // Vergrößern federnd; beim Verlassen erst nach kurzer Pause kleiner (kein Flackern am Rand)
                if hot { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { m.hovering = true } }
                else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak m] in
                        guard let m else { return }
                        let still = m.geo.hitRects(m.height).contains { $0.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation) }
                        if !still { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { m.hovering = false } }
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hitTimer = t
    }

    // MARK: Offscreen-Bilder

    @discardableResult
    static func renderPNG(_ phase: APCardPhase, to url: URL, progress: CGFloat = 1, hovering: Bool = false, showOriginal: Bool = false,
                          copied: Bool = true, pill: NSRect = NSRect(x: 560, y: 30, width: 66, height: 24),
                          screen: NSRect = NSRect(x: 0, y: 0, width: 1512, height: 949),
                          background: NSColor = NSColor(white: 0.88, alpha: 1), illustration: String? = nil) -> Bool {
        _ = NSApplication.shared
        let geo = APGeo.make(pill: pill, visible: screen, frame: screen)
        let m = APCardModel(phase: phase, geo: geo)
        m.progress = progress; m.hovering = hovering; m.showOriginal = showOriginal; m.copied = copied
        if let illustration { m.illustrations[phase.key] = illustration }
        let root = ZStack(alignment: .topLeading) {
            Color(nsColor: background)
            Capsule().fill(Color.black.opacity(0.92))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.32), lineWidth: 1))
                .frame(width: geo.pill.width, height: geo.pill.height)
                .offset(x: geo.pill.minX, y: geo.pill.minY)
            APCardStage(model: m)
        }
        .frame(width: geo.windowFrame.width, height: geo.windowFrame.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: geo.windowFrame.size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

// MARK: - SwiftUI: Bühne + Morph

struct APCardStage: View {
    @ObservedObject var model: APCardModel
    var body: some View {
        Color.clear
            .frame(width: model.geo.windowFrame.width, height: model.geo.windowFrame.height)
            .modifier(APMorph(progress: model.progress, height: model.height, geo: model.geo,
                              content: AnyView(APCardContent(model: model))))
            .environment(\.colorScheme, .dark)
    }
}

/// Wie VFMorph (Pille → Karte), zusätzlich ist die Kartenhöhe animierbar (Zustandswechsel, Hover-Vergrößerung)
struct APMorph: ViewModifier, Animatable {
    var progress: CGFloat
    var height: CGFloat
    let geo: APGeo
    let content: AnyView

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, height) }
        set { progress = newValue.first; height = newValue.second }
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }

    func body(content base: Content) -> some View {
        let p = progress, c = min(1, max(0, p))
        let a = geo.pill, b = geo.card(height)
        let cx = Self.lerp(a.midX, b.midX, c), cy = Self.lerp(a.midY, b.midY, c)
        let w = max(a.width, Self.lerp(a.width, b.width, p)), h = max(a.height, Self.lerp(a.height, b.height, p))
        let radius = Self.lerp(min(a.width, a.height) / 2, APCardMetrics.corner, c)
        let shapeAlpha = Self.smooth(0, 0.1, p)
        let contentAlpha = Self.smooth(0.45, 0.92, p)
        let border = Self.lerp(0.32, 0.09, c)
        let fill = Color(white: Self.lerp(0, 0.067, c))
        let scale = min(1, max(0.72, min(w / b.width, h / b.height)))
        let ov = APCardMetrics.tileOverlap * c
        let release = 40 * Self.smooth(0.9, 1.0, p)
        let W = geo.windowFrame.width, H = geo.windowFrame.height

        return base.overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(border), lineWidth: 1))
                    .shadow(color: .black.opacity(0.32 * c), radius: 22, x: 0, y: 10)
                    .shadow(color: .black.opacity(0.18 * c), radius: 3, x: 0, y: 1)
                    .frame(width: w, height: h)
                    .offset(x: cx - w / 2, y: cy - h / 2)
                    .opacity(shapeAlpha)
                ZStack(alignment: .topLeading) {
                    content
                        .frame(width: b.width, height: b.height, alignment: .top)
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

// MARK: - Inhalt

struct APCardContent: View {
    @ObservedObject var model: APCardModel

    var body: some View {
        let p = model.phase
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header(p)
                    .padding(.trailing, APCardMetrics.tile + 14)
                    .frame(height: headerHeight(p), alignment: .topLeading)
                body(p)
                Spacer(minLength: 0)
                buttons(p)
            }
            .padding(.leading, 22).padding(.trailing, 16).padding(.top, 18).padding(.bottom, 16)
            tile(p)
                .offset(x: -14, y: -APCardMetrics.tileOverlap)
        }
        .frame(width: APCardMetrics.width, height: model.height, alignment: .topLeading)
    }

    private func headerHeight(_ p: APCardPhase) -> CGFloat {
        switch p {
        case .offer: return 78
        case .done: return model.showOriginal ? 84 : 98
        default: return 84
        }
    }

    // Kopf: Marke, Titel, Kurzzeile
    @ViewBuilder private func header(_ p: APCardPhase) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                switch p {
                case .offer: chip("Vorschlag", "wand.and.stars", APCardStyle.lilac)
                case .building(_, _, let started):
                    chip("Agent-Prompt", "sparkles", APCardStyle.lilac)
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("\(max(0, Int(ctx.date.timeIntervalSince(started)))) s")
                            .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.42))
                    }
                    .padding(.leading, 2)
                case .done(let r):
                    chip(r.byRules ? "Prompt · ohne KI" : "Agent-Prompt", r.byRules ? "list.bullet.indent" : "sparkles", r.byRules ? APCardStyle.amber : APCardStyle.lilac)
                    Spacer(minLength: 4)
                    APSegment(left: "Prompt", right: "Original", rightOn: model.showOriginal) { on in
                        withAnimation(.easeOut(duration: 0.16)) { model.showOriginal = on }
                    }
                    .fixedSize()
                case .stopped(let k, _, _):
                    chip(k == .cancelled ? "Abgebrochen" : "Nicht gebaut", k == .cancelled ? "stop.circle" : "exclamationmark.triangle", APCardStyle.amber)
                }
            }
            Text(title(p))
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.85)
                .padding(.top, 8)
            if case .done(let r) = p, !model.showOriginal {
                // Kurzzeile: Ziel (eine Zeile) + Umfang
                let g = r.gist
                Text(g.goal)
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.top, 3)
                Text(APCardContent.counts(g))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(APCardStyle.lilac.opacity(0.85))
                    .lineLimit(1)
                    .padding(.top, 3)
            } else {
                Text(subtitle(p))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
    }

    static func counts(_ g: APGist) -> String {
        var parts: [String] = []
        parts.append(g.tasks == 1 ? "1 Anforderung" : "\(g.tasks) Anforderungen")
        if g.criteria > 0 { parts.append(g.criteria == 1 ? "1 Prüfpunkt" : "\(g.criteria) Prüfpunkte") }
        if g.rules > 0 { parts.append(g.rules == 1 ? "1 Regel" : "\(g.rules) Regeln") }
        if g.open > 0 { parts.append(g.open == 1 ? "1 offene Frage" : "\(g.open) offene Fragen") }
        return parts.joined(separator: " · ")
    }

    private func title(_ p: APCardPhase) -> String {
        switch p {
        case .offer: return "Daraus einen Agent-Prompt machen?"
        case .building: return "Prompt wird gebaut …"
        case .done: return "Dein Agent-Prompt ist fertig"
        case .stopped(let k, _, _): return k == .cancelled ? "Prompt abgebrochen" : "Prompt hat nicht geklappt"
        }
    }

    private func subtitle(_ p: APCardPhase) -> String {
        switch p {
        case .offer(let d): return d.cardLine
        case .building(let partial, let words, _):
            if !APCardStyle.claudeAvailable() { return "Flow ordnet deine \(words) Wörter nach Regeln …" }
            return partial.isEmpty ? "Claude ordnet deine \(words) Wörter …" : "Claude schreibt – \(APText.words(partial)) von ~\(max(words, APText.words(partial))) Wörtern"
        case .done(let r):
            if model.showOriginal { return "Dein Original-Diktat · \(APText.words(r.original)) Wörter" }
            return r.gist.line
        case .stopped(_, let why, _):
            return "Dein Original ist sicher – im Verlauf und in der Zwischenablage." + (why.isEmpty || why == "Abgebrochen" ? "" : " (\(why))")
        }
    }

    private func chip(_ label: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).frame(height: 19)
        .background(Capsule().fill(tint.opacity(0.14)))
        .fixedSize()
    }

    // Mitte: Vorschau / Live-Text / Original
    @ViewBuilder private func body(_ p: APCardPhase) -> some View {
        switch p {
        case .offer: EmptyView()
        case .building(let partial, _, _):
            preview {
                if partial.isEmpty { APFoldingLines().padding(.horizontal, 14).padding(.vertical, 14) }
                else { APLiveText(text: partial) }
            } overlay: {
                VStack { Spacer(); APSweepBar().frame(height: 2).padding(.horizontal, 1) }
            } corner: { EmptyView() }
        case .done(let r):
            preview {
                ScrollView(.vertical, showsIndicators: model.hovering) {
                    APPromptText(text: model.showOriginal ? r.original : r.prompt, original: model.showOriginal)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } overlay: {
                if !model.hovering {
                    VStack { Spacer(); LinearGradient(colors: [.clear, APCardStyle.card.opacity(0.95)], startPoint: .top, endPoint: .bottom).frame(height: 26) }
                        .allowsHitTesting(false)
                }
            } corner: { EmptyView() }
        case .stopped(_, _, let original):
            preview {
                ScrollView(.vertical, showsIndicators: model.hovering) {
                    Text(original)
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.82)).lineSpacing(2.5)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } overlay: {
                VStack { Spacer(); LinearGradient(colors: [.clear, APCardStyle.card.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: 22) }
                    .allowsHitTesting(false)
            } corner: { EmptyView() }
        }
    }

    private func preview<C: View, O: View, K: View>(@ViewBuilder _ content: () -> C, @ViewBuilder overlay: () -> O,
                                                     @ViewBuilder corner: () -> K) -> some View {
        ZStack(alignment: .topLeading) {
            content()
            overlay()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(APCardStyle.previewFill))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .overlay(alignment: .topTrailing) { corner().padding(.top, 7).padding(.trailing, 8) }
        .padding(.top, 2).padding(.bottom, 12)
    }

    // Unten: Knöpfe
    @ViewBuilder private func buttons(_ p: APCardPhase) -> some View {
        HStack(spacing: 6) {
            switch p {
            case .offer:
                APButton(title: "Prompt bauen", symbol: "sparkles", kind: .primary) { model.act(.build) }
                APButton(title: "Nein", kind: .ghost) { model.act(.dismissOffer) }
                Spacer(minLength: 0)
            case .building:
                APButton(title: "Abbrechen", kind: .secondary) { model.act(.cancel) }
                Spacer(minLength: 0)
                Text("Original liegt schon in der Zwischenablage")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            case .done(let r):
                if model.showOriginal {
                    APButton(title: model.copiedOriginal ? "Kopiert" : "Original kopieren", symbol: model.copiedOriginal ? "checkmark" : "doc.on.doc", kind: .primary) { model.act(.copyOriginal) }
                    APButton(title: "Original einfügen", symbol: "arrow.down.to.line", kind: .secondary) { model.act(.insertOriginal) }
                } else {
                    APButton(title: model.copied ? "Kopiert" : "Kopieren", symbol: model.copied ? "checkmark" : "doc.on.doc", kind: .primary, done: model.copied) { model.act(.copy) }
                    APButton(title: model.inserted ? "Eingefügt" : "Einfügen", symbol: "arrow.down.to.line", kind: .secondary) { model.act(.insert) }
                    APButton(title: "Ansehen", kind: .ghost) { model.act(.open) }
                }
                Spacer(minLength: 0)
                Text(r.byRules ? APCardStyle.rulesLabel(r.note) : "\(APCardStyle.sourceLabel(r.source)) · \(String(format: "%.1f", Double(r.buildMs) / 1000).replacingOccurrences(of: ".", with: ",")) s")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
            case .stopped:
                APButton(title: "Original einfügen", symbol: "arrow.down.to.line", kind: .primary) { model.act(.insertOriginal) }
                APButton(title: model.copiedOriginal ? "Kopiert" : "Original kopieren", symbol: model.copiedOriginal ? "checkmark" : "doc.on.doc", kind: .secondary) { model.act(.copyOriginal) }
                Spacer(minLength: 0)
                APButton(title: "Nochmal", symbol: "arrow.clockwise", kind: .ghost) { model.act(.retry) }
            }
        }
        .frame(height: 30)
    }

    // Illustration oben rechts (ragt über die Karte) + ✕
    @ViewBuilder private func tile(_ p: APCardPhase) -> some View {
        let s = APCardMetrics.tile
        let name = model.illustration(for: p)
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = APCardStyle.image(name) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(red: 0.92, green: 0.86, blue: 0.98)
                        Image(systemName: "text.badge.star").font(.system(size: 34, weight: .medium)).foregroundStyle(Color(red: 0.45, green: 0.30, blue: 0.66))
                    }
                }
            }
            .frame(width: s, height: s)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
            .id(name)
            .transition(.opacity)

            Button { model.act(.close) } label: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.white.opacity(0.55))
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                }
                .frame(width: 20, height: 20).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(isBuilding(p) ? "Abbrechen" : "Schließen")
        }
        .frame(width: s, height: s)
    }

    private func isBuilding(_ p: APCardPhase) -> Bool { if case .building = p { return true }; return false }
}

// MARK: - Bausteine

struct APButton: View {
    enum Kind { case primary, secondary, ghost }
    let title: String
    var symbol: String? = nil
    let kind: Kind
    var done = false
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: kind == .ghost ? .medium : .semibold)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(kind == .primary ? Color.black : Color.white.opacity(kind == .ghost ? (hover ? 0.9 : 0.62) : 0.92))
            .padding(.horizontal, kind == .ghost ? 10 : 13)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(APPressStyle())
        .onHover { hover = $0 }
    }

    private var fill: Color {
        switch kind {
        case .primary: return done ? Color(red: 0.86, green: 0.97, blue: 0.90) : (hover ? Color.white.opacity(0.9) : .white)
        case .secondary: return Color.white.opacity(hover ? 0.16 : 0.10)
        case .ghost: return Color.white.opacity(hover ? 0.08 : 0)
        }
    }
}

private struct APPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Kleiner Umschalter „Prompt | Original“ oben rechts in der Vorschau
struct APSegment: View {
    let left: String
    let right: String
    let rightOn: Bool
    let set: (Bool) -> Void
    var body: some View {
        HStack(spacing: 0) {
            seg(left, on: !rightOn) { set(false) }
            seg(right, on: rightOn) { set(true) }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
    private func seg(_ t: String, on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.6))
                .padding(.horizontal, 8).frame(height: 18)
                .background(Capsule().fill(on ? Color.white.opacity(0.92) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Prompt-Text leicht gesetzt: Überschriften lila in Versalien, „**Ziel:**“ fett, Rest Monospace
struct APPromptText: View {
    let text: String
    var original = false
    var body: some View {
        if original {
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.84)).lineSpacing(2.5).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(APPromptText.lines(text).enumerated()), id: \.offset) { _, l in line(l) }
            }
            .textSelection(.enabled)
        }
    }

    enum Line { case heading(String), goal(String, String), item(String), text(String), blank }

    static func lines(_ s: String) -> [Line] {
        var out: [Line] = []
        for raw in s.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if case .blank? = out.last {} else { out.append(.blank) }; continue }
            if t.hasPrefix("#") { out.append(.heading(t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))); continue }
            if let m = APText.firstMatch(APText.regex(#"^\*\*([^*]{1,20}):\*\*\s*(.*)$"#), t),
               let a = Range(m.range(at: 1), in: t), let b = Range(m.range(at: 2), in: t) {
                out.append(.goal(String(t[a]), String(t[b]))); continue
            }
            if t.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) != nil { out.append(.item(raw.replacingOccurrences(of: "**", with: ""))); continue }
            out.append(.text(t.replacingOccurrences(of: "**", with: "")))
        }
        while case .blank? = out.last { out.removeLast() }
        return out
    }

    @ViewBuilder private func line(_ l: Line) -> some View {
        switch l {
        case .heading(let h):
            Text(h.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(1.0).foregroundStyle(APCardStyle.lilac.opacity(0.9)).padding(.top, 5)
        case .goal(let k, let v):
            (Text(k + ": ").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
             + Text(v.replacingOccurrences(of: "`", with: "")).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.92)))
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        case .item(let s):
            Text(s.replacingOccurrences(of: "`", with: "")).font(APCardStyle.mono).foregroundStyle(.white.opacity(0.84)).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        case .text(let s):
            Text(s.replacingOccurrences(of: "`", with: "")).font(APCardStyle.mono).foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
        case .blank:
            Color.clear.frame(height: 2)
        }
    }
}

/// Live-Text beim Bauen: läuft von selbst nach unten mit, Schreibmarke blinkt am Ende
struct APLiveText: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    APPromptText(text: text)
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        RoundedRectangle(cornerRadius: 1).fill(APCardStyle.lilac.opacity(on ? 0.95 : 0.25)).frame(width: 7, height: 12)
                    }
                    .padding(.top, 2)
                    Color.clear.frame(height: 6).id("ende")
                }
                .padding(.horizontal, 14).padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo("ende", anchor: .bottom) }
            .onChange(of: text) { proxy.scrollTo("ende", anchor: .bottom) }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// Wartebild vor dem ersten Wort: Pegel-Balken der Pille falten sich Zeile für Zeile zu Textzeilen
struct APFoldingLines: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let rows = 6
                let rowH: CGFloat = 20
                let widths: [CGFloat] = [0.55, 0.92, 0.78, 0.86, 0.64, 0.4]
                for r in 0..<rows {
                    let y = CGFloat(r) * rowH + 8
                    guard y < size.height - 6 else { break }
                    let lineW = size.width * widths[r % widths.count]
                    let seg: CGFloat = 5, gapW: CGFloat = 3
                    let n = Int(lineW / (seg + gapW))
                    // Welle läuft pro Zeile versetzt durch; danach liegt die Zeile flach (= „Text“)
                    let cycle = 2.4
                    let phase = (t + Double(r) * 0.32).truncatingRemainder(dividingBy: cycle) / cycle
                    for k in 0..<n {
                        let x = CGFloat(k) * (seg + gapW)
                        let front = CGFloat(phase) * lineW * 1.25
                        let d = (front - x) / 60
                        let folded = min(1, max(0, d))                          // 0 = Pegel-Balken, 1 = flache Zeile
                        let wobble = abs(sin(t * 7.3 + Double(k) * 1.7) * cos(t * 3.1 + Double(k) * 0.9))
                        let barH = 3 + (1 - folded) * CGFloat(4 + 9 * wobble)
                        let h = folded >= 1 ? 5 : barH
                        let a = 0.14 + 0.5 * Double(folded) * (0.6 + 0.4 * sin(t * 2 + Double(r)))
                        let rect = CGRect(x: x, y: y + (12 - h) / 2, width: folded > 0.5 ? seg + gapW + 0.5 : seg * 0.6, height: h)
                        let color = folded > 0.5 ? Color.white.opacity(a) : APCardStyle.lilac.opacity(0.35 + 0.4 * wobble)
                        g.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2), with: .color(color))
                    }
                }
            }
        }
    }
}

/// Dünner Leuchtstreifen, der unten durch die Vorschau wandert (unbestimmter Fortschritt)
struct APSweepBar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            GeometryReader { geo in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let x = CGFloat((t * 0.55).truncatingRemainder(dividingBy: 1)) * (geo.size.width + 140) - 140
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, APCardStyle.lilac.opacity(0.9), .white, APCardStyle.lilac.opacity(0.9), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 140)
                        .offset(x: x)
                }
                .clipShape(Capsule())
            }
        }
    }
}

extension APCard {
    /// Esc: Maus auf der Karte? (beim Bauen bricht Esc nur dann ab)
    func escape() {
        guard let m = model, !closing else { return }
        let on = m.geo.hitRects(m.height).contains { $0.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation) }
        APFlow.shared.escape(mouseOnCard: on)
    }
}
