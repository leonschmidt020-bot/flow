import AppKit

/// „Mit Kontext“ kopieren, bevor Transkript und Bilder fertig sind.
///
/// 19.10.2026 (Wunsch: „Mit Kontext kopiert – das, was ich gesprochen habe, war gar nicht drin“): Aufnahme 131 s mit
/// Mikrofon, „Kopieren“ um 18:43:17 → Video + Pfad sofort in der Zwischenablage, der Kontext (29 Sätze, 2,9 s) ersetzte
/// es erst um 18:43:19. Eingefügt war da schon (Claude-Code-Verlauf: 18:43:19 nur der Pfad). Der Hinweis
/// „Bilder/Transkript kommen gleich dazu …“ reicht nicht – wer sofort ⌘V drückt, bekommt den halben Inhalt.
///
/// Jetzt: Die Datei liegt sofort drin (Finder, Chats), der TEXT ist ein Versprechen (NSPasteboardItemDataProvider).
/// Fragt eine App beim Einfügen nach dem Text, wartet Flow, bis der Kontext fertig ist, und liefert Pfad + Kontext.
/// Gemessen: macOS wartet auf ein Versprechen mindestens 30 s (Test 2 / 11 / 30 s je vollständig geliefert); Flow
/// wartet höchstens `waitLimit` und liefert dann den Pfad mit einem Satz, warum der Kontext fehlt.
///
/// Fallen:
/// - Der Kontext wird auf einem Hintergrund-Faden fertig und hier unter einer Sperre abgelegt (`finish`) – das Warten
///   braucht den Hauptfaden also nicht (ein Einfügen aus Flow selbst kann aus einem Main-Queue-Block kommen).
/// - Flows eigene Sicherungen der Zwischenablage (Diktat einfügen, Befehlsmodus) dürfen das Versprechen nicht abwarten:
///   `snapshotMarker` merkt nur „Versprechen lag hier“, `restore` schreibt es danach neu.
/// - Solange eine App gerade beliefert wird, darf niemand die Zwischenablage neu schreiben (`isProviding`).
final class ScreenRecClip: NSObject, NSPasteboardItemDataProvider {
    /// Länger wartet das Einfügen nie (Kontext für 10 min Video braucht ~10 s)
    static var waitLimit: TimeInterval = 25
    /// Marker in einer Zwischenablage-Sicherung (wird nie wirklich geschrieben)
    static let markerType = NSPasteboard.PasteboardType("app.flowdictation.flow.screenrec-promise")

    private static let lock = NSLock()
    /// fertige Kontexte je Video-Pfad (nil-Wert = fertig, aber ohne Text, z. B. Datei kaputt)
    private static var finished: [String: String?] = [:]
    private static var live: [String: ScreenRecClip] = [:]

    let url: URL
    let pasteboard: NSPasteboard
    /// Zählerstand der Zwischenablage nach unserem letzten Schreiben
    private(set) var changeCount = -1
    /// Text wurde schon einer App geliefert (steht jetzt fest in der Zwischenablage)
    private(set) var delivered = false
    private(set) var isProviding = false
    /// Einfügen wartet gerade auf den Kontext (für einen Hinweis an der Pille)
    var onWait: (() -> Void)?

    init(url: URL, pasteboard: NSPasteboard = .general) {
        self.url = url; self.pasteboard = pasteboard
    }

    // MARK: Kontext fertig (beliebiger Faden)

    static func finish(_ url: URL, context: String?) {
        lock.lock(); finished[url.path] = .some(context); lock.unlock()
    }

    /// (fertig?, Kontext)
    private func state() -> (Bool, String?) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let v = Self.finished[url.path] else { return (false, nil) }
        return (true, v)
    }

    // MARK: Schreiben (Hauptfaden)

    /// Video sofort + Text als Versprechen
    @discardableResult
    func write() -> Int {
        let it = NSPasteboardItem()
        it.setString(url.absoluteString, forType: .fileURL)
        it.setString("Bildschirmaufnahme", forType: Inserter.clipVaultSource)
        it.setDataProvider(self, forTypes: [.string])
        FlowPasteboard.noteOwnWrite()
        pasteboard.clearContents()
        pasteboard.writeObjects([it])
        changeCount = pasteboard.changeCount
        delivered = false
        Self.lock.lock(); Self.live[pasteboard.name.rawValue] = self; Self.lock.unlock()
        return changeCount
    }

    /// Liegt unser Versprechen noch unerfüllt in der Zwischenablage?
    var isPending: Bool { pasteboard.changeCount == changeCount && !delivered }

    static func pending(on pb: NSPasteboard) -> ScreenRecClip? {
        lock.lock(); let c = live[pb.name.rawValue]; lock.unlock()
        guard let c, c.isPending else { return nil }
        return c
    }

    // MARK: Sicherung der Zwischenablage (Diktat, Befehlsmodus) – Versprechen nicht abwarten

    /// Statt die Daten zu lesen (das würde auf den Kontext warten): nur merken, dass hier das Versprechen lag
    static func snapshotMarker(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]]? {
        guard let c = pending(on: pb) else { return nil }
        return [[markerType: Data(c.url.path.utf8)]]
    }

    /// Sicherung mit Marker zurücklegen = Versprechen neu schreiben. true = erledigt.
    static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], into pb: NSPasteboard) -> Bool {
        guard items.count == 1, let d = items[0][markerType], let path = String(data: d, encoding: .utf8) else { return false }
        lock.lock(); let c = live[pb.name.rawValue]; lock.unlock()
        let clip = (c?.url.path == path) ? c! : ScreenRecClip(url: URL(fileURLWithPath: path), pasteboard: pb)
        clip.write()
        return true
    }

    // MARK: Text, wie er eingefügt wird

    /// 26.10.2026 (Aufnahme aus dem ClipVault-Verlauf kopiert → der Kontext fehlte): der fertige
    /// Kontext liegt zusätzlich neben den Bildern als „<Video> – Bilder/Kontext.txt“. ClipVault hängt ihn beim Kopieren
    /// der Video-Datei an den Text (multiselect.swift, `MultiCopy.recordingContext`).
    static func contextFile(for url: URL) -> URL {
        URL(fileURLWithPath: url.deletingPathExtension().path + " – Bilder", isDirectory: true).appendingPathComponent("Kontext.txt")
    }

    static func saveContext(_ url: URL, _ text: String) {
        guard !text.isEmpty else { return }
        let f = contextFile(for: url)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try text.write(to: f, atomically: true, encoding: .utf8) } catch { log("Bildschirmaufnahme: Kontext nicht gespeichert (\(error.localizedDescription))") }
    }

    static func text(_ url: URL, context: String?) -> String {
        var t = CVPickSet.shellEscape(url.path)
        if let c = context, !c.isEmpty { t += "\n\n" + c }
        return t
    }

    // MARK: NSPasteboardItemDataProvider

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        isProviding = true
        defer { isProviding = false }
        let t0 = Date()
        var (done, ctx) = state()
        if !done { onWait?() }
        // Verschachtelte Runloop statt Semaphor: Pille, Karten und Zeitgeber laufen weiter
        while !done && Date().timeIntervalSince(t0) < Self.waitLimit {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            (done, ctx) = state()
        }
        var text = Self.text(url, context: ctx)
        if !done {
            text += "\n\n(Transkript und Bilder waren nach \(Int(Self.waitLimit)) s noch nicht fertig – das Video liegt unter dem Pfad oben.)"
        }
        item.setString(text, forType: type)
        delivered = true
        let waited = Date().timeIntervalSince(t0)
        log("Bildschirmaufnahme: Text beim Einfügen geliefert\(waited > 0.05 ? String(format: " – %.1f s auf den Kontext gewartet", waited) : "")"
            + (done ? (ctx?.isEmpty == false ? "" : " (ohne Kontext)") : " – Kontext NICHT fertig"))
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Self.lock.lock()
        if Self.live[pasteboard.name.rawValue] === self { Self.live[pasteboard.name.rawValue] = nil }
        Self.lock.unlock()
    }
}
