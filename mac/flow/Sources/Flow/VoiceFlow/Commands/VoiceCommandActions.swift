import AppKit
import EventKit

// MARK: - Sprachbefehle: Kalender & Erinnerungen (EventKit, Zugriff wird erst beim ersten Befehl erfragt)

/// `live` schreibt in die Standard-Liste/den Standard-Kalender. `dryRun` baut dieselben EKReminder/EKEvent,
/// speichert sie aber NIE – für Tests (legt nichts in echten Kalendern an).
struct VCEventKit {
    var addReminder: (_ title: String, _ due: Date?, _ allDay: Bool, _ done: @escaping (String?) -> Void) -> Void
    var addEvent: (_ title: String, _ start: Date, _ end: Date, _ allDay: Bool, _ done: @escaping (String?) -> Void) -> Void

    static let note = "Per Sprachbefehl (Flow)"

    static func makeReminder(_ store: EKEventStore, title: String, due: Date?, allDay: Bool) -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = note
        if let due {
            let comps: Set<Calendar.Component> = allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            r.dueDateComponents = Calendar.current.dateComponents(comps, from: due)
            // Mit Uhrzeit: Hinweis zur Fälligkeit (sonst erinnert die App nicht aktiv)
            if !allDay { r.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        return r
    }

    static func makeEvent(_ store: EKEventStore, title: String, start: Date, end: Date, allDay: Bool) -> EKEvent {
        let e = EKEvent(eventStore: store)
        e.title = title
        e.isAllDay = allDay
        e.startDate = start
        e.endDate = allDay ? start : max(end, start.addingTimeInterval(60))
        e.notes = note
        return e
    }

    static let live = VCEventKit(
        addReminder: { title, due, allDay, done in
            SmartEventKit.access(.reminder) { ok, why in
                guard ok else { return done(why) }
                let store = SmartEventKit.store
                guard let cal = store.defaultCalendarForNewReminders() else { return done("Keine Erinnerungsliste gefunden") }
                let r = makeReminder(store, title: title, due: due, allDay: allDay)
                r.calendar = cal
                do { try store.save(r, commit: true); done(nil) }
                catch { log("Sprachbefehl: Erinnerung nicht gespeichert (\(error.localizedDescription))"); done("Erinnerung nicht gespeichert") }
            }
        },
        addEvent: { title, start, end, allDay, done in
            SmartEventKit.access(.event) { ok, why in
                guard ok else { return done(why) }
                let store = SmartEventKit.store
                guard let cal = store.defaultCalendarForNewEvents else { return done("Kein Kalender gefunden") }
                let e = makeEvent(store, title: title, start: start, end: end, allDay: allDay)
                e.calendar = cal
                do { try store.save(e, span: .thisEvent, commit: true); done(nil) }
                catch { log("Sprachbefehl: Termin nicht gespeichert (\(error.localizedDescription))"); done("Termin nicht gespeichert") }
            }
        })

    /// Probelauf: baut die echten EventKit-Objekte (ohne Kalender-Zugriff) und meldet sie, speichert nichts.
    static func dryRun(_ record: @escaping (String) -> Void) -> VCEventKit {
        let store = EKEventStore()   // ohne Zugriff: Objekte lassen sich bauen, aber nicht speichern
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEE dd.MM.yyyy HH:mm"
        return VCEventKit(
            addReminder: { title, due, allDay, done in
                let r = makeReminder(store, title: title, due: due, allDay: allDay)
                let dc = r.dueDateComponents
                let dueText = dc.flatMap { Calendar.current.date(from: $0) }.map { f.string(from: $0) } ?? "–"
                record("EKReminder title=„\(r.title ?? "")“ due=\(dueText) hasTime=\(dc?.hour != nil) alarms=\(r.alarms?.count ?? 0) notes=„\(r.notes ?? "")“ [NICHT gespeichert]")
                done(nil)
            },
            addEvent: { title, start, end, allDay, done in
                let e = makeEvent(store, title: title, start: start, end: end, allDay: allDay)
                let mins = Int(e.endDate.timeIntervalSince(e.startDate) / 60)
                record("EKEvent title=„\(e.title ?? "")“ start=\(f.string(from: e.startDate)) end=\(f.string(from: e.endDate)) (\(mins) min) allDay=\(e.isAllDay) notes=„\(e.notes ?? "")“ [NICHT gespeichert]")
                done(nil)
            })
    }
}

// MARK: - Sprachbefehle: an den Partner schicken (geteilter ClipVault-Tresor)
//
// Über die ClipVault-Kommandozeile (siehe clipvault/PROTOCOL.md):
//   clipvault send addText text=… source=<ich>   → {"ok":true,"id":"…"}
//   clipvault send share id=…                   → {"ok":true,…}
// CLIPVAULT_HOME wird an den Prozess weitergereicht → Tests laufen gegen einen Test-Tresor mit eigenen Meldungsnamen.

enum VCVault {
    struct Failure: Error { let message: String }
    struct SyncState { var connected: Bool; var reason: String }

    /// Das ClipVault-Programm (liegt immer im echten ~/.config/flow-clipvault; überschreibbar mit VF_CLIPVAULT_BIN)
    static var binary: URL {
        if let b = ProcessInfo.processInfo.environment["VF_CLIPVAULT_BIN"], !b.isEmpty { return URL(fileURLWithPath: (b as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow-clipvault/clipvault")
    }

    /// Aus status.txt des (Test-)Tresors: läuft ClipVault, ist gekoppelt, ist der Sync gerade verbunden?
    static func syncState(base: URL = ClipVaultClient.base) -> SyncState {
        let s = (try? String(contentsOf: base.appendingPathComponent("status.txt"), encoding: .utf8)) ?? ""
        var kv: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return SyncState(connected: false, reason: "ClipVault ist nicht installiert") }
        guard let pid = kv["pid"].flatMap({ Int32($0) }), pid > 0, kill(pid, 0) == 0 else { return SyncState(connected: false, reason: "ClipVault läuft nicht") }
        guard kv["sync"] == "cloudflare" else { return SyncState(connected: false, reason: "Tresor ist nicht gekoppelt") }
        switch kv["sync_state"] ?? "" {
        case "connected": return SyncState(connected: true, reason: "")
        case "waiting": return SyncState(connected: false, reason: "\(Identity.partner(.nominative, capitalized: true)) ist noch nicht beigetreten")
        case "offline": return SyncState(connected: false, reason: "Keine Verbindung zum Tresor")
        default: return SyncState(connected: false, reason: "Sync ist nicht verbunden")
        }
    }

    /// Text in den Verlauf legen und teilen. Läuft im Hintergrund, `done` kommt auf irgendeinem Thread.
    /// Erfolg: true = beim Server angekommen (nicht mehr „wartend“), false = liegt in der Warteschlange und geht später raus.
    static func share(_ text: String, me: String = Identity.clipVaultMe, done: @escaping (Result<Bool, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let add = run(["send", "addText", "text=\(text)", "source=\(me)"]) else { return done(.failure(Failure(message: "ClipVault antwortet nicht"))) }
            guard add["ok"] as? Bool == true, let id = add["id"] as? String, !id.isEmpty else {
                return done(.failure(Failure(message: (add["error"] as? String).map { "ClipVault: \($0)" } ?? "ClipVault hat den Text nicht angenommen")))
            }
            guard let sh = run(["send", "share", "id=\(id)"]) else { return done(.failure(Failure(message: "ClipVault antwortet nicht"))) }
            guard sh["ok"] as? Bool == true else {
                return done(.failure(Failure(message: (sh["error"] as? String).map { "Teilen fehlgeschlagen: \($0)" } ?? "Teilen fehlgeschlagen")))
            }
            done(.success(waitDelivered(id)))
        }
    }

    /// status.txt kann bis zu 30 s alt sein – darum nachsehen, ob der Eintrag wirklich hochgeladen wurde (shared.json → pending).
    static func waitDelivered(_ id: String, timeout: TimeInterval = 2.5, base: URL = ClipVaultClient.base) -> Bool {
        let url = base.appendingPathComponent("shared.json")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                let pending = ((o["pending"] as? [String]) ?? []).map { $0.lowercased() }
                let known = ((o["items"] as? [[String: Any]]) ?? []).contains { ($0["id"] as? String)?.lowercased() == id.lowercased() }
                if known && !pending.contains(id.lowercased()) { return true }
            }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    /// Ruft `clipvault …` auf und liest die letzte JSON-Zeile der Ausgabe.
    static func run(_ args: [String], timeout: TimeInterval = 6) -> [String: Any]? {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { log("Sprachbefehl: ClipVault nicht startbar (\(error.localizedDescription))"); return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o
    }
}
