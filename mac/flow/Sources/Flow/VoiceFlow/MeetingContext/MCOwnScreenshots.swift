import Foundation
import ImageIO

// MARK: - Eigene Screenshots aus dem Meeting-Zeitraum (nur LESEN)
//
// Zeitfenster: Meeting-Beginn − 2 Min. … Ende + 10 Min.
// Quellen:
//   1. Screenshot-Ordner: `defaults read com.apple.screencapture location`, ~/Desktop/Screenshots (+ Behalten/), ~/Desktop –
//      nur Bilddateien, die nach Screenshot aussehen (Bildschirmfoto/Screenshot/… oder Datum im Namen).
//   2. ClipVault-Verlauf (~/.config/flow-clipvault/index.json): Bild-Einträge im Zeitfenster, NICHT aus Geheim-Bereichen.
//      Doppelte (Screenshot, den der Screenshot-Helfer zusätzlich in ClipVault legt) fallen weg: gleiche Größe, ±5 s.
// Tests: MC_SCREENSHOT_DIRS=<ordner1>:<ordner2> ersetzt die Ordner, CLIPVAULT_HOME den ClipVault-Ordner.

struct MCOwnShot: Equatable {
    enum Source: String { case screenshot = "Eigener Screenshot", clipvault = "Aus ClipVault" }
    let url: URL
    let date: Date
    let source: Source
    var ocr: String?
    let width: Int
    let height: Int
}

enum MCOwnScreenshots {
    static let before: TimeInterval = 120
    static let after: TimeInterval = 600

    static func window(_ m: Meeting) -> (Date, Date) {
        let end = m.status == .recording ? Date() : m.date.addingTimeInterval(max(m.duration, 0))
        return (m.date.addingTimeInterval(-before), end.addingTimeInterval(after))
    }

    static func dirs() -> [URL] {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["MC_SCREENSHOT_DIRS"], !env.isEmpty {
            return env.split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath, isDirectory: true) }
        }
        let home = fm.homeDirectoryForCurrentUser
        var out: [URL] = []
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            out.append(URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true))
        }
        let shots = home.appendingPathComponent("Desktop/Screenshots", isDirectory: true)
        out += [shots, shots.appendingPathComponent("Behalten", isDirectory: true), home.appendingPathComponent("Desktop", isDirectory: true)]
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted && fm.fileExists(atPath: $0.path) }
    }

    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    static func looksLikeScreenshot(_ name: String) -> Bool {
        let l = name.lowercased()
        if ["bildschirmfoto", "screenshot", "screen shot", "capture", "captura", "schermata", "cleanshot"].contains(where: { l.contains($0) }) { return true }
        return l.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    static func pixelSize(_ u: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    /// Alle eigenen Screenshots/Bilder im Zeitfenster, zeitlich sortiert
    static func collect(for m: Meeting) -> [MCOwnShot] {
        let (a, b) = window(m)
        return collect(from: a, to: b)
    }

    static func collect(from a: Date, to b: Date) -> [MCOwnShot] {
        let fm = FileManager.default
        var out: [MCOwnShot] = []
        for d in dirs() {
            let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
            for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [] {
                guard imageExt.contains(u.pathExtension.lowercased()), looksLikeScreenshot(u.lastPathComponent),
                      let rv = try? u.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
                let date = rv.creationDate ?? rv.contentModificationDate ?? .distantPast
                guard date >= a, date <= b else { continue }
                let (w, h) = pixelSize(u)
                out.append(MCOwnShot(url: u, date: date, source: .screenshot, ocr: nil, width: w, height: h))
            }
        }
        // ClipVault-Bilder (nur lesen)
        let base = ClipVaultClient.base
        let secret = Set((ClipVaultClient.decodeCollections(base.appendingPathComponent("collections.json")) ?? []).filter(\.isSecret).map(\.id))
        for it in ClipVaultClient.decodeItems(base.appendingPathComponent("index.json")) ?? [] {
            guard it.rawKind == "image", let img = it.image, it.date >= a, it.date <= b,
                  !(it.collection.map { secret.contains($0) } ?? false) else { continue }
            let u = base.appendingPathComponent(img)
            guard fm.fileExists(atPath: u.path) else { continue }
            let (w, h) = pixelSize(u)
            let dup = out.contains { $0.source == .screenshot && abs($0.date.timeIntervalSince(it.date)) <= 5 && $0.width == w && $0.height == h }
            if dup { continue }
            out.append(MCOwnShot(url: u, date: it.date, source: .clipvault, ocr: it.ocr, width: w, height: h))
        }
        return out.sorted { $0.date < $1.date }
    }
}
