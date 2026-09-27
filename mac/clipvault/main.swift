// ClipVault — Einstieg: Befehle (doctor, add, copy-ki, …) + App-Start
import Cocoa
import Carbon.HIToolbox
import QuartzCore
import QuickLookThumbnailing
import WebKit
import CryptoKit

let cliArgs = CommandLine.arguments
if cliArgs.count >= 2 && cliArgs[1] == "copy-ki" {
    let text = cliArgs.count >= 3 ? cliArgs[2] : (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "")
    let p = NSPasteboard.general; p.clearContents()
    p.setString(text, forType: .string)
    p.setString("KI", forType: NSPasteboard.PasteboardType("app.flowdictation.clipvault.source"))
    exit(0)
}
// Datei in den Verlauf legen, OHNE die Zwischenablage anzufassen: clipvault add /pfad.png
// (Hammerspoon ruft das bei jedem Screenshot -> der Screenshot ist immer in ClipVault,
//  auch wenn die Vorschau-Blase verpasst wurde.)
if cliArgs.count >= 3 && cliArgs[1] == "add" {
    let path = (cliArgs[2] as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: path) else { print("Datei nicht gefunden: \(path)"); exit(1) }
    // Erst nach ~/.config/flow-clipvault/incoming/ kopieren: Dieser Befehl laeuft als Kind von Hammerspoon
    // (mit dessen Schreibtisch-Freigabe). So muss die Dauer-App nie selbst auf den Schreibtisch zugreifen.
    var handoff = path
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
       let sz = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil, sz <= 200 * 1024 * 1024 {
        let d = URL(fileURLWithPath: CV_DIR + "incoming/" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let dest = d.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        if (try? FileManager.default.copyItem(atPath: path, toPath: dest.path)) != nil { handoff = dest.path + "\t" + path }
    }
    let counter = Int(Date().timeIntervalSince1970 * 10)
    try? "\(counter) \(handoff)".write(toFile: CV_DIR + "ingest-cmd", atomically: true, encoding: .utf8)
    print("an ClipVault uebergeben: \(path)")
    exit(0)
}
// Texterkennung fuer EIN Bild (wird von der laufenden App als Kindprozess genutzt): clipvault ocr-file <bild>
if cliArgs.count >= 3 && cliArgs[1] == "ocr-file" {
    guard let t = recognizeText(at: URL(fileURLWithPath: (cliArgs[2] as NSString).expandingTildeInPath)) else {
        FileHandle.standardError.write("Bild nicht lesbar\n".data(using: .utf8)!); exit(2)
    }
    FileHandle.standardOutput.write(t.data(using: .utf8)!); exit(0)
}
// Befehl an die laufende App schicken (Test/Skripte):  clipvault send <aktion> [feld=wert …]
//   z. B.  clipvault send addText text="Hallo" · clipvault send pin id=<id> · clipvault send ping
// Wartet bis 3 s auf die Antwort (app.flowdictation.clipvault.result) und gibt sie aus.
if cliArgs.count >= 3 && cliArgs[1] == "send" {
    guard let token = CVToken.read() else { print("Kein Schluessel (~/.config/flow-clipvault/token) — laeuft ClipVault schon in der neuen Fassung?"); exit(1) }
    var o: [String: Any] = ["token": token, "action": cliArgs[2]]
    for a in cliArgs.dropFirst(3) {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        if kv[1] == "null" { o[kv[0]] = NSNull() } else if kv[1] == "true" || kv[1] == "false" { o[kv[0]] = (kv[1] == "true") } else { o[kv[0]] = kv[1] }
    }
    let req = UUID().uuidString; o["reqId"] = req
    let data = try! JSONSerialization.data(withJSONObject: o)
    let appS = NSApplication.shared; appS.setActivationPolicy(.prohibited)
    var done = false
    DistributedNotificationCenter.default().addObserver(forName: CommandChannel.resultName, object: nil, queue: .main) { n in
        guard let s = n.object as? String, s.contains(req) else { return }
        print(s); done = true; exit(0)
    }
    DistributedNotificationCenter.default().postNotificationName(CommandChannel.cmdName, object: String(data: data, encoding: .utf8)!, userInfo: nil, deliverImmediately: true)
    let wait: Double = ["pair", "sync", "unpair", "sendvocab"].contains(where: { cliArgs[2].lowercased().hasPrefix($0) }) ? 25 : 3
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { if !done { print("Keine Antwort (laeuft ClipVault? stimmt der Schluessel?)"); exit(1) } }
    appS.run()
}
// Aenderungs-/Antwort-Meldungen mitlesen (Test):  clipvault listen [sekunden]
if cliArgs.count >= 2 && cliArgs[1] == "listen" {
    let secs = cliArgs.count >= 3 ? (Double(cliArgs[2]) ?? 10) : 10
    let appL = NSApplication.shared; appL.setActivationPolicy(.prohibited)
    let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
    for name in [ChangeNotifier.name, CommandChannel.resultName, VocabStore.notifyName] {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { n in
            print("[\(df.string(from: Date()))] \(n.name.rawValue) \(n.object as? String ?? "")"); fflush(stdout)
        }
    }
    print("hoere \(Int(secs)) s …"); fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    appL.run()
}
// Selbstdiagnose: clipvault doctor
if cliArgs.count >= 2 && cliArgs[1] == "doctor" {
    func run(_ cmd: String) -> String {
        let t = Process(); t.launchPath = "/bin/sh"; t.arguments = ["-c", cmd]
        let pipe = Pipe(); t.standardOutput = pipe; t.standardError = Pipe()
        try? t.run(); t.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    func mark(_ ok: Bool) -> String { ok ? " OK  " : "FEHLT" }
    let unknown = "  ?  "
    print("ClipVault — Selbstdiagnose\n" + String(repeating: "=", count: 46))
    // nur DIESE Installation (Pfad), nie eine andere ClipVault-Kopie auf demselben Mac
    let pids = run("pgrep -f '^\(CV_DIR)clipvault( |$)'")
    print("\(mark(!pids.isEmpty))  laeuft            \(pids.isEmpty ? "nicht gestartet — 'launchctl kickstart -k gui/$(id -u)/app.flowdictation.clipvault'" : "PID \(pids.replacingOccurrences(of: "\n", with: ", "))")")
    let status = (try? String(contentsOfFile: CV_DIR + "status.txt", encoding: .utf8)) ?? ""
    var kv: [String:String] = [:]
    for l in status.split(separator: "\n") { let p = l.split(separator: "=", maxSplits: 1); if p.count == 2 { kv[String(p[0])] = String(p[1]) } }
    if status.isEmpty {
        print("\(unknown)  Cmd+Shift+V       unbekannt — die laufende Fassung ist aelter als diese Diagnose. Neu installieren, dann nochmal.")
    } else {
        let hk = kv["hotkey"] == "ok"
        print("\(mark(hk))  Cmd+Shift+V       \(hk ? "Hotkey registriert" : "NICHT registriert — belegt eine andere App Cmd+Shift+V?")")
    }
    print("\(status.isEmpty ? unknown : mark(true))  Verlauf           \(kv["eintraege"] ?? "unbekannt") Eintraege, \(kv["bereiche"] ?? "unbekannt") Bereiche")
    let tokOK = CVToken.read() != nil
    let perms = ((try? FileManager.default.attributesOfItem(atPath: CVToken.path))?[.posixPermissions] as? Int) ?? 0
    print("\(mark(tokOK && perms == 0o600))  Befehlskanal      \(tokOK ? "Schluessel da (\(String(perms, radix: 8)))" : "kein Schluessel — neue Fassung noch nicht gestartet")\(kv["befehle"].map { " · \($0)" } ?? "")")
    if let o = kv["ocr"] { print("\(mark(true))  Texterkennung     \(o) Bilder gelesen") }
    if let g = kv["geteilt"] { print("\(mark(true))  Geteilt           \(g) · Sync: \(kv["sync"] ?? "keins")\(kv["sync_state"].map { " (\($0))" } ?? "")\(kv["sync_reason"].map { " – \($0)" } ?? "")") }
    let agent = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/app.flowdictation.clipvault.plist")
    print("\(mark(agent))  Autostart         \(agent ? "LaunchAgent installiert" : "kein LaunchAgent — startet nicht von allein")")
    // Screenshots
    let loc = run("defaults read com.apple.screencapture location 2>/dev/null")
    let shotDir = loc.isEmpty ? NSHomeDirectory() + "/Desktop" : (loc as NSString).expandingTildeInPath
    print("\(mark(FileManager.default.fileExists(atPath: shotDir)))  Screenshot-Ordner \(shotDir)")
    let hsRunning = !run("pgrep -x Hammerspoon").isEmpty
    print("\(hsRunning ? mark(true) : " opt ")  Hammerspoon       \(hsRunning ? "laeuft (optional: eigene Screenshot-Kuerzel)" : "nicht noetig — optional fuer eigene Screenshot-Kuerzel")")
    let ax = AXIsProcessTrusted()
    print("\(mark(ax))  Bedienungshilfen  \(ax ? "erteilt" : "fehlt fuer dieses Programm (fuer Hammerspoon separat pruefen)")")
    let thumb = run("defaults read com.apple.screencapture show-thumbnail 2>/dev/null")
    print("\(mark(thumb == "0"))  Apple-Vorschau    \(thumb == "0" ? "aus (unsere Vorschau uebernimmt)" : "an — Apples Miniatur ueberlagert unsere; 'defaults write com.apple.screencapture show-thumbnail -bool false'")")
    print(String(repeating: "-", count: 46))
    if let log = try? String(contentsOfFile: CV_DIR + "clipvault.log", encoding: .utf8) {
        let last = log.split(separator: "\n").suffix(8)
        print("Letzte Meldungen:"); last.forEach { print("  " + $0) }
    } else { print("Noch keine Meldungen protokolliert.") }
    exit(0)
}
// Statisches Render der PhoneDrop-Karte (Design-Check): clipvault phonedrop-render /pfad.png
if cliArgs.count >= 3 && cliArgs[1] == "phonedrop-render" {
    CV_READ_ONLY = true
    let appR = NSApplication.shared; appR.setActivationPolicy(.accessory)
    let pd = PhoneDrop.shared
    pd.renderState(mid: 0.78)
    let v = pd.root; v.layoutSubtreeIfNeeded()
    let container = NSView(frame: v.bounds); container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(white:0.10, alpha:1).cgColor
    container.addSubview(v)
    container.layoutSubtreeIfNeeded()
    let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
    container.cacheDisplay(in: container.bounds, to: rep)
    try? rep.representation(using:.png, properties:[:])!.write(to: URL(fileURLWithPath: cliArgs[2]))
    print("phonedrop render ok"); exit(0)
}
// Link-Vorschau testen: clipvault linkprev-test <url> /pfad.png
if cliArgs.count >= 4 && cliArgs[1] == "linkprev-test" {
    CV_READ_ONLY = true
    let appL = NSApplication.shared; appL.setActivationPolicy(.accessory)
    guard let u = URL(string: cliArgs[2]) else { print("bad url"); exit(1) }
    LinkPreview.shared.fetch(u) { img, title in
        if let img = img, let png = img.pngData() {
            try? png.write(to: URL(fileURLWithPath: cliArgs[3]))
            print("ok  title=\(title ?? "-")  size=\(Int(img.size.width))x\(Int(img.size.height))")
        } else { print("FAIL  title=\(title ?? "-")") }
        exit(0)
    }
    appL.run()
}
// Statisches Render des Panels (Design-Check): clipvault panel-render /pfad.png
// Szenen: link (Standard) · text · bild · farbe · passwort · geteilt · geteilt-neu · geteilt-gesehen · geteilt-bild · bilder (Filter) · bearbeiten
if cliArgs.count >= 3 && cliArgs[1] == "panel-render" {
    CV_READ_ONLY = true   // Zweitprozess: nichts schreiben, nichts loeschen
    let appP = NSApplication.shared; appP.setActivationPolicy(.accessory)
    let pc = PanelController()
    pc.table.floatsGroupRows = false   // schwebende Kopfzeile malt offscreen einen schwarzen Balken (nur im Render)
    pc.reload()
    let scene = cliArgs.count >= 4 ? cliArgs[3] : "link"
    func pick(_ f: (ClipItem) -> Bool) {
        guard let li = Store.shared.items.first(where: f) else { return }
        pc.currentCollection = li.collection; pc.reload()
        if let idx = pc.display.firstIndex(where: { pc.rowId($0) == li.id }) { pc.selectRow(idx) }
    }
    switch scene {
    case "text": pick { $0.kind == .text && $0.collection == nil && soleURL($0.text) == nil }
    case "bild": pick { $0.kind == .image && !($0.ocrText ?? "").isEmpty }
    case "farbe": pick { $0.kind == .text && $0.badges.contains(.color) }
    case "passwort": pick { $0.kind == .text && Store.shared.isSecret($0.collection) }
    case "geteilt": pc.currentCollection = SHARED_CHIP; pc.buildChips(); pc.reload()
    case "geteilt-neu", "geteilt-gesehen":
        // Neues vom Partner: Stand aus shared-seen.json; gibt es dort nichts Neues, gelten fuer das Bild alle
        // Partner-Eintraege als neu (nur im Speicher, es wird nichts geschrieben)
        if SharedSeen.shared.newCount == 0 { SharedSeen.shared.overrideForRender(baseline: 0, seen: []) }
        pc.currentCollection = SHARED_CHIP; pc.buildChips(); pc.buildFilters(); pc.reload()
        if let first = SharedSeen.shared.newItems.first, let idx = pc.display.firstIndex(where: { pc.rowId($0) == first.id }) { pc.selectRow(idx) }
        if scene == "geteilt-gesehen" { RunLoop.main.run(until: Date().addingTimeInterval(1.8)) }   // Vorschau-Verweilen > 1,5 s
    case "geteilt-dateien", "geteilt-laedt", "geteilt-lokal":
        // Dateien im geteilten Tresor: Speicherstand, Fortschrittsring, „Laden" / lokale Datei (nur im Speicher)
        SharedVault.shared.storage = SharedStorage(used: 1_210_000_000, quota: 3_000_000_000, bigCount: 2, bigBytes: 130_000_000)
        let files = SharedVault.shared.visible.filter { $0.kind == .file }
        let notLocal = files.first { !SharedVault.shared.isLocal($0) && $0.serverGone != true }
        let local = files.first { SharedVault.shared.isLocal($0) && $0.isBig } ?? files.first { SharedVault.shared.isLocal($0) }
        let busy = files.first { !SharedVault.shared.isLocal($0) && $0.id != notLocal?.id && $0.serverGone != true } ?? notLocal
        if let b = busy, let sz = b.size { SharedVault.shared.setTransfer(b.id, SharedTransfer(dir: .down, done: sz * 45 / 100, total: sz)) }
        pc.currentCollection = SHARED_CHIP; pc.buildChips(); pc.buildFilters(); pc.reload()
        let want = scene == "geteilt-lokal" ? local : (scene == "geteilt-laedt" ? busy : notLocal)
        if let w = want, let idx = pc.display.firstIndex(where: { pc.rowId($0) == w.id }) {
            pc.selectRow(idx, scroll: true); pc.table.layoutSubtreeIfNeeded()
            (pc.table.view(atColumn: 0, row: idx, makeIfNecessary: false) as? HoverRowView)?.onHover?()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // QuickLook-Vorschau
    case "bilder": pc.typeFilter = .images; pc.buildFilters(); pc.reload(); if let f = pc.firstItemRow() { pc.selectRow(f) }
    case "geteilt-bild":   // geteiltes Bild, das schon auf dem Mac liegt (Öffnen-Knopf, Klick = Quick Look)
        pc.currentCollection = SHARED_CHIP; pc.buildChips(); pc.buildFilters(); pc.reload()
        if let sh = SharedVault.shared.visible.first(where: { $0.kind == .image && SharedVault.shared.isLocal($0) }),
           let idx = pc.display.firstIndex(where: { pc.rowId($0) == sh.id }) { pc.selectRow(idx, scroll: true) }
    case "bearbeiten": pick { $0.kind == .text && $0.collection == nil && soleURL($0.text) == nil }
        if let it = pc.selectedClip() { pc.beginEdit(it) }
    case "teilen", "teilen-an":   // Hover-Pille + Vorschau mit Teilen-Knopf (nur im Speicher markiert, nichts wird geschrieben)
        if let li = Store.shared.items.first(where: { $0.kind == .text && $0.collection == nil && !$0.pinned && soleURL($0.text) == nil }) {
            li.shared = (scene == "teilen-an"); pc.reload()
            if let idx = pc.display.firstIndex(where: { pc.rowId($0) == li.id }) {
                pc.selectRow(idx, scroll: true); pc.table.layoutSubtreeIfNeeded()
                (pc.table.view(atColumn: 0, row: idx, makeIfNecessary: false) as? HoverRowView)?.onHover?()
            }
        }
    default: pick { $0.kind == .text && soleURL($0.text) != nil }
    }
    let v = pc.effect
    let container = NSView(frame: v.bounds); container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
    v.removeFromSuperview(); container.addSubview(v)
    container.layoutSubtreeIfNeeded()
    let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
    container.cacheDisplay(in: container.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: cliArgs[2]))
    print("panel render ok (\(scene))"); exit(0)
}
// Test: Datei-URL eines geteilten Eintrags auf eine EIGENE Zwischenablage legen (nie die allgemeine) und wie der
// Finder einfuegen (Datei-URL lesen, Datei in den Zielordner kopieren):  clipvault pasteboard-test <geteilte-id> <zielordner>
if cliArgs.count >= 4 && cliArgs[1] == "pasteboard-test" {
    CV_READ_ONLY = true; CV_HEADLESS = true
    let pb = NSPasteboard(name: NSPasteboard.Name("app.flowdictation.clipvault.test." + UUID().uuidString))
    defer { pb.releaseGlobally() }
    guard SharedVault.shared.copyToPasteboard(id: cliArgs[2], pasteboard: pb) else { print("FEHLER: nicht kopierbar (nicht geladen?)"); exit(1) }
    print("Typen: " + (pb.types ?? []).map(\.rawValue).joined(separator: ", "))
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard let u = urls.first else { print("FEHLER: keine Datei-URL"); exit(1) }
    let dest = URL(fileURLWithPath: (cliArgs[3] as NSString).expandingTildeInPath).appendingPathComponent(u.lastPathComponent)
    try? FileManager.default.removeItem(at: dest)
    do { try FileManager.default.copyItem(at: u, to: dest) } catch { print("FEHLER: \(error.localizedDescription)"); exit(1) }
    print("eingefuegt: \(dest.path)"); exit(0)
}
// Live-Test der Animation: clipvault test-phonedrop
if cliArgs.count >= 2 && cliArgs[1] == "test-phonedrop" {
    let appT = NSApplication.shared; appT.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { PhoneDrop.shared.show("Text in Zwischenablage") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { exit(0) }
    appT.run()
}
// Selbsttest: derselbe Screenshot ueber Datei + Zwischenablage -> ein Eintrag (nur mit CLIPVAULT_HOME)
if cliArgs.count >= 2 && cliArgs[1] == "doppelt-test" { runDoppeltTest(cliArgs) }
// Geteilter Tresor: Kopplung + Sync (sync.swift)
if cliArgs.count >= 2 && ["sync-agent", "pair", "unpair", "sync", "partner"].contains(cliArgs[1]) { runSyncCLI(cliArgs) }
// Unbekannter Befehl? Dann NICHT stillschweigend die ganze App starten.
// (Genau das passierte frueher: ein Tippfehler oder ein Befehl aus einer neueren Fassung
//  startete eine ZWEITE ClipVault-Instanz — zwei Menueleisten-Symbole und zwei Programme,
//  die gleichzeitig in denselben Verlauf schreiben.)
if cliArgs.count >= 2 && !cliArgs[1].hasPrefix("-") {
    print("""
    ClipVault — Zwischenablage-Verlauf

    Ohne Argument startet das Programm im Hintergrund (Menueleiste + Cmd+Shift+V).

    Befehle:
      doctor              Selbstdiagnose (laeuft es? greift der Hotkey? Screenshot-Ordner?)
      add <pfad>          Datei in den Verlauf legen, ohne die Zwischenablage anzufassen
      copy-ki [text]      Text kopieren und als "von KI" markieren (auch ueber stdin)
      panel-render <png> [szene]
                          Fenster als Bild ablegen (Gestaltungs-Kontrolle)
                          szene: link · text · bild · farbe · passwort · geteilt · geteilt-neu · geteilt-gesehen
                                 · bilder · bearbeiten · teilen · teilen-an
                                 · geteilt-dateien · geteilt-laedt · geteilt-lokal
      send <aktion> [feld=wert …]
                          Befehl an die laufende App (siehe PROTOCOL.md), z. B. send ping
      listen [sekunden]   Aenderungs-/Antwort-Meldungen mitlesen
      ocr-file <bild>     Text in einem Bild erkennen (Deutsch + Englisch)
      pair create [name] | join <code> [name] | cancel | status
      partner [name]      Name des Freundes/Partners setzen (leer = „Partner“)
                          Geteilten Tresor mit dem Partner koppeln (Ende-zu-Ende verschluesselt)
      unpair              Kopplung trennen (Schluessel aus dem Schluesselbund loeschen)
      sync setup <url> | status
                          Sync-Server (Cloudflare Worker) eintragen / Zustand zeigen
      sync-agent          nur Sync ohne Oberflaeche (Test-/Zweitgeraet, mit CLIPVAULT_HOME)
      doppelt-test [--ohne-abgleich]
                          Selbsttest Screenshot-Doppel (nur mit CLIPVAULT_HOME=<Testordner>)
      linkprev-test <url> <png>
      phonedrop-render <png> | test-phonedrop

    Unbekannter Befehl: \(cliArgs[1])
    """)
    exit(1)
}

// Nur EINE Instanz. Zwei laufende Programme wuerden sich beim Speichern gegenseitig
// ueberschreiben — der Verlauf ginge dabei verloren.
func acquireSingleInstanceLock() -> Bool {
    let fd = open(CV_DIR + "app.lock", O_CREAT | O_RDWR, 0o644)
    if fd < 0 { return true }            // Sperre nicht moeglich -> im Zweifel starten
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    return true                          // fd bleibt offen -> Sperre gilt bis Programmende
}
if !acquireSingleInstanceLock() {
    cvLog("Start abgebrochen — ClipVault laeuft bereits")
    FileHandle.standardError.write("ClipVault laeuft bereits.\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if !FileManager.default.fileExists(atPath: AI_APPS_PATH) {
    try? AI_APPS_DEFAULT.write(toFile: AI_APPS_PATH, atomically: true, encoding: .utf8)
}
AppState.shared.start()
UCKiller.shared.start()
app.run()
