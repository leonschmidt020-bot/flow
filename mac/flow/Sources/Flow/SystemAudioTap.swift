import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// Captures everything the Mac plays (i.e. the other meeting participants) via a
// Core Audio process tap (macOS 14.2+). No Screen Recording permission needed;
// the first start triggers the "System Audio Recording" TCC prompt
// (NSAudioCaptureUsageDescription). Without permission the tap delivers silence.
//
// Structure adapted from insidegui/AudioCap (BSD-2) and openwhispr's
// macos-audio-tap.swift (MIT).

final class SystemAudioTap {

    // MARK: Errors

    enum TapError: LocalizedError {
        case alreadyRunning
        case createTapFailed(OSStatus)
        case readTapFormatFailed(OSStatus)
        case unsupportedTapFormat(String)
        case readTapUIDFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case converterFailed(String)
        case createIOProcFailed(OSStatus)
        case startDeviceFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "System-Audio-Aufnahme läuft bereits."
            case .createTapFailed(let s) where s == noErr:
                return "System-Audio-Tap konnte nicht erstellt werden (ungültige Tap-ID). Wird automatisch erneut versucht."
            case .createTapFailed(let s):
                return "System-Audio-Tap konnte nicht erstellt werden (\(SystemAudioTap.describe(s))). Ist die Berechtigung „Systemaudio-Aufnahme“ erteilt?"
            case .readTapFormatFailed(let s):
                return "Audioformat des System-Taps konnte nicht gelesen werden (\(SystemAudioTap.describe(s)))."
            case .unsupportedTapFormat(let d):
                return "Nicht unterstütztes Audioformat des System-Taps: \(d)"
            case .readTapUIDFailed(let s):
                return "UID des System-Taps konnte nicht gelesen werden (\(SystemAudioTap.describe(s)))."
            case .createAggregateFailed(let s):
                return "Privates Aggregat-Gerät für den System-Tap konnte nicht erstellt werden (\(SystemAudioTap.describe(s)))."
            case .converterFailed(let d):
                return "Audio-Konverter (→ 16 kHz mono) konnte nicht erstellt werden: \(d)"
            case .createIOProcFailed(let s):
                return "IO-Callback für den System-Tap konnte nicht registriert werden (\(SystemAudioTap.describe(s)))."
            case .startDeviceFailed(let s):
                return "System-Audio-Aufnahme konnte nicht gestartet werden (\(SystemAudioTap.describe(s))). Ist die Berechtigung „Systemaudio-Aufnahme“ erteilt?"
            }
        }
    }

    // MARK: Public

    init() {
        ioQueue.setSpecific(key: ioQueueKey, value: ())
    }

    deinit {
        // Listeners/IOProc hold only weak references, so deinit can run; tear down synchronously.
        teardownAll(flush: false)
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    /// Starts capturing system audio. `onSamples` is called on a private serial queue with 16 kHz mono Float32 chunks.
    func start(onSamples: @escaping ([Float]) -> Void) throws {
        try controlQueue.sync {
            guard !isRunning else { throw TapError.alreadyRunning }
            ioQueue.sync {
                self.sink = onSamples
                self.pending.removeAll(keepingCapacity: true)
            }
            do {
                noteIO()
                session = try Session.make(owner: self, ioQueue: ioQueue)
            } catch {
                ioQueue.sync { self.sink = nil }
                throw error
            }
            installSystemListener()
            setRunning(true)
            startWatchdog()
        }
    }

    func stop() {
        setRunning(false)
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            // Called from inside onSamples: stopping the device synchronously from its own
            // IO queue would deadlock, so tear down asynchronously.
            controlQueue.async { [weak self] in self?.teardownAll(flush: true) }
        } else {
            controlQueue.sync { teardownAll(flush: true) }
        }
    }

    // MARK: Configuration

    private static let targetSampleRate: Double = 16_000
    /// Delivered chunk size: 100 ms at 16 kHz.
    private static let chunkSamples = 1_600

    // MARK: State

    private let controlQueue = DispatchQueue(label: "flow.systemaudiotap.control")
    private let ioQueue = DispatchQueue(label: "flow.systemaudiotap.io", qos: .userInitiated)
    private let ioQueueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private var running = false                 // guarded by stateLock

    // controlQueue-confined
    private var session: Session?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var watchdog: DispatchSourceTimer?
    private var nextRetry = Date.distantPast
    private var rebuildAttempts = 0
    private var lastIO = Date()                 // guarded by stateLock

    // ioQueue-confined
    private var sink: (([Float]) -> Void)?
    private var pending: [Float] = []

    private func setRunning(_ value: Bool) {
        stateLock.lock(); running = value; stateLock.unlock()
    }

    // MARK: Teardown

    /// controlQueue (or deinit).
    private func teardownAll(flush: Bool) {
        watchdog?.cancel()
        watchdog = nil
        removeSystemListener()
        session?.invalidate()
        session = nil
        // All IO blocks for the destroyed IOProc have completed or will find no sink.
        let drain = {
            if flush, let sink = self.sink, !self.pending.isEmpty {
                let rest = self.pending
                self.pending.removeAll()
                sink(rest)
            }
            self.pending.removeAll()
            self.sink = nil
        }
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil { drain() } else { ioQueue.sync(execute: drain) }
    }

    // MARK: Device-change handling

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func installSystemListener() {
        guard systemListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceEvent("Standard-Ausgabegerät geändert")
        }
        var address = Self.defaultOutputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        if status == noErr {
            systemListener = block
        } else {
            NSLog("[SystemAudioTap] Listener für Ausgabegerät nicht installierbar: %@", Self.describe(status))
        }
    }

    private func removeSystemListener() {
        guard let block = systemListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        systemListener = nil
    }

    /// Called on controlQueue (listener blocks are delivered there).
    ///
    /// Measured: the tap-only aggregate keeps delivering transparently when the default output
    /// switches (speakers ⇄ Bluetooth), whereas destroying/recreating it during the switch fails
    /// once (tap ID 0) and then delivers sparse data while the route settles. So a route change
    /// only triggers a health check; the session is rebuilt only if audio actually stalls.
    fileprivate func deviceEvent(_ reason: String) {
        guard isRunning else { return }
        controlQueue.asyncAfter(deadline: .now() + Self.stallTimeout) { [weak self] in
            self?.checkHealth(trigger: reason)
        }
    }

    private static let stallTimeout: TimeInterval = 2.5

    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.checkHealth(trigger: nil) }
        t.resume()
        watchdog = t
    }

    fileprivate func noteIO() {
        stateLock.lock(); lastIO = Date(); stateLock.unlock()
    }

    private func checkHealth(trigger: String?) {
        guard isRunning else { return }
        if session == nil {
            guard Date() >= nextRetry else { return }
            rebuild(reason: trigger ?? "Neuer Versuch nach Fehler")
            return
        }
        stateLock.lock(); let silentFor = Date().timeIntervalSince(lastIO); stateLock.unlock()
        if silentFor > Self.stallTimeout {
            rebuild(reason: (trigger.map { $0 + ", " } ?? "") + String(format: "keine Audiodaten seit %.1f s", silentFor))
        }
    }

    fileprivate func rebuild(reason: String) {
        guard isRunning else { return }
        session?.invalidate()
        session = nil
        noteIO() // grace period for the new session
        do {
            session = try Session.make(owner: self, ioQueue: ioQueue)
            rebuildAttempts = 0
            NSLog("[SystemAudioTap] Neu aufgebaut (%@).", reason)
        } catch {
            rebuildAttempts += 1
            // Device may be mid-switch (e.g. Bluetooth connecting): the watchdog retries with backoff.
            nextRetry = Date().addingTimeInterval(min(10, 0.5 * Double(rebuildAttempts)))
            NSLog("[SystemAudioTap] Neuaufbau fehlgeschlagen (Versuch %d): %@", rebuildAttempts, error.localizedDescription)
        }
    }

    // MARK: Sample delivery (ioQueue)

    fileprivate func deliver(_ samples: UnsafeBufferPointer<Float>) {
        guard let sink else { return }
        pending.append(contentsOf: samples)
        let n = Self.chunkSamples
        guard pending.count >= n else { return }
        var offset = 0
        while pending.count - offset >= n {
            sink(Array(pending[offset ..< offset + n]))
            offset += n
        }
        pending.removeFirst(offset)
    }

    // MARK: - Session (one tap + aggregate device + IOProc)

    private final class Session {
        private var tapID = AudioObjectID(kAudioObjectUnknown)
        private var aggregateID = AudioObjectID(kAudioObjectUnknown)
        private var procID: AudioDeviceIOProcID?
        private var formatListener: AudioObjectPropertyListenerBlock?
        private weak var owner: SystemAudioTap?
        private let controlQueue: DispatchQueue

        // ioQueue-confined
        private var converter: AVAudioConverter?
        private var sourceFormat: AVAudioFormat?
        private var outputFormat: AVAudioFormat?
        private var invalidated = false
        private let invalidLock = NSLock()

        private init(owner: SystemAudioTap) {
            self.owner = owner
            self.controlQueue = owner.controlQueue
        }

        static func make(owner: SystemAudioTap, ioQueue: DispatchQueue) throws -> Session {
            let s = Session(owner: owner)
            do {
                try s.build(ioQueue: ioQueue)
            } catch {
                s.invalidate()
                throw error
            }
            return s
        }

        private func build(ioQueue: DispatchQueue) throws {
            // 1. Global mono tap, excluding our own process (our own sounds are not "the meeting").
            var excluded: [AudioObjectID] = []
            if let own = SystemAudioTap.ownProcessObjectID() { excluded.append(own) }
            let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            desc.name = "Flow System Audio"
            desc.uuid = UUID()
            desc.isPrivate = true
            desc.muteBehavior = .unmuted

            var newTap = AudioObjectID(kAudioObjectUnknown)
            var status = AudioHardwareCreateProcessTap(desc, &newTap)
            // Rarely the HAL returns noErr with tap ID 0 right after a previous tap was torn down.
            var retries = 0
            while status == noErr, newTap == kAudioObjectUnknown, retries < 3 {
                retries += 1
                Thread.sleep(forTimeInterval: 0.15)
                status = AudioHardwareCreateProcessTap(desc, &newTap)
            }
            guard status == noErr, newTap != kAudioObjectUnknown else { throw TapError.createTapFailed(status) }
            tapID = newTap

            // 2. Stream format of the tap.
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            status = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
            guard status == noErr else { throw TapError.readTapFormatFailed(status) }
            guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
                throw TapError.unsupportedTapFormat("\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) Kanäle, formatID \(asbd.mFormatID)")
            }

            // Tap UID (equals desc.uuid, but read it back to be safe).
            let tapUID = SystemAudioTap.readString(tapID, kAudioTapPropertyUID) ?? desc.uuid.uuidString

            // 3. Private, tap-only aggregate device (no sub-devices; the tap provides the clock).
            //
            // Measured on macOS 26 with 44.1 kHz Bluetooth headphones as default output: when the
            // output device is added as main sub-device (AudioCap style), the IOProc runs at the
            // device's 44.1 kHz clock while both the tap and the aggregate still report 48 kHz,
            // so a 1 kHz tone came out as 1088 Hz and ~8 % of the samples were missing. It also
            // delivered nothing at all while no app was playing. The tap-only aggregate delivers
            // correct-rate audio continuously (silence included), which keeps the system track
            // time-aligned with the microphone track.
            let aggDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Flow System Audio Tap",
                kAudioAggregateDeviceUIDKey: "de.flow.systemaudiotap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]

            var newAgg = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg)
            guard status == noErr, newAgg != kAudioObjectUnknown else { throw TapError.createAggregateFailed(status) }
            aggregateID = newAgg

            guard let src = AVAudioFormat(streamDescription: &asbd) else {
                throw TapError.unsupportedTapFormat("\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) Kanäle, formatID \(asbd.mFormatID)")
            }
            guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SystemAudioTap.targetSampleRate,
                                          channels: 1, interleaved: false) else {
                throw TapError.converterFailed("Zielformat ungültig")
            }
            guard let conv = AVAudioConverter(from: src, to: dst) else {
                throw TapError.converterFailed("\(src) → \(dst)")
            }
            if src.channelCount > 1 {
                // Should not happen for a mono tap, but downmix instead of dropping channels.
                conv.downmix = true
            }
            sourceFormat = src
            outputFormat = dst
            converter = conv

            // 4. IOProc on the private serial queue.
            var newProc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
                self?.process(inInputData)
            }
            guard status == noErr, let newProc else { throw TapError.createIOProcFailed(status) }
            procID = newProc

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw TapError.startDeviceFailed(status) }

            // 5. Rebuild if the tap format changes. (A stalled/dead device is caught by the owner's
            // watchdog. Deliberately NO kAudioDevicePropertyDeviceIsAlive listener on the aggregate:
            // measured, it makes every second tap re-creation fail with tap ID 0.)
            formatListener = addListener(object: tapID, selector: kAudioTapPropertyFormat)
        }

        private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector) -> AudioObjectPropertyListenerBlock? {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Delivered on controlQueue.
                guard let self, !self.isInvalidated, self.formatChanged() else { return }
                self.owner?.rebuild(reason: "Tap-Format geändert")
            }
            return AudioObjectAddPropertyListenerBlock(object, &addr, controlQueue, block) == noErr ? block : nil
        }

        private func removeListener(object: AudioObjectID, selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock?) {
            guard let block, object != kAudioObjectUnknown else { return }
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(object, &addr, controlQueue, block)
        }

        /// True if the tap now reports a different stream format than the converter was built for.
        private func formatChanged() -> Bool {
            guard let src = sourceFormat else { return false }
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr else { return false }
            return asbd.mSampleRate != src.sampleRate || asbd.mChannelsPerFrame != src.channelCount
        }

        private var isInvalidated: Bool {
            invalidLock.lock(); defer { invalidLock.unlock() }
            return invalidated
        }

        /// Must not be called from the IO queue.
        func invalidate() {
            invalidLock.lock()
            if invalidated { invalidLock.unlock(); return }
            invalidated = true
            invalidLock.unlock()

            removeListener(object: tapID, selector: kAudioTapPropertyFormat, block: formatListener)
            formatListener = nil

            if aggregateID != kAudioObjectUnknown {
                if let procID {
                    AudioDeviceStop(aggregateID, procID)
                    AudioDeviceDestroyIOProcID(aggregateID, procID)
                }
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            procID = nil
            aggregateID = AudioObjectID(kAudioObjectUnknown)

            if tapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tapID)
                tapID = AudioObjectID(kAudioObjectUnknown)
            }
        }

        /// ioQueue.
        private func process(_ input: UnsafePointer<AudioBufferList>) {
            guard !isInvalidated, let converter, let src = sourceFormat, let dst = outputFormat, let owner else { return }
            owner.noteIO()
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard abl.count > 0, let first = abl.first, first.mData != nil, first.mDataByteSize > 0 else { return }

            guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, bufferListNoCopy: input, deallocator: nil),
                  inBuf.frameLength > 0 else { return }

            let capacity = AVAudioFrameCount((Double(inBuf.frameLength) * dst.sampleRate / src.sampleRate).rounded(.up)) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else { return }

            var consumed = false
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            guard status != .error, error == nil, outBuf.frameLength > 0,
                  let ch = outBuf.floatChannelData else { return }
            owner.deliver(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
        }

        deinit { invalidate() }
    }

    // MARK: - Core Audio helpers

    fileprivate static func ownProcessObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return (status == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }

    fileprivate static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    fileprivate static func describe(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let s = String(bytes: bytes, encoding: .ascii) {
            return "OSStatus \(status) '\(s)'"
        }
        return "OSStatus \(status)"
    }
}
