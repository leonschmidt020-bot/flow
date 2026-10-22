import AppKit

// MARK: - Diktat-Sicherung
//
// 16.10.2026 (Wunsch: „wenn das abgebrochen wird, ist das, was ich geredet habe, weg … ich brauche eine Sicherung …
// und wenn es nicht transkribiert wurde, dass ich es wieder transkribieren kann“).
// Jedes Diktat wird schon WÄHREND des Sprechens alle 2 s auf die Platte geschrieben – so übersteht es auch einen Absturz.
// Abgebrochen, Zeitlimit oder Absturz → Flow erkennt das Gesagte im Hintergrund nach und legt es in die Zwischenablage.
// Ordner: ~/.config/flow/Diktat-Sicherungen · die neuesten 30 bleiben, höchstens 300 MB, Frist wie „Transkripte löschen nach“.
//
// 18.10.2026 (Audit Schreiblast): vorher wurde jedes Diktat dreimal geschrieben – rohe Float-Samples (`.laeuft.f32`,
// 64 KB/s), am Ende dasselbe noch einmal als WAV (32 KB/s) und eine dritte Kopie nach diktate/ (32 KB/s) ≈ 128 KB je
// gesprochener Sekunde. Jetzt EIN Schreibweg: die Sicherung ist von Anfang an eine 16-bit-WAV (`.laeuft.wav`, Kopf mit
// Platzhalter-Größen). Am Ende kommen nur der Rest (≤ 2 s) und die echten Größen in den Kopf, dann wird umbenannt.
// Nach einem Absturz trägt der Start die Größen nach – die Samples bleiben, wo sie sind. diktate/ und letzte-aufnahme.wav
// sind harte Links auf diese Datei (Dictation.saveDebug). ≈ 32 KB je gesprochener Sekunde.

enum DictationBackupStatus: String, Codable {
    case fertig, abgebrochen, zeitlimit, absturz, leer

    var label: String {
        switch self {
        case .fertig: return "fertig"
        case .abgebrochen: return "abgebrochen"
        case .zeitlimit: return "Zeitlimit"
        case .absturz: return "nicht fertig geworden"
        case .leer: return "nichts erkannt"
        }
    }
}

struct DictationBackupEntry: Codable, Equatable {
    var id: String
    var date: Date
    var duration: Double
    var status: DictationBackupStatus
    var text: String?

    var hasText: Bool { !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// „16.10. 14:03 · 2:15 · abgebrochen“
    var menuTitle: String {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE")
        df.dateFormat = Calendar.current.isDateInToday(date) ? "'Heute' HH:mm" : "dd.MM. HH:mm"
        let s = max(1, Int(duration.rounded()))
        return "\(df.string(from: date)) · \(s / 60):\(String(format: "%02d", s % 60)) · \(status.label)\(hasText ? " ✓" : "")"
    }
}

final class DictationBackup {
    static let shared = DictationBackup()

    /// Für Tests umlenkbar
    var dir: URL = Paths.base.appendingPathComponent("Diktat-Sicherungen", isDirectory: true)
    static let keep = 30
    /// Nur noch, wenn „Transkripte löschen nach“ auf „Nie“ steht (vorher immer 14 Tage – auch bei 3 Tagen Frist)
    static let maxDays = 14.0
    static let rate = 16000
    static let headerSize = 44
    /// 18.10.2026: 30 × 20-min-Diktat (je ~38 MB) wären über 1 GB gewesen
    var maxBytes = 300 * 1024 * 1024
    /// Frist in Tagen wie Transkripte/Protokoll (0 = „Nie“ → maxDays). Wird auf dem Main-Thread gelesen; Tests setzen sie fest.
    var retentionDays: () -> Int = { Settings.shared.retentionDays }

    /// Eine laufende Aufnahme. `handle`/`frames` nur auf q.
    private final class Recording {
        let id: String, url: URL
        var handle: FileHandle?
        var frames = 0
        init(id: String, url: URL) { self.id = id; self.url = url }
    }

    private let q = DispatchQueue(label: "flow.diktat-sicherung")
    private var rec: Recording?
    /// So viele Samples sind schon an q übergeben (Main-Thread)
    private var written = 0
    private var timer: Timer?
    private(set) var currentID: String?
    private var started = Date()

    static func newID(_ d: Date = Date()) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd_HHmmss_SSS"
        return df.string(from: d)
    }

    private func wav(_ id: String) -> URL { dir.appendingPathComponent("\(id).wav") }
    private func meta(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    /// Laufende Aufnahme (bis 1.7.55: `.laeuft.f32` mit rohen Float-Samples – liest recoverCrashed weiterhin)
    private func partial(_ id: String) -> URL { dir.appendingPathComponent("\(id).laeuft.wav") }

    // MARK: Aufnahme mitschreiben

    /// Diktat beginnt: alle 2 s die neuen Samples (`peek(abPosition)`) an die Teil-Datei hängen.
    /// 18.10.2026: kehrt sofort zurück. Vorher legte q.sync die Datei an und wartete dabei hinter dem WAV-Schreiben des
    /// vorigen Diktats – das hielt den Mikro-Start auf (Anfang eines schnellen zweiten Diktats abgeschnitten). Bis die
    /// Datei steht, liegen die ersten Samples ohnehin im Speicher (DictationTap) und kommen mit dem ersten Nachschub.
    func begin(peek: @escaping (Int) -> [Float]) {
        if currentID != nil { finish([], status: .leer) }
        let id = Self.newID()
        let r = Recording(id: id, url: partial(id))
        rec = r
        currentID = id
        started = Date()
        written = 0
        let folder = dir
        q.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: r.url.path, contents: Self.wavHeader(frames: 0),
                                                 attributes: [.posixPermissions: 0o600]) else { return }
            r.handle = try? FileHandle(forWritingTo: r.url)
            _ = try? r.handle?.seekToEnd()
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.flush(peek) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func flush(_ peek: (Int) -> [Float]) {
        guard let r = rec else { return }
        let s = peek(written)
        guard !s.isEmpty else { return }
        written += s.count
        q.async {
            guard let h = r.handle else { return }
            do { try h.write(contentsOf: Self.pcm16(s)); r.frames += s.count }
            catch { try? h.close(); r.handle = nil }   // z. B. Platte voll → finish schreibt die Datei dann einmal ganz
        }
    }

    /// Diktat zu Ende (egal wie): Rest anhängen, Kopf fertig, umbenennen, Beschreibung schreiben. Zu kurz/leer → nichts behalten.
    /// `samples` = die ganze Aufnahme (dieselbe, aus der `peek` gelesen hat). Gibt die Sicherungs-ID zurück (nil = nichts gesichert).
    @discardableResult
    func finish(_ samples: [Float], status: DictationBackupStatus, text: String? = nil) -> String? {
        timer?.invalidate(); timer = nil
        guard let id = currentID, let r = rec else { return nil }
        currentID = nil; rec = nil
        let keep = samples.count >= Self.rate   // unter 1 s lohnt keine Sicherung
        let entry = DictationBackupEntry(id: id, date: started, duration: Double(samples.count) / Double(Self.rate), status: status, text: text)
        let days = retentionDays()
        q.async { [self] in
            guard keep else {
                try? r.handle?.close(); r.handle = nil
                try? FileManager.default.removeItem(at: r.url)
                return
            }
            if complete(r, samples) { writeMeta(entry) }
            prune(days: days)
        }
        return keep ? id : nil
    }

    /// Status/Text nachtragen (z. B. nach dem Erkennen)
    func update(_ id: String, status: DictationBackupStatus? = nil, text: String? = nil) {
        q.async { [self] in
            guard var e = readMeta(id) else { return }
            if let status { e.status = status }
            if let text { e.text = text }
            writeMeta(e)
        }
    }

    /// Sicherung ganz weg (z. B. „Nichts gehört“)
    func discard(_ id: String) {
        q.async { [self] in
            try? FileManager.default.removeItem(at: wav(id))
            try? FileManager.default.removeItem(at: meta(id))
        }
    }

    /// Läuft nach allem, was bis jetzt eingereiht ist (fertige WAV liegt dann da) – für die Fehlersuch-Links (Dictation.saveDebug)
    func afterWrites(_ body: @escaping () -> Void) { q.async(execute: body) }

    // MARK: Lesen

    func entries(limit: Int = keep) -> [DictationBackupEntry] {
        q.sync {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let ids = files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            // gleiche Sekunde (das Datum in der .json hat keine Millisekunden) → nach ID, die hat sie
            return ids.compactMap { readMeta($0) }.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }.prefix(limit).map { $0 }
        }
    }

    func entry(_ id: String) -> DictationBackupEntry? { q.sync { readMeta(id) } }

    /// 18.10.2026: über q – sonst las „Esc beim Erkennen“ (Dictation.abortTranscription) evtl. eine halb geschriebene Datei.
    /// Nicht vom Main-Thread aufrufen (lange Diktate = einige MB lesen); rescueRecognize ruft es im Hintergrund.
    func samples(_ id: String) -> [Float] { q.sync { WavWriter.read(wav(id)) } }

    func fileURL(_ id: String) -> URL { wav(id) }

    // MARK: Absturz

    /// Beim Start: Teil-Datei eines nicht beendeten Diktats → WAV mit Status „absturz“ (danach wird aufgeräumt)
    func recoverCrashed() -> [DictationBackupEntry] {
        let days = retentionDays()
        let running = currentID
        return q.sync {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            var out: [DictationBackupEntry] = []
            for f in files {
                let id: String
                let legacy = f.hasSuffix(".laeuft.f32")
                if legacy { id = String(f.dropLast(".laeuft.f32".count)) }
                else if f.hasSuffix(".laeuft.wav") { id = String(f.dropLast(".laeuft.wav".count)) }
                else { continue }
                if id == running { continue }
                let url = dir.appendingPathComponent(f)
                let frames: Int
                if legacy {
                    // bis 1.7.55: rohe Float-Samples → einmal als 16-bit-WAV schreiben
                    let data = (try? Data(contentsOf: url)) ?? Data()
                    let s: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    try? fm.removeItem(at: url)
                    guard s.count >= Self.rate, Self.writeWav(s, to: wav(id)) else { continue }
                    frames = s.count
                } else {
                    // Samples liegen schon richtig – nur die Größen im Kopf nachtragen (halbes Sample am Ende weg)
                    let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                    let n = max(0, (size - Self.headerSize) / 2)
                    guard n >= Self.rate else { try? fm.removeItem(at: url); continue }
                    guard Self.fixHeader(url, frames: n) else { continue }
                    try? fm.removeItem(at: wav(id))
                    guard (try? fm.moveItem(at: url, to: wav(id))) != nil else { continue }
                    frames = n
                }
                let date = Self.date(fromID: id) ?? Date()
                let e = DictationBackupEntry(id: id, date: date, duration: Double(frames) / Double(Self.rate), status: .absturz, text: nil)
                writeMeta(e)
                out.append(e)
            }
            prune(days: days)
            return out
        }
    }

    static func date(fromID id: String) -> Date? {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd_HHmmss_SSS"
        return df.date(from: id)
    }

    // MARK: WAV (16 kHz mono 16 bit, fester 44-Byte-Kopf)

    static func wavHeader(frames: Int) -> Data {
        let dataBytes = UInt32(clamping: frames * 2)
        var d = Data(); d.reserveCapacity(headerSize)
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        tag("RIFF"); u32(dataBytes &+ 36); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        tag("data"); u32(dataBytes)
        return d
    }

    static func pcm16<C: Collection>(_ s: C) -> Data where C.Element == Float {
        var d = Data(count: s.count * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            var i = 0
            for x in s {
                let v = x.isNaN ? 0 : max(-1, min(1, x))
                p[i] = Int16((v * 32767).rounded()).littleEndian
                i += 1
            }
        }
        return d
    }

    /// Ganze Datei auf einmal (Ausweg, wenn das Mitschreiben nicht ging, und für alte .f32-Reste)
    static func writeWav(_ s: [Float], to url: URL) -> Bool {
        var d = wavHeader(frames: s.count)
        d.append(pcm16(s))
        guard (try? d.write(to: url)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Kopf einer unterbrochenen Datei reparieren: Größen eintragen, angefangenes Sample abschneiden
    static func fixHeader(_ url: URL, frames: Int) -> Bool {
        guard let h = try? FileHandle(forUpdating: url) else { return false }
        defer { try? h.close() }
        do {
            try h.truncate(atOffset: UInt64(headerSize + frames * 2))
            try h.seek(toOffset: 0)
            try h.write(contentsOf: wavHeader(frames: frames))
            return true
        } catch { return false }
    }

    // MARK: intern (nur auf q)

    /// Aufnahme abschließen: Rest anhängen, echte Größen in den Kopf, `.laeuft.wav` → `.wav`.
    /// Fehlt die Teil-Datei (oder ging ein Schreiben schief), wird sie einmal ganz aus `samples` geschrieben.
    private func complete(_ r: Recording, _ samples: [Float]) -> Bool {
        let fm = FileManager.default
        var ok = false
        if let h = r.handle, r.frames <= samples.count {
            do {
                try h.truncate(atOffset: UInt64(Self.headerSize + r.frames * 2))
                if samples.count > r.frames { try h.write(contentsOf: Self.pcm16(samples[r.frames...])) }
                try h.seek(toOffset: 0)
                try h.write(contentsOf: Self.wavHeader(frames: samples.count))
                ok = true
            } catch {}
        }
        try? r.handle?.close(); r.handle = nil
        if !ok { ok = Self.writeWav(samples, to: r.url) }
        guard ok else { try? fm.removeItem(at: r.url); return false }
        try? fm.removeItem(at: wav(r.id))
        return (try? fm.moveItem(at: r.url, to: wav(r.id))) != nil
    }

    private func readMeta(_ id: String) -> DictationBackupEntry? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: meta(id)) else { return nil }
        return try? dec.decode(DictationBackupEntry.self, from: d)
    }

    private func writeMeta(_ e: DictationBackupEntry) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        guard let d = try? enc.encode(e) else { return }
        try? d.write(to: meta(e.id), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: meta(e.id).path)
    }

    /// Aufräumen: neueste 30, Frist wie die Transkripte, höchstens `maxBytes` (die neueste bleibt immer).
    /// 18.10.2026: auch Waisen – eine WAV, deren Beschreibung nicht geschrieben wurde, blieb vorher für immer liegen
    /// (es wurden nur .json betrachtet). Laufende `.laeuft.*`-Dateien fasst nur recoverCrashed an.
    private func prune(days: Int) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let names = Set(files)
        var ids: [String] = []
        for f in files where !f.contains(".laeuft.") {
            let isWav = f.hasSuffix(".wav"), isMeta = f.hasSuffix(".json")
            guard isWav || isMeta else { continue }
            let id = String(f.dropLast(isWav ? 4 : 5))
            guard Self.date(fromID: id) != nil else { continue }   // nur eigene Dateien
            if names.contains(id + (isWav ? ".json" : ".wav")) {
                if isMeta { ids.append(id) }
            } else {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        ids.sort(by: >)
        let maxAge = (days > 0 ? Double(days) : Self.maxDays) * 86400
        let cutoff = Date().addingTimeInterval(-maxAge)
        func size(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0 }
        var total = 0
        for (i, id) in ids.enumerated() {
            total += size(wav(id)) + size(meta(id))
            let old = (Self.date(fromID: id) ?? Date()) < cutoff
            if i >= Self.keep || old || (i > 0 && total > maxBytes) {
                try? fm.removeItem(at: wav(id))
                try? fm.removeItem(at: meta(id))
            }
        }
    }
}

// MARK: - Selbsttest (--selftest-backup, nur mit FLOW_HOME)

enum DictationBackupCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1, args[1] == "--selftest-backup" else { return nil }
        guard ProcessInfo.processInfo.environment["FLOW_HOME"] != nil else {
            print("FEHLER --selftest-backup braucht FLOW_HOME (Test-Ordner)"); return 1
        }
        let fm = FileManager.default
        let b = DictationBackup()
        b.dir = Paths.base.appendingPathComponent("Diktat-Sicherungen-Test", isDirectory: true)
        b.retentionDays = { 3 }
        try? fm.removeItem(at: b.dir)
        var ok = 0, bad = 0
        func check(_ c: Bool, _ name: String) { if c { ok += 1; print("  ok     \(name)") } else { bad += 1; print("  FEHLER \(name)") } }
        func size(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? -1 }
        func inode(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? Int) ?? -1 }
        func files() -> [String] { ((try? fm.contentsOfDirectory(atPath: b.dir.path)) ?? []).sorted() }
        func waitQ() { _ = b.entries(limit: 0) }   // q.sync: alles Eingereihte ist geschrieben
        let tone: [Float] = (0..<(16000 * 3)).map { Float(sin(Double($0) * 0.05) * 0.3) }
        let wavBytes = DictationBackup.headerSize + tone.count * 2

        // 1) Absturz (Format bis 1.7.55): Float-Teil-Datei bleibt liegen → beim Start wird daraus eine WAV
        let crashID = DictationBackup.newID(Date().addingTimeInterval(-60))
        try? fm.createDirectory(at: b.dir, withIntermediateDirectories: true)
        let part = b.dir.appendingPathComponent("\(crashID).laeuft.f32")
        try? tone.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: part)
        let rec = b.recoverCrashed()
        check(rec.count == 1 && rec.first?.status == .absturz, "Absturz-Rest wird zur Sicherung (Status absturz)")
        check(!fm.fileExists(atPath: part.path), "Teil-Datei danach weg")
        check(b.samples(crashID).count == tone.count, "WAV hat alle Samples (\(b.samples(crashID).count))")

        // 2) Mitschreiben während des Sprechens – direkt als 16-bit-WAV
        b.begin { from in from < tone.count ? Array(tone[from...]) : [] }
        let id = b.currentID ?? ""
        let partial = b.dir.appendingPathComponent("\(id).laeuft.wav")
        RunLoop.main.run(until: Date().addingTimeInterval(2.4))
        waitQ()
        let psize = size(partial)
        check(psize == wavBytes, "nach 2 s liegt das Gesagte schon auf der Platte (\(psize) B, 16-bit-WAV)")

        // 3) Abbrechen → WAV + Status, Teil-Datei weg
        let bid = b.finish(tone, status: .abgebrochen)
        check(bid == id, "finish gibt die Sicherungs-ID zurück")
        let e = b.entry(id)
        check(e?.status == .abgebrochen && abs((e?.duration ?? 0) - 3) < 0.01, "Beschreibung: abgebrochen, 3 s")
        check(!fm.fileExists(atPath: partial.path), "Teil-Datei nach finish weg")

        // 4) Nachtragen nach dem Erkennen
        b.update(id, status: .fertig, text: "Hallo Welt")
        check(b.entry(id)?.text == "Hallo Welt" && b.entry(id)?.hasText == true, "Text nachgetragen")
        check(b.entries().first?.id == id, "neueste Sicherung steht oben")

        // 5) EIN Schreibweg: genau eine WAV (16 bit, Kopf stimmt) + Beschreibung, keine .f32/.laeuft-Reste
        let mine = files().filter { $0.hasPrefix(id) }
        let w = b.fileURL(id)
        check(mine == ["\(id).json", "\(id).wav"] && !files().contains { $0.contains(".laeuft.") || $0.hasSuffix(".f32") },
              "nach finish nur \(id).wav + .json, keine Float-/Teil-Kopie (\(mine.joined(separator: ", ")))")
        let head = (try? Data(contentsOf: w).prefix(DictationBackup.headerSize)) ?? Data()
        check(size(w) == wavBytes && head == DictationBackup.wavHeader(frames: tone.count) && b.samples(id).count == tone.count,
              "WAV: 16 bit, Kopf mit echten Größen, alle Samples (\(size(w)) B)")

        // 6) Fehlersuche (diktate/, letzte-aufnahme.wav) = harte Links, kein zweites Schreiben; Text nur mit logTexts
        let dbg = Paths.base.appendingPathComponent("diktate-Test", isDirectory: true)
        let latest = Paths.base.appendingPathComponent("letzte-aufnahme-Test.wav")
        try? fm.removeItem(at: dbg); try? fm.removeItem(at: latest)
        try? fm.createDirectory(at: dbg, withIntermediateDirectories: true)
        let did = Dictation.saveDebug(backupID: id, backup: b, dir: dbg, latest: latest)
        waitQ()
        let dwav = dbg.appendingPathComponent("\(did).wav")
        check(inode(dwav) == inode(w) && inode(latest) == inode(w) && inode(w) > 0,
              "diktate/ + letzte-aufnahme.wav zeigen auf dieselbe Datei (harter Link, 0 B extra)")
        check(WavWriter.read(dwav).count == tone.count, "Fehlersuch-Kopie liest sich wie vorher (\(WavWriter.read(dwav).count) Samples)")
        Dictation.saveDebugText(did, "geheimer Text", logTexts: false, dir: dbg)
        let txt = dbg.appendingPathComponent("\(did).txt")
        check(!fm.fileExists(atPath: txt.path), "„Texte mitschreiben“ aus → kein Text in diktate/")
        Dictation.saveDebugText(did, "Text", logTexts: true, dir: dbg)
        check(fm.fileExists(atPath: txt.path), "„Texte mitschreiben“ an → Text wie bisher")
        _ = Dictation.saveDebug(backupID: nil, backup: b, dir: dbg, latest: latest)
        waitQ()
        check(!fm.fileExists(atPath: latest.path), "ohne Sicherung (unter 1 s) zeigt letzte-aufnahme.wav auf nichts Altes")

        // 7) begin wartet nicht auf die Platte; Nacherkennen liest erst nach dem Schreiben
        b.afterWrites { Thread.sleep(forTimeInterval: 0.5) }   // langsame Platte / langes voriges Diktat
        let t0 = Date()
        b.begin { _ in [] }
        let dt = Date().timeIntervalSince(t0)
        check(dt < 0.05, String(format: "begin kehrt sofort zurück, auch wenn die Platte beschäftigt ist (%.0f ms)", dt * 1000))
        let qid = b.finish(tone, status: .abgebrochen) ?? ""
        let got = b.samples(qid).count
        check(got == tone.count, "Nacherkennen nach Esc liest die fertige Sicherung (\(got) Samples, nicht halb)")

        // 8) Absturz mitten im Diktat (neues Format): Kopf mit Platzhaltern + Samples + halbes Sample → gültige WAV
        let crash2 = DictationBackup.newID(Date().addingTimeInterval(-30))
        let part2 = b.dir.appendingPathComponent("\(crash2).laeuft.wav")
        var raw = DictationBackup.wavHeader(frames: 0); raw.append(DictationBackup.pcm16(tone)); raw.append(0x7F)
        try? raw.write(to: part2)
        let rec2 = b.recoverCrashed()
        let w2 = b.fileURL(crash2)
        let head2 = (try? Data(contentsOf: w2).prefix(DictationBackup.headerSize)) ?? Data()
        check(rec2.map(\.id) == [crash2] && rec2.first?.status == .absturz && !fm.fileExists(atPath: part2.path),
              "16-bit-Teil-Datei nach Absturz → Sicherung (Status absturz), Teil-Datei weg")
        check(head2 == DictationBackup.wavHeader(frames: tone.count) && size(w2) == wavBytes && b.samples(crash2).count == tone.count,
              "Kopf repariert, halbes Sample weg, alle \(tone.count) Samples lesbar")

        // 9) zu kurz → nichts behalten
        b.begin { _ in [] }
        check(b.finish(Array(tone[0..<8000]), status: .fertig) == nil, "unter 1 s wird nichts gesichert")

        // 10) Aufräumen: höchstens 30, nichts älter als die Frist
        for i in 0..<35 {
            b.begin { _ in [] }
            _ = b.finish(tone, status: .fertig)
            _ = i
            Thread.sleep(forTimeInterval: 0.002)
        }
        let old = DictationBackup.newID(Date().addingTimeInterval(-20 * 86400))
        b.begin { _ in [] }; _ = b.finish(tone, status: .fertig)   // Auslöser für prune
        let n = b.entries(limit: 999).count
        check(n == DictationBackup.keep, "höchstens \(DictationBackup.keep) Sicherungen (\(n))")
        _ = old
        check(b.entry(crashID) == nil, "älteste fliegen zuerst raus")

        // 11) Waisen: WAV ohne Beschreibung / Beschreibung ohne WAV fliegen raus, fremde Dateien bleiben
        let orphanWav = b.dir.appendingPathComponent("\(DictationBackup.newID(Date().addingTimeInterval(-90))).wav")
        let orphanMeta = b.dir.appendingPathComponent("\(DictationBackup.newID(Date().addingTimeInterval(-80))).json")
        let foreign = b.dir.appendingPathComponent("liesmich.txt")
        _ = DictationBackup.writeWav(tone, to: orphanWav)
        try? Data("{}".utf8).write(to: orphanMeta)
        try? Data("x".utf8).write(to: foreign)
        b.begin { _ in [] }; _ = b.finish(tone, status: .fertig)
        waitQ()
        check(!fm.fileExists(atPath: orphanWav.path) && !fm.fileExists(atPath: orphanMeta.path) && fm.fileExists(atPath: foreign.path),
              "Waisen (WAV ohne .json, .json ohne WAV) werden gelöscht, fremde Dateien nicht")
        let orphan2 = b.dir.appendingPathComponent("\(DictationBackup.newID(Date().addingTimeInterval(-70))).wav")
        _ = DictationBackup.writeWav(tone, to: orphan2)
        _ = b.recoverCrashed()
        check(!fm.fileExists(atPath: orphan2.path), "auch der Start (Absturz-Wiederherstellung) räumt auf")

        // 12) Frist folgt der Einstellung „Transkripte löschen nach“ (vorher immer 14 Tage) – frischer Ordner, damit die 30er-Grenze nicht mitspielt
        waitQ(); try? fm.removeItem(at: b.dir); try? fm.createDirectory(at: b.dir, withIntermediateDirectories: true)
        func plant(daysAgo: Double) -> String {
            let pid = DictationBackup.newID(Date().addingTimeInterval(-daysAgo * 86400))
            _ = DictationBackup.writeWav(tone, to: b.fileURL(pid))
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let pe = DictationBackupEntry(id: pid, date: Date().addingTimeInterval(-daysAgo * 86400), duration: 3, status: .fertig, text: "alt")
            try? enc.encode(pe).write(to: b.dir.appendingPathComponent("\(pid).json"))
            return pid
        }
        let five = plant(daysAgo: 5)
        b.retentionDays = { 0 }   // „Nie“ → wie bisher 14 Tage
        b.begin { _ in [] }; _ = b.finish(tone, status: .fertig)
        check(b.entry(five) != nil, "„Nie“: 5 Tage alte Sicherung bleibt (14-Tage-Grenze wie bisher)")
        b.retentionDays = { 3 }
        b.begin { _ in [] }; _ = b.finish(tone, status: .fertig)
        check(b.entry(five) == nil, "Frist 3 Tage: 5 Tage alte Sicherung (samt Text) ist weg")

        // 13) Größen-Grenze: 30 × 20-min-Diktat kann nicht mehr über 1 GB werden
        b.maxBytes = 4 * (wavBytes + 400)
        var made: [String] = []
        for _ in 0..<6 { b.begin { _ in [] }; made += [b.finish(tone, status: .fertig)].compactMap { $0 }; Thread.sleep(forTimeInterval: 0.002) }
        let all = b.entries(limit: 999)
        let bytes = files().filter { !$0.hasSuffix(".txt") }.reduce(0) { $0 + size(b.dir.appendingPathComponent($1)) }
        check(all.map(\.id) == Array(made.suffix(4).reversed()) && bytes <= b.maxBytes,
              "über der Byte-Grenze fliegen die ältesten raus (\(all.count) Sicherungen, \(bytes / 1024) KB ≤ \(b.maxBytes / 1024) KB)")
        b.maxBytes = 300 * 1024 * 1024

        try? fm.removeItem(at: b.dir)
        try? fm.removeItem(at: dbg); try? fm.removeItem(at: latest)
        print("Diktat-Sicherung: \(ok)/\(ok + bad) ok")
        return bad == 0 ? 0 : 1
    }
}
