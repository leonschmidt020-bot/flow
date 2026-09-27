import Foundation

// MARK: - Schlüsselbild-Erkennung (reine Logik, ohne Bildschirm testbar: `Flow --mc-sim`)
//
// Eingang: 1 Bild/s als kleines Graustufenbild (160 px breit). Ausgang: „jetzt ein Schlüsselbild sichern“.
//
// 1. Raster aus 8×8-px-Zellen. Je Zelle: mittlere Abweichung zum vorigen Bild.
// 2. Teilnehmer-Videos: Zellen, die sich fast jede Sekunde ändern (langsamer Mittelwert > 0,45), werden
//    ausgeblendet (Maske). Scrollen/Folienwechsel sind kurz und fallen nicht darunter.
// 3. Erst wenn das Bild (ohne Maske) ≥ 2 s ruhig ist, wird verglichen → kein Sichern mitten im Scrollen/Übergang.
// 4. Ruhiges Bild vs. letztes Schlüsselbild: Anteil geänderter Zellen (bezogen auf das GANZE Bild) ≥ Schwelle → sichern.
//    Kleine Änderungen (Mauszeiger ist aus, Hover in der Leiste) bleiben darunter, schrittweise Änderungen summieren sich.
// 5. Aufbau-Folien: neues Bild < 25 s nach dem vorigen und ähnlich → ersetzt das vorige (vollständigste Stufe bleibt).
// 6. Mengenbremse: Eimer mit 12 Marken, füllt sich mit 80/Std. → höchstens ~80 Bilder pro Stunde, kurze Schübe erlaubt.

struct MCThumb {
    let w: Int
    let h: Int
    var px: [UInt8]   // Graustufen, zeilenweise

    static let width = 160

    /// BGRA-Puffer (beliebige Größe) auf 160 px Breite mitteln
    static func fromBGRA(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> MCThumb {
        let tw = MCThumb.width
        let th = max(40, min(140, Int((Double(height) * Double(tw) / Double(max(width, 1))).rounded())))
        var out = [UInt8](repeating: 0, count: tw * th)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let sx = Double(width) / Double(tw), sy = Double(height) / Double(th)
        // pro Zielpixel ein 3×3-Raster von Stichproben (schnell, genug gegen Rauschen)
        for y in 0..<th {
            for x in 0..<tw {
                var sum = 0
                for j in 0..<3 {
                    let yy = min(height - 1, Int((Double(y) + (Double(j) + 0.5) / 3) * sy))
                    let row = p + yy * bytesPerRow
                    for i in 0..<3 {
                        let xx = min(width - 1, Int((Double(x) + (Double(i) + 0.5) / 3) * sx))
                        let q = row + xx * 4
                        // BGRA → Luma (Rec. 601, ganzzahlig)
                        sum += (Int(q[2]) * 77 + Int(q[1]) * 150 + Int(q[0]) * 29) >> 8
                    }
                }
                out[y * tw + x] = UInt8(sum / 9)
            }
        }
        return MCThumb(w: tw, h: th, px: out)
    }
}

final class MCChangeDetector {
    struct Params {
        var cell = 8
        /// Zelle gilt als geändert ab dieser mittleren Abweichung (0…255)
        var cellDiff: Double = 7
        /// „ruhig“: höchstens dieser Anteil Zellen ändert sich von Bild zu Bild
        var stableFrac: Double = 0.012
        /// so viele ruhige Sekunden vor dem Vergleich
        var stableSeconds = 2
        /// Schwelle: Anteil geänderter Zellen (ganzes Bild) gegenüber dem letzten Schlüsselbild
        var keyFrac: Double = 0.06
        /// Video-Maske: Änderungshäufigkeit je Zelle (steigt mit `liveUp`, fällt mit `liveDown`), an ab `liveOn`, aus unter `liveOff`
        var liveUp: Double = 0.10
        var liveDown: Double = 0.07
        var liveOn: Double = 0.30
        var liveOff: Double = 0.10
        /// Mindestabstand zweier Schlüsselbilder
        var minGap: Double = 6
        /// Schrittweise Änderungen (Aufbau-Folie, Tippen, kleines Scrollen): kommt die nächste Änderung < replaceWindow s
        /// nach dem letzten Sichern und ist ähnlich (< replaceFrac), ersetzt sie das vorige Bild – höchstens replaceChain s lang
        var replaceWindow: Double = 25
        var replaceFrac: Double = 0.30
        /// … und nur, wenn die Änderung überwiegend auf vorher LEEREN Flächen liegt (dazugekommen statt ersetzt)
        var additiveMin: Double = 0.7
        var replaceChain: Double = 120
        /// Kleine Nachträge (letzte getippte Zeilen, Markierung auf der Folie): ≥ minorFrac geändert und minorStable s ruhig
        /// → das letzte Bild wird aktualisiert (kein neues Bild, kostet keine Marke)
        var minorFrac: Double = 0.012
        var minorStable = 12
        /// Mengenbremse
        var perHour: Double = 80
        var burst: Double = 12
        /// erstes Bild frühestens nach … s (Maske für Videos muss sich erst bilden)
        var firstAfter: Double = 3
    }

    enum Decision: Equatable {
        case none
        /// neues Schlüsselbild; `replacesPrevious` = das letzte ersetzen (Aufbau-Folie)
        case save(change: Double, replacesPrevious: Bool, roi: [Double]?)
    }

    var p = Params()
    private(set) var cols = 0, rows = 0
    private var prev: MCThumb?
    private var key: MCThumb? { didSet { keyFlat = key.map { flatCells($0) } ?? [] } }
    /// Zellen des Vergleichsbilds ohne Inhalt (einfarbig)
    private var keyFlat: [Bool] = []
    private var keyT: Double = -1e9
    private var live: [Double] = []
    private var liveMask: [Bool] = []
    /// Maske auf ganze Video-Kacheln erweitert (Umriss der zusammenhängenden Video-Zellen + 1 Zelle Rand)
    private var region: [Bool] = []
    /// Beginn der aktuellen Ersetzungs-Kette / letztes Sichern
    private var chainT: Double = -1e9
    private var lastSaveT: Double = -1e9
    private var stableRun = 0
    private var tokens: Double
    private var lastT: Double?
    private(set) var saved = 0
    /// Diagnose
    private(set) var maskedFrac: Double = 0
    private(set) var lastChangeVsKey: Double = 0

    init(params: Params = Params()) {
        p = params
        tokens = params.burst
    }

    /// Nach einem Fensterwechsel neu anfangen (Maske und Vergleichsbild verwerfen)
    func reset() {
        prev = nil; key = nil; keyT = -1e9; live = []; liveMask = []; region = []; stableRun = 0; cols = 0; rows = 0
        chainT = -1e9; lastSaveT = -1e9
    }

    /// Ein Bild pro Sekunde. `t` = Sekunden seit Beginn.
    func feed(_ th: MCThumb, t: Double) -> Decision {
        if let lt = lastT { tokens = min(p.burst, tokens + (t - lt) * p.perHour / 3600) }
        lastT = t
        let c = p.cell
        let nc = th.w / c, nr = th.h / c
        if nc != cols || nr != rows || prev == nil || prev!.px.count != th.px.count {
            cols = nc; rows = nr
            live = [Double](repeating: 0, count: nc * nr)
            liveMask = [Bool](repeating: false, count: nc * nr)
            region = liveMask
            prev = th; key = nil; stableRun = 0
            return .none
        }
        let dPrev = cellDiffs(th, prev!)
        prev = th
        // Maske (Teilnehmer-Videos) nachführen
        for i in 0..<dPrev.count {
            let x: Double = dPrev[i] > p.cellDiff ? 1 : 0
            live[i] += (x - live[i]) * (x > live[i] ? p.liveUp : p.liveDown)
            if liveMask[i] { if live[i] < p.liveOff { liveMask[i] = false } } else if live[i] > p.liveOn { liveMask[i] = true }
        }
        region = MCChangeDetector.expand(liveMask, cols: cols, rows: rows)
        var changedNow = 0, masked = 0
        for i in 0..<dPrev.count {
            if region[i] { masked += 1 } else if dPrev[i] > p.cellDiff { changedNow += 1 }
        }
        let total = Double(dPrev.count)
        maskedFrac = Double(masked) / total
        let unstable = Double(changedNow) / total > p.stableFrac
        stableRun = unstable ? 0 : stableRun + 1
        guard stableRun >= p.stableSeconds, t >= p.firstAfter else { return .none }

        guard let k = key else {
            // erstes Schlüsselbild
            key = th; keyT = t; chainT = t; lastSaveT = t; saved += 1; tokens -= 1
            return .save(change: 1, replacesPrevious: false, roi: roi(th))
        }
        let dKey = cellDiffs(th, k)
        var changed = 0, added = 0
        for i in 0..<dKey.count where !region[i] && dKey[i] > p.cellDiff {
            changed += 1
            if i < keyFlat.count && keyFlat[i] { added += 1 }
        }
        let frac = Double(changed) / total
        let additive = Double(added) / Double(max(changed, 1))
        lastChangeVsKey = frac
        if frac < p.keyFrac {
            guard frac >= p.minorFrac, changed >= 3, stableRun >= p.minorStable, t - lastSaveT >= p.minGap else { return .none }
            key = th; lastSaveT = t
            return .save(change: frac, replacesPrevious: true, roi: roi(th))
        }
        guard t - lastSaveT >= p.minGap else { return .none }
        let replace = t - lastSaveT < p.replaceWindow && t - chainT < p.replaceChain && frac < p.replaceFrac && additive >= p.additiveMin
        if !replace {
            guard tokens >= 1 else { return .none }   // Bremse: später erneut (Änderung bleibt bestehen)
            tokens -= 1
            saved += 1
            chainT = t
            keyT = t
        }
        key = th
        lastSaveT = t
        return .save(change: frac, replacesPrevious: replace, roi: roi(th))
    }

    /// Nach einem manuell gemerkten Moment: aktuelles Bild gilt als Vergleichsbild
    func markCurrentAsKey(t: Double) {
        if let pv = prev { key = pv; keyT = t; chainT = -1e9; lastSaveT = t }
    }

    /// Video-Zellen → ganze Kacheln: Umriss je zusammenhängender Gruppe (8er-Nachbarschaft, ≥ 2 Zellen) füllen, 1 Zelle Rand.
    /// So zählen Sprecher-Rahmen, Namensschilder und ruhige Ecken einer Kachel nicht als „Folie geändert“.
    static func expand(_ m: [Bool], cols: Int, rows: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: m.count)
        var seen = [Bool](repeating: false, count: m.count)
        for s in 0..<m.count where m[s] && !seen[s] {
            var stack = [s]; seen[s] = true
            var n = 0, x0 = cols, y0 = rows, x1 = 0, y1 = 0
            while let i = stack.popLast() {
                n += 1
                let x = i % cols, y = i / cols
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < cols, ny < rows else { continue }
                    let j = ny * cols + nx
                    if m[j] && !seen[j] { seen[j] = true; stack.append(j) }
                } }
            }
            let pad = n >= 2 ? 1 : 0
            for y in max(0, y0 - pad)...min(rows - 1, y1 + pad) { for x in max(0, x0 - pad)...min(cols - 1, x1 + pad) { out[y * cols + x] = true } }
        }
        return out
    }

    /// Zelle einfarbig (Spannweite hell–dunkel < 14)?
    private func flatCells(_ th: MCThumb) -> [Bool] {
        let c = p.cell
        var out = [Bool](repeating: false, count: cols * rows)
        guard th.px.count >= cols * c * rows * c else { return out }
        for r in 0..<rows {
            for q in 0..<cols {
                var mn = 255, mx = 0
                for y in (r * c)..<(r * c + c) {
                    let o = y * th.w + q * c
                    for x in 0..<c { let v = Int(th.px[o + x]); if v < mn { mn = v }; if v > mx { mx = v } }
                }
                out[r * cols + q] = mx - mn < 14
            }
        }
        return out
    }

    private func cellDiffs(_ a: MCThumb, _ b: MCThumb) -> [Double] {
        let c = p.cell
        var out = [Double](repeating: 0, count: cols * rows)
        a.px.withUnsafeBufferPointer { pa in
            b.px.withUnsafeBufferPointer { pb in
                for r in 0..<rows {
                    for q in 0..<cols {
                        var s = 0
                        for y in (r * c)..<(r * c + c) {
                            let o = y * a.w + q * c
                            for x in 0..<c { s += abs(Int(pa[o + x]) - Int(pb[o + x])) }
                        }
                        out[r * cols + q] = Double(s) / Double(c * c)
                    }
                }
            }
        }
        return out
    }

    /// Bereich mit geteiltem Inhalt: größtes Rechteck neben den Video-Kacheln (links/rechts/oben/unten vom Umriss aller
    /// Video-Zellen). So liest die Texterkennung keine Namensschilder. nil = keine Kacheln erkannt oder kein klarer Bereich.
    private func roi(_ th: MCThumb) -> [Double]? {
        var x0 = cols, y0 = rows, x1 = -1, y1 = -1, n = 0
        for i in 0..<region.count where region[i] {
            n += 1
            let x = i % cols, y = i / cols
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        guard n >= max(3, region.count / 33) else { return nil }
        let W = Double(cols), H = Double(rows)
        // Kandidaten (x, y, w, h) in Zellen
        let c: [(Double, Double, Double, Double)] = [
            // je 1 Zelle in den Rand der Kacheln hinein (die Maske ist um 1 Zelle aufgeblasen – sonst fehlt der Folienrand)
            (0, 0, min(W, Double(x0 + 1)), H),                   // links der Kacheln
            (Double(max(0, x1)), 0, W - Double(max(0, x1)), H),  // rechts
            (0, 0, W, min(H, Double(y0 + 1))),                   // darüber
            (0, Double(max(0, y1)), W, H - Double(max(0, y1))),  // darunter
        ]
        guard let best = c.max(by: { $0.2 * $0.3 < $1.2 * $1.3 }), best.2 * best.3 >= 0.25 * W * H else { return nil }
        return [best.0 / W, best.1 / H, best.2 / W, best.3 / H]
    }
}
