import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            if uid.hasPrefix("CADefaultDeviceAggregate") || name.contains("Flow") { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> AudioDeviceID? { inputs().first { $0.uid == uid }?.id }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
}

/// Mikrofon-Aufnahme → 16 kHz mono Float32. Liefert Samples und einen Pegel (0…1) für die Wellenform.
final class MicCapture {
    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?

    // Alles, was die Engine betrifft, läuft ausschließlich auf `queue` (keine Wettläufe mehr zwischen Main, Tap und Neustart).
    private var engine: AVAudioEngine?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "flow.mic")
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private var configObserver: NSObjectProtocol?
    private var runningVP = false
    private var runningDevice: String?

    private let stateLock = NSLock()
    private var _isRunning = false
    private var _voiceProcessing = false
    /// Läuft die Engine gerade? (von jedem Thread lesbar)
    var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
    /// Apples Sprachverarbeitung (nur während Anrufen nötig). Wirkt beim nächsten Start.
    var voiceProcessing: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _voiceProcessing }
        set { stateLock.lock(); _voiceProcessing = newValue; stateLock.unlock() }
    }

    /// Während eines Anrufs: eigene, sanfte Verstärkung statt Apples Sprachverarbeitung.
    /// 28.09.2026 gemessen: Schaltet Flow die Sprachverarbeitung ein, bekommt eine Anruf-App OHNE sie (Teams) nur noch
    /// absolute Stille – im Meeting hat einen keiner gehört. Nutzt die Anruf-App selbst die Sprachverarbeitung, kommt
    /// unser normales Mikro dagegen etwa 30× leiser an. Deshalb: nie selbst einschalten, das leise Signal hier anheben.
    var callBoost: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _callBoost }
        set { stateLock.lock(); _callBoost = newValue; stateLock.unlock() }
    }
    private var _callBoost = false
    private var agc = CallAGC()

    init() { queue.setSpecific(key: onQueueKey, value: true) }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: onQueueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    /// Stellt (asynchron) sicher, dass das Mikro im gewünschten Zustand läuft. Mehrfachaufrufe schaden nicht:
    /// läuft es schon mit derselben Sprachverarbeitung und demselben Gerät, passiert nichts.
    func ensureRunning(deviceUID: String?, completion: ((Error?, TimeInterval, Bool) -> Void)? = nil) {
        let t0 = Date()
        let vp = voiceProcessing
        queue.async {
            var err: Error?
            var started = false
            if self.engine == nil || self.runningVP != vp || self.runningDevice != deviceUID {
                do { try self.startOnQueue(deviceUID: deviceUID, vp: vp); started = true } catch { err = error }
            }
            let dt = Date().timeIntervalSince(t0)
            if let completion { DispatchQueue.main.async { completion(err, dt, started) } }
        }
    }

    /// Asynchron stoppen. Ein danach eingereihtes `ensureRunning` startet wieder (Reihenfolge bleibt erhalten).
    func stopAsync() { queue.async { self.stopOnQueue() } }

    /// Synchron starten (Meeting). Wirft bei Fehler.
    func start(deviceUID: String?) throws {
        let vp = voiceProcessing
        try onQueue { try startOnQueue(deviceUID: deviceUID, vp: vp) }
    }

    func stop() { onQueue { stopOnQueue() } }

    private func startOnQueue(deviceUID: String?, vp: Bool) throws {
        stopOnQueue()
        let eng = AVAudioEngine()
        let input = eng.inputNode
        if let uid = deviceUID, var dev = AudioDevices.device(uid: uid), let au = input.audioUnit {
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { log("Mikrofon \(uid) nicht setzbar: \(st)") }
        }
        if vp {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Andere Apps (Musik, YouTube) NICHT leiser machen
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                // Keine automatische Verstärkung: die würde leise Hintergrund-Stimmen (Video, Bruder) hochziehen
                input.isVoiceProcessingAGCEnabled = false
                // Achtung: mainMixerNode NICHT anfassen – sonst schlägt der Start mit -10875 fehl.
            } catch {
                log("Sprachverarbeitung nicht verfügbar: \(error)")
            }
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0, let conv = AVAudioConverter(from: fmt, to: target) else {
            throw NSError(domain: "Flow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon verfügbar"])
        }
        // Sprachverarbeitung liefert mehrere Kanäle – nur Kanal 0 ist die bereinigte Stimme.
        if fmt.channelCount > 1 { conv.channelMap = [0] }
        // Konverter lokal festhalten: der Tap-Thread greift nie auf geteilten Zustand zu
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.process(buf, conv)
        }
        eng.prepare()
        try eng.start()
        engine = eng
        runningVP = vp
        runningDevice = deviceUID
        stateLock.lock(); _isRunning = true; stateLock.unlock()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng,
                                                                queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.engine === eng else { return }   // alte Engine – schon ersetzt
                log("Audio-Konfiguration geändert → Mikrofon neu starten")
                try? self.startOnQueue(deviceUID: self.runningDevice, vp: self.runningVP)
            }
        }
    }

    private func stopOnQueue() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        stateLock.lock(); _isRunning = false; stateLock.unlock()
    }

    private func process(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter) {
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        var samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        if callBoost { agc.apply(&samples) } else { agc.reset() }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(samples.count))
        // -55 dB … -12 dB → 0 … 1
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(1, max(0, (db + 55) / 43))
        onSamples?(samples)
        onLevel?(level)
    }
}

/// Einfacher, thread-sicherer Sample-Puffer.
final class SampleBuffer {
    private var data: [Float] = []
    private let lock = NSLock()
    func append(_ s: [Float]) { lock.lock(); data.append(contentsOf: s); lock.unlock() }
    func take() -> [Float] { lock.lock(); defer { data = []; lock.unlock() }; return data }
    var count: Int { lock.lock(); defer { lock.unlock() }; return data.count }
    func snapshot(from: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return from < data.count ? Array(data[from...]) : []
    }
    func reset() { lock.lock(); data = []; lock.unlock() }
}

/// Einfache automatische Verstärkung für Anrufe: Ziel-Spitze 0,3, höchstens 30-fach, schneller Rückgang bei lauten
/// Stellen (kein Übersteuern), langsamer Anstieg. Leises Grundrauschen (Spitze unter 0,0015) wird nicht hochgezogen.
struct CallAGC {
    private var envelope: Float = 0
    private var gain: Float = 1
    /// Grundrauschen (RMS): fällt sofort, steigt langsam – begrenzt die Verstärkung, damit Raumrauschen nicht
    /// zur „Sprache“ wird (28.09.: Median der Spur lag sonst bei 0,019)
    private var noise: Float = 0.001

    mutating func reset() { envelope = 0; gain = 1; noise = 0.001 }

    mutating func apply(_ s: inout [Float]) {
        var pk: Float = 0, sum: Float = 0
        for v in s { pk = max(pk, abs(v)); sum += v * v }
        let rms = s.isEmpty ? 0 : (sum / Float(s.count)).squareRoot()
        noise = rms < noise ? max(rms, 0.00005) : noise * 1.002
        // Hüllkurve: steigt sofort, fällt über ~2 s ab (Puffer ≈ 64 ms bei 16 kHz)
        envelope = pk > envelope ? pk : envelope * 0.97 + pk * 0.03
        let noiseCap = max(1, 0.004 / noise)   // Rauschen höchstens auf ~0,004 RMS anheben
        let want: Float = envelope < 0.0015 ? 1 : min(30, noiseCap, max(1, 0.3 / envelope))
        // Verstärkung: runter sofort, hoch langsam (≈ 1 s bis zum Ziel)
        gain = want < gain ? want : gain + (want - gain) * 0.06
        guard gain > 1.01 else { return }
        for i in s.indices { s[i] = max(-1, min(1, s[i] * gain)) }
    }
}
