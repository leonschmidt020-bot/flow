import AppKit
import SwiftUI

/// Farbiger Rahmen um die ruhende Pille statt kleiner Punkte:
/// grün = Neues vom Partner, rot = Update, lila = Vorschläge. Bei mehreren gilt diese Reihenfolge.
/// Beim Erscheinen (oder Farbwechsel) zeichnet sich der Rahmen einmal mit einem Leuchtkopf um die Pille,
/// danach atmet er dreimal leicht und bleibt dann ruhig stehen. Folgt der Pille auf jeden Bildschirm.
final class PillRing {
    static let shared = PillRing()

    enum Kind: Int, CaseIterable { case suggestion = 0, update = 1, shared = 2   // höher = wichtiger
        var color: Color {
            switch self {
            case .shared: return Color(red: 0.20, green: 0.78, blue: 0.35)
            case .update: return Color(red: 1.0, green: 0.27, blue: 0.23)
            case .suggestion: return Color(red: 0.62, green: 0.45, blue: 1.0)
            }
        }
    }

    private var active: Set<Kind> = []
    private var panel: NSPanel?
    private let model = PillRingModel()
    private var timer: Timer?
    /// Abstand des Rahmens zur Pille (pt) – Platz fürs Leuchten
    static let gap: CGFloat = 3, glow: CGFloat = 8

    var current: Kind? { active.max { $0.rawValue < $1.rawValue } }

    func set(_ kind: Kind, _ on: Bool) {
        let before = current
        if on { active.insert(kind) } else { active.remove(kind) }
        let now = current
        guard before != now else { return }
        if let now { show(now, sweep: true) } else { hide() }
    }

    // MARK: Fenster

    private func show(_ kind: Kind, sweep: Bool) {
        if panel == nil {
            let p = SmartBadgePanel(size: NSSize(width: 60, height: 20), acceptsMouse: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.contentView = NSHostingView(rootView: PillRingView(model: model))
            panel = p
        }
        model.color = kind.color
        position()
        panel?.orderFrontRegardless()
        if sweep {
            model.progress = 0; model.head = 1
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.95)) { self.model.progress = 1 }
                withAnimation(.easeIn(duration: 0.35).delay(0.85)) { self.model.head = 0 }
            }
        }
        startTimer()
    }

    private func hide() {
        stopTimer()
        guard let p = panel, p.isVisible else { return }
        withAnimation(.easeOut(duration: 0.25)) { model.progress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { [weak self] in
            guard self?.current == nil else { return }
            p.orderOut(nil)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.position() }
        t.tolerance = 0.015   // darf mit anderen Weckern zusammengelegt werden (spart Aufwachen im Leerlauf)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// Rahmen der Pille folgen (sie wächst beim Drüberfahren und wandert mit der Maus über Bildschirme)
    private func position() {
        guard let p = panel, let pill = VFNotify.shared.pillAnchor?(), pill.width > 0 else { panel?.orderOut(nil); return }
        // Nicht während Diktat/Meeting-Aufnahme (Pille ist dann beschäftigt) – Rahmen kurz ausblenden
        let idle = SmartFlow.shared.pillIsIdle() && !SmartFlow.shared.isBusy()
        if !idle { if p.alphaValue > 0 { p.alphaValue = 0 }; return }
        if p.alphaValue < 1 { p.animator().alphaValue = 1 }
        let pad = PillRing.gap + PillRing.glow
        let f = pill.insetBy(dx: -pad, dy: -pad).integral
        if p.frame != f {
            p.setFrame(f, display: true)
            model.pillSize = pill.size
        }
        if !p.isVisible, current != nil { p.orderFrontRegardless() }
    }
}

final class PillRingModel: ObservableObject {
    @Published var color: Color = .green
    @Published var progress: CGFloat = 0     // 0 → 1: Rahmen zeichnet sich um die Pille
    @Published var head: CGFloat = 0         // Leuchtkopf-Stärke während des Zeichnens
    @Published var pillSize: CGSize = CGSize(width: 44, height: 9)
}

struct PillRingView: View {
    @ObservedObject var model: PillRingModel
    @State private var breathe = false

    var body: some View {
        GeometryReader { g in
            let inset = PillRing.glow
            let w = g.size.width - inset * 2, h = g.size.height - inset * 2
            let shape = Capsule(style: .circular)   // echte Kapsel wie die Pille (abgerundetes Rechteck war an den Enden flach)
            let closed = model.progress >= 0.999      // geschlossen: ohne Anfang/Ende zeichnen, sonst Knubbel an der Naht
            ZStack {
                // weiches Leuchten
                Group {
                    if closed { shape.stroke(model.color.opacity(breathe ? 0.20 : 0.10), lineWidth: 3) }
                    else { shape.trim(from: 0, to: model.progress).stroke(model.color.opacity(breathe ? 0.20 : 0.10), style: StrokeStyle(lineWidth: 3, lineCap: .round)) }
                }
                .blur(radius: 3)
                // scharfer Rahmen
                Group {
                    if closed { shape.stroke(model.color.opacity(0.85), lineWidth: 1.3) }
                    else { shape.trim(from: 0, to: model.progress).stroke(model.color.opacity(0.85), style: StrokeStyle(lineWidth: 1.3, lineCap: .round)) }
                }
                .opacity(breathe ? 1 : 0.85)
                // Leuchtkopf, der vorne mitläuft
                shape.trim(from: max(0, model.progress - 0.08), to: model.progress)
                    .stroke(Color.white.opacity(0.7 * model.head), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .blur(radius: 1.2)
            }
            .frame(width: w, height: h)
            .rotationEffect(.degrees(-90 * 0))       // Start oben links, im Uhrzeigersinn
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        // Audit 27.09.2026: endloses Atmen (weichgezeichnete Striche, jedes Bild neu) kostete gemessen ~4,8 % CPU dauerhaft –
        // der Rahmen steht oft tagelang (Vorschläge, Update). Jetzt drei Atemzüge, danach bleibt er ruhig hell stehen.
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatCount(3, autoreverses: true)) { breathe = true } }
    }
}

// MARK: - Offscreen-Bild (Sichtprüfung): Pille + Rahmen in mehreren Zeichen-Stufen
extension PillRing {
    static func renderPNG(to url: URL) -> Bool {
        _ = NSApplication.shared
        let pills: [CGSize] = [CGSize(width: 44, height: 9), CGSize(width: 96, height: 26), CGSize(width: 9, height: 44)]
        let steps: [CGFloat] = [0.25, 0.6, 1.0]
        let cell: CGFloat = 150
        let root = VStack(spacing: 0) {
            ForEach(Array(Kind.allCases.reversed()), id: \.rawValue) { kind in
                HStack(spacing: 0) {
                    ForEach(pills, id: \.width) { ps in
                        ForEach(steps, id: \.self) { st in
                            let m: PillRingModel = { let m = PillRingModel(); m.color = kind.color; m.progress = st; m.head = st < 1 ? 1 : 0; m.pillSize = ps; return m }()
                            ZStack {
                                Color(white: 0.13)
                                Capsule().fill(Color(white: 0.16)).overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                                    .frame(width: ps.width, height: ps.height)
                                PillRingView(model: m).frame(width: ps.width + 2 * (gap + glow), height: ps.height + 2 * (gap + glow))
                            }.frame(width: cell, height: cell * 0.6)
                        }
                    }
                }
            }
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: cell * 9, height: cell * 0.6 * 3)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}
