import AppKit
import AVFoundation
import Combine

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    /// "me" = eigenes Mikrofon, sonst Sprecher-Schlüssel ("S1", "S2", … / "live")
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: String
    var answer: String?
    var date = Date()
}

struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case recording, processing, done, failed }
    var id: String
    var title: String
    var date: Date
    var duration: Double = 0
    var app: String?
    var status: Status = .recording
    var progressNote: String?
    var segments: [Segment] = []
    var speakerNames: [String: String] = [:]
    var speakerEmbeddings: [String: [Float]] = [:]
    var summary: String?
    var chat: [ChatMessage] = []
    /// „Behalten“ → wird nie automatisch gelöscht
    var keep: Bool? = nil

    /// Wann das Meeting automatisch gelöscht wird (nil = nie)
    var deletionDate: Date? {
        let days = Settings.shared.retentionDays
        guard days > 0, keep != true else { return nil }
        return date.addingTimeInterval(Double(days) * 86400)
    }

    var folder: URL { Paths.meetings.appendingPathComponent(id) }
    var micURL: URL { folder.appendingPathComponent("ich.wav") }
    var systemURL: URL { folder.appendingPathComponent("andere.wav") }

    func name(for key: String) -> String {
        if let n = speakerNames[key], !n.isEmpty { return n }
        switch key {
        case "me": return Settings.shared.myName.isEmpty ? "Ich" : Settings.shared.myName
        case "live": return "Teilnehmer"
        default:
            if key.hasPrefix("S"), let n = Int(key.dropFirst()) { return "Sprecher \(n)" }
            return key
        }
    }

    var speakerKeys: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Transkript als Text – zum Kopieren und für Claude.
    func transcriptText(withTimes: Bool = true) -> String {
        var out: [String] = []
        var last: String?
        for s in segments {
            let n = name(for: s.speaker)
            if n == last, !withTimes, let prev = out.popLast() {
                out.append(prev + " " + s.text)
            } else {
                out.append(withTimes ? "[\(Meeting.stamp(s.start))] \(n): \(s.text)" : "\(n): \(s.text)")
            }
            last = n
        }
        return out.joined(separator: "\n")
    }

    func markdown() -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        var md = "# \(title)\n\n\(df.string(from: date)) · \(Meeting.stamp(duration))"
        if let app { md += " · \(app)" }
        md += "\n\n"
        if let summary, !summary.isEmpty { md += "## Zusammenfassung\n\n\(summary)\n\n" }
        md += "## Transkript\n\n"
        for s in segments { md += "**\(name(for: s.speaker))** [\(Meeting.stamp(s.start))]: \(s.text)\n\n" }
        return md
    }
}

/// Alle Meetings auf der Platte + das gerade laufende.
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()
    @Published var meetings: [Meeting] = []
    @Published var selectedID: String?

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var list: [Meeting] = []
        for d in dirs {
            let f = d.appendingPathComponent("meeting.json")
            if let data = try? Data(contentsOf: f), var m = try? dec.decode(Meeting.self, from: data) {
                // Beim Absturz während Aufnahme/Auswertung hängen gebliebene Meetings markieren.
                if m.status == .recording || m.status == .processing, !(MeetingController.activeID == m.id) {
                    m.status = .failed; m.progressNote = "Unterbrochen – „Neu auswerten“ versuchen"
                }
                list.append(m)
            }
        }
        meetings = list.sorted { $0.date > $1.date }
    }

    func save(_ m: Meeting) {
        try? FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(m) { try? d.write(to: m.folder.appendingPathComponent("meeting.json"), options: .atomic) }
        try? m.markdown().write(to: m.folder.appendingPathComponent("transkript.md"), atomically: true, encoding: .utf8)
        update(m)
    }

    /// Nur im Speicher aktualisieren (Live-Ansicht), ohne Platte.
    func update(_ m: Meeting) {
        let apply = {
            if let i = self.meetings.firstIndex(where: { $0.id == m.id }) { self.meetings[i] = m }
            else { self.meetings.insert(m, at: 0) }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    /// Löscht Meetings, deren Frist abgelaufen ist (außer „Behalten“ und laufenden). Endgültig, nicht in den Papierkorb.
    func cleanup() {
        let now = Date()
        var removed = 0
        for m in meetings {
            guard m.status != .recording, m.status != .processing, let d = m.deletionDate, d < now else { continue }
            try? FileManager.default.removeItem(at: m.folder)
            removed += 1
        }
        if removed > 0 {
            meetings.removeAll { m in !FileManager.default.fileExists(atPath: m.folder.path) }
            if let s = selectedID, meeting(s) == nil { selectedID = meetings.first?.id }
            log("Aufgeräumt: \(removed) Meeting(s) älter als \(Settings.shared.retentionDays) Tage gelöscht")
        }
        // Meeting-Ordner ohne lesbare meeting.json (abgebrochene Aufnahmen) nach Ordner-Alter löschen
        let days = Settings.shared.retentionDays
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            let known = Set(meetings.map(\.id))
            let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for d in dirs where !known.contains(d.lastPathComponent) {
                // Audit 27.09.2026: liegt eine meeting.json/import.json drin, ist es kein Aufnahme-Rest, sondern ein Meeting, das
                // nur gerade nicht lesbar ist (z. B. nach einem Downgrade) – nie ungefragt löschen, auch nicht „Behalten“-Meetings.
                if FileManager.default.fileExists(atPath: d.appendingPathComponent("meeting.json").path)
                    || FileManager.default.fileExists(atPath: d.appendingPathComponent("import.json").path) { continue }
                let mod = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if mod < cutoff { try? FileManager.default.removeItem(at: d); log("Aufgeräumt: verwaister Meeting-Ordner") }
            }
            // letzte Diktat-Aufnahmen ebenfalls nach Frist
            for f in (try? FileManager.default.contentsOfDirectory(at: Dictation.debugDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if mod < cutoff { try? FileManager.default.removeItem(at: f) }
            }
        }
        MeetingStore.pruneLog()
        DictationHistory.shared.prune()
        HubNotesStore.cleanup(keeping: Set(meetings.map(\.id)))
        MCCleanup.run(meetings: meetings)
    }

    /// Das Protokoll enthält diktierte Texte → gleiche Frist wie die Transkripte.
    static func pruneLog() {
        let days = Settings.shared.retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        rewriteLog { txt in
            let f = ISO8601DateFormatter()
            let kept = txt.components(separatedBy: "\n").filter { line in
                guard let sp = line.firstIndex(of: " "), let d = f.date(from: String(line[..<sp])) else { return false }
                return d >= cutoff
            }
            return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        }
    }

    func setKeep(_ id: String, _ keep: Bool) {
        guard var m = meeting(id) else { return }
        m.keep = keep
        save(m)
    }

    func delete(_ id: String) {
        guard let m = meeting(id) else { return }
        try? FileManager.default.removeItem(at: m.folder)   // endgültig (Datenschutz), wie das automatische Aufräumen
        MCStore.shared.forget(id)
        meetings.removeAll { $0.id == id }
        if selectedID == id { selectedID = meetings.first?.id }
    }
}

/// Gemerkte Stimmen (Name → Stimm-Embedding), damit Sprecher in späteren Meetings automatisch erkannt werden.
enum VoiceStore {
    struct Voice: Codable { var name: String; var embedding: [Float]; var samples: Int }

    static func all() -> [Voice] {
        guard let d = try? Data(contentsOf: Paths.voices) else { return [] }
        return (try? JSONDecoder().decode([Voice].self, from: d)) ?? []
    }

    static func remember(name: String, embedding: [Float]) {
        guard !embedding.isEmpty, !name.isEmpty else { return }
        var list = all()
        if let i = list.firstIndex(where: { $0.name.lowercased() == name.lowercased() }),
           list[i].embedding.count == embedding.count {
            let n = Float(list[i].samples)
            list[i].embedding = zip(list[i].embedding, embedding).map { ($0 * n + $1) / (n + 1) }
            list[i].samples += 1
        } else {
            list.removeAll { $0.name.lowercased() == name.lowercased() }
            list.append(Voice(name: name, embedding: embedding, samples: 1))
        }
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: Paths.voices, options: .atomic) }
    }

    static func forget(name: String) {
        var list = all()
        list.removeAll { $0.name == name }
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: Paths.voices, options: .atomic) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return d / max(sqrt(na) * sqrt(nb), 1e-6)
    }

    /// Bester Treffer über der Schwelle, oder nil.
    static func match(_ e: [Float], threshold: Float = 0.62) -> (String, Float)? {
        all().map { ($0.name, cosine($0.embedding, e)) }.max { $0.1 < $1.1 }.flatMap { $0.1 >= threshold ? $0 : nil }
    }
}

/// Schreibt 16 kHz mono Samples als 16-bit-WAV (halb so groß wie Float).
final class WavWriter {
    private var file: AVAudioFile?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "flow.wav")
    private(set) var framesWritten: Int64 = 0

    init(url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ s: [Float]) {
        guard !s.isEmpty else { return }
        queue.async { [self] in
            guard let f = file, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)) else { return }
            buf.frameLength = AVAudioFrameCount(s.count)
            s.withUnsafeBufferPointer { p in buf.floatChannelData![0].update(from: p.baseAddress!, count: s.count) }
            try? f.write(from: buf)
            framesWritten += Int64(s.count)
        }
    }

    /// Mit Stille bis zur Position auffüllen (hält beide Spuren zeitgleich).
    func pad(to frames: Int64) {
        queue.async { [self] in
            let missing = frames - framesWritten
            guard missing > 0, missing < 16000 * 60 * 60 else { return }
            let s = [Float](repeating: 0, count: Int(missing))
            guard let f = file, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)) else { return }
            buf.frameLength = AVAudioFrameCount(s.count)
            s.withUnsafeBufferPointer { p in buf.floatChannelData![0].update(from: p.baseAddress!, count: s.count) }
            try? f.write(from: buf)
            framesWritten += missing
        }
    }

    func close() { queue.sync { file = nil } }

    static func read(_ url: URL) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        do { try f.read(into: buf) } catch { return [] }
        guard let ch = buf.floatChannelData else { return [] }
        if f.processingFormat.sampleRate == 16000 {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        }
        return []
    }
}

/// Energie-basierte Sprach-Abschnitte für die Live-Mitschrift.
final class LiveSegmenter {
    private let frame = 480  // 30 ms
    private var pending: [Float] = []
    private var current: [Float] = []
    private var currentStart: Int64 = 0
    private var position: Int64 = 0
    private var silenceFrames = 0
    private var speechFrames = 0
    private var noiseFloor: Float = 0.004
    var onSegment: ((_ start: Double, _ samples: [Float]) -> Void)?

    func feed(_ s: [Float]) {
        pending.append(contentsOf: s)
        while pending.count >= frame {
            let f = Array(pending[0..<frame]); pending.removeFirst(frame)
            var sum: Float = 0; for x in f { sum += x * x }
            let rms = sqrt(sum / Float(frame))
            let speech = rms > max(0.006, noiseFloor * 3)
            if !speech { noiseFloor = noiseFloor * 0.995 + rms * 0.005 }
            if speech {
                if current.isEmpty { currentStart = max(0, position - Int64(frame * 8)) }
                silenceFrames = 0; speechFrames += 1
                current.append(contentsOf: f)
            } else if !current.isEmpty {
                silenceFrames += 1
                current.append(contentsOf: f)
                if silenceFrames >= 23 { flush() }  // ~0,7 s Pause
            }
            if current.count > 16000 * 25 { flush() }
            position += Int64(frame)
        }
    }

    func flush() {
        if speechFrames >= 10 && current.count > 8000 { onSegment?(Double(currentStart) / 16000, current) }
        current = []; silenceFrames = 0; speechFrames = 0
    }
}
