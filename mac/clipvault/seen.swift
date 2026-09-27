// ClipVault — „Neu vom Partner" (gruener Punkt im Bereich „Geteilt")
//
// Gemeinsamer Gesehen-Stand mit anderen Programmen (z. B. einer Hub-/Diktat-App):
//   ~/.config/flow-clipvault/shared-seen.json   (0600, atomar ersetzt)
//   {"baseline": <unix sekunden>, "seen": ["<eintrags-id>", …]}     hoechstens 1000 ids, die neuesten bleiben
//
// NEU ist ein geteilter Eintrag, wenn ALLES gilt:
//   * vom Partner (createdBy != eigener Name, gleiche Logik wie shared.swift)
//   * nicht geloescht
//   * createdAt > baseline
//   * id steht nicht in `seen`
// Fehlt die Datei, wird sie mit baseline = jetzt angelegt (alter Bestand zaehlt nicht als neu).
// Andere Programme duerfen `seen` ergaenzen und danach `app.flowdictation.clipvault.changed` senden —
// ClipVault liest die Datei beim Oeffnen des Panels und bei jeder Aenderungs-Meldung neu.
import Cocoa

final class SharedSeen: NSObject {
    static let shared = SharedSeen()
    static let maxIds = 1000
    var path: String { CV_DIR + "shared-seen.json" }
    private(set) var baseline: Double = 0
    private(set) var seen: [String] = []          // aelteste zuerst, neueste zuletzt
    private var seenKeys = Set<String>()          // klein geschrieben (ids kommen je nach Geraet unterschiedlich)
    private var loaded = false
    private var frozen = false                    // panel-render: Stand im Speicher, Datei nicht lesen

    private struct Disk: Codable { var baseline: Double; var seen: [String] }

    /// Datei neu lesen. Rueckgabe: hat sich der Stand geaendert?
    @discardableResult func reload() -> Bool {
        if frozen { return false }
        let beforeB = baseline, beforeS = seen, wasLoaded = loaded
        if let data = FileManager.default.contents(atPath: path) {
            if let d = try? JSONDecoder().decode(Disk.self, from: data) {
                apply(d.baseline, d.seen)
            } else {
                // kaputt/fremdes Format: bisherigen Stand behalten (bzw. ab jetzt zaehlen) und sauber neu schreiben
                if !loaded { apply(Date().timeIntervalSince1970, []) }
                cvLog("Gesehen-Stand: shared-seen.json unlesbar — neu geschrieben")
                write()
            }
        } else {
            // Datei fehlt (erster Start oder bewusst geloescht): nur was ab jetzt kommt, gilt als neu
            apply(Date().timeIntervalSince1970, [])
            write()
        }
        return !wasLoaded || beforeB != baseline || beforeS != seen
    }
    private func apply(_ b: Double, _ s: [String]) {
        var list = s
        if list.count > SharedSeen.maxIds { list = Array(list.suffix(SharedSeen.maxIds)) }
        baseline = b; seen = list; seenKeys = Set(list.map { $0.lowercased() }); loaded = true
    }
    private func ensureLoaded() { if !loaded { reload() } }

    private func write() {
        guard !CV_READ_ONLY else { return }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        guard let data = try? e.encode(Disk(baseline: baseline, seen: seen)) else { return }
        try? FileManager.default.createDirectory(atPath: CV_DIR, withIntermediateDirectories: true)
        let tmp = path + ".tmp\(getpid())"
        unlink(tmp)
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        chmod(tmp, 0o600)
        if rename(tmp, path) != 0 { unlink(tmp) }
    }

    // ---- Lesen ----
    func isNew(_ s: SharedItem) -> Bool {
        ensureLoaded()
        return s.createdBy != SharedVault.shared.me && !s.deleted
            && s.createdAt.timeIntervalSince1970 > baseline && !seenKeys.contains(s.id.lowercased())
    }
    func isNew(id: String) -> Bool { SharedVault.shared.item(id).map(isNew) ?? false }
    /// neue Eintraege, neueste zuerst
    var newItems: [SharedItem] { SharedVault.shared.items.filter(isNew).sorted { $0.createdAt > $1.createdAt } }
    var newCount: Int { newItems.count }

    // ---- Markieren ----
    /// Markiert die genannten Eintraege als gesehen (nur, was gerade NEU ist). Rueckgabe: die markierten ids.
    @discardableResult func markSeen(_ ids: [String]) -> [String] {
        reload()                                            // was andere Programme inzwischen markiert haben, behalten
        var marked: [String] = []
        for id in ids {
            guard let s = SharedVault.shared.item(id), isNew(s), !marked.contains(s.id) else { continue }
            marked.append(s.id)
        }
        guard !marked.isEmpty else { return [] }
        apply(baseline, seen + marked)
        write()
        ChangeNotifier.bump()
        cvStatusWriter?()
        PanelController.shared?.seenStateChanged()
        return marked
    }
    @discardableResult func markAllSeen() -> [String] { reload(); return markSeen(newItems.map(\.id)) }

    /// Nur fuer panel-render (Nur-Lese-Modus): Stand im Speicher setzen, nichts schreiben
    func overrideForRender(baseline b: Double, seen s: [String]) { apply(b, s); frozen = true }

    /// Aenderungs-Meldungen mithoeren (andere Programme markieren ebenfalls in der Datei)
    func startWatching() {
        ensureLoaded()
        // .deliverImmediately: ClipVault ist nie die aktive App — sonst kaemen Meldungen erst verspaetet an
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(externalChange(_:)), name: ChangeNotifier.name,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }
    @objc private func externalChange(_ n: Notification) {
        DispatchQueue.main.async {
            guard self.reload() else { return }
            cvStatusWriter?()
            PanelController.shared?.seenStateChanged()
        }
    }
}
