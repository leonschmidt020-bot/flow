import AVFoundation
import FluidAudio
import Foundation

// MARK: - Dekodieren: jede Audio-/Videodatei → 16 kHz mono Int16 (roh) im Notiz-Ordner
//
// Reihenfolge (gemessen auf macOS 26, siehe Bericht):
//  1. AVAudioFile (AudioToolbox) – liest mp3, m4a, wav, aiff, caf, aac, flac, Ogg Vorbis, Ogg Opus (WhatsApp!), mp4/mov-Tonspur
//  2. AVAssetReader – Videos/Container, die AVAudioFile nicht öffnet
//  3. ffmpeg aus Homebrew (nur falls installiert) – webm, mkv, wma …
// Gestreamt in Blöcken: auch eine 3-h-Datei braucht beim Dekodieren nur ein paar MB.

struct AudioImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static let cancelled = AudioImportError(message: "Abgebrochen")
}

enum AudioDecoder {
    static let sampleRate = 16000.0

    /// Dauer ohne Dekodieren (für die Anzeige vorab). nil = unbekannt.
    static func probeDuration(_ url: URL) -> Double? {
        if let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0, f.length > 0 {
            return Double(f.length) / f.fileFormat.sampleRate
        }
        return nil
    }

    struct Result { let seconds: Double; let decoder: String }

    /// Dekodiert `url` nach `out` (roh, Int16 LE, 16 kHz mono). `progress` 0…1, `cancelled` wird zwischendurch abgefragt.
    static func decode(_ url: URL, to out: URL, progress: @escaping (Double) -> Void = { _ in },
                       cancelled: @escaping () -> Bool = { false }) throws -> Result {
        let fm = FileManager.default
        let name = url.lastPathComponent
        guard fm.fileExists(atPath: url.path) else { throw AudioImportError(message: "„\(name)“ ist nicht mehr da – verschoben oder gelöscht?") }
        guard fm.isReadableFile(atPath: url.path) else {
            throw AudioImportError(message: "Kein Zugriff auf „\(name)“. Zieh die Datei direkt auf Flow oder erlaube den Ordner in den Systemeinstellungen → Datenschutz → Dateien und Ordner.")
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if size == 0 { throw AudioImportError(message: "„\(name)“ ist leer (0 Byte).") }

        var errors: [String] = []
        var sawNoTrack = false
        // 1) AVAudioFile
        do {
            let s = try decodeAudioFile(url, to: out, progress: progress, cancelled: cancelled)
            if s >= 0.3 { return Result(seconds: s, decoder: "AVAudioFile") }
            errors.append("AVAudioFile: nur \(String(format: "%.2f", s)) s")
        } catch let e as AudioImportError where e.message == AudioImportError.cancelled.message { throw e }
        catch { errors.append("AVAudioFile: \(error.localizedDescription)") }
        // 2) AVAssetReader
        do {
            let s = try decodeAssetReader(url, to: out, progress: progress, cancelled: cancelled)
            if s >= 0.3 { return Result(seconds: s, decoder: "AVAssetReader") }
            errors.append("AVAssetReader: nur \(String(format: "%.2f", s)) s")
        } catch let e as AudioImportError where e.message == AudioImportError.cancelled.message { throw e }
        catch let e as AudioImportError where e.message == "keine Tonspur" { sawNoTrack = true; errors.append("AVAssetReader: keine Tonspur") }
        catch { errors.append("AVAssetReader: \(error.localizedDescription)") }
        // 3) ffmpeg (optional)
        if let ff = AudioImportFormats.ffmpeg {
            do {
                let s = try decodeFFmpeg(ff, url, to: out, progress: progress, cancelled: cancelled)
                if s >= 0.3 { return Result(seconds: s, decoder: "ffmpeg") }
                errors.append("ffmpeg: nur \(String(format: "%.2f", s)) s")
            } catch let e as AudioImportError where e.message == AudioImportError.cancelled.message { throw e }
            catch { errors.append("ffmpeg: \(error.localizedDescription)") }
        }
        try? fm.removeItem(at: out)
        log("Audiodatei nicht lesbar (\(url.pathExtension)): " + errors.joined(separator: " · "))
        let ext = url.pathExtension.lowercased()
        if sawNoTrack {
            throw AudioImportError(message: "„\(name)“ hat keine Tonspur – im Video ist nichts zu hören.")
        }
        if AudioImportFormats.ffmpegOnly.contains(ext) && AudioImportFormats.ffmpeg == nil {
            throw AudioImportError(message: "Das Format .\(ext) kann macOS nicht selbst lesen. Mit ffmpeg geht es („brew install ffmpeg“) – oder die Datei vorher als MP3/M4A sichern.")
        }
        throw AudioImportError(message: "„\(name)“ ist beschädigt oder kein Audio – nicht lesbar.")
    }

    // MARK: 1) AVAudioFile + AVAudioConverter

    private static func decodeAudioFile(_ url: URL, to out: URL, progress: (Double) -> Void, cancelled: () -> Bool) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw AudioImportError(message: "kein Tonformat") }
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw AudioImportError(message: "kein Umwandler") }
        conv.downmix = true
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let total = max(Double(file.length), 1)
        let inCap: AVAudioFrameCount = 65536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap) else { throw AudioImportError(message: "kein Puffer") }
        let outCap = AVAudioFrameCount(Double(inCap) * sampleRate / inFmt.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { throw AudioImportError(message: "kein Puffer") }
        let writer = try PCMWriter(out)
        defer { writer.close() }
        var read: Double = 0
        var eof = false
        var readError: Error?
        var lastReport = Date.distantPast
        while true {
            if cancelled() { throw AudioImportError.cancelled }
            outBuf.frameLength = 0
            var convErr: NSError?
            let status = conv.convert(to: outBuf, error: &convErr) { _, outStatus in
                if eof { outStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf, frameCount: inCap)
                } catch {
                    // Ende oder kaputter Rest (z. B. abgeschnittene MP3) → was da ist, behalten
                    if inBuf.frameLength == 0 { readError = error }
                }
                if inBuf.frameLength == 0 { eof = true; outStatus.pointee = .endOfStream; return nil }
                read += Double(inBuf.frameLength)
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convErr { throw convErr }
            if outBuf.frameLength > 0, let ch = outBuf.floatChannelData?[0] {
                try writer.write(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
            }
            if Date().timeIntervalSince(lastReport) > 0.25 { lastReport = Date(); progress(min(1, read / total)) }
            if status == .endOfStream || status == .error { break }
            if eof && outBuf.frameLength == 0 { break }
        }
        _ = readError
        progress(1)
        return Double(writer.frames) / sampleRate
    }

    // MARK: 2) AVAssetReader (Video-Container)

    private static func decodeAssetReader(_ url: URL, to out: URL, progress: @escaping (Double) -> Void, cancelled: () -> Bool) throws -> Double {
        let asset = AVURLAsset(url: url)
        final class Box: @unchecked Sendable { var tracks: [AVAssetTrack] = []; var dur: Double = 0; var err: Error? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.tracks = try await asset.loadTracks(withMediaType: .audio)
                box.dur = try await asset.load(.duration).seconds
            } catch { box.err = error }
            sem.signal()
        }
        sem.wait()
        if let e = box.err { throw e }
        guard let track = box.tracks.first else { throw AudioImportError(message: "keine Tonspur") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioImportError(message: "startet nicht") }
        let writer = try PCMWriter(out)
        defer { writer.close() }
        var lastReport = Date.distantPast
        while let sb = output.copyNextSampleBuffer() {
            if cancelled() { reader.cancelReading(); throw AudioImportError.cancelled }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr,
               CMBlockBufferIsRangeContiguous(bb, atOffset: 0, length: len) {
                try writer.writeRaw(UnsafeRawBufferPointer(start: ptr, count: len))
            } else {
                var d = Data(count: len)
                d.withUnsafeMutableBytes { raw in _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: raw.baseAddress!) }
                try d.withUnsafeBytes { try writer.writeRaw($0) }
            }
            if box.dur > 0, Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date(); progress(min(1, Double(writer.frames) / sampleRate / box.dur))
            }
        }
        if reader.status == .failed { throw reader.error ?? AudioImportError(message: "Lesefehler") }
        progress(1)
        return Double(writer.frames) / sampleRate
    }

    // MARK: 3) ffmpeg (nur wenn per Homebrew vorhanden)

    private static func decodeFFmpeg(_ bin: String, _ url: URL, to out: URL, progress: (Double) -> Void, cancelled: () -> Bool) throws -> Double {
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-nostdin", "-v", "error", "-y", "-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", out.path]
        p.standardOutput = FileHandle.nullDevice
        // Audit 27.09.2026: stderr in eine Datei statt in eine Pipe, die erst nach dem Ende gelesen wurde – bei kaputten Dateien
        // schreibt ffmpeg pro Paket eine Zeile; nach 64 KB blockierte ffmpeg und die Import-Warteschlange hing für immer.
        let errURL = out.deletingLastPathComponent().appendingPathComponent(".ffmpeg-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else { throw AudioImportError(message: "ffmpeg-Protokoll nicht anlegbar") }
        defer { try? errHandle.close(); try? FileManager.default.removeItem(at: errURL) }
        p.standardError = errHandle
        try p.run()
        let expected = probeDuration(url) ?? 0
        let started = Date()
        let limit = max(300, expected * 2 + 120)   // Notbremse, falls ffmpeg hängt (Netzlaufwerk, kaputte Datei)
        while p.isRunning {
            if cancelled() { p.terminate(); throw AudioImportError.cancelled }
            if Date().timeIntervalSince(started) > limit { p.terminate(); throw AudioImportError(message: "ffmpeg reagiert nicht (Zeitlimit)") }
            if expected > 0, let sz = try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64 {
                progress(min(1, Double(sz) / 2 / sampleRate / expected))
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let msg = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw AudioImportError(message: String(msg.prefix(200))) }
        chmod(out.path, 0o600)
        let sz = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        progress(1)
        return Double(sz) / 2 / sampleRate
    }
}

/// Schreibt Float-Samples als Int16 LE (roh) – gepuffert.
final class PCMWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var frames: Int = 0

    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let h = try? FileHandle(forWritingTo: url) else { throw AudioImportError(message: "Zwischendatei nicht anlegbar") }
        try h.truncate(atOffset: 0)
        handle = h
        buffer.reserveCapacity(1 << 20)
    }

    func write(_ s: UnsafeBufferPointer<Float>) throws {
        var tmp = [Int16](repeating: 0, count: s.count)
        for i in 0..<s.count { tmp[i] = Int16(max(-1, min(1, s[i])) * 32767).littleEndian }
        tmp.withUnsafeBytes { buffer.append(contentsOf: $0) }
        frames += s.count
        if buffer.count >= 1 << 20 { try flush() }
    }

    func writeRaw(_ raw: UnsafeRawBufferPointer) throws {
        buffer.append(contentsOf: raw)
        frames += raw.count / 2
        if buffer.count >= 1 << 20 { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() { try? flush(); try? handle.close() }
}

/// Dekodierter Ton, per mmap eingeblendet (zählt nicht als „schmutziger“ Speicher) – Quelle für Sprechertrennung und Stücke.
final class PCMSource: AudioSampleSource, @unchecked Sendable {
    private let data: Data
    let sampleCount: Int

    init(_ url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        sampleCount = data.count / 2
    }

    var seconds: Double { Double(sampleCount) / AudioDecoder.sampleRate }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        // Wie FluidAudios Quellen: Bereich am Rand abschneiden, Rest bleibt unangetastet (kein Fehler)
        guard count > 0, sampleCount > 0 else { return }
        let start = max(0, offset)
        guard start < sampleCount else { return }
        let n = min(sampleCount - start, count)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self).baseAddress! + start
            for i in 0..<n { destination[i] = Float(Int16(littleEndian: p[i])) / 32768 }
        }
    }

    /// Ausschnitt in Sekunden als Float-Samples
    func samples(from start: Double, to end: Double) -> [Float] {
        let a = max(0, min(sampleCount, Int(start * AudioDecoder.sampleRate)))
        let b = max(a, min(sampleCount, Int(end * AudioDecoder.sampleRate)))
        var out = [Float](repeating: 0, count: b - a)
        out.withUnsafeMutableBufferPointer { try? copySamples(into: $0.baseAddress!, offset: a, count: b - a) }
        return out
    }

    /// Sprach-Sekunden (RMS > 0,01 in 30-ms-Fenstern) – wie MeetingProcessor.speechSeconds, aber ohne alles zu laden
    func speechSeconds() -> Double {
        let f = 480
        var n = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self).baseAddress!
            var i = 0
            while i + f <= sampleCount {
                var sum: Float = 0
                for j in i..<(i + f) { let x = Float(Int16(littleEndian: p[j])) / 32768; sum += x * x }
                if (sum / Float(f)).squareRoot() > 0.01 { n += 1 }
                i += f
            }
        }
        return Double(n * f) / AudioDecoder.sampleRate
    }
}
