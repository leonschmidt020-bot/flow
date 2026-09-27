import AppKit
import ImageIO
import Vision

// MARK: - Texterkennung der Schlüsselbilder (Vision, Deutsch + Englisch)
//
// Wie bei ClipVault in einem KURZLEBIGEN Kindprozess (`Flow --mc-ocr`, JSON über stdin/stdout):
// Vision lädt ~100–200 MB Modelle in den Prozess und gibt sie nicht zuverlässig frei. So bleibt die App schlank,
// und ein Absturz in Vision reißt das Meeting nicht mit. Mehrere Bilder pro Aufruf (Modelle nur einmal laden).

final class MCOCR {
    static let shared = MCOCR()
    private let q = DispatchQueue(label: "flow.meetingkontext.ocr", qos: .utility)
    private var pending: [String: Set<String>] = [:]   // meetingID → frameIDs (nur auf q)
    private var scheduled = false
    private var running = false
    private var waiters: [() -> Void] = []

    /// Bild einreihen. Während der Aufnahme gesammelt (alle ~20 s ein Kindprozess), `urgent` = sofort.
    func enqueue(meetingID: String, frameID: String, urgent: Bool = false) {
        q.async {
            self.pending[meetingID, default: []].insert(frameID)
            self.schedule(after: urgent ? 0.2 : 20)
        }
    }

    /// Alles Offene jetzt lesen (Meeting beendet)
    func flush() { q.async { self.schedule(after: 0) } }

    /// Bilder eines Meetings ohne Text nachtragen (z. B. nach Absturz)
    func backfill(meetingID: String) {
        let ids = MCStore.shared.log(meetingID).frames.filter { $0.ocr == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        q.async { self.pending[meetingID, default: []].formUnion(ids); self.schedule(after: 0.5) }
    }

    /// Wartet, bis nichts mehr offen ist (höchstens `timeout`)
    func waitIdle(timeout: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            let finish = { if !done { done = true; c.resume() } }
            q.async {
                if self.pending.isEmpty && !self.running { finish(); return }
                self.waiters.append { finish() }
                self.schedule(after: 0)
            }
            q.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    private var timerItem: DispatchWorkItem?
    private var dueAt = Date.distantFuture
    /// Lauf planen – ein früherer Termin gewinnt immer
    private func schedule(after s: Double) {
        let due = Date().addingTimeInterval(s)
        if scheduled, due >= dueAt { return }
        timerItem?.cancel()
        scheduled = true
        dueAt = due
        let w = DispatchWorkItem { [weak self] in self?.runBatch() }
        timerItem = w
        q.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func runBatch() {
        scheduled = false
        dueAt = .distantFuture
        guard !running else { schedule(after: 1); return }
        guard !pending.isEmpty else { let w = waiters; waiters = []; w.forEach { $0() }; return }
        let work = pending; pending = [:]
        running = true
        var jobs: [[String: Any]] = []
        var map: [String: (String, String)] = [:]   // Pfad → (meeting, frame)
        for (mid, ids) in work {
            let log = MCStore.shared.log(mid)
            for f in log.frames where ids.contains(f.id) {
                let path = MCStore.shared.url(mid, f).path
                var j: [String: Any] = ["path": path]
                if let r = f.roi { j["roi"] = r }
                jobs.append(j); map[path] = (mid, f.id)
            }
        }
        let t0 = Date()
        let results = MCOCR.runChild(jobs)
        for (path, text) in results {
            guard let (mid, fid) = map[path] else { continue }
            MCStore.shared.mutate(mid) { l in if let i = l.frames.firstIndex(where: { $0.id == fid }) { l.frames[i].ocr = text } }
        }
        // nicht lesbare Bilder: leer markieren, damit nicht endlos wiederholt wird
        for (path, (mid, fid)) in map where results[path] == nil {
            MCStore.shared.mutate(mid) { l in if let i = l.frames.firstIndex(where: { $0.id == fid }), l.frames[i].ocr == nil { l.frames[i].ocr = "" } }
        }
        log(String(format: "Meeting-Kontext: Texterkennung %d Bild(er) in %.1f s", jobs.count, Date().timeIntervalSince(t0)))
        running = false
        if pending.isEmpty { let w = waiters; waiters = []; w.forEach { $0() } } else { schedule(after: 0.5) }
    }

    /// Eigene Binary als Kindprozess: `--mc-ocr` liest JSON-Aufträge von stdin, schreibt {pfad: text} auf stdout.
    static func runChild(_ jobs: [[String: Any]]) -> [String: String] {
        guard !jobs.isEmpty, let input = try? JSONSerialization.data(withJSONObject: jobs) else { return [:] }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--mc-ocr"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("Meeting-Kontext: Texterkennung startet nicht: \(error)"); return [:] }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30 + Double(jobs.count) * 8, execute: killer)
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        guard p.terminationStatus == 0, let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return o
    }

    // MARK: im Kindprozess

    /// `--mc-ocr`: Aufträge von stdin
    static func childMain() -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 2 }
        var out: [String: String] = [:]
        for j in jobs {
            guard let path = j["path"] as? String else { continue }
            let roi = (j["roi"] as? [Double]).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            if let t = recognize(URL(fileURLWithPath: path), roi: roi) { out[path] = t }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: out) else { return 1 }
        FileHandle.standardOutput.write(d)
        return 0
    }

    /// Text lesen. `roi` (0…1, y von oben) = nur den geteilten Inhalt lesen (ohne Namensschilder der Video-Kacheln).
    static func recognize(_ url: URL, roi: CGRect?) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["de-DE", "en-US"]
        req.automaticallyDetectsLanguage = false
        if let r = roi {
            // Vision: Ursprung unten links
            req.regionOfInterest = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        // Zeilen in Lesereihenfolge (oben → unten, links → rechts)
        let obs = (req.results ?? []).sorted { a, b in
            let ay = a.boundingBox.midY, by = b.boundingBox.midY
            if abs(ay - by) > 0.012 { return ay > by }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
