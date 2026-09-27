// ClipVault — Echtzeit-Sync des geteilten Tresors (du <-> ein Freund/Partner) ueber deinen eigenen Cloudflare Worker
//
// Server: clipvault/sync-worker (ein SQLite-Durable-Object pro Tresor). Er sieht NUR Chiffrat.
//   * Ende-zu-Ende: AES-GCM-256 (CryptoKit). Tresor-Schluessel + Zugangs-Token liegen NUR im Schluesselbund.
//     Verschluesselt wird der ganze Eintrag (Art, Text, Bild-/Dateibytes, Absender, Zeiten, angeheftet, geloescht).
//     Zusatzdaten (AAD) binden jedes Chiffrat an Tresor + Eintrags-id -> der Server kann nichts vertauschen.
//   * Kopplung: `pairCreate` erzeugt Tresor + Einladung (15 min). Der Code traegt Worker-URL, Tresor-id,
//     Beitritts-Geheimnis und Tresor-Schluessel. Nico: `clipvault pair join <code>` (oder Panel -> Geteilt -> Koppeln).
//   * Live: WebSocket /v/<tresor>/ws (Ping alle 30 s, Wiederverbinden mit Backoff) + Nachholen ueber
//     /since (beim Verbinden, alle 60 s, nach Aufwachen/Netzwechsel). Warteschlange: sync-queue.json (nur ids).
//   * Konflikte: letzter Schreiber gewinnt (updatedAt), Loeschen = Grabstein.
// Dateien (alle 0600, KEINE Geheimnisse): sync.json (URL, Tresor-id, Geraete-id, Cursor), sync-queue.json,
// sync-pairing.json (nur waehrend ein Code angezeigt wird — der Code IST geheim, 15 min, danach weg).
// Protokolliert werden nie Inhalte oder Schluessel.
import Cocoa
import CryptoKit
import Security
import Network

/// Test-/Zweitgeraet ohne Oberflaeche (clipvault sync-agent): keine Toasts, kein Panel
var CV_HEADLESS = false

private func syncLog(_ msg: String) { DispatchQueue.main.async { cvLog("Sync: " + msg) } }
private let SYNC_DEBUG = ProcessInfo.processInfo.environment["CLIPVAULT_SYNC_DEBUG"] == "1"
private func syncDebug(_ msg: @autoclosure () -> String) { if SYNC_DEBUG { syncLog("[debug] " + msg()) } }

// MARK: - Dateien
enum SyncFiles {
    static var config: String { CV_DIR + "sync.json" }
    static var queue: String { CV_DIR + "sync-queue.json" }
    static var pairing: String { CV_DIR + "sync-pairing.json" }
    static var notify: String { CV_DIR + "sync-notify.txt" }

    /// atomar + 0600 (temp-Datei mit Rechten anlegen, dann umbenennen)
    @discardableResult static func writePrivate(_ data: Data, _ path: String) -> Bool {
        let tmp = path + ".tmp\(getpid())"
        unlink(tmp)
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        chmod(tmp, 0o600)
        if rename(tmp, path) != 0 { unlink(tmp); return false }
        return true
    }
}

// MARK: - Konfiguration (sync.json — nicht geheim)
struct SyncConfig: Codable {
    var url: String?            // Worker-URL des EIGENEN Workers, z. B. https://flow-clipvault-sync.<konto>.workers.dev
    var vaultId: String?        // UUID (klein)
    var deviceId: String?       // UUID (klein), pro Mac
    var cursor: Int64?          // Serverzeit (ms) des zuletzt nachgeholten Eintrags
    var partnerJoined: Bool?
    var proto: Int?             // 2 = kennt grosse Eintraege, 3 = kennt gemeinsame Namen (je einmal alles neu nachholen, was aeltere Fassungen nur als Hinweis/Grabstein kannten)
    static func load() -> SyncConfig {
        var c = (try? Data(contentsOf: URL(fileURLWithPath: SyncFiles.config))).flatMap { try? JSONDecoder().decode(SyncConfig.self, from: $0) }
            ?? SyncConfig()
        if c.deviceId == nil { c.deviceId = UUID().uuidString.lowercased(); c.save() }
        return c
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(self) { SyncFiles.writePrivate(d, SyncFiles.config) }
    }
}

// MARK: - Schluesselbund
// Warum ueber /usr/bin/security statt SecItem*: macOS haengt an jeden Eintrag eine Partitionsliste mit der
// Code-Signatur des Erzeugers. ClipVault wird mit swiftc gebaut und ad hoc signiert -> nach JEDEM Neubau ein
// neuer cdhash -> macOS fragt „clipvault moechte auf den Schluesselbund zugreifen" (und der Aufruf blockiert).
// Eintraege, die das Apple-Werkzeug `security` anlegt, tragen die stabile Partition „apple-tool:" -> Lesen ueber
// `security` fragt nie nach, egal wie oft ClipVault neu gebaut wird. `-A`: fuer Programme dieses Benutzers ohne
// Nachfrage (Schutz = Anmeldung am Mac, gesperrter Schluesselbund; derselbe Rahmen wie der Klartext-Verlauf).
// Geheimnisse gehen per stdin an `security -i` (nie als Programm-Argument sichtbar), Werte als Hex.
enum SyncKeychain {
    static let service: String = {
        let env = ProcessInfo.processInfo.environment
        if let s = env["CLIPVAULT_KEYCHAIN_SUFFIX"], !s.isEmpty { return "app.flowdictation.clipvault.sync." + s.filter { $0.isLetter || $0.isNumber } }
        if let h = CV_HOME_OVERRIDE { return "app.flowdictation.clipvault.sync.test\(UInt32(truncatingIfNeeded: h.hashValueStable))" }
        return "app.flowdictation.clipvault.sync"
    }()
    private static let tool = "/usr/bin/security"

    /// `security` mit Zeitlimit ausfuehren (falls doch ein Dialog kaeme, haengt ClipVault nicht)
    private static func run(_ args: [String], stdin: String? = nil, timeout: Double = 8) -> (Int32, String) {
        let t0 = Date(); defer { syncDebug("security \(args.first ?? "") \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(), inp = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = inp
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (-1, "") }
        if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)) }
        try? inp.fileHandleForWriting.close()
        // stdout parallel leeren (sonst koennte ein volles Rohr den Prozess blockieren)
        final class Box { var data = Data() }
        let box = Box(), readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { box.data = out.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            syncLog("Schluesselbund antwortet nicht (Zeitlimit, \(args.first ?? ""), laeuft noch: \(p.isRunning))")
            p.terminate(); return (-2, "")
        }
        _ = readers.wait(timeout: .now() + 1)          // Prozess ist beendet -> EOF folgt sofort
        return (p.terminationStatus, String(data: box.data, encoding: .utf8) ?? "")
    }
    static func get(_ account: String) -> Data? {
        let (st, out) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard st == 0 else { if st != 44 { syncLog("Schluesselbund lesen fehlgeschlagen (\(st))") }; return nil }   // 44 = nicht vorhanden
        let hex = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = PairCode.hexData(hex)
        return d.count * 2 == hex.count && !d.isEmpty ? d : nil
    }
    /// loeschen -> neu anlegen -> zuruecklesen. Kein `-U`: einen BESTEHENDEN Eintrag zu aendern kann einen
    /// Dialog ausloesen; ein frisch angelegter gehoert `security` (Partition apple-tool:) und fragt nie.
    @discardableResult static func set(_ account: String, _ data: Data) -> Bool {
        for attempt in 1...2 {
            delete(account)
            let cmd = "add-generic-password -A -s \(service) -a \(account) -l ClipVault-Sync -j clipvault -w \(data.hex)\n"
            let (st, _) = run(["-i"], stdin: cmd)
            if st == 0, get(account) == data { return true }
            syncLog("Schluesselbund schreiben fehlgeschlagen (Versuch \(attempt), \(st))")
        }
        return false
    }
    static func delete(_ account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }
}

// MARK: - Fehler
struct SyncError: Error {
    var message: String
    var status: Int = 0
    var network = false
    static func http(_ s: Int, _ m: String) -> SyncError { SyncError(message: m, status: s) }
}

// MARK: - Nutzlast: ein Eintrag als Klartext-Paket  "CVS1" | UInt32 Kopflaenge | Kopf-JSON | Rohbytes
// Grosse Eintraege (v2): dasselbe Paket OHNE Rohbytes als „Manifest" (kind = "bigfile", echte Art in `big`) —
// aeltere Clients kennen "bigfile" nicht, zeigen `text` (Hinweis) und lassen den Eintrag sonst in Ruhe.
// Die Bytes liegen in Teilen zu 1 MiB, jedes Teil ein eigenes AES-GCM-Chiffrat (eigene Zufalls-Nonce),
// AAD = clipvault-part|v2|<tresor>|<id>|<content>|<idx>/<anzahl> -> Teile lassen sich weder vertauschen noch
// zwischen Eintraegen/Fassungen verschieben oder abschneiden.
enum SyncWire {
    static let maxBody = 8 * 1024 * 1024
    struct Header: Codable {
        var v = 1
        var id: String; var kind: String; var text: String?; var fileName: String?
        var createdBy: String; var createdAt: Double; var updatedAt: Double; var pinned: Bool; var deleted: Bool
        // v2 (optional)
        var big: String? = nil          // "file" | "image"
        var size: Int64? = nil
        var parts: Int? = nil
        var partSize: Int? = nil
        var content: String? = nil
        var sourceId: String? = nil
        // Gemeinsame Namen (vocab.swift): nur bei kind == "vocab". Aeltere Decoder ueberspringen das Feld.
        var vocab: VocabWire? = nil
    }
    struct VocabWire: Codable { var word: String; var type: String }
    static func aad(vault: String, id: String) -> Data { Data("clipvault-item|v1|\(vault.lowercased())|\(id.lowercased())".utf8) }
    static func partAAD(vault: String, id: String, content: String, idx: Int, count: Int) -> Data {
        Data("clipvault-part|v2|\(vault.lowercased())|\(id.lowercased())|\(content.lowercased())|\(idx)/\(count)".utf8)
    }
    static func hint(_ it: SharedItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: it.size ?? 0, countStyle: .file)
        let what = it.kind == .image ? "Bild" : "Datei „\(it.fileName ?? "Datei")\""
        return "\(what) (\(size)) — zum Öffnen ClipVault aktualisieren."
    }

    private static func frame(_ h: Header, body: Data) throws -> Data {
        let head = try JSONEncoder().encode(h)
        var d = Data("CVS1".utf8)
        var n = UInt32(head.count).bigEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        d.append(head); d.append(body)
        return d
    }
    static func encode(_ it: SharedItem) throws -> Data {
        var h = Header(id: it.id, kind: it.kind.rawValue, text: it.deleted ? nil : it.text, fileName: it.deleted ? nil : it.fileName,
                       createdBy: it.createdBy, createdAt: it.createdAt.timeIntervalSince1970, updatedAt: it.updatedAt.timeIntervalSince1970,
                       pinned: it.pinned, deleted: it.deleted)
        h.sourceId = it.sourceId
        if it.isBig && !it.deleted {   // Manifest
            h.v = 2; h.big = it.kind.rawValue; h.kind = "bigfile"; h.text = hint(it)
            h.size = it.size; h.parts = it.parts; h.partSize = SharedVault.partSize; h.content = it.content
            return try frame(h, body: Data())
        }
        let body: Data = it.deleted ? Data() : (it.kind == .image ? (it.imagePNG ?? Data()) : (it.kind == .file ? (it.fileData ?? Data()) : Data()))
        if body.count > maxBody { throw SyncError(message: "Zu groß zum Teilen (max. 8 MB)", status: 413) }
        if !it.deleted && ((it.kind == .image && it.imagePNG == nil) || (it.kind == .file && it.fileData == nil)) {
            throw SyncError(message: "Bild/Datei fehlt auf der Platte")
        }
        if !it.deleted, it.kind == .image || it.kind == .file { h.size = Int64(body.count) }
        return try frame(h, body: body)
    }
    /// Gemeinsamer Name: fuer aeltere Clients ein Grabstein ohne Text (unsichtbar), das Wort steht in `vocab`
    static func encodeVocab(_ v: VocabEntry) throws -> Data {
        var h = Header(id: v.id, kind: "vocab", text: nil, fileName: nil, createdBy: v.by, createdAt: v.createdAt,
                       updatedAt: v.updatedAt, pinned: false, deleted: true)
        h.vocab = VocabWire(word: v.word, type: v.type)
        return try frame(h, body: Data())
    }
    private static func header(_ d: Data) throws -> (Header, Data) {
        guard d.count >= 8, d.prefix(4) == Data("CVS1".utf8) else { throw SyncError(message: "unbekanntes Format") }
        let n = d.subdata(in: 4..<8).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard 8 + n <= d.count else { throw SyncError(message: "kaputtes Paket") }
        let h = try JSONDecoder().decode(Header.self, from: d.subdata(in: 8..<(8 + n)))
        guard UUID(uuidString: h.id) != nil else { throw SyncError(message: "ungueltige id") }
        return (h, d.subdata(in: (8 + n)..<d.count))
    }
    enum Opened { case item(SharedItem), vocab(VocabEntry) }
    static func decodeAny(_ d: Data) throws -> Opened {
        let (h, _) = try header(d)
        guard h.kind == "vocab" else { return .item(try decode(d)) }
        guard let w = h.vocab, let word = VocabStore.clean(w.word) else { throw SyncError(message: "kaputter Name") }
        return .vocab(VocabEntry(id: h.id, word: word, type: VocabStore.type(w.type), by: String(h.createdBy.prefix(40)),
                                 createdAt: h.createdAt, updatedAt: h.updatedAt, dir: "in"))
    }
    static func decode(_ d: Data) throws -> SharedItem {
        let (h, body) = try header(d)
        let isBig = h.kind == "bigfile" && !h.deleted
        let kind: SharedItem.Kind = isBig ? (SharedItem.Kind(rawValue: h.big ?? "file") ?? .file) : (SharedItem.Kind(rawValue: h.kind) ?? .text)
        var s = SharedItem(id: h.id, kind: kind, text: isBig ? nil : h.text, createdBy: String(h.createdBy.prefix(40)),
                           createdAt: Date(timeIntervalSince1970: h.createdAt), updatedAt: Date(timeIntervalSince1970: h.updatedAt))
        s.pinned = h.pinned; s.deleted = h.deleted
        s.sourceId = h.sourceId.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        if isBig {
            guard let parts = h.parts, parts > 0, parts <= 256, let size = h.size, size > 0,
                  size <= SharedVault.maxShareBytes, h.partSize == SharedVault.partSize,
                  Int64(parts) == (size + Int64(SharedVault.partSize) - 1) / Int64(SharedVault.partSize),
                  let c = h.content, c.count == 32, c.allSatisfy({ $0.isHexDigit }) else { throw SyncError(message: "kaputtes Manifest") }
            s.parts = parts; s.size = size; s.content = c.lowercased()
            if kind == .file { s.fileName = safeFileName(h.fileName) }
        } else if !h.deleted {
            if kind == .image { s.imagePNG = body; s.size = Int64(body.count) }
            if kind == .file { s.fileName = safeFileName(h.fileName); s.fileData = body; s.size = Int64(body.count) }
        } else if kind == .file { s.fileName = nil }
        return s
    }
    /// Dateiname kommt vom Partner -> nie Pfade/„..“ zulassen (sonst Schreiben ausserhalb von shared/)
    static func safeFileName(_ n: String?) -> String { SharedVault.safeName(n ?? "Datei") }
    static func seal(_ plain: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let c = try AES.GCM.seal(plain, using: key, authenticating: aad).combined else { throw SyncError(message: "Verschluesseln fehlgeschlagen") }
        return c
    }
    static func open(_ box: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: aad)
    }
}

// MARK: - Kopplungscode   cvpair1.<base64url( 01 | tresor 16 B | geheimnis 16 B | schluessel 32 B | url utf8 )>
enum PairCode {
    struct Parts { var url: String; var vaultId: String; var secret: String; var key: Data }
    static func encode(_ p: Parts) -> String {
        var d = Data([1])
        d.append(uuidBytes(p.vaultId)); d.append(hexData(p.secret)); d.append(p.key); d.append(Data(p.url.utf8))
        return "cvpair1." + d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ raw: String) -> Parts? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        if let r = s.range(of: "cvpair1.") { s = String(s[r.upperBound...]) } else { return nil }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), d.count > 65, d[0] == 1 else { return nil }
        let b = [UInt8](d)
        let vault = uuidString(Array(b[1..<17]))
        let secret = b[17..<33].map { String(format: "%02x", $0) }.joined()
        let key = Data(b[33..<65])
        guard let url = String(data: Data(b[65...]), encoding: .utf8), url.hasPrefix("http") else { return nil }
        return Parts(url: url, vaultId: vault, secret: secret, key: key)
    }
    static func uuidBytes(_ s: String) -> Data {
        guard let u = UUID(uuidString: s) else { return Data(count: 16) }
        return withUnsafeBytes(of: u.uuid) { Data($0) }
    }
    static func uuidString(_ b: [UInt8]) -> String {
        let t: uuid_t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        return UUID(uuid: t).uuidString.lowercased()
    }
    static func hexData(_ h: String) -> Data {
        var d = Data(); var i = h.startIndex
        while i < h.endIndex, let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex), let v = UInt8(h[i..<j], radix: 16) { d.append(v); i = j }
        return d
    }
}
func randomBytes(_ n: Int) -> Data {
    var b = [UInt8](repeating: 0, count: n)
    if SecRandomCopyBytes(kSecRandomDefault, n, &b) != errSecSuccess { for i in b.indices { b[i] = UInt8.random(in: 0...255) } }
    return Data(b)
}
extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

enum SyncFmt {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: n)
    }
}

// MARK: - Zustand fuer Oberflaeche/status.txt
struct SyncSnapshot: Equatable {
    var state = "unconfigured"      // unconfigured · unpaired · pairing · waiting · connecting · connected · offline
    var reason = ""
    var paired = false
    var partnerJoined = false
    var queue = 0
    var pairingCode: String? = nil
    var pairingExpires: Date? = nil
    var lastLatencyMs: Int? = nil
    var received = 0
    var host = ""
    var vault = ""
    var storage: SharedStorage? = nil
    var transfers = 0
}

// MARK: - Motor (alles Netz + Zustand; laeuft nicht auf dem Main-Thread)
actor SyncEngine {
    private var cfg = SyncConfig()
    private var key: SymmetricKey?
    private var token: String?
    private var queue: [String] = []
    private var state = "unconfigured"
    private var reason = ""
    private var pairingCode: String?
    private var pairingExpires: Date?
    private var pairingBaseline = 0
    private var ws: URLSessionWebSocketTask?
    private var gen = 0
    private var lastPong = Date.distantPast
    private var backoff: Double = 1
    private var flushing = false
    private var flushRetryAt: Date?
    private var catching = false
    private var catchAgain = false
    private var lastLatencyMs: Int?
    private var received = 0
    private var started = false
    private var uploads: [String: Task<Void, Never>] = [:]
    private var downloads: [String: Task<Void, Never>] = [:]
    private var storage: SharedStorage?
    private let testPartDelay = UInt64(ProcessInfo.processInfo.environment["CLIPVAULT_TEST_PART_DELAY_MS"].flatMap { Int($0) } ?? 0)
    private let http: URLSession
    private let wsSession: URLSession
    private let publish: @Sendable (SyncSnapshot) -> Void

    init(publish: @escaping @Sendable (SyncSnapshot) -> Void) {
        self.publish = publish
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 180
        c.httpShouldUsePipelining = true; c.urlCache = nil
        http = URLSession(configuration: c)
        let w = URLSessionConfiguration.ephemeral
        w.timeoutIntervalForRequest = 3600
        wsSession = URLSession(configuration: w)
    }

    // ---------- Start ----------
    func boot() {
        guard !started else { return }
        started = true
        cfg = SyncConfig.load()
        if (cfg.proto ?? 0) < 3 { cfg.cursor = 0; cfg.proto = 3; cfg.save() }   // einmal alles nachholen (grosse Eintraege, gemeinsame Namen)
        loadQueue()
        loadSecrets()
        try? FileManager.default.removeItem(atPath: SyncFiles.pairing)   // alter Code ist nach Neustart ungueltig
        if isPaired { state = "connecting"; connect() } else { state = cfg.url == nil ? "unconfigured" : "unpaired" }
        emit()
        Task { await self.periodic() }
    }
    private var isPaired: Bool { cfg.vaultId != nil && key != nil && token != nil && cfg.url != nil }
    private var device: String { cfg.deviceId ?? "unknown" }
    private func loadSecrets() {
        if let k = SyncKeychain.get("vault-key"), k.count == 32 { key = SymmetricKey(data: k) } else { key = nil }
        token = SyncKeychain.get("vault-token").flatMap { String(data: $0, encoding: .utf8) }
    }
    private func loadQueue() {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: SyncFiles.queue)), let q = try? JSONDecoder().decode([String].self, from: d) { queue = q }
    }
    private func saveQueue() {
        if let d = try? JSONEncoder().encode(queue) { SyncFiles.writePrivate(d, SyncFiles.queue) }
    }
    private func emit() {
        if let e = pairingExpires, e < Date() { endPairing() }
        var s = SyncSnapshot()
        s.state = pairingCode != nil ? "pairing" : (isPaired && cfg.partnerJoined != true && state == "connected" ? "waiting" : state)
        s.reason = reason; s.paired = isPaired; s.partnerJoined = cfg.partnerJoined == true
        s.queue = queue.count; s.pairingCode = pairingCode; s.pairingExpires = pairingExpires
        s.lastLatencyMs = lastLatencyMs; s.received = received
        s.host = cfg.url.flatMap { URL(string: $0)?.host } ?? ""
        s.vault = String((cfg.vaultId ?? "").prefix(8))
        s.storage = storage; s.transfers = uploads.count + downloads.count
        publish(s)
    }
    private func setState(_ s: String, _ why: String = "") {
        if s == state && why == reason { return }
        state = s; reason = why; emit()
    }

    private func periodic() async {
        var tick = 0
        while true {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            tick += 1
            if pairingCode != nil { await pollPairing() }
            if let e = pairingExpires, e < Date() { endPairing(); emit() }
            if tick % 12 == 0, isPaired { await catchUp(); await flush() }          // alle 60 s
            if tick % 60 == 3, isPaired { await refreshInfo() }                      // Speicherstand alle 5 min
            if let r = flushRetryAt, r < Date(), !queue.isEmpty { flushRetryAt = nil; await flush() }
        }
    }

    // ---------- HTTP ----------
    private func base() throws -> String {
        guard let u = cfg.url?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !u.isEmpty else { throw SyncError(message: "Sync nicht eingerichtet — `clipvault sync setup <worker-url>`") }
        return u
    }
    private func vaultPath() throws -> String {
        guard let v = cfg.vaultId else { throw SyncError(message: "nicht gekoppelt") }
        return try base() + "/v/" + v
    }
    private func request(_ method: String, _ url: String, body: Data? = nil, auth: String? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw SyncError(message: "ungueltige URL") }
        var r = URLRequest(url: u); r.httpMethod = method
        r.setValue(device, forHTTPHeaderField: "X-CV-Device")
        if let a = auth { r.setValue("Bearer " + a, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let b = body { r.httpBody = b }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await http.data(for: r) }
        catch { throw SyncError(message: "keine Verbindung", network: true) }
        guard let h = resp as? HTTPURLResponse else { throw SyncError(message: "keine Antwort", network: true) }
        // Server antwortet wieder, WebSocket wartet aber noch im Backoff -> sofort neu verbinden
        if h.statusCode < 500, ws == nil, state == "offline", isPaired { backoff = 1; connect() }
        if !(200..<300).contains(h.statusCode) {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? "HTTP \(h.statusCode)"
            throw SyncError(message: String(msg.prefix(160)), status: h.statusCode, network: h.statusCode >= 500)
        }
        return (data, h)
    }
    private func jsonBody(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
    private func obj(_ d: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:] }

    // ---------- Kopplung ----------
    /// Init-Geheimnis des eigenen Workers (INIT_SECRET) – nur der Mac, der einen Tresor ANLEGT, braucht es.
    /// Liegt im Schluesselbund, nie in sync.json. `clipvault sync setup <url> <geheimnis>` oder Hub › ClipVault › Einstellungen.
    private var initSecret: String? { SyncKeychain.get("init-secret").flatMap { String(data: $0, encoding: .utf8) } }

    func setup(url: String, initSecret: String? = nil) throws -> [String: Any] {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        guard let p = URL(string: u), let sch = p.scheme, sch == "https" || (sch == "http" && ["127.0.0.1", "localhost"].contains(p.host ?? "")),
              p.host != nil else { throw SyncError(message: "URL muss https:// sein (http nur fuer localhost)") }
        if isPaired && cfg.url != u { throw SyncError(message: "Schon gekoppelt — erst `clipvault unpair`") }
        cfg.url = u; cfg.save()
        if let sec = initSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !sec.isEmpty {
            guard SyncKeychain.set("init-secret", Data(sec.utf8)) else { throw SyncError(message: "Schluesselbund nicht beschreibbar") }
        }
        if !isPaired { state = "unpaired" }
        emit()
        return ["url": u, "initSecret": self.initSecret != nil]
    }

    func pairCreate(me: String) async throws -> [String: Any] {
        let b = try base()
        if !isPaired {
            let vault = UUID().uuidString.lowercased()
            let tok = randomBytes(32).hex
            let k = randomBytes(32)
            do {
                _ = try await request("POST", b + "/v/" + vault + "/init", auth: tok, headers: ["X-CV-Init-Secret": initSecret ?? ""])
            } catch let e as SyncError where e.status == 403 || e.status == 503 {
                throw SyncError(message: e.status == 503
                    ? "Dein Worker hat noch kein INIT_SECRET – `npx wrangler secret put INIT_SECRET` (siehe sync-worker/README.md)"
                    : "Init-Geheimnis fehlt oder falsch – `clipvault sync setup <url> <geheimnis>`", status: e.status)
            }
            guard SyncKeychain.set("vault-key", k), SyncKeychain.set("vault-token", Data(tok.utf8)) else {
                throw SyncError(message: "Schluesselbund nicht beschreibbar")
            }
            cfg.vaultId = vault; cfg.cursor = 0; cfg.partnerJoined = false; cfg.save()
            loadSecrets()
            syncLog("neuer Tresor angelegt (\(vault.prefix(8)))")
            connect()
        }
        guard let tok = token, let k = key, let vault = cfg.vaultId else { throw SyncError(message: "Tresor unvollstaendig") }
        let secret = randomBytes(16).hex
        let (d, _) = try await request("POST", try vaultPath() + "/invite", body: jsonBody(["secret": secret]), auth: tok,
                                       headers: ["Content-Type": "application/json"])
        let expMs = (obj(d)["expiresAt"] as? Double) ?? (Date().timeIntervalSince1970 * 1000 + 15 * 60_000)
        let code = PairCode.encode(.init(url: b, vaultId: vault, secret: secret, key: k.withUnsafeBytes { Data($0) }))
        pairingBaseline = (try? await info())?["devices"] as? Int ?? 1
        pairingCode = code; pairingExpires = Date(timeIntervalSince1970: expMs / 1000)
        let file: [String: Any] = ["code": code, "payload": code, "expiresAt": expMs / 1000]
        SyncFiles.writePrivate(jsonBody(file), SyncFiles.pairing)
        syncLog("Kopplungscode erzeugt (15 min gueltig)")
        emit()
        return ["code": code, "payload": code, "expiresAt": expMs / 1000]
    }
    private func info() async throws -> [String: Any] {
        guard let tok = token else { throw SyncError(message: "nicht gekoppelt") }
        let (d, _) = try await request("GET", try vaultPath() + "/info", auth: tok)
        return obj(d)
    }
    private func pollPairing() async {
        guard pairingCode != nil, let i = try? await info() else { return }
        if (i["devices"] as? Int ?? 0) > pairingBaseline && (i["invite"] as? Bool) == false { partnerDidJoin() }
    }
    private func partnerDidJoin() {
        let wasPairing = pairingCode != nil
        cfg.partnerJoined = true; cfg.save()
        endPairing()
        if wasPairing { syncLog("Partner ist beigetreten") }
        emit()
    }
    private func endPairing() {
        pairingCode = nil; pairingExpires = nil
        try? FileManager.default.removeItem(atPath: SyncFiles.pairing)
    }
    func pairCancel() async -> [String: Any] {
        if let tok = token, let p = try? vaultPath() { _ = try? await request("DELETE", p + "/invite", auth: tok) }
        endPairing(); emit()
        return [:]
    }

    func pairJoin(_ raw: String) async throws -> [String: Any] {
        guard let p = PairCode.decode(raw) else { throw SyncError(message: "Code nicht erkannt (beginnt mit cvpair1.)") }
        if isPaired {
            if cfg.vaultId == p.vaultId { return ["vault": String(p.vaultId.prefix(8)), "already": true] }
            throw SyncError(message: "Schon mit einem anderen Tresor gekoppelt — erst `clipvault unpair`")
        }
        var u = p.url; while u.hasSuffix("/") { u.removeLast() }
        let (d, _) = try await request("POST", u + "/v/" + p.vaultId + "/join", body: jsonBody(["secret": p.secret, "device": device]),
                                       headers: ["Content-Type": "application/json"])
        guard let tok = obj(d)["token"] as? String, tok.count == 64 else { throw SyncError(message: "Server lieferte keinen Zugang") }
        guard SyncKeychain.set("vault-key", p.key), SyncKeychain.set("vault-token", Data(tok.utf8)) else {
            throw SyncError(message: "Schluesselbund nicht beschreibbar")
        }
        cfg.url = u; cfg.vaultId = p.vaultId; cfg.cursor = 0; cfg.partnerJoined = true; cfg.save()
        loadSecrets()
        syncLog("Tresor beigetreten (\(p.vaultId.prefix(8)))")
        backoff = 1
        connect()
        Task { await self.catchUp(); await self.flush() }
        emit()
        return ["vault": String(p.vaultId.prefix(8))]
    }

    func unpair() -> [String: Any] {
        gen += 1; ws?.cancel(with: .goingAway, reason: nil); ws = nil
        for t in uploads.values { t.cancel() }; for t in downloads.values { t.cancel() }
        uploads.removeAll(); downloads.removeAll(); storage = nil
        SyncKeychain.delete("vault-key"); SyncKeychain.delete("vault-token")
        key = nil; token = nil
        cfg.vaultId = nil; cfg.cursor = nil; cfg.partnerJoined = nil; cfg.save()
        queue.removeAll(); saveQueue()
        endPairing()
        state = cfg.url == nil ? "unconfigured" : "unpaired"; reason = ""
        syncLog("getrennt")
        emit()
        return [:]
    }

    func status() -> [String: Any] {
        var d: [String: Any] = ["state": pairingCode != nil ? "pairing" : state, "paired": isPaired, "partnerJoined": cfg.partnerJoined == true,
                                "queue": queue.count, "received": received, "device": String(device.prefix(8)),
                                "keychain": SyncKeychain.service]
        if !reason.isEmpty { d["reason"] = reason }
        if let u = cfg.url { d["url"] = u }
        if let v = cfg.vaultId { d["vault"] = String(v.prefix(8)) }
        if let l = lastLatencyMs { d["lastLatencyMs"] = l }
        if let e = pairingExpires { d["pairingExpires"] = e.timeIntervalSince1970 }
        if let st = storage { d["used"] = st.used; d["quota"] = st.quota; d["bigItems"] = st.bigCount; d["bigBytes"] = st.bigBytes }
        d["uploads"] = Array(uploads.keys); d["downloads"] = Array(downloads.keys)
        return d
    }

    // ---------- Hochladen (Warteschlange) ----------
    func enqueue(_ id: String) async {
        if !queue.contains(id) { queue.append(id); saveQueue() }
        emit()
        await flush()
    }
    func flush() async {
        guard !flushing, isPaired, let k = key, let tok = token, let vault = cfg.vaultId else { return }
        flushing = true; defer { flushing = false; emit() }
        var i = 0
        while i < queue.count {
            let id = queue[i]
            let snap: SharedItem? = await MainActor.run { SharedVault.shared.item(id).map { SharedVault.shared.withBlobs($0) } }
            if snap == nil, let v = await MainActor.run(body: { VocabStore.shared.entry(id) }) {
                switch await pushVocab(v, key: k, tok: tok, vault: vault) {
                case .done: dropFromQueue(id)
                case .later: return
                case .stop: return
                }
                continue
            }
            guard let it = snap, UUID(uuidString: id) != nil else { dropFromQueue(id); continue }
            // grosse Eintraege: eigener Hochlader im Hintergrund (Teile, fortsetzbar, hoechstens 2 gleichzeitig)
            if it.isBig && !it.deleted {
                if it.uploadError != nil { dropFromQueue(id); continue }
                if uploads[id] == nil && uploads.count < 2 { startUpload(id) }
                i += 1; continue
            }
            if let u = uploads[id] { u.cancel(); uploads[id] = nil }          // z. B. waehrend des Hochladens geloescht
            let sealed: Data
            do { sealed = try SyncWire.seal(try SyncWire.encode(it), key: k, aad: SyncWire.aad(vault: vault, id: id)) }
            catch let e as SyncError {
                syncLog("nicht hochgeladen: \(e.message)")
                dropFromQueue(id)
                let msg = e.message
                await MainActor.run { SharedVault.shared.markUploadFailed(id, msg); if !CV_HEADLESS { Toast.shared.show(msg) } }
                continue
            } catch { dropFromQueue(id); continue }
            do {
                let (d, _) = try await request("PUT", try vaultPath() + "/items/" + id.lowercased(), body: sealed, auth: tok, headers: [
                    "Content-Type": "application/octet-stream",
                    "X-CV-Updated-At": String(format: "%.6f", it.updatedAt.timeIntervalSince1970),
                    "X-CV-Deleted": it.deleted ? "1" : "0"])
                dropFromQueue(id)
                let applied = obj(d)["applied"] as? Bool ?? true
                let now: Date? = await MainActor.run { SharedVault.shared.item(id)?.updatedAt }
                if now == it.updatedAt { await MainActor.run { SharedVault.shared.markSynced([id]) } }
                else if !queue.contains(id) { queue.append(id); saveQueue() }       // zwischendurch geaendert -> nochmal
                if !applied { Task { await self.catchUp() } }                          // Server hat Neueres
            } catch let e as SyncError {
                if e.status == 401 || e.status == 404 { setState("offline", "Zugang abgelehnt — neu koppeln"); return }
                if e.status == 413 || e.status == 507 || e.status == 400 {
                    let msg = e.status == 507 ? fullMessage() : (e.status == 413 ? "Zu groß zum Teilen" : "Server lehnte Eintrag ab (\(e.message))")
                    syncLog("nicht hochgeladen: \(msg)")
                    dropFromQueue(id)
                    await MainActor.run { SharedVault.shared.markUploadFailed(id, msg); if !CV_HEADLESS { Toast.shared.show(msg) } }
                    if e.status == 507 { await refreshInfo() }
                    continue
                }
                // Netz weg / 429 / 5xx -> spaeter nochmal (Warteschlange bleibt auf Platte)
                flushRetryAt = Date().addingTimeInterval(e.status == 429 ? 15 : min(backoff * 2, 30))
                if e.network, state == "connected" { setState("offline", "keine Verbindung") }
                return
            } catch { return }
        }
    }
    // ---------- Gemeinsame Namen (vocab.swift) ----------
    private enum PushResult { case done, later, stop }
    /// Ein Wort hochladen: Nutzlast wie ein Grabstein (aeltere Clients zeigen nichts), beim Server KEIN Grabstein
    private func pushVocab(_ v: VocabEntry, key k: SymmetricKey, tok: String, vault: String) async -> PushResult {
        do {
            let sealed = try SyncWire.seal(try SyncWire.encodeVocab(v), key: k, aad: SyncWire.aad(vault: vault, id: v.id))
            let (d, _) = try await request("PUT", try vaultPath() + "/items/" + v.id.lowercased(), body: sealed, auth: tok, headers: [
                "Content-Type": "application/octet-stream",
                "X-CV-Updated-At": String(format: "%.6f", v.updatedAt),
                "X-CV-Deleted": "0"])
            if (obj(d)["applied"] as? Bool) == false { Task { await self.catchUp() } }   // Partner hat dasselbe Wort neuer
            syncDebug("Name hochgeladen")
            return .done
        } catch let e as SyncError {
            if e.status == 401 || e.status == 404 { setState("offline", "Zugang abgelehnt — neu koppeln"); return .stop }
            if e.status == 400 || e.status == 413 || e.status == 507 { syncLog("Name nicht hochgeladen (\(e.status))"); return .done }
            flushRetryAt = Date().addingTimeInterval(e.status == 429 ? 15 : min(backoff * 2, 30))
            if e.network, state == "connected" { setState("offline", "keine Verbindung") }
            return .later
        } catch { return .done }
    }
    /// Schluessel fuer Wort-ids (aus dem Tresor-Schluessel; beide Partner rechnen dieselbe id aus)
    func vocabIdKey() -> SymmetricKey? { key.map { VocabStore.idKey(vaultKey: $0) } }
    /// Befehl sendVocab: Wort anlegen (falls neu) und in die Warteschlange
    func sendVocab(word: String, type: String, by: String) async throws -> [String: Any] {
        guard let ik = vocabIdKey(), isPaired else { throw SyncError(message: "nicht gekoppelt") }
        let out = await MainActor.run { VocabStore.shared.learnedLocally(word: word, type: type, by: by, idKey: ik) }
        switch out {
        case .known(let e):
            return ["vocabId": e.id, "sent": false, "known": e.dir == "in" ? "partner" : "self"]
        case .queued(let e):
            await enqueue(e.id)
            return ["vocabId": e.id, "sent": true]
        }
    }
    private func applyVocab(_ list: [VocabEntry], live: Bool) async {
        guard let ik = vocabIdKey() else { return }
        // id muss zum Wort passen (sonst waere die Doppel-Erkennung ausgehebelt)
        let ok = list.filter { VocabStore.id(for: $0.word, idKey: ik).lowercased() == $0.id.lowercased() }
        if ok.count != list.count { syncLog("Name verworfen (id passt nicht zum Wort)") }
        guard !ok.isEmpty else { return }
        if live, let newest = ok.map(\.updatedAt).max() {
            lastLatencyMs = max(0, Int((Date().timeIntervalSince1970 - newest) * 1000))
        }
        received += ok.count
        await MainActor.run {
            var fresh = 0
            for v in ok {
                if VocabStore.shared.applyRemote(v, me: SharedVault.shared.me) { fresh += 1 }
                SharedVault.shared.forgetHidden(v.id)        // aeltere Fassung hatte es als Grabstein abgelegt
            }
            cvLog("Sync: \(live ? "live" : "nachgeholt") \(ok.count) Name(n)\(fresh > 0 ? ", \(fresh) neu im Posteingang" : "")")
            if fresh > 0 { VocabStore.notifyInbox(); cvStatusWriter?() }
        }
        emit()
    }

    private func dropFromQueue(_ id: String) {
        let n = queue.count
        queue.removeAll { $0 == id }
        if queue.count != n { saveQueue() }
    }
    private func fullMessage() -> String {
        if let st = storage, st.quota > 0 {
            return "Geteilter Speicher voll (\(SyncFmt.bytes(st.used)) von \(SyncFmt.bytes(st.quota))) — „Große Dateien aufräumen\""
        }
        return "Geteilter Speicher voll — „Große Dateien aufräumen\""
    }

    // ---------- Grosse Eintraege: Hochladen in Teilen ----------
    private func startUpload(_ id: String) {
        uploads[id] = Task {
            await self.runUpload(id)
            await self.uploadEnded(id)
        }
        emit()
    }
    private func uploadEnded(_ id: String) async {
        uploads[id] = nil
        emit()
        if !queue.isEmpty { await flush() }
    }
    private func progress(_ id: String, _ dir: SharedTransfer.Dir, _ done: Int64, _ total: Int64, _ t0: Date) async {
        await MainActor.run { SharedVault.shared.setTransfer(id, SharedTransfer(dir: dir, done: done, total: total, startedAt: t0)) }
    }
    private func clearProgress(_ id: String) async { await MainActor.run { SharedVault.shared.setTransfer(id, nil) } }
    private static func readChunk(_ url: URL, _ idx: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(idx) * UInt64(SharedVault.partSize))
        return try fh.read(upToCount: SharedVault.partSize) ?? Data()
    }
    private func expectedLen(_ idx: Int, parts: Int, size: Int64) -> Int {
        idx < parts - 1 ? SharedVault.partSize : Int(size - Int64(parts - 1) * Int64(SharedVault.partSize))
    }

    private func runUpload(_ id: String) async {
        guard let k = key, let tok = token, let vault = cfg.vaultId else { return }
        let found: (SharedItem, URL?)? = await MainActor.run { SharedVault.shared.item(id).map { ($0, SharedVault.shared.localURL($0)) } }
        guard let (it, localURL) = found, it.isBig, !it.deleted, let parts = it.parts, let content = it.content, let size = it.size else {
            dropFromQueue(id); return
        }
        guard let url = localURL, (((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil) ?? -1) == size else {
            dropFromQueue(id)
            await MainActor.run { SharedVault.shared.markUploadFailed(id, "Datei fehlt auf der Platte") }
            return
        }
        let t0 = Date()
        let total = size + Int64(parts) * 28                     // je Teil 12 B Nonce + 16 B Tag
        do {
            let path = try vaultPath() + "/items/" + id.lowercased()
            let manifest = try SyncWire.seal(try SyncWire.encode(it), key: k, aad: SyncWire.aad(vault: vault, id: id))
            let (bd, _) = try await request("POST", path + "/begin", body: manifest, auth: tok, headers: [
                "Content-Type": "application/octet-stream",
                "X-CV-Updated-At": String(format: "%.6f", it.updatedAt.timeIntervalSince1970),
                "X-CV-Parts": String(parts), "X-CV-Total": String(total), "X-CV-Content": content,
                "X-CV-Keep": it.pinned ? "1" : "0"])
            let bo = obj(bd)
            if (bo["applied"] as? Bool) == false {                 // Server hat Neueres
                dropFromQueue(id)
                let now: Date? = await MainActor.run { SharedVault.shared.item(id)?.updatedAt }
                if now == it.updatedAt { await MainActor.run { SharedVault.shared.markSynced([id]) } }
                Task { await self.catchUp() }
                return
            }
            if let u = (bo["used"] as? NSNumber)?.int64Value, let q = (bo["quota"] as? NSNumber)?.int64Value {
                var st = storage ?? SharedStorage(); st.used = u; st.quota = q; storage = st; emit()
            }
            let have = Set((bo["have"] as? [NSNumber] ?? []).map(\.intValue))
            var done: Int64 = have.reduce(0) { $0 + Int64(expectedLen($1, parts: parts, size: size)) }
            var missing = (0..<parts).filter { !have.contains($0) }
            if !have.isEmpty { syncLog("Hochladen fortgesetzt: \(have.count)/\(parts) Teile schon da") }
            await progress(id, .up, done, size, t0)
            for round in 0..<3 {
                if !missing.isEmpty {
                    try await withThrowingTaskGroup(of: Int64.self) { g in
                        var next = 0
                        func add() {
                            guard next < missing.count else { return }
                            let idx = missing[next]; next += 1
                            g.addTask { try await self.uploadPart(url: url, path: path, vault: vault, id: id, content: content, idx: idx, parts: parts, key: k, tok: tok) }
                        }
                        for _ in 0..<3 { add() }
                        while let n = try await g.next() {
                            done += n
                            await progress(id, .up, done, size, t0)
                            add()
                        }
                    }
                }
                try Task.checkCancellation()
                do {
                    let (cd, _) = try await request("POST", path + "/commit", auth: tok)
                    let exp = (obj(cd)["expires_at"] as? NSNumber)?.doubleValue
                    await MainActor.run { SharedVault.shared.setServerMeta(id, gone: false, expiresAt: exp.map { $0 / 1000 }) }
                    break
                } catch let e as SyncError where e.status == 409 && round < 2 {
                    // Server vermisst Teile -> gleiche Content-id erneut anmelden, fehlende nachreichen
                    let (bd2, _) = try await request("POST", path + "/begin", body: manifest, auth: tok, headers: [
                        "Content-Type": "application/octet-stream",
                        "X-CV-Updated-At": String(format: "%.6f", it.updatedAt.timeIntervalSince1970),
                        "X-CV-Parts": String(parts), "X-CV-Total": String(total), "X-CV-Content": content, "X-CV-Keep": it.pinned ? "1" : "0"])
                    let have2 = Set((obj(bd2)["have"] as? [NSNumber] ?? []).map(\.intValue))
                    missing = (0..<parts).filter { !have2.contains($0) }
                    done = have2.reduce(0) { $0 + Int64(expectedLen($1, parts: parts, size: size)) }
                }
            }
            let secs = max(0.001, Date().timeIntervalSince(t0))
            syncLog(String(format: "hochgeladen: %@ in %.1f s (%.1f MB/s)", SyncFmt.bytes(size), secs, Double(size) / 1_048_576 / secs))
            dropFromQueue(id)
            let now: Date? = await MainActor.run { SharedVault.shared.item(id)?.updatedAt }
            if now == it.updatedAt { await MainActor.run { SharedVault.shared.markSynced([id]) } }
            else if !queue.contains(id) { queue.append(id); saveQueue() }
            await clearProgress(id)
            await refreshInfo()
        } catch is CancellationError {
            await clearProgress(id)
        } catch let e as SyncError {
            await clearProgress(id)
            if Task.isCancelled { return }
            if e.status == 507 || e.status == 413 || e.status == 400 {
                let msg = e.status == 507 ? fullMessage() : (e.status == 413 ? "Zu groß zum Teilen (max. 200 MB)" : "Server lehnte die Datei ab (\(e.message))")
                syncLog("nicht hochgeladen: \(msg)")
                dropFromQueue(id)
                if e.status == 507 { await refreshInfo() }
                let m2 = e.status == 507 ? fullMessage() : msg
                await MainActor.run { SharedVault.shared.markUploadFailed(id, m2); if !CV_HEADLESS { Toast.shared.show(m2) } }
                return
            }
            if e.status == 401 || e.status == 404 { setState("offline", "Zugang abgelehnt — neu koppeln"); return }
            syncLog("Hochladen unterbrochen (\(e.message)) — geht spaeter weiter")
            flushRetryAt = Date().addingTimeInterval(e.status == 429 ? 15 : min(backoff * 2, 30))
            if e.network, state == "connected" { setState("offline", "keine Verbindung") }
        } catch {
            await clearProgress(id)
            if Task.isCancelled { return }
            syncLog("Hochladen fehlgeschlagen: \(error.localizedDescription)")
            dropFromQueue(id)
            await MainActor.run { SharedVault.shared.markUploadFailed(id, "Datei nicht lesbar") }
        }
    }
    private func uploadPart(url: URL, path: String, vault: String, id: String, content: String, idx: Int, parts: Int,
                            key: SymmetricKey, tok: String) async throws -> Int64 {
        let plain = try SyncEngine.readChunk(url, idx)
        let sealed = try SyncWire.seal(plain, key: key, aad: SyncWire.partAAD(vault: vault, id: id, content: content, idx: idx, count: parts))
        var attempt = 0
        while true {
            try Task.checkCancellation()
            if testPartDelay > 0 { try await Task.sleep(nanoseconds: testPartDelay * 1_000_000) }
            do {
                _ = try await request("PUT", path + "/parts/\(idx)", body: sealed, auth: tok,
                                      headers: ["Content-Type": "application/octet-stream", "X-CV-Content": content])
                return Int64(plain.count)
            } catch let e as SyncError where (e.status == 429 || e.status >= 500 || e.network) && attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(Double(attempt) * (e.status == 429 ? 3 : 1.5) * 1_000_000_000))
            }
        }
    }

    // ---------- Grosse Eintraege: Laden auf Abruf ----------
    func download(_ id: String) {
        guard isPaired, downloads[id] == nil else { return }
        downloads[id] = Task {
            await self.runDownload(id)
            await self.downloadEnded(id)
        }
        emit()
    }
    private func downloadEnded(_ id: String) { downloads[id] = nil; emit() }
    func cancelTransfer(_ id: String) async {
        let had = uploads[id] != nil || downloads[id] != nil
        uploads[id]?.cancel(); uploads[id] = nil
        downloads[id]?.cancel(); downloads[id] = nil
        if had { syncLog("Uebertragung abgebrochen") }
        await clearProgress(id)
        emit()
    }
    private func runDownload(_ id: String) async {
        guard let k = key, let tok = token, let vault = cfg.vaultId else { return }
        let found: (SharedItem, URL?, Bool)? = await MainActor.run {
            SharedVault.shared.item(id).map { s in (s, s.kind == .image ? SharedVault.shared.imageURL(s.id) : SharedVault.shared.fileURL(s), SharedVault.shared.isLocal(s)) }
        }
        guard let (it, destURL, local) = found, !local, it.isBig, !it.deleted, it.serverGone != true,
              let parts = it.parts, let content = it.content, let size = it.size, let dest = destURL else { return }
        let dir = dest.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".laden-\(content).part")
        let t0 = Date()
        do {
            await MainActor.run { SharedVault.privateDir(SharedVault.shared.dir); SharedVault.privateDir(SharedVault.shared.filesDir); SharedVault.privateDir(dir) }
            try? FileManager.default.removeItem(at: tmp)
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SyncError(message: "Datei nicht anlegbar") }
            let fh = try FileHandle(forWritingTo: tmp)
            defer { try? fh.close() }
            try fh.truncate(atOffset: UInt64(size))
            let path = try vaultPath() + "/items/" + id.lowercased()
            var done: Int64 = 0
            await progress(id, .down, 0, size, t0)
            try await withThrowingTaskGroup(of: (Int, Data).self) { g in
                var next = 0
                func add() {
                    guard next < parts else { return }
                    let idx = next; next += 1
                    let want = expectedLen(idx, parts: parts, size: size)
                    g.addTask {
                        let box = try await self.fetchPart(path: path, idx: idx, tok: tok)
                        let plain: Data
                        do { plain = try SyncWire.open(box, key: k, aad: SyncWire.partAAD(vault: vault, id: id, content: content, idx: idx, count: parts)) }
                        catch { throw SyncError(message: "Teil \(idx + 1) beschädigt oder manipuliert — Laden abgebrochen", status: -3) }
                        guard plain.count == want else { throw SyncError(message: "Teil \(idx + 1) hat die falsche Länge", status: -3) }
                        return (idx, plain)
                    }
                }
                for _ in 0..<3 { add() }
                while let (idx, plain) = try await g.next() {
                    try fh.seek(toOffset: UInt64(idx) * UInt64(SharedVault.partSize))
                    try fh.write(contentsOf: plain)
                    done += Int64(plain.count)
                    await progress(id, .down, done, size, t0)
                    add()
                }
            }
            try fh.synchronize()
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            chmod(dest.path, 0o600)
            let secs = max(0.001, Date().timeIntervalSince(t0))
            syncLog(String(format: "geladen: %@ in %.1f s (%.1f MB/s)", SyncFmt.bytes(size), secs, Double(size) / 1_048_576 / secs))
            await MainActor.run { SharedVault.shared.downloadFinished(id) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            await clearProgress(id)
            await MainActor.run { if SharedVault.shared.pendingCopy == id { SharedVault.shared.pendingCopy = nil } }
            if error is CancellationError || Task.isCancelled { return }
            let e = error as? SyncError
            if e?.status == 410 {
                syncLog("Laden: auf dem Server abgelaufen")
                await MainActor.run { SharedVault.shared.setServerMeta(id, gone: true, expiresAt: nil); if !CV_HEADLESS { Toast.shared.show("Auf dem Server abgelaufen") } }
                return
            }
            let msg = e?.message ?? error.localizedDescription
            syncLog("Laden fehlgeschlagen: \(msg)")
            if e?.status != -3 && (e?.network == true || (e?.status ?? 0) >= 500 || e?.status == 429) {
                return   // Netz: beim naechsten Nachholen (automatisch bis 20 MB) bzw. erneut „Laden"
            }
            await MainActor.run { if !CV_HEADLESS { Toast.shared.show(msg) } }
        }
    }
    private func fetchPart(path: String, idx: Int, tok: String) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let t0 = Date(); let d = try await request("GET", path + "/parts/\(idx)", auth: tok).0
                syncDebug("Teil \(idx) geladen in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                return d
            }
            catch let e as SyncError where (e.status == 429 || e.status >= 500 || e.network) && attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(Double(attempt) * (e.status == 429 ? 3 : 1.5) * 1_000_000_000))
            }
        }
    }
    /// bis 20 MB sofort laden (was noch nicht lokal liegt)
    private func autoDownloads() async {
        let ids: [String] = await MainActor.run {
            SharedVault.shared.items.filter { s in
                s.isBig && !s.deleted && s.serverGone != true && (s.size ?? .max) <= SharedVault.autoDownloadMax && !SharedVault.shared.isLocal(s)
            }.map(\.id)
        }
        for id in ids where downloads[id] == nil && uploads[id] == nil { download(id) }
    }

    // ---------- Speicher: Stand + Aufraeumen ----------
    func refreshInfo() async {
        guard let i = try? await info() else { return }
        var st = SharedStorage()
        st.used = (i["used"] as? NSNumber)?.int64Value ?? 0
        st.quota = (i["quota"] as? NSNumber)?.int64Value ?? 0
        st.bigCount = (i["bigItems"] as? NSNumber)?.intValue ?? 0
        st.bigBytes = (i["bigBytes"] as? NSNumber)?.int64Value ?? 0
        if st.quota > 0 { storage = st; emit() }   // alter Server ohne v2 -> kein Speicherstand
    }
    func evict(_ ids: [String]) async -> Int {
        guard let tok = token, let p = try? vaultPath() else { return 0 }
        var n = 0
        for id in ids {
            if (try? await request("POST", p + "/items/" + id.lowercased() + "/evict", auth: tok)) != nil {
                n += 1
                await MainActor.run { SharedVault.shared.setServerMeta(id, gone: true, expiresAt: nil) }
            }
        }
        syncLog("aufgeraeumt: \(n) grosse Datei(en) vom Server")
        await refreshInfo()
        return n
    }
    /// Metadaten des Servers zu grossen Eintraegen uebernehmen (abgelaufen? wann?)
    private func applyMeta(_ rows: [[String: Any]]) async {
        let metas: [(String, Bool, Double?)] = rows.compactMap { r in
            guard let id = (r["id"] as? String)?.lowercased(), (r["parts"] as? NSNumber)?.intValue ?? 0 > 0, (r["deleted"] as? Bool) != true else { return nil }
            return (id, r["gone"] as? Bool ?? false, (r["expires_at"] as? NSNumber).map { $0.doubleValue / 1000 })
        }
        guard !metas.isEmpty else { return }
        await MainActor.run { for (id, g, e) in metas { SharedVault.shared.setServerMeta(id, gone: g, expiresAt: e) } }
    }

    // ---------- Nachholen ----------
    func catchUp() async {
        guard isPaired, let tok = token else { return }
        if catching { catchAgain = true; return }
        catching = true; defer { catching = false }
        repeat {
            catchAgain = false
            var cursor = cfg.cursor ?? 0
            var more = true
            while more {
                guard let (d, _) = try? await request("GET", try vaultPath() + "/since?t=\(cursor)", auth: tok) else { return }
                let o = obj(d)
                let rows = o["items"] as? [[String: Any]] ?? []
                more = o["more"] as? Bool ?? false
                let next = (o["next"] as? NSNumber)?.int64Value ?? cursor
                let local: [String: (Double, Bool)] = await MainActor.run {
                    var m = [String: (Double, Bool)]()
                    for s in SharedVault.shared.items where !SharedVault.shared.isHiddenTombstone(s) {
                        m[s.id.lowercased()] = (s.updatedAt.timeIntervalSince1970, s.isBig || s.deleted)
                    }
                    for v in VocabStore.shared.entries { m[v.id.lowercased()] = (v.updatedAt, true) }
                    return m
                }
                var got: [SharedItem] = [], names: [VocabEntry] = []
                for r in rows {
                    guard let id = (r["id"] as? String)?.lowercased() else { continue }
                    let upd = (r["updated_at"] as? NSNumber)?.doubleValue ?? 0
                    let del = r["deleted"] as? Bool ?? false
                    let have = local[id]
                    let rowBig = ((r["parts"] as? NSNumber)?.intValue ?? 0) > 0
                    // lokal gleich/neuer — ausser: grosser Eintrag, den eine aeltere Fassung nur als Hinweis-Text kannte
                    if let h = have, h.0 >= upd - 0.000_5, !(rowBig && !h.1) { continue }
                    if have == nil && del { continue }                               // Grabstein fuer Unbekanntes
                    var blob: Data? = (r["blob"] as? String).flatMap { Data(base64Encoded: $0) }
                    if blob == nil { blob = try? await fetchBlob(id) }
                    switch blob.flatMap({ open(id, $0) }) {
                    case .item(let it)?: got.append(it)
                    case .vocab(let v)?: names.append(v)
                    case nil: break
                    }
                }
                if !got.isEmpty { await apply(got, live: false) }
                if !names.isEmpty { await applyVocab(names, live: false) }
                await applyMeta(rows)
                if next != cursor { cursor = next; cfg.cursor = cursor; cfg.save() }
            }
        } while catchAgain
        await autoDownloads()
    }
    private func fetchBlob(_ id: String) async throws -> Data {
        guard let tok = token else { throw SyncError(message: "nicht gekoppelt") }
        let (d, _) = try await request("GET", try vaultPath() + "/items/" + id, auth: tok)
        return d
    }
    private func open(_ id: String, _ blob: Data) -> SyncWire.Opened? {
        guard let k = key, let v = cfg.vaultId else { return nil }
        do {
            let o = try SyncWire.decodeAny(try SyncWire.open(blob, key: k, aad: SyncWire.aad(vault: v, id: id)))
            let oid: String
            switch o { case .item(let it): oid = it.id; case .vocab(let e): oid = e.id }
            guard oid.lowercased() == id else { syncLog("Eintrag verworfen (id passt nicht)"); return nil }
            return o
        } catch {
            syncLog("Eintrag nicht entschluesselbar — verworfen")
            return nil
        }
    }
    private func apply(_ items: [SharedItem], live: Bool) async {
        let now = Date()
        if live, let newest = items.map(\.updatedAt).max() {
            let ms = max(0, Int((now.timeIntervalSince1970 - newest.timeIntervalSince1970) * 1000))
            lastLatencyMs = ms
        }
        received += items.count
        let latency = lastLatencyMs
        await MainActor.run {
            let before = Set(SharedVault.shared.items.filter { !$0.deleted }.map(\.id))
            SharedVault.shared.applyRemote(items)
            let fresh = items.filter { !$0.deleted && !before.contains($0.id) && $0.createdBy != SharedVault.shared.me }
            if live { cvLog("Sync: live empfangen \(items.count) (\(latency.map { "\($0) ms" } ?? "?") nach Aenderung)") }
            else { cvLog("Sync: nachgeholt \(items.count)") }
            if let f = fresh.first, !CV_HEADLESS, SyncBackend.notifyEnabled { Toast.shared.show("\(f.createdBy) hat etwas geteilt") }
        }
        emit()
    }

    // ---------- WebSocket ----------
    private func wsURL() -> URL? {
        guard let p = try? vaultPath() else { return nil }
        var s = p + "/ws?device=" + device
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) } else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        return URL(string: s)
    }
    private func connect() {
        guard isPaired, let u = wsURL(), let tok = token else { return }
        gen += 1; let g = gen
        ws?.cancel(with: .goingAway, reason: nil)
        var r = URLRequest(url: u)
        r.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        r.setValue(device, forHTTPHeaderField: "X-CV-Device")
        let t = wsSession.webSocketTask(with: r)
        t.maximumMessageSize = 16 * 1024 * 1024
        ws = t; lastPong = Date.distantPast
        if state != "connected" { setState("connecting") }
        syncDebug("verbinde (gen \(g))")
        t.resume()
        Task { await self.receiveLoop(t, g) }
        Task { await self.pingLoop(t, g) }
    }
    private func receiveLoop(_ t: URLSessionWebSocketTask, _ g: Int) async {
        while g == gen {
            let m: URLSessionWebSocketTask.Message
            do { m = try await t.receive() } catch {
                let code = (error as NSError).code
                await failed(g, t.closeCode != .invalid ? "vom Server geschlossen (\(t.closeCode.rawValue))" : "Verbindung getrennt (\(code))"); return
            }
            guard g == gen else { return }
            switch m {
            case .string(let s): await handle(s, g)
            case .data(let d): if let s = String(data: d, encoding: .utf8) { await handle(s, g) }
            @unknown default: break
            }
        }
    }
    /// Alle 30 s "ping"; kommt auf einen Ping binnen 10 s kein "pong", gilt die Verbindung als tot.
    private func pingLoop(_ t: URLSessionWebSocketTask, _ g: Int) async {
        while g == gen {
            let sent = Date()
            do { try await t.send(.string("ping")) } catch { await failed(g, "Senden fehlgeschlagen"); return }
            syncDebug("ping gesendet (gen \(g))")
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard g == gen else { return }
            if lastPong < sent { await failed(g, "keine Antwort vom Server"); return }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }
    private func handle(_ s: String, _ g: Int) async {
        if s == "pong" {
            lastPong = Date()
            syncDebug("pong (gen \(g), Zustand \(state))")
            if state != "connected" {
                backoff = 1; setState("connected")
                syncLog("verbunden (live)")
                Task { await self.catchUp(); await self.flush(); await self.refreshInfo() }
            }
            return
        }
        let o = obj(Data(s.utf8))
        switch o["type"] as? String {
        case "item":
            guard let id = (o["id"] as? String)?.lowercased() else { return }
            await applyMeta([o])                                                          // abgelaufen/aufgeraeumt gilt auch fuer eigene
            if (o["device"] as? String)?.lowercased() == device { return }                 // eigenes Echo
            if ((o["parts"] as? NSNumber)?.intValue ?? 0) > 0, (o["updated_at"] as? NSNumber)?.doubleValue ?? 0 <= (await MainActor.run { SharedVault.shared.item(id)?.updatedAt.timeIntervalSince1970 } ?? -1) + 0.000_5 {
                return                                                                     // nur Metadaten geaendert
            }
            var blob = (o["blob"] as? String).flatMap { Data(base64Encoded: $0) }
            if blob == nil { blob = try? await fetchBlob(id) }
            switch blob.flatMap({ open(id, $0) }) {
            case .item(let it)?: await apply([it], live: true); await applyMeta([o]); await autoDownloads()
            case .vocab(let v)?: await applyVocab([v], live: true)
            case nil: break
            }
            // Cursor bleibt beim Nachholen (dort lueckenlos); der naechste Durchlauf ueberspringt Bekanntes.
        case "peer":
            if (o["event"] as? String) == "joined" { partnerDidJoin() }
        default: break
        }
    }
    private func failed(_ g: Int, _ why: String) async {
        guard g == gen else { return }
        gen += 1
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        guard isPaired else { return }
        let wasConnected = state == "connected"
        setState("offline", why)
        let wait = backoff + Double.random(in: 0...0.5)
        if wasConnected || backoff >= 30 { syncLog("getrennt: \(why) — neuer Versuch in \(Int(wait.rounded())) s") }
        backoff = min(backoff * 2, 30)
        let mine = gen
        Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            await self.reconnectIfIdle(mine)
        }
    }
    private func reconnectIfIdle(_ g: Int) {
        guard g == gen, ws == nil, isPaired else { return }
        connect()
    }
    /// Aufwachen / Netz wieder da: sofort neu verbinden + nachholen
    func kick() async {
        guard isPaired else { return }
        if state != "connected" || ws == nil { backoff = 1; connect() }
        else { Task { await self.probe() }; await catchUp(); await flush() }
    }
    /// Audit 27.09.2026: nach dem Aufwachen oder einem Netzwechsel haengt die alte Verbindung oft halbtot
    /// ("keine Antwort vom Server" / errno 57 erst beim naechsten Ping, bis zu 40 s spaeter — so lange kam
    /// nichts live an). Jetzt sofort ein Ping; ohne pong binnen 5 s wird neu verbunden.
    private func probe() async {
        guard let t = ws else { return }
        let g = gen, sent = Date()
        do { try await t.send(.string("ping")) } catch { await failed(g, "Senden fehlgeschlagen"); return }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard g == gen else { return }
        if lastPong < sent { await failed(g, "keine Antwort nach Aufwachen/Netzwechsel") }
    }
    func shutdown() {
        gen += 1; ws?.cancel(with: .goingAway, reason: nil); ws = nil
    }
}

// MARK: - Einklinken in ClipVault (wird ueber den ObjC-Namen gefunden, siehe shared.swift)
@objc(ClipVaultSyncBackend)
final class SyncBackend: NSObject, SharedVaultBackend, SharedVaultCommandHandler, SharedVaultStatusProvider, SharedVaultPanelUI, SharedVaultTransferBackend {
    static weak var current: SyncBackend?
    private(set) var snap = SyncSnapshot()
    private var engine: SyncEngine!
    private var pathMonitor: NWPathMonitor?
    private var lastPathOK: Bool?
    private var lastPathIfaces: [String] = []

    override init() {
        super.init()
        engine = SyncEngine(publish: { [weak self] s in DispatchQueue.main.async { self?.update(s) } })
        SyncBackend.current = self
    }
    var backendName: String { "cloudflare" }
    static var notifyEnabled: Bool {
        let s = (try? String(contentsOfFile: SyncFiles.notify, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["1", "an", "on", "ja", "true"].contains(s)
    }

    func start(vault: SharedVault) {
        let e = engine!
        Task { await e.boot() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await e.kick() }
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in
            let ok = p.status == .satisfied
            let ifaces = p.availableInterfaces.map(\.name)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Netz wieder da ODER anderes Netz (z. B. WLAN -> iPhone-Hotspot): die alte Verbindung pruefen
                let switched = ok && self.lastPathOK == true && !self.lastPathIfaces.isEmpty && ifaces != self.lastPathIfaces
                if ok && (self.lastPathOK == false || switched) { Task { await e.kick() } }
                self.lastPathOK = ok; self.lastPathIfaces = ifaces
            }
        }
        m.start(queue: DispatchQueue(label: "clipvault.sync.path"))
        pathMonitor = m
    }
    func push(_ item: SharedItem) {
        let e = engine!, id = item.id
        Task { await e.enqueue(id) }
    }
    // ---- Dateien in Teilen ----
    func download(_ id: String) { let e = engine!; Task { await e.download(id) } }
    func cancelTransfer(_ id: String) { let e = engine!; Task { await e.cancelTransfer(id) } }
    func evict(_ ids: [String]) { let e = engine!; Task { _ = await e.evict(ids) } }
    func refreshStorage() { let e = engine!; Task { await e.refreshInfo() } }

    func stop() {
        pathMonitor?.cancel()
        let e = engine!
        Task { await e.shutdown() }
    }

    private var wroteOnce = false
    private func update(_ s: SyncSnapshot) {
        if !wroteOnce { wroteOnce = true; snap = s; cvStatusWriter?(); ChangeNotifier.bump(); return }   // erster Stand sofort in status.txt
        guard s != snap else { return }
        let stateChanged = s.state != snap.state || s.pairingCode != snap.pairingCode || s.partnerJoined != snap.partnerJoined
        snap = s
        if SharedVault.shared.storage != s.storage { SharedVault.shared.storage = s.storage }
        cvStatusWriter?()
        if stateChanged { ChangeNotifier.bump(); PanelController.shared?.refreshAfterExternalChange() }
    }

    // status.txt — `sync=keins` solange nicht gekoppelt (der Hub zeigt dann „Nicht verbunden")
    var statusLines: [String] {
        var l = [snap.paired ? "sync=cloudflare" : "sync=keins", "sync_state=\(snap.state)", "sync_queue=\(snap.queue)"]
        if snap.paired { l.append("sync_partner=\(SharedVault.shared.partner)") }
        if !snap.reason.isEmpty { l.append("sync_reason=\(snap.reason)") }
        if let ms = snap.lastLatencyMs { l.append("sync_latenz_ms=\(ms)") }
        if let st = snap.storage { l.append("sync_used=\(st.used)"); l.append("sync_quota=\(st.quota)") }
        let vin = VocabStore.shared.inbox.count
        if vin > 0 { l.append("vocab_inbox=\(vin)") }
        let tr = SharedVault.shared.transfers
        if !tr.isEmpty {
            l.append("sync_transfers=" + tr.map { "\($0.key):\($0.value.dir == .up ? "up" : "down"):\(Int($0.value.fraction * 100))" }.sorted().joined(separator: ","))
        }
        return l
    }

    // Befehle: pairCreate · pairJoin (code=…) · pairCancel · unpair · syncStatus · syncSetup (url=…) · storage
    //          sendVocab (word=…, type=…) · vocabInbox (opt. all=1) · vocabAck (id=… | ids=a,b | all=1)
    func handlesCommand(_ action: String) -> Bool {
        ["pairCreate", "pairJoin", "pairCancel", "unpair", "syncStatus", "syncSetup", "storage",
         "sendVocab", "vocabInbox", "vocabAck", "setPartner"].contains(action)
    }
    func handleCommand(_ action: String, _ o: [String: Any], reply: @escaping (CommandChannel.Result) -> Void) {
        let e = engine!
        let me = SharedVault.shared.me
        func str(_ k: String) -> String? { (o[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        func flag(_ k: String) -> Bool { (o[k] as? Bool) == true || ["1", "true", "ja"].contains(str(k)?.lowercased() ?? "") }
        // Partner-Name kann bei jedem Kopplungs-Befehl mitkommen (name=…) – der Nutzer gibt ihn beim Koppeln ein
        if let n = str("name"), ["pairCreate", "pairJoin", "setPartner"].contains(action) { SharedVault.shared.setPartner(n) }
        switch action {
        case "setPartner":
            if str("name") == nil { SharedVault.shared.setPartner("") }
            reply(CommandChannel.Result(ok: true, extra: ["partner": SharedVault.shared.partner]))
            return
        case "vocabInbox":
            let list = flag("all") ? VocabStore.shared.entries.sorted { $0.createdAt > $1.createdAt } : VocabStore.shared.inbox
            reply(CommandChannel.Result(ok: true, extra: ["items": list.map(VocabStore.json), "count": VocabStore.shared.inbox.count]))
            return
        case "vocabAck":
            var ids: [String]? = nil
            if !flag("all") {
                let raw = (str("ids") ?? str("id") ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).map(String.init)
                guard !raw.isEmpty else { reply(CommandChannel.Result(ok: false, error: "id, ids oder all fehlt")); return }
                ids = raw
            }
            let done = VocabStore.shared.ack(ids)
            cvStatusWriter?()
            reply(CommandChannel.Result(ok: true, extra: ["acked": done, "count": VocabStore.shared.inbox.count]))
            return
        case "sendVocab":
            guard let w = VocabStore.clean(str("word") ?? str("text") ?? "") else {
                reply(CommandChannel.Result(ok: false, error: "kein gueltiges Wort (2–60 Zeichen, hoechstens 4 Woerter)")); return
            }
            let type = VocabStore.type(str("type"))
            Task {
                do { reply(CommandChannel.Result(ok: true, extra: try await e.sendVocab(word: w, type: type, by: me))) }
                catch let err as SyncError { reply(CommandChannel.Result(ok: false, error: err.message)) }
                catch { reply(CommandChannel.Result(ok: false, error: "\(error)")) }
            }
            return
        default: break
        }
        Task {
            do {
                var r: [String: Any]
                switch action {
                case "pairCreate": r = try await e.pairCreate(me: me)
                case "pairJoin":
                    guard let c = str("code") ?? str("text") else { throw SyncError(message: "code fehlt") }
                    r = try await e.pairJoin(c)
                case "pairCancel": r = await e.pairCancel()
                case "unpair": r = await e.unpair()
                case "syncSetup":
                    guard let u = str("url") ?? str("text") else { throw SyncError(message: "url fehlt") }
                    r = try await e.setup(url: u, initSecret: str("initSecret"))
                case "storage":
                    await e.refreshInfo(); r = await e.status()
                default: r = await e.status()
                }
                reply(CommandChannel.Result(ok: true, id: r["code"] as? String, extra: r))
            } catch let err as SyncError {
                reply(CommandChannel.Result(ok: false, error: err.message))
            } catch {
                reply(CommandChannel.Result(ok: false, error: "\(error)"))
            }
        }
    }

    // ---- kleine Oberflaeche im Panel („Geteilt“), damit Nico ohne Hub koppeln kann ----
    var panelStatusText: String {
        switch snap.state {
        case "connected": return "Verbunden mit \(SharedVault.shared.partner) · live"
        case "waiting": return "Tresor bereit — \(SharedVault.shared.partner) ist noch nicht gekoppelt."
        case "pairing": return "Code wird angezeigt — wartet auf \(SharedVault.shared.partner) …"
        case "connecting": return "Verbinde …"
        case "offline": return "Offline — \(snap.reason.isEmpty ? "wartet auf Netz" : snap.reason)"
        case "unpaired": return "Noch nicht mit \(SharedVault.shared.partner) gekoppelt."
        default: return "Sync noch nicht eingerichtet (clipvault sync setup <url>)."
        }
    }
    var wantsPairButton: Bool { ["unpaired", "waiting", "pairing"].contains(snap.state) }

    func presentPairingDialog() {
        let a = NSAlert()
        a.messageText = "Mit einem Freund/Partner koppeln"
        a.informativeText = "Name eingeben, dann den Code des anderen einfügen — oder selbst einen Code erzeugen und ihn privat schicken."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
        nameField.placeholderString = "Name des Freundes/Partners"
        let known = SharedVault.shared.partner
        if known != "Partner" { nameField.stringValue = known }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "cvpair1.…"
        box.addSubview(nameField); box.addSubview(field)
        a.accessoryView = box
        a.addButton(withTitle: "Verbinden"); a.addButton(withTitle: "Code erzeugen"); a.addButton(withTitle: "Abbrechen")
        a.window.initialFirstResponder = nameField
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        if r != .alertThirdButtonReturn, !nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            SharedVault.shared.setPartner(nameField.stringValue)
        }
        let partner = SharedVault.shared.partner
        let e = engine!, me = SharedVault.shared.me
        if r == .alertFirstButtonReturn {
            let code = field.stringValue
            Task {
                do { _ = try await e.pairJoin(code); await MainActor.run { Toast.shared.show("Mit \(partner) verbunden") } }
                catch let err as SyncError { await MainActor.run { Toast.shared.show(err.message) } }
                catch {}
            }
        } else if r == .alertSecondButtonReturn {
            Task {
                do {
                    let res = try await e.pairCreate(me: me)
                    let code = res["code"] as? String ?? ""
                    await MainActor.run { SyncBackend.showCode(code, partner: partner) }
                } catch let err as SyncError { await MainActor.run { Toast.shared.show(err.message) } }
                catch {}
            }
        }
    }
    @MainActor static func showCode(_ code: String, partner: String) {
        let a = NSAlert()
        a.messageText = "Code für \(partner)"
        a.informativeText = "15 Minuten gültig. \(partner) fügt ihn bei sich ein (Geteilt → Koppeln oder `clipvault pair join <code>`). Der Code enthält den Tresor-Schlüssel — nur privat schicken."
        let tf = NSTextField(wrappingLabelWithString: code)
        tf.isSelectable = true; tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.frame = NSRect(x: 0, y: 0, width: 340, height: 64)
        a.accessoryView = tf
        a.addButton(withTitle: "Kopieren"); a.addButton(withTitle: "Schließen")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(code, forType: .string)
            pb.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))   // nicht in den Verlauf
            AppState.shared.lastChange = pb.changeCount
            Toast.shared.show("Code kopiert")
        }
    }
}

// MARK: - Kommandozeile:  clipvault sync-agent | pair … | unpair | sync …
func runSyncCLI(_ args: [String]) -> Never {
    let sub = args.count >= 3 ? args[2] : ""
    switch args[1] {
    case "sync-agent":
        // Kopf-loser Zweit-/Testbetrieb: nur Befehlskanal + geteilter Tresor + Sync (kein Panel, keine Zwischenablage)
        let fd = open(CV_DIR + "app.lock", O_CREAT | O_RDWR, 0o644)
        if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 { print("laeuft bereits in \(CV_DIR)"); exit(0) }
        CV_HEADLESS = true
        try? FileManager.default.createDirectory(atPath: CV_DIR, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let started = Date()
        cvStatusWriter = {
            let s = """
            pid=\(ProcessInfo.processInfo.processIdentifier)
            modus=sync-agent
            eintraege=\(Store.shared.items.count)
            befehle=\(CommandChannel.shared.handled) ok, \(CommandChannel.shared.rejected) abgelehnt
            geteilt=\(SharedVault.shared.visible.count) (\(SharedVault.shared.pending.count) wartend)
            shared_new=\(SharedSeen.shared.newCount)
            \(cvSyncStatusLines().joined(separator: "\n"))
            seit=\(ISO8601DateFormatter().string(from: started))
            """
            try? s.write(toFile: CV_DIR + "status.txt", atomically: true, encoding: .utf8)
        }
        CommandChannel.shared.start()
        SharedVaultHook.bootstrap()
        SharedSeen.shared.startWatching()
        cvStatusWriter?()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in cvStatusWriter?() }
        cvLog("sync-agent gestartet (\(CV_DIR))")
        print("sync-agent laeuft (\(CV_DIR)) — Befehle: CLIPVAULT_HOME=\(CV_DIR) clipvault send …"); fflush(stdout)
        app.run()
        exit(0)
    case "pair":
        switch sub {
        case "create", "code": syncSend("pairCreate", args.count >= 4 ? ["name": args[3...].joined(separator: " ")] : [:])
        case "join":
            guard args.count >= 4 else { print("clipvault pair join <code> [name]"); exit(2) }
            syncSend("pairJoin", args.count >= 5 ? ["code": args[3], "name": args[4...].joined(separator: " ")] : ["code": args[3]])
        case "cancel": syncSend("pairCancel", [:])
        case "status", "": syncSend("syncStatus", [:])
        default: print("clipvault pair create [name] | join <code> [name] | cancel | status"); exit(2)
        }
    case "unpair": syncSend("unpair", [:])
    case "partner": syncSend("setPartner", args.count >= 3 ? ["name": args[2...].joined(separator: " ")] : [:])
    default: // sync
        switch sub {
        case "setup":
            guard args.count >= 4 else { print("clipvault sync setup <worker-url> [init-geheimnis]"); exit(2) }
            syncSend("syncSetup", args.count >= 5 ? ["url": args[3], "initSecret": args[4]] : ["url": args[3]])
        case "status", "": syncSend("syncStatus", [:])
        default: print("clipvault sync setup <url> [init-geheimnis] | status"); exit(2)
        }
    }
}
private func syncSend(_ action: String, _ extra: [String: Any]) -> Never {
    guard let token = CVToken.read() else { print("Kein Schluessel in \(CV_DIR)token — laeuft ClipVault?"); exit(1) }
    var o = extra; o["token"] = token; o["action"] = action
    let req = UUID().uuidString; o["reqId"] = req
    let data = try! JSONSerialization.data(withJSONObject: o)
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    DistributedNotificationCenter.default().addObserver(forName: CommandChannel.resultName, object: nil, queue: .main) { n in
        guard let s = n.object as? String, s.contains(req) else { return }
        guard let d = s.data(using: .utf8), let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { print(s); exit(1) }
        if r["ok"] as? Bool == true {
            if let code = r["code"] as? String {
                print("Kopplungscode (15 min gueltig, enthaelt den Tresor-Schluessel — nur privat weitergeben):\n\n\(code)\n")
            } else {
                let clean = r.filter { !["reqId", "action", "ok", "id"].contains($0.key) }
                let out = (try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("ok \(out)")
            }
            exit(0)
        }
        print("Fehler: \(r["error"] as? String ?? "?")"); exit(1)
    }
    DistributedNotificationCenter.default().postNotificationName(CommandChannel.cmdName, object: String(data: data, encoding: .utf8)!, userInfo: nil, deliverImmediately: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("Keine Antwort (laeuft ClipVault in \(CV_DIR)?)"); exit(1) }
    app.run()
    exit(1)
}
