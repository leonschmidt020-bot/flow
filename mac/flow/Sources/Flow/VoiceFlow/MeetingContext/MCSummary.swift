import Foundation

// MARK: - Zusammenfassung MIT Bildern
//
// Claude bekommt Transkript + erkannten Text + bis zu 20 Schlüsselbilder. Die CLI läuft dafür mit genau EINEM
// Werkzeug: `Read` – eingesperrt auf einen Arbeitsordner im Meeting-Ordner (`--restricted` + Arbeitsordner = dieser Ordner),
// `--strict-mcp-config` (keine MCP-Server), keine Einstellungen, keine Sitzung, kein Netz-Werkzeug, Nachfragen = abgelehnt.
// Geprüft: liest Bilder wirklich (Formen/Farben ohne Text werden beschrieben) und verweigert Dateien außerhalb.

enum ClaudeVision {
    /// Wie `ClaudeCLI.run`, aber Claude darf Dateien (Bilder) im Ordner `dir` lesen – und nur dort.
    static func run(system: String, input: String, dir: URL, model: String = "sonnet", timeout: TimeInterval = 420) async throws -> String {
        guard let bin = ClaudeCLI.binary else { throw ClaudeCLI.Failure(message: "Claude-CLI nicht gefunden") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["-p", "--model", model, "--system-prompt", system,
                               "--tools", "Read", "--allowedTools", "Read", "--restricted", "--add-dir", dir.path,
                               "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
                               "--permission-prompts", "none", "--output-format", "text"]
                let src = ProcessInfo.processInfo.environment
                var env: [String: String] = [:]
                for k in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] { if let v = src[k] { env[k] = v } }
                env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                p.environment = env
                p.currentDirectoryURL = dir
                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
                var outData = Data(), errData = Data()
                let g = DispatchGroup(); g.enter(); g.enter()
                DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                do { try p.run() } catch {
                    cont.resume(throwing: ClaudeCLI.Failure(message: "Claude-CLI startet nicht: \(error.localizedDescription)")); return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input.data(using: .utf8) ?? Data())
                    try? inPipe.fileHandleForWriting.close()
                }
                p.waitUntilExit(); killer.cancel(); g.wait()
                let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus != 0 || out.isEmpty {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: ClaudeCLI.Failure(message: "Claude-CLI Fehler (\(p.terminationStatus)): \(err.prefix(300))\(out.prefix(300))"))
                } else { cont.resume(returning: out) }
            }
        }
    }
}

enum MeetingVisualSummary {
    static let maxImages = 20

    /// Die aussagekräftigsten Bilder: gemerkte Momente zuerst, dann nach neuem Text (OCR) und Bildänderung,
    /// über die Zeit verteilt. Rückgabe zeitlich sortiert.
    static func pick(_ frames: [MCFrame], max n: Int = maxImages) -> [MCFrame] {
        guard frames.count > n else { return frames }
        func words(_ s: String?) -> Set<String> {
            Set((s ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        }
        var chosen = frames.filter(\.isMoment)
        if chosen.count > n { return Array(chosen.suffix(n)) }
        var seenWords = chosen.reduce(into: Set<String>()) { $0.formUnion(words($1.ocr)) }
        var rest = frames.filter { !$0.isMoment }
        let span = max(1, (frames.last?.t ?? 1) - (frames.first?.t ?? 0))
        while chosen.count < n, !rest.isEmpty {
            var bestI = 0, bestS = -Double.infinity
            for (i, f) in rest.enumerated() {
                let w = words(f.ocr)
                let novel = Double(w.subtracting(seenWords).count)
                let near = chosen.map { abs($0.t - f.t) }.min() ?? span
                let s = min(novel, 60) * 1.0 + f.change * 40 + min(near / span, 0.3) * 60
                if s > bestS { bestS = s; bestI = i }
            }
            let f = rest.remove(at: bestI)
            seenWords.formUnion(words(f.ocr))
            chosen.append(f)
        }
        return chosen.sorted { $0.t < $1.t }
    }

    static let systemAddition = """

    Du bekommst zusätzlich Schlüsselbilder vom Bildschirm des Meetings (Folien, geteilte Bildschirme, Code, Designs) \
    als Dateien im Arbeitsordner, mit Zeitstempel und erkanntem Text. Lies JEDES aufgeführte Bild mit dem Read-Werkzeug, \
    bevor du schreibst. Beziehe ein, was gezeigt wurde, und nenne es konkret im Text, z. B. „auf der Folie ‚Budget Q4‘ …“, \
    „im geteilten Code (Datei x.swift) …“, „im Design der Startseite …“. Zahlen aus Folien/Tabellen genau übernehmen.
    Füge nach **Kernpunkte** den Abschnitt **Gezeigt** hinzu: Stichpunkte „[mm:ss] was zu sehen war – wozu es gehörte“.
    Mit ★ markierte Momente hat der Nutzer als wichtig gemerkt – sie gehören auf jeden Fall hinein.
    Erwähne keine Dateinamen der Bilder und nichts über Werkzeuge.
    """

    /// nil = keine Bilder (dann normale Zusammenfassung ohne Werkzeuge)
    static func run(meeting m: Meeting, system: String) async throws -> String? {
        guard MCSettings.shared.summaryWithImages else { return nil }
        var mc = MCStore.shared.log(m.id)
        guard !mc.frames.isEmpty || !mc.moments.isEmpty else { return nil }
        if mc.frames.contains(where: { $0.ocr == nil }) {
            MCOCR.shared.backfill(meetingID: m.id)
            await MCOCR.shared.waitIdle(timeout: 90)
            mc = MCStore.shared.log(m.id)
        }
        let picked = pick(mc.frames)
        let dir = MCStore.folder(m.id).appendingPathComponent(".claude-eingabe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        var names: [String: String] = [:]
        for (i, f) in picked.enumerated() {
            let name = String(format: "bild_%02d_%@.jpg", i + 1, MCText.fileStamp(f.t))
            // 1568 px lange Seite = optimale Größe für Claude (größer wird ohnehin verkleinert)
            if let img = MCImageIO.load(MCStore.shared.url(m.id, f)),
               MCImageIO.writeJPEG(img, to: dir.appendingPathComponent(name), quality: 0.8, maxSide: 1568) { names[f.id] = name }
        }
        let input = prompt(m, log: mc, picked: picked, names: names)
        let t0 = Date()
        let out = try await ClaudeVision.run(system: system + systemAddition, input: input, dir: dir, model: "sonnet", timeout: 480)
        log(String(format: "Meeting-Kontext: Zusammenfassung mit %d Bildern in %.0f s", names.count, Date().timeIntervalSince(t0)))
        return out
    }

    static func prompt(_ m: Meeting, log: MCLog, picked: [MCFrame], names: [String: String]) -> String {
        var s = "Transkript:\n\(m.transcriptText())\n\n"
        if !log.moments.isEmpty {
            s += "★ Wichtig markierte Momente (jeweils die 30 s davor):\n"
            for mo in log.moments {
                let said = MCText.spoken(m, from: mo.t - 30, to: mo.t + 3)
                s += "- [\(Meeting.stamp(mo.t))] \((said.isEmpty ? mo.liveText : said).replacingOccurrences(of: "\n", with: " / "))\n"
            }
            s += "\n"
        }
        if !picked.isEmpty {
            s += "Schlüsselbilder im Arbeitsordner (bitte alle mit Read ansehen):\n"
            for f in picked {
                guard let n = names[f.id] else { continue }
                let ocr = (f.ocr ?? "").replacingOccurrences(of: "\n", with: " · ")
                s += "- \(n) · [\(Meeting.stamp(f.t))]\(f.isMoment ? " ★" : "")\(f.window.map { " · Fenster: \($0)" } ?? "")\n"
                if !ocr.isEmpty { s += "  erkannter Text: \(ocr.prefix(900))\n" }
            }
        }
        let others = log.frames.filter { names[$0.id] == nil && !($0.ocr ?? "").isEmpty }
        if !others.isEmpty {
            s += "\nWeitere Bilder (nur erkannter Text):\n"
            for f in others { s += "- [\(Meeting.stamp(f.t))] \((f.ocr ?? "").replacingOccurrences(of: "\n", with: " · ").prefix(400))\n" }
        }
        return s
    }

    // MARK: Fragen an das Meeting (Frage-Leiste) – mit Bildern

    static let askAddition = """

    Im Arbeitsordner liegen transkript.md (vollständiges Transkript mit Zeitstempeln), meeting.md (Zusammenfassung, Momente, Notizen), \
    bilder.md (Zeitleiste der Bilder mit erkanntem Text) und bilder/ (Schlüsselbilder vom Meeting-Bildschirm und eigene Screenshots \
    aus dem Meeting-Zeitraum). Wenn die Frage etwas \
    betrifft, das gezeigt wurde (Folie, Code, Design, Zahlen), sieh dir die passenden Bilder mit Read an und nenne sie mit Zeitstempel. \
    Erwähne keine Dateinamen oder Werkzeuge.
    """

    /// nil = keine Bilder → normale Frage ohne Werkzeuge (oder Fehler → ebenfalls ohne Bilder erneut)
    static func ask(meetingID: String, system: String, input: String) async -> String? {
        guard let m = await MainActor.run(body: { MeetingStore.shared.meeting(meetingID) }) else { return nil }
        let mc = MCStore.shared.log(m.id)
        guard !mc.frames.isEmpty || !MCOwnScreenshots.collect(for: m).isEmpty else { return nil }
        do {
            let r = try MeetingContextPackage.build(m)
            let t0 = Date()
            let out = try await ClaudeVision.run(system: system + askAddition, input: input, dir: r.dir, model: "sonnet", timeout: 240)
            log(String(format: "Meeting-Kontext: Frage mit %d+%d Bildern in %.0f s beantwortet", r.keyframes, r.ownShots, Date().timeIntervalSince(t0)))
            return out
        } catch {
            log("Meeting-Kontext: Frage mit Bildern fehlgeschlagen (\(error.localizedDescription)) – ohne Bilder")
            return nil
        }
    }
}
