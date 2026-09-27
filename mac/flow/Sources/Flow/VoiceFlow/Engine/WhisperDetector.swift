import Accelerate
import Foundation

/// Erkennt geflüsterte Sprache – billig (≈ 1–3 ms pro Sekunde Ton, nur vDSP), ohne Modell.
///
/// Flüstern = Sprache ohne Stimmbänder: kaum Periodizität (keine Grundfrequenz), flacheres Spektrum mit
/// relativ mehr Höhen, wenig Energie unter ~300 Hz, niedriger Pegel – aber mit der Silben-Modulation von Sprache
/// (Lüfter/Rauschen sind gleichmäßig und zählen nicht).
///
/// Kalibriert am 26.09.2026 (`--voice-lab detect`): echte Diktate (auch leise, 1 m weg) haben 56–91 %
/// stimmhafte Sprach-Rahmen, geflüsterte Aufnahmen 2–19 % (LPC-geflüsterte Aufnahmen, `say -v Whisper`,
/// geflüsterte TTS-Stimmen, höchstens 36 %). Normale TTS-Stimmen ab 54 %. Grenze 40 %.
enum WhisperDetector {
    struct Analysis: Sendable, Equatable {
        /// Sekunden mit Sprache (auch leise)
        var speechSeconds: Double
        /// Anteil stimmhafter Rahmen unter den Sprach-Rahmen (0…1)
        var voicedRatio: Float
        /// Anteil der Energie über 2 kHz an 0,3–6 kHz (Sprach-Rahmen, Median)
        var highRatio: Float
        /// Spektrale Flachheit 0,3–4 kHz (Median)
        var flatness: Float
        /// Sprach-Pegel (Median, dBFS)
        var speechDB: Float
        /// Schwankung des Pegels über die Sprach-Rahmen (dB) – Sprache moduliert, Lüfter nicht
        var modulationDB: Float
        /// Geflüstert?
        var isWhisper: Bool
        /// 0 = klar gesprochen … 1 = klar geflüstert
        var score: Float

        static let silent = Analysis(speechSeconds: 0, voicedRatio: 0, highRatio: 0, flatness: 0, speechDB: -120,
                                     modulationDB: 0, isWhisper: false, score: 0)
    }

    struct Rules: Sendable {
        /// Höchstens so viel stimmhafte Sprache → Flüstern
        var maxVoiced: Float = 0.40
        /// Mindestens so viel Sprache
        var minSpeech: Double = 0.35
        /// Sprache muss schwanken (Silben), sonst ist es Rauschen
        var minModulationDB: Float = 3.0
        /// Stimmhaft ab dieser normierten Autokorrelation (60–400 Hz)
        var voicedNCCF: Float = 0.6
    }

    nonisolated(unsafe) static var rules = Rules()

    static let frame = 512, hop = 256

    /// Ganze Aufnahme (oder ein Fenster) auswerten.
    static func analyze(_ s: [Float], rules: Rules = WhisperDetector.rules) -> Analysis {
        guard s.count >= frame * 4 else { return .silent }
        let n = (s.count - frame) / hop + 1
        var rms = [Float](repeating: 0, count: n)
        s.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var v: Float = 0
                vDSP_rmsqv(p.baseAddress! + i * hop, 1, &v, vDSP_Length(frame))
                rms[i] = v
            }
        }
        let sorted = rms.sorted()
        let floor = sorted[n / 10]
        let peak = sorted[n - 1]
        let gate = max(0.0006, floor * 2.5, peak * 0.02)
        let speechIdx = (0..<n).filter { rms[$0] > gate }
        let speechSec = Double(speechIdx.count * hop) / 16000
        guard speechSec >= rules.minSpeech else {
            var a = Analysis.silent; a.speechSeconds = speechSec; return a
        }
        // Modulation: Streuung des Pegels (dB) über die Sprach-Rahmen
        let dbs = speechIdx.map { 20 * log10(max(rms[$0], 1e-7)) }
        let meanDB = dbs.reduce(0, +) / Float(dbs.count)
        let modDB = sqrt(dbs.reduce(0) { $0 + ($1 - meanDB) * ($1 - meanDB) } / Float(dbs.count))
        let medDB = dbs.sorted()[dbs.count / 2]

        // Höchstens ~240 Sprach-Rahmen gleichmäßig auswerten (lange Diktate bleiben billig)
        let step = max(1, speechIdx.count / 240)
        let pick = stride(from: 0, to: speechIdx.count, by: step).map { speechIdx[$0] }
        var voiced = 0
        var highs: [Float] = [], flats: [Float] = []
        let fft = FFTHelper.shared
        s.withUnsafeBufferPointer { p in
            var buf = [Float](repeating: 0, count: frame)
            for i in pick {
                let base = p.baseAddress! + i * hop
                // Mittelwert weg
                var mean: Float = 0
                vDSP_meanv(base, 1, &mean, vDSP_Length(frame))
                var neg = -mean
                vDSP_vsadd(base, 1, &neg, &buf, 1, vDSP_Length(frame))
                if nccfMax(buf) > rules.voicedNCCF { voiced += 1 }
                let (hr, fl) = fft.bands(buf)
                highs.append(hr); flats.append(fl)
            }
        }
        let vr = Float(voiced) / Float(max(1, pick.count))
        let hr = highs.sorted()[highs.count / 2]
        let fl = flats.sorted()[flats.count / 2]
        let modOK = modDB >= rules.minModulationDB
        let isW = vr <= rules.maxVoiced && modOK
        // Weicher Wert für Anzeige/Protokoll: 1 bei 0 % stimmhaft, 0 ab 2× Grenze
        let score = modOK ? max(0, min(1, 1 - vr / (2 * rules.maxVoiced))) : 0
        return Analysis(speechSeconds: speechSec, voicedRatio: vr, highRatio: hr, flatness: fl, speechDB: medDB,
                        modulationDB: modDB, isWhisper: isW, score: score)
    }

    /// Kurzform für Fenster im Stimmabgleich
    static func isWhisper(_ s: [Float]) -> Bool { analyze(s).isWhisper }

    /// Enthält das Stück geflüsterte Sprache? (Für die VAD: leise Flüster-Stücke nicht als „Stille“ verwerfen.)
    static func hasWhisperSpeech(_ s: [Float]) -> Bool {
        let a = analyze(s)
        return a.isWhisper && a.speechSeconds >= 0.4
    }

    /// Höchste normierte Autokorrelation für Verzögerungen 40…266 Samples (60–400 Hz).
    static func nccfMax(_ f: [Float]) -> Float {
        let n = f.count
        var best: Float = 0
        f.withUnsafeBufferPointer { p in
            let b = p.baseAddress!
            // Energie-Präfixsummen für die Normierung
            var sq = [Float](repeating: 0, count: n + 1)
            for i in 0..<n { sq[i + 1] = sq[i] + b[i] * b[i] }
            for lag in stride(from: 40, through: 266, by: 1) {
                let m = n - lag
                var d: Float = 0
                vDSP_dotpr(b, 1, b + lag, 1, &d, vDSP_Length(m))
                let e1 = sq[m] - sq[0], e2 = sq[n] - sq[lag]
                let c = d / max(sqrt(e1 * e2), 1e-12)
                if c > best { best = c }
            }
        }
        return best
    }
}

/// Kleine FFT-Hilfe (512 Punkte, Hann-Fenster) für die Band-Merkmale.
final class FFTHelper: @unchecked Sendable {
    static let shared = FFTHelper()
    private let n = 512
    private let setup: FFTSetup
    private let window: [Float]
    private let lock = NSLock()

    init() {
        setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: 512)
        vDSP_hann_window(&w, 512, Int32(vDSP_HANN_NORM))
        window = w
    }

    /// (Anteil 2–6 kHz an 0,3–6 kHz, Flachheit 0,3–4 kHz)
    func bands(_ x: [Float]) -> (Float, Float) {
        lock.lock(); defer { lock.unlock() }
        var xw = [Float](repeating: 0, count: n)
        vDSP_vmul(x, 1, window, 1, &xw, 1, vDSP_Length(n))
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                xw.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &sc, 1, 9, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&sc, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        // Bin-Breite 31,25 Hz
        func sum(_ a: Int, _ b: Int) -> Float { var s: Float = 0; for k in a..<b { s += power[k] }; return s }
        let mid = sum(10, 64), high = sum(64, 192)
        let hr = high / max(mid + high, 1e-12)
        var logSum: Float = 0, lin: Float = 0
        for k in 10..<128 { logSum += log(power[k] + 1e-12); lin += power[k] }
        let cnt = Float(118)
        let flat = exp(logSum / cnt) / max(lin / cnt, 1e-12)
        return (hr, flat)
    }
}
