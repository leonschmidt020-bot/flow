import AppKit
import CryptoKit
import ImageIO
import SwiftUI

// MARK: - ClipVault im Hub: Datenzugriff
// ClipVault (eigener Prozess, Quellen in mac/clipvault) besitzt die Daten.
// Der Hub LIEST nur: ~/.config/flow-clipvault/index.json + collections.json (+ Bilder/Dateien/linkprev).
// Jede Änderung geht als Befehl über den Befehlskanal (DistributedNotification „app.flowdictation.clipvault.cmd“).
// Neu laden: bei „app.flowdictation.clipvault.changed“ oder spätestens nach 2 s (Datei-Zeitstempel).

enum CVKind: String, CaseIterable, Identifiable {
    case text, link, image, file
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Bild"
        case .file: return "Datei"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

struct CVFileRef: Equatable, Hashable {
    let name: String
    let stored: String?
    let orig: String
}

struct CVCollection: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var symbol: String
    /// Geheim-Bereich (wie ClipVault): nil = am Namen erkennen
    var secret: Bool? = nil

    /// „Passwörter“-Bereich: Inhalte verdeckt, bis man drüberfährt; ClipVault löscht sie nach 24 h (außer angeheftet).
    var isSecret: Bool { secret ?? CVCollection.looksSecret(name) }
    static func looksSecret(_ n: String) -> Bool {
        let l = n.lowercased()
        return l.contains("passw") || l.contains("kennw") || l.contains("geheim") || l.contains("secret")
    }
    var isImageSymbol: Bool { symbol.hasPrefix("img:") }
}

struct CVItem: Identifiable, Equatable {
    let id: String
    let rawKind: String
    var text: String?
    var image: String?          // Dateiname relativ zu ~/.config/flow-clipvault
    var date: Date
    var source: String?
    var files: [CVFileRef]
    var pinned: Bool
    var collection: String?
    // Optionale Felder, die ClipVault-Core ergänzen kann (unbekannt = nil)
    /// Erkannter Text (Feld „ocrText“). nil = nicht geprüft oder kein Text – siehe ocrChecked
    var ocr: String?
    var ocrChecked = false
    var title: String?
    /// Für den geteilten Tresor freigegeben (Feld „shared“)
    var shared = false
    /// Seit wann im aktuellen Bereich (Ablauf im Passwort-Bereich)
    var collectedAt: Date?
    var edited: Date?
    /// Nur Info von ClipVault: "link", "email", "phone", "color", "code"
    var badges: [String] = []
    var url: URL?               // Text ist genau ein http(s)-Link

    var kind: CVKind {
        switch rawKind {
        case "image": return .image
        case "file": return .file
        default: return url != nil ? .link : .text
        }
    }
    var isAI: Bool { source == "KI" }
    var isVoice: Bool { source == "Diktat" || source == "Meeting" || source == "Command Mode" }
    var isPhone: Bool { source == "iPhone" }
    /// Für Links-Seite/-Filter: reiner Link ODER Text mit Link darin (wie ClipVaults Panel)
    var hasLink: Bool { kind == .link || (kind == .text && badges.contains("link")) }

    /// Eine Zeile für Listen (ohne Zeilenumbrüche, gekürzt)
    var headline: String {
        switch kind {
        case .image: return title ?? "Bild"
        case .file:
            guard let f = files.first else { return "Datei" }
            return files.count > 1 ? "\(f.name) + \(files.count - 1) weitere" : f.name
        case .link: return title ?? url?.absoluteString ?? ""
        case .text:
            let t = (text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(t.prefix(400))
        }
    }

    var searchBlob: String {
        [text, ocr, title, source, files.map(\.name).joined(separator: " "), url?.host].compactMap { $0 }.joined(separator: " ")
    }
}

/// Ergebnis eines Befehls (für die kleine Rückmeldung im Hub)
struct CVToast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    var symbol: String = "checkmark"
    var isError = false
}

// MARK: - Client

final class ClipVaultClient: ObservableObject {
    static let shared = ClipVaultClient()

    /// Ordner der ClipVault-Daten (für Tests änderbar)
    static var base: URL = {
        // CLIPVAULT_HOME: nur für Tests/Sichtprüfung (z. B. leerer Ordner = noch nicht gekoppelt)
        let env = ProcessInfo.processInfo.environment["CLIPVAULT_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return env.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow-clipvault")
                           : URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
    }()
    static let changedName = Notification.Name("app.flowdictation.clipvault.changed")
    static let commandName = Notification.Name("app.flowdictation.clipvault.cmd")
    static let resultName = Notification.Name("app.flowdictation.clipvault.result")
    /// Offene Befehle: reqId → was bei Fehler angezeigt wird
    private var waiting: [String: (action: String, onError: ((String) -> Void)?)] = [:]
    private var resultObserver: NSObjectProtocol?

    @Published private(set) var items: [CVItem] = []
    @Published private(set) var collections: [CVCollection] = []
    @Published private(set) var loadedAt: Date?
    @Published private(set) var loadError: String?
    @Published var toast: CVToast?
    /// Neu hinzugekommene Einträge (für die Einflug-Animation)
    @Published private(set) var freshIDs: Set<String> = []

    private var indexStamp: Date?
    private var collectionsStamp: Date?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let io = DispatchQueue(label: "hub.clipvault.load", qos: .userInitiated)
    private var started = false
    /// Löschen/Anheften sofort zeigen, bis ClipVault die Datei neu geschrieben hat
    private var pending: [String: (CVItem?) -> CVItem?] = [:]

    private init() {}

    var indexURL: URL { Self.base.appendingPathComponent("index.json") }
    var collectionsURL: URL { Self.base.appendingPathComponent("collections.json") }
    var tokenURL: URL { Self.base.appendingPathComponent("token") }
    var aiAppsURL: URL { Self.base.appendingPathComponent("ai-apps.txt") }

    /// Startet Beobachtung (idempotent). Die Seiten rufen das in onAppear.
    func start() {
        guard !started else { return }
        started = true
        reload(force: true, sync: true)
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.changedName, object: nil, queue: .main) { [weak self] _ in
            self?.reload(force: true)
        }
        resultObserver = DistributedNotificationCenter.default().addObserver(forName: Self.resultName, object: nil, queue: .main) { [weak self] n in
            self?.handleResult(n.object as? String)
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reload(force: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Laden

    func reload(force: Bool, sync: Bool = false) {
        let iu = indexURL, cu = collectionsURL
        let iStamp = Self.mtime(iu), cStamp = Self.mtime(cu)
        if !force, iStamp == indexStamp, cStamp == collectionsStamp { return }
        let work = { () -> ([CVItem]?, [CVCollection]?, String?) in
            let its = Self.decodeItems(iu)
            let cols = Self.decodeCollections(cu)
            var err: String? = nil
            if its == nil && FileManager.default.fileExists(atPath: iu.path) { err = "Verlauf konnte nicht gelesen werden" }
            return (its, cols, err)
        }
        let apply: (([CVItem]?, [CVCollection]?, String?)) -> Void = { [weak self] r in
            guard let self else { return }
            self.indexStamp = iStamp; self.collectionsStamp = cStamp
            if let cols = r.1, cols != self.collections { self.collections = cols }
            if var its = r.0 {
                its = self.applyPending(its)
                let old = Set(self.items.map(\.id))
                let new = its.filter { !old.contains($0.id) }.map(\.id)
                if self.loadedAt != nil && !new.isEmpty && new.count < 12 {
                    self.freshIDs.formUnion(new)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.freshIDs.subtract(new) }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { self.items = its }
                } else if its != self.items {
                    self.items = its
                }
            } else if !FileManager.default.fileExists(atPath: iu.path) {
                self.items = []
            }
            self.loadError = r.2
            self.loadedAt = Date()
        }
        if sync { apply(work()) } else { io.async { let r = work(); DispatchQueue.main.async { apply(r) } } }
    }

    private func applyPending(_ list: [CVItem]) -> [CVItem] {
        guard !pending.isEmpty else { return list }
        var out: [CVItem] = []
        for it in list {
            if let f = pending[it.id] { if let n = f(it) { out.append(n) } } else { out.append(it) }
        }
        return out
    }

    static func mtime(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    /// Tolerant: unbekannte Felder werden ignoriert, fehlende sind nil. Reihenfolge wie in der Datei (neueste zuerst).
    static func decodeItems(_ url: URL) -> [CVItem]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return arr.compactMap { d -> CVItem? in
            guard let id = d["id"] as? String else { return nil }
            let kind = (d["kind"] as? String) ?? "text"
            let ts = (d["ts"] as? Double) ?? (d["ts"] as? NSNumber)?.doubleValue ?? 0
            let files: [CVFileRef] = ((d["files"] as? [[String: Any]]) ?? []).compactMap {
                guard let name = $0["name"] as? String else { return nil }
                return CVFileRef(name: name, stored: $0["stored"] as? String, orig: ($0["orig"] as? String) ?? "")
            }
            let text = d["text"] as? String
            var item = CVItem(id: id, rawKind: kind, text: text, image: d["image"] as? String,
                              date: Date(timeIntervalSince1970: ts), source: d["source"] as? String, files: files,
                              pinned: (d["pinned"] as? Bool) ?? false, collection: d["collection"] as? String)
            if let o = (d["ocrText"] as? String) ?? (d["ocr"] as? String) { item.ocrChecked = true; item.ocr = o.isEmpty ? nil : o }
            item.title = (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            item.shared = (d["shared"] as? Bool) ?? false
            if let c = d["collectedAt"] as? Double { item.collectedAt = Date(timeIntervalSince1970: c) }
            if let e = d["edited"] as? Double { item.edited = Date(timeIntervalSince1970: e) }
            item.badges = (d["badges"] as? [String]) ?? []
            if kind == "text", let t = text, let det { item.url = singleURL(t, det) }
            return item
        }
    }

    /// Wie ClipVault: nur wenn der GANZE Text genau ein http(s)-Link ist.
    static func singleURL(_ raw: String, _ det: NSDataDetector) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2000, !t.contains(" "), !t.contains("\n") else { return nil }
        let ns = t as NSString
        let ms = det.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length))
        guard ms.count == 1, let m = ms.first, m.range.location == 0, m.range.length == ns.length,
              let u = m.url, let sch = u.scheme?.lowercased(), sch == "http" || sch == "https" else { return nil }
        return u
    }

    static func decodeCollections(_ url: URL) -> [CVCollection]? {
        guard let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return CVCollection(id: id, name: name, symbol: (d["symbol"] as? String) ?? "folder.fill", secret: d["secret"] as? Bool)
        }
    }

    // MARK: Abfragen

    func collection(_ id: String?) -> CVCollection? { id.flatMap { i in collections.first { $0.id == i } } }
    func item(_ id: String?) -> CVItem? { id.flatMap { i in items.first { $0.id == i } } }
    /// Geschützt: im Passwörter-Bereich ODER der Text sieht nach Zugangsdaten aus („Passwort: …“)
    func isSecret(_ item: CVItem) -> Bool {
        if collection(item.collection)?.isSecret ?? false { return true }
        guard item.kind == .text, let t = item.text?.lowercased() else { return false }
        return Self.secretMarkers.contains { t.contains($0) }
    }
    static let secretMarkers = ["passwort:", "passwort =", "password:", "password=", "kennwort:", "pw:", "pin:", "api key:", "apikey=", "token:"]
    /// Wann löscht ClipVault den Eintrag? nil = nie (angeheftet oder in normalem Bereich)
    func expiry(_ item: CVItem) -> Date? {
        if item.pinned { return nil }
        if let c = collection(item.collection) {
            return c.isSecret ? (item.collectedAt ?? item.date).addingTimeInterval(24 * 3600) : nil
        }
        return item.date.addingTimeInterval(2 * 24 * 3600)
    }

    func count(in collection: String) -> Int { items.lazy.filter { $0.collection == collection }.count }

    func imageURL(_ item: CVItem) -> URL? { item.image.map { Self.base.appendingPathComponent($0) } }

    func fileURL(_ ref: CVFileRef) -> URL {
        if FileManager.default.fileExists(atPath: ref.orig) { return URL(fileURLWithPath: ref.orig) }
        if let s = ref.stored { return Self.base.appendingPathComponent(s) }
        return URL(fileURLWithPath: ref.orig)
    }

    /// Website-Vorschau, die ClipVault schon zwischengespeichert hat (linkprev/<sha256[0..16]>.png + .txt)
    static func linkPreviewKey(_ url: URL) -> String {
        let d = SHA256.hash(data: Data(url.absoluteString.utf8))
        return d.map { String(format: "%02x", $0) }.prefix(16).joined()
    }
    func linkPreviewImageURL(_ url: URL) -> URL? {
        let u = Self.base.appendingPathComponent("linkprev/\(Self.linkPreviewKey(url)).png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    func linkTitle(_ url: URL) -> String? {
        let u = Self.base.appendingPathComponent("linkprev/\(Self.linkPreviewKey(url)).txt")
        guard let t = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: Status von ClipVault (status.txt, PID prüfen)

    struct Status { var running: Bool; var hotkeyOK: Bool; var count: Int?; var since: Date? }

    func status() -> Status {
        let s = (try? String(contentsOf: Self.base.appendingPathComponent("status.txt"), encoding: .utf8)) ?? ""
        var kv: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        var running = false
        if let pid = kv["pid"].flatMap({ Int32($0) }), pid > 0 { running = kill(pid, 0) == 0 }
        return Status(running: running, hotkeyOK: kv["hotkey"] == "ok", count: kv["eintraege"].flatMap { Int($0) },
                      since: kv["seit"].flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    // MARK: Befehlskanal

    var token: String? {
        guard let t = try? String(contentsOf: tokenURL, encoding: .utf8) else { return nil }
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    var canSendCommands: Bool { token != nil }

    /// Schickt einen Befehl an ClipVault. Gibt false zurück, wenn kein Token da ist (ClipVault kennt den Kanal noch nicht).
    private func handleResult(_ json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let req = o["reqId"] as? String, let w = waiting.removeValue(forKey: req) else { return }
        guard (o["ok"] as? Bool) != true else { return }
        let err = (o["error"] as? String) ?? "unbekannter Fehler"
        if let h = w.onError { h(err) } else {
            show(CVToast(text: "ClipVault: \(err)", symbol: "exclamationmark.triangle", isError: true))
        }
        pending.removeAll()
        reload(force: true)
    }

    @discardableResult
    func send(_ action: String, id: String? = nil, collection: String?? = nil, text: String? = nil, extra: [String: Any] = [:],
              onError: ((String) -> Void)? = nil) -> Bool {
        guard let token else {
            show(CVToast(text: "ClipVault antwortet nicht – Befehlskanal fehlt", symbol: "exclamationmark.triangle", isError: true))
            return false
        }
        let req = UUID().uuidString
        waiting[req] = (action, onError)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.waiting[req] = nil }
        var obj: [String: Any] = ["token": token, "action": action, "reqId": req]
        if let id { obj["id"] = id }
        if let collection { obj["collection"] = collection ?? NSNull() }
        if let text { obj["text"] = text }
        for (k, v) in extra { obj[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let json = String(data: data, encoding: .utf8) else { return false }
        DistributedNotificationCenter.default().postNotificationName(Self.commandName, object: json, userInfo: nil, deliverImmediately: true)
        return true
    }

    func show(_ t: CVToast) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toast = t }
        let id = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.toast?.id == id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.toast = nil }
        }
    }

    /// Optimistisch sofort ändern; ClipVault schreibt danach die Datei und schickt „changed“.
    private func optimistic(_ id: String, _ f: @escaping (CVItem?) -> CVItem?) {
        pending[id] = f
        withAnimation(.easeOut(duration: 0.18)) { items = items.compactMap { $0.id == id ? f($0) : $0 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.pending[id] = nil }
    }

    // MARK: Aktionen (öffentlich)

    /// Kopieren: über ClipVault (rückt nach oben). Ohne Befehlskanal direkt in die Zwischenablage.
    func copy(_ item: CVItem) {
        if canSendCommands { send("copy", id: item.id) } else { copyLocally(item) }
        show(CVToast(text: "Kopiert", symbol: "doc.on.doc"))
    }

    func copyLocally(_ item: CVItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link: pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let u = imageURL(item), let img = NSImage(contentsOf: u) { pb.writeObjects([img]) }
        case .file: pb.writeObjects(item.files.map { fileURL($0) as NSURL })
        }
    }

    func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(s, forType: .string)
        show(CVToast(text: "Kopiert", symbol: "doc.on.doc"))
    }

    func setPinned(_ item: CVItem, _ on: Bool) {
        guard send(on ? "pin" : "unpin", id: item.id) else { return }
        optimistic(item.id) { var i = $0; i?.pinned = on; if on { i?.collection = nil }; return i }
        show(CVToast(text: on ? "Angeheftet" : "Nicht mehr angeheftet", symbol: on ? "pin.fill" : "pin.slash"))
    }

    func delete(_ item: CVItem) {
        guard send("delete", id: item.id) else { return }
        optimistic(item.id) { _ in nil }
        show(CVToast(text: "Gelöscht", symbol: "trash"))
    }

    func setCollection(_ item: CVItem, _ collectionID: String?) {
        guard send("setCollection", id: item.id, collection: .some(collectionID)) else { return }
        optimistic(item.id) { var i = $0; i?.collection = collectionID; if collectionID != nil { i?.pinned = false }; return i }
        let name = collection(collectionID)?.name
        show(CVToast(text: name.map { "In „\($0)“ gelegt" } ?? "Aus dem Bereich genommen", symbol: "square.stack.3d.up"))
    }

    func edit(_ item: CVItem, text: String) {
        guard send("edit", id: item.id, text: text) else { return }
        optimistic(item.id) { var i = $0; i?.text = text; return i }
        show(CVToast(text: "Gespeichert", symbol: "pencil"))
    }

    func addText(_ text: String, collection: String? = nil) {
        guard send("addText", collection: collection.map { .some($0) }, text: text) else { return }
        show(CVToast(text: "Zu ClipVault hinzugefügt", symbol: "plus"))
    }

    func requestOCR(_ item: CVItem) {
        guard send("ocr", id: item.id) else { return }
        show(CVToast(text: "Text wird erkannt …", symbol: "text.viewfinder"))
    }

    func share(_ item: CVItem) {
        guard send("share", id: item.id) else { return }
        optimistic(item.id) { var i = $0; i?.shared = true; return i }
        show(CVToast(text: "Mit \(Identity.partner(.dative)) geteilt", symbol: "person.2.fill"))
    }

    func unshare(_ item: CVItem) {
        guard send("unshare", id: item.id) else { return }
        optimistic(item.id) { var i = $0; i?.shared = false; return i }
        show(CVToast(text: "Nicht mehr geteilt", symbol: "person.2.slash"))
    }

    func createCollection(name: String, symbol: String, secret: Bool? = nil) {
        var extra: [String: Any] = ["name": name, "symbol": symbol]
        if let secret { extra["secret"] = secret }
        guard send("createCollection", extra: extra) else { return }
        show(CVToast(text: "Bereich „\(name)“ angelegt", symbol: "plus.square.on.square"))
    }

    func renameCollection(_ c: CVCollection, name: String, symbol: String) {
        guard send("renameCollection", collection: .some(c.id), extra: ["name": name, "symbol": symbol],
                   onError: { [weak self] _ in
                       self?.show(CVToast(text: "Umbenennen kann ClipVault noch nicht", symbol: "exclamationmark.triangle", isError: true))
                   }) else { return }
        if let i = collections.firstIndex(of: c) { collections[i].name = name; collections[i].symbol = symbol }
        show(CVToast(text: "Bereich umbenannt", symbol: "pencil"))
    }

    func deleteCollection(_ c: CVCollection) {
        guard send("deleteCollection", collection: .some(c.id)) else { return }
        withAnimation { collections.removeAll { $0.id == c.id } }
        show(CVToast(text: "Bereich „\(c.name)“ gelöscht", symbol: "trash"))
    }

    // MARK: Nur für die Sichtprüfung (nichts wird geschrieben)
    func replaceForPreview(items: [CVItem], collections: [CVCollection]) {
        self.items = items; self.collections = collections; loadedAt = Date(); started = true
    }
}

// MARK: - Vorschaubilder (ImageIO, nie ganze Bilder in Listen)

final class CVThumbs {
    static let shared = CVThumbs()
    private let cache = NSCache<NSString, NSImage>()
    private let q = DispatchQueue(label: "hub.clipvault.thumbs", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 400 }

    func cached(_ url: URL, _ maxPixel: Int) -> NSImage? { cache.object(forKey: "\(maxPixel)|\(url.path)" as NSString) }

    func load(_ url: URL, maxPixel: Int, _ done: @escaping (NSImage?) -> Void) {
        let key = "\(maxPixel)|\(url.path)" as NSString
        if let c = cache.object(forKey: key) { done(c); return }
        q.async { [cache] in
            let img = CVThumbs.make(url, maxPixel: maxPixel)
            if let img { cache.setObject(img, forKey: key) }
            DispatchQueue.main.async { done(img) }
        }
    }

    static func make(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Pixelmaße ohne das Bild zu dekodieren
    private static var sizes: [String: CGSize] = [:]
    static func pixelSize(_ url: URL) -> CGSize? {
        if let s = sizes[url.path] { return s }
        guard let s = readPixelSize(url) else { return nil }
        sizes[url.path] = s
        return s
    }
    private static func readPixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// Vorschaubild, das im Hintergrund geladen wird
struct CVThumb: View {
    let url: URL?
    var maxPixel: Int = 320
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
                } else {
                    VF.cardSoft
                }
            }
            .clipped()
        .onAppear(perform: load)
        .onChange(of: url) { _, _ in image = nil; load() }
    }

    private func load() {
        guard let url else { return }
        if let c = CVThumbs.shared.cached(url, maxPixel) { image = c; return }
        CVThumbs.shared.load(url, maxPixel: maxPixel) { img in withAnimation(.easeOut(duration: 0.15)) { image = img } }
    }
}

// MARK: - Formatierung

enum CVFormat {
    static let de = Locale(identifier: "de_DE")

    static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Heute" }
        if cal.isDateInYesterday(d) { return "Gestern" }
        return HubFormat.date(d, cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEEE, d. MMMM" : "d. MMMM yyyy")
    }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "gerade eben" }
        if s < 3600 { return "vor \(Int(s / 60)) Min." }
        if Calendar.current.isDateInToday(d) { return "heute, \(HubFormat.time(d))" }
        if Calendar.current.isDateInYesterday(d) { return "gestern, \(HubFormat.time(d))" }
        return HubFormat.date(d, "d. MMM, HH:mm")
    }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    static func words(_ s: String) -> Int { s.split { $0.isWhitespace || $0.isNewline }.count }
    static func wordsLabel(_ s: String) -> String { let n = words(s); return n == 1 ? "1 Wort" : "\(n) Wörter" }
}

extension View {
    /// Geheimes verdecken (graue Platzhalter-Balken statt Text) – kein Filter, damit es auch in Bildschirmfotos/Freigaben sicher ist
    @ViewBuilder func cvHidden(_ hidden: Bool) -> some View {
        if hidden { self.redacted(reason: .placeholder) } else { self }
    }
}
