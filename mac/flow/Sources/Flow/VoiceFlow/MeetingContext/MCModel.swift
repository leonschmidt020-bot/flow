import AppKit
import Combine
import Foundation

// MARK: - Meeting-Kontext: Datenmodell
//
// Pro Meeting liegt im Meeting-Ordner (~/.config/flow/meetings/<id>/):
//   bilder/f001_00-12.jpg …    Schlüsselbilder (nur Bild-Wechsel, volle Auflösung, max. 2560 px)
//   bilder.json                Liste der Bilder + erkannter Text (OCR) + markierte Momente
//   bildschirm.mov             optional: Video mit 1 Bild/s (Standard aus)
//   Kontext-Paket/             optional: „Kontext-Paket für Claude“ (meeting.md + bilder/)
// Alles liegt im Meeting-Ordner → gleiche Frist wie das Transkript (3 Tage, außer „Behalten“).

struct MCFrame: Codable, Identifiable, Equatable {
    var id: String
    /// Sekunden seit Aufnahme-Beginn (gleiche Zeitachse wie das Transkript)
    var t: Double
    /// zuletzt unverändert gesehen (bei Aufbau-Folien: letzte Stufe)
    var tLast: Double
    /// Pfad relativ zum Meeting-Ordner
    var file: String
    var width: Int
    var height: Int
    /// erkannter Text (nil = noch nicht gelesen, "" = kein Text)
    var ocr: String?
    /// Bereich mit geteiltem Inhalt (0…1, x/y/w/h, y von oben) – ohne Teilnehmer-Videos
    var roi: [Double]?
    /// wie stark sich das Bild vom vorigen unterscheidet (0…1)
    var change: Double = 0
    /// per ⌃⌥S gemerkt
    var moment: Bool?
    /// Fenstertitel beim Aufnehmen
    var window: String?

    var isMoment: Bool { moment == true }
}

struct MCMoment: Codable, Identifiable, Equatable {
    var id: String
    var t: Double
    /// zugehöriges Bild (falls der Bildschirm mitgeschnitten wurde)
    var frame: String?
    /// Transkript der letzten 30 s zum Zeitpunkt des Merkens (Live-Text; das fertige Transkript wird beim Anzeigen neu gelesen)
    var liveText: String
}

struct MCLog: Codable, Equatable {
    var version = 1
    var frames: [MCFrame] = []
    var moments: [MCMoment] = []
    /// Bildschirm wurde (zeitweise) mitgeschnitten
    var captured = false
    /// Datei des optionalen Videos (relativ)
    var video: String?
    /// Titel der mitgeschnittenen Fenster (zur Anzeige)
    var windows: [String] = []

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("bilder.json") }

    static func load(_ folder: URL) -> MCLog {
        guard let d = try? Data(contentsOf: url(folder)), let l = try? JSONDecoder().decode(MCLog.self, from: d) else { return MCLog() }
        return l
    }

    func save(_ folder: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let u = MCLog.url(folder)
        try? d.write(to: u, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    var isEmpty: Bool { frames.isEmpty && moments.isEmpty }
}

/// Liest/schreibt bilder.json je Meeting und benachrichtigt die Oberfläche.
final class MCStore: ObservableObject {
    static let shared = MCStore()
    @Published private(set) var revision = 0
    private var cache: [String: MCLog] = [:]
    private let lock = NSLock()

    static func folder(_ meetingID: String) -> URL { Paths.meetings.appendingPathComponent(meetingID) }

    func log(_ meetingID: String) -> MCLog {
        lock.lock(); defer { lock.unlock() }
        if let l = cache[meetingID] { return l }
        let l = MCLog.load(MCStore.folder(meetingID))
        cache[meetingID] = l
        return l
    }

    /// Ändern + speichern (thread-sicher). Oberfläche bekommt eine Meldung auf dem Main-Thread.
    func mutate(_ meetingID: String, _ f: (inout MCLog) -> Void) {
        lock.lock()
        var l = cache[meetingID] ?? MCLog.load(MCStore.folder(meetingID))
        f(&l)
        cache[meetingID] = l
        lock.unlock()
        l.save(MCStore.folder(meetingID))
        bump()
    }

    /// Vergessen (z. B. nach dem Löschen eines Meetings)
    func forget(_ meetingID: String) {
        lock.lock(); cache[meetingID] = nil; lock.unlock()
        bump()
    }

    private func bump() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }

    func url(_ meetingID: String, _ frame: MCFrame) -> URL { MCStore.folder(meetingID).appendingPathComponent(frame.file) }
}

// MARK: - Einstellungen (eigene Datei, nicht settings.json)

final class MCSettings: ObservableObject {
    static let shared = MCSettings()
    static var fileURL: URL { Paths.base.appendingPathComponent("meeting-kontext.json") }

    /// Standard für neue Meetings: Meeting-Fenster mitschneiden (Schlüsselbilder + Texterkennung)
    @Published var captureScreen = true { didSet { save() } }
    /// Zusätzlich Video mit 1 Bild/s (~50 MB/Std.)
    @Published var saveVideo = false { didSet { save() } }
    /// Zusammenfassung sieht die Bilder (Claude liest bis zu 20 Schlüsselbilder)
    @Published var summaryWithImages = true { didSet { save() } }

    private struct Stored: Codable { var captureScreen: Bool?; var saveVideo: Bool?; var summaryWithImages: Bool? }
    private var loading = false

    private init() {
        loading = true
        if let d = try? Data(contentsOf: MCSettings.fileURL), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            captureScreen = s.captureScreen ?? captureScreen
            saveVideo = s.saveVideo ?? saveVideo
            summaryWithImages = s.summaryWithImages ?? summaryWithImages
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(captureScreen: captureScreen, saveVideo: saveVideo, summaryWithImages: summaryWithImages)
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: MCSettings.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: MCSettings.fileURL.path)
    }
}

// MARK: - Hilfen

enum MCText {
    /// Gesprochenes in einem Zeitfenster (fertiges oder Live-Transkript)
    static func spoken(_ m: Meeting, from a: Double, to b: Double, maxChars: Int = 600) -> String {
        let segs = m.segments.filter { $0.end >= a && $0.start <= b }
        var out: [String] = []
        var last: String?
        for s in segs {
            let n = m.name(for: s.speaker)
            if n == last, let prev = out.popLast() { out.append(prev + " " + s.text) }
            else { out.append("\(n): \(s.text)") }
            last = n
        }
        let s = out.joined(separator: "\n")
        return s.count > maxChars ? String(s.prefix(maxChars)) + " …" : s
    }

    /// Dateiname-Zeitstempel „12-34“ bzw. „1-02-03“
    static func fileStamp(_ t: Double) -> String { Meeting.stamp(t).replacingOccurrences(of: ":", with: "-") }

    /// Fenster, in dem ein Bild „zu sehen war“: von t bis zum nächsten Bild (höchstens 3 Min.)
    static func visibleRange(_ frames: [MCFrame], _ i: Int, meetingEnd: Double) -> (Double, Double) {
        let f = frames[i]
        let next = i + 1 < frames.count ? frames[i + 1].t : meetingEnd
        return (max(0, f.t - 10), min(max(next, f.tLast) + 5, f.t + 180))
    }
}

// MARK: - Aufräumen (läuft mit MeetingStore.cleanup, stündlich)
//
// Bilder, Video, Paket und Screenshot-Kopien liegen im Meeting-Ordner und gehen mit dem Meeting (gleiche Frist, „Behalten“ schützt).
// Zusätzlich: liegengebliebene Claude-Eingabeordner (Absturz während der Zusammenfassung) sofort weg.

enum MCCleanup {
    static func run(meetings: [Meeting]) {
        let fm = FileManager.default
        for m in meetings where m.status != .recording && m.status != .processing {
            let u = m.folder.appendingPathComponent(".claude-eingabe")
            if fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
        }
    }
}
