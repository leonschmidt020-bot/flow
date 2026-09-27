import AppKit
import SwiftUI

// MARK: - Wasser-Fortschritt (eine Zeichnung für Pille, Kachel und Listenbalken)
//
// Ruhig und „premium“:
//  • Wasser streng in die Innenform geschnitten (Kapsel bzw. abgerundetes Rechteck, mit Abstand zum Rand) – nie eckig, nie über den Rand
//  • steigt von unten nach oben, sobald die Form mindestens 14 pt hoch ist; flache Balken füllen sich von links nach rechts
//  • Verlauf: tiefes Blau am Boden, heller an der Oberfläche
//  • nur die Oberfläche wogt, Ausschlag passend zur Breite (9-pt-Strich ≈ 0,8 pt), nahe leer/voll flach
//  • ganz zarter Glanz direkt unter der Oberfläche – kein wandernder weißer Balken
//  • 0 % = nichts zu sehen, 100 % = randvoll

enum AudioWaterAxis { case up, right }

enum AudioWater {
    static let deep = (r: 0.08, g: 0.30, b: 0.84)
    static let surface = (r: 0.36, g: 0.63, b: 1.00)

    static var surfaceColor: Color { Color(red: surface.r, green: surface.g, blue: surface.b) }

    /// Füllrichtung: ab 14 pt Höhe von unten nach oben, sonst (flacher Balken) von links nach rechts
    static func axis(for size: CGSize) -> AudioWaterAxis { size.height >= 14 || size.height > size.width ? .up : .right }

    private static func color(_ c: (r: Double, g: Double, b: Double), _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: a)
    }

    private static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Zeichnet das Wasser in `rect` (Außenform). y wächst nach oben (AppKit/CG-Standard).
    /// - cornerRadius: nil = Kapsel (halbe kurze Seite), sonst Radius der Außenform
    /// - inset: Abstand zum Rand der Außenform (Rand der Pille bleibt frei)
    static func draw(in cg: CGContext, rect: CGRect, cornerRadius: CGFloat? = nil, inset: CGFloat,
                     fraction: Double, axis: AudioWaterAxis, t: Double, alpha: CGFloat = 1, blend: CGBlendMode = .normal) {
        let inner = rect.insetBy(dx: inset, dy: inset)
        guard inner.width > 0.5, inner.height > 0.5, alpha > 0.003 else { return }
        let f = CGFloat(max(0, min(1, fraction)))
        let len = axis == .up ? inner.height : inner.width
        let span = axis == .up ? inner.width : inner.height
        let level = len * f
        guard level > 0.2 else { return }   // 0 % → nichts

        let rad: CGFloat = cornerRadius.map { max(0, min($0 - inset, min(inner.width, inner.height) / 2)) }
            ?? min(inner.width, inner.height) / 2
        let clip = CGPath(roundedRect: inner, cornerWidth: rad, cornerHeight: rad, transform: nil)

        // Wellen-Ausschlag: ~9 % der Oberflächen-Breite (9-pt-Strich → 0,8 pt), höchstens 1,4 pt;
        // nahe leer/voll flach (sonst ragen Wellenspitzen über den Pegel hinaus)
        let room = min(level, len - level)
        let baseAmp = min(1.4, max(0.35, span * 0.09))
        let amp = baseAmp * smoothstep(0, baseAmp * 3, room)
        let wl = max(12, span * 1.3)
        func wave(_ s: CGFloat) -> CGFloat {
            let u = Double(s / wl) * 2 * .pi
            return amp * CGFloat(0.72 * sin(u + t * 2.1) + 0.28 * sin(u * 1.63 - t * 1.3 + 1.1))
        }
        func surfacePoint(_ s: CGFloat) -> CGPoint {
            axis == .up ? CGPoint(x: inner.minX + s, y: inner.minY + level + wave(s))
                        : CGPoint(x: inner.minX + level + wave(s), y: inner.minY + s)
        }
        let steps = max(12, Int(span / 1.5))
        let line = CGMutablePath()
        for i in 0...steps {
            let s = -1 + (span + 2) * CGFloat(i) / CGFloat(steps)
            let p = surfacePoint(s)
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        // Wasserfläche: Boden-Ecke → Oberfläche → andere Boden-Ecke (1 pt über die Innenform hinaus, der Schnitt macht die Form)
        let poly = CGMutablePath()
        var pts: [CGPoint] = [CGPoint(x: inner.minX - 1, y: inner.minY - 1)]
        for i in 0...steps { pts.append(surfacePoint(-1 + (span + 2) * CGFloat(i) / CGFloat(steps))) }
        pts.append(axis == .up ? CGPoint(x: inner.maxX + 1, y: inner.minY - 1) : CGPoint(x: inner.minX - 1, y: inner.maxY + 1))
        poly.addLines(between: pts)
        poly.closeSubpath()

        cg.saveGState()
        cg.setBlendMode(blend)
        cg.addPath(clip); cg.clip()
        cg.addPath(poly); cg.clip()
        // Verlauf: Boden tief → Oberfläche hell (über die Wasserhöhe, damit auch wenig Wasser beide Töne zeigt)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let midC = (r: (deep.r + surface.r) / 2 - 0.02, g: (deep.g + surface.g) / 2, b: (deep.b + surface.b) / 2 + 0.02)
        if let g = CGGradient(colorsSpace: space,
                              colors: [color(deep, 0.97 * alpha), color(midC, 0.97 * alpha), color(surface, 0.97 * alpha)] as CFArray,
                              locations: [0, 0.55, 1]) {
            let a = axis == .up ? CGPoint(x: inner.midX, y: inner.minY) : CGPoint(x: inner.minX, y: inner.midY)
            let top = max(level, min(len, 5))   // ganz wenig Wasser: nicht nur das helle Ende zeigen
            let b = axis == .up ? CGPoint(x: inner.midX, y: inner.minY + top) : CGPoint(x: inner.minX + top, y: inner.midY)
            cg.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // zarter Glanz direkt unter der Oberfläche (verschwindet, wenn die Form randvoll ist)
        let sheenA = 0.16 * alpha * smoothstep(0, 3, len - level) * smoothstep(0, 2, level)
        if sheenA > 0.003 {
            let depth = min(2.6, max(1.2, span * 0.3), level)
            if let g = CGGradient(colorsSpace: space,
                                  colors: [CGColor(gray: 1, alpha: sheenA), CGColor(gray: 1, alpha: 0)] as CFArray,
                                  locations: [0, 1]) {
                let a = axis == .up ? CGPoint(x: inner.midX, y: inner.minY + level + amp) : CGPoint(x: inner.minX + level + amp, y: inner.midY)
                let b = axis == .up ? CGPoint(x: inner.midX, y: inner.minY + level - amp - depth)
                                    : CGPoint(x: inner.minX + level - amp - depth, y: inner.midY)
                cg.drawLinearGradient(g, start: a, end: b, options: [])
            }
        }
        cg.restoreGState()

        // feine Oberflächen-Linie (nur innerhalb der Innenform, blendet nahe voll aus)
        let lineA = 0.30 * alpha * smoothstep(0, 3, len - level) * smoothstep(0, 1.5, level)
        if lineA > 0.003 {
            cg.saveGState()
            cg.setBlendMode(blend)
            cg.addPath(clip); cg.clip()
            cg.addPath(line)
            cg.setStrokeColor(CGColor(gray: 1, alpha: lineA))
            cg.setLineWidth(span < 10 ? 0.5 : 0.7)
            cg.setLineJoin(.round)
            cg.strokePath()
            cg.restoreGState()
        }
    }

    /// AppKit-Variante (aktueller NSGraphicsContext)
    static func draw(in rect: NSRect, cornerRadius: CGFloat? = nil, inset: CGFloat, fraction: Double, axis: AudioWaterAxis,
                     t: Double, alpha: CGFloat = 1, blend: CGBlendMode = .normal) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        draw(in: cg, rect: rect, cornerRadius: cornerRadius, inset: inset, fraction: fraction, axis: axis, t: t, alpha: alpha, blend: blend)
    }
}

// MARK: - SwiftUI: Wasser in einer Fläche (Kachel, Balken)

struct AudioWaterFill: View {
    var fraction: Double
    /// nil = aus der Größe (≥ 14 pt hoch → von unten nach oben)
    var axis: AudioWaterAxis?
    var cornerRadius: CGFloat?
    var inset: CGFloat = 0
    /// Nur Render: feste Zeit
    var time: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: time != nil)) { ctx in
            let t = time ?? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)
            Canvas { g, size in
                g.withCGContext { cg in
                    cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)   // CG: y nach oben
                    AudioWater.draw(in: cg, rect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius, inset: inset,
                                    fraction: fraction, axis: axis ?? AudioWater.axis(for: size), t: t)
                }
            }
        }
    }
}

/// Wie `AudioWaterFill`, aber der Pegel kommt geglättet aus dem laufenden Fortschritt (springt nie, läuft nie rückwärts).
struct AudioWaterLive: View {
    let meetingID: String
    let live: AudioImport.Live
    var axis: AudioWaterAxis?
    var cornerRadius: CGFloat?
    var inset: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)
            let f = AudioProgressSmoother.shared.value(meetingID, live: live, at: ctx.date)
            Canvas { g, size in
                g.withCGContext { cg in
                    cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
                    AudioWater.draw(in: cg, rect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius, inset: inset,
                                    fraction: f, axis: axis ?? AudioWater.axis(for: size), t: t)
                }
            }
        }
    }
}

// MARK: - Geglätteter Pegel
//
// Echter Fortschritt kommt in Stufen (~2,5-min-Stücke). Angezeigt wird:
//  1. Schätzung: vom letzten Stück aus läuft der Pegel mit dem gemessenen Tempo (Echtzeitfaktor × Stücklänge) auf das
//     nächste Stück zu – linear bis 85 %, dann weich asymptotisch → erreicht das nächste Stück nie von selbst,
//     d. h. höchstens ein Stück über dem echten Wert.
//  2. Folgen: kritisch gedämpfte Feder zur Schätzung (kein Sprung, kein Überschwingen), nie rückwärts.

final class AudioProgressSmoother {
    static let shared = AudioProgressSmoother()

    private struct State { var x: Double; var v: Double; var t: Date }
    private var states: [String: State] = [:]
    /// Federstärke (rad/s): ~0,8 s bis die Anzeige einer Stufe gefolgt ist
    static let omega = 5.5

    /// Zielwert aus echtem Fortschritt + Schätzung bis zum nächsten Stück
    static func target(_ l: AudioImport.Live, at now: Date) -> Double {
        var f = l.fraction
        if let from = l.hintFrom, let next = l.hintNext, let at = l.hintAt, let secs = l.hintSeconds, secs > 0.05, next > from {
            let x = max(0, now.timeIntervalSince(at)) / secs
            let knee = 0.85
            let e = x < knee ? x : knee + (1 - knee) * (1 - exp(-(x - knee) / (1 - knee)))
            let est = from + (next - from) * e
            if est < next { f = max(f, est) }
        }
        return max(0, min(1, f))
    }

    /// Angezeigter Pegel für `id` zum Zeitpunkt `now` (zeitbasiert – mehrfache Aufrufe im selben Bild sind harmlos)
    func value(_ id: String, live: AudioImport.Live, at now: Date = Date()) -> Double {
        let target = Self.target(live, at: now)
        guard var s = states[id] else {
            // erster Blick: laufende Datei (z. B. nach Neustart) direkt auf dem Stand zeigen, neue Datei ab 0
            states[id] = State(x: target, v: 0, t: now)
            return target
        }
        let dt = min(2, max(0, now.timeIntervalSince(s.t)))
        if dt > 0 {
            let n = max(1, Int(ceil(dt * 240)))
            let h = dt / Double(n)
            let w = Self.omega
            for _ in 0..<n {
                let goal = max(target, s.x)
                s.v += (w * w * (goal - s.x) - 2 * w * s.v) * h
                if s.v < 0 { s.v = 0 }
                let nx = s.x + s.v * h
                if nx > goal { s.x = goal; s.v = 0 } else { s.x = nx }
            }
            s.t = now
            states[id] = s
        }
        return s.x
    }

    /// Letzter angezeigter Wert (ohne weiterzurechnen)
    func last(_ id: String) -> Double? { states[id]?.x }

    func forget(_ id: String) { states[id] = nil }
}
