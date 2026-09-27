import Foundation

/// Hält Ton vom Mac (Musik, YouTube, Meeting-Teilnehmer) aus dem Diktat heraus.
/// Stufe 1 macht Apples Sprachverarbeitung im Mikro (Echo-Unterdrückung).
/// Stufe 2 (hier): Rest-Echo stummschalten, wo der Mac gerade Ton spielt und das Mikro nur leise ist.
/// Stufe 3 (hier): Wortfolgen, die auch im Mac-Ton vorkamen, aus dem Text entfernen.
enum EchoFilter {
    static let frame = 480  // 30 ms bei 16 kHz

    private static func rms(_ s: [Float], _ i: Int) -> Float {
        let a = i * frame, b = min(a + frame, s.count)
        guard b > a else { return 0 }
        var sum: Float = 0
        for j in a..<b { sum += s[j] * s[j] }
        return sqrt(sum / Float(b - a))
    }

    /// Schaltet Mikro-Stellen stumm, die nur Hintergrund/Rest-Echo sind.
    /// Liefert die bereinigten Samples und wie viele Sekunden echte Sprache übrig bleiben.
    static func gate(mic: [Float], system: [Float]) -> (samples: [Float], speechSeconds: Double) {
        let n = mic.count / frame
        guard n > 0 else { return (mic, 0) }
        var keep = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let m = rms(mic, i)
            let s = i * frame < system.count ? rms(system, i) : 0
            // Spielt der Mac gerade etwas, muss das Mikro deutlich lauter sein als der Rest-Hall.
            let threshold: Float = s > 0.003 ? max(0.0065, s * 0.4) : 0.0025
            keep[i] = m > threshold
        }
        // Weiche Ränder: 150 ms vor und 240 ms nach jeder Sprachstelle mitnehmen (Silbenanfänge/-enden).
        var dil = keep
        for i in 0..<n where keep[i] {
            for j in max(0, i - 5)...min(n - 1, i + 8) { dil[j] = true }
        }
        var out = mic
        var kept = 0
        for i in 0..<n {
            if dil[i] { kept += 1; continue }
            for j in (i * frame)..<min((i + 1) * frame, out.count) { out[j] = 0 }
        }
        let speech = Double(keep.filter { $0 }.count * frame) / 16000
        return (out, speech)
    }

    static func hasSound(_ s: [Float]) -> Bool {
        let n = s.count / frame
        var active = 0
        for i in 0..<n where rms(s, i) > 0.003 { active += 1 }
        return Double(active * frame) / 16000 > 0.4
    }

    private static func words(_ t: String) -> [String] {
        t.lowercased().components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { !$0.isEmpty }
    }

    /// Entfernt aus dem Diktat alle Folgen von ≥3 Wörtern, die auch im Mac-Ton vorkamen.
    /// Besteht das Diktat fast nur aus Mac-Ton-Wörtern, bleibt nichts übrig.
    static func subtract(dictation: String, systemText: String) -> String {
        let sys = words(systemText)
        guard sys.count >= 3 else { return dictation }
        var tri = Set<String>()
        for i in 0..<(sys.count - 2) { tri.insert(sys[i...(i + 2)].joined(separator: " ")) }
        let sysSet = Set(sys)

        // Original-Tokens behalten (mit Satzzeichen), parallel normalisierte Form
        let tokens = dictation.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let norm = tokens.map { words($0).joined() }
        guard !tokens.isEmpty else { return dictation }
        var drop = [Bool](repeating: false, count: tokens.count)
        if tokens.count >= 3 {
            for i in 0..<(tokens.count - 2) where tri.contains("\(norm[i]) \(norm[i + 1]) \(norm[i + 2])") {
                drop[i] = true; drop[i + 1] = true; drop[i + 2] = true
            }
        }
        let overlap = Double(norm.filter { sysSet.contains($0) }.count) / Double(norm.count)
        // Ganzes Diktat verwerfen nur bei längeren Stücken (kurze wie „Danke dir“ teilen zufällig Wörter mit Liedern)
        if norm.count >= 4 && overlap >= 0.8 { return "" }
        let kept = zip(tokens, drop).filter { !$0.1 }.map(\.0)
        return kept.joined(separator: " ")
    }
}
