import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Geteilter Tresor mit dem Partner
// Die Echtzeit-Synchronisation baut ein anderer Agent. Er liefert eine Klasse, die `SharedVaultSource` erfüllt,
// und setzt sie beim Start:   CVShared.install(MeineQuelle())
// Bis dahin läuft `CVPlaceholderSharedSource` (leer, Kopplungscode nur als Vorschau).

struct SharedVaultItem: Identifiable, Equatable {
    let id: String
    var kind: CVKind
    var text: String?
    /// Lokale Datei (Bild) – die Quelle lädt sie herunter und legt sie ab
    var image: URL?
    var fileName: String?
    /// Vorname dessen, der geteilt hat (ClipVault: shared-me.txt bzw. Vorname des macOS-Kontos)
    var createdBy: String
    var createdAt: Date
    var pinned: Bool
    /// Dateien: lokale Kopie (ClipVault: shared/files/<id>/<name>), nil = noch nicht geladen (große Dateien laden auf Abruf)
    var file: URL? = nil
    var size: Int64? = nil

    var fromMe: Bool { Identity.isMe(createdBy) }
    /// „30,4 MB" bzw. „30,4 MB · noch nicht geladen"
    var sizeLabel: String {
        let s = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        guard kind == .file, file == nil else { return s }
        return s.isEmpty ? "noch nicht geladen" : s + " · noch nicht geladen"
    }
    /// Finder-Icon der Datei (oder ihres Typs, solange sie nicht geladen ist)
    var fileIcon: NSImage {
        if let f = file { return NSWorkspace.shared.icon(forFile: f.path) }
        let ext = ((fileName ?? "") as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

enum SharedVaultStatus: Equatable {
    case notPaired
    /// Kopplungscode wird angezeigt, der Partner gibt ihn auf seinem Mac ein (payload = Inhalt für den QR-Code)
    case pairing(code: String, payload: String)
    case connecting
    case connected(partner: String)
    case offline(reason: String)

    var isConnected: Bool { if case .connected = self { return true }; return false }
    var label: String {
        switch self {
        case .notPaired: return "Nicht verbunden"
        case .pairing: return "Wartet auf \(Identity.partner(.accusative)) …"
        case .connecting: return "Verbinde …"
        case .connected(let p): return "Verbunden mit \(p) · live"
        case .offline(let r): return "Offline – \(r)"
        }
    }
}

/// Schnittstelle für den Sync-Agenten. Alle Aufrufe und `onChange` auf dem Main-Thread.
protocol SharedVaultSource: AnyObject {
    var items: [SharedVaultItem] { get }          // neueste zuerst
    var status: SharedVaultStatus { get }
    /// Muss bei jeder Änderung von items/status aufgerufen werden (Main-Thread)
    var onChange: (() -> Void)? { get set }
    func start()
    func beginPairing()
    func cancelPairing()
    func unpair()
    func setPinned(_ id: String, _ pinned: Bool)
    func remove(_ id: String)
}

/// Beobachtbare Hülle für die Oberfläche
final class CVShared: ObservableObject {
    static let shared = CVShared()
    private(set) var source: SharedVaultSource = CVFileSharedSource()
    @Published private(set) var items: [SharedVaultItem] = []
    @Published private(set) var status: SharedVaultStatus = .notPaired
    @Published private(set) var freshIDs: Set<String> = []
    private var started = false

    private init() {}

    /// Vom Sync-Agenten beim App-Start aufrufen
    static func install(_ s: SharedVaultSource) {
        shared.source = s
        shared.bind()
        if shared.started { s.start() }
        shared.pull(animated: false)
    }

    func start() {
        guard !started else { return }
        started = true
        bind()
        source.start()
        pull(animated: false)
    }

    private func bind() {
        source.onChange = { [weak self] in self?.pull(animated: true) }
    }

    private func pull(animated: Bool) {
        let new = source.items
        let old = Set(items.map(\.id))
        let added = new.filter { !old.contains($0.id) }.map(\.id)
        if animated && !added.isEmpty && !items.isEmpty {
            freshIDs.formUnion(added)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.freshIDs.subtract(added) }
        }
        withAnimation(animated ? .spring(response: 0.42, dampingFraction: 0.82) : nil) {
            items = new
            status = source.status
        }
    }

    func beginPairing() { source.beginPairing() }
    func cancelPairing() { source.cancelPairing() }
    func unpair() { source.unpair() }
    func setPinned(_ id: String, _ on: Bool) { source.setPinned(id, on) }
    func remove(_ id: String) { source.remove(id) }

    func copy(_ item: SharedVaultItem) {
        if source is CVFileSharedSource, ClipVaultClient.shared.canSendCommands {
            ClipVaultClient.shared.send("copy", id: item.id)
            ClipVaultClient.shared.show(CVToast(text: "Kopiert", symbol: "doc.on.doc"))
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let f = item.file { pb.writeObjects([f as NSURL]) }   // echte Datei (Finder, Mail, WhatsApp …)
        else if let u = item.image, let img = NSImage(contentsOf: u) { pb.writeObjects([img]) } else { pb.setString(item.text ?? "", forType: .string) }
        ClipVaultClient.shared.show(CVToast(text: "Kopiert", symbol: "doc.on.doc"))
    }
}

/// Standard: liest ClipVaults lokalen geteilten Bestand (~/.config/flow-clipvault/shared.json + shared/<id>.png) – nur lesend.
/// Änderungen (anheften, entfernen) gehen über den Befehlskanal. Sobald der Sync (clipvault/sync.swift) läuft,
/// schreibt ClipVault die Einträge des Partners in dieselbe Datei → sie erscheinen hier live (changed-Meldung + 2-s-Abfrage).
final class CVFileSharedSource: SharedVaultSource {
    private(set) var items: [SharedVaultItem] = []
    private(set) var status: SharedVaultStatus = .notPaired
    var onChange: (() -> Void)?
    private var stamp: Date?
    private var statusStamp: Date?
    private var pairing: SharedVaultStatus?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    private var base: URL { ClipVaultClient.base }
    private var jsonURL: URL { base.appendingPathComponent("shared.json") }

    func start() {
        load(force: true)
        observer = DistributedNotificationCenter.default().addObserver(forName: ClipVaultClient.changedName, object: nil, queue: .main) { [weak self] _ in
            self?.load(force: true)
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.load(force: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Einstellungen → ClipVault (status.txt sync_partner / shared-partner.txt) → „deinem Partner“
    private var partner: String { Identity.partner(.dative) }

    private func load(force: Bool) {
        let m = ClipVaultClient.mtime(jsonURL), sm = ClipVaultClient.mtime(base.appendingPathComponent("status.txt"))
        if !force && m == stamp && sm == statusStamp { return }
        stamp = m; statusStamp = sm
        var newItems: [SharedVaultItem] = []
        if let data = try? Data(contentsOf: jsonURL),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let arr = o["items"] as? [[String: Any]] {
            newItems = arr.compactMap { d -> SharedVaultItem? in
                guard let id = d["id"] as? String, (d["deleted"] as? Bool) != true else { return nil }
                let kind: CVKind = {
                    switch d["kind"] as? String { case "image": return .image; case "link": return .link; case "file": return .file; default: return .text }
                }()
                let img = base.appendingPathComponent("shared/\(id).png")
                let name = d["fileName"] as? String
                // Datei: neu shared/files/<id>/<name>, aeltere ClipVault-Fassung shared/<id>/<name>
                let file = name.flatMap { n in
                    [base.appendingPathComponent("shared/files/\(id)/\(n)"), base.appendingPathComponent("shared/\(id)/\(n)")]
                        .first { FileManager.default.fileExists(atPath: $0.path) }
                }
                return SharedVaultItem(id: id, kind: kind, text: d["text"] as? String,
                                       image: kind == .image && FileManager.default.fileExists(atPath: img.path) ? img : nil,
                                       fileName: name,
                                       createdBy: (d["createdBy"] as? String) ?? Identity.clipVaultMe,
                                       createdAt: Date(timeIntervalSince1970: (d["createdAt"] as? Double) ?? 0),
                                       pinned: (d["pinned"] as? Bool) ?? false,
                                       file: kind == .file ? file : nil,
                                       size: (d["size"] as? NSNumber)?.int64Value
                                           ?? file.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)??.int64Value })
            }.sorted { $0.createdAt > $1.createdAt }
        }
        // Sync-Stand aus status.txt: sync=cloudflare|keins, sync_state=connected|connecting|offline|pairing|waiting|unpaired
        let st = (try? String(contentsOf: base.appendingPathComponent("status.txt"), encoding: .utf8)) ?? ""
        func val(_ k: String) -> String { st.split(separator: "\n").first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } ?? "" }
        let sync = val("sync"), state = val("sync_state")
        // Kopplungscode, solange ClipVault einen anzeigt (sync-pairing.json, 0600, 15 min)
        var code: SharedVaultStatus?
        if let d = try? Data(contentsOf: base.appendingPathComponent("sync-pairing.json")),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let c = o["code"] as? String,
           ((o["expiresAt"] as? Double) ?? 0) > Date().timeIntervalSince1970 {
            code = .pairing(code: c, payload: (o["payload"] as? String) ?? c)
        }
        let newStatus: SharedVaultStatus
        if let code { newStatus = code; pairing = nil }
        else if state == "offline" { newStatus = .offline(reason: val("sync_reason").isEmpty ? "wartet auf Netz" : val("sync_reason")); pairing = nil }
        else if state == "connecting" { newStatus = .connecting; pairing = nil }
        else if state == "waiting" || state == "unpaired" || state == "unconfigured" { newStatus = pairing ?? .notPaired }
        else if !sync.isEmpty && sync != "keins" && sync != "–" { newStatus = .connected(partner: partner); pairing = nil }
        else { newStatus = pairing ?? .notPaired }
        if newItems != items || newStatus != status {
            items = newItems; status = newStatus
            onChange?()
        }
    }

    // Echter Ablauf ueber ClipVaults Befehlskanal (sync.swift): ClipVault legt den Code in sync-pairing.json ab,
    // meldet „changed" -> load() zeigt ihn. Fehler (z. B. kein Sync-Server eingetragen) kommen als Hinweis-Toast.
    func beginPairing() {
        pairing = .connecting; status = .connecting; onChange?()
        // Name des Partners (Einstellungen/Onboarding) gleich an ClipVault geben – so heißt er in „Geteilt mit …“
        let name = Settings.shared.partnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        ClipVaultClient.shared.send("pairCreate", extra: name.isEmpty ? [:] : ["name": name], onError: { [weak self] err in
            ClipVaultClient.shared.show(CVToast(text: "Koppeln: \(err)", symbol: "exclamationmark.triangle", isError: true))
            self?.pairing = nil; self?.load(force: true)
        })
    }
    func cancelPairing() { ClipVaultClient.shared.send("pairCancel"); pairing = nil; status = .notPaired; onChange?() }
    func unpair() { ClipVaultClient.shared.send("unpair"); pairing = nil; status = .notPaired; onChange?() }
    func setPinned(_ id: String, _ pinned: Bool) {
        // scope=shared: den geteilten Eintrag meinen, nicht den gleichnamigen Verlaufs-Eintrag
        ClipVaultClient.shared.send(pinned ? "pin" : "unpin", id: id, extra: ["scope": "shared"])
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].pinned = pinned; onChange?() }
    }
    func remove(_ id: String) {
        ClipVaultClient.shared.send("unshare", id: id)
        items.removeAll { $0.id == id }; onChange?()
    }
}

/// Platzhalter bis der Sync steht: keine Einträge, Kopplungscode nur lokal erzeugt.
final class CVPlaceholderSharedSource: SharedVaultSource {
    private(set) var items: [SharedVaultItem] = []
    private(set) var status: SharedVaultStatus = .notPaired
    var onChange: (() -> Void)?

    func start() {}

    func beginPairing() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<6).map { _ in alphabet.randomElement()! })
        let pretty = code.prefix(3) + "-" + code.suffix(3)
        status = .pairing(code: String(pretty), payload: "clipvault-pair://\(pretty)")
        onChange?()
    }

    func cancelPairing() { status = .notPaired; onChange?() }
    func unpair() { status = .notPaired; onChange?() }
    func setPinned(_ id: String, _ pinned: Bool) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].pinned = pinned; onChange?() }
    }
    func remove(_ id: String) { items.removeAll { $0.id == id }; onChange?() }
}

/// Nur für die Sichtprüfung: erfundene Einträge, verbunden
final class CVDemoSharedSource: SharedVaultSource {
    var items: [SharedVaultItem]
    var status: SharedVaultStatus
    var onChange: (() -> Void)?
    init(connected: Bool) {
        status = connected ? .connected(partner: Identity.partnerName ?? "Sam") : .notPaired
        let partner = Identity.partnerName ?? "Sam", me = Identity.myName
        let now = Date()
        items = !connected ? [] : [
            SharedVaultItem(id: "s1", kind: .text, text: "Treffpunkt Samstag: 9:30 am Bus, Liste der Kinder liegt im Ordner „Camp“.",
                            createdBy: partner, createdAt: now.addingTimeInterval(-120), pinned: true),
            SharedVaultItem(id: "s5", kind: .file, text: nil, fileName: "Camp-Video.mp4", createdBy: partner,
                            createdAt: now.addingTimeInterval(-600), pinned: false, size: 30_421_636),
            SharedVaultItem(id: "s2", kind: .link, text: "https://example.com/camp-planung", createdBy: me,
                            createdAt: now.addingTimeInterval(-1500), pinned: false),
            SharedVaultItem(id: "s3", kind: .text, text: "Rechnungsnummer-Schema: RE-2026-### – bitte ab jetzt so benennen.",
                            createdBy: me, createdAt: now.addingTimeInterval(-5400), pinned: false),
            SharedVaultItem(id: "s4", kind: .text, text: "Prompt: Fasse das Meeting in 5 Stichpunkten zusammen, Aufgaben mit Namen.",
                            createdBy: partner, createdAt: now.addingTimeInterval(-90000), pinned: false),
        ]
    }
    func start() {}
    func beginPairing() {}
    func cancelPairing() {}
    func unpair() {}
    func setPinned(_ id: String, _ pinned: Bool) {}
    func remove(_ id: String) {}
}

enum CVQR {
    /// QR-Code als scharfes Bild (Core Image)
    static func image(_ payload: String, size: CGFloat = 200) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(payload.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scale = (size * 2 / out.extent.width).rounded(.down)
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
