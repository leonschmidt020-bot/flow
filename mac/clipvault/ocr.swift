// ClipVault — Texterkennung (OCR) fuer Bild-Eintraege
// Vision (VNRecognizeTextRequest, Deutsch + Englisch). Laeuft in einem KURZLEBIGEN Kindprozess
// (`clipvault ocr-file <bild>`): Vision laedt seine Modelle (~100 MB) in den Prozess und gibt sie
// nicht zuverlaessig wieder frei. So bleibt die Dauer-App schlank (RAM-Regel), und ein Absturz
// in Vision reisst ClipVault nicht mit.
import Cocoa
import Vision

/// Text aus einem Bild lesen (wird im Kindprozess aufgerufen). nil = Bild nicht lesbar.
func recognizeText(at url: URL) -> String? {
    // ImageIO statt NSImage: dekodiert direkt auf hoechstens 4096 px (riesige Bilder sprengen sonst den RAM)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts(4096)) else { return nil }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = ["de-DE", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([req]) } catch { return nil }
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
}

final class OCR {
    static let shared = OCR()
    static let doneNote = Notification.Name("ClipVaultOCRDone")   // lokal (object = Eintrags-id)
    private let q = DispatchQueue(label: "app.flowdictation.clipvault.ocr", qos: .utility)
    private var queued = Set<String>()     // nur Main-Thread
    private var failed = Set<String>()     // diese Sitzung nicht erneut automatisch versuchen

    func isBusy(_ id: String) -> Bool { queued.contains(id) }

    /// Eintrag zur Erkennung einreihen. force = auch wenn schon erkannt (Befehl `ocr`, Menue „erneut erkennen").
    func enqueue(_ it: ClipItem, force: Bool = false) {
        guard !CV_READ_ONLY, it.kind == .image, let url = Store.shared.imageURL(it) else { return }
        if !force && (it.ocrText != nil || failed.contains(it.id)) { return }
        if queued.contains(it.id) { return }
        queued.insert(it.id)
        let id = it.id
        q.async {
            let text = OCR.runChild(url.path)
            DispatchQueue.main.async {
                self.queued.remove(id)
                if let text = text {
                    Store.shared.setOCR(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    self.failed.insert(id); cvLog("OCR fehlgeschlagen: \(url.lastPathComponent)")
                }
                NotificationCenter.default.post(name: OCR.doneNote, object: id)
            }
        }
    }

    /// Alle Bilder ohne erkannten Text nacheinander abarbeiten (niedrige Prioritaet, einer nach dem anderen)
    func backfill() {
        let todo = Store.shared.items.filter { $0.kind == .image && $0.ocrText == nil }
        if !todo.isEmpty { cvLog("OCR: \(todo.count) Bilder werden im Hintergrund gelesen") }
        for it in todo { enqueue(it) }
    }

    /// Eigene Binary als Kindprozess starten: `clipvault ocr-file <pfad>` -> Text auf stdout
    static func runChild(_ path: String) -> String? {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let p = Process()
        p.executableURL = exe
        p.arguments = ["ocr-file", path]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Notbremse: haengt Vision, nach 45 s beenden
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
