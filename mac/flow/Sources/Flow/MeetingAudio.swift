import AVFoundation
import Foundation

// MARK: - Meeting-Ton platzsparend ablegen
//
// 18.10.2026 (Wunsch: „komprimiere es immer automatisch, so dass es wenig Speicherplatz verbraucht“): Die Spuren lagen als
// 16-bit-WAV (16 kHz mono) im Meeting-Ordner – ich.wav + andere.wav ≈ 230 MB je Stunde, „Behalten“-Meetings für immer,
// übernommene Importdateien (original.qta, 182 MB) ebenso. Jetzt, sobald das Transkript gespeichert ist:
//   Meeting-Spuren   → ich.m4a / andere.m4a   AAC mono 16 kHz, 32 kbit/s (≈ 14 MB je Spur und Stunde, ~8× kleiner);
//                      die Auswertung liest ohnehin 16 kHz → „Neu auswerten“ bekommt dieselbe Abtastrate
//   Import-Original  → original.m4a           AAC mono 24 kHz, 48 kbit/s (nur Flows eigene Kopie im Notiz-Ordner,
//                      nie Dateien woanders; Videos bleiben unverändert, sonst ginge das Bild verloren)
// Je Datei: nach <ordner>/.komprimieren/ schreiben → komplett zurücklesen und prüfen (lesbar, Länge ±0,5 s, Lautstärke
// plausibel) → an den Platz verschieben → erst DANN die Quelle löschen. Scheitert etwas, bleibt die Quelle unverändert.
// Nur Meetings mit Status „fertig“: Aufnahme, Auswertung, unterbrochene/fehlgeschlagene Meetings behalten ihre WAV.
// Wer die Spur liest, fragt `MeetingAudio.trackURL` (WAV, solange es sie gibt, sonst .m4a).

enum MeetingAudio {
    /// Meeting-Spuren: so liest die Auswertung (16 kHz mono). 48 kbit/s wäre bei 16 kHz das Maximum, 64 lehnt AAC ab.
    static let trackRate = 16000.0
    static let trackBitRate = 32000
    /// Importierte Originale (Sprache, zum Anhören etwas mehr Bandbreite)
    static let importRate = 24000.0
    static let importBitRate = 48000
    /// Zwischenablage für die gerade entstehende Datei (versteckt → taucht in keiner Dateiliste auf)
    static let tempDirName = ".komprimieren"

    /// Komprimierte Fassung neben der WAV (ich.wav → ich.m4a)
    static func compressedURL(_ wav: URL) -> URL { wav.deletingPathExtension().appendingPathExtension("m4a") }

    /// Spur zum Lesen: die WAV, solange es sie gibt (Aufnahme, Auswertung, Umwandlung läuft gerade), sonst die .m4a.
    /// Gibt es keine von beiden, die WAV-Adresse (Lesen liefert dann wie bisher []).
    static func trackURL(_ wav: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: wav.path) { return wav }
        let c = compressedURL(wav)
        return fm.fileExists(atPath: c.path) ? c : wav
    }

    static func hasTrack(_ wav: URL) -> Bool { FileManager.default.fileExists(atPath: trackURL(wav).path) }

    struct Stats {
        var bytesBefore: Int64 = 0
        var bytesAfter: Int64 = 0
        var seconds: Double = 0
    }

    struct Failure: LocalizedError {
        let message: String
        /// Kein Fehler im eigentlichen Sinn (leere Spur, bringt keinen Platz) → nur leise protokollieren
        var quiet = false
        var errorDescription: String? { message }
    }

    static func size(_ u: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0 }

    /// Schritt 1+2: `src` nach AAC (.m4a, mono, `sampleRate`, `bitRate`) umwandeln und vollständig zurücklesen.
    /// Das Ergebnis liegt in `<ordner von src>/.komprimieren/<name>.m4a`; die Quelle wird nie angefasst.
    static func encodeVerified(_ src: URL, sampleRate: Double, bitRate: Int, minSaving: Double = 0.1) throws -> (tmp: URL, stats: Stats) {
        let fm = FileManager.default
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: src) } catch { throw Failure(message: "nicht lesbar (\(error.localizedDescription))") }
        let inFmt = input.processingFormat
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw Failure(message: "kein Tonformat") }
        // Leere Spur (z. B. Systemton nicht erlaubt, oder Kopf nach einem Absturz nie geschrieben) → bleibt, wie sie ist
        guard input.length > 0 else { throw Failure(message: "leer", quiet: true) }
        let srcSeconds = Double(input.length) / inFmt.sampleRate

        let dir = src.deletingLastPathComponent().appendingPathComponent(tempDirName, isDirectory: true)
        // nicht mit anlegen, falls der Meeting-Ordner inzwischen gelöscht wurde (Aufräumen nach Frist)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard fm.fileExists(atPath: dir.path) else { throw Failure(message: "Ordner nicht beschreibbar") }
        let tmp = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".m4a")
        try? fm.removeItem(at: tmp)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: tmp); removeDirIfEmpty(dir) } }

        // 1) Umwandeln (in Blöcken – auch eine 3-h-Spur braucht nur ein paar MB)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate]
        var energyIn = 0.0, framesIn = 0
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let outFmt = out.processingFormat
            let chunk: AVAudioFrameCount = 1 << 15
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk) else { throw Failure(message: "kein Puffer") }
            if inFmt.sampleRate == outFmt.sampleRate, inFmt.channelCount == 1, inFmt.commonFormat == .pcmFormatFloat32, !inFmt.isInterleaved {
                // Meeting-Spur: schon 16 kHz mono → Samples unverändert in den Kodierer (kein Umrechnen, Länge exakt)
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunk) else { throw Failure(message: "kein Puffer") }
                while input.framePosition < input.length {
                    let want = AVAudioFrameCount(min(Int64(chunk), input.length - input.framePosition))
                    try input.read(into: inBuf, frameCount: want)
                    if inBuf.frameLength == 0 { break }
                    outBuf.frameLength = inBuf.frameLength
                    outBuf.floatChannelData![0].update(from: inBuf.floatChannelData![0], count: Int(inBuf.frameLength))
                    energyIn += energy(outBuf); framesIn += Int(outBuf.frameLength)
                    try out.write(from: outBuf)
                }
            } else {
                // Import: Abtastrate + Kanäle angleichen (wie AudioDecoder)
                guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw Failure(message: "kein Umwandler") }
                conv.downmix = true
                conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
                let outCap = AVAudioFrameCount(Double(chunk) * sampleRate / inFmt.sampleRate) + 1024
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { throw Failure(message: "kein Puffer") }
                var eof = false
                var readError: Error?
                while true {
                    outBuf.frameLength = 0
                    var convErr: NSError?
                    let status = conv.convert(to: outBuf, error: &convErr) { _, st in
                        if eof || input.framePosition >= input.length { eof = true; st.pointee = .endOfStream; return nil }
                        let want = AVAudioFrameCount(min(Int64(chunk), input.length - input.framePosition))
                        do { try input.read(into: inBuf, frameCount: want) } catch { readError = error; eof = true; st.pointee = .endOfStream; return nil }
                        if inBuf.frameLength == 0 { eof = true; st.pointee = .endOfStream; return nil }
                        st.pointee = .haveData
                        return inBuf
                    }
                    if let convErr { throw convErr }
                    if let readError { throw readError }   // kaputter Rest → lieber das Original behalten
                    if outBuf.frameLength > 0 {
                        energyIn += energy(outBuf); framesIn += Int(outBuf.frameLength)
                        try out.write(from: outBuf)
                    }
                    if status == .endOfStream || status == .error { break }
                    if eof && outBuf.frameLength == 0 { break }
                }
            }
            out.close()
        } catch let f as Failure { throw f }
        catch { throw Failure(message: "Umwandeln fehlgeschlagen (\(error.localizedDescription))") }

        // 2) Prüfen: komplett dekodieren, Länge und Lautstärke vergleichen
        let check: AVAudioFile
        do { check = try AVAudioFile(forReading: tmp, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw Failure(message: "Ergebnis nicht lesbar (\(error.localizedDescription))") }
        guard check.processingFormat.sampleRate == sampleRate, check.processingFormat.channelCount == 1 else {
            throw Failure(message: "Ergebnis hat das falsche Format (\(check.processingFormat))")
        }
        let dstSeconds = Double(check.length) / sampleRate
        guard abs(dstSeconds - srcSeconds) <= 0.5 else {
            throw Failure(message: String(format: "Länge passt nicht (%.2f s statt %.2f s)", dstSeconds, srcSeconds))
        }
        var energyOut = 0.0, framesOut = 0
        do {
            let chunk: AVAudioFrameCount = 1 << 16
            guard let buf = AVAudioPCMBuffer(pcmFormat: check.processingFormat, frameCapacity: chunk) else { throw Failure(message: "kein Puffer") }
            while check.framePosition < check.length {
                let want = AVAudioFrameCount(min(Int64(chunk), check.length - check.framePosition))
                try check.read(into: buf, frameCount: want)
                if buf.frameLength == 0 { break }
                energyOut += energy(buf); framesOut += Int(buf.frameLength)
            }
        } catch let f as Failure { throw f }
        catch { throw Failure(message: "Ergebnis nicht vollständig lesbar (\(error.localizedDescription))") }
        guard abs(Double(framesOut) / sampleRate - srcSeconds) <= 0.5 else {
            throw Failure(message: String(format: "nur %.2f von %.2f s lesbar", Double(framesOut) / sampleRate, srcSeconds))
        }
        let rmsIn = sqrt(energyIn / Double(max(framesIn, 1))), rmsOut = sqrt(energyOut / Double(max(framesOut, 1)))
        // AAC schneidet nur Höhen ab (Rauschen: −3 % Energie) – stummes oder übersteuertes Ergebnis wäre ein Fehler
        if rmsIn > 0.001, !(rmsOut > rmsIn * 0.5 && rmsOut < rmsIn * 2) {
            throw Failure(message: String(format: "Lautstärke weicht ab (%.4f statt %.4f)", rmsOut, rmsIn))
        }
        let st = Stats(bytesBefore: size(src), bytesAfter: size(tmp), seconds: srcSeconds)
        guard st.bytesAfter > 0, Double(st.bytesAfter) <= Double(st.bytesBefore) * (1 - minSaving) else {
            throw Failure(message: "bringt keinen Platz (\(st.bytesBefore) → \(st.bytesAfter) Byte)", quiet: true)
        }
        keep = true
        return (tmp, st)
    }

    /// Schritt 3: geprüfte Zwischendatei an den Platz `dst`, dann `src` löschen.
    /// `gate` wird kurz vor dem Löschen der Quelle gefragt (z. B. „Meeting noch fertig?“, import.json umstellen);
    /// sagt es nein, wird `dst` wieder entfernt und die Quelle bleibt. Liefert true, wenn umgestellt wurde.
    @discardableResult
    static func commit(tmp: URL, src: URL, dst: URL, gate: () -> Bool = { true }) throws -> Bool {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tmp); removeDirIfEmpty(tmp.deletingLastPathComponent()) }
        if src.standardizedFileURL.path == dst.standardizedFileURL.path {
            // gleicher Name (Import war schon .m4a, aber groß): erst fragen, dann in einem Schritt ersetzen
            guard gate() else { return false }
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
            chmod(dst.path, 0o600)
            return true
        }
        // Rest eines abgebrochenen Laufs (Quelle war noch da) → wird ersetzt
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: tmp, to: dst)
        chmod(dst.path, 0o600)
        guard (try? AVAudioFile(forReading: dst))?.length ?? 0 > 0, gate() else {
            try? fm.removeItem(at: dst)
            return false
        }
        try fm.removeItem(at: src)
        return true
    }

    /// Umwandeln + prüfen + umstellen in einem (Meeting-Spuren, Test).
    @discardableResult
    static func compress(_ src: URL, to dst: URL, sampleRate: Double, bitRate: Int, minSaving: Double = 0.1,
                         gate: () -> Bool = { true }) throws -> Stats {
        let (tmp, st) = try encodeVerified(src, sampleRate: sampleRate, bitRate: bitRate, minSaving: minSaving)
        guard try commit(tmp: tmp, src: src, dst: dst, gate: gate) else {
            throw Failure(message: "wird gerade gebraucht – später", quiet: true)
        }
        return st
    }

    struct Report {
        var done = 0, failed = 0
        var before: Int64 = 0, after: Int64 = 0
    }

    /// Beide Spuren eines Meetings, nacheinander. `stillAllowed` wird vor jeder Datei und vor dem Löschen gefragt.
    @discardableResult
    static func compressTracks(of m: Meeting, stillAllowed: () -> Bool = { true }) -> Report {
        var r = Report()
        for wav in [m.systemURL, m.micURL] where FileManager.default.fileExists(atPath: wav.path) {
            guard stillAllowed() else { break }
            let t0 = Date()
            do {
                let st = try compress(wav, to: compressedURL(wav), sampleRate: trackRate, bitRate: trackBitRate, gate: stillAllowed)
                r.done += 1; r.before += st.bytesBefore; r.after += st.bytesAfter
                log(String(format: "Meeting-Ton %@: %@ %.1f MB → %@ %.1f MB (%.0f s Ton, %.1f s)", m.id, wav.lastPathComponent,
                           Double(st.bytesBefore) / 1_048_576, compressedURL(wav).lastPathComponent, Double(st.bytesAfter) / 1_048_576,
                           st.seconds, Date().timeIntervalSince(t0)))
            } catch let f as Failure where f.quiet {
                continue
            } catch {
                r.failed += 1
                log("Meeting-Ton \(m.id): \(wav.lastPathComponent) bleibt als WAV – \(error.localizedDescription)")
            }
        }
        return r
    }

    /// Von Flow übernommene Importdatei → original.m4a. `stillAllowed` wird kurz vor dem Umstellen gefragt (Notiz nicht
    /// wieder in Arbeit?); `setSource` stellt import.json auf die neue Datei um – vor dem Löschen der Quelle.
    @discardableResult
    static func compressImportOriginal(_ src: URL, stillAllowed: () -> Bool, setSource: (URL) -> Void) -> Stats? {
        // Schon kompakt (z. B. Sprachnachricht als Opus, AAC ≤ 72 kbit/s, unsere eigene original.m4a) → nicht anfassen
        if let f = try? AVAudioFile(forReading: src), f.length > 0, f.fileFormat.sampleRate > 0 {
            let secs = Double(f.length) / f.fileFormat.sampleRate
            if Double(size(src)) * 8 / max(secs, 0.1) <= Double(importBitRate) * 1.5 { return nil }
        }
        let dst = src.deletingLastPathComponent().appendingPathComponent("original.m4a")
        let t0 = Date()
        do {
            let (tmp, st) = try encodeVerified(src, sampleRate: importRate, bitRate: importBitRate)
            let ok = try commit(tmp: tmp, src: src, dst: dst, gate: {
                guard stillAllowed() else { return false }
                setSource(dst)
                return true
            })
            guard ok else { return nil }
            log(String(format: "Import-Original %@ %.1f MB → original.m4a %.1f MB (%.0f s Ton, %.1f s)", src.lastPathComponent,
                       Double(st.bytesBefore) / 1_048_576, Double(st.bytesAfter) / 1_048_576, st.seconds, Date().timeIntervalSince(t0)))
            return st
        } catch let f as Failure where f.quiet {
            return nil
        } catch {
            log("Import-Original \(src.deletingLastPathComponent().lastPathComponent)/\(src.lastPathComponent) bleibt – \(error.localizedDescription)")
            return nil
        }
    }

    /// Reste abgebrochener Umwandlungen (App beendet mitten im Schreiben) – nur die Zwischenablage, nie Spuren
    static func removeLeftovers() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            let t = d.appendingPathComponent(tempDirName, isDirectory: true)
            if FileManager.default.fileExists(atPath: t.path) { try? FileManager.default.removeItem(at: t) }
        }
    }

    private static func removeDirIfEmpty(_ d: URL) {
        if ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? ["?"]).isEmpty { try? FileManager.default.removeItem(at: d) }
    }

    private static func energy(_ b: AVAudioPCMBuffer) -> Double {
        guard let ch = b.floatChannelData else { return 0 }
        let p = ch[0]
        var e = 0.0
        for i in 0..<Int(b.frameLength) { let x = Double(p[i]); e += x * x }
        return e
    }
}

extension Meeting {
    /// Mikrofon-Spur zum Lesen (ich.wav oder, nach dem Komprimieren, ich.m4a)
    var micTrack: URL { MeetingAudio.trackURL(micURL) }
    /// Systemton-Spur zum Lesen (andere.wav oder andere.m4a)
    var systemTrack: URL { MeetingAudio.trackURL(systemURL) }
}

// MARK: - Hintergrund: eine Datei nach der anderen, niedrigste Priorität, nie auf dem Main-Thread

final class MeetingAudioCompressor {
    static let shared = MeetingAudioCompressor()
    private let queue = DispatchQueue(label: "flow.meeting.audio", qos: .background)
    private init() {}

    /// Nach der Auswertung (Transkript gespeichert): Spuren bzw. übernommenes Import-Original komprimieren
    func enqueue(_ id: String) {
        queue.async { Self.run(id) }
    }

    /// Beim App-Start: vorhandene Meetings nach `seconds` umwandeln (eins nach dem anderen; laufende werden übersprungen)
    func scheduleMigration(after seconds: Double = 60) {
        queue.asyncAfter(deadline: .now() + seconds) {
            MeetingAudio.removeLeftovers()
            let ids = Self.onMain { MeetingStore.shared.meetings.filter { $0.status == .done }.map(\.id) }
            var r = MeetingAudio.Report()
            for id in ids {
                let one = Self.run(id)
                r.done += one.done; r.failed += one.failed; r.before += one.before; r.after += one.after
            }
            if r.done > 0 || r.failed > 0 {
                log(String(format: "Meeting-Ton: %d Datei(en) komprimiert, %.0f MB → %.0f MB%@", r.done,
                           Double(r.before) / 1_048_576, Double(r.after) / 1_048_576, r.failed > 0 ? " (\(r.failed) bleiben unverändert)" : ""))
            }
        }
    }

    /// Ruft `done` auf dem Main-Thread, sobald alles bisher Eingereihte erledigt ist (Test)
    func whenIdle(_ done: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: done) }
    }

    @discardableResult
    private static func run(_ id: String) -> MeetingAudio.Report {
        var r = MeetingAudio.Report()
        if onMain({ AudioImport.isFileNote(id) }) {
            guard let src = onMain({ ownedOriginal(id) }) else { return r }
            let st = MeetingAudio.compressImportOriginal(src, stillAllowed: { onMain { ownedOriginal(id) == src } }, setSource: { dst in
                onMain {
                    guard var j = AudioImportFiles.loadJob(id) else { return }
                    j.source = dst.path
                    AudioImportFiles.saveJob(j)
                }
            })
            if let st { r.done += 1; r.before += st.bytesBefore; r.after += st.bytesAfter }
            return r
        }
        guard let m = onMain({ doneMeeting(id) }) else { return r }
        return MeetingAudio.compressTracks(of: m, stillAllowed: { onMain { doneMeeting(id) != nil } })
    }

    /// Nur fertige Meetings (Transkript gespeichert) – nichts, was gerade aufnimmt, ausgewertet wird oder unterbrochen ist
    private static func doneMeeting(_ id: String) -> Meeting? {
        guard let m = MeetingStore.shared.meeting(id), m.status == .done else { return nil }
        return m
    }

    /// Übernommene Importdatei (original.<ext> im Notiz-Ordner), fertig ausgewertet, kein Video – sonst nil
    private static func ownedOriginal(_ id: String) -> URL? {
        guard doneMeeting(id) != nil, let j = AudioImportFiles.loadJob(id), j.ownedCopy == true,
              j.phase == .done || j.phase == .summarizing,
              AudioImport.shared.runningID != id, !AudioImport.shared.waiting.contains(id) else { return nil }
        let src = j.sourceURL
        guard AudioDropReader.isInside(src.path, AudioImportFiles.folder(id)), src.lastPathComponent.hasPrefix("original."),
              !AudioImportFormats.isVideo(src.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: src.path) else { return nil }
        return src
    }

    private static func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }
}
