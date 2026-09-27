import Foundation
import NaturalLanguage

/// Flow unterstützt nur Deutsch und Englisch. Parakeet kennt 25 Sprachen und rät bei kurzen/undeutlichen
/// Aufnahmen gern Französisch & Co. („Allô, allô“ statt „Hallo, hallo“).
/// Erkennt so etwas und lässt die Aufnahme dann von Whisper neu erkennen – nur mit Deutsch oder Englisch.
enum LanguageGuard {
    /// Buchstaben, die im Deutschen und Englischen praktisch nie vorkommen.
    private static let foreignChars = Set("àâçéèêëîïôûùÿœæñíóúãõåøłșțčšžýáìòăąęėīūőű¿¡")

    static func looksForeign(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.lowercased().contains(where: { foreignChars.contains($0) }) { return true }
        let words = t.split(whereSeparator: { !$0.isLetter }).count
        guard words >= 3 else { return false }
        let r = NLLanguageRecognizer()
        r.processString(t)
        let h = r.languageHypotheses(withMaximum: 5)
        let deEn = (h[.german] ?? 0) + (h[.english] ?? 0)
        let top = h.max { $0.value < $1.value }
        if let top, top.key != .german, top.key != .english, top.value > 0.6, deEn < 0.25 { return true }
        return false
    }

    /// Deutsch oder Englisch – was passt besser zum Text?
    static func guessDeEn(_ text: String) -> String {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english]
        r.processString(text)
        let h = r.languageHypotheses(withMaximum: 2)
        return (h[.english] ?? 0) > (h[.german] ?? 0) + 0.2 ? "en" : "de"
    }
}

/// whisper.cpp (large-v3-turbo) als Rückfallebene. Liegt schon auf dem Mac (Homebrew + Modell im Cache).
enum WhisperFallback {
    static let cli: String? = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static let model: String? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper-cpp/models").path
        return ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin", "ggml-small.bin"]
            .map { "\(dir)/\($0)" }.first { FileManager.default.fileExists(atPath: $0) }
    }()
    static var isAvailable: Bool { cli != nil && model != nil }

    /// Erkennt die Aufnahme neu – ausschließlich Deutsch oder Englisch.
    static func transcribe(_ samples: [Float], hint: String, forced: String? = nil) -> String? {
        guard let cli, let model else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flow-fallback-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let w = try? WavWriter(url: url) else { return nil }
        w.write(samples); w.close()
        func run(_ args: [String]) -> (out: String, err: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            // -np nur beim Erkennen: sonst fehlt die Zeile „auto-detected language“
            p.arguments = ["-m", model, "-nt", "-f", url.path] + (args.contains("-dl") ? [] : ["-np"]) + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            do { try p.run() } catch { return ("", "") }
            var errData = Data()
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); g.wait()
            return (String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? "")
        }

        // 1) Sprache erkennen lassen (nur Encoder, ~0,5 s). Englisch nur, wenn Whisper sich sicher ist.
        let det = run(["-l", "auto", "-dl"]).err
        var detected = "", prob = 0.0
        if let r = det.range(of: "auto-detected language: ") {
            let rest = det[r.upperBound...]
            detected = String(rest.prefix(2))
            if let pr = rest.range(of: "p = ") { prob = Double(rest[pr.upperBound...].prefix(8).filter { "0123456789.".contains($0) }) ?? 0 }
        }
        var lang = "de"
        if let forced { lang = forced }
        else if detected == "en" && prob >= 0.5 { lang = "en" }
        else if detected != "de" && detected != "en" && LanguageGuard.guessDeEn(hint) == "en" { lang = "en" }
        log(String(format: "Whisper-Sprache: %@ (p=%.2f) → %@", detected, prob, lang))
        // 2) Mit fester Sprache erkennen
        let text = run(["-l", lang]).out
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Typische Whisper-Halluzinationen bei Stille verwerfen
        let junk = ["untertitel", "vielen dank fürs zuschauen", "thanks for watching", "amara.org", "copyright"]
        if junk.contains(where: { text.lowercased().contains($0) }) { return nil }
        return text.isEmpty ? nil : text
    }
}
