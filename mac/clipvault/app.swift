// ClipVault — App-Zustand: Zwischenablage erfassen, Hotkey, Aufnehmen von aussen
import Cocoa
import Carbon.HIToolbox
import QuartzCore
import QuickLookThumbnailing
import WebKit
import CryptoKit

// MARK: - App
final class AppState: NSObject {
    static let shared = AppState()
    var statusItem: NSStatusItem!
    let panel = PanelController()
    let pb = NSPasteboard.general; var lastChange = 0; var lastToastCounter = -1; var lastIngestCounter = -1
    var hotkeyRef: EventHotKeyRef?
    var hotkeyOK = false
    var handlerInstalled = false
    let startedAt = Date()
    func start() {
        lastChange = pb.changeCount
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
            b.image?.isTemplate = true
            b.target = self; b.action = #selector(toggle)
        }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkToast() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkIngest() }
        // Zustandsdatei aktuell halten (fuer `clipvault doctor`)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.writeStatus() }
        cvStatusWriter = { [weak self] in self?.writeStatus() }
        registerHotkey()
        cvLog("ClipVault gestartet (\(Store.shared.items.count) Eintraege)")
        // Befehlskanal fuer externe Oberflaechen + geteilter Tresor (Sync klinkt sich ein, falls sync.swift dabei ist)
        CommandChannel.shared.start()
        // liegengebliebene Zwischenkopien von `clipvault add` (App lief nicht) nach einem Tag wegraeumen
        let inc = URL(fileURLWithPath: CV_DIR + "incoming")
        for d in (try? FileManager.default.contentsOfDirectory(at: inc, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: d) }
        }
        SharedVaultHook.bootstrap()
        SharedSeen.shared.startWatching()   // shared-seen.json anlegen/lesen, Markierungen anderer Programme mitbekommen
        // Bilder ohne erkannten Text nach und nach lesen (erst wenn der Start durch ist)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { OCR.shared.backfill() }
        // Passwort-Bereich: abgelaufene Eintraege auch ohne neue Kopie entfernen
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            if Store.shared.prune() { Store.shared.persist(); self?.panel.refreshAfterExternalChange() }
        }
        let base = CV_DIR
        NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown]) { event in
            let btn = event.buttonNumber
            try? "\(btn)".write(toFile: base + "lastbutton.txt", atomically: true, encoding: .utf8)
            if let cfg = try? String(contentsOfFile: base + "openbutton.txt", encoding: .utf8),
               let n = Int(cfg.trimmingCharacters(in: .whitespacesAndNewlines)), n == btn {
                DispatchQueue.main.async { AppState.shared.toggle() }
            }
        }
    }
    @objc func toggle() { panel.toggle(on: NSScreen.main ?? NSScreen.screens.first!) }
    /// from: nur fuer den Selbsttest eine eigene Zwischenablage (nie die allgemeine anfassen)
    @discardableResult
    func capture(_ src: String?, from other: NSPasteboard? = nil) -> String? {
        let pb = other ?? self.pb
        let imgExt: Set<String> = ["jpg","jpeg","png","heic","heif","gif","tiff","tif","bmp","webp"]
        // EINZELNE Bilddatei (lokal kopiert ODER vom iPhone)? -> ECHTES Bild laden (nicht das Datei-Icon!)
        // + echte Bilddaten in die Zwischenablage, damit es ÜBERALL als Bild einfügbar ist
        if let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.filter({ FileManager.default.fileExists(atPath: $0.path) }), !urls.isEmpty {
            if urls.count == 1, imgExt.contains(urls[0].pathExtension.lowercased()), let nsi = NSImage(contentsOf: urls[0]), let png = nsi.pngData() {
                Store.shared.addImage(png, source: src, origin: urls[0].path)
                pb.clearContents(); pb.setData(png, forType: .png)
                if let tiff = nsi.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
                if other == nil { lastChange = pb.changeCount }   // eigene Änderung nicht erneut verarbeiten
                return "Bild in Zwischenablage"
            }
            Store.shared.addFiles(urls, source: src); return urls.count > 1 ? "Dateien in Zwischenablage" : "Datei in Zwischenablage"
        }
        // Inline-Bilddaten (Screenshot, Copy aus Preview/Browser)
        if let img = pb.data(forType: .png) { Store.shared.addImage(img, source: src); return "Bild in Zwischenablage" }
        if let tiff = pb.data(forType: .tiff), let nsi = NSImage(data: tiff), let png = nsi.pngData() { Store.shared.addImage(png, source: src); return "Bild in Zwischenablage" }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Store.shared.addText(s, source: src); return "Text in Zwischenablage" }
        return nil
    }
    func tick() {
        if pb.changeCount == lastChange { return }
        lastChange = pb.changeCount
        let typeNames = (pb.types ?? []).map { $0.rawValue }
        try? typeNames.joined(separator: "\n").write(toFile: CV_DIR + "lasttypes.txt", atomically: true, encoding: .utf8)
        // Universal Clipboard vom iPhone/iPad?
        let remote = typeNames.contains { $0.lowercased().contains("is-remote-clipboard") }
        if remote {
            // iPhone-Inhalt lädt asynchron -> kurz warten, dann erst lesen (sonst leer/Platzhalter)
            let cc = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                guard let self = self, self.pb.changeCount == cc else { return }
                let k = self.capture("iPhone")
                PhoneDrop.shared.show(k ?? "In Zwischenablage")
                self.panel.reloadIfVisible()
            }
            return
        }
        // nspasteboard.org-Konvention: Passwortmanager & Co. markieren Inhalte als verborgen/voruebergehend/
        // automatisch erzeugt — die gehoeren NICHT in einen Verlauf (auch das Diktat-Tool nutzt das im Passwortfeld).
        let skip = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        if typeNames.contains(where: { skip.contains($0) }) { return }
        // Reihenfolge: expliziter Marker (copy-ki) schlaegt App-Erkennung
        let explicit = pb.string(forType: NSPasteboard.PasteboardType("app.flowdictation.clipvault.source"))
        capture(explicit ?? aiSourceFromFrontmostApp())
        panel.reloadIfVisible()
    }
    // MARK: - Aufnehmen von aussen (16.08.2026)
    // Damit ein Screenshot IMMER im Verlauf landet — auch wenn die Vorschau-Blase
    // mal nicht kommt oder der Kopieren-Knopf verpasst wird. Hammerspoon schreibt
    // `<zaehler> <pfad>` in ingest-cmd, ClipVault legt die Datei in den Verlauf,
    // OHNE die Zwischenablage anzufassen (Lenas aktuelle Kopie bleibt unberuehrt).
    // 26.09.2026: Beim Start wurde der LETZTE Pfad aus ingest-cmd erneut eingelesen. Lag der auf dem
    // Schreibtisch, fragte macOS nach jedem Neubau (neue Signatur) erneut um Erlaubnis — und der
    // wartende open() blockierte die ganze App, bis jemand den Dialog beantwortete.
    // Jetzt: (1) alter Eintrag beim Start nur merken, nicht einlesen; (2) `clipvault add` kopiert die
    // Datei vorher nach ~/.config/flow-clipvault/incoming/ (als Kind von Hammerspoon mit dessen Freigabe),
    // (3) das Lesen passiert ausserhalb des Main-Threads.
    private var ingestPrimed = false
    private var ingestStamp: CVFileStamp?
    func checkIngest() {
        let p = CV_DIR + "ingest-cmd"
        // Audit 27.09.2026: nur lesen, wenn sich die Datei geaendert hat (vorher 4x/s oeffnen + lesen)
        let st = CVFileStamp(p)
        if ingestPrimed, st == ingestStamp { return }
        ingestStamp = st
        guard let txt = try? String(contentsOfFile: p, encoding: .utf8) else { ingestPrimed = true; return }
        let parts = txt.split(separator: " ", maxSplits: 1)
        guard let c = Int(parts.first ?? ""), parts.count > 1 else { ingestPrimed = true; return }
        if !ingestPrimed { ingestPrimed = true; lastIngestCounter = c; return }
        if c == lastIngestCounter { return }
        lastIngestCounter = c
        // Format: "<zaehler> <pfad>" oder "<zaehler> <kopie>\t<original>"
        let rest = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        ingest(path: rest[0], original: rest.count > 1 ? rest[1] : nil)
    }
    func ingest(path: String, original: String? = nil) {
        let url = URL(fileURLWithPath: path)
        let name = URL(fileURLWithPath: original ?? path).lastPathComponent
        let fromIncoming = path.hasPrefix(CV_DIR + "incoming/")
        let cleanup = { if fromIncoming { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        let imgExt: Set<String> = ["jpg","jpeg","png","heic","heif","gif","tiff","tif","bmp","webp"]
        guard imgExt.contains(url.pathExtension.lowercased()) else {
            DispatchQueue.global(qos: .utility).async {
                let ok = FileManager.default.fileExists(atPath: path)
                DispatchQueue.main.async { [weak self] in
                    guard ok else { cvLog("Aufnehmen: Datei fehlt — \(path)"); return }
                    Store.shared.addFiles([url], origPaths: original.map { [$0] })
                    cleanup(); cvLog("Aufgenommen (Datei): \(name)"); self?.panel.reloadIfVisible()
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let png: Data? = autoreleasepool {
                if url.pathExtension.lowercased() == "png", let d = try? Data(contentsOf: url) { return d }
                return NSImage(contentsOf: url)?.pngData()
            }
            DispatchQueue.main.async { [weak self] in
                defer { cleanup() }
                guard let png = png else { cvLog("Aufnehmen: Bild nicht lesbar — \(name)"); return }
                // Doppel (derselbe Screenshot kam schon ueber die Zwischenablage) fuehrt addImage selbst zusammen
                Store.shared.addImage(png, origin: original ?? path)
                cvLog("Aufgenommen: \(name)")
                self?.panel.reloadIfVisible()
            }
        }
    }
    private var toastStamp: CVFileStamp?
    private var toastPrimed = false
    func checkToast() {
        let p = CV_DIR + "toast-cmd"
        // Audit 27.09.2026: laeuft 20x/s — nur noch ein stat(); gelesen wird nur bei Aenderung.
        // Beim Start wird der alte Zaehler nur vorgemerkt (vorher kam der letzte Toast nach jedem Neustart erneut).
        let st = CVFileStamp(p)
        if toastPrimed, st == toastStamp { return }
        let first = !toastPrimed
        toastPrimed = true
        toastStamp = st
        guard let txt = try? String(contentsOfFile: p, encoding: .utf8) else { return }
        let parts = txt.split(separator: " ", maxSplits: 1)
        guard let c = Int(parts.first ?? "") else { return }
        if first { lastToastCounter = c; return }
        if c == lastToastCounter { return }
        lastToastCounter = c
        let text = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "In Zwischenablage"
        Toast.shared.show(text)
    }
    func copyAndPaste(_ item: ClipItem) {
        Store.shared.moveToTop(item); pb.clearContents()
        if item.kind == .text, let t = item.text { pb.setString(t, forType: .string) }
        else if item.kind == .file, let refs = item.files {
            let urls: [NSURL] = refs.compactMap { r in
                if FileManager.default.fileExists(atPath: r.orig) { return NSURL(fileURLWithPath: r.orig) }
                if let st = r.stored { let p = Store.shared.dir.appendingPathComponent(st).path; if FileManager.default.fileExists(atPath: p) { return NSURL(fileURLWithPath: p) } }
                return nil
            }
            if !urls.isEmpty { pb.writeObjects(urls) }
        }
        else if let d = Store.shared.dataFor(item) { pb.setData(d, forType: .png) }
        lastChange = pb.changeCount
        // nur kopieren - Lena fuegt selbst mit Cmd+V ein
    }
    // STABIL (16.08.2026): Frueher wurde der Rueckgabewert von RegisterEventHotKey ignoriert.
    // Hatte eine andere App Cmd+Shift+V schon belegt (oder war der Systemdienst beim Login noch
    // nicht bereit), tat der Hotkey einfach nichts — ohne jeden Hinweis. Jetzt wird der Status
    // geprueft, bei Fehlschlag mehrfach nachgefasst und das Ergebnis protokolliert.
    func registerHotkey(attempt: Int = 1) {
        if let r = hotkeyRef { UnregisterEventHotKey(r); hotkeyRef = nil }
        let hotID = EventHotKeyID(signature: OSType(0x434C4950), id: 1); var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), hotID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, ref != nil {
            hotkeyRef = ref; hotkeyOK = true
            if attempt > 1 { cvLog("Hotkey Cmd+Shift+V registriert (Versuch \(attempt))") }
        } else {
            hotkeyOK = false
            cvLog("Hotkey Cmd+Shift+V NICHT registriert (Code \(status), Versuch \(attempt)) — vermutlich von einer anderen App belegt")
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 3.0) { [weak self] in self?.registerHotkey(attempt: attempt + 1) }
            }
        }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let handler: EventHandlerUPP = { (_, _, _) -> OSStatus in DispatchQueue.main.async { AppState.shared.toggle() }; return noErr }
            InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        writeStatus()
    }
    // Zustandsdatei fuer `clipvault doctor` — beantwortet: laeuft es, greift der Hotkey, wie gross ist der Verlauf
    func writeStatus() {
        let s = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        hotkey=\(hotkeyOK ? "ok" : "FEHLT")
        eintraege=\(Store.shared.items.count)
        bereiche=\(Store.shared.collections.count)
        befehle=\(CommandChannel.shared.handled) ok, \(CommandChannel.shared.rejected) abgelehnt
        ocr=\(Store.shared.items.filter { $0.kind == .image && $0.ocrText != nil }.count)/\(Store.shared.items.filter { $0.kind == .image }.count)
        geteilt=\(SharedVault.shared.visible.count) (\(SharedVault.shared.pending.count) wartend)
        shared_new=\(SharedSeen.shared.newCount)
        \(cvSyncStatusLines().joined(separator: "\n"))
        seit=\(ISO8601DateFormatter().string(from: startedAt))
        """
        try? s.write(toFile: CV_DIR + "status.txt", atomically: true, encoding: .utf8)
    }
}
