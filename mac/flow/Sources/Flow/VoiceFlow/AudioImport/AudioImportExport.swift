import AppKit
import UniformTypeIdentifiers

// MARK: - Export: Markdown (Meeting.markdown), Text, SRT-Untertitel – für jede Notiz (Meeting oder Datei)

enum NoteExport {
    enum Kind: String, CaseIterable {
        case markdown, text, srt
        var ext: String { switch self { case .markdown: return "md"; case .text: return "txt"; case .srt: return "srt" } }
        var menuTitle: String {
            switch self {
            case .markdown: return "Als Markdown sichern …"
            case .text: return "Als Text sichern …"
            case .srt: return "Als Untertitel (SRT) sichern …"
            }
        }
    }

    static func content(_ m: Meeting, _ kind: Kind) -> String {
        switch kind {
        case .markdown:
            var md = m.markdown()
            let notes = HubNotesStore.load(m.id).trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { md += "\n## Meine Notizen\n\n\(notes)\n" }
            return md
        case .text: return text(m)
        case .srt: return srt(m)
        }
    }

    /// Klartext: Kopf, Zusammenfassung (ohne Markdown-Sternchen), Transkript mit Zeitmarken
    static func text(_ m: Meeting) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        var out = "\(m.title)\n\(df.string(from: m.date)) · \(Meeting.stamp(m.duration))" + (m.app.map { " · \($0)" } ?? "") + "\n\n"
        if let s = m.summary, !s.isEmpty {
            let plain = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            out += "ZUSAMMENFASSUNG\n\n\(plain)\n\n"
        }
        out += "TRANSKRIPT\n\n" + m.transcriptText(withTimes: true) + "\n"
        return out
    }

    /// SRT: je Abschnitt Untertitel von höchstens ~7 s / 84 Zeichen (lange Abschnitte werden anteilig aufgeteilt)
    static func srt(_ m: Meeting) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var cues: [(Double, Double, String)] = []
        let multi = Set(m.segments.map(\.speaker)).count > 1
        for s in m.segments {
            let words = s.text.split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }
            let dur = max(0.5, s.end - s.start)
            let totalChars = max(1, words.reduce(0) { $0 + $1.count + 1 })
            var groups: [[String]] = [[]]
            var chars = 0
            for w in words {
                let cueDur = Double(chars + w.count) / Double(totalChars) * dur
                if !groups[groups.count - 1].isEmpty, chars + w.count > (gi0(groups) ? 70 : 84) || cueDur > 7 {
                    groups.append([]); chars = 0
                }
                groups[groups.count - 1].append(w); chars += w.count + 1
            }
            var t = s.start
            for (gi, g) in groups.enumerated() {
                let c = g.reduce(0) { $0 + $1.count + 1 }
                let d = dur * Double(c) / Double(totalChars)
                var line = g.joined(separator: " ")
                if multi && gi == 0 { line = "\(m.name(for: s.speaker)): " + line }
                cues.append((t, min(s.end, t + d), wrap(line)))
                t += d
            }
        }
        return cues.enumerated().map { i, c in "\(i + 1)\n\(ts(c.0)) --> \(ts(max(c.1, c.0 + 0.3)))\n\(c.2)\n" }.joined(separator: "\n")
    }

    /// Erste Gruppe eines Abschnitts trägt den Sprechernamen → etwas kürzer
    private static func gi0(_ g: [[String]]) -> Bool { g.count == 1 }

    /// Höchstens zwei Zeilen à ~42 Zeichen
    private static func wrap(_ s: String) -> String {
        guard s.count > 44 else { return s }
        let words = s.split(separator: " ")
        var a = "", b = ""
        for w in words {
            if a.count + w.count + 1 <= max(42, s.count / 2) && b.isEmpty { a += (a.isEmpty ? "" : " ") + w } else { b += (b.isEmpty ? "" : " ") + w }
        }
        return b.isEmpty ? a : a + "\n" + b
    }

    /// Sichern-Dialog
    static func save(_ m: Meeting, _ kind: Kind) {
        let p = NSSavePanel()
        p.nameFieldStringValue = m.title.replacingOccurrences(of: "/", with: "-") + "." + kind.ext
        if let t = UTType(filenameExtension: kind.ext) { p.allowedContentTypes = [t] }
        if p.runModal() == .OK, let u = p.url { try? content(m, kind).write(to: u, atomically: true, encoding: .utf8) }
    }
}
