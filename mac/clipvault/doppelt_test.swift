// ClipVault — Selbsttest „Screenshot landet doppelt" (27.09.2026)
//   CLIPVAULT_HOME=/tmp/cv-test clipvault doppelt-test [--ohne-abgleich]
// Laeuft NUR gegen einen Test-Ordner. Die allgemeine Zwischenablage wird nie gelesen oder beschrieben:
// der Kopieren-Knopf wird mit einer EIGENEN, benannten Zwischenablage nachgestellt.
// Die Testbilder werden hier gezeichnet (kein privates Material).
import Cocoa
import ImageIO
import UniformTypeIdentifiers

func runDoppeltTest(_ args: [String]) -> Never {
    guard CV_HOME_OVERRIDE != nil else {
        print("Nur mit CLIPVAULT_HOME=<Testordner> — der Test laeuft nie gegen den echten Verlauf."); exit(2)
    }
    CV_HEADLESS = true
    let appT = NSApplication.shared; appT.setActivationPolicy(.prohibited)
    if args.contains("--ohne-abgleich") { Store.imageDedupe = false }
    let st = Store.shared, state = AppState.shared
    let work = URL(fileURLWithPath: CV_DIR + "testbilder", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    var failures = 0

    func spin(_ secs: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(secs)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    // Screenshot-aehnliches Bild zeichnen: Fenster, Leisten, Text. extra = ein zusaetzliches Zeichen (wie getippt)
    func drawShot(seed: Int, extra: String = "", w: Int = 2048, h: Int = 1152, space: CGColorSpace) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        NSColor(calibratedHue: CGFloat(seed % 7) / 7, saturation: 0.25, brightness: 0.92, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 160, y: 120, width: w - 320, height: h - 240), xRadius: 18, yRadius: 18).fill()
        NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 160, y: h - 180, width: w - 320, height: 60).fill()
        let font = NSFont.systemFont(ofSize: 34)
        for i in 0..<14 {
            let line = "Zeile \(i + 1) · Testbild \(seed) · Screenshot-Doppel-Pruefung \(String(repeating: "abc ", count: (seed + i) % 9))"
            (line as NSString).draw(at: NSPoint(x: 220, y: h - 260 - i * 52), withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)])
        }
        if !extra.isEmpty {
            (("Eingabe: " + extra) as NSString).draw(at: NSPoint(x: 220, y: 170), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        } else {
            ("Eingabe: " as NSString).draw(at: NSPoint(x: 220, y: 170), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!, srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    // "Screenshot-Datei": PNG mit Metadaten (wie macOS: Beschreibung/XMP) und P3-Profil
    func writeShotFile(_ img: CGImage, _ name: String) -> String {
        let url = work.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "Screenshot", kCGImagePropertyPNGSoftware: "Test"]] as CFDictionary)
        CGImageDestinationFinalize(d)
        return url.path
    }
    // "Kopieren-Knopf": nur TIFF in einer eigenen Zwischenablage (so legt Hammerspoon hs.image ab)
    func pasteboardWith(_ img: CGImage, convertTo: CGColorSpace? = nil) -> NSPasteboard {
        var cg = img
        if let cs = convertTo, let c = img.copy(colorSpace: cs) {
            // echte Farbumrechnung: in einen Kontext des Zielraums zeichnen
            let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height)); cg = ctx.makeImage() ?? c
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("app.flowdictation.clipvault.test." + UUID().uuidString))
        pb.clearContents()
        pb.setData(NSBitmapImageRep(cgImage: cg).tiffRepresentation!, forType: .tiff)
        return pb
    }
    // wie `clipvault add` + Hammerspoon: Kopie nach incoming/, dann ingest
    func ingestFile(_ path: String) {
        let before = Store.shared.items.first.map { "\($0.id)\($0.date.timeIntervalSince1970)" }
        let d = URL(fileURLWithPath: CV_DIR + "incoming/" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let dest = d.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try? FileManager.default.copyItem(atPath: path, toPath: dest.path)
        state.ingest(path: dest.path, original: path)
        spin(5) { Store.shared.items.first.map { "\($0.id)\($0.date.timeIntervalSince1970)" } != before }
    }
    func images() -> [ClipItem] { st.items.filter { $0.kind == .image } }
    func check(_ name: String, _ want: Int, _ got: Int, _ note: String = "") {
        let ok = want == got
        if !ok { failures += 1 }
        print("\(ok ? "OK    " : "FEHLER")  \(name): \(got) Eintrag/Eintraege (erwartet \(want))\(note.isEmpty ? "" : " — " + note)")
    }
    print("ClipVault Doppel-Test \(Store.imageDedupe ? "(mit Abgleich)" : "(OHNE Abgleich = alter Ablauf)") · Testordner \(CV_DIR)")

    // 1) Datei zuerst, 1 s spaeter der Kopieren-Knopf
    var n0 = images().count
    let a = drawShot(seed: 1, space: p3); let aPath = writeShotFile(a, "Bildschirmfoto A.png")
    ingestFile(aPath)
    let aId = st.items.first?.id
    spin(12) { st.item(aId ?? "")?.ocrText != nil }       // Texterkennung abwarten, damit man sieht: sie bleibt
    let ocrBefore = st.item(aId ?? "")?.ocrText
    spin(1)
    state.capture(nil, from: pasteboardWith(a))
    var top = st.items.first
    check("1 Datei, dann Kopieren-Knopf", 1, images().count - n0,
          "gleiche id: \(top?.id == aId), Original: \(top?.origin != nil), Text erhalten: \(ocrBefore != nil && top?.ocrText == ocrBefore)")

    // 2) Kopieren-Knopf zuerst (z. B. ⌃⇧⌘4), dann kommt die Datei -> reichere Fassung (Datei) gewinnt
    n0 = images().count
    let b = drawShot(seed: 2, space: p3); let bPath = writeShotFile(b, "Bildschirmfoto B.png")
    state.capture(nil, from: pasteboardWith(b))
    let bId = st.items.first?.id
    spin(1); ingestFile(bPath)
    top = st.items.first
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: bPath)[.size] as? Int) ?? -1
    let keptSize = top.flatMap { st.dataFor($0)?.count } ?? -2
    check("2 Kopieren-Knopf, dann Datei", 1, images().count - n0,
          "gleiche id: \(top?.id == bId), Original: \(top?.origin != nil), Bytes = Datei: \(keptSize == fileSize)")

    // 3) Zwischenablage in anderem Farbprofil (sRGB statt P3) -> Pixelwerte weichen leicht ab, trotzdem dasselbe Bild
    n0 = images().count
    let c = drawShot(seed: 3, space: p3); let cPath = writeShotFile(c, "Bildschirmfoto C.png")
    ingestFile(cPath); spin(0.5)
    state.capture(nil, from: pasteboardWith(c, convertTo: srgb))
    check("3 Farbprofil umgerechnet (P3 -> sRGB)", 1, images().count - n0)

    // 4) Zwei ABSICHTLICHE Screenshots kurz nacheinander, einer mit einem getippten Zeichen -> beide bleiben
    n0 = images().count
    let d1 = drawShot(seed: 4, space: p3), d2 = drawShot(seed: 4, extra: "x", space: p3)
    ingestFile(writeShotFile(d1, "Bildschirmfoto D1.png")); spin(0.5)
    ingestFile(writeShotFile(d2, "Bildschirmfoto D2.png"))
    check("4 zweiter Screenshot mit einem getippten Zeichen", 2, images().count - n0)

    // 5) Anderes Bild in derselben Groesse
    n0 = images().count
    ingestFile(writeShotFile(drawShot(seed: 5, space: p3), "Bildschirmfoto E.png")); spin(0.3)
    state.capture(nil, from: pasteboardWith(drawShot(seed: 6, space: p3)))
    check("5 anderes Bild, gleiche Groesse", 2, images().count - n0)

    // 6) Texte: „Schick Nico" legt den Text ab, dieselbe Nachricht kommt per pbcopy mit Zeilenumbruch
    let texts = { st.items.filter { $0.kind == .text }.count }
    var t0 = texts()
    st.addText("Testnachricht fuer den Doppel-Test, bitte ignorieren", source: "Lena")
    st.addText("Testnachricht fuer den Doppel-Test, bitte ignorieren\n", source: "KI")
    check("6 Text + gleicher Text mit Zeilenumbruch", 1, texts() - t0)
    // 7) Diktat: Inserter legt Text + Quelle „Diktat" auf die Zwischenablage -> genau ein Eintrag
    t0 = texts()
    let pbD = NSPasteboard(name: NSPasteboard.Name("app.flowdictation.clipvault.test." + UUID().uuidString))
    pbD.clearContents(); pbD.setString("Diktat Testsatz fuer den Doppel-Test", forType: .string)
    pbD.setString("Diktat", forType: NSPasteboard.PasteboardType("app.flowdictation.clipvault.source"))
    state.capture(pbD.string(forType: NSPasteboard.PasteboardType("app.flowdictation.clipvault.source")), from: pbD)
    st.addText("Diktat Testsatz fuer den Doppel-Test", source: "Diktat")   // gleicher Text noch einmal (z. B. Befehl addText)
    check("7 Diktat einmal ueber Zwischenablage + einmal direkt", 1, texts() - t0)

    print(failures == 0 ? "ALLE PRUEFUNGEN BESTANDEN" : "\(failures) Pruefung(en) fehlgeschlagen")
    spin(0.5)
    exit(failures == 0 ? 0 : 1)
}
