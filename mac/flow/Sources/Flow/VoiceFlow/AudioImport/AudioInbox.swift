import Foundation

// MARK: - Eingangsordner ~/Documents/Flow/Eingang
//
// Eingeschaltet in Einstellungen → Notetaker → Audiodateien (Standard: aus – erst dann fragt macOS nach „Dokumente“).
// Beim Einschalten werden Eingang/ und Eingang/Erledigt/ angelegt. Jede neue Audio-/Videodatei, die sich 2 s nicht mehr
// verändert (Kopieren/Download fertig), wird transkribiert. Danach wandert sie nach Erledigt/ (nie gelöscht);
// unlesbare Dateien nach „Nicht lesbar/“, damit sie nicht endlos neu versucht werden.

final class AudioInbox {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var timer: Timer?
    /// Pfad → (Größe, Änderungszeit, seit) – erst stabile Dateien annehmen
    private var seen: [String: (Int64, Date, Date)] = [:]
    private(set) var running = false

    var settings: AudioImportSettings { .shared }

    func apply() {
        if settings.inboxEnabled { startWatching() } else { stop() }
    }

    /// Ordner anlegen (auch ohne Beobachten, z. B. für „Im Finder zeigen“)
    @discardableResult
    func ensureFolders() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: settings.inboxURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: settings.doneURL, withIntermediateDirectories: true)
            return true
        } catch {
            log("Eingangsordner nicht anlegbar: \(error.localizedDescription)")
            return false
        }
    }

    private func startWatching() {
        guard !running else { return }
        guard ensureFolders() else {
            AudioImport.shared.reportError(file: "Eingangsordner", "Der Eingangsordner \(settings.inboxDisplay) lässt sich nicht anlegen. Erlaube Flow den Zugriff auf „Dokumente“ (Systemeinstellungen → Datenschutz → Dateien und Ordner).")
            return
        }
        running = true
        fd = open(settings.inboxURL.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
            s.setEventHandler { [weak self] in self?.scan() }
            s.setCancelHandler { [fd] in close(fd) }
            s.resume()
            source = s
        }
        // Zusätzlich alle 3 s (Größe stabil? iCloud/Netzlaufwerke melden nicht immer ein Ereignis)
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("Eingangsordner beobachtet: \(settings.inboxDisplay)")
        scan()
    }

    func stop() {
        guard running else { return }
        running = false
        source?.cancel(); source = nil; fd = -1
        timer?.invalidate(); timer = nil
        seen = [:]
        log("Eingangsordner: Beobachtung aus")
    }

    /// Einmal durchsehen: neue, stabile Dateien annehmen
    func scan(now: Date = Date()) {
        guard running else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let items = (try? fm.contentsOfDirectory(at: settings.inboxURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let busy = Set(AudioImportFiles.allJobs().filter { $0.phase.isActive || $0.phase == .queued }.map(\.source))
        var present = Set<String>()
        for u in items {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let path = u.standardizedFileURL.path
            present.insert(path)
            let ext = u.pathExtension.lowercased()
            if ["crdownload", "download", "part", "partial", "tmp", "icloud"].contains(ext) { continue }
            guard AudioImportFormats.accepts(u), !busy.contains(path) else { continue }
            let size = Int64(v.fileSize ?? 0)
            let mod = v.contentModificationDate ?? now
            if let s = seen[path], s.0 == size, s.1 == mod {
                // 2 s unverändert → annehmen
                if size > 0, now.timeIntervalSince(s.2) >= 2 {
                    seen[path] = (size, mod, .distantFuture)   // nicht doppelt annehmen
                    log("Eingangsordner: neue Datei \(u.lastPathComponent)")
                    AudioImport.shared.open([u], origin: .inbox)
                }
            } else {
                seen[path] = (size, mod, now)
            }
        }
        seen = seen.filter { present.contains($0.key) }
    }

    // MARK: Verschieben (nie löschen)

    func moveDone(_ job: AudioImportJob) { move(job, to: settings.doneURL) }

    func moveFailed(_ job: AudioImportJob) {
        try? FileManager.default.createDirectory(at: settings.failedURL, withIntermediateDirectories: true)
        move(job, to: settings.failedURL)
    }

    private func move(_ job: AudioImportJob, to dir: URL) {
        let fm = FileManager.default
        let src = job.sourceURL
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var dst = dir.appendingPathComponent(src.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) (\(n)).\(src.pathExtension)")
            n += 1
        }
        do {
            try fm.moveItem(at: src, to: dst)
            if var j = AudioImportFiles.loadJob(job.id) {
                j.source = dst.path; j.movedTo = dst.path
                AudioImportFiles.saveJob(j)
            }
            log("Eingangsordner: \(src.lastPathComponent) → \(dir.lastPathComponent)/")
        } catch {
            log("Eingangsordner: Verschieben fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}
