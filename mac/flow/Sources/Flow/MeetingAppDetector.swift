import Foundation
import CoreAudio
import AppKit

/// Detects meeting/call apps that are currently capturing the microphone, using Core Audio
/// process objects (macOS 14+). No extra permission needed.
final class MeetingAppDetector {
    struct ActiveApp: Equatable { let bundleID: String; let name: String; let pid: pid_t }

    /// Called on the main thread whenever the set of meeting apps using the mic changes.
    var onChange: (([ActiveApp]) -> Void)?
    private(set) var active: [ActiveApp] = []

    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {}

    deinit { timer?.invalidate() }

    func start(interval: TimeInterval = 3) {
        let begin = { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            let t = Timer(timeInterval: max(0.5, interval), repeats: true) { [weak self] _ in self?.poll() }
            t.tolerance = min(1, interval * 0.2)
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
            self.poll()
        }
        if Thread.isMainThread { begin() } else { DispatchQueue.main.async(execute: begin) }
    }

    func stop() {
        let end = { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
        if Thread.isMainThread { end() } else { DispatchQueue.main.async(execute: end) }
    }

    // MARK: - Known apps

    /// Canonical bundle ID, display name, and bundle-ID prefixes (case-insensitive; a prefix
    /// matches the ID itself or any "<prefix>.<suffix>" helper, e.g. com.google.Chrome.helper).
    private struct KnownApp { let bundleID: String; let name: String; let prefixes: [String] }

    private static let knownApps: [KnownApp] = [
        KnownApp(bundleID: "us.zoom.xos", name: "Zoom", prefixes: ["us.zoom.xos"]),
        KnownApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", prefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
        // FaceTime (and Phone/continuity calls) route the mic through the avconferenced daemon.
        KnownApp(bundleID: "com.apple.FaceTime", name: "FaceTime", prefixes: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        KnownApp(bundleID: "com.google.Chrome", name: "Chrome (z. B. Google Meet)", prefixes: ["com.google.Chrome"]),
        // Safari's media capture runs in the shared WebKit GPU process.
        KnownApp(bundleID: "com.apple.Safari", name: "Safari", prefixes: ["com.apple.WebKit.GPU", "com.apple.Safari"]),
        KnownApp(bundleID: "company.thebrowser.Browser", name: "Arc", prefixes: ["company.thebrowser.Browser"]),
        KnownApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", prefixes: ["com.microsoft.edgemac"]),
        KnownApp(bundleID: "com.brave.Browser", name: "Brave", prefixes: ["com.brave.Browser"]),
        KnownApp(bundleID: "org.mozilla.firefox", name: "Firefox", prefixes: ["org.mozilla.firefox", "org.mozilla.plugincontainer"]),
        KnownApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", prefixes: ["com.tinyspeck.slackmacgap"]),
        KnownApp(bundleID: "com.hnc.Discord", name: "Discord", prefixes: ["com.hnc.Discord"]),
        KnownApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", prefixes: ["com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "Cisco-Systems.Spark"]),
        KnownApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", prefixes: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        KnownApp(bundleID: "com.skype.skype", name: "Skype", prefixes: ["com.skype.skype"]),
        KnownApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal", prefixes: ["org.whispersystems.signal-desktop"]),
        KnownApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram", prefixes: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
    ]

    private static func match(_ bundleID: String) -> KnownApp? {
        let id = bundleID.lowercased()
        var best: (app: KnownApp, len: Int)?
        for app in knownApps {
            for p in app.prefixes {
                let lp = p.lowercased()
                if id == lp || id.hasPrefix(lp + ".") || id.hasPrefix(lp + "-") {
                    if lp.count > (best?.len ?? -1) { best = (app, lp.count) }
                }
            }
        }
        return best?.app
    }

    // MARK: - Polling

    private func poll() {
        let found = Self.currentMeetingApps(excluding: ownPID)
        guard found != active else { return }
        active = found
        onChange?(found)
    }

    /// Reads all Core Audio process objects and returns the known meeting apps with running input.
    static func currentMeetingApps(excluding ownPID: pid_t) -> [ActiveApp] {
        var result: [String: ActiveApp] = [:]
        for obj in processObjects() {
            guard readUInt32(obj, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            guard let pid = readPID(obj), pid != ownPID else { continue }
            let bundleID = readString(obj, kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? processName(pid).map { $0 == "avconferenced" ? "com.apple.avconferenced" : $0 }
            guard let bundleID, let known = match(bundleID) else { continue }
            if result[known.bundleID] == nil {
                result[known.bundleID] = ActiveApp(bundleID: known.bundleID, name: known.name, pid: pid)
            }
        }
        return result.values.sorted { $0.name < $1.name }
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func readUInt32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readPID(_ obj: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    private static func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}
