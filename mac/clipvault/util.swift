// ClipVault — gemeinsame Helfer (Pfade, Protokoll, KI-Erkennung, Bild-Thumbs, Formate)
import Cocoa
import Carbon.HIToolbox
import QuartzCore
import QuickLookThumbnailing
import WebKit
import CryptoKit

let ICON_PATH = NSHomeDirectory() + "/.config/flow-clipvault/icon.png"
// CLIPVAULT_HOME (nur fuer Tests): zweites "Geraet" auf demselben Mac mit eigenem Datenordner.
// Dann bekommen auch die verteilten Meldungen ein Suffix, damit sich Test und echte App nie hoeren.
let CV_HOME_OVERRIDE: String? = ProcessInfo.processInfo.environment["CLIPVAULT_HOME"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
let CV_DIR = CV_HOME_OVERRIDE.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? (NSHomeDirectory() + "/.config/flow-clipvault/")
let CV_NOTIFY_SUFFIX = CV_HOME_OVERRIDE.map { "." + String(UInt32(truncatingIfNeeded: $0.hashValueStable)) } ?? ""

extension String {
    /// stabil ueber Prozesse hinweg (Swift-hashValue ist pro Prozess zufaellig)
    var hashValueStable: UInt64 { var h: UInt64 = 1469598103934665603; for b in utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }; return h }
}

// MARK: - Protokoll (16.08.2026)
// Frueher scheiterten Dinge lautlos: ging der Hotkey nicht oder war der Verlauf kaputt,
// merkte man es erst, wenn nichts mehr ging. Jetzt schreibt ClipVault mit, was passiert —
// `clipvault doctor` liest es vor.
/// Fingerabdruck einer Datei (Inode, Groesse, Aenderungszeit) — billiger als Lesen; nil = fehlt
struct CVFileStamp: Equatable {
    let ino: UInt64, size: Int64, sec: Int, nsec: Int
    init?(_ path: String) {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        ino = UInt64(s.st_ino); size = Int64(s.st_size); sec = s.st_mtimespec.tv_sec; nsec = s.st_mtimespec.tv_nsec
    }
}

// Audit 27.09.2026: cvLog wird auch aus Hintergrund-Threads gerufen (OCR, Aufnehmen) — ohne Sperre
// konnten sich Zeilen beim Halbieren gegenseitig ueberschreiben.
private let cvLogLock = NSLock()
func cvLog(_ msg: String) {
    cvLogLock.lock(); defer { cvLogLock.unlock() }
    let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(msg)\n"
    let p = CV_DIR + "clipvault.log"
    if let h = FileHandle(forWritingAtPath: p) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        // Protokoll bei 200 KB halbieren, damit es nie volllaeuft
        if let sz = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? nil, sz > 200_000,
           let all = try? String(contentsOfFile: p, encoding: .utf8) {
            let keep = all.split(separator: "\n").suffix(400).joined(separator: "\n") + "\n"
            try? keep.write(toFile: p, atomically: true, encoding: .utf8)
        }
    } else {
        try? line.write(toFile: p, atomically: true, encoding: .utf8)
    }
}

// MARK: - KI-Erkennung (14.08.2026)
// Frueher wurde ein Eintrag NUR als "von KI" markiert, wenn er ueber `clipvault copy-ki`
// kam. Alles andere (pbcopy, Cmd+C, Kopieren-Knopf) blieb unmarkiert — deshalb erschien
// das Funkeln nur zufaellig. Jetzt zusaetzlich: welche App war beim Kopieren im Vordergrund?
// Die Liste liegt als Textdatei daneben und laesst sich ohne Neubau erweitern.
let AI_APPS_PATH = CV_DIR + "ai-apps.txt"
let AI_APPS_DEFAULT = """
# ClipVault — Apps, deren Kopien als "von KI" markiert werden.
# Eine Kennung oder ein App-Name pro Zeile. Gross/Kleinschreibung egal,
# Teiltreffer genuegt. Zeilen mit # sind Kommentare.
# Aenderungen wirken sofort, ohne Neustart.
com.anthropic
com.openai
claude
chatgpt
gemini
antigravity
perplexity
copilot
cursor

"""

func aiSourceFromFrontmostApp() -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let bundle = (app.bundleIdentifier ?? "").lowercased()
    let name = (app.localizedName ?? "").lowercased()
    // Diagnose: haelt fest, welche App zuletzt erkannt wurde — hilft beim Pflegen von ai-apps.txt
    try? "\(name)\n\(bundle)".write(toFile: CV_DIR + "lastapp.txt", atomically: true, encoding: .utf8)
    guard let raw = try? String(contentsOfFile: AI_APPS_PATH, encoding: .utf8) else { return nil }
    for line in raw.split(separator: "\n") {
        let pat = line.trimmingCharacters(in: .whitespaces).lowercased()
        if pat.isEmpty || pat.hasPrefix("#") { continue }
        if bundle.contains(pat) || name.contains(pat) { return "KI" }
    }
    return nil
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// Kleines Listen-Thumbnail statt Vollbild im RAM (4K-Screenshot dekodiert = ~14 MB, Thumb = ~0,2 MB).
// ImageIO dekodiert DIREKT klein — das Vollbild landet nie im Speicher.
func thumbOpts(_ maxPx: CGFloat) -> CFDictionary {
    [kCGImageSourceCreateThumbnailFromImageAlways: true,
     kCGImageSourceThumbnailMaxPixelSize: maxPx,
     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
}
func loadThumb(url: URL, maxPx: CGFloat = 168) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts(maxPx)) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width)/2, height: CGFloat(cg.height)/2))
}
func loadThumb(data: Data, maxPx: CGFloat = 168) -> NSImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts(maxPx)) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width)/2, height: CGFloat(cg.height)/2))
}

// Scharfe, auflösungsunabhängige Eck-Maske (capInsets-Stretch) — saubere Ecken auf jedem Monitor
func roundMask(_ radius: CGFloat) -> NSImage {
    let d = radius * 2 + 2
    let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
        NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true
    }
    img.capInsets = NSEdgeInsets(top: radius+1, left: radius+1, bottom: radius+1, right: radius+1)
    img.resizingMode = .stretch
    return img
}

let timeFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM yyyy · HH:mm"; return f }()
let numFmt: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "de_DE"); return f }()
let linkDet = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
// Ist der Text GENAU ein einzelner http(s)-Link? (dann zeigen wir Website-Vorschau)
func soleURL(_ text: String?) -> URL? {
    guard var t = text else { return nil }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t.count < 2048, let det = linkDet else { return nil }
    let ns = t as NSString
    let ms = det.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length))
    guard ms.count == 1, let m = ms.first, m.range.location == 0, m.range.length == ns.length,
          let u = m.url, let sch = u.scheme?.lowercased(), sch == "http" || sch == "https" else { return nil }
    return u
}
let dayFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"; return f }()

// MARK: - Nur-Lese-Modus (Render-/Test-Befehle)
// `panel-render` & Co. bauen das Panel in einem ZWEITEN Prozess nach. Der darf weder den
// Verlauf schreiben noch Bilder loeschen noch Aenderungs-Meldungen verschicken — sonst
// ueberschreibt er, was die laufende App gerade haelt.
var CV_READ_ONLY = false

// MARK: - Smart-Erkennung (Badges: Link, E-Mail, Telefon, Farbe, Code)
enum Badge: String, CaseIterable {
    case link, email, phone, color, code
    var label: String {
        switch self { case .link: return "Link"; case .email: return "E-Mail"; case .phone: return "Telefon"; case .color: return "Farbe"; case .code: return "Code" }
    }
    var symbol: String {
        switch self { case .link: return "link"; case .email: return "envelope"; case .phone: return "phone"; case .color: return "paintpalette.fill"; case .code: return "chevron.left.forwardslash.chevron.right" }
    }
    var tint: NSColor {
        switch self { case .link: return .systemTeal; case .email: return .systemBlue; case .phone: return .systemGreen; case .color: return .systemPink; case .code: return .systemMint }
    }
}
private let phoneDet = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
private let emailRx = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9-]+(\\.[A-Z0-9-]+)*\\.[A-Z]{2,}", options: [.caseInsensitive])
private let hexRx = try? NSRegularExpression(pattern: "^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$", options: [.caseInsensitive])
private let rgbRx = try? NSRegularExpression(pattern: "^rgba?\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*(,\\s*([0-9.]+)\\s*)?\\)$", options: [.caseInsensitive])
private let codeKwRx = try? NSRegularExpression(pattern: "\\b(func|function|def|class|import|return|const|let|var|struct|enum|public|private|async|await|SELECT|FROM|WHERE|echo|sudo|npm|git|cd)\\b", options: [])

/// Welche Sorte Inhalt steckt im Text? Reihenfolge = Wichtigkeit (Farbe/E-Mail/Telefon vor Link vor Code).
func detectBadges(_ raw: String) -> [Badge] {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return [] }
    let sample = t.count > 20_000 ? String(t.prefix(20_000)) : t
    let ns = sample as NSString
    let full = NSRange(location: 0, length: ns.length)
    var out: [Badge] = []
    if parseColor(t) != nil { out.append(.color) }
    if let rx = emailRx, rx.firstMatch(in: sample, options: [], range: full) != nil { out.append(.email) }
    // Telefonnummer nur, wenn der (kurze) Text im Wesentlichen EINE Nummer ist — sonst Fehlalarme in Fliesstext
    if t.count <= 40, let det = phoneDet, let m = det.firstMatch(in: sample, options: [], range: full),
       Double(m.range.length) >= Double(ns.length) * 0.7, sample.filter({ $0.isNumber }).count >= 6 {
        out.append(.phone)
    }
    if let det = linkDet {
        let hasWeb = det.matches(in: sample, options: [], range: full).contains { m in
            guard let s = m.url?.scheme?.lowercased() else { return false }; return s == "http" || s == "https"
        }
        if hasWeb { out.append(.link) }
    }
    if looksLikeCode(sample) { out.append(.code) }
    return out
}

func looksLikeCode(_ t: String) -> Bool {
    let lines = t.split(separator: "\n", omittingEmptySubsequences: true)
    var score = 0
    if lines.count >= 2 {
        let enders = lines.filter { l in
            let e = l.trimmingCharacters(in: .whitespaces)
            return e.hasSuffix(";") || e.hasSuffix("{") || e.hasSuffix("}") || e.hasSuffix(");") || e.hasSuffix("):")
        }.count
        if enders >= 2 { score += 2 }
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") || $0.hasPrefix("  ") }.count
        if indented >= 2 { score += 1 }
    }
    let tokens = ["=>", "->", "==", "!=", "&&", "||", "</", "/>", "();", "{}", "::", "$(", "--"]
    score += min(3, tokens.filter { t.contains($0) }.count)
    if let rx = codeKwRx, rx.numberOfMatches(in: t, options: [], range: NSRange(location: 0, length: (t as NSString).length)) >= 3 { score += 1 }
    if t.hasPrefix("$ ") || t.hasPrefix("#!/") { score += 2 }
    // Fliesstext (viele normale Woerter, Satzzeichen) ist kein Code
    return score >= 3
}

/// "#1a2b3c", "#fff", "rgb(10, 20, 30)" -> Farbe (sonst nil)
func parseColor(_ raw: String) -> NSColor? {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count <= 32 else { return nil }
    let ns = t as NSString, full = NSRange(location: 0, length: ns.length)
    if let rx = hexRx, rx.firstMatch(in: t, options: [], range: full) != nil {
        var h = String(t.dropFirst())
        if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(h, radix: 16) else { return nil }
        let hasA = h.count == 8
        let r = CGFloat((v >> (hasA ? 24 : 16)) & 0xff) / 255, g = CGFloat((v >> (hasA ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((v >> (hasA ? 8 : 0)) & 0xff) / 255, a = hasA ? CGFloat(v & 0xff) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    if let rx = rgbRx, let m = rx.firstMatch(in: t, options: [], range: full) {
        func n(_ i: Int) -> CGFloat? { let r = m.range(at: i); return r.location == NSNotFound ? nil : CGFloat(Double(ns.substring(with: r)) ?? -1) }
        guard let r = n(1), let g = n(2), let b = n(3), (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }
        return NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: min(1, max(0, n(5) ?? 1)))
    }
    return nil
}

/// Farbwerte fuer die Vorschau: HEX · RGB · HSL
func colorDescription(_ c: NSColor) -> String {
    guard let s = c.usingColorSpace(.sRGB) else { return "" }
    let r = Int(round(s.redComponent * 255)), g = Int(round(s.greenComponent * 255)), b = Int(round(s.blueComponent * 255))
    let hex = String(format: "#%02X%02X%02X", r, g, b)
    var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
    s.getHue(&h, saturation: &sat, brightness: &br, alpha: &a)
    // HSB -> HSL
    let l = br * (1 - sat / 2)
    let sl = (l == 0 || l == 1) ? 0 : (br - l) / min(l, 1 - l)
    var out = "HEX   \(hex)\nRGB   \(r), \(g), \(b)\nHSL   \(Int(round(h*360)))°, \(Int(round(sl*100))) %, \(Int(round(l*100))) %"
    if a < 0.999 { out += "\nAlpha \(Int(round(a*100))) %" }
    return out
}

/// Farbfeld als Bild (Vorschau + Zeilen-Icon)
func colorSwatch(_ c: NSColor, size: NSSize, radius: CGFloat) -> NSImage {
    NSImage(size: size, flipped: false) { rect in
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        // Schachbrett unter halbtransparenten Farben
        if c.alphaComponent < 0.999 {
            let sq: CGFloat = 8
            for yi in 0..<Int(ceil(rect.height / sq)) { for xi in 0..<Int(ceil(rect.width / sq)) {
                ((xi + yi) % 2 == 0 ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.6, alpha: 1)).setFill()
                NSRect(x: CGFloat(xi)*sq, y: CGFloat(yi)*sq, width: sq, height: sq).fill()
            } }
        }
        c.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true
    }
}
