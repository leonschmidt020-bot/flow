// ClipVault — dasselbe Bild nur EINMAL im Verlauf (27.09.2026)
//
// Warum: Jeder Screenshot landete doppelt, etwa 1 s (oder beim späten Klick bis ~1 min) auseinander:
//   1. Hammerspoon legt die Screenshot-Datei per `clipvault add` in den Verlauf (Original-PNG mit XMP-Metadaten),
//   2. der Kopieren-Knopf der Vorschau legt dasselbe Bild in die Zwischenablage -> ClipVault nimmt es dort NOCHMAL auf.
// Die Pixel sind identisch, die Bytes nicht (die Zwischenablage-Fassung hat keine iTXt/eXIf-Metadaten mehr) —
// ein Byte-Vergleich findet das nie.
//
// Lösung: ein Bild-Fingerabdruck (Pixelmaße + 16×16 Graustufen) als schneller Vorfilter, danach eine Feinprüfung
// auf 256 px (kein Pixel darf merklich abweichen). So werden echte Doppel zusammengeführt, aber zwei ABSICHTLICH
// kurz nacheinander gemachte Screenshots mit kleiner Änderung (ein getipptes Zeichen, ein Cursor) bleiben getrennt.
import Cocoa
import ImageIO

struct ImagePrint {
    let w: Int, h: Int
    let gray: [UInt8]          // 16×16 Graustufen
    static let side = 16

    static func make(data: Data) -> ImagePrint? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { make(src: $0) }
    }
    static func make(url: URL) -> ImagePrint? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { make(src: $0) }
    }
    static func make(src: CGImageSource) -> ImagePrint? {
        guard let (w, h) = pixelSize(src), let g = grayPixels(src, maxPx: 64, outW: side, outH: side) else { return nil }
        return ImagePrint(w: w, h: h, gray: g)
    }
    /// Gleiche Maße und im Mittel höchstens ~1 % Helligkeitsunterschied (Farbprofil-Rundungen erlaubt)
    func roughlyMatches(_ o: ImagePrint) -> Bool {
        guard w == o.w, h == o.h, gray.count == o.gray.count else { return false }
        var sum = 0, mx = 0
        for i in 0..<gray.count { let d = abs(Int(gray[i]) - Int(o.gray[i])); sum += d; mx = max(mx, d) }
        return Double(sum) / Double(gray.count) <= 2.5 && mx <= 16
    }
}

/// Pixelmaße (ohne das Bild zu dekodieren)
func pixelSize(_ src: CGImageSource) -> (Int, Int)? {
    guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
    let o = (p[kCGImagePropertyOrientation] as? Int) ?? 1
    return o >= 5 ? (h, w) : (w, h)   // gedrehte Fotos: Maße so, wie sie angezeigt werden
}

/// Bild klein dekodieren (ImageIO, nie das Vollbild im RAM) und in ein festes Graustufen-Raster zeichnen.
/// Fester Farbraum -> Zwischenablage-TIFF und Original-PNG landen trotz anderer Farbprofile auf denselben Werten.
func grayPixels(_ src: CGImageSource, maxPx: CGFloat, outW: Int, outH: Int) -> [UInt8]? {
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts(maxPx)),
          let cs = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
          let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW,
                              space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))   // Transparenz = weiß
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
    guard let p = ctx.data else { return nil }
    return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: outW * outH))
}

/// Feinprüfung auf 256 px lange Kante: KEIN Pixel darf mehr als 12 Stufen abweichen.
/// (Ein getipptes Zeichen oder ein Mauszeiger in einem 2K-Screenshot ergibt hier 30–100 Stufen -> bleibt getrennt.)
func imagesLookSame(_ a: CGImageSource, _ b: CGImageSource, w: Int, h: Int) -> Bool {
    let long = 256.0, s = long / Double(max(w, h))
    let fw = max(1, Int((Double(w) * s).rounded())), fh = max(1, Int((Double(h) * s).rounded()))
    guard let pa = grayPixels(a, maxPx: CGFloat(long), outW: fw, outH: fh),
          let pb = grayPixels(b, maxPx: CGFloat(long), outW: fw, outH: fh) else { return false }
    for i in 0..<pa.count where abs(Int(pa[i]) - Int(pb[i])) > 12 { return false }
    return true
}

extension Store {
    /// So lange nach dem letzten Benutzen gilt ein gleiches Bild als Doppel. Belegt aus Lenas Verlauf:
    /// meist ~1 s, aber wer die Vorschau-Blase erst später klickt, kopiert 40–50 s danach.
    static let imageTwinWindow: TimeInterval = 180
    /// Nur für den Selbsttest (`clipvault doppelt-test`): alten Ablauf ohne Abgleich nachstellen
    static var imageDedupe = true

    /// Liegt dasselbe Bild schon (kürzlich benutzt) im Verlauf?
    func recentImageTwin(data: Data, print fp: ImagePrint) -> ClipItem? {
        guard Store.imageDedupe, let newSrc = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let now = Date()
        for it in items where it.kind == .image && now.timeIntervalSince(it.date) <= Store.imageTwinWindow {
            guard let url = imageURL(it) else { continue }
            if it.imagePrint == nil { it.imagePrint = ImagePrint.make(url: url) }
            guard let p = it.imagePrint, p.roughlyMatches(fp),
                  let oldSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
                  imagesLookSame(newSrc, oldSrc, w: fp.w, h: fp.h) else { continue }
            return it
        }
        return nil
    }

    /// Doppel zusammenführen: der vorhandene Eintrag bleibt (id, erkannter Text, Anheften, Bereich, Teilen),
    /// wandert nach oben und bekommt — falls die neue Fassung "reicher" ist (Original-Datei bekannt) — deren Bytes.
    func mergeImageTwin(_ it: ClipItem, data: Data, print fp: ImagePrint, source: String?, origin: String?) {
        if origin != nil && it.origin == nil && !it.shared, let url = imageURL(it) {
            // Gleicher Dateiname, atomar ersetzt: eine laufende Texterkennung liest entweder die alte oder die neue
            // Fassung — beide haben dieselben Pixel. Keine verwaisten Dateien.
            if (try? data.write(to: url, options: .atomic)) != nil {
                it.thumb = loadThumb(data: data); it.bigThumb = nil; it.imagePrint = fp
            }
        }
        if it.origin == nil { it.origin = origin }
        if it.source == nil { it.source = source }
        moveToTop(it)                      // setzt „zuletzt benutzt" = jetzt und speichert
        if prune() { persist() }
        cvLog("Bild doppelt — mit vorhandenem Eintrag zusammengefuehrt (\(fp.w)x\(fp.h), \(origin != nil ? "Datei" : "Zwischenablage"))")
    }
}
