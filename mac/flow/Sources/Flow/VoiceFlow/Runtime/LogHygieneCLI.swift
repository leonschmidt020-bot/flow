import Foundation

// MARK: - Protokoll-Hygiene (18.10.2026, Audit Schreiblast)
//
// stderr.log: wurde beim Start ab 1 MB ganz geleert – und mit ihm genau die Absturz-Spuren (fatalError, AppKit-Ausnahmen),
// für die es ihn gibt. Jetzt bleiben die letzten 256 KB, in derselben Datei (launchd hält sie offen, O_APPEND).
// flow.log: das stündliche Aufräumen schrieb die ganze Datei jedes Mal neu, auch wenn nichts abgelaufen war (~7 MB/Tag).
// Jetzt nur, wenn die erste Zeile älter als die Frist ist; dann gleich 6 h Vorlauf mit weg, damit es nicht in der nächsten
// Stunde wieder nötig ist (≤ 4× am Tag statt 24×, nichts bleibt länger als die Frist). Dazu eine 5-MB-Grenze, auch bei „Nie“.

enum LogHygiene {
    static let stderrOver = 1_000_000
    static let stderrKeep = 256 * 1024
    static let logCap = 5 * 1024 * 1024
    /// Über der Grenze auf 4 MB kürzen – sonst stünde das Umschreiben bei jedem Lauf wieder an
    static let logKeep = 4 * 1024 * 1024
    static let lead: TimeInterval = 6 * 3600

    /// Datei über `over` Bytes → nur die letzten `keep` Bytes behalten (ab einem Zeilenanfang). Schreibt in DIESELBE Datei
    /// (gleicher Inode): launchd hat stderr.log offen, eine neue Datei bekäme nichts mehr. Gibt (vorher, nachher) zurück.
    @discardableResult
    static func keepTail(_ url: URL, over: Int = stderrOver, keep: Int = stderrKeep) -> (before: Int, after: Int)? {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, keep > 0 else { return nil }
        let size = Int(st.st_size)
        guard size > over, size > keep else { return nil }
        var buf = [UInt8](repeating: 0, count: keep)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, keep, off_t(size - keep)) }
        guard n > 0 else { return nil }
        var start = 0
        if let nl = buf[0..<n].firstIndex(of: 0x0A), nl + 1 < n { start = nl + 1 }   // angeschnittene erste Zeile weg
        let len = n - start
        let w = buf[start..<n].withUnsafeBytes { pwrite(fd, $0.baseAddress, len, 0) }
        guard w == len, ftruncate(fd, off_t(len)) == 0 else { return nil }
        // Unser eigenes fd 2 zeigt auf diese Datei, aber ohne O_APPEND (z. B. Start aus dem Terminal mit `2>`)?
        // Dann ans neue Ende setzen – sonst schriebe es an der alten Position weiter und davor entstünde ein Loch aus Nullen.
        var e = stat()
        if fstat(2, &e) == 0, e.st_ino == st.st_ino, e.st_dev == st.st_dev, fcntl(2, F_GETFL) & O_APPEND == 0 { lseek(2, 0, SEEK_END) }
        return (size, len)
    }

    /// Muss flow.log umgeschrieben werden? Liest nur Größe und Anfang der ersten Zeile, schreibt nichts.
    static func logNeedsPrune(_ url: URL, retentionDays: Int, now: Date = Date()) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0 else { return false }
        if size > logCap { return true }
        guard retentionDays > 0, let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 64)) ?? Data()
        // Unlesbarer Anfang → wie bisher aufräumen (Zeilen ohne Datum fliegen raus)
        guard let sp = head.firstIndex(of: 0x20),
              let d = ISO8601DateFormatter().date(from: String(decoding: head[..<sp], as: UTF8.self)) else { return true }
        return d < now.addingTimeInterval(-Double(retentionDays) * 86400)
    }

    /// Aufgeräumter Inhalt: Zeilen älter als Frist − Vorlauf weg (nur mit Frist), danach höchstens 4 MB der neuesten Zeilen.
    static func prunedLog(_ txt: String, retentionDays: Int, now: Date = Date()) -> String {
        var lines = txt.components(separatedBy: "\n")
        if retentionDays > 0 {
            let span = Double(retentionDays) * 86400
            let cutoff = now.addingTimeInterval(-span + min(lead, span / 4))
            let f = ISO8601DateFormatter()
            lines = lines.filter { line in
                guard let sp = line.firstIndex(of: " "), let d = f.date(from: String(line[..<sp])) else { return false }
                return d >= cutoff
            }
        } else {
            lines = lines.filter { !$0.isEmpty }
        }
        var bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        if bytes > logCap {
            var from = lines.count
            bytes = 0
            for i in stride(from: lines.count - 1, through: 0, by: -1) {
                bytes += lines[i].utf8.count + 1
                if bytes > logKeep { break }
                from = i
            }
            lines = Array(lines[from...])
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Prüfen und nur wenn nötig umschreiben. `rewrite` = rewriteLog (läuft auf der Log-Queue); ohne = direkt (Tests).
    @discardableResult
    static func prune(_ url: URL, retentionDays: Int, now: Date = Date(),
                      rewrite: ((@escaping (String) -> String) -> Void)? = nil) -> Bool {
        guard logNeedsPrune(url, retentionDays: retentionDays, now: now) else { return false }
        let t: (String) -> String = { prunedLog($0, retentionDays: retentionDays, now: now) }
        if let rewrite { rewrite(t) } else { rewriteFile(url, t) }
        return true
    }

    /// Lesen, umformen, nur bei Änderung atomar schreiben. Kaputte UTF-8-Reste (z. B. Stromausfall mitten in einer Zeile)
    /// werden ersetzt – vorher scheiterte das Lesen dann, und die Datei wurde nie wieder aufgeräumt.
    static func rewriteFile(_ url: URL, _ transform: (String) -> String) {
        guard let d = try? Data(contentsOf: url) else { return }
        let txt = String(decoding: d, as: UTF8.self)
        let out = transform(txt)
        guard out != txt else { return }
        try? out.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Selbsttest (--selftest-logs, nur mit FLOW_HOME)

enum LogHygieneCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1, args[1] == "--selftest-logs" else { return nil }
        guard ProcessInfo.processInfo.environment["FLOW_HOME"] != nil else {
            print("FEHLER --selftest-logs braucht FLOW_HOME (Test-Ordner)"); return 1
        }
        let fm = FileManager.default
        let dir = Paths.base.appendingPathComponent("Log-Test", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = 0, bad = 0
        func check(_ c: Bool, _ name: String) { if c { ok += 1; print("  ok     \(name)") } else { bad += 1; print("  FEHLER \(name)") } }
        func size(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? -1 }
        func inode(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? Int) ?? -1 }
        func text(_ u: URL) -> String { String(decoding: (try? Data(contentsOf: u)) ?? Data(), as: UTF8.self) }
        let iso = ISO8601DateFormatter()
        let now = Date()
        func line(_ ago: TimeInterval, _ s: String) -> String { "\(iso.string(from: now.addingTimeInterval(-ago))) \(s)\n" }

        // 1) stderr.log: über 1 MB → die letzten 256 KB bleiben (vorher: ganz geleert)
        let err = dir.appendingPathComponent("stderr.log")
        var big = ""
        for i in 0..<30_000 { big += "Zeile \(i) fatalError? nein, nur Füllung …\n" }
        big += "LETZTE ZEILE: Fatal error: Index out of range\n"
        try? Data(big.utf8).write(to: err)
        let ino = inode(err), before = size(err)
        let appendFD = open(err.path, O_WRONLY | O_APPEND)   // so hält launchd die Datei offen
        let r = LogHygiene.keepTail(err)
        let t1 = text(err)
        check(before > 1_000_000 && r != nil && size(err) <= LogHygiene.stderrKeep && size(err) > LogHygiene.stderrKeep - 200,
              "stderr.log über 1 MB → letzte 256 KB bleiben (\(before / 1024) → \(size(err) / 1024) KB)")
        check(t1.hasSuffix("LETZTE ZEILE: Fatal error: Index out of range\n") && t1.hasPrefix("Zeile "),
              "Absturz-Spur am Ende bleibt, Anfang ist eine ganze Zeile")
        check(inode(err) == ino, "dieselbe Datei (launchd schreibt weiter hinein)")
        _ = "nach dem Kürzen\n".withCString { write(appendFD, $0, strlen($0)) }
        close(appendFD)
        let t2 = text(err)
        check(t2.hasSuffix("Index out of range\nnach dem Kürzen\n") && !t2.contains("\0"), "Schreiben über offenes O_APPEND-Handle landet am neuen Ende, kein Loch")
        check(LogHygiene.keepTail(err) == nil && text(err) == t2, "unter 1 MB: nichts angefasst")

        // 1b) eigenes fd 2 ohne O_APPEND (Terminal-Umleitung) → danach am neuen Ende weiter
        try? Data(big.utf8).write(to: err)
        let saved = dup(2)
        let plain = open(err.path, O_WRONLY)
        lseek(plain, 0, SEEK_END)
        dup2(plain, 2); close(plain)
        LogHygiene.keepTail(err)
        _ = "stderr danach\n".withCString { write(2, $0, strlen($0)) }
        dup2(saved, 2); close(saved)
        let t3 = text(err)
        check(t3.hasSuffix("out of range\nstderr danach\n") && !t3.contains("\0") && size(err) <= LogHygiene.stderrKeep + 100,
              "fd 2 ohne O_APPEND schreibt danach am neuen Ende (kein Loch aus Nullen)")

        // 2) flow.log: nichts abgelaufen → NICHT umschreiben
        let lg = dir.appendingPathComponent("flow.log")
        var fresh = ""
        for i in 0..<500 { fresh += line(Double(500 - i) * 60, "frisch \(i)") }
        try? Data(fresh.utf8).write(to: lg)
        let ino2 = inode(lg)
        let mod2 = (try? fm.attributesOfItem(atPath: lg.path))?[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        let did = LogHygiene.prune(lg, retentionDays: 3, now: now)
        let mod2b = (try? fm.attributesOfItem(atPath: lg.path))?[.modificationDate] as? Date
        check(!did && inode(lg) == ino2 && mod2 == mod2b && text(lg) == fresh, "nichts abgelaufen → Datei wird nicht umgeschrieben")

        // 3) erste Zeile älter als die Frist → umschreiben, Altes (+6 h Vorlauf) weg, Frisches bleibt
        let stale = line(4 * 86400, "alt") + line(3 * 86400 - 3600, "läuft in 1 h ab") + line(3 * 86400 - 7 * 3600, "knapp drin")
            + line(2 * 86400, "vorgestern") + fresh
        try? Data(stale.utf8).write(to: lg)
        let did3 = LogHygiene.prune(lg, retentionDays: 3, now: now)
        let t4 = text(lg)
        check(did3 && !t4.contains(" alt\n") && !t4.contains("läuft in 1 h ab") && t4.hasPrefix(line(3 * 86400 - 7 * 3600, "knapp drin"))
              && t4.contains("vorgestern") && t4.hasSuffix(" frisch 499\n"),
              "abgelaufen → umgeschrieben: älter als Frist und die nächsten 6 h weg, Rest bleibt")
        check(!LogHygiene.prune(lg, retentionDays: 3, now: now) && !LogHygiene.prune(lg, retentionDays: 3, now: now.addingTimeInterval(5 * 3600)),
              "danach 5 h lang kein erneutes Umschreiben (vorher stündlich)")
        check(LogHygiene.prune(lg, retentionDays: 3, now: now.addingTimeInterval(8 * 3600)) && !text(lg).contains("knapp drin") && text(lg).contains("vorgestern"),
              "8 h später läuft „knapp drin“ ab → wieder aufgeräumt")

        // 4) „Nie“ (0): alte Zeilen bleiben, aber die 5-MB-Grenze gilt
        try? Data(stale.utf8).write(to: lg)
        check(!LogHygiene.prune(lg, retentionDays: 0, now: now) && text(lg) == stale, "„Nie“ + klein: nichts angefasst")
        var huge = ""
        huge.reserveCapacity(6 * 1024 * 1024)
        var k = 0
        while huge.utf8.count < 6 * 1024 * 1024 { huge += line(10 * 86400 - Double(k), "Zeile \(k) mit etwas Text, damit es schnell groß wird ……"); k += 1 }
        let lastLine = line(1, "neueste")
        huge += lastLine
        try? Data(huge.utf8).write(to: lg)
        let did4 = LogHygiene.prune(lg, retentionDays: 0, now: now)
        let t5 = text(lg)
        let firstOK = t5.split(separator: "\n", maxSplits: 1).first.map { iso.date(from: String($0.prefix(while: { $0 != " " }))) != nil } ?? false
        check(did4 && size(lg) <= LogHygiene.logKeep && size(lg) > LogHygiene.logKeep - 200 && t5.hasSuffix(lastLine) && firstOK,
              "„Nie“ + über 5 MB → auf die neuesten 4 MB gekürzt (\(huge.utf8.count / 1024) → \(size(lg) / 1024) KB), ganze Zeilen")
        check(!LogHygiene.prune(lg, retentionDays: 0, now: now), "danach unter der Grenze → kein weiteres Umschreiben")

        // 5) über 5 MB mit Frist, kaputtes UTF-8 am Ende (Stromausfall mitten im Schreiben) → trotzdem aufgeräumt
        var torn = Data(huge.utf8); torn.append(contentsOf: [0xE2, 0x80])
        try? torn.write(to: lg)
        let did5 = LogHygiene.prune(lg, retentionDays: 3, now: now)
        check(did5 && size(lg) <= LogHygiene.logKeep && text(lg).hasSuffix(lastLine),
              "kaputtes UTF-8 blockiert das Aufräumen nicht mehr (\(size(lg) / 1024) KB)")

        try? fm.removeItem(at: dir)
        print("Logs: \(ok)/\(ok + bad) ok")
        return bad == 0 ? 0 : 1
    }
}
