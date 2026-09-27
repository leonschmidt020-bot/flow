import AppKit
import Foundation

// MARK: - Paket für Agenten („Prompt für Agent“)
//
// <meeting>/Kontext-Paket/
//   transkript.md  das VOLLSTÄNDIGE Transkript (Zeitstempel, Sprecher) – eigene Datei, damit ein Agent es sicher ganz liest
//   meeting.md     Überblick: Titel, Datum, Teilnehmer, Zusammenfassung, markierte Momente, eigene Notizen, Dateiliste
//   bilder.md      Zeitleiste: Schlüsselbilder mit erkanntem Text + eigene Screenshots, je mit dem Gesprochenen drumherum
//   bilder/        Schlüsselbilder (harte Links, kein doppelter Speicher) + eigene Screenshots (Kopien)
// 27.09.2026: Früher stand das Transkript ganz hinten in meeting.md hinter der langen Bilder-Zeitleiste – ein Agent las
// die Datei nur zum Teil und meinte, das Transkript fehle.
// Liegt im Meeting-Ordner → verschwindet mit dem Meeting (3 Tage, außer „Behalten“). Wird bei jedem Klick neu gebaut,
// damit die Pfade im Prompt immer stimmen.

enum MeetingContextPackage {
    static func folder(_ m: Meeting) -> URL { m.folder.appendingPathComponent("Kontext-Paket", isDirectory: true) }

    struct Result {
        let dir: URL; let keyframes: Int; let ownShots: Int; let moments: Int
        var segments = 0, words = 0, transcriptLines = 0
        var hasTimeline = false
        /// Originalaufnahme im Meeting-Ordner (Import oder „Audio behalten“)
        var audio: URL?
    }

    /// Eintrag der Zeitleiste
    private struct Entry {
        let t: Double
        let file: String?
        let title: String
        let ocr: String
        let window: (Double, Double)
    }

    /// Paket bauen (Hintergrund-tauglich). Liest eigene Screenshots nur, kopiert sie ins Paket.
    @discardableResult
    static func build(_ m: Meeting) throws -> Result {
        let fm = FileManager.default
        let dir = folder(m)
        try? fm.removeItem(at: dir)
        let bilder = dir.appendingPathComponent("bilder", isDirectory: true)
        try fm.createDirectory(at: bilder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mc = MCStore.shared.log(m.id)
        let end = m.duration > 0 ? m.duration : (mc.frames.last?.tLast ?? 0) + 60
        var entries: [Entry] = []

        for (i, f) in mc.frames.enumerated() {
            let src = MCStore.shared.url(m.id, f)
            guard fm.fileExists(atPath: src.path) else { continue }
            let name = String(format: "B%02d_%@%@.jpg", i + 1, MCText.fileStamp(f.t), f.isMoment ? "_moment" : "")
            let dst = bilder.appendingPathComponent(name)
            if (try? fm.linkItem(at: src, to: dst)) == nil { try? fm.copyItem(at: src, to: dst) }
            let (a, b) = MCText.visibleRange(mc.frames, i, meetingEnd: end)
            entries.append(Entry(t: f.t, file: "bilder/\(name)",
                                 title: "Bildschirm \(Meeting.stamp(f.t))\(f.isMoment ? " ★ Moment" : "")\(f.window.map { " · \($0)" } ?? "")",
                                 ocr: (f.ocr ?? "").trimmingCharacters(in: .whitespacesAndNewlines), window: (a, b)))
        }

        // eigene Screenshots im Zeitraum (−2 Min. … +10 Min.) – nicht bei importierten Dateien: deren „Datum“ ist der
        // Import-Zeitpunkt, die Screenshots von dann haben mit der Aufnahme nichts zu tun
        var shots = m.app == "Datei" ? [] : MCOwnScreenshots.collect(for: m)
        ocrOwnShots(&shots, cacheIn: m.folder)
        for (i, s) in shots.enumerated() {
            let t = s.date.timeIntervalSince(m.date)
            let ext = s.url.pathExtension.lowercased().isEmpty ? "png" : s.url.pathExtension.lowercased()
            let name = String(format: "S%02d_%@_%@.%@", i + 1, stamp(t).replacingOccurrences(of: ":", with: "-"),
                              s.source == .screenshot ? "screenshot" : "clipvault", ext)
            try? fm.copyItem(at: s.url, to: bilder.appendingPathComponent(name))
            entries.append(Entry(t: t, file: "bilder/\(name)", title: "\(s.source.rawValue) \(stamp(t))",
                                 ocr: (s.ocr ?? "").trimmingCharacters(in: .whitespacesAndNewlines), window: (t - 30, t + 30)))
        }

        func write(_ text: String, _ name: String) throws {
            let u = dir.appendingPathComponent(name)
            try text.write(to: u, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        }
        let sorted = entries.sorted { $0.t < $1.t }
        let tr = transcript(m, mc: mc)
        var r = Result(dir: dir, keyframes: mc.frames.count, ownShots: shots.count, moments: mc.moments.count)
        r.segments = m.segments.count
        r.words = m.segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        r.transcriptLines = tr.components(separatedBy: "\n").count
        r.hasTimeline = !sorted.isEmpty
        r.audio = audioFile(m)
        try write(tr, "transkript.md")
        if r.hasTimeline { try write(timeline(m, entries: sorted), "bilder.md") }
        let md = markdown(m, mc: mc, r)
        try write(md, "meeting.md")
        log("Meeting-Kontext: Paket gebaut (\(r.segments) Abschnitte/\(r.words) Wörter Transkript, \(mc.frames.count) Schlüsselbilder, \(shots.count) eigene Screenshots)")
        return r
    }

    /// Originalaufnahme im Meeting-Ordner (importierte Datei oder behaltener Ton)
    private static func audioFile(_ m: Meeting) -> URL? {
        let exts: Set<String> = ["qta", "m4a", "mp3", "wav", "aac", "caf", "aiff", "flac", "ogg", "opus", "mp4", "mov"]
        let files = (try? FileManager.default.contentsOfDirectory(at: m.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Zeit relativ zum Meeting-Beginn, vorher mit „−“
    static func stamp(_ t: Double) -> String { t < 0 ? "−" + Meeting.stamp(-t) : Meeting.stamp(t) }

    /// Texterkennung für eigene Screenshots (einmal je Datei, Ergebnis im Meeting-Ordner zwischengespeichert)
    private static func ocrOwnShots(_ shots: inout [MCOwnShot], cacheIn folder: URL) {
        let cacheURL = folder.appendingPathComponent("screenshots-text.json")
        var cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheURL))) ?? [:]
        func key(_ s: MCOwnShot) -> String { "\(s.url.path)|\(Int(s.date.timeIntervalSince1970))" }
        let todo = shots.filter { $0.ocr == nil && cache[key($0)] == nil }
        if !todo.isEmpty {
            let res = MCOCR.runChild(todo.map { ["path": $0.url.path] })
            for s in todo { cache[key(s)] = res[s.url.path] ?? "" }
            if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
        }
        for i in shots.indices where shots[i].ocr == nil { shots[i].ocr = cache[key(shots[i])] }
    }

    private static func markdown(_ m: Meeting, mc: MCLog, _ r: Result) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        var s = "# \(m.title)\n\n"
        s += "> Meeting-Paket aus Flow (lokal). Zeiten [mm:ss] zählen ab Meeting-Beginn.\n\n"
        s += "- **Datum:** \(df.string(from: m.date))\n"
        s += "- **Dauer:** \(HubNoteDetail.duration(m.duration))\n"
        if let a = m.app, !a.isEmpty { s += "- **App:** \(a == "Datei" ? "importierte Audiodatei" : a)\n" }
        let people = m.speakerKeys.map { m.name(for: $0) }
        if !people.isEmpty { s += "- **Teilnehmer:** \(people.joined(separator: ", "))\n" }
        if !mc.windows.isEmpty { s += "- **Mitgeschnittene Fenster:** \(mc.windows.joined(separator: " · "))\n" }
        s += "- **Bilder:** \(r.keyframes) Schlüsselbilder, \(r.ownShots) eigene Screenshots"
        s += mc.moments.isEmpty ? "\n\n" : " · **Markierte Momente:** \(mc.moments.count)\n\n"

        s += "## Dateien in diesem Paket\n\n"
        s += "- `transkript.md` – **das vollständige Transkript**: \(r.segments) Abschnitte, ca. \(r.words) Wörter, \(r.transcriptLines) Zeilen\n"
        if r.hasTimeline { s += "- `bilder.md` – Zeitleiste der Bilder mit erkanntem Text und dem Gesprochenen dazu; Bilder in `bilder/` (B… = Meeting-Bildschirm, S… = eigene Screenshots)\n" }
        if let a = r.audio { s += "- Originalaufnahme: `\(a.path)`\n" }
        s += "\n"

        if let sum = m.summary, !sum.isEmpty { s += "## Zusammenfassung\n\n\(sum)\n\n" }

        if !mc.moments.isEmpty {
            s += "## ★ Markierte Momente\n\n"
            for mo in mc.moments.sorted(by: { $0.t < $1.t }) {
                let said = MCText.spoken(m, from: mo.t - 30, to: mo.t + 3, maxChars: 2000)
                s += "### ★ \(Meeting.stamp(mo.t))\n\n"
                if let fid = mo.frame, let i = mc.frames.firstIndex(where: { $0.id == fid }) {
                    let f = mc.frames[i]
                    s += "![Moment](bilder/\(String(format: "B%02d_%@_moment.jpg", i + 1, MCText.fileStamp(f.t))))\n\n"
                }
                let text = said.isEmpty ? mo.liveText : said
                if !text.isEmpty { s += text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n" }
            }
        }

        let notes = HubNotesStore.load(m.id).trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { s += "## Meine Notizen\n\n\(notes)\n\n" }
        s += "---\n\nDas vollständige Transkript steht in `transkript.md`.\n"
        return s
    }

    private static func timeline(_ m: Meeting, entries: [Entry]) -> String {
        var s = "# \(m.title) – Zeitleiste der Bilder\n\n"
        s += "> B… = Schlüsselbilder vom Meeting-Fenster (Folien, geteilte Bildschirme, Code), S… = eigene Screenshots aus dem Meeting-Zeitraum. Bilder in `bilder/`.\n\n"
        for e in entries {
            s += "## \(e.title)\n\n"
            if let f = e.file { s += "![\(e.title)](\(f))\n\n" }
            if !e.ocr.isEmpty { s += "**Erkannter Text:**\n\n```text\n\(e.ocr)\n```\n\n" }
            let said = MCText.spoken(m, from: e.window.0, to: e.window.1, maxChars: 1200)
            if !said.isEmpty {
                s += "**Gesprochen dazu (\(stamp(e.window.0))–\(stamp(e.window.1))):**\n\n"
                s += said.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        return s
    }

    private static func transcript(_ m: Meeting, mc: MCLog) -> String {
        let people = m.speakerKeys.map { m.name(for: $0) }
        var s = "# \(m.title) – vollständiges Transkript\n\n"
        s += "> \(m.segments.count) Abschnitte · Zeiten [mm:ss] ab Meeting-Beginn"
        s += people.isEmpty ? "" : " · Sprecher: \(people.joined(separator: ", "))"
        s += mc.moments.isEmpty ? "\n\n" : " · ★ = markierter Moment\n\n"
        let marks = mc.moments.map(\.t)
        for seg in m.segments {
            let star = marks.contains { seg.end >= $0 - 30 && seg.start <= $0 } ? " ★" : ""
            s += "[\(Meeting.stamp(seg.start))]\(star) **\(m.name(for: seg.speaker)):** \(seg.text)\n\n"
        }
        if m.segments.isEmpty { s += "_(kein Transkript vorhanden)_\n" }
        s += "\n— Ende des Transkripts —\n"
        return s
    }

    // MARK: Prompt für Agenten

    static func agentPrompt(_ m: Meeting, _ r: Result) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateFormat = "EEEE, d. MMMM yyyy, 'um' HH:mm"
        var info = ["\(df.string(from: m.date))"]
        if m.duration > 0 { info.append(HubNoteDetail.duration(m.duration)) }
        if let a = m.app, !a.isEmpty { info.append(a == "Datei" ? "importierte Audiodatei" : a) }
        let people = m.speakerKeys.map { m.name(for: $0) }
        var p = "Meeting „\(m.title)“ – \(info.joined(separator: ", "))"
        p += people.isEmpty ? ".\n\n" : ". Teilnehmer: \(people.joined(separator: ", ")).\n\n"
        p += "Alle Unterlagen liegen lokal auf diesem Mac im Ordner:\n\(r.dir.path)/\n\n"
        p += "- transkript.md – das VOLLSTÄNDIGE Transkript mit Zeitstempeln und Sprechern (\(r.segments) Abschnitte, ca. \(r.words) Wörter, \(r.transcriptLines) Zeilen, endet mit „— Ende des Transkripts —“)\n"
        p += "- meeting.md – Überblick: Datum, Teilnehmer, Zusammenfassung, markierte Momente, eigene Notizen\n"
        if r.hasTimeline {
            p += "- bilder.md + bilder/ – \(r.keyframes) Schlüsselbilder vom Meeting-Bildschirm und \(r.ownShots) eigene Screenshots, mit erkanntem Text und dem Gesprochenen dazu\n"
        }
        if let a = r.audio { p += "- Originalaufnahme: \(a.path)\n" }
        p += "\nLies zuerst transkript.md KOMPLETT – bei einer langen Datei in mehreren Teilen, bis „— Ende des Transkripts —“ – "
        p += r.hasTimeline ? "dann meeting.md und bilder.md mit den Bildern. " : "dann meeting.md. "
        p += "Bestätige kurz, dass du alles gelesen hast, und warte dann auf meine Aufgabe."
        return p
    }

    /// Klick auf „Prompt für Agent“: Paket neu bauen, Prompt in die Zwischenablage, Pillen-Hinweis. `done(ok)` auf dem Main-Thread.
    static func copyAgentPrompt(_ m: Meeting, done: @escaping (Bool) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = try? build(m)
            DispatchQueue.main.async {
                guard let r else {
                    MeetingContext.shared.toast?("Paket fehlgeschlagen")
                    done(false); return
                }
                Inserter.copy(agentPrompt(m, r), source: "Meeting")
                MeetingContext.shared.toast?("Prompt kopiert ✓")
                done(true)
            }
        }
    }
}
