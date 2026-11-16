import AppKit
import AVFoundation

/// „Als MP3“ (16.11.2026): nur der Ton einer Bildschirmaufnahme als Datei in „Downloads“.
/// MP3 mit ffmpeg aus Homebrew (macOS selbst kann kein MP3 schreiben); ohne ffmpeg als M4A (AAC) – spielt überall.
/// Das Video bleibt unverändert. Die Tondatei liegt danach auch in der Zwischenablage (⌘V) und wird im Finder gezeigt.
enum ScreenRecAudio {
    /// Freier Dateiname: „x.mp3“, sonst „x 2.mp3“, „x 3.mp3“ … (nie überschreiben)
    static func freeURL(dir: URL, base: String, ext: String) -> URL {
        var u = dir.appendingPathComponent("\(base).\(ext)"); var i = 2
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(base) \(i).\(ext)"); i += 1 }
        return u
    }

    static func saveToDownloads(video: URL) {
        let toast: (String, Double) -> Void = { t, s in DispatchQueue.main.async { ScreenRec.shared.pill?.view.showToast(t, seconds: s) } }
        toast("Ton wird als MP3 gespeichert …", 2.5)
        Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let base = video.deletingPathExtension().lastPathComponent
            let t0 = Date()
            guard let tracks = try? await AVURLAsset(url: video).loadTracks(withMediaType: .audio), !tracks.isEmpty else {
                log("Bildschirmaufnahme → MP3: keine Tonspur in \(video.lastPathComponent)")
                toast("Die Aufnahme hat keinen Ton – nichts gespeichert", 3); return
            }
            var out: URL?
            if let ff = AudioImportFormats.ffmpeg {
                let u = freeURL(dir: dir, base: base, ext: "mp3")
                if mp3(ffmpeg: ff, video: video, to: u) { out = u } else { try? FileManager.default.removeItem(at: u) }
            }
            if out == nil {
                let u = freeURL(dir: dir, base: base, ext: "m4a")
                if await m4a(video: video, to: u) { out = u }
            }
            guard let out else {
                log("Bildschirmaufnahme → MP3: Umwandeln gescheitert (\(video.lastPathComponent))")
                toast("Ton ließ sich nicht speichern", 3); return
            }
            let size = ((try? out.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1000
            log("Bildschirmaufnahme → Ton: \(out.lastPathComponent) in Downloads, \(size) KB, \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            await MainActor.run {
                let it = NSPasteboardItem()
                it.setString(out.absoluteString, forType: .fileURL)
                it.setString(CVPickSet.shellEscape(out.path), forType: .string)
                FlowPasteboard.noteOwnWrite()
                let pb = NSPasteboard.general
                pb.clearContents(); pb.writeObjects([it])
                ScreenRec.shared.pill?.view.showToast(out.pathExtension == "mp3" ? "MP3 liegt in Downloads – auch kopiert (⌘V)"
                                                      : "Ton als M4A in Downloads (für MP3 fehlt ffmpeg)", seconds: 3)
                NSWorkspace.shared.activateFileViewerSelecting([out])
            }
        }
    }

    /// Alle Tonspuren zusammen (Systemton, ggf. Mikro), 192 kbit/s
    private static func mp3(ffmpeg: String, video: URL, to out: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-loglevel", "error", "-n", "-i", video.path, "-vn", "-c:a", "libmp3lame", "-b:a", "192k", out.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let size = (try? out.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return p.terminationStatus == 0 && size > 0
    }

    private static func m4a(video: URL, to out: URL) async -> Bool {
        guard let ex = AVAssetExportSession(asset: AVURLAsset(url: video), presetName: AVAssetExportPresetAppleM4A) else { return false }
        ex.outputURL = out; ex.outputFileType = .m4a
        await ex.export()
        return ex.status == .completed
    }
}
