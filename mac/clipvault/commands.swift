// ClipVault — Befehlskanal fuer externe Oberflaechen (z. B. den Hub) + Aenderungs-Meldungen
// Protokoll (Namen, Felder, Beispiele): siehe PROTOCOL.md
import Cocoa
import Security

// MARK: - Aenderungs-Meldung  app.flowdictation.clipvault.changed
// Nach JEDER Aenderung am Verlauf (auch normalen Kopien) — hoechstens alle 200 ms.
// Die letzte Aenderung eines Schwalls wird immer noch gemeldet (nachlaufende Meldung).
enum ChangeNotifier {
    static let name = Notification.Name("app.flowdictation.clipvault.changed" + CV_NOTIFY_SUFFIX)
    private static var last = Date.distantPast
    private static var scheduled = false
    private(set) static var posted = 0
    static func bump() {
        if CV_READ_ONLY { return }
        if !Thread.isMainThread { DispatchQueue.main.async { bump() }; return }
        if scheduled { return }
        let wait = 0.2 - Date().timeIntervalSince(last)
        if wait <= 0 { post() }
        else {
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { scheduled = false; post() }
        }
    }
    private static func post() {
        last = Date(); posted += 1
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

// MARK: - Schluessel  ~/.config/flow-clipvault/token  (0600, 64 Hex-Zeichen)
enum CVToken {
    static let path = CV_DIR + "token"
    static func read() -> String? {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count == 64 && s.allSatisfy({ $0.isHexDigit }) ? s : nil
    }
    static func loadOrCreate() -> String {
        if let t = read() { chmod(path, 0o600); return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: Data((t + "\n").utf8), attributes: [.posixPermissions: 0o600])
        chmod(path, 0o600)
        cvLog("Befehlskanal: neuer Schluessel angelegt (token)")
        return t
    }
    /// Vergleich ohne fruehen Abbruch (verraet nicht, ab welchem Zeichen es falsch ist)
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in x.indices { d |= x[i] ^ y[i] }
        return d == 0
    }
}

// MARK: - Befehle  app.flowdictation.clipvault.cmd  (object = JSON-String)
final class CommandChannel: NSObject {
    static let shared = CommandChannel()
    static let cmdName = Notification.Name("app.flowdictation.clipvault.cmd" + CV_NOTIFY_SUFFIX)
    static let resultName = Notification.Name("app.flowdictation.clipvault.result" + CV_NOTIFY_SUFFIX)
    private var token = ""
    private var lastRejectLog = Date.distantPast
    private(set) var handled = 0
    private(set) var rejected = 0

    func start() {
        token = CVToken.loadOrCreate()
        // .deliverImmediately: auch zustellen, wenn ClipVault gerade nicht die aktive App ist
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)), name: CommandChannel.cmdName, object: nil, suspensionBehavior: .deliverImmediately)
        cvLog("Befehlskanal bereit (app.flowdictation.clipvault.cmd)")
    }

    struct Result { var ok: Bool; var id: String? = nil; var error: String? = nil; var extra: [String: Any] = [:] }

    @objc func received(_ n: Notification) {
        guard let s = n.object as? String, let data = s.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            reject("kein gueltiges JSON"); return
        }
        let given = o["token"] as? String ?? ""
        if !CVToken.equal(given, token) {
            // Schluessel evtl. von Hand erneuert -> einmal frisch lesen
            if let fresh = CVToken.read(), CVToken.equal(given, fresh) { token = fresh }
            else { reject("falscher Schluessel"); return }
        }
        let action = o["action"] as? String ?? ""
        // Kopplung/Sync-Befehle (pairCreate, pairJoin, unpair, syncStatus, syncSetup …) laufen asynchron im Backend
        if let h = SharedVaultHook.backend as? SharedVaultCommandHandler, h.handlesCommand(action) {
            h.handleCommand(action, o) { [weak self] r in DispatchQueue.main.async { self?.finish(action, o, r) } }
            return
        }
        finish(action, o, perform(action, o))
    }
    private func finish(_ action: String, _ o: [String: Any], _ r: Result) {
        handled += 1
        if !r.ok { cvLog("Befehl \(action) abgelehnt: \(r.error ?? "?")") }
        if let req = o["reqId"] as? String { reply(req, action: action, r) }
    }
    private func reject(_ why: String) {
        rejected += 1
        if Date().timeIntervalSince(lastRejectLog) > 10 { cvLog("Befehl ignoriert: \(why)"); lastRejectLog = Date() }
    }
    private func reply(_ req: String, action: String, _ r: Result) {
        var d: [String: Any] = r.extra
        d["reqId"] = req; d["action"] = action; d["ok"] = r.ok
        if let id = r.id { d["id"] = id }
        if let e = r.error { d["error"] = e }
        guard let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(CommandChannel.resultName, object: s, userInfo: nil, deliverImmediately: true)
    }

    private func str(_ o: [String: Any], _ k: String) -> String? {
        guard let v = o[k] as? String else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : v
    }

    func perform(_ action: String, _ o: [String: Any]) -> Result {
        let store = Store.shared
        let id = str(o, "id")
        func needItem() -> ClipItem? { id.flatMap { store.item($0) } }
        // Lese-/Markier-Befehle bauen die Liste nicht neu (sonst springt die Hover-Pille bei jeder Abfrage zu)
        defer { if !["sharedNew", "markSeen", "transfers"].contains(action) { PanelController.shared?.refreshAfterExternalChange() } }
        switch action {
        case "ping":
            return Result(ok: true)
        case "copy":
            if let it = needItem() {
                AppState.shared.copyAndPaste(it)
                Toast.shared.show(it.kind == .file ? "Datei in Zwischenablage" : (it.kind == .image ? "Bild in Zwischenablage" : "In Zwischenablage"))
                return Result(ok: true, id: it.id)
            }
            if let id = id, SharedVault.shared.copyToPasteboard(id: id) { return Result(ok: true, id: id) }
            return Result(ok: false, error: "Eintrag nicht gefunden")
        case "pin", "unpin":
            guard let id = id else { return Result(ok: false, error: "id fehlt") }
            // scope=shared: den geteilten Eintrag meinen (gleiche id wie der Verlaufs-Eintrag, aus dem geteilt wurde)
            if str(o, "scope") == "shared", SharedVault.shared.item(id) != nil { SharedVaultHook.setPinned(id, action == "pin"); return Result(ok: true, id: id) }
            if store.setPinned(id: id, action == "pin") { return Result(ok: true, id: id) }
            if SharedVault.shared.item(id) != nil { SharedVaultHook.setPinned(id, action == "pin"); return Result(ok: true, id: id) }
            return Result(ok: false, error: "Eintrag nicht gefunden")
        case "delete":
            guard let it = needItem() else { return Result(ok: false, error: "Eintrag nicht gefunden") }
            store.delete(id: it.id); return Result(ok: true, id: it.id)
        case "setCollection":
            guard let it = needItem() else { return Result(ok: false, error: "Eintrag nicht gefunden") }
            let cid = str(o, "collection")
            if let c = cid, store.collection(c) == nil { return Result(ok: false, error: "Bereich nicht gefunden") }
            store.setCollection(itemId: it.id, collectionId: cid); return Result(ok: true, id: it.id)
        case "createCollection":
            guard let name = str(o, "name") ?? str(o, "text") else { return Result(ok: false, error: "name fehlt") }
            let c = store.addCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), symbol: str(o, "symbol") ?? "folder.fill", secret: o["secret"] as? Bool)
            return Result(ok: true, id: c.id)
        case "renameCollection":
            guard let cid = str(o, "collection") ?? id, store.collection(cid) != nil else { return Result(ok: false, error: "Bereich nicht gefunden") }
            let name = (str(o, "name") ?? str(o, "text"))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let symbol = str(o, "symbol")
            guard name != nil || symbol != nil else { return Result(ok: false, error: "name fehlt") }
            store.renameCollection(id: cid, name: name, symbol: symbol); return Result(ok: true, id: cid)
        case "addImage":
            guard let p = str(o, "path") else { return Result(ok: false, error: "path fehlt") }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard let png: Data = autoreleasepool(invoking: {
                if url.pathExtension.lowercased() == "png", let d = try? Data(contentsOf: url) { return d }
                return NSImage(contentsOf: url)?.pngData()
            }) else { return Result(ok: false, error: "Bild nicht lesbar") }
            let nid = store.addImage(png, source: str(o, "source"))
            return Result(ok: true, id: nid)
        case "deleteCollection":
            guard let cid = str(o, "collection") ?? id, store.collection(cid) != nil else { return Result(ok: false, error: "Bereich nicht gefunden") }
            store.removeCollection(id: cid); return Result(ok: true, id: cid)
        case "edit":
            guard let it = needItem() else { return Result(ok: false, error: "Eintrag nicht gefunden") }
            guard it.kind == .text else { return Result(ok: false, error: "nur Text-Eintraege sind bearbeitbar") }
            guard let t = o["text"] as? String, store.edit(id: it.id, text: t) else { return Result(ok: false, error: "text fehlt/leer") }
            return Result(ok: true, id: it.id)
        case "addText":
            guard let t = o["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Result(ok: false, error: "text fehlt/leer") }
            let cid = str(o, "collection")
            if let c = cid, store.collection(c) == nil { return Result(ok: false, error: "Bereich nicht gefunden") }
            let nid = store.addText(t, source: str(o, "source"), collection: cid)
            return Result(ok: true, id: nid)
        case "ocr":
            guard let it = needItem(), it.kind == .image else { return Result(ok: false, error: "Bild-Eintrag nicht gefunden") }
            OCR.shared.enqueue(it, force: true); return Result(ok: true, id: it.id)
        case "share":
            guard let it = needItem() else { return Result(ok: false, error: "Eintrag nicht gefunden") }
            switch SharedVaultHook.share(it) {
            case .success(let list): return Result(ok: true, id: list.first?.id ?? it.id, extra: ["ids": list.map(\.id)])
            case .failure(let e): return Result(ok: false, error: e.message)
            }
        case "unshare":
            guard let id = id else { return Result(ok: false, error: "id fehlt") }
            SharedVaultHook.unshare(id); return Result(ok: true, id: id)
        case "addFile":     // path=<datei> (mehrere: paths=<pfad1>\n<pfad2>…) — Datei(en) in den Verlauf, Zwischenablage bleibt
            let raw = (str(o, "paths") ?? str(o, "path") ?? "").split(separator: "\n").map { (String($0) as NSString).expandingTildeInPath }
            let urls = raw.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty, urls.count == raw.count else { return Result(ok: false, error: "Datei nicht gefunden") }
            store.addFiles(urls, source: str(o, "source"))
            return Result(ok: true, id: store.items.first?.id)
        case "download":    // grossen geteilten Eintrag laden („Laden")
            guard let id = id, let s = SharedVault.shared.item(id), !s.deleted else { return Result(ok: false, error: "Eintrag nicht gefunden") }
            if SharedVault.shared.isLocal(s) { return Result(ok: true, id: s.id, extra: ["local": true]) }
            guard s.isBig else { return Result(ok: false, error: "nichts zu laden") }
            guard s.serverGone != true else { return Result(ok: false, error: "auf dem Server abgelaufen") }
            SharedVaultHook.download(s.id); return Result(ok: true, id: s.id)
        case "cancelTransfer":
            guard let id = id else { return Result(ok: false, error: "id fehlt") }
            SharedVaultHook.cancelTransfer(id); return Result(ok: true, id: id)
        case "retryUpload":
            guard let id = id, let s = SharedVault.shared.retryUpload(id: id) else { return Result(ok: false, error: "Eintrag nicht gefunden") }
            SharedVaultHook.backend?.push(s); return Result(ok: true, id: id)
        case "cleanupBig":  // „Große Dateien aufräumen": Teile grosser, nicht angehefteter Eintraege vom Server loeschen
            let list = SharedVaultHook.cleanupBig()
            return Result(ok: true, extra: ["ids": list.map(\.id), "bytes": list.reduce(Int64(0)) { $0 + ($1.size ?? 0) }])
        case "saveToDownloads":
            guard let id = id, let dest = SharedVault.shared.saveToDownloads(id: id) else { return Result(ok: false, error: "Datei nicht (lokal) vorhanden") }
            return Result(ok: true, id: id, extra: ["path": dest.path])
        case "transfers":   // laufende Uebertragungen: {id: {dir, done, total}}
            var d: [String: Any] = [:]
            for (k, t) in SharedVault.shared.transfers { d[k] = ["dir": t.dir == .up ? "up" : "down", "done": t.done, "total": t.total] }
            return Result(ok: true, extra: ["transfers": d])
        case "sharedNew":   // neue Eintraege vom Partner (gruener Punkt): Anzahl + ids, neueste zuerst
            let seen = SharedSeen.shared
            seen.reload()
            let ids = seen.newItems.map(\.id)
            return Result(ok: true, extra: ["count": ids.count, "ids": ids, "baseline": seen.baseline])
        case "markSeen":    // id=<eintrag> oder all=1
            let seen = SharedSeen.shared
            let all: Bool = {
                if let b = o["all"] as? Bool { return b }
                if let n = o["all"] as? NSNumber { return n.intValue != 0 }
                if let s = str(o, "all")?.lowercased() { return ["1", "true", "ja", "yes"].contains(s) }
                return false
            }()
            let marked: [String]
            if all { marked = seen.markAllSeen() }
            else {
                guard let id = id else { return Result(ok: false, error: "id oder all=1 fehlt") }
                guard SharedVault.shared.item(id) != nil else { return Result(ok: false, error: "Eintrag nicht gefunden") }
                marked = seen.markSeen([id])
            }
            let rest = seen.newItems.map(\.id)
            return Result(ok: true, id: all ? nil : id, extra: ["marked": marked, "count": rest.count, "ids": rest])
        case "reload":
            store.reloadFromDisk(); SharedVault.shared.load(); SharedSeen.shared.reload(); ChangeNotifier.bump()
            return Result(ok: true)
        case "show":
            DispatchQueue.main.async {
                let pc = AppState.shared.panel
                if !pc.panel.isVisible { pc.show(on: NSScreen.main ?? NSScreen.screens[0]) }
                if let c = self.str(o, "collection") { pc.open(collection: c) }
            }
            return Result(ok: true)
        default:
            return Result(ok: false, error: "unbekannte Aktion: \(action)")
        }
    }
}
