import Foundation
import UniformTypeIdentifiers

// MARK: - Audiodateien transkribieren: Datenmodell
//
// Eine Audiodatei wird zu einer ganz normalen Notiz (`Meeting`) im Notetaker – Quelle „Datei“ (`Meeting.app`),
// Titel = Dateiname, bis die Zusammenfassung einen besseren Titel liefert.
// Alles, was nur der Import braucht, liegt als Beiblatt `import.json` im Notiz-Ordner (Kern-Modell bleibt unverändert):
//   meetings/<id>/import.json      Auftrag: Quelle, Phase, Stückplan, Fortschritt, Zeiten
//   meetings/<id>/audio.pcm        16 kHz mono Int16 (dekodiert, nur während der Auswertung – danach gelöscht)
//   meetings/<id>/sprecher.json    Ergebnis der Sprechertrennung (für „Fortsetzen“ nach Neustart/Abbruch)
//   meetings/<id>/stuecke/NNN.json fertige Abschnitte je Stück
// Die Originaldatei wird NUR referenziert, nie kopiert (Ausnahme: Eingangsordner → danach nach „Erledigt“ verschoben).

enum AudioImportOrigin: String, Codable {
    case drop        // auf Hub/Pille/Karte gezogen
    case picker      // „Datei wählen …“
    case finder      // Finder → Öffnen mit → Flow
    case inbox       // Eingangsordner
    case cli         // Test/Kommandozeile

    var label: String {
        switch self {
        case .drop: return "gezogen"
        case .picker: return "ausgewählt"
        case .finder: return "Finder"
        case .inbox: return "Eingangsordner"
        case .cli: return "Test"
        }
    }
}

enum AudioImportPhase: String, Codable {
    case queued, decoding, diarizing, transcribing, finishing, summarizing, done, failed, cancelled

    /// Läuft noch (bzw. wurde durch Beenden der App unterbrochen und wird beim Start fortgesetzt)
    var isActive: Bool { [.queued, .decoding, .diarizing, .transcribing, .finishing].contains(self) }
}

struct AudioImportChunk: Codable, Equatable {
    var start: Double
    var end: Double
    /// "de" / "en" – nach der Erkennung gesetzt (Mehrheit nach Sprechdauer der Äußerungen)
    var language: String?
    /// Sprechdauer je Sprache in diesem Stück (Äußerung für Äußerung erkannt)
    var deSeconds: Double?
    var enSeconds: Double?
}

struct AudioImportJob: Codable, Equatable {
    var id: String
    /// Aktueller Ort der Originaldatei (Eingangsordner: nach dem Verschieben der Ort in „Erledigt“)
    var source: String
    var fileName: String
    var origin: AudioImportOrigin
    var bytes: Int64 = 0
    var added = Date()
    var phase: AudioImportPhase = .queued
    /// Länge der Tonspur in Sekunden (nach dem Dekodieren exakt)
    var duration: Double = 0
    var decoded = false
    var diarized = false
    var chunks: [AudioImportChunk] = []
    var chunksDone = 0
    /// Fehlertext für die Karte (freundlich, deutsch)
    var error: String?
    /// Sekunden pro Schritt (für Tempo-Messung / Echtzeitfaktor)
    var timings: [String: Double] = [:]
    /// Sekunden Ton, die zusätzlich Whisper bekommen hat (Hybrid)
    var whisperSeconds: Double = 0
    var whisperCalls = 0
    /// Wie oft die Auswertung (nach Abbruch/Neustart) fortgesetzt wurde
    var resumes = 0
    /// Dekoder, der die Datei lesen konnte ("AVAudioFile", "AVAssetReader", "ffmpeg")
    var decoder: String?
    /// Nur Eingangsordner: wohin die Datei nach der Auswertung gewandert ist
    var movedTo: String?
    /// Die Datei gehört Flow (Datei-Versprechen, z. B. aus Sprachmemos) → wandert nach der Auswertung in den Notiz-Ordner
    var ownedCopy: Bool?

    /// Art der Aufnahme für die Fertig-Karte („Sprachmemo · …“)
    var kindLabel: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "qta" || (ownedCopy == true && ["m4a", "qta"].contains(ext) && fileName.hasPrefix("New Recording")) { return "Sprachmemo" }
        if ["opus", "ogg", "oga"].contains(ext) || fileName.lowercased().contains("whatsapp") { return "Sprachnachricht" }
        if AudioImportFormats.isVideo(ext) { return "Video" }
        return "Datei"
    }

    var sourceURL: URL { URL(fileURLWithPath: source) }

    /// 0…1 über alle Schritte (Gewichte aus Messungen auf dem M4 Pro, siehe AudioImportCLI)
    var fraction: Double {
        switch phase {
        case .queued: return 0
        case .decoding: return 0.02
        case .diarizing: return 0.05
        case .transcribing:
            guard !chunks.isEmpty else { return 0.3 }
            return 0.3 + 0.65 * Double(chunksDone) / Double(chunks.count)
        case .finishing: return 0.96
        case .summarizing: return 0.98
        case .done: return 1
        case .failed, .cancelled:
            return chunks.isEmpty ? 0 : 0.3 + 0.65 * Double(chunksDone) / Double(chunks.count)
        }
    }
}

// MARK: - Dateien, Ordner

enum AudioImportFiles {
    static func folder(_ id: String) -> URL { Paths.meetings.appendingPathComponent(id) }
    static func jobURL(_ id: String) -> URL { folder(id).appendingPathComponent("import.json") }
    static func pcmURL(_ id: String) -> URL { folder(id).appendingPathComponent("audio.pcm") }
    static func diarizationURL(_ id: String) -> URL { folder(id).appendingPathComponent("sprecher.json") }
    static func chunkDir(_ id: String) -> URL { folder(id).appendingPathComponent("stuecke") }
    static func chunkURL(_ id: String, _ i: Int) -> URL { chunkDir(id).appendingPathComponent(String(format: "%03d.json", i)) }

    static func isFileNote(_ id: String) -> Bool { FileManager.default.fileExists(atPath: jobURL(id).path) }

    static func loadJob(_ id: String) -> AudioImportJob? {
        guard let d = try? Data(contentsOf: jobURL(id)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AudioImportJob.self, from: d)
    }

    static func saveJob(_ j: AudioImportJob) {
        try? FileManager.default.createDirectory(at: folder(j.id), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(j) {
            try? d.write(to: jobURL(j.id), options: .atomic)
            chmod(jobURL(j.id).path, 0o600)
        }
    }

    /// Alle Import-Aufträge auf der Platte
    static func allJobs() -> [AudioImportJob] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { loadJob($0.lastPathComponent) }
    }

    /// Zwischenstände löschen (nach Erfolg): dekodierter Ton, Sprecher, Stücke
    static func removeScratch(_ id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: pcmURL(id))
        try? fm.removeItem(at: diarizationURL(id))
        try? fm.removeItem(at: chunkDir(id))
    }
}

// MARK: - Einstellungen (eigene Datei audioimport.json, Rechte 0600)

final class AudioImportSettings: ObservableObject {
    static let shared = AudioImportSettings()
    static var fileURL: URL { Paths.base.appendingPathComponent("audioimport.json") }

    private struct Stored: Codable {
        var inboxEnabled: Bool?
        var inboxPath: String?
        var whisperAssist: Bool?
        var notifyWhenDone: Bool?
    }

    /// Eingangsordner beobachten (aus, bis du ihn einschaltest – erst dann wird ~/Documents angefasst)
    @Published var inboxEnabled = false { didSet { if inboxEnabled != oldValue { save(); onInboxChange?() } } }
    /// Eigener Ort für den Eingangsordner (nil = ~/Documents/Flow/Eingang)
    @Published var inboxPath: String? { didSet { if inboxPath != oldValue { save(); onInboxChange?() } } }
    /// Unsichere Stellen zusätzlich mit Whisper erkennen (Hybrid)
    @Published var whisperAssist = true { didSet { if whisperAssist != oldValue { save() } } }
    /// Meldung an der Pille, wenn eine Datei fertig ist
    @Published var notifyWhenDone = true { didSet { if notifyWhenDone != oldValue { save() } } }

    var onInboxChange: (() -> Void)?
    private var loading = false

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            inboxEnabled = s.inboxEnabled ?? false
            inboxPath = s.inboxPath
            whisperAssist = s.whisperAssist ?? true
            notifyWhenDone = s.notifyWhenDone ?? true
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(inboxEnabled: inboxEnabled, inboxPath: inboxPath, whisperAssist: whisperAssist, notifyWhenDone: notifyWhenDone)
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: Self.fileURL, options: .atomic)
            chmod(Self.fileURL.path, 0o600)
        }
    }

    /// ~/Documents/Flow/Eingang – oder `FLOW_EINGANG` (Tests) – oder ein eigener Ort
    var inboxURL: URL {
        if let env = ProcessInfo.processInfo.environment["FLOW_EINGANG"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let p = inboxPath, !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/\(AudioImportFormats.appFolderName)/Eingang", isDirectory: true)
    }
    var doneURL: URL { inboxURL.appendingPathComponent("Erledigt", isDirectory: true) }
    var failedURL: URL { inboxURL.appendingPathComponent("Nicht lesbar", isDirectory: true) }
    var inboxDisplay: String { (inboxURL.path as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Formate

enum AudioImportFormats {
    /// Name des App-Ordners in ~/Documents (App-Name aus dem Bundle)
    static var appFolderName: String {
        let n = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
        return n.isEmpty || n == "Flow" ? "Flow" : n
    }

    /// Endungen, die direkt mit macOS-Bordmitteln (AVFoundation/AudioToolbox) gelesen werden – auf macOS 26 inkl. Ogg/Opus
    static let native: Set<String> = ["mp3", "m4a", "m4b", "m4r", "wav", "wave", "aif", "aiff", "aifc", "caf", "aac", "adts",
                                      "flac", "ogg", "oga", "opus", "mp4", "m4v", "mov", "qt", "qta", "3gp", "3g2", "amr", "ac3", "ec3", "mp2", "mpga"]
    /// Nur mit ffmpeg (falls per Homebrew installiert)
    static let ffmpegOnly: Set<String> = ["webm", "mkv", "wma", "wmv", "avi", "flv", "ogv", "mka", "spx", "ape", "wv", "ts", "mts"]

    static var allExtensions: Set<String> { native.union(ffmpegOnly) }

    static func isVideo(_ ext: String) -> Bool { ["mp4", "m4v", "mov", "qt", "3gp", "3g2", "webm", "mkv", "wmv", "avi", "flv", "ogv", "ts", "mts"].contains(ext) }

    /// Kann (vermutlich) gelesen werden? Endung ODER Inhaltstyp Audio/Video.
    static func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if allExtensions.contains(ext) { return true }
        if let t = UTType(filenameExtension: ext) { return t.conforms(to: .audio) || t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) }
        return false
    }

    /// Für den Öffnen-Dialog
    static var contentTypes: [UTType] {
        var t: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]
        for e in ["ogg", "opus", "oga", "flac", "caf", "aac", "webm", "mkv"] { if let u = UTType(filenameExtension: e) { t.append(u) } }
        return t
    }

    static var ffmpeg: String? {
        // FLOW_NO_FFMPEG=1: Test „Mac ohne Homebrew-ffmpeg“
        if ProcessInfo.processInfo.environment["FLOW_NO_FFMPEG"] == "1" { return nil }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
