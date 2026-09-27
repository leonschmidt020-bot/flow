import AppKit
import SwiftUI

// MARK: - Update verfügbar: roter Punkt oben in der Mitte der ruhenden Pille
// (grün oben links = Neues vom Partner, lila oben rechts = Vorschläge)
// Maus ~0,4 s auf den Punkt (oder auf die Pille, wenn sonst nichts Neues da ist) → kleine Karte
// „Update verfügbar … Jetzt installieren“. Ist das letzte Update gescheitert oder zurückgenommen (update-failed.json),
// zeigt dieselbe Karte den Fehler mit „Nochmal versuchen“ – nie „aktuell“, solange die App älter als das Repo ist.

final class UpdateBadgeModel: ObservableObject {
    @Published var summary = ""
    @Published var count = 0
    @Published var installing = false
    @Published var appeared = false
    /// letztes Update gescheitert → Fehler-Karte
    @Published var failed = false
    @Published var title = "Update verfügbar"
    var install: () -> Void = {}
    var later: () -> Void = {}
}

final class UpdateBadge {
    static let shared = UpdateBadge()
    static let red = Color(red: 1.0, green: 0.23, blue: 0.19)   // Rot = Update
    static let width: CGFloat = 340

    private var dot: NSPanel?
    private var card: NSPanel?
    private let model = UpdateBadgeModel()
    private var timer: Timer?
    private var hoverSince: Date?
    private var leftSince: Date?
    private var hidden = false          // „Später“ in der Karte → Punkt bis zum nächsten neuen Stand ausblenden
    private var hiddenFor: [String] = []

    var isOpen: Bool { card?.isVisible ?? false }
    private var pending: Updater.Pending? { Updater.shared.pendingUpdate }

    func start() {
        Updater.shared.onPendingChange = { [weak self] in self?.refresh() }
        model.install = { [weak self] in
            self?.model.installing = true
            Updater.shared.install()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.closeCard() }
        }
        model.later = { [weak self] in
            self?.hidden = true
            self?.hiddenFor = self?.pending?.key ?? []
            self?.closeCard()
            self?.refresh()
        }
        refresh()
    }

    private func refresh() {
        if let p = pending {
            if hidden && hiddenFor != p.key { hidden = false }       // neuer Stand → Punkt wieder zeigen
            UpdateBadge.fill(model, p)
        }
        model.installing = Updater.shared.isInstalling
        update()
    }

    private var shouldShowDot: Bool {
        pending != nil && !hidden && !Updater.shared.isInstalling && SmartFlow.shared.pillIsIdle() && !SmartFlow.shared.isBusy()
    }

    /// Update wartet und ist nicht weggeklickt – solange läuft der Takt (auch während eines Diktats), sonst ist der Rahmen danach taub
    private var wantsDot: Bool { pending != nil && !hidden && !Updater.shared.isInstalling }

    private func update() {
        if wantsDot || isOpen { if shouldShowDot { showDot() } else { hideDot() }; startTimer() }
        else { hideDot(); closeCard(); stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; hoverSince = nil; leftSince = nil }

    private func tick() {
        guard let pill = VFNotify.shared.pillAnchor?(), pill.width > 0 else { hideDot(); return }
        let show = shouldShowDot
        if show { showDot(); positionDot(pill) } else { hideDot() }
        let m = NSEvent.mouseLocation
        let onDot = (dot?.isVisible == true ? dot!.frame : .zero).insetBy(dx: -5, dy: -5).contains(m)
        // Die Pille selbst nur, wenn weder Neues vom Partner noch Vorschläge warten
        let onPill = pill.insetBy(dx: -6, dy: -6).contains(m) && PillRing.shared.current == .update
        if isOpen {
            let inside = onDot || pill.insetBy(dx: -6, dy: -6).contains(m) || (card?.frame.insetBy(dx: -6, dy: -6).contains(m) ?? false)
            if inside { leftSince = nil } else {
                if leftSince == nil { leftSince = Date() }
                if Date().timeIntervalSince(leftSince!) > 0.6 { closeCard() }
            }
            if SmartFlow.shared.isBusy() { closeCard() }
        } else if show && (onDot || onPill) && !VFNotify.shared.isShowing
                    && !SharedInboxBadge.shared.isListOpen && !SmartPillBadge.shared.isListOpen {
            if hoverSince == nil { hoverSince = Date() }
            if Date().timeIntervalSince(hoverSince!) > 0.4 { openCard() }
        } else { hoverSince = nil }
        if !wantsDot && !isOpen { stopTimer() }
    }

    // MARK: Punkt

    static func dotCenter(for pill: NSRect) -> NSPoint {
        pill.height > pill.width * 1.5 ? NSPoint(x: pill.midX + pill.width / 2 - 1, y: pill.midY)
                                       : NSPoint(x: pill.midX, y: pill.maxY)
    }

    private func showDot() { PillRing.shared.set(.update, pending != nil && !hidden && !Updater.shared.isInstalling) }   // Rahmen um die Pille statt Punkt
    private func hideDot() { PillRing.shared.set(.update, pending != nil && !hidden && !Updater.shared.isInstalling) }

    private func positionDot(_ pill: NSRect) {
        guard let d = dot else { return }
        let c = UpdateBadge.dotCenter(for: pill)
        let o = NSPoint(x: (c.x - d.frame.width / 2).rounded(), y: (c.y - d.frame.height / 2).rounded())
        if d.frame.origin != o { d.setFrameOrigin(o) }
    }

    // MARK: Karte

    func openCard() {
        guard !isOpen, pending != nil, let pill = VFNotify.shared.pillAnchor?() else { return }
        SharedInboxBadge.shared.closeList(); SmartPillBadge.shared.closeList()
        let p = card ?? SmartBadgePanel(size: NSSize(width: UpdateBadge.width, height: 150), acceptsMouse: true)
        card = p
        p.contentView = VFNotifyHostingView(rootView: UpdateBadgeCard(model: model))
        model.appeared = false
        let host = NSHostingView(rootView: UpdateBadgeCard(model: model).frame(width: UpdateBadge.width).fixedSize(horizontal: false, vertical: true))
        let size = NSSize(width: UpdateBadge.width, height: ceil(max(120, host.fittingSize.height)))
        let scr = VFNotify.screen(containing: NSPoint(x: pill.midX, y: pill.midY)) ?? NSScreen.main
        p.setFrame(SmartPillBadge.listFrame(size: size, pill: pill, visible: scr?.visibleFrame ?? pill.insetBy(dx: -600, dy: -400)), display: true)
        p.orderFrontRegardless()
        DispatchQueue.main.async { withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { self.model.appeared = true } }
        leftSince = nil
        startTimer()
    }

    func closeCard() {
        guard let p = card, p.isVisible else { return }
        withAnimation(.easeOut(duration: 0.14)) { model.appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { p.orderOut(nil) }
        hoverSince = nil
    }

    /// Karte aus dem offenen Stand füllen (normal oder gescheitert)
    static func fill(_ m: UpdateBadgeModel, _ p: Updater.Pending) {
        if let f = p.failed {
            m.failed = true
            m.title = f.rolledBack == true ? "Update zurückgenommen" : "Update hat nicht geklappt"
            m.summary = "\(f.reason) · Stand \(f.version ?? "?") (\(f.commit.prefix(7)))"
            m.count = 0
        } else {
            m.failed = false
            m.title = "Update verfügbar"
            m.summary = Updater.summary(p)
            m.count = p.all.count
        }
    }

    // MARK: Offscreen-Bild

    static func renderPNG(summary: String, count: Int, failed: Bool = false, to url: URL) -> Bool {
        _ = NSApplication.shared
        let m = UpdateBadgeModel(); m.summary = summary; m.count = count; m.appeared = true
        if failed {
            fill(m, Updater.Pending(flow: [], clipvault: [], failed: Updater.Failed(
                commit: "74bf01e0000000", version: "1.7.10", reason: "Flow 1.7.10 lief nicht stabil (kein Lebenszeichen binnen 120 s)",
                rolledBack: true, manual: false, at: 0)))
        }
        let root = ZStack {
            LinearGradient(colors: [Color(white: 0.86), Color(white: 0.93)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                UpdateBadgeCard(model: m).frame(width: width).fixedSize(horizontal: false, vertical: true)
                ZStack(alignment: .top) {
                    Capsule().fill(Color(white: 0.16).opacity(0.92)).overlay(Capsule().strokeBorder(Color.white.opacity(0.42), lineWidth: 1))
                        .frame(width: 44, height: 9)
                    ZStack {
                        Circle().fill(.white).frame(width: SmartPillBadge.dotSize, height: SmartPillBadge.dotSize)
                        Circle().fill(red).frame(width: SmartPillBadge.dotSize - 3.2, height: SmartPillBadge.dotSize - 3.2)
                    }.offset(y: -5)
                }
            }
        }.frame(width: width + 80, height: 260)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width + 80, height: 260)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}

final class BlueDotView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let s = SmartPillBadge.dotSize
        let r = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1); sh.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.systemRed.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1.6, dy: 1.6)).fill()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

struct UpdateBadgeCard: View {
    @ObservedObject var model: UpdateBadgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.failed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(UpdateBadge.red)
                Text(model.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                if !model.failed {
                    Text("\(model.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(UpdateBadge.red.opacity(0.3)))
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14)
            Text(model.summary).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.top, 7)
            Text(model.failed ? "Flow läuft mit der bisherigen Version weiter. Details: update.log"
                              : "Deine Daten bleiben – Flow startet danach kurz neu.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 16).padding(.top, 5)
            HStack(spacing: 6) {
                Button(action: model.install) {
                    HStack(spacing: 6) {
                        if model.installing { ProgressView().controlSize(.small).tint(.black) }
                        Text(model.installing ? "Wird installiert …" : (model.failed ? "Nochmal versuchen" : "Jetzt installieren")).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.black).padding(.horizontal, 14).frame(height: 30)
                    .background(Capsule().fill(Color.white)).contentShape(Capsule())
                }.buttonStyle(.plain).disabled(model.installing)
                Button(action: model.later) {
                    Text("Später").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 12).frame(height: 30).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(VFNotifyStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
        .padding(1)
        .scaleEffect(model.appeared ? 1 : 0.92, anchor: .bottom)
        .opacity(model.appeared ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }
}
