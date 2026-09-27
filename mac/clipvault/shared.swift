// ClipVault — Geteilter Tresor (zwei Personen: du + ein Freund/Partner, Name beim Koppeln)
//
// Hier liegen NUR die Andockstellen. Die eigentliche Synchronisierung (Cloudflare Worker + Durable Object,
// Ende-zu-Ende verschluesselt) steckt in `clipvault/sync.swift` (+ Server in `clipvault/sync-worker/`):
//
//     @objc(ClipVaultSyncBackend)
//     final class SyncBackend: NSObject, SharedVaultBackend {
//         override init() { super.init() }
//         var backendName: String { "cloudflare" }
//         func start(vault: SharedVault) { … vault.applyRemote([...]) bei jeder Aenderung von aussen … }
//         func push(_ item: SharedItem) { … hochladen (deleted == true = entfernen) … vault.markSynced([item.id]) }
//         func stop() { … }
//     }
//
// ClipVault findet die Klasse beim Start ueber ihren Objective-C-Namen „ClipVaultSyncBackend"
// (SharedVaultHook.bootstrap) — install.sh baut alle clipvault/*.swift zusammen.
// Ohne sync.swift bleibt alles lokal: Geteiltes erscheint im Bereich „Geteilt" mit „wartet auf Sync".
import Cocoa
import CryptoKit

// MARK: - Modell
struct SharedItem: Codable, Equatable {
    enum Kind: String, Codable { case text, image, link, file }
    let id: String                 // = id des urspruenglichen Verlaufs-Eintrags (UUID, weltweit eindeutig; bei mehreren Dateien abgeleitet)
    var kind: Kind
    var text: String?              // text/link: Inhalt · image/file: optionaler Begleittext (z. B. OCR)
    var imagePNG: Data? = nil      // nur kind == image. In shared.json NICHT enthalten (liegt als shared/<id>.png)
    var fileName: String? = nil    // nur kind == file
    var fileData: Data? = nil      // nur kind == file, nur kleine Eintraege (v1). Liegt als shared/files/<id>/<fileName>
    var createdBy: String          // Vorname des Absenders (shared-me.txt bzw. macOS-Konto)
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool = false
    var deleted: Bool = false      // weiches Loeschen (damit die Loeschung auch beim anderen ankommt)
    // ---- seit 26.09.2026: Dateien jeder Art bis 200 MB (alle optional -> alte shared.json bleibt lesbar) ----
    var size: Int64? = nil         // Klartext-Bytes (Bild/Datei)
    var parts: Int? = nil          // > 0: grosser Eintrag, liegt auf dem Server in Teilen (je 1 MiB, einzeln verschluesselt)
    var content: String? = nil     // Kennung des Inhalts (32 hex) — gleich = dieselben Teile (Fortsetzen, Anheften ohne Neu-Upload)
    var sourceId: String? = nil    // Verlaufs-Eintrag, aus dem geteilt wurde (mehrere Dateien = mehrere geteilte Eintraege)
    var serverGone: Bool? = nil    // Teile auf dem Server abgelaufen / aufgeraeumt (lokale Kopien bleiben)
    var expiresAt: Double? = nil   // Unix-s: wann die Teile auf dem Server ablaufen (nur grosse, nicht angeheftete)
    var uploadError: String? = nil // nur lokal: Hochladen endgueltig gescheitert (z. B. Speicher voll)
    enum CodingKeys: String, CodingKey { case id, kind, text, fileName, createdBy, createdAt, updatedAt, pinned, deleted,
                                          size, parts, content, sourceId, serverGone, expiresAt, uploadError }
    var isBig: Bool { (parts ?? 0) > 0 }
}

/// Laufende Uebertragung eines grossen Eintrags (nur im Speicher)
struct SharedTransfer: Equatable {
    enum Dir { case up, down }
    var dir: Dir
    var done: Int64
    var total: Int64
    var startedAt = Date()
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}
/// Belegung des geteilten Speichers (vom Server, /info)
struct SharedStorage: Equatable {
    var used: Int64 = 0
    var quota: Int64 = 0
    var bigCount = 0
    var bigBytes: Int64 = 0
}

/// Die Synchronisierung (sync.swift) erfuellt dieses Protokoll.
protocol SharedVaultBackend: AnyObject {
    /// Kurzer Name fuer Anzeige/doctor, z. B. "Supabase"
    var backendName: String { get }
    /// Einmal beim Start. Das Backend meldet danach Aenderungen von aussen mit `vault.applyRemote(_:)`
    /// (gern mehrfach, auch den ganzen Bestand) — auf dem Main-Thread.
    func start(vault: SharedVault)
    /// Lokale Aenderung hochladen: neu, geaendert (pinned) oder `deleted == true`.
    /// imagePNG/fileData sind befuellt. Nach Erfolg `vault.markSynced([item.id])` aufrufen.
    func push(_ item: SharedItem)
    func stop()
}

/// Optional: Backend beantwortet eigene Befehle (pairCreate, pairJoin, unpair, syncStatus …) asynchron.
protocol SharedVaultCommandHandler: AnyObject {
    func handlesCommand(_ action: String) -> Bool
    func handleCommand(_ action: String, _ params: [String: Any], reply: @escaping (CommandChannel.Result) -> Void)
}
/// Optional: Backend liefert Zeilen fuer status.txt (z. B. `sync=supabase`, `sync_state=connected`).
/// Ohne diese Angabe schreibt ClipVault `sync=<backendName>`.
protocol SharedVaultStatusProvider: AnyObject {
    var statusLines: [String] { get }
}
/// Optional: Kopplungs-Knopf + Zustandszeile im Panel-Bereich „Geteilt" (ohne Hub).
protocol SharedVaultPanelUI: AnyObject {
    var panelStatusText: String { get }
    var wantsPairButton: Bool { get }
    func presentPairingDialog()
}
/// Optional: Dateien in Teilen (Laden auf Abruf, Abbrechen, Aufraeumen, Speicherstand)
protocol SharedVaultTransferBackend: AnyObject {
    func download(_ id: String)
    func cancelTransfer(_ id: String)
    /// Teile grosser Eintraege vom Server loeschen (Eintraege + lokale Kopien bleiben)
    func evict(_ ids: [String])
    func refreshStorage()
}
/// Wer status.txt schreibt (App bzw. Test-Agent) — das Backend ruft das bei jedem Zustandswechsel.
var cvStatusWriter: (() -> Void)?
func cvSyncStatusLines() -> [String] {
    guard let b = SharedVaultHook.backend else { return ["sync=keins"] }
    if let p = b as? SharedVaultStatusProvider { return p.statusLines }
    return ["sync=\(b.backendName)"]
}

enum ShareError: Error {
    case missing, tooLarge(String), unsupported(String)
    var message: String {
        switch self {
        case .missing: return "Eintrag nicht gefunden"
        case .tooLarge(let s), .unsupported(let s): return s
        }
    }
}

// MARK: - Einstieg fuer Panel, Befehle und Sync
enum SharedVaultHook {
    private(set) static var backend: SharedVaultBackend?
    static var transfers: SharedVaultTransferBackend? { backend as? SharedVaultTransferBackend }

    /// Beim App-Start: gibt es eine Sync-Klasse (sync.swift)? Dann einklinken.
    static func bootstrap() {
        if let cls = NSClassFromString("ClipVaultSyncBackend") as? NSObject.Type, let b = cls.init() as? SharedVaultBackend {
            install(b)
        }
    }
    static func install(_ b: SharedVaultBackend) {
        backend?.stop()
        backend = b
        cvLog("Geteilter Tresor: Backend \(b.backendName) eingeklinkt")
        b.start(vault: SharedVault.shared)
        // was offline geteilt wurde, jetzt nachreichen
        for id in SharedVault.shared.pending { if let it = SharedVault.shared.item(id) { b.push(it) } }
    }
    /// Teilen: Text/Link, Bild, Datei(en) jeder Art (bis 200 MB je Datei), Ordner werden als .zip geteilt.
    @discardableResult static func share(_ item: ClipItem) -> Result<[SharedItem], ShareError> {
        let r = SharedVault.shared.share(item)
        if case .success(let list) = r { list.forEach { backend?.push($0) } }
        return r
    }
    /// Freigabe zuruecknehmen — `id` = geteilter Eintrag ODER Verlaufs-Eintrag (dann alle seine Dateien)
    static func unshare(_ id: String) {
        for s in SharedVault.shared.unshare(id: id) {
            transfers?.cancelTransfer(s.id)
            backend?.push(s)
        }
    }
    static func setPinned(_ id: String, _ p: Bool) {
        if let s = SharedVault.shared.setPinned(id: id, p) { backend?.push(s) }
    }
    /// „Laden": grossen Eintrag vom Server holen
    static func download(_ id: String) { transfers?.download(id) }
    static func cancelTransfer(_ id: String) { transfers?.cancelTransfer(id) }
    /// „Große Dateien aufräumen": Teile grosser, nicht angehefteter Eintraege vom Server loeschen
    @discardableResult static func cleanupBig() -> [SharedItem] {
        let list = SharedVault.shared.cleanupCandidates
        if !list.isEmpty { transfers?.evict(list.map(\.id)) }
        return list
    }
}

// MARK: - Lokaler Bestand  (~/.config/flow-clipvault/shared.json + shared/)
final class SharedVault {
    static let shared = SharedVault()
    static let maxShareBytes: Int64 = 200 * 1024 * 1024     // pro Datei
    static let v1MaxBytes = 4 * 1024 * 1024                 // bis hierher ein Stueck (auch fuer aeltere Clients lesbar)
    static let partSize = 1024 * 1024                       // groessere in Teilen zu 1 MiB
    static let autoDownloadMax: Int64 = 20 * 1024 * 1024    // bis hierher laedt der Empfaenger sofort, sonst „Laden"
    let dir = Store.shared.dir.appendingPathComponent("shared")
    var filesDir: URL { dir.appendingPathComponent("files") }
    var jsonURL: URL { Store.shared.dir.appendingPathComponent("shared.json") }
    private(set) var items: [SharedItem] = []
    private(set) var pending = Set<String>()          // lokal geaendert, vom Backend noch nicht bestaetigt
    private var thumbs = [String: NSImage]()
    /// Uebertragungen (grosse Eintraege), Speicherstand des Servers
    private(set) var transfers: [String: SharedTransfer] = [:]
    var storage: SharedStorage? { didSet { if storage != oldValue { cvStatusWriter?(); PanelController.shared?.storageChanged() } } }
    /// Kopieren eines noch nicht geladenen Eintrags: nach dem Laden automatisch in die Zwischenablage
    var pendingCopy: String?
    /// Wer bin ich / mit wem teile ich? (ueberschreibbar: shared-me.txt / shared-partner.txt)
    let me: String
    /// Name des Freundes/Partners, mit dem der Tresor geteilt wird – wird beim Koppeln eingegeben (shared-partner.txt)
    private(set) var partner: String

    init() {
        func cfg(_ f: String) -> String? {
            (try? String(contentsOf: Store.shared.dir.appendingPathComponent(f), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        me = cfg("shared-me.txt") ?? first
        partner = cfg("shared-partner.txt") ?? "Partner"
        load()
    }

    /// Partner-Namen setzen (beim Koppeln oder `clipvault partner <name>`). Leer = zurück auf „Partner“.
    func setPartner(_ raw: String) {
        let n = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let url = Store.shared.dir.appendingPathComponent("shared-partner.txt")
        if n.isEmpty { try? FileManager.default.removeItem(at: url); partner = "Partner" }
        else {
            FileManager.default.createFile(atPath: url.path, contents: Data(n.utf8), attributes: [.posixPermissions: 0o600])
            partner = n
        }
        cvStatusWriter?()
    }

    private struct Disk: Codable { var version = 1; var pending: [String]; var items: [SharedItem] }
    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }

    func load() {
        guard let data = try? Data(contentsOf: jsonURL), let d = try? SharedVault.decoder().decode(Disk.self, from: data) else { return }
        items = d.items; pending = Set(d.pending); thumbs.removeAll()
    }
    private func persist() {
        guard !CV_READ_ONLY else { return }
        let d = Disk(pending: Array(pending).sorted(), items: items)
        if let data = try? SharedVault.encoder().encode(d) { try? data.write(to: jsonURL, options: .atomic) }
    }
    private func changed() {
        persist(); ChangeNotifier.bump()
        cvStatusWriter?()                                  // shared_new= aktuell halten
        PanelController.shared?.refreshAfterExternalChange()
    }

    // ---- Lesen ----
    func item(_ id: String) -> SharedItem? { items.first { $0.id == id } ?? items.first { $0.id.lowercased() == id.lowercased() } }
    /// Sichtbar im Panel: nicht geloescht, Angeheftete zuerst, dann neueste zuerst
    var visible: [SharedItem] {
        items.filter { !$0.deleted }.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.updatedAt > b.updatedAt }
    }
    func imageURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).png") }
    /// Wohin die Datei gehoert (neu: shared/files/<id>/<name>; aeltere Fassung: shared/<id>/<name>)
    func fileURL(_ it: SharedItem) -> URL? {
        guard let n = it.fileName else { return nil }
        let u = filesDir.appendingPathComponent(it.id).appendingPathComponent(n)
        if !FileManager.default.fileExists(atPath: u.path) {
            let legacy = dir.appendingPathComponent(it.id).appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        }
        return u
    }
    /// Die lokale Datei (Bild-PNG bzw. Datei), falls vorhanden
    func localURL(_ it: SharedItem) -> URL? {
        let u: URL? = it.kind == .image ? imageURL(it.id) : (it.kind == .file ? fileURL(it) : nil)
        guard let url = u, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func isLocal(_ it: SharedItem) -> Bool { localURL(it) != nil }
    /// Groesse fuer die Anzeige (Klartext)
    func byteSize(_ it: SharedItem) -> Int64? {
        if let s = it.size { return s }
        guard let u = localURL(it) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? nil
    }
    func thumb(_ it: SharedItem) -> NSImage? {
        guard it.kind == .image else { return nil }
        if let t = thumbs[it.id] { return t }
        guard let t = loadThumb(url: imageURL(it.id)) else { return nil }
        if thumbs.count > 40 { thumbs.removeAll() }
        thumbs[it.id] = t; return t
    }
    /// Eintrag mit geladenen Bild-/Dateidaten (nur kleine Eintraege — grosse laedt der Sync teilweise direkt von Platte)
    func withBlobs(_ it: SharedItem) -> SharedItem {
        var s = it
        guard !s.isBig else { return s }
        if s.kind == .image, s.imagePNG == nil { s.imagePNG = try? Data(contentsOf: imageURL(s.id)) }
        if s.kind == .file, s.fileData == nil, let u = fileURL(s) { s.fileData = try? Data(contentsOf: u) }
        return s
    }
    /// Grosse, nicht angeheftete Eintraege, deren Teile noch auf dem Server liegen („Große Dateien aufräumen")
    var cleanupCandidates: [SharedItem] {
        items.filter { !$0.deleted && $0.isBig && !$0.pinned && $0.serverGone != true && $0.uploadError == nil && ($0.size ?? 0) > SharedVault.autoDownloadMax && !pending.contains($0.id) }
    }

    // ---- Dateien: Rechte + Kennungen ----
    static func privateDir(_ u: URL) {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(u.path, 0o700)
    }
    static func privateFile(_ u: URL) { chmod(u.path, 0o600) }
    /// stabile, weltweit eindeutige id fuer die n-te Datei eines Verlaufs-Eintrags
    static func derivedId(_ base: String, _ n: Int) -> String {
        if n == 0 { return base }
        var b = [UInt8](SHA256.hash(data: Data("clipvault-multi|\(base.lowercased())|\(n)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50; b[8] = (b[8] & 0x3F) | 0x80        // UUID v5-Form
        let t: uuid_t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        return UUID(uuid: t).uuidString
    }
    private static func newContentId() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    /// Teilen-Metadaten fuer eine lokal liegende Datei/ein Bild: gross -> Teile + neue Inhalts-Kennung
    private func stamp(_ s: inout SharedItem, bytes: Int64) {
        s.size = bytes; s.uploadError = nil; s.serverGone = nil; s.expiresAt = nil
        if bytes > Int64(SharedVault.v1MaxBytes) {
            s.parts = Int((bytes + Int64(SharedVault.partSize) - 1) / Int64(SharedVault.partSize))
            s.content = SharedVault.newContentId()
        } else { s.parts = nil; s.content = nil }
    }

    // ---- Lokale Aenderungen ----
    func share(_ clip: ClipItem) -> Result<[SharedItem], ShareError> {
        guard !CV_READ_ONLY else { return .failure(.missing) }
        let now = Date()
        func base(_ id: String) -> SharedItem {
            var s = SharedItem(id: id, kind: .text, text: nil, createdBy: me, createdAt: now, updatedAt: now)
            if let old = item(id) { s.createdAt = old.createdAt; s.pinned = old.pinned }
            return s
        }
        var out: [SharedItem] = []
        switch clip.kind {
        case .text:
            guard let t = clip.text, !t.isEmpty else { return .failure(.unsupported("Leerer Text")) }
            var s = base(clip.id)
            s.kind = soleURL(t) != nil ? .link : .text; s.text = t
            out.append(s)
        case .image:
            guard let url = Store.shared.imageURL(clip), FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
            var s = base(clip.id)
            SharedVault.privateDir(dir)
            let dest = imageURL(s.id)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return .failure(.missing) }
            SharedVault.privateFile(dest)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil) ?? 0
            if bytes > SharedVault.maxShareBytes { try? FileManager.default.removeItem(at: dest); return .failure(.tooLarge("Bild zu groß zum Teilen (max. 200 MB)")) }
            s.kind = .image; s.text = (clip.ocrText?.isEmpty == false) ? clip.ocrText : nil
            stamp(&s, bytes: bytes)
            thumbs[s.id] = nil
            out.append(s)
        case .file:
            guard let refs = clip.files, !refs.isEmpty else { return .failure(.missing) }
            var skipped: [String] = []
            for (n, r) in refs.enumerated() {
                let src: URL? = FileManager.default.fileExists(atPath: r.orig) ? URL(fileURLWithPath: r.orig)
                    : r.stored.map { Store.shared.dir.appendingPathComponent($0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                guard let u = src else { skipped.append(r.name); continue }
                let id = SharedVault.derivedId(clip.id, n)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                if isDir.boolValue { zipFolderAndShare(u, id: id, sourceId: clip.id); continue }   // kommt gleich nach
                let bytes = ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? nil) ?? 0
                if bytes > SharedVault.maxShareBytes { skipped.append(r.name); continue }
                var s = base(id)
                guard placeFile(u, id: id, name: r.name) else { skipped.append(r.name); continue }
                s.kind = .file; s.fileName = r.name; s.sourceId = refs.count > 1 ? clip.id : nil
                stamp(&s, bytes: bytes)
                out.append(s)
            }
            let folders = refs.enumerated().filter { n, r in var d: ObjCBool = false; return FileManager.default.fileExists(atPath: r.orig, isDirectory: &d) && d.boolValue }.count
            if out.isEmpty && folders == 0 {
                return .failure(skipped.isEmpty ? .missing : .tooLarge(refs.count == 1 ? "Datei zu groß zum Teilen (max. 200 MB)" : "Keine Datei teilbar (max. 200 MB je Datei)"))
            }
        }
        for s in out { items.removeAll { $0.id == s.id }; items.insert(s, at: 0); pending.insert(s.id) }
        Store.shared.setShared(id: clip.id, true)
        changed()
        return .success(out)
    }
    /// Datei in den Tresor-Ordner legen (APFS: Klon, kostet keinen Platz), Rechte 0600 / Ordner 0700
    private func placeFile(_ src: URL, id: String, name: String) -> Bool {
        let d = filesDir.appendingPathComponent(id)
        SharedVault.privateDir(filesDir)
        try? FileManager.default.removeItem(at: d)
        SharedVault.privateDir(d)
        let dest = d.appendingPathComponent(SharedVault.safeName(name))
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return false }
        SharedVault.privateFile(dest)
        return true
    }
    static func safeName(_ n: String) -> String {
        var s = n.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\0", with: "")
        while s.hasPrefix(".") { s.removeFirst() }
        s = String(s.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Datei" : s
    }
    /// Ordner als .zip teilen (ditto im Hintergrund, danach wie eine Datei)
    private func zipFolderAndShare(_ folder: URL, id: String, sourceId: String) {
        let name = SharedVault.safeName(folder.lastPathComponent) + ".zip"
        let d = filesDir.appendingPathComponent(id)
        SharedVault.privateDir(filesDir); try? FileManager.default.removeItem(at: d); SharedVault.privateDir(d)
        let dest = d.appendingPathComponent(name)
        let me = self.me
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, dest.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil) ?? 0
            DispatchQueue.main.async {
                guard p.terminationStatus == 0, bytes > 0 else { if !CV_HEADLESS { Toast.shared.show("Ordner ließ sich nicht packen") }; return }
                guard bytes <= SharedVault.maxShareBytes else {
                    try? FileManager.default.removeItem(at: d)
                    if !CV_HEADLESS { Toast.shared.show("Ordner zu groß zum Teilen (max. 200 MB gepackt)") }; return
                }
                SharedVault.privateFile(dest)
                let now = Date()
                var s = SharedItem(id: id, kind: .file, text: nil, createdBy: me, createdAt: now, updatedAt: now)
                s.fileName = name; s.sourceId = id == sourceId ? nil : sourceId
                self.stamp(&s, bytes: bytes)
                self.items.removeAll { $0.id == s.id }; self.items.insert(s, at: 0); self.pending.insert(s.id)
                self.changed()
                SharedVaultHook.backend?.push(s)
            }
        }
    }
    /// Weich loeschen (damit die Loeschung beim anderen ankommt). `id` = geteilter Eintrag oder Verlaufs-Eintrag.
    func unshare(id: String) -> [SharedItem] {
        let key = id.lowercased()
        let hits = items.indices.filter { !items[$0].deleted && (items[$0].id.lowercased() == key || items[$0].sourceId?.lowercased() == key) }
        Store.shared.setShared(id: id, false)
        for i in hits { if let src = items[i].sourceId { Store.shared.setShared(id: src, false) } }
        var out: [SharedItem] = []
        for i in hits {
            items[i].deleted = true; items[i].updatedAt = Date(); items[i].uploadError = nil; pending.insert(items[i].id)
            removeBlobs(items[i].id); transfers[items[i].id] = nil
            out.append(items[i])
        }
        if !out.isEmpty { changed() }
        return out
    }
    func setPinned(id: String, _ p: Bool) -> SharedItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[i].pinned = p; items[i].updatedAt = Date(); pending.insert(id); changed()
        return items[i]
    }
    /// Hochladen erneut versuchen (nach „Speicher voll" o. ae.)
    func retryUpload(id: String) -> SharedItem? {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].deleted else { return nil }
        items[i].uploadError = nil; items[i].updatedAt = Date(); pending.insert(id); changed()
        return items[i]
    }
    private func removeBlobs(_ id: String) {
        guard !CV_READ_ONLY else { return }
        try? FileManager.default.removeItem(at: imageURL(id))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
        try? FileManager.default.removeItem(at: filesDir.appendingPathComponent(id))
        thumbs[id] = nil
    }

    // ---- Vom Backend ----
    /// Entfernte Eintraege uebernehmen (neuere updatedAt gewinnt). Bild-/Dateidaten werden auf Platte gelegt.
    func applyRemote(_ remote: [SharedItem]) {
        var touched = false
        for var r in remote {
            var old: SharedItem?
            if let i = items.firstIndex(where: { $0.id.lowercased() == r.id.lowercased() }) {
                old = items[i]
                // lokal neuer -> behalten. Ausnahme: eine aeltere Fassung kannte den grossen Eintrag nur als Hinweis-Text
                let wasHint = r.isBig && !items[i].isBig && items[i].kind == .text && !items[i].deleted
                if r.updatedAt < items[i].updatedAt && !wasHint { continue }
                var cmp = r; cmp.imagePNG = nil; cmp.fileData = nil
                if r.updatedAt == items[i].updatedAt && cmp == items[i] { pending.remove(items[i].id); continue }
            }
            SharedVault.privateDir(dir)
            if r.deleted { removeBlobs(r.id) }
            else if !CV_READ_ONLY {
                // anderer Inhalt als die lokale Kopie (neu geteilt) -> alte Kopie weg, wird neu geladen
                if let o = old, o.content != r.content || o.fileName != r.fileName || (o.isBig != r.isBig) { if r.isBig || o.isBig { removeBlobs(r.id) } }
                if let png = r.imagePNG { let u = imageURL(r.id); try? png.write(to: u, options: .atomic); SharedVault.privateFile(u); thumbs[r.id] = nil }
                if let fd = r.fileData, let u = fileURL(r) {
                    SharedVault.privateDir(filesDir); SharedVault.privateDir(u.deletingLastPathComponent())
                    try? fd.write(to: u, options: .atomic); SharedVault.privateFile(u)
                }
                if r.size == nil, let d = r.imagePNG ?? r.fileData { r.size = Int64(d.count) }
            }
            r.imagePNG = nil; r.fileData = nil                                 // RAM schlank halten
            items.removeAll { $0.id.lowercased() == r.id.lowercased() }; items.append(r)
            pending.remove(r.id); touched = true
            if Store.shared.item(r.id) != nil { Store.shared.setShared(id: r.id, !r.deleted) }
            if let src = r.sourceId, Store.shared.item(src) != nil {
                Store.shared.setShared(id: src, items.contains { $0.sourceId == src && !$0.deleted })
            }
        }
        if touched { items.sort { $0.updatedAt > $1.updatedAt }; changed() }
    }
    /// Grabstein ohne Inhalt, den nichts mehr braucht (so legen aeltere Fassungen auch gemeinsame Namen ab, vocab.swift).
    /// Das Nachholen behandelt solche ids als unbekannt -> ein gemeinsamer Name dahinter wird einmal richtig eingelesen.
    func isHiddenTombstone(_ s: SharedItem) -> Bool {
        s.deleted && s.kind == .text && (s.text ?? "").isEmpty && s.fileName == nil && !pending.contains(s.id)
    }
    /// Grabstein-Platzhalter eines gemeinsamen Namens entfernen (war nie sichtbar)
    func forgetHidden(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id.lowercased() == id.lowercased() }), isHiddenTombstone(items[i]) else { return }
        items.remove(at: i); persist()
    }
    /// Metadaten vom Server (nicht verschluesselt, nicht Teil des Eintrags): Teile abgelaufen? wann?
    func setServerMeta(_ id: String, gone: Bool, expiresAt: Double?) {
        guard let i = items.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else { return }
        let g: Bool? = gone ? true : nil
        guard items[i].serverGone != g || items[i].expiresAt != expiresAt else { return }
        items[i].serverGone = g; items[i].expiresAt = expiresAt
        changed()
    }
    /// Hochladen endgueltig gescheitert (Speicher voll, zu gross …) -> Eintrag bleibt lokal, zeigt den Grund
    func markUploadFailed(_ id: String, _ msg: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].uploadError = msg; pending.remove(id); transfers[id] = nil
        changed()
    }
    /// Backend bestaetigt: diese Eintraege sind oben angekommen
    func markSynced(_ ids: [String]) {
        let before = pending.count
        ids.forEach { pending.remove($0) }
        if pending.count != before { changed() }
    }
    /// Datei fertig geladen (Teile entschluesselt + zusammengesetzt)
    func downloadFinished(_ id: String) {
        transfers[id] = nil; thumbs[id] = nil
        changed()
        if pendingCopy?.lowercased() == id.lowercased() {
            pendingCopy = nil
            if !CV_HEADLESS { copyToPasteboard(id: id) }
        }
    }

    // ---- Uebertragungen (Fortschritt fuer Panel/status.txt) ----
    private var lastTransferNote = Date.distantPast
    func setTransfer(_ id: String, _ t: SharedTransfer?) {
        let had = transfers[id] != nil
        transfers[id] = t
        if t == nil || !had {
            cvStatusWriter?()
            PanelController.shared?.transferChanged(id, structural: true)
        } else {
            PanelController.shared?.transferChanged(id, structural: false)
            if Date().timeIntervalSince(lastTransferNote) > 1 { lastTransferNote = Date(); cvStatusWriter?() }
        }
    }

    // ---- Kopieren ----
    /// `pb`: normalerweise die allgemeine Zwischenablage; Tests nutzen eine eigene.
    @discardableResult func copyToPasteboard(id: String, pasteboard: NSPasteboard = .general) -> Bool {
        guard let s = item(id), !s.deleted else { return false }
        let general = pasteboard == NSPasteboard.general
        if (s.kind == .file || s.kind == .image), !isLocal(s) {
            // noch nicht geladen: laden, danach automatisch kopieren
            guard s.isBig, s.serverGone != true else { if general && !CV_HEADLESS { Toast.shared.show("Datei nicht mehr verfügbar") }; return false }
            pendingCopy = s.id
            SharedVaultHook.download(s.id)
            if general && !CV_HEADLESS { Toast.shared.show("Wird geladen … danach in der Zwischenablage") }
            return true
        }
        let pb = pasteboard; pb.clearContents()
        switch s.kind {
        case .text, .link: pb.setString(s.text ?? "", forType: .string)
        case .image:
            guard let d = try? Data(contentsOf: imageURL(s.id)) else { return false }
            pb.setData(d, forType: .png)
        case .file:
            // echte Datei-URL: Einfuegen in Finder, Mail, WhatsApp … legt die Datei ab / haengt sie an
            guard let u = localURL(s) else { return false }
            pb.writeObjects([u as NSURL])
        }
        if general {
            AppState.shared.lastChange = pb.changeCount   // nicht als neuer Verlaufs-Eintrag erfassen
            if !CV_HEADLESS { Toast.shared.show(s.kind == .file ? "Datei in Zwischenablage" : (s.kind == .image ? "Bild in Zwischenablage" : "In Zwischenablage")) }
            SharedSeen.shared.markSeen([id])              // kopiert = gesehen (Klick, Cmd+1-9, Kopieren, Befehl copy)
        }
        return true
    }
    /// „In Downloads sichern": Kopie mit freiem Namen in ~/Downloads (Rueckgabe: Ziel)
    func saveToDownloads(id: String) -> URL? {
        guard let s = item(id), let src = localURL(s) else { return nil }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        var name = s.kind == .image ? "Geteilt von \(s.createdBy) \(SharedVault.stampFmt.string(from: s.createdAt)).png" : (s.fileName ?? src.lastPathComponent)
        name = SharedVault.safeName(name)
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var dest = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"); n += 1
        }
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return nil }
        chmod(dest.path, 0o644)
        return dest
    }
    static let stampFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "yyyy-MM-dd HH.mm"; return f }()
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
