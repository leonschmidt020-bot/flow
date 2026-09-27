import AppKit
import CoreText
import SwiftUI

// MARK: - Flow: gemeinsames Fundament für alle Seiten (Design-Werte)

enum VF {
    // Farben (hell, warm – wie Flow Hub)
    static let chrome = Color(red: 0.953, green: 0.949, blue: 0.933)      // Fenster/Seitenleiste  #F3F2EE
    static let panel = Color(red: 0.984, green: 0.980, blue: 0.969)       // Inhaltsfläche        #FBFAF7
    static let card = Color.white
    static let cardSoft = Color(red: 0.961, green: 0.957, blue: 0.941)    // Insights-Karten      #F5F4F0
    static let ink = Color(red: 0.102, green: 0.102, blue: 0.098)         // Text                #1A1A19
    static let muted = Color(red: 0.42, green: 0.404, blue: 0.376)        // Nebentext           #6B6760
    static let hairline = Color(red: 0.902, green: 0.890, blue: 0.867)    // Linien              #E6E3DD
    static let selected = Color(red: 0.910, green: 0.902, blue: 0.882)    // Auswahl Seitenleiste #E8E6E1
    static let buttonSoft = Color(red: 0.937, green: 0.929, blue: 0.910)  // Zweitknopf          #EFEDE8
    static let black = Color(red: 0.11, green: 0.11, blue: 0.11)          // Hauptknopf          #1C1C1C
    static let purple = Color(red: 0.55, green: 0.36, blue: 0.80)         // Auswahlrahmen Stil
    static let orange = Color(red: 0.96, green: 0.69, blue: 0.33)
    // Insights-Grüntöne
    static let teal1 = Color(red: 0.184, green: 0.365, blue: 0.361)       // #2F5D5C
    static let teal2 = Color(red: 0.306, green: 0.549, blue: 0.533)       // #4E8C88
    static let teal3 = Color(red: 0.612, green: 0.812, blue: 0.776)       // #9CCFC6
    static let teal4 = Color(red: 0.867, green: 0.937, blue: 0.918)       // #DDEFEA
    static let beige = Color(red: 0.788, green: 0.757, blue: 0.706)       // #C9C1B4

    // Schriften: Seitentitel/Oberfläche = SF (sans), Banner-Überschriften & große Zahlen = Instrument Serif (falls geladen)
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let name = italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular"
        if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: .regular, design: .serif).italic(italic)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static let pageTitle = Font.system(size: 30, weight: .semibold)
    static let sectionLabel = Font.system(size: 12.5, weight: .semibold)   // GROSSBUCHSTABEN mit .tracking(1.2)

    // Maße
    static let panelRadius: CGFloat = 18
    static let cardRadius: CGFloat = 14
    static let bannerRadius: CGFloat = 18
    static let buttonRadius: CGFloat = 9
    static let contentMaxWidth: CGFloat = 1060

    /// Eigene Schriften aus Resources/Assets registrieren (einmal beim Start)
    static func registerFonts() {
        for f in ["InstrumentSerif-Regular.ttf", "InstrumentSerif-Italic.ttf"] {
            if let u = VFAsset.url(f) { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
        }
    }
}

/// Bilder/Schriften aus Resources/Assets (im App-Paket, sonst direkt aus dem Quellordner)
enum VFAsset {
    /// Entwickler-Build ohne App-Paket: Resources/Assets neben dem Quellbaum suchen (.build/release/Flow → ../../Resources/Assets),
    /// sonst FLOW_SRC oder der übliche Ort. Keine festen Benutzerpfade.
    static let sourceDir: URL = {
        let fm = FileManager.default
        if let src = ProcessInfo.processInfo.environment["FLOW_SRC"], !src.isEmpty {
            return URL(fileURLWithPath: (src as NSString).expandingTildeInPath).appendingPathComponent("Resources/Assets")
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let cand = dir.appendingPathComponent("Resources/Assets")
            if fm.fileExists(atPath: cand.appendingPathComponent("manifest.json").path) { return cand }
            dir.deleteLastPathComponent()
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Flow/src/mac/flow/Resources/Assets")
    }()

    static func url(_ file: String) -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Assets/\(file)"), FileManager.default.fileExists(atPath: r.path) { return r }
        let s = sourceDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: s.path) ? s : nil
    }

    private static var cache: [String: NSImage] = [:]
    /// name ohne Endung; sucht .png, dann .jpg
    static func image(_ name: String) -> NSImage? {
        if let c = cache[name] { return c }
        for ext in ["png", "jpg"] {
            if let u = url("\(name).\(ext)"), let img = NSImage(contentsOf: u) { cache[name] = img; return img }
        }
        return nil
    }
}

/// App-Art für Stil & Insights (nach Bundle-ID der App im Vordergrund)
enum AppCategory: String, Codable, CaseIterable, Identifiable {
    case personal, work, email, ai, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .personal: return "Persönliche Nachrichten"
        case .work: return "Arbeitsnachrichten"
        case .email: return "E-Mail"
        case .ai: return "KI-Prompts"
        case .other: return "Sonstiges"
        }
    }
    static func of(bundleID: String, appName: String = "") -> AppCategory {
        let b = bundleID.lowercased()
        let personal = ["net.whatsapp", "desktop.whatsapp", "ru.keepcoder.telegram", "org.telegram", "com.hnc.discord",
                        "com.apple.mobilesms", "org.whispersystems.signal", "com.facebook.archon", "com.burbn.instagram"]
        let work = ["com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.microsoft.teams2", "notion.id", "com.linear",
                    "com.atlassian", "com.clickup", "us.zoom.xos"]
        let email = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "it.bloop.airmail"]
        let ai = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92",
                  "com.google.antigravity", "com.exafunction.windsurf", "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
        if personal.contains(where: { b.hasPrefix($0) }) { return .personal }
        if work.contains(where: { b.hasPrefix($0) }) { return .work }
        if email.contains(where: { b.hasPrefix($0) }) { return .email }
        if ai.contains(where: { b.hasPrefix($0) }) { return .ai }
        return .other
    }
}
