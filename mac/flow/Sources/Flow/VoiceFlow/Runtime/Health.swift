import Foundation

/// Lebenszeichen + Absturz-Erkennung (Stabilitätsplan #4).
///
/// `~/.config/flow/health.json` – das Health-Gate nach einem Update liest sie (scripts/install_lib.sh):
///   pid, version, build, bundle, startedAt, lastHeartbeat (alle 30 s vom Main-Thread – hängt der, bleibt es aus),
///   busy (Aufnahme/Diktat/Meeting → kein Update-Neustart), cleanExit (true nach sauberem Beenden),
///   uncleanExits / crashReports (Zähler seit Beginn), lastCrashScan
/// Beim Start: Hat der vorige Lauf nicht sauber beendet → Log-Zeile + Zähler. Neue Absturzberichte
/// (`~/Library/Logs/DiagnosticReports/Flow*.ips`, `Flow*.ips`) seit dem letzten Start → Dateiname + Ausnahmetyp
/// ins Log – nie Inhalte (Stack, Speicher, Texte).
final class Health {
    static let shared = Health(url: Paths.base.appendingPathComponent("health.json"), reportsDir: Health.defaultReportsDir)

    struct State: Codable {
        var pid: Int32
        var version: String
        var build: String
        var bundle: String
        var startedAt: Double
        var lastHeartbeat: Double
        var busy: Bool
        var cleanExit: Bool
        var uncleanExits: Int
        var crashReports: Int
        var lastCrashScan: Double
    }
    struct StartReport { var unclean: Bool; var reports: [String] }

    static var defaultReportsDir: URL {
        if let d = ProcessInfo.processInfo.environment["FLOW_DIAG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    let url: URL
    let reportsDir: URL
    /// Aufnahme/Diktat/Meeting läuft (setzt App.swift, sobald die Controller stehen)
    var busyProbe: () -> Bool = { false }
    private let queue = DispatchQueue(label: "flow.health")
    private var state: State?
    private var timer: Timer?
    private var termSource: DispatchSourceSignal?

    init(url: URL, reportsDir: URL) { self.url = url; self.reportsDir = reportsDir }

    func load() -> State? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: d)
    }

    // MARK: Start

    /// Beim App-Start (vor allem anderen): vorigen Lauf auswerten, Absturzberichte suchen, neues Lebenszeichen schreiben.
    @discardableResult
    func begin(now: Double = Date().timeIntervalSince1970) -> StartReport {
        let prev = load()
        var s = State(pid: getpid(), version: AppVersion.short, build: AppVersion.build ?? "", bundle: Bundle.main.bundlePath,
                      startedAt: now, lastHeartbeat: now, busy: false, cleanExit: false,
                      uncleanExits: prev?.uncleanExits ?? 0, crashReports: prev?.crashReports ?? 0, lastCrashScan: now)
        var rep = StartReport(unclean: false, reports: [])
        if let p = prev, !p.cleanExit {
            s.uncleanExits += 1
            rep.unclean = true
            log("Absturz-Erkennung: voriger Lauf (\(p.version), Build \(p.build), pid \(p.pid)) wurde nicht sauber beendet – insgesamt \(s.uncleanExits)×")
        }
        // Erster Start mit Health: die letzten 7 Tage ansehen
        rep.reports = Health.scanReports(in: reportsDir, since: prev?.lastCrashScan ?? now - 7 * 86400)
        s.crashReports += rep.reports.count
        for r in rep.reports { log("Absturzbericht: \(r)") }
        Health.trimStderr()
        queue.sync { state = s; write() }
        return rep
    }

    /// App-Modus: Heartbeat-Timer auf dem Main-Runloop + sauberes Ende auch bei SIGTERM (launchctl bootout beim Update)
    func startTimers() {
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.heartbeat() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Ohne Handler beendet SIGTERM die App sofort – dann sähe jedes Update wie ein Absturz aus.
        // Eigene Queue (nicht main): ein hängender Main-Thread darf das Beenden nicht aufhalten.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global(qos: .userInitiated))
        src.setEventHandler { [weak self] in
            self?.markCleanExit()
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)          // wie bisher durch das Signal enden (launchd sieht denselben Ausgang)
        }
        src.resume()
        termSource = src
    }

    // MARK: Laufend

    /// Vom Main-Thread (Timer): beweist, dass die Oberfläche lebt
    func heartbeat(now: Double = Date().timeIntervalSince1970) {
        let busy = busyProbe()
        queue.async { [self] in
            guard state != nil else { return }
            state!.lastHeartbeat = now
            state!.busy = busy
            write()
        }
    }

    /// Nur schreiben, wenn sich etwas ändert (Updater ruft das während eines Updates sekündlich)
    func setBusy(_ busy: Bool) {
        queue.async { [self] in
            guard state != nil, state!.busy != busy else { return }
            state!.busy = busy
            write()
        }
    }

    /// Sauberes Ende (applicationWillTerminate, SIGTERM) – synchron, der Prozess endet gleich
    func markCleanExit() {
        queue.sync {
            guard state != nil else { return }
            state!.cleanExit = true
            state!.busy = false
            write()
        }
    }

    /// Nur für Tests: warten, bis alles geschrieben ist
    func flush() { queue.sync {} }

    private func write() {   // nur auf `queue`
        guard let s = state else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Absturzberichte

    /// Neue Berichte dieser App seit `since` – „Dateiname · Ausnahmetyp (Signal)“, älteste zuerst
    static func scanReports(in dir: URL, since: Double) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var found: [(Double, String)] = []
        for n in names where n.hasSuffix(".ips") && (n.hasPrefix("Flow") || n.hasPrefix("Flow")) {
            let path = dir.appendingPathComponent(n).path
            guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  m.timeIntervalSince1970 > since else { continue }
            found.append((m.timeIntervalSince1970, "\(n) · \(exceptionType(path))"))
        }
        return found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// .ips = 1. Zeile Kopf-JSON, danach Bericht-JSON. Nur `exception.type` + `signal` (bzw. `bug_type`) – nichts Privates.
    static func exceptionType(_ path: String) -> String {
        guard let d = FileManager.default.contents(atPath: path), let txt = String(data: d, encoding: .utf8) else { return "unlesbar" }
        let parts = txt.split(separator: "\n", maxSplits: 1)
        if parts.count > 1, let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
           let ex = body["exception"] as? [String: Any] {
            let type = ex["type"] as? String ?? "?"
            if let sig = ex["signal"] as? String { return "\(type) (\(sig))" }
            return type
        }
        if let h = parts.first, let head = try? JSONSerialization.jsonObject(with: Data(h.utf8)) as? [String: Any],
           let bt = head["bug_type"] as? String { return "bug_type \(bt)" }
        return "ohne Ausnahmetyp"
    }

    /// LaunchAgent schreibt stderr nach stderr.log (build.sh) – ab 1 MB leeren
    static func trimStderr() {
        let p = Paths.base.appendingPathComponent("stderr.log").path
        if let size = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int, size > 1_000_000 {
            truncate(p, 0)
            log("stderr.log gekürzt (\(size / 1024) KB)")
        }
    }
}

// MARK: - Selbsttest (Release-Tor): FLOW_HOME=<leer> Flow --selftest-health

enum HealthSelfTest {
    static func run() -> Int32 {
        let c = SelfTestChecks()
        let fm = FileManager.default
        let diag = Paths.base.appendingPathComponent("diag")
        try? fm.createDirectory(at: diag, withIntermediateDirectories: true)
        let h = Health(url: Paths.base.appendingPathComponent("health.json"), reportsDir: diag)
        try? fm.removeItem(at: h.url)

        var r = h.begin(now: 1000)
        c.check(!r.unclean && h.load()?.pid == getpid() && h.load()?.cleanExit == false, "erster Start: health.json angelegt, kein Absturz gemeldet")
        r = h.begin(now: 2000)
        c.check(r.unclean && h.load()?.uncleanExits == 1, "Start ohne sauberes Ende davor → unsauber erkannt und gezählt", "\(h.load()?.uncleanExits ?? -1)")
        h.markCleanExit()
        c.check(h.load()?.cleanExit == true, "sauberes Ende schreibt cleanExit")
        r = h.begin(now: 2500)
        c.check(!r.unclean && h.load()?.uncleanExits == 1, "Start nach sauberem Ende → kein Absturz")

        // Absturzberichte: zwei neue von uns, einer fremd, einer alt
        func ips(_ name: String, _ body: String, mtime: Double) {
            let u = diag.appendingPathComponent(name)
            try? ("{\"app_name\":\"x\",\"bug_type\":\"309\"}\n" + body).write(to: u, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: u.path)
        }
        ips("Flow-2026-09-27-101010.ips", "{\"exception\":{\"type\":\"EXC_CRASH\",\"signal\":\"SIGABRT\"},\"asi\":{\"x\":[\"geheimer Text\"]}}", mtime: 2800)
        ips("Flow-2026-09-27-101011.ips", "{\"exception\":{\"type\":\"EXC_BAD_ACCESS\",\"signal\":\"SIGSEGV\"}}", mtime: 2900)
        ips("Safari-2026-09-27-101012.ips", "{\"exception\":{\"type\":\"EXC_CRASH\"}}", mtime: 2900)
        ips("Flow-2026-01-01-000000.ips", "{\"exception\":{\"type\":\"EXC_OLD\"}}", mtime: 100)
        r = h.begin(now: 3000)
        c.check(r.reports.count == 2 && r.reports[0].contains("EXC_CRASH (SIGABRT)") && r.reports[1].contains("EXC_BAD_ACCESS (SIGSEGV)"),
                "neue .ips seit dem letzten Start gefunden (nur Flow/Flow, Ausnahmetyp)", r.reports.joined(separator: " | "))
        c.check(!r.reports.joined().contains("geheim"), "Bericht-Inhalt landet nicht im Log")
        c.check(h.load()?.crashReports == 2, "Absturzberichte gezählt")
        r = h.begin(now: 4000)
        c.check(r.reports.isEmpty, "schon gesehene Berichte nicht doppelt")

        // Lebenszeichen + busy
        h.busyProbe = { true }
        h.heartbeat(now: 4030)
        h.flush()
        c.check(h.load()?.lastHeartbeat == 4030 && h.load()?.busy == true, "Heartbeat schreibt lastHeartbeat + busy (liest update.sh)")
        h.busyProbe = { false }
        h.setBusy(false); h.flush()
        c.check(h.load()?.busy == false, "setBusy schreibt sofort")
        h.setBusy(true); h.markCleanExit()
        c.check(h.load()?.busy == false && h.load()?.cleanExit == true, "sauberes Ende: cleanExit, busy zurückgesetzt")
        // Für den Shell-Leser im Tor (plutil) bleibt ein laufender Stand liegen
        _ = h.begin(now: Date().timeIntervalSince1970)
        return c.finish("Health")
    }
}
