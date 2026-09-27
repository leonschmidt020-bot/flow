// ClipVault — Datenmodell + Verlauf (index.json / collections.json)
// Das Dateiformat ist in PROTOCOL.md beschrieben — andere Programme (z. B. der Hub) lesen es.
// Neue Felder IMMER optional anlegen, damit alte index.json-Dateien weiter lesbar bleiben.
import Cocoa

// MARK: - Model
struct FileRef: Codable { let name: String; let stored: String?; let orig: String }
struct Collection: Codable {
    let id: String; var name: String; var symbol: String
    /// Geheim-Bereich (Passwoerter): Eintraege verborgen (•••) und nach 24 h geloescht, ausser angeheftet.
    /// nil = automatisch am Namen erkennen ("Passwörter", "Kennwörter", "Geheim", "Secret").
    var secret: Bool? = nil
    var isSecret: Bool { secret ?? Collection.looksSecret(name) }
    static func looksSecret(_ n: String) -> Bool {
        let l = n.lowercased()
        return l.contains("passw") || l.contains("kennw") || l.contains("geheim") || l.contains("secret")
    }
}
final class ClipItem {
    enum Kind: String { case text, image, file }
    let id: String; let kind: Kind
    var text: String? { didSet { cachedBadges = nil } }
    var imageFile: String?
    var date: Date; var thumb: NSImage?; var bigThumb: NSImage?; var source: String?; var files: [FileRef]?; var pinned: Bool = false; var collection: String?
    var ocrText: String?          // erkannter Text (nur Bilder); "" = geprueft, kein Text
    var shared: Bool = false      // fuer den geteilten Tresor freigegeben
    var collectedAt: Date?        // seit wann im aktuellen Bereich (Ablauf im Passwort-Bereich)
    var edited: Date?             // zuletzt von Hand bearbeitet
    var origin: String?           // nur Bilder: Originaldatei (Screenshot/Finder), falls bekannt
    var imagePrint: ImagePrint?   // nur im Speicher: Fingerabdruck fuer den Doppel-Abgleich (imagededupe.swift)
    private var cachedBadges: [Badge]?
    var badges: [Badge] {
        if let b = cachedBadges { return b }
        let b = kind == .text ? detectBadges(text ?? "") : []
        cachedBadges = b; return b
    }
    init(id: String = UUID().uuidString, kind: Kind, text: String? = nil, imageFile: String? = nil, date: Date = Date(), source: String? = nil, files: [FileRef]? = nil, pinned: Bool = false, collection: String? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.imageFile = imageFile; self.date = date; self.source = source; self.files = files; self.pinned = pinned; self.collection = collection
    }
}
struct StoredItem: Codable {
    let id: String; let kind: String; let text: String?; let image: String?; let ts: Double; let source: String?; let files: [FileRef]?; let pinned: Bool?; let collection: String?
    // seit 26.09.2026 (alle optional -> alte Dateien bleiben lesbar)
    var ocrText: String? = nil
    var shared: Bool? = nil
    var collectedAt: Double? = nil
    var edited: Double? = nil
    // seit 27.09.2026
    var origin: String? = nil
    /// Nur zur Info fuer andere Programme (wird beim Lesen ignoriert und neu berechnet)
    var badges: [String]? = nil
}

// MARK: - Store
final class Store {
    static let shared = Store()
    private(set) var items: [ClipItem] = []
    var collections: [Collection] = []
    let dir: URL; let maxItems = 200; let maxAge: TimeInterval = 2*24*3600
    static let secretTTL: TimeInterval = 24*3600
    init() {
        let base = URL(fileURLWithPath: CV_DIR, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base; loadCollections(); load()
    }
    var indexURL: URL { dir.appendingPathComponent("index.json") }
    var collectionsURL: URL { dir.appendingPathComponent("collections.json") }
    func item(_ id: String) -> ClipItem? { items.first { $0.id == id } }
    func collection(_ id: String?) -> Collection? { guard let id = id else { return nil }; return collections.first { $0.id == id } }
    func isSecret(_ collectionId: String?) -> Bool { collection(collectionId)?.isSecret ?? false }
    /// Wann laeuft ein Eintrag im Passwort-Bereich ab? nil = laeuft nicht ab.
    func secretExpiry(_ it: ClipItem) -> Date? {
        guard !it.pinned, isSecret(it.collection) else { return nil }
        return (it.collectedAt ?? it.date).addingTimeInterval(Store.secretTTL)
    }

    func loadCollections() {
        if let data = try? Data(contentsOf: collectionsURL), let cs = try? JSONDecoder().decode([Collection].self, from: data) {
            collections = cs
        } else {
            collections = [Collection(id: UUID().uuidString, name: "Arbeit", symbol: "briefcase.fill"),
                           Collection(id: UUID().uuidString, name: "Passwörter", symbol: "lock.fill")]
            persistCollections()
        }
    }
    func persistCollections() {
        guard !CV_READ_ONLY else { return }
        if let d = try? JSONEncoder().encode(collections) { try? d.write(to: collectionsURL, options: .atomic) }
        ChangeNotifier.bump()
    }
    @discardableResult func addCollection(name: String, symbol: String, secret: Bool? = nil) -> Collection {
        let c = Collection(id: UUID().uuidString, name: name, symbol: symbol, secret: secret); collections.append(c); persistCollections(); return c
    }
    func renameCollection(id: String, name: String?, symbol: String?) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        if let n = name, !n.isEmpty { collections[i].name = n }
        if let s = symbol, !s.isEmpty { collections[i].symbol = s }
        persistCollections()
    }
    func removeCollection(id: String) {
        for it in items where it.collection == id { it.collection = nil; it.collectedAt = nil }
        collections.removeAll { $0.id == id }; persistCollections(); persist()
    }
    func setCollection(itemId: String, collectionId: String?) {
        if let it = items.first(where: { $0.id == itemId }) {
            it.collection = collectionId
            it.collectedAt = collectionId == nil ? nil : Date()
            if collectionId != nil { it.pinned = false }
            persist()
        }
    }
    func delete(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) { removeStorage(items[idx]); items.remove(at: idx); persist() }
    }
    @discardableResult func setPinned(id: String, _ p: Bool) -> Bool {
        guard let it = item(id) else { return false }
        if it.pinned != p { it.pinned = p; persist() }
        return true
    }
    /// Text eines Text-Eintrags ersetzen (Bearbeiten vor dem Kopieren / Hub-Befehl `edit`)
    @discardableResult func edit(id: String, text: String) -> Bool {
        guard let it = item(id), it.kind == .text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if it.text != text { it.text = text; it.edited = Date(); persist() }
        return true
    }
    func setOCR(id: String, text: String) {
        guard let it = item(id) else { return }
        it.ocrText = text; persist()
    }
    func setShared(id: String, _ s: Bool) {
        guard let it = item(id), it.shared != s else { return }
        it.shared = s; persist()
    }
    /// Verlauf + Bereiche neu von der Platte lesen (Befehl `reload`)
    func reloadFromDisk() { loadCollections(); load() }

    // STABIL (16.08.2026): Der Verlauf wurde frueher unverschluesselt "einfach so" geschrieben.
    // Stuerzte der Rechner mitten im Schreiben ab, war index.json halb geschrieben = kaputt —
    // und beim naechsten Start war der GANZE Verlauf weg, ohne jede Meldung.
    // Jetzt: immer atomar schreiben (erst temporaer, dann umbenennen) + eine Sicherheitskopie
    // der letzten heilen Fassung. Ist die Hauptdatei kaputt, kommt die Kopie zum Einsatz.
    var backupURL: URL { dir.appendingPathComponent("index.bak.json") }
    private func decodeIndex(_ url: URL) -> [StoredItem]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode([StoredItem].self, from: data)
    }
    func load() {
        var stored = decodeIndex(indexURL)
        if stored == nil && FileManager.default.fileExists(atPath: indexURL.path) && !CV_READ_ONLY {
            // Hauptdatei ist beschaedigt -> Sicherheitskopie versuchen, kaputte Datei aufheben
            cvLog("Verlauf beschaedigt — versuche Sicherheitskopie")
            stored = decodeIndex(backupURL)
            let broken = dir.appendingPathComponent("index.kaputt.json")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: indexURL, to: broken)
            cvLog(stored == nil ? "Sicherheitskopie fehlt/kaputt — Verlauf startet leer" : "Verlauf aus Sicherheitskopie wiederhergestellt (\(stored!.count) Eintraege)")
        }
        guard let stored = stored else { return }
        items = stored.map { s in
            autoreleasepool {
                let it = ClipItem(id: s.id, kind: ClipItem.Kind(rawValue: s.kind) ?? .text, text: s.text, imageFile: s.image, date: Date(timeIntervalSince1970: s.ts), source: s.source, files: s.files, pinned: s.pinned ?? false, collection: s.collection)
                it.ocrText = s.ocrText; it.shared = s.shared ?? false
                it.collectedAt = s.collectedAt.map { Date(timeIntervalSince1970: $0) }
                it.edited = s.edited.map { Date(timeIntervalSince1970: $0) }
                it.origin = s.origin
                if let f = s.image { it.thumb = loadThumb(url: dir.appendingPathComponent(f)) }
                if it.kind == .file { it.thumb = self.fileIcon(it.files) }
                return it
            }
        }
        var dirty = migrateSecrets()
        if prune() { dirty = true }
        if dirty { persist() }
    }
    /// Einmalig (26.09.2026): Der Passwort-Bereich laeuft ab jetzt nach 24 h ab. Was Lena vorher
    /// bewusst dort abgelegt hat, soll dadurch NICHT verschwinden -> diese Eintraege werden angeheftet.
    private func migrateSecrets() -> Bool {
        var dirty = false
        let marker = dir.appendingPathComponent(".passwort-ablauf-v1")
        if !CV_READ_ONLY && !FileManager.default.fileExists(atPath: marker.path) {
            var n = 0
            for it in items where isSecret(it.collection) && !it.pinned { it.pinned = true; n += 1 }
            try? "Bestehende Passwort-Eintraege angeheftet: \(n)\n".write(to: marker, atomically: true, encoding: .utf8)
            if n > 0 { cvLog("Passwort-Bereich: \(n) bestehende Eintraege angeheftet (laufen nicht ab)"); dirty = true }
        }
        for it in items where isSecret(it.collection) && it.collectedAt == nil { it.collectedAt = Date(); dirty = true }
        return dirty
    }
    private var lastBackup = Date.distantPast
    func persist() {
        guard !CV_READ_ONLY else { return }
        let stored = items.map { i -> StoredItem in
            var s = StoredItem(id: i.id, kind: i.kind.rawValue, text: i.text, image: i.imageFile, ts: i.date.timeIntervalSince1970, source: i.source, files: i.files, pinned: i.pinned, collection: i.collection)
            s.ocrText = i.ocrText; s.shared = i.shared ? true : nil
            s.collectedAt = i.collectedAt?.timeIntervalSince1970; s.edited = i.edited?.timeIntervalSince1970
            s.origin = i.origin
            let b = i.badges; s.badges = b.isEmpty ? nil : b.map { $0.rawValue }
            return s
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        // Sicherheitskopie der noch heilen Fassung (hoechstens alle 60 s, kostet sonst unnoetig Platte)
        if Date().timeIntervalSince(lastBackup) > 60, FileManager.default.fileExists(atPath: indexURL.path),
           let old = try? Data(contentsOf: indexURL), !old.isEmpty {
            try? old.write(to: backupURL, options: .atomic); lastBackup = Date()
        }
        do { try data.write(to: indexURL, options: .atomic) }
        catch { cvLog("Verlauf konnte nicht gespeichert werden: \(error.localizedDescription)") }
        ChangeNotifier.bump()
    }
    func removeStorage(_ it: ClipItem) {
        guard !CV_READ_ONLY else { return }
        if let f = it.imageFile { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        if it.kind == .file { try? FileManager.default.removeItem(at: dir.appendingPathComponent("files/\(it.id)")) }
    }
    func fileIcon(_ refs: [FileRef]?) -> NSImage? {
        guard let r = refs?.first else { return nil }
        let path = FileManager.default.fileExists(atPath: r.orig) ? r.orig : (r.stored.map { dir.appendingPathComponent($0).path } ?? r.orig)
        let ic = NSWorkspace.shared.icon(forFile: path); ic.size = NSSize(width: 40, height: 40); return ic
    }
    /// Alte Eintraege entfernen. Rueckgabe: wurde etwas geloescht?
    @discardableResult func prune() -> Bool {
        let now = Date(), cutoff = now.addingTimeInterval(-maxAge)
        let before = items.count
        func expired(_ it: ClipItem) -> Bool {
            if it.pinned { return false }                                   // angeheftet -> nie
            if let exp = secretExpiry(it) { return exp < now }              // Passwort-Bereich -> 24 h
            if it.collection != nil { return false }                        // anderer Bereich -> nie
            return it.date < cutoff                                         // Verlauf -> 2 Tage
        }
        let keep: (ClipItem) -> Bool = { $0.pinned || $0.collection != nil }  // zaehlen nicht zum 200er-Deckel
        for it in items where expired(it) { removeStorage(it) }
        items.removeAll { expired($0) }
        if items.count > maxItems {
            var overflow = items.count - maxItems
            var kept: [ClipItem] = []
            for it in items.reversed() {
                if overflow > 0 && !keep(it) { removeStorage(it); overflow -= 1 } else { kept.append(it) }
            }
            items = kept.reversed()
        }
        return items.count != before
    }
    @discardableResult func addText(_ s: String, source: String? = nil, collection: String? = nil) -> String {
        let it: ClipItem
        // 27.09.2026: auch Texte, die sich NUR in Leerzeichen/Zeilenumbruechen am Rand unterscheiden, sind derselbe
        // Eintrag (z. B. "Schick Nico" legt den Text ab + dieselbe Nachricht kommt per pbcopy mit "\n" am Ende).
        let key = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = items.firstIndex(where: { $0.kind == .text && ($0.text == s || $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) == key) }) { it = items.remove(at: idx); it.date = Date(); it.source = source ?? it.source; items.insert(it, at: 0) }
        else { it = ClipItem(kind: .text, text: s, source: source); items.insert(it, at: 0) }
        if let c = collection, it.collection != c { it.collection = c; it.collectedAt = Date(); it.pinned = false }
        prune(); persist()
        return it.id
    }
    /// origin: Originaldatei (Screenshot-Ordner/Finder), falls bekannt. Rueckgabe: id des Eintrags
    /// (bei einem Doppel die des vorhandenen, siehe imagededupe.swift).
    @discardableResult func addImage(_ data: Data, source: String? = nil, origin: String? = nil) -> String {
        let fp = ImagePrint.make(data: data)
        if let fp = fp, let twin = recentImageTwin(data: data, print: fp) {
            mergeImageTwin(twin, data: data, print: fp, source: source, origin: origin)
            OCR.shared.enqueue(twin)   // falls der Zwilling noch nicht gelesen wurde
            return twin.id
        }
        let fname = UUID().uuidString + ".png"; try? data.write(to: dir.appendingPathComponent(fname))
        let it = ClipItem(kind: .image, imageFile: fname, source: source); it.thumb = loadThumb(data: data)
        it.origin = origin; it.imagePrint = fp
        items.insert(it, at: 0); prune(); persist()
        OCR.shared.enqueue(it)   // neue Bilder/Screenshots sofort durchsuchbar machen (im Hintergrund)
        return it.id
    }
    /// origPaths: wo die Datei wirklich liegt, falls `urls` nur eine Zwischenkopie ist (clipvault add)
    func addFiles(_ urls: [URL], source: String? = nil, origPaths: [String]? = nil) {
        let origs = (origPaths?.count == urls.count) ? origPaths! : urls.map { $0.path }
        let key = origs.joined(separator: "\u{0}")
        if let idx = items.firstIndex(where: { $0.kind == .file && ($0.files?.map { $0.orig }.joined(separator: "\u{0}")) == key }) {
            let it = items.remove(at: idx); it.date = Date(); items.insert(it, at: 0); prune(); persist(); return
        }
        let itemID = UUID().uuidString
        let filesDir = dir.appendingPathComponent("files/\(itemID)")
        let cap: Int64 = 200 * 1024 * 1024  // bis 200 MB pro Datei in den Verlauf kopieren (ueberlebt 2 Tage)
        var refs: [FileRef] = []
        for (i, u) in urls.enumerated() {
            let name = URL(fileURLWithPath: origs[i]).lastPathComponent
            var storedRel: String? = nil
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if exists && !isDir.boolValue, let attrs = try? FileManager.default.attributesOfItem(atPath: u.path), let sz = attrs[.size] as? Int64, sz <= cap {
                try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
                let dest = filesDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { storedRel = "files/\(itemID)/\(name)" }
            }
            refs.append(FileRef(name: name, stored: storedRel, orig: origs[i]))
        }
        let it = ClipItem(id: itemID, kind: .file, source: source, files: refs)
        it.thumb = fileIcon(refs)
        items.insert(it, at: 0); prune(); persist()
    }
    func dataFor(_ item: ClipItem) -> Data? { guard let f = item.imageFile else { return nil }; return try? Data(contentsOf: dir.appendingPathComponent(f)) }
    func imageURL(_ item: ClipItem) -> URL? { item.imageFile.map { dir.appendingPathComponent($0) } }
    /// Beste vorhandene Datei eines Datei-Eintrags (Original, sonst gesicherte Kopie)
    func fileURL(_ item: ClipItem) -> URL? {
        guard let r = item.files?.first else { return nil }
        if FileManager.default.fileExists(atPath: r.orig) { return URL(fileURLWithPath: r.orig) }
        if let st = r.stored { let u = dir.appendingPathComponent(st); if FileManager.default.fileExists(atPath: u.path) { return u } }
        return nil
    }
    func moveToTop(_ item: ClipItem) { if let idx = items.firstIndex(where: { $0.id == item.id }) { let it = items.remove(at: idx); it.date = Date(); items.insert(it, at: 0); persist() } }
    func togglePin(_ item: ClipItem) { if let it = items.first(where: { $0.id == item.id }) { it.pinned.toggle(); persist() } }
}
