import AppKit
import Combine
import Foundation

/// Alle Pfade an einem Ort. Laufzeitdaten liegen bewusst NICHT in Documents (sonst TCC-Dialoge).
enum Paths {
    /// Datenordner: ~/.config/flow – oder `FLOW_HOME` (Tests, Sichtprüfung mit leerem Ordner = neuer Benutzer)
    static let base: URL = {
        let env = ProcessInfo.processInfo.environment["FLOW_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let u = env.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow")
            : URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// Anzeige-Pfad („~/.config/flow“)
    static var baseDisplay: String { (base.path as NSString).abbreviatingWithTildeInPath }
    static let settings = base.appendingPathComponent("settings.json")

    /// Datenordner nur für den eigenen Benutzer lesbar (Transkripte, Stimmprofile = sensible Daten)
    static func secure() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        if let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let u as URL in e {
                let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // ausführbare Dateien (z. B. bin/flow) behalten ihr x-Recht
                let exec = fm.isExecutableFile(atPath: u.path) && !dir
                try? fm.setAttributes([.posixPermissions: (dir || exec) ? 0o700 : 0o600], ofItemAtPath: u.path)
            }
        }
    }
    static let voices = base.appendingPathComponent("voices.json")
    static let log = base.appendingPathComponent("flow.log")
    static let meetings: URL = {
        let u = base.appendingPathComponent("meetings")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

private let logQueue = DispatchQueue(label: "flow.log")
private let logFormatter = ISO8601DateFormatter()
private var logHandle: FileHandle?

/// Thread-sicher: alle Zeilen laufen über eine Queue und ein Handle (kein Durcheinander, kein Absturz bei vollem Speicher)
func log(_ s: String) {
    let line = "\(logFormatter.string(from: Date())) \(s.replacingOccurrences(of: "\n", with: "⏎"))\n"
    logQueue.async {
        if logHandle == nil {
            if !FileManager.default.fileExists(atPath: Paths.log.path) {
                FileManager.default.createFile(atPath: Paths.log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            logHandle = try? FileHandle(forWritingTo: Paths.log)
        }
        guard let h = logHandle, let d = line.data(using: .utf8) else { return }
        do { try h.seekToEnd(); try h.write(contentsOf: d) } catch { logHandle = nil }
    }
}

/// Log-Datei umschreiben (Aufräumen) – auf derselben Queue wie das Schreiben
func rewriteLog(_ transform: @escaping (String) -> String) {
    logQueue.async {
        try? logHandle?.close(); logHandle = nil
        guard let txt = try? String(contentsOf: Paths.log, encoding: .utf8) else { return }
        try? transform(txt).write(to: Paths.log, atomically: true, encoding: .utf8)
    }
}

enum HotkeyChoice: String, Codable, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fn: return "Fn / 🌐"
        case .rightOption: return "Rechte Wahltaste ⌥"
        case .rightCommand: return "Rechte Befehlstaste ⌘"
        case .rightControl: return "Rechte Control-Taste ⌃"
        }
    }
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }
    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }
}

enum AIPolish: String, Codable, CaseIterable, Identifiable {
    /// „always“ als Rohwert: ältere Versionen lesen die Datei weiter (dort hieß das „Immer, Apple Intelligence“)
    case off, fast = "always", thorough
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Aus"
        case .fast: return "Schnell (auf dem Mac, Standard)"
        case .thorough: return "Gründlich (Claude, langsamer)"
        }
    }
    /// Bis 1.6: „correctionsOnly“ (Standard) und „always“ → Schnell
    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "off": self = .off
        case "thorough": self = .thorough
        default: self = .fast
        }
    }
}

enum PillVisibility: String, Codable, CaseIterable, Identifiable {
    case always, whileActive
    var id: String { rawValue }
    var label: String { self == .always ? "Immer sichtbar (kleiner Strich)" : "Nur beim Sprechen" }
}

enum PillFollow: String, Codable, CaseIterable, Identifiable {
    case focusedWindow, mouse
    var id: String { rawValue }
    var label: String { self == .focusedWindow ? "Bildschirm mit dem aktiven Fenster" : "Bildschirm mit der Maus" }
}

enum MeetingDetection: String, Codable, CaseIterable, Identifiable {
    case off, ask, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Aus"
        case .ask: return "Nachfragen, wenn ein Meeting startet"
        case .auto: return "Automatisch aufnehmen"
        }
    }
}

/// Feste Andock-Punkte. fx/fy = Anteil des sichtbaren Bildschirmbereichs (0 = links/unten).
enum PillPreset: String, Codable, CaseIterable, Identifiable {
    case bottomCenter, bottomLeft, bottomRight, middleRight, middleLeft, topCenter, topRight, topLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomCenter: return "Unten Mitte"
        case .bottomLeft: return "Unten links"
        case .bottomRight: return "Unten rechts"
        case .middleRight: return "Mitte rechts"
        case .middleLeft: return "Mitte links"
        case .topCenter: return "Oben Mitte"
        case .topRight: return "Oben rechts"
        case .topLeft: return "Oben links"
        }
    }
    /// Mittelpunkt der Pille im sichtbaren Bereich des Bildschirms.
    func center(in r: NSRect) -> NSPoint {
        let m: CGFloat = 22  // Abstand zum Rand
        let l = r.minX + m + 40, rr = r.maxX - m - 40, b = r.minY + m, t = r.maxY - m, mx = r.midX, my = r.midY
        switch self {
        case .bottomCenter: return NSPoint(x: mx, y: b)
        case .bottomLeft: return NSPoint(x: l, y: b)
        case .bottomRight: return NSPoint(x: rr, y: b)
        case .middleRight: return NSPoint(x: r.maxX - PillPlacement.edge, y: my)   // hochkant, direkt am Rand
        case .middleLeft: return NSPoint(x: r.minX + PillPlacement.edge, y: my)
        case .topCenter: return NSPoint(x: mx, y: t)
        case .topRight: return NSPoint(x: rr, y: t)
        case .topLeft: return NSPoint(x: l, y: t)
        }
    }
}

/// Position pro Bildschirm: entweder ein Preset oder frei gezogen (Anteile).
struct PillPlacement: Codable, Equatable {
    var preset: PillPreset?
    var fx: Double = 0.5
    var fy: Double = 0.0

    /// Abstand der Pillen-Mitte zum Bildschirmrand, wenn sie am Rand klebt.
    static let edge: CGFloat = 14
    /// Im äußeren Zehntel losgelassen → klebt am Rand.
    static let edgeZone = 0.10

    /// Linke/rechte Seite → Pille steht hochkant.
    var isSide: Bool {
        if let p = preset { return p == .middleLeft || p == .middleRight }
        return fx < PillPlacement.edgeZone || fx > 1 - PillPlacement.edgeZone
    }

    func center(in r: NSRect) -> NSPoint {
        if let p = preset { return p.center(in: r) }
        var x = r.minX + CGFloat(fx) * r.width, y = r.minY + CGFloat(fy) * r.height
        let z = PillPlacement.edgeZone, e = PillPlacement.edge
        if fx > 1 - z { x = r.maxX - e } else if fx < z { x = r.minX + e }
        else if fy < z { y = r.minY + 22 } else if fy > 1 - z { y = r.maxY - 22 }
        return NSPoint(x: x, y: y)
    }
}

struct DictEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var heard: String
    var write: String
    /// Aus deinen Korrekturen gelernt
    var learned: Bool? = nil
    /// Echtes Wort („ID“) → nicht blind ersetzen, nur als Hinweis an Whisper
    var vocabOnly: Bool? = nil
}

enum LanguageMode: String, Codable, CaseIterable, Identifiable {
    case both, de, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return "Deutsch + Englisch (automatisch)"
        case .de: return "Nur Deutsch"
        case .en: return "Nur Englisch"
        }
    }
    var short: String { self == .both ? "DE+EN" : (self == .de ? "DE" : "EN") }
}

enum ASREngine: String, Codable, CaseIterable, Identifiable {
    case whisper, parakeet
    var id: String { rawValue }
    var label: String { self == .whisper ? "Genau – Whisper (~0,6 s, kennt dein Wörterbuch)" : "Blitzschnell – Parakeet (~0,1 s)" }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var hotkey: HotkeyChoice = .fn
    /// Standard: Whisper, wenn whisper-server (Homebrew) + Modell da sind – sonst Parakeet (läuft ohne Homebrew)
    @Published var engine: ASREngine = WhisperEngine.available ? .whisper : .parakeet
    @Published var languageMode: LanguageMode = .both
    /// Aus Korrekturen im Textfeld lernen
    @Published var learnFromEdits = true
    @Published var doubleTapHandsFree = true
    @Published var removeFillers = true
    @Published var voiceCommands = true
    @Published var aiPolish: AIPolish = .fast
    @Published var sounds = true
    @Published var micUID: String? = nil
    @Published var keepInClipboard = true
    /// Ton vom Mac (Musik, YouTube) aus dem Diktat herausrechnen
    @Published var filterMacAudio = true
    /// Nur die eigene Stimme behalten (braucht ein eingelerntes Stimmprofil)
    @Published var onlyMyVoice = true
    @Published var pillVisibility: PillVisibility = .always
    @Published var placements: [String: PillPlacement] = [:]
    @Published var pillFollow: PillFollow = .mouse
    @Published var dictionary: [DictEntry] = Settings.defaultDictionary
    @Published var meetingDetection: MeetingDetection = .ask
    /// Nach dem Meeting automatisch zusammenfassen – braucht die optionale Claude-CLI, darum Standard AUS
    @Published var autoSummary = false
    /// Command Mode (fn + ⌃: markierten Text per Sprachbefehl umschreiben) – braucht die optionale Claude-CLI, Standard AUS
    @Published var commandMode = false
    /// Eigener Name (Begrüßung, eigenes Mikro im Transkript, Whisper-Hinweis). Vorgabe: Vorname des macOS-Kontos.
    @Published var myName = Identity.systemFirstName
    /// Name des Partners im geteilten ClipVault-Tresor (leer = aus der ClipVault-Kopplung, sonst „dein Partner“)
    @Published var partnerName = ""
    /// Willkommens-Ablauf erledigt (bestehende settings.json ohne diesen Schlüssel gilt als erledigt)
    @Published var onboardingDone = false
    @Published var keepAudio = true
    /// Diktat-Texte im Protokoll mitschreiben (nur zur Fehlersuche)
    @Published var logTexts = false
    /// Transkripte + Aufnahmen nach so vielen Tagen automatisch löschen (0 = nie)
    @Published var retentionDays = 3
    /// „Text dorthin, wo die Maus ist“: Fn halten fügt ins Fenster unter der Maus ein (VoiceFlow/MouseTarget, Standard aus)
    @Published var mouseTarget = false
    /// … und danach Enter drücken – nur in Terminals/Chats (MTRules.autoSend), nie in Dokumenten
    @Published var mouseTargetAutoSend = false
    /// Blauer Rahmen „Text kommt hierher“ um das Ziel-Fenster, solange gesprochen wird
    @Published var mouseTargetHighlight = true

    private var bag = Set<AnyCancellable>()

    /// Unveränderliche Kopie für Hintergrund-Threads (Diktat, Whisper, Meetings) – kein Datenrennen mit der Oberfläche.
    struct Frozen {
        var dictionary: [DictEntry] = []
        var removeFillers = true, voiceCommands = true, logTexts = false, onlyMyVoice = true, filterMacAudio = true
        var myName = ""
        var languageMode: LanguageMode = .both
        var engine: ASREngine = .whisper
        var aiPolish: AIPolish = .fast
    }
    private static let frozenLock = NSLock()
    private static var _frozen = Frozen()
    static var frozen: Frozen { frozenLock.lock(); defer { frozenLock.unlock() }; return _frozen }
    private func refreeze() {
        let f = Frozen(dictionary: dictionary, removeFillers: removeFillers, voiceCommands: voiceCommands, logTexts: logTexts,
                       onlyMyVoice: onlyMyVoice, filterMacAudio: filterMacAudio, myName: myName, languageMode: languageMode,
                       engine: engine, aiPolish: aiPolish)
        Settings.frozenLock.lock(); Settings._frozen = f; Settings.frozenLock.unlock()
    }
    private var loading = false

    /// Startwörterbuch für einen neuen Benutzer: nur die App-Namen selbst, nichts Persönliches.
    /// (Wer schon eine settings.json hat, behält sein Wörterbuch – das hier greift nur ohne Datei.)
    static let defaultDictionary: [DictEntry] = [
        DictEntry(heard: "Clip Vault", write: "ClipVault"),
        DictEntry(heard: "Whisper Flow", write: "Flow"),
    ]

    /// true = beim Start gab es keine settings.json (neuer Benutzer / frischer Mac)
    private(set) var isFreshInstall = false

    private struct Stored: Codable {
        var hotkey: HotkeyChoice?
        var engine: ASREngine?
        var languageMode: LanguageMode?
        var learnFromEdits: Bool?
        var doubleTapHandsFree: Bool?
        var removeFillers: Bool?
        var voiceCommands: Bool?
        var aiPolish: AIPolish?
        var sounds: Bool?
        var micUID: String?
        var keepInClipboard: Bool?
        var filterMacAudio: Bool?
        var onlyMyVoice: Bool?
        var pillVisibility: PillVisibility?
        var placements: [String: PillPlacement]?
        var pillFollow: PillFollow?
        var dictionary: [DictEntry]?
        var meetingDetection: MeetingDetection?
        var autoSummary: Bool?
        var myName: String?
        var partnerName: String?
        var onboardingDone: Bool?
        var keepAudio: Bool?
        var logTexts: Bool?
        var retentionDays: Int?
        var mouseTarget: Bool?
        var mouseTargetAutoSend: Bool?
        var mouseTargetHighlight: Bool?
        var commandMode: Bool?
    }

    private init() {
        load()
        refreeze()
        objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreeze() }.store(in: &bag)
        objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)
    }

    private func load() {
        guard let d = try? Data(contentsOf: Paths.settings) else {
            // Keine Datei → neuer Benutzer: Willkommen zeigen, neutrale Vorgaben
            isFreshInstall = true
            onboardingDone = false
            return
        }
        guard let s = try? JSONDecoder().decode(Stored.self, from: d) else {
            // Unlesbar → NIE stillschweigend überschreiben: erst sichern, dann mit Vorgaben weiter
            let backup = Paths.base.appendingPathComponent("settings.unlesbar-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: Paths.settings, to: backup)
            log("settings.json unlesbar – gesichert als \(backup.lastPathComponent)")
            onboardingDone = true
            // Audit 27.09.2026: mit Vorgaben weiterzulaufen hieß auch „nach 3 Tagen löschen“ – selbst wenn „nie“ eingestellt war.
            // Solange unklar ist, was der Nutzer wollte: nichts automatisch löschen.
            retentionDays = 0
            return
        }
        loading = true
        hotkey = s.hotkey ?? hotkey
        engine = s.engine ?? engine
        languageMode = s.languageMode ?? languageMode
        learnFromEdits = s.learnFromEdits ?? learnFromEdits
        doubleTapHandsFree = s.doubleTapHandsFree ?? doubleTapHandsFree
        removeFillers = s.removeFillers ?? removeFillers
        voiceCommands = s.voiceCommands ?? voiceCommands
        aiPolish = s.aiPolish ?? aiPolish
        sounds = s.sounds ?? sounds
        micUID = s.micUID
        keepInClipboard = s.keepInClipboard ?? keepInClipboard
        filterMacAudio = s.filterMacAudio ?? filterMacAudio
        onlyMyVoice = s.onlyMyVoice ?? onlyMyVoice
        pillVisibility = s.pillVisibility ?? pillVisibility
        placements = s.placements ?? placements
        pillFollow = s.pillFollow ?? pillFollow
        dictionary = s.dictionary ?? dictionary
        meetingDetection = s.meetingDetection ?? meetingDetection
        autoSummary = s.autoSummary ?? autoSummary
        myName = s.myName ?? myName
        partnerName = s.partnerName ?? partnerName
        // Bestehende Installation (Datei ohne den Schlüssel) → kein Willkommens-Ablauf
        onboardingDone = s.onboardingDone ?? true
        keepAudio = s.keepAudio ?? keepAudio
        logTexts = s.logTexts ?? logTexts
        retentionDays = s.retentionDays ?? retentionDays
        mouseTarget = s.mouseTarget ?? mouseTarget
        mouseTargetAutoSend = s.mouseTargetAutoSend ?? mouseTargetAutoSend
        mouseTargetHighlight = s.mouseTargetHighlight ?? mouseTargetHighlight
        commandMode = s.commandMode ?? commandMode
        loading = false
    }

    func save() {
        let s = Stored(hotkey: hotkey, engine: engine, languageMode: languageMode, learnFromEdits: learnFromEdits, doubleTapHandsFree: doubleTapHandsFree, removeFillers: removeFillers,
                       voiceCommands: voiceCommands, aiPolish: aiPolish, sounds: sounds, micUID: micUID,
                       keepInClipboard: keepInClipboard, filterMacAudio: filterMacAudio, onlyMyVoice: onlyMyVoice, pillVisibility: pillVisibility, placements: placements, pillFollow: pillFollow,
                       dictionary: dictionary, meetingDetection: meetingDetection, autoSummary: autoSummary,
                       myName: myName, partnerName: partnerName, onboardingDone: onboardingDone, keepAudio: keepAudio, logTexts: logTexts, retentionDays: retentionDays,
                       mouseTarget: mouseTarget, mouseTargetAutoSend: mouseTargetAutoSend,
                       mouseTargetHighlight: mouseTargetHighlight, commandMode: commandMode)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: Paths.settings, options: .atomic) }
    }

    /// Stabiler Schlüssel pro Monitor (Name + Auflösung überlebt Umstecken besser als die Display-ID).
    static func key(for screen: NSScreen) -> String {
        "\(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    func placement(for screen: NSScreen) -> PillPlacement {
        placements[Settings.key(for: screen)] ?? PillPlacement(preset: .bottomCenter)
    }
}

extension NSWindow {
    /// Mittig auf dem Bildschirm unter der Maus öffnen (bei 3 Monitoren wichtig).
    func centerOnMouseScreen() {
        let m = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main else { center(); return }
        let v = scr.visibleFrame
        var f = frame
        f.size.width = min(f.width, v.width - 40); f.size.height = min(f.height, v.height - 40)
        f.origin = NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2)
        setFrame(f, display: false)
    }
}
