import Accelerate
import Foundation

/// Klang-Vergleich für Namen: MFCC-Merkmale + DTW (dynamische Zeitverzerrung).
/// Vergleicht ein Stück Diktat (die Wörter, wo Parakeet „Shark Wes“ gehört hat) mit deinen eigenen Aufnahmen
/// des Namens. Sprecherabhängig – genau richtig: es soll eigene Aussprache wiedererkennen. ~1 ms pro Vergleich.
enum AcousticMatch {
    static let sampleRate = 16_000
    static let frame = 400        // 25 ms
    static let hop = 160          // 10 ms
    static let fftSize = 512
    static let melBands = 26
    static let coeffs = 13        // c1…c13 (c0 = Lautstärke fällt weg)

    private static let window: [Float] = {
        var w = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&w, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        return w
    }()

    private static let melFilters: [[Float]] = {
        func mel(_ f: Float) -> Float { 2595 * log10(1 + f / 700) }
        func hz(_ m: Float) -> Float { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(80), hi = mel(7600)
        let pts = (0...(melBands + 1)).map { hz(lo + (hi - lo) * Float($0) / Float(melBands + 1)) }
        let bins = pts.map { Int(($0 / Float(sampleRate)) * Float(fftSize)) }
        var out: [[Float]] = []
        for m in 1...melBands {
            var f = [Float](repeating: 0, count: fftSize / 2 + 1)
            let a = bins[m - 1], b = bins[m], c = bins[m + 1]
            if b > a { for k in a..<b { f[k] = Float(k - a) / Float(b - a) } }
            if c > b { for k in b..<c { f[k] = Float(c - k) / Float(c - b) } }
            out.append(f)
        }
        return out
    }()

    private static let dct: [[Float]] = (1...coeffs).map { k in
        (0..<melBands).map { n in cos(Float.pi * Float(k) * (Float(n) + 0.5) / Float(melBands)) }
    }

    private static let fftSetup: FFTSetup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!

    /// MFCC-Rahmen (je 13 Werte), mittelwertbereinigt (CMN) → Mikro/Raum fällt weitgehend heraus.
    static func features(_ s: [Float]) -> [[Float]] {
        guard s.count >= frame else { return [] }
        var frames: [[Float]] = []
        var re = [Float](repeating: 0, count: fftSize / 2), im = [Float](repeating: 0, count: fftSize / 2)
        var buf = [Float](repeating: 0, count: fftSize)
        var start = 0
        // Vorbetonung
        var x = s
        for i in stride(from: x.count - 1, to: 0, by: -1) { x[i] -= 0.97 * x[i - 1] }
        while start + frame <= x.count {
            for i in 0..<fftSize { buf[i] = i < frame ? x[start + i] * window[i] : 0 }
            var power = [Float](repeating: 0, count: fftSize / 2 + 1)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buf.withUnsafeBufferPointer { bp in
                        bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                    power[0] = rp[0] * rp[0]
                    power[fftSize / 2] = ip[0] * ip[0]
                    for k in 1..<(fftSize / 2) { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
                }
            }
            var logMel = [Float](repeating: 0, count: melBands)
            for m in 0..<melBands {
                var e: Float = 0
                vDSP_dotpr(melFilters[m], 1, power, 1, &e, vDSP_Length(power.count))
                logMel[m] = log(max(e, 1e-10))
            }
            frames.append(dct.map { row in
                var v: Float = 0
                vDSP_dotpr(row, 1, logMel, 1, &v, vDSP_Length(melBands))
                return v
            })
            start += hop
        }
        // CMN + grobe Varianz-Normierung
        guard !frames.isEmpty else { return [] }
        var mean = [Float](repeating: 0, count: coeffs), sd = [Float](repeating: 0, count: coeffs)
        for f in frames { for i in 0..<coeffs { mean[i] += f[i] } }
        for i in 0..<coeffs { mean[i] /= Float(frames.count) }
        for f in frames { for i in 0..<coeffs { sd[i] += (f[i] - mean[i]) * (f[i] - mean[i]) } }
        for i in 0..<coeffs { sd[i] = sqrt(sd[i] / Float(frames.count)) + 1e-3 }
        return frames.map { f in (0..<coeffs).map { (f[$0] - mean[$0]) / sd[$0] } }
    }

    /// Nur die Rahmen mit Sprache (Energie), damit Stille vorn/hinten den Vergleich nicht verwässert
    static func speechOnly(_ s: [Float]) -> [Float] { SpeechMeter.trim(s, padBefore: 0.03, padAfter: 0.05) }

    /// DTW-Abstand zweier Merkmalsfolgen, normiert auf die Pfadlänge. Kleiner = ähnlicher. Band = ±50 % Länge.
    static func dtw(_ a: [[Float]], _ b: [[Float]]) -> Float {
        let n = a.count, m = b.count
        guard n > 2, m > 2 else { return .infinity }
        // Sehr unterschiedliche Längen → sicher kein Treffer
        if Double(max(n, m)) / Double(min(n, m)) > 2.6 { return .infinity }
        let band = max(abs(n - m) + 4, max(n, m) / 2)
        let inf = Float.infinity
        var prev = [Float](repeating: inf, count: m + 1), cur = [Float](repeating: inf, count: m + 1)
        var prevLen = [Int](repeating: 0, count: m + 1), curLen = [Int](repeating: 0, count: m + 1)
        prev[0] = 0
        for i in 1...n {
            for j in 0...m { cur[j] = inf; curLen[j] = 0 }
            let jc = Int(Double(i) * Double(m) / Double(n))
            let lo = max(1, jc - band), hi = min(m, jc + band)
            if lo > hi { swap(&prev, &cur); swap(&prevLen, &curLen); continue }
            for j in lo...hi {
                var d: Float = 0
                let ai = a[i - 1], bj = b[j - 1]
                for k in 0..<ai.count { let t = ai[k] - bj[k]; d += t * t }
                d = sqrt(d)
                var best = prev[j - 1], len = prevLen[j - 1]
                if prev[j] < best { best = prev[j]; len = prevLen[j] }
                if cur[j - 1] < best { best = cur[j - 1]; len = curLen[j - 1] }
                cur[j] = best + d
                curLen[j] = len + 1
            }
            swap(&prev, &cur); swap(&prevLen, &curLen)
        }
        return prev[m] / Float(max(1, prevLen[m]))
    }

    /// Teilfolgen-DTW: wo im (längeren) Fenster `query` passt die Vorlage am besten? Anfang und Ende im Fenster frei.
    /// Normiert auf die Pfadlänge. Gleicht ungenaue Wortgrenzen von Parakeet aus.
    static func subDTW(_ template: [[Float]], in query: [[Float]]) -> Float {
        let n = template.count, m = query.count
        guard n > 2, m > 2 else { return .infinity }
        if Double(m) < Double(n) * 0.45 { return .infinity }
        let inf = Float.infinity
        var prev = [Float](repeating: 0, count: m + 1), cur = [Float](repeating: inf, count: m + 1)
        var prevLen = [Int](repeating: 0, count: m + 1), curLen = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = inf; curLen[0] = 0
            let ti = template[i - 1]
            for j in 1...m {
                var d: Float = 0
                let qj = query[j - 1]
                for k in 0..<ti.count { let t = ti[k] - qj[k]; d += t * t }
                d = sqrt(d)
                // Schritte: diagonal, Vorlage weiter (Query steht), Query weiter (Vorlage steht) – mit Längen-Mitzählung
                var best = prev[j - 1], len = prevLen[j - 1]
                if prev[j] < best { best = prev[j]; len = prevLen[j] }
                if cur[j - 1] < best { best = cur[j - 1]; len = curLen[j - 1] }
                cur[j] = best + d
                curLen[j] = len + 1
            }
            swap(&prev, &cur); swap(&prevLen, &curLen)
        }
        var best = inf
        for j in 1...m {
            let l = prevLen[j]
            // Treffer muss mindestens ~60 % so lang sein wie die Vorlage (sonst passt nur ein Stückchen)
            guard l >= n else { continue }
            let v = prev[j] / Float(l)
            if v < best { best = v }
        }
        return best
    }

    /// Sprach-Inseln einer Aufnahme (getrennt durch ≥ 0,15 s Stille), in Sekunden
    static func islands(_ s: [Float], minGap: Double = 0.15, minLen: Double = 0.25) -> [(start: Double, end: Double)] {
        let r = SpeechMeter.frameRMS(s)
        guard let peak = r.max(), peak > 0.002 else { return [] }
        let thr = max(0.0015, peak * 0.1)
        var out: [(Double, Double)] = []
        var i = 0
        let fs = 480.0 / 16000
        while i < r.count {
            guard r[i] > thr else { i += 1; continue }
            var j = i, lastLoud = i
            while j < r.count {
                if r[j] > thr { lastLoud = j } else if Double(j - lastLoud) * fs >= minGap { break }
                j += 1
            }
            let a = Double(i) * fs, b = Double(lastLoud + 1) * fs
            if b - a >= minLen { out.append((a, b)) }
            i = j
        }
        return out.map { (start: $0.0, end: $0.1) }
    }

    /// Rahmen-Bereich (MFCC-Index) für ein Zeitfenster
    static func frames(_ f: [[Float]], start: Double, end: Double) -> [[Float]] {
        let a = max(0, Int(start * 100)), b = min(f.count, Int(end * 100))
        return a < b ? Array(f[a..<b]) : []
    }

    /// Kleinster Abstand zu einer Sammlung von Vorlagen
    static func bestDistance(_ q: [[Float]], templates: [[[Float]]]) -> Float {
        templates.map { dtw(q, $0) }.min() ?? .infinity
    }

    /// Ausschnitt [start, end] (Sekunden) mit etwas Rand
    static func slice(_ s: [Float], start: Double, end: Double, pad: Double = 0.06) -> [Float] {
        let a = max(0, Int((start - pad) * Double(sampleRate))), b = min(s.count, Int((end + pad) * Double(sampleRate)))
        return a < b ? Array(s[a..<b]) : []
    }
}
