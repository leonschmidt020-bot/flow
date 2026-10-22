import AppKit
import SwiftUI

/// Flow schreibt selbst in die Zwischenablage → kurz nichts davon als fremde Kopie werten
/// (Diktat-Einfügen + Wiederherstellen, Kopieren aus der Partner-Liste, dem Hub, Meeting-Bildern, Bildschirmaufnahme).
enum FlowPasteboard {
    private(set) static var lastOwnWrite = Date.distantPast
    static func noteOwnWrite() { lastOwnWrite = Date() }
    static let ownWindow: TimeInterval = 2
}

// MARK: - Vorschaubilder-Leiste in der Karte (bis 6, dann „+N“)

enum VFThumbs {
    static let thumbPixels = 96
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]
    static func isImageURL(_ u: URL) -> Bool { imageExtensions.contains(u.pathExtension.lowercased()) }
}

struct VFThumbStrip: View {
    let urls: [URL]
    let more: Int
    static let size: CGFloat = 36
    static let height: CGFloat = 46        // Leiste + Abstand nach oben
    /// Namenszeile(n) darunter: eine Zeile, ab ~46 Zeichen zwei
    static func captionHeight(_ c: String?) -> CGFloat { c.map { $0.count > 46 ? 34 : 19 } ?? 0 }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, u in
                ZStack {
                    Color.white.opacity(0.08)
                    if !VFThumbs.isImageURL(u) {
                        VFFileTile(url: u)
                    } else if let img = CVThumbs.shared.cached(u, VFThumbs.thumbPixels) ?? CVThumbs.make(u, maxPixel: VFThumbs.thumbPixels) {
                        Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minWidth: Self.size).frame(height: Self.size)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.10)))
            }
        }
        .padding(.top, 10)
    }
}

/// Kachel für Nicht-Bilder: Programm-Symbol + Endung (MP4, PDF …)
struct VFFileTile: View {
    let url: URL
    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 9)
            Text(url.pathExtension.isEmpty ? "DATEI" : url.pathExtension.uppercased())
                .font(.system(size: 7.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .padding(.horizontal, 3).frame(height: 10)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.bottom, 2)
        }
    }
}
