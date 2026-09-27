import AppKit

/// Automatische Updates: Flow schaut 90 s nach dem Start und dann jede Minute (kurze Abfrage) im öffentlichen Repo
/// (FLOW_REPO_URL in mac/flow.conf, Kanal `main`) nach, ob es einen neuen Stand für mac/flow oder mac/clipvault gibt.
/// Wenn ja, wächst eine Karte
/// aus der Pille: „Update verfügbar … Installieren?“. Ein Klick führt `update.sh` aus (holt nur fast-forward,
/// baut, startet neu). Deine Daten in ~/.config bleiben unangetastet.
///
/// Sicherer Weg (Stabilitätsplan #1): build.sh tauscht erst nach geprüftem Staging-Bundle und nimmt das Update zurück,
/// wenn die neue Version kein Lebenszeichen gibt. Scheitert es, schreibt update.sh `update-failed.json` – dann zeigt die
/// Karte „Update hat nicht geklappt“ mit „Nochmal versuchen“ statt „aktuell“. `update-pin` (./update.sh --pin) = still sein.
/// Nie während Aufnahme, Diktat oder Meeting: Installieren wartet, und während des Updates meldet die App „busy“
/// sekündlich in health.json, damit build.sh nicht mitten hinein neu startet.
final class Updater {
    static let shared = Updater()
    private let queue = DispatchQueue(label: "flow.updater", qos: .utility)
    private var timer: Timer?
    private var installing = false
    /// „Später“ → die Karte frühestens in 12 Stunden wieder zeigen (der rote Punkt an der Pille bleibt)
    private var snoozedUntil = Date.distantPast
    /// Offenes Update (nil = aktuell) – der rote Punkt an der Pille hängt daran
    private(set) var pendingUpdate: Pending?
    var onPendingChange: (() -> Void)?
    var isInstalling: Bool { installing }
    private var offeredFor: [String] = []
    private var busyTimer: Timer?

    /// Projektordner, aus dem diese App gebaut wurde (build.sh schreibt ihn in die Info.plist) = <klon>/mac/flow
    static var sourceDir: String? { Bundle.main.object(forInfoDictionaryKey: "FlowSourceDir") as? String }
    /// Ist `dir` Teil eines Git-Klons? (Monorepo: .git liegt zwei Ebenen höher, nicht in mac/flow)
    static func isGitCheckout(_ dir: String) -> Bool { git(dir, ["rev-parse", "--is-inside-work-tree"])?.hasPrefix("true") ?? false }
    static var logURL: URL { Paths.base.appendingPathComponent("update.log") }
    static var failedURL: URL { Paths.base.appendingPathComponent("update-failed.json") }
    static var pinURL: URL { Paths.base.appendingPathComponent("update-pin") }

    /// Läuft gerade eine Aufnahme, ein Diktat oder ein Meeting? Dann kein Neustart durch ein Update.
    static var appBusy: Bool {
        guard let d = NSApp?.delegate as? AppDelegate else { return false }
        return (d.meeting?.isRecording ?? false) || (d.dictation?.isBusy ?? false)
    }

    /// ./update.sh --pin <tag> → Tag, auf dem festgehalten wird (Updater schweigt)
    static var pinnedTag: String? {
        guard let t = try? String(contentsOf: pinURL, encoding: .utf8) else { return nil }
        let tag = t.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return tag.isEmpty ? "?" : tag
    }

    /// Von update.sh geschrieben, wenn Bau/Installation scheiterte oder zurückgenommen wurde
    struct Failed: Codable, Equatable {
        let commit: String
        let version: String?
        let reason: String
        let rolledBack: Bool?
        let manual: Bool?
        let at: Double
    }
    /// Offen nur, solange NICHT genau dieser Commit läuft (z. B. nach einem zweiten --rollback wieder vorwärts)
    static func failedUpdate() -> Failed? {
        guard let d = try? Data(contentsOf: failedURL), let f = try? JSONDecoder().decode(Failed.self, from: d) else { return nil }
        return f.commit == AppVersion.commit ? nil : f
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "vf.autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "vf.autoUpdate") }
    }

    func start() {
        announceIfJustUpdated()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.quickCheck() }
        // Jede Minute nur kurz fragen, ob sich auf GitHub etwas geändert hat (git ls-remote, kein Download);
        // die volle Prüfung läuft nur bei einer Änderung – und sicherheitshalber alle 30 Minuten.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.quickCheck() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Prüfen

    private var lastRemote: [String: String] = [:]
    private var lastFull = Date.distantPast

    /// Schnell: stimmt der Stand auf GitHub noch mit dem zuletzt gesehenen überein?
    func quickCheck() {
        guard Updater.enabled, !installing, Updater.pinnedTag == nil, let dir = Updater.sourceDir else { return }
        queue.async {
            var changed = false
            // Kanal = der Branch des Klons (Standard `main`); gefragt wird nur dessen Spitze auf dem Server
            let branch = Updater.git(dir, ["rev-parse", "--abbrev-ref", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "main"
            let ref = branch == "HEAD" ? "HEAD" : "refs/heads/" + branch
            if let out = Updater.git(dir, ["ls-remote", "origin", ref]),
               let sha = out.split(separator: "\t").first.map(String.init), !sha.isEmpty {
                if self.lastRemote[dir] != sha { self.lastRemote[dir] = sha; changed = true }
            }
            let due = Date().timeIntervalSince(self.lastFull) > 30 * 60
            if changed || due { self.lastFull = Date(); DispatchQueue.main.async { self.check() } }
        }
    }

    struct Pending {
        let flow: [String]; let clipvault: [String]
        /// gescheitertes Update (Karte zeigt Fehler + „Nochmal versuchen“)
        var failed: Failed? = nil
        var all: [String] { flow + clipvault }
        /// Kennung des Stands (Karte/Punkt nur einmal je Stand)
        var key: [String] { all + (failed.map { ["failed-\($0.at)"] } ?? []) }
    }

    /// `manual`: aus den Einstellungen („Jetzt prüfen“) – ignoriert Aus-Schalter und „Später“.
    func check(manual: Bool = false, result: ((String) -> Void)? = nil) {
        guard manual || Updater.enabled else { return }
        guard let dir = Updater.sourceDir, Updater.isGitCheckout(dir) else {
            result?("Kein Projektordner gefunden – Update geht nur mit ./update.sh."); return
        }
        if let tag = Updater.pinnedTag {
            if pendingUpdate != nil { pendingUpdate = nil; onPendingChange?() }
            result?("Festgehalten auf \(tag) – keine Updates. Aufheben: ./update.sh --unpin"); return
        }
        queue.async {
            let found = Updater.pending(dir: dir)
            DispatchQueue.main.async {
                // Offline: ein gescheitertes Update trotzdem zeigen (das steht lokal fest)
                guard var p = found ?? (Updater.failedUpdate() != nil ? Pending(flow: [], clipvault: []) : nil) else {
                    result?("GitHub nicht erreichbar – später nochmal."); return
                }
                // Repo schon auf dem neuen Stand, App aber nicht (Build gescheitert / zurückgenommen) → NICHT „aktuell“
                if p.all.isEmpty { p.failed = Updater.failedUpdate() }
                if let f = p.failed {
                    self.pendingUpdate = p
                    self.onPendingChange?()
                    log("Update-Prüfung: Update auf \(f.version ?? "?") offen – \(f.reason)")
                    result?("Update auf \(f.version ?? "neuen Stand") hat nicht geklappt: \(f.reason)")
                    self.announceRollback(f)
                    return
                }
                if p.all.isEmpty {
                    if self.pendingUpdate != nil { self.pendingUpdate = nil; self.onPendingChange?() }
                    log("Update-Prüfung: aktuell"); result?("Flow ist aktuell (\(AppVersion.line))."); return
                }
                self.pendingUpdate = p
                self.onPendingChange?()
                log("Update verfügbar: \(p.flow.count) + \(p.clipvault.count) Änderungen")
                result?("Update verfügbar – \(p.all.count) Änderung\(p.all.count == 1 ? "" : "en").")
                // Karte nur einmal pro neuem Stand (und nicht nach „Später“) – außer bei „Jetzt prüfen“
                if manual || (Date() >= self.snoozedUntil && self.offeredFor != p.key) { self.offeredFor = p.key; self.offer(p) }
            }
        }
    }

    /// nil = Netz/Git-Fehler
    private static func pending(dir: String) -> Pending? {
        guard git(dir, ["fetch", "--quiet", "origin"]) != nil else { return nil }
        // Monorepo: nur Commits, die mac/flow bzw. mac/clipvault ändern (Windows-Commits lösen kein Mac-Update aus)
        let m = lines(git(dir, ["log", "--no-merges", "--format=%s", "HEAD..@{u}", "--", "."]))
        let c = lines(git(dir, ["log", "--no-merges", "--format=%s", "HEAD..@{u}", "--", "../clipvault"]))
        return Pending(flow: m, clipvault: c)
    }

    private static func lines(_ s: String?) -> [String] {
        (s ?? "").split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Kurze Zusammenfassung für die Karte: erste Betreffzeilen ohne Präfix „Flow:“
    static func summary(_ p: Pending) -> String {
        let clean = p.all.map { s -> String in
            var t = s
            for pre in ["Flow:", "Flow 1.", "ClipVault:"] where t.hasPrefix(pre) {
                t = String(t.dropFirst(pre.count)).trimmingCharacters(in: .whitespaces)
            }
            if let dash = t.range(of: " – ") { t = String(t[..<dash.lowerBound]) }
            return t.count > 60 ? String(t.prefix(58)) + "…" : t
        }
        let head = clean.prefix(2).joined(separator: " · ")
        return clean.count > 2 ? "\(head) · +\(clean.count - 2) weitere" : head
    }

    // MARK: Anbieten & Installieren

    private func offer(_ p: Pending) {
        // Nie mitten in einer Aufnahme stören – dann in 10 Minuten nochmal
        let d = AppDelegate.shared
        if d.meeting.isRecording || d.dictation.isBusy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.offer(p) }
            return
        }
        VFNotify.shared.show(VFNotice(
            id: "update", title: "Update verfügbar",
            text: Updater.summary(p),
            illustration: "illu_willkommen", fallbackSymbol: "arrow.down.circle",
            primary: ("Installieren", { [weak self] in self?.install() }),
            secondary: ("Später", { [weak self] in self?.snoozedUntil = Date().addingTimeInterval(12 * 3600) }),
            timeout: nil,
            onClose: { [weak self] in self?.snoozedUntil = Date().addingTimeInterval(12 * 3600) }))
    }

    /// Nach einer automatischen Rücknahme einmal melden (nicht bei ./update.sh --rollback von Hand)
    private func announceRollback(_ f: Failed) {
        guard f.rolledBack == true, f.manual != true,
              UserDefaults.standard.double(forKey: "vf.rollbackShown") != f.at else { return }
        UserDefaults.standard.set(f.at, forKey: "vf.rollbackShown")
        log("Update zurückgenommen: \(f.version ?? "?") – \(f.reason)")
        VFNotify.shared.show(VFNotice(
            id: "update", title: "Update zurückgenommen",
            text: "Flow \(f.version ?? "") lief nicht stabil – die vorige Version (\(AppVersion.short)) läuft wieder. Deine Daten sind geblieben.",
            illustration: "illu_leer", fallbackSymbol: "arrow.uturn.backward.circle",
            primary: ("Nochmal versuchen", { [weak self] in self?.install() }), secondary: ("OK", {}),
            timeout: 30))
    }

    func install() {
        guard !installing, let dir = Updater.sourceDir else { return }
        // Nie mitten in Aufnahme/Diktat/Meeting neu starten – danach von selbst weiter
        if Updater.appBusy {
            log("Update: wartet, bis Aufnahme/Diktat/Meeting fertig ist")
            onPendingChange?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.install() }
            return
        }
        installing = true
        onPendingChange?()
        // Während update.sh läuft (Bauen dauert Minuten): Aufnahme-Stand sofort in health.json, build.sh wartet dann
        let bt = Timer(timeInterval: 1, repeats: true) { _ in Health.shared.setBusy(Updater.appBusy) }
        RunLoop.main.add(bt, forMode: .common)
        busyTimer = bt
        VFNotify.shared.dismiss(id: "update")
        UserDefaults.standard.set(AppVersion.line, forKey: "vf.updatedFrom")
        AppDelegate.shared.pill.view.showToast("Update wird installiert – Flow startet gleich neu", seconds: 4)
        log("Update: starte update.sh")
        // Läuft als eigener Prozess weiter, auch wenn build.sh diese App beendet (LaunchAgent: AbandonProcessGroup).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", Updater.installScript(dir: dir, logPath: Updater.logURL.path)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        p.terminationHandler = { [weak self] pr in
            // Kommt nur an, wenn die App NICHT neu gestartet wurde → Fehler oder nichts zu bauen
            DispatchQueue.main.async {
                self?.installing = false
                self?.busyTimer?.invalidate(); self?.busyTimer = nil
                self?.onPendingChange?()
                UserDefaults.standard.removeObject(forKey: "vf.updatedFrom")
                log("Update: update.sh beendet (\(pr.terminationStatus))")
                if pr.terminationStatus == 75 {
                    // build.sh hat gewartet, aber die Aufnahme läuft noch → nichts angefasst, später von selbst nochmal
                    AppDelegate.shared.pill.view.showToast("Update wartet – Aufnahme läuft noch", seconds: 3)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.install() }
                    return
                }
                if pr.terminationStatus == 0 {
                    // Kein Neustart nötig (z. B. nur ClipVault aktualisiert) → Stand neu prüfen, damit der rote Punkt verschwindet
                    let cvOnly = (self?.pendingUpdate?.flow.isEmpty ?? false) && !(self?.pendingUpdate?.clipvault.isEmpty ?? true)
                    self?.pendingUpdate = nil
                    self?.offeredFor = []
                    self?.onPendingChange?()
                    AppDelegate.shared.pill.view.showToast(cvOnly ? "ClipVault aktualisiert ✓" : "Schon aktuell ✓", seconds: 3)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.check() }
                }
                if pr.terminationStatus != 0 {
                    VFNotify.shared.show(VFNotice(
                        id: "update", title: "Update hat nicht geklappt",
                        text: "Details stehen in update.log. Flow läuft mit der bisherigen Version weiter.",
                        illustration: "illu_leer", fallbackSymbol: "exclamationmark.triangle",
                        primary: ("Log öffnen", { NSWorkspace.shared.open(Updater.logURL) }), secondary: ("OK", {}),
                        timeout: 30))
                    // update-failed.json liegt jetzt da → Karte an der Pille zeigt den Fehler mit „Nochmal versuchen“
                    self?.offeredFor = []
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.check() }
                }
            }
        }
        do { try p.run() } catch {
            installing = false
            busyTimer?.invalidate(); busyTimer = nil
            log("Update: startet nicht: \(error)")
        }
    }

    /// Der Shell-Befehl von „Installieren“ (läuft mit /bin/bash -lc): lokale Änderungen in . und .. per git stash
    /// beiseitelegen, dann ./update.sh – alles ins update.log.
    /// Audit 27.09.2026: nur noch stashen, wenn der Klon wirklich neue Commits vom Server bekommt – vorher wurde auch
    /// ohne Update laufende, nicht committete Arbeit weggelegt und nie zurückgeholt. Eigene Funktion, damit das Release-Tor GENAU diesen
    /// Befehl ausführt (`Flow --updater-command <ordner> <log>`).
    static func installScript(dir: String, logPath: String) -> String {
        let logPath = logPath.replacingOccurrences(of: "'", with: "")
        return "cd '\(dir.replacingOccurrences(of: "'", with: ""))' && { echo \"=== $(date) ===\"; for d in .; do git -C \"$d\" rev-parse --git-dir >/dev/null 2>&1 && [ -n \"$(git -C \"$d\" status --porcelain --untracked-files=no)\" ] && git -C \"$d\" fetch -q origin 2>/dev/null && [ -n \"$(git -C \"$d\" log --oneline HEAD..@{u} 2>/dev/null)\" ] && git -C \"$d\" stash push -q -m \"Flow Update $(date +%F_%H%M)\" && echo \"Lokale Änderungen in $d beiseitegelegt (git stash list)\"; done; ./update.sh; } >> '\(logPath)' 2>&1"
    }

    /// Nach dem Neustart: „Flow aktualisiert“ zeigen
    private func announceIfJustUpdated() {
        guard let from = UserDefaults.standard.string(forKey: "vf.updatedFrom") else { return }
        UserDefaults.standard.removeObject(forKey: "vf.updatedFrom")
        guard from != AppVersion.line else { return }
        log("Update: \(from) → \(AppVersion.line)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            VFNotify.shared.show(VFNotice(
                id: "update", title: "Flow ist aktuell",
                text: "Neu installiert: \(AppVersion.line). Deine Daten sind geblieben.",
                illustration: "illu_willkommen", fallbackSymbol: "checkmark.circle",
                primary: ("Super", {}), secondary: nil, timeout: 12))
        }
    }

    // MARK: Git

    /// Führt git im Ordner aus; nil bei Fehler. Nutzt die normale Git-Anmeldung (gh als Credential-Helper).
    static func git(_ dir: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GIT_TERMINAL_PROMPT"] = "0"          // nie auf eine Passwort-Eingabe warten
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) ?? "" : nil
    }
}
