import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Ablegen: Datei-URLs UND Datei-Versprechen (File Promises)
//
// Finder, Musik, QuickTime liefern Datei-URLs. Sprachmemos, Mail-Anhänge, Fotos und manche Catalyst-Apps (WhatsApp)
// liefern dagegen ein „Versprechen“ (NSFilePromiseProvider): die Datei existiert erst, wenn der Empfänger sie anfordert.
// Sprachmemos verspricht z. B. „New Recording 69.qta“ (QuickTime-Audio, com.apple.quicktime-audio).
// Versprochene Dateien landen in ~/.config/flow/abgelegt/<zufall>/ und wandern nach der Auswertung in den Notiz-Ordner
// (werden also mit der Notiz nach der Frist gelöscht). Echte Datei-URLs werden weiter nur referenziert.

enum AudioDropReader {
    static var promiseRoot: URL { Paths.base.appendingPathComponent("abgelegt", isDirectory: true) }

    /// Liegt `path` in `dir`? (vergleicht standardisierte Pfade – /private/tmp ↔ /tmp)
    static func isInside(_ path: String, _ dir: URL) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let d = dir.standardizedFileURL.path
        return p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }
    private static let queue: OperationQueue = {
        let q = OperationQueue(); q.name = "flow.audioimport.promises"; q.qualityOfService = .userInitiated
        return q
    }()

    /// Typen fürs Registrieren (AppKit)
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Was liegt im Zug? (für Hervorhebung/Annahme – liest noch keine Datei)
    struct Peek { var urls: [URL]; var promises: [NSFilePromiseReceiver]; var promiseTypes: [String] }

    static func peek(_ pb: NSPasteboard) -> Peek {
        let urls = ((pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
            .filter { u in
                var d: ObjCBool = false
                return AudioImportFormats.accepts(u) || (FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue)
            }
        let promises = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        return Peek(urls: urls, promises: promises, promiseTypes: promises.flatMap(\.fileTypes))
    }

    /// Versprochener Dateityp brauchbar? Unbekannter/fehlender Typ → großzügig annehmen (wird nach dem Empfang geprüft).
    static func promiseTypeOK(_ t: String) -> Bool {
        if let u = UTType(t) {
            if u.conforms(to: .audio) || u.conforms(to: .movie) || u.conforms(to: .audiovisualContent) { return true }
            if u.isDynamic { return true }
            return false
        }
        if let u = UTType(filenameExtension: t) { return u.conforms(to: .audiovisualContent) }
        return true
    }

    static func canAccept(_ pb: NSPasteboard) -> Bool {
        let p = peek(pb)
        if !p.urls.isEmpty { return true }
        guard !p.promises.isEmpty else { return false }
        return p.promiseTypes.isEmpty || p.promiseTypes.contains(where: promiseTypeOK)
    }

    /// Dateien holen: URLs sofort, Versprechen in einen eigenen Ordner (höchstens 120 s warten). Ergebnis auf dem Hauptthread.
    static func receive(_ pb: NSPasteboard, completion: @escaping (_ urls: [URL], _ promised: [URL]) -> Void) {
        let p = peek(pb)
        guard !p.promises.isEmpty else { completion(p.urls, []); return }
        let dir = promiseRoot.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let group = DispatchGroup()
        let lock = NSLock()
        var got: [URL] = []
        for r in p.promises {
            let n = max(1, r.fileTypes.count)
            for _ in 0..<n { group.enter() }
            var left = n
            r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                lock.lock()
                if error == nil { got.append(url) } else { log("Datei-Versprechen fehlgeschlagen: \(error!.localizedDescription)") }
                let leave = left > 0
                left -= 1
                lock.unlock()
                if leave { group.leave() }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if group.wait(timeout: .now() + 120) == .timedOut { log("Datei-Versprechen: Zeitüberschreitung (120 s)") }
            lock.lock(); let files = got; lock.unlock()
            for f in files { chmod(f.path, 0o600) }
            let ok = files.filter { AudioImportFormats.accepts($0) }
            // Nicht brauchbare versprochene Dateien (z. B. PDF-Anhang) gleich wieder weg
            for f in files where !ok.contains(f) { try? FileManager.default.removeItem(at: f) }
            if ok.isEmpty { try? FileManager.default.removeItem(at: dir) }
            DispatchQueue.main.async { completion(p.urls, ok) }
        }
    }

    /// Verwaiste Ablage-Ordner (kein Auftrag verweist darauf) aufräumen
    static func cleanupOrphans() {
        let fm = FileManager.default
        let used = Set(AudioImportFiles.allJobs().map { URL(fileURLWithPath: $0.source).deletingLastPathComponent().standardizedFileURL.path })
        for d in (try? fm.contentsOfDirectory(at: promiseRoot, includingPropertiesForKeys: nil)) ?? []
        where !used.contains(d.standardizedFileURL.path) {
            try? fm.removeItem(at: d)
        }
    }
}

extension AudioImport {
    /// Einheitlicher Weg für jede Ablage (Pille, Hub, Karte): URLs + Versprechen → transkribieren
    func acceptDrop(_ pb: NSPasteboard, origin: AudioImportOrigin = .drop, openNotetaker: Bool) -> Bool {
        guard AudioDropReader.canAccept(pb) else { return false }
        AudioDropReader.receive(pb) { [weak self] urls, promised in
            guard let self else { return }
            var ids = self.open(urls, origin: origin)
            ids += self.open(promised, origin: origin, ownedCopies: true)
            if promised.isEmpty && urls.isEmpty {
                self.reportError(file: "Abgelegte Datei", "Die App hat keine Audiodatei geliefert. Sichere die Aufnahme zuerst (z. B. in Sprachmemos: Teilen → In Dateien sichern) und zieh dann die Datei hierher.")
            }
            if !ids.isEmpty, openNotetaker, self.appMode { VFHub.shared.go(.notetaker) }
        }
        return true
    }
}

// MARK: - SwiftUI-Ablage (Hub-Fenster + Karte) mit Versprechen

struct AudioImportDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    var openNotetaker = true

    func validateDrop(info: DropInfo) -> Bool { AudioDropReader.canAccept(NSPasteboard(name: .drag)) }
    func dropEntered(info: DropInfo) { targeted = AudioDropReader.canAccept(NSPasteboard(name: .drag)) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: targeted ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return AudioImport.shared.acceptDrop(NSPasteboard(name: .drag), openNotetaker: openNotetaker)
    }

    /// Typen, auf die SwiftUI überhaupt reagiert (Rest filtert validateDrop)
    static let types: [UTType] = [.fileURL, .audio, .movie, .audiovisualContent, .item,
                                  UTType("com.apple.NSFilePromiseItemMetaData") ?? .item]
}
