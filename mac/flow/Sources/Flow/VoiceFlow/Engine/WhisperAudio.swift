import Accelerate
import Foundation

/// Pegel für Flüstern: Flüstern ist 15–25 dB leiser als normale Sprache und hat kaum Tiefen – nur Rumpeln/Brummen
/// liegt dort. Deshalb: Hochpass 120 Hz, dann auf festen Sprachpegel (-20 dBFS am 95-%-Rahmen) anheben,
/// höchstens 40-fach (+32 dB), weiche Begrenzung statt Übersteuern. (`Transcriber.normalizedGentle` hebt höchstens 4-fach.)
enum WhisperGain {
    static let targetDB: Float = -20
    static let maxGain: Float = 40

    static func prepare(_ s: [Float]) -> [Float] {
        guard s.count > 1024 else { return s }
        var y = highPass(s, cutoff: 120)
        // Sprach-Pegel: 95-%-Wert der 30-ms-Rahmen
        let f = 480
        var r: [Float] = []
        r.reserveCapacity(y.count / f)
        y.withUnsafeBufferPointer { p in
            var i = 0
            while i + f <= p.count { var v: Float = 0; vDSP_rmsqv(p.baseAddress! + i, 1, &v, vDSP_Length(f)); r.append(v); i += f }
        }
        guard !r.isEmpty else { return s }
        r.sort()
        let ref = r[min(r.count - 1, Int(Double(r.count) * 0.95))]
        guard ref > 1e-5 else { return s }
        let gain = min(maxGain, pow(10, targetDB / 20) / ref)
        guard gain > 1.05 else { return y }
        // weiche Begrenzung (tanh) oberhalb ~-3 dBFS
        for i in 0..<y.count { let v = y[i] * gain; y[i] = abs(v) < 0.7 ? v : (v > 0 ? 1 : -1) * (0.7 + 0.3 * tanh((abs(v) - 0.7) / 0.3)) }
        return y
    }

    /// Butterworth-Hochpass 2. Ordnung (Biquad)
    static func highPass(_ s: [Float], cutoff: Double) -> [Float] {
        let w0 = 2 * Double.pi * cutoff / 16000, q = 0.7071
        let alpha = sin(w0) / (2 * q), cw = cos(w0)
        let a0 = 1 + alpha
        let b0 = Float((1 + cw) / 2 / a0), b1 = Float(-(1 + cw) / a0), b2 = b0
        let a1 = Float(-2 * cw / a0), a2 = Float((1 - alpha) / a0)
        var out = [Float](repeating: 0, count: s.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<s.count {
            let x = s[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            out[i] = y; x2 = x1; x1 = x; y2 = y1; y1 = y
        }
        return out
    }
}

/// Macht aus normaler Sprache geflüsterte (LPC: Stimmband-Anregung durch Rauschen ersetzen, Tiefen weg, leiser).
/// Für die Flüster-Vergleichsstimmen (Kohorte) und Selbsttests – echte Flüster-Aufnahmen gibt es von fremden Stimmen nicht.
enum Whisperizer {
    static func make(_ x: [Float], levelDB: Float = -44, seed: UInt64 = 1) -> [Float] {
        let n = 400, h = 200, order = 18
        guard x.count > n * 2 else { return x }
        var rng = SplitMix(seed: seed)
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        // Vor-Betonung
        var pre = [Float](repeating: 0, count: x.count)
        pre[0] = x[0]
        for i in 1..<x.count { pre[i] = x[i] - 0.95 * x[i - 1] }
        var y = [Float](repeating: 0, count: x.count + n)
        var i = 0
        while i + n < x.count {
            var fr = [Float](repeating: 0, count: n)
            for k in 0..<n { fr[k] = pre[i + k] * win[k] }
            let a = lpc(fr, order: order)
            // Rest-Energie (Anregung)
            var e: Float = 0
            for k in 0..<n {
                var r = fr[k]
                for j in 1...order where k - j >= 0 { r += a[j] * fr[k - j] }
                e += r * r
            }
            let g = sqrt(e / Float(n))
            // Rauschen durch das Vokaltrakt-Filter 1/A(z)
            var out = [Float](repeating: 0, count: n)
            for k in 0..<n {
                var v = rng.gauss() * g
                for j in 1...order where k - j >= 0 { v -= a[j] * out[k - j] }
                out[k] = v
            }
            for k in 0..<n { y[i + k] += out[k] * win[k] }
            i += h
        }
        // Ent-Betonung + Hochpass 300 Hz (Flüstern hat kaum Tiefen)
        var d = [Float](repeating: 0, count: x.count)
        var prev: Float = 0
        for k in 0..<x.count { prev = y[k] + 0.95 * prev; d[k] = prev }
        d = WhisperGain.highPass(d, cutoff: 300)
        // Pegel: 80-%-Rahmen auf levelDB, dazu leises Mikro-Rauschen
        var r: [Float] = []
        var k = 0
        while k + 480 <= d.count { var v: Float = 0; d.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + k, 1, &v, 480) }; r.append(v); k += 480 }
        r.sort()
        let act = r.isEmpty ? 1 : max(r[Int(Double(r.count - 1) * 0.8)], 1e-9)
        let gain = pow(10, levelDB / 20) / act
        let floor = pow(10, Float(-66) / 20)
        return d.map { $0 * gain + rng.gauss() * floor }
    }

    /// Levinson-Durbin; a[0] = 1
    static func lpc(_ fr: [Float], order: Int) -> [Float] {
        var r = [Float](repeating: 0, count: order + 1)
        for lag in 0...order {
            var s: Float = 0
            fr.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(fr.count - lag)) }
            r[lag] = s
        }
        var a = [Float](repeating: 0, count: order + 1)
        a[0] = 1
        guard r[0] > 1e-10 else { return a }
        r[0] *= 1.0001
        var e = r[0]
        for i in 1...order {
            var acc = r[i]
            for j in 1..<i { acc += a[j] * r[i - j] }
            let k = -acc / e
            var na = a
            for j in 1..<i { na[j] = a[j] + k * a[i - j] }
            na[i] = k
            a = na
            e *= (1 - k * k)
            if e <= 0 { break }
        }
        return a
    }

    struct SplitMix {
        var s: UInt64
        init(seed: UInt64) { s = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
        mutating func gauss() -> Float {
            let u1 = max(uniform(), 1e-7), u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }
}
