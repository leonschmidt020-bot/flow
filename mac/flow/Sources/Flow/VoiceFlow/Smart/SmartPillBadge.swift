import AppKit
import Combine
import SwiftUI

// MARK: - „Flow lernt mit“: kleiner Punkt an der ruhenden Pille + Vorschlagsliste beim Überfahren
//
// Liegt als eigenes, winziges Fenster über der Pille (Pill.swift bleibt unverändert).
// Punkt nur, wenn Vorschläge offen sind UND die Pille ruht. Maus ~0,4 s auf Pille/Punkt (oder Klick auf
// den Punkt) → kompakte dunkle Liste wächst zur Bildschirmmitte hin; jeder Eintrag: Ja / Nein.
// Einrichten: SmartPillBadge.shared.start() (nach VFNotify.shared.pillAnchor)

final class SmartPillBadge {
    static let shared = SmartPillBadge()

    /// Kapsel der Pille in Bildschirmkoordinaten (Standard: dieselbe Quelle wie die Meldungskarten)
    var pillRect: () -> NSRect? = { VFNotify.shared.pillAnchor?() }

    static let dotSize: CGFloat = 9
    static let listWidth: CGFloat = 392
    static let hoverDelay: TimeInterval = 0.4
    static let leaveDelay: TimeInterval = 0.6

    private var dot: NSPanel?
    private var list: NSPanel?
    private var listModel = SmartListModel()
    private var timer: Timer?
    private var hoverSince: Date?
    private var leftSince: Date?
    private var bag = Set<AnyCancellable>()
    private var started = false

    var isListOpen: Bool { list?.isVisible ?? false }

    func start() {
        guard !started else { return }
        started = true
        let flow = SmartFlow.shared
        flow.$visiblePending.combineLatest(flow.$prefs)
            .receive(on: RunLoop.main)
            .sink { [weak self] items, _ in
                self?.listModel.items = items
                self?.update()
            }
            .store(in: &bag)
        listModel.accept = { id, choice in SmartFlow.shared.accept(id, choice: choice) }
        listModel.dismiss = { id in SmartFlow.shared.dismiss(id) }
        listModel.openHub = { [weak self] in
            self?.closeList()
            VoiceFlowWindow.shared.show(VFSection(rawValue: "gelernt") ?? .insights)
        }
    }

    // MARK: Sichtbarkeit

    private var shouldShowDot: Bool {
        let f = SmartFlow.shared
        return hasPending && f.pillIsIdle() && !f.isBusy()
    }

    /// Es warten Vorschläge (unabhängig davon, ob die Pille gerade beschäftigt ist).
    /// Der Takt muss laufen, solange der lila Rahmen steht – sonst reagiert die Pille nach einem Diktat nicht mehr aufs Überfahren.
    private var hasPending: Bool { SmartFlow.shared.prefs.enabled && !SmartFlow.shared.visiblePending.isEmpty }

    private func update() {
        if hasPending || isListOpen {
            if shouldShowDot { showDot() } else { hideDot() }
            startTimer()
        } else {
            hideDot(); closeList(); stopTimer()
        }
        if isListOpen, listModel.items.isEmpty { closeList() }
        if isListOpen { resizeList() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil; hoverSince = nil; leftSince = nil }

    private func tick() {
        SmartFlow.shared.dropExpired()   // abgelaufene Vorschläge nehmen auch den Rahmen mit
        guard let pill = pillRect(), pill.width > 0 else { hideDot(); return }
        let show = shouldShowDot
        if show { showDot(); positionDot(pill) } else { hideDot() }
        let m = NSEvent.mouseLocation
        let dotFrame = dot?.isVisible == true ? dot!.frame : .zero
        let hot = pill.insetBy(dx: -6, dy: -6).contains(m) || dotFrame.insetBy(dx: -4, dy: -4).contains(m)
        if isListOpen {
            let inside = hot || (list?.frame.insetBy(dx: -6, dy: -6).contains(m) ?? false)
            if inside { leftSince = nil } else {
                if leftSince == nil { leftSince = Date() }
                if Date().timeIntervalSince(leftSince!) > SmartPillBadge.leaveDelay { closeList() }
            }
            if VFNotify.shared.isShowing || SmartFlow.shared.isBusy() { closeList() }
        } else if show && hot && !VFNotify.shared.isShowing && !SharedInboxBadge.shared.isListOpen
                    // Gibt es Neues vom Partner, gehört das Überfahren der Pille dem grünen Punkt – Vorschläge nur über den lila Punkt
                    && PillRing.shared.current == .suggestion {
            if hoverSince == nil { hoverSince = Date() }
            if Date().timeIntervalSince(hoverSince!) > SmartPillBadge.hoverDelay { openList() }
        } else {
            hoverSince = nil
        }
        if !hasPending && !isListOpen { stopTimer() }
    }

    // MARK: Punkt

    private func showDot() { PillRing.shared.set(.suggestion, SmartFlow.shared.prefs.enabled && !SmartFlow.shared.visiblePending.isEmpty) }   // Rahmen um die Pille statt Punkt

    private func hideDot() { PillRing.shared.set(.suggestion, SmartFlow.shared.prefs.enabled && !SmartFlow.shared.visiblePending.isEmpty) }

    /// Oben rechts an der Kapsel (hochkant: oben)
    static func dotCenter(for pill: NSRect) -> NSPoint {
        pill.height > pill.width * 1.5 ? NSPoint(x: pill.midX + pill.width / 2 - 1, y: pill.maxY - 1)
                                       : NSPoint(x: pill.maxX - 2, y: pill.maxY - 1)
    }

    private func positionDot(_ pill: NSRect) {
        guard let d = dot else { return }
        let c = SmartPillBadge.dotCenter(for: pill)
        let o = NSPoint(x: (c.x - d.frame.width / 2).rounded(), y: (c.y - d.frame.height / 2).rounded())
        if d.frame.origin != o { d.setFrameOrigin(o) }
    }

    // MARK: Liste

    func openList() {
        guard !isListOpen, !listModel.items.isEmpty, let pill = pillRect() else { return }
        let p = list ?? SmartBadgePanel(size: NSSize(width: SmartPillBadge.listWidth, height: 200), acceptsMouse: true)
        list = p
        let host = VFNotifyHostingView(rootView: SmartSuggestionList(model: listModel))
        p.contentView = host
        listModel.appeared = false
        layoutList(pill: pill)
        p.alphaValue = 1
        p.orderFrontRegardless()
        DispatchQueue.main.async { withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { self.listModel.appeared = true } }
        leftSince = nil
        startTimer()
        log("Flow lernt mit: Vorschlagsliste geöffnet (\(listModel.items.count))")
    }

    func closeList() {
        guard let p = list, p.isVisible else { return }
        withAnimation(.easeOut(duration: 0.14)) { listModel.appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { p.orderOut(nil) }
        hoverSince = nil
    }

    private func resizeList() { if let pill = pillRect() { layoutList(pill: pill) } }

    private func layoutList(pill: NSRect) {
        guard let p = list else { return }
        let size = SmartSuggestionList.size(for: listModel.items)
        let scr = VFNotify.screen(containing: NSPoint(x: pill.midX, y: pill.midY)) ?? NSScreen.main
        let vis = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 949)
        p.setFrame(SmartPillBadge.listFrame(size: size, pill: pill, visible: vis), display: true)
    }

    /// Zur Bildschirmmitte hin neben/über/unter die Pille, ganz auf dem Bildschirm (testbar)
    static func listFrame(size: NSSize, pill: NSRect, visible vis: NSRect) -> NSRect {
        let gap: CGFloat = 12, inset: CGFloat = 10
        var r: NSRect
        if pill.height > pill.width * 1.5 {
            let left = pill.midX > vis.midX
            r = NSRect(x: left ? pill.minX - gap - size.width : pill.maxX + gap, y: pill.midY - size.height / 2, width: size.width, height: size.height)
        } else if pill.midY < vis.midY {
            r = NSRect(x: pill.midX - size.width / 2, y: pill.maxY + gap, width: size.width, height: size.height)
        } else {
            r = NSRect(x: pill.midX - size.width / 2, y: pill.minY - gap - size.height, width: size.width, height: size.height)
        }
        r.origin.x = min(max(r.minX, vis.minX + inset), vis.maxX - inset - size.width)
        r.origin.y = min(max(r.minY, vis.minY + inset), vis.maxY - inset - size.height)
        return r.integral
    }

    // MARK: Offscreen-Bild (Sichtprüfung)

    @discardableResult
    static func renderPNG(items: [SmartSuggestion], to url: URL, hoveredPill: Bool = true) -> Bool {
        _ = NSApplication.shared
        let scrW: CGFloat = 900, scrH: CGFloat = 640
        let pill = hoveredPill ? NSRect(x: scrW / 2 - 45, y: 22, width: 90, height: 24) : NSRect(x: scrW / 2 - 22, y: 30, width: 44, height: 9)
        let listSize = SmartSuggestionList.size(for: items)
        let lf = listFrame(size: listSize, pill: pill, visible: NSRect(x: 0, y: 0, width: scrW, height: scrH))
        let model = SmartListModel()
        model.items = items
        model.appeared = true
        func flip(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: scrH - r.maxY, width: r.width, height: r.height) }
        let dc = dotCenter(for: pill)
        let root = ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.86), Color(white: 0.93)], startPoint: .top, endPoint: .bottom)
            // die Pille
            Capsule().fill(hoveredPill ? Color.black.opacity(0.82) : Color(white: 0.16).opacity(0.92))
                .overlay(Capsule().strokeBorder(Color.white.opacity(hoveredPill ? 0.32 : 0.42), lineWidth: 1))
                .overlay(alignment: .leading) {
                    if hoveredPill {
                        HStack(spacing: 5) {
                            Image(systemName: "globe").font(.system(size: 12, weight: .medium))
                            Text("DE+EN").font(.system(size: 11, weight: .semibold))
                        }.foregroundStyle(.white.opacity(0.92)).padding(.leading, 10)
                    }
                }
                .frame(width: pill.width, height: pill.height)
                .offset(x: flip(pill).minX, y: flip(pill).minY)
            SmartDotShape()
                .frame(width: dotSize + 8, height: dotSize + 8)
                .offset(x: dc.x - (dotSize + 8) / 2, y: scrH - dc.y - (dotSize + 8) / 2)
            if !items.isEmpty {
                SmartSuggestionList(model: model)
                    .frame(width: lf.width, height: lf.height)
                    .offset(x: flip(lf).minX, y: flip(lf).minY)
            }
        }
        .frame(width: scrW, height: scrH)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: scrW, height: scrH)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}

// MARK: - Fenster

final class SmartBadgePanel: NSPanel {
    init(size: NSSize, acceptsMouse: Bool = true) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = !acceptsMouse
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lila Punkt mit weißem Ring (wie ein Badge)
final class SmartDotView: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let s = SmartPillBadge.dotSize
        let r = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1); sh.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor(VF.purple).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1.6, dy: 1.6)).fill()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Gleicher Punkt für das Offscreen-Bild
struct SmartDotShape: View {
    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: SmartPillBadge.dotSize, height: SmartPillBadge.dotSize)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            Circle().fill(VF.purple).frame(width: SmartPillBadge.dotSize - 3.2, height: SmartPillBadge.dotSize - 3.2)
        }
    }
}

// MARK: - Liste (dunkel, wie die Meldungskarten)

final class SmartListModel: ObservableObject {
    @Published var items: [SmartSuggestion] = []
    @Published var appeared = false
    /// Gewähltes Kürzel je Snippet-Vorschlag
    @Published var chosen: [UUID: String] = [:]
    var accept: (UUID, String?) -> Void = { _, _ in }
    var dismiss: (UUID) -> Void = { _ in }
    var openHub: () -> Void = {}
}

struct SmartSuggestionList: View {
    @ObservedObject var model: SmartListModel
    static let maxRows = 3
    static let rowHeight: CGFloat = 92
    static let chipExtra: CGFloat = 34

    /// Echte Höhe von SwiftUI messen (Text kann 1–2 Zeilen haben)
    static func size(for items: [SmartSuggestion]) -> NSSize {
        let m = SmartListModel(); m.items = items; m.appeared = true
        let host = NSHostingView(rootView: SmartSuggestionList(model: m)
            .frame(width: SmartPillBadge.listWidth).fixedSize(horizontal: false, vertical: true))
        let h = host.fittingSize.height
        return NSSize(width: SmartPillBadge.listWidth, height: ceil(max(80, h)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.80, green: 0.70, blue: 1.0))
                Text("Vorschläge").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("\(model.items.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Color.white.opacity(0.12)))
                Spacer()
                Button(action: model.openHub) {
                    Text("Alle ansehen").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).frame(height: 46)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            ForEach(Array(model.items.prefix(Self.maxRows))) { s in
                SmartListRow(s: s, model: model)
                if s.id != model.items.prefix(Self.maxRows).last?.id { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 60) }
            }
            if model.items.count > Self.maxRows {
                Button(action: model.openHub) {
                    Text("+ \(model.items.count - Self.maxRows) weitere in „Gelernt“").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity).frame(height: 30)
                }.buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(VFNotifyStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
        .padding(1)
        .scaleEffect(model.appeared ? 1 : 0.92, anchor: .bottom)
        .opacity(model.appeared ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }
}

struct SmartListRow: View {
    let s: SmartSuggestion
    @ObservedObject var model: SmartListModel
    @State private var hover = false

    var body: some View {
        let (bg, ink) = VFNotifyStyle.fallbackColors(s.kind.illustration)
        let options = s.payload.triggerOptions ?? []
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(bg)
                Image(systemName: s.kind.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
            }
            .frame(width: 32, height: 32)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(s.text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.68)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if s.kind == .snippet, options.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(options, id: \.self) { o in
                            let on = (model.chosen[s.id] ?? options[0]) == o
                            Button { model.chosen[s.id] = o } label: {
                                Text(o).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
                                    .foregroundStyle(on ? .white : .white.opacity(0.62))
                                    .padding(.horizontal, 9).frame(height: 22)
                                    .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0.05)))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.5 : 0.12), lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 5)
                }
                HStack(spacing: 4) {
                    Button { model.accept(s.id, model.chosen[s.id] ?? options.first) } label: {
                        Text(SmartFlow.primaryLabel(s.kind)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 12).frame(height: 24).background(Capsule().fill(.white)).contentShape(Capsule())
                    }.buttonStyle(.plain)
                    Button { model.dismiss(s.id) } label: {
                        Text("Nein").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 10).frame(height: 24).contentShape(Capsule())
                    }.buttonStyle(.plain).help("Nein – solche Vorschläge kommen seltener")
                    Spacer()
                    SmartConfidenceDots(value: s.confidence)
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Color.white.opacity(hover ? 0.04 : 0))
        .onHover { hover = $0 }
    }
}

/// Drei ansteigende Balken (wie Empfang) = wie sicher sich Flow ist
struct SmartConfidenceDots: View {
    let value: Double
    var dark = true
    var body: some View {
        let n = value >= 0.8 ? 3 : (value >= 0.65 ? 2 : 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill((dark ? Color.white : VF.teal1).opacity(i < n ? (dark ? 0.6 : 0.9) : 0.18))
                    .frame(width: 3, height: CGFloat(5 + 3 * i))
            }
        }
        .help("Sicherheit: \(Int(value * 100)) %")
        .accessibilityLabel("Sicherheit \(Int(value * 100)) Prozent")
    }
}
