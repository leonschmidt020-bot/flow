import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Meeting-Fenster finden (nur das Fenster der Meeting-App – nie andere Fenster)

struct MCWindowCandidate: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String
    let frame: CGRect
    let onScreen: Bool
    /// je höher, desto eher das Meeting-Fenster
    let score: Double
    /// passt zur erkannten Meeting-App (sonst nur per Hand wählbar)
    let matchesMeetingApp: Bool

    var label: String { title.isEmpty ? appName : "\(appName) – \(title)" }
}

enum MCWindowPicker {
    /// Erkannte App (kanonische Bundle-ID aus MeetingAppDetector) → Bundle-IDs der Fenster-Besitzer
    static func owners(for app: String) -> [String] {
        switch app {
        case "com.microsoft.teams2": return ["com.microsoft.teams2", "com.microsoft.teams"]
        case "com.apple.FaceTime": return ["com.apple.FaceTime"]
        case "com.cisco.webexmeetingsapp": return ["com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "Cisco-Systems.Spark"]
        case "net.whatsapp.WhatsApp": return ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]
        case "ru.keepcoder.Telegram": return ["ru.keepcoder.Telegram", "org.telegram.desktop"]
        default: return [app]
        }
    }

    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
                                        "com.brave.Browser", "org.mozilla.firefox"]
    /// Chat-Apps: Hauptfenster enthält private Chats → nur Fenster mit Anruf-/Meeting-Titel
    static let chatApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp", "org.whispersystems.signal-desktop",
                                        "ru.keepcoder.Telegram"]
    /// Wörter im Fenstertitel, die auf ein Meeting deuten (Browser: der AKTIVE Tab muss das Meeting sein)
    /// („call“/„anruf“ bewusst nicht: zu viele normale Seiten heißen so)
    static let browserKeywords = ["meet", "zoom", "teams", "webex", "jitsi", "whereby", "besprechung", "huddle", "konferenz"]
    static let chatKeywords = ["huddle", "anruf", "call", "meeting", "besprechung", "video", "konferenz", "bildschirm", "screen"]
    static let meetingKeywords = ["meeting", "besprechung", "huddle", "call", "anruf", "konferenz", "freigabe", "sharing", "screen", "bildschirm"]

    /// Alle normalen Fenster (für die Auswahl) – bewertet für die gegebene Meeting-App.
    static func candidates(meetingApp: String?) async -> [MCWindowCandidate] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return [] }
        // Reihenfolge vorn → hinten (nur für sichtbare Fenster)
        var rank: [CGWindowID: Int] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (i, d) in list.enumerated() { if let n = d[kCGWindowNumber as String] as? UInt32 { rank[n] = i } }
        }
        let own = Bundle.main.bundleIdentifier ?? "app.flowdictation.flow"
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownerIDs = Set((meetingApp.map { MCWindowPicker.owners(for: $0) } ?? []).map { $0.lowercased() })
        let appIsBrowser = meetingApp.map { browsers.contains($0) } ?? false
        let appIsChat = meetingApp.map { chatApps.contains($0) } ?? false
        var out: [MCWindowCandidate] = []
        for w in content.windows {
            guard w.windowLayer == 0, w.frame.width >= 320, w.frame.height >= 220,
                  let app = w.owningApplication, app.processID != ownPID, app.bundleIdentifier != own else { continue }
            let bid = app.bundleIdentifier
            let title = w.title ?? ""
            let lt = title.lowercased()
            let lb = bid.lowercased()
            let belongs = ownerIDs.contains { lb == $0 || lb.hasPrefix($0 + ".") }
            var matches = belongs
            if belongs && appIsBrowser { matches = browserKeywords.contains { lt.contains($0) } }
            if belongs && appIsChat { matches = chatKeywords.contains { lt.contains($0) } }
            var score = Double(w.frame.width * w.frame.height) / 1_000_000   // ~0,5 … 6
            if matches { score += 10 }
            if meetingKeywords.contains(where: { lt.contains($0) }) { score += 3 }
            if let r = rank[w.windowID] { score += max(0, 2 - Double(r) * 0.2) } else { score -= 1 }
            if w.isOnScreen { score += 1 }
            out.append(MCWindowCandidate(id: w.windowID, title: title, appName: app.applicationName, bundleID: bid,
                                         frame: w.frame, onScreen: w.isOnScreen, score: score, matchesMeetingApp: matches))
        }
        return out.sorted { $0.score > $1.score }
    }

    static func scWindow(_ id: CGWindowID) async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        return content.windows.first { $0.windowID == id }
    }
}

// MARK: - Aufnahme eines Fensters: 1 Bild/s klein (Wechsel erkennen), Schlüsselbilder in voller Auflösung

final class MCCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let meetingID: String
    let folder: URL
    let startedAt: Date
    private(set) var window: SCWindow
    private(set) var windowTitle: String
    private var stream: SCStream?
    private var filter: SCContentFilter
    private let queue = DispatchQueue(label: "flow.meetingkontext.capture", qos: .utility)
    private var timer: DispatchSourceTimer?
    let detector: MCChangeDetector
    private var lastThumb: MCThumb?
    private var lastBuffer: CVPixelBuffer?
    private var video: MCVideoWriter?
    private var saving = false
    private var stopped = false
    /// App Nap aus, solange mitgeschnitten wird (sonst bündelt macOS den 1-Hz-Takt einer Hintergrund-App)
    private var activity: NSObjectProtocol?
    let saveVideo: Bool
    /// Statistik (für Tests / Diagnose)
    private(set) var framesSeen = 0
    private(set) var ticks = 0
    private(set) var savedCount = 0
    private(set) var replacedCount = 0

    /// Meldet gespeicherte Bilder (Main-Thread)
    var onFrameSaved: ((MCFrame) -> Void)?
    /// Stream ist abgebrochen (Fenster zu, Freigabe entzogen) – Main-Thread
    var onStopped: ((Error?) -> Void)?

    init(meetingID: String, folder: URL, startedAt: Date, window: SCWindow, saveVideo: Bool, params: MCChangeDetector.Params = .init()) {
        self.meetingID = meetingID
        self.folder = folder
        self.startedAt = startedAt
        self.window = window
        self.windowTitle = window.title ?? ""
        self.saveVideo = saveVideo
        self.filter = SCContentFilter(desktopIndependentWindow: window)
        self.detector = MCChangeDetector(params: params)
    }

    private var streamWidth: Int { saveVideo ? 1280 : 640 }

    private func streamConfig(for w: SCWindow) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let aspect = max(0.2, min(5, w.frame.height / max(w.frame.width, 1)))
        c.width = streamWidth
        c.height = max(120, Int((Double(streamWidth) * aspect).rounded()) & ~1)
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // 1 Bild/s
        c.queueDepth = 4
        c.showsCursor = false
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.capturesAudio = false
        c.ignoreShadowsSingleWindow = true
        c.preservesAspectRatio = true
        c.scalesToFit = true
        return c
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bilder"), withIntermediateDirectories: true)
        let s = SCStream(filter: filter, configuration: streamConfig(for: window), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Meeting-Kontext: Meeting-Fenster wird mitgeschnitten")
        if saveVideo {
            let c = streamConfig(for: window)
            video = try? MCVideoWriter(url: folder.appendingPathComponent("bildschirm.mov"), width: c.width, height: c.height)
            if video != nil { MCStore.shared.mutate(meetingID) { $0.video = "bildschirm.mov" } }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        log("Meeting-Kontext: Aufnahme von „\(windowTitle)“ (\(window.owningApplication?.applicationName ?? "?")) \(Int(window.frame.width))×\(Int(window.frame.height))")
    }

    /// Anderes Fenster (Wechsel per Hand oder weil das alte zu ist)
    func switchTo(_ w: SCWindow) async {
        let f = SCContentFilter(desktopIndependentWindow: w)
        do {
            try await stream?.updateContentFilter(f)
            try await stream?.updateConfiguration(streamConfig(for: w))
            queue.sync { self.filter = f; self.window = w; self.windowTitle = w.title ?? ""; self.detector.reset(); self.lastThumb = nil }
            log("Meeting-Kontext: Fenster gewechselt → „\(w.title ?? "")“")
        } catch { log("Meeting-Kontext: Fensterwechsel fehlgeschlagen \(error)") }
    }

    /// Fenstergröße geändert → Stream-Seitenverhältnis anpassen
    func windowResized(_ w: SCWindow) async {
        guard abs(w.frame.width - window.frame.width) > 8 || abs(w.frame.height - window.frame.height) > 8 else { return }
        try? await stream?.updateConfiguration(streamConfig(for: w))
        queue.sync { self.window = w; self.windowTitle = w.title ?? self.windowTitle }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        timer?.cancel(); timer = nil
        try? await stream?.stopCapture()
        stream = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        let v: MCVideoWriter? = queue.sync { let v = self.video; self.video = nil; self.lastBuffer = nil; return v }
        await v?.finish()
        // warten, bis ein laufendes Sichern fertig ist (max. 5 s)
        for _ in 0..<50 where queue.sync(execute: { saving }) { try? await Task.sleep(nanoseconds: 100_000_000) }
        log("Meeting-Kontext: Aufnahme gestoppt – \(savedCount) Bilder (\(replacedCount) Aufbau-Stufen ersetzt), \(framesSeen) Einzelbilder gesehen")
    }

    // MARK: SCStream

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        framesSeen += 1
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        lastThumb = MCThumb.fromBGRA(base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        if video != nil { lastBuffer = pb }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Meeting-Kontext: Stream beendet: \(error.localizedDescription)")
        DispatchQueue.main.async { self.onStopped?(error) }
    }

    // MARK: Takt (1 Hz): erkennen, ggf. Schlüsselbild sichern, Video fortschreiben

    private func tick() {
        guard !stopped, let th = lastThumb else { return }
        ticks += 1
        let t = Date().timeIntervalSince(startedAt)
        if let v = video, let pb = lastBuffer { v.append(pb, at: t) }
        guard !saving else { return }
        if case .save(let change, let replace, let roi) = detector.feed(th, t: t) {
            saving = true
            let f = filter, w = window, title = windowTitle
            Task { await self.saveKeyframe(filter: f, window: w, title: title, t: t, change: change, replace: replace, roi: roi, moment: false) }
        }
    }

    /// Volles Bildschirmfoto des Fensters (auch für „Moment merken“)
    func snapshot() async -> CGImage? {
        let (f, w): (SCContentFilter, SCWindow) = queue.sync { (filter, window) }
        return await MCCaptureSession.screenshot(filter: f, window: w)
    }

    static func screenshot(filter: SCContentFilter, window w: SCWindow) async -> CGImage? {
        let c = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var pw = w.frame.width * max(1, scale), ph = w.frame.height * max(1, scale)
        let maxSide: CGFloat = 2560
        if max(pw, ph) > maxSide { let k = maxSide / max(pw, ph); pw *= k; ph *= k }
        c.width = Int(pw); c.height = Int(ph)
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        c.capturesAudio = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
    }

    /// Gemerkten Moment (⌃⌥S) als Bild sichern
    func saveMoment(t: Double) async -> MCFrame? {
        // läuft gerade ein automatisches Sichern → kurz warten (sonst doppelte Nummer)
        for _ in 0..<40 where queue.sync(execute: { saving }) { try? await Task.sleep(nanoseconds: 75_000_000) }
        let (f, w, title): (SCContentFilter, SCWindow, String) = queue.sync { saving = true; return (filter, window, windowTitle) }
        let fr = await saveKeyframe(filter: f, window: w, title: title, t: t, change: 0, replace: false, roi: nil, moment: true)
        queue.async { self.detector.markCurrentAsKey(t: t) }
        return fr
    }

    @discardableResult
    private func saveKeyframe(filter f: SCContentFilter, window w: SCWindow, title: String, t: Double, change: Double,
                              replace: Bool, roi: [Double]?, moment: Bool) async -> MCFrame? {
        defer { queue.async { self.saving = false } }
        guard let img = await MCCaptureSession.screenshot(filter: f, window: w) else {
            log("Meeting-Kontext: Bildschirmfoto fehlgeschlagen")
            return nil
        }
        let log0 = MCStore.shared.log(meetingID)
        var replaceTarget: MCFrame?
        if replace, let last = log0.frames.last, !last.isMoment { replaceTarget = last }
        let n = (log0.frames.count + 1)
        let id = replaceTarget?.id ?? String(format: "f%03d", n)
        let tFirst = replaceTarget?.t ?? t
        let file = replaceTarget?.file ?? "bilder/\(id)_\(MCText.fileStamp(tFirst))\(moment ? "_moment" : "").jpg"
        let url = folder.appendingPathComponent(file)
        guard MCImageIO.writeJPEG(img, to: url, quality: 0.78) else { return nil }
        let fr = MCFrame(id: id, t: tFirst, tLast: t, file: file, width: img.width, height: img.height, ocr: nil, roi: roi,
                         change: max(change, replaceTarget?.change ?? 0), moment: moment ? true : nil, window: title.isEmpty ? nil : title)
        MCStore.shared.mutate(meetingID) { l in
            l.captured = true
            if !title.isEmpty && !l.windows.contains(title) { l.windows.append(title) }
            if let i = l.frames.firstIndex(where: { $0.id == id }) { l.frames[i] = fr } else { l.frames.append(fr) }
            l.frames.sort { $0.t < $1.t }
        }
        if replaceTarget != nil { replacedCount += 1 } else { savedCount += 1 }
        MCOCR.shared.enqueue(meetingID: meetingID, frameID: id, urgent: moment)
        DispatchQueue.main.async { self.onFrameSaved?(fr) }
        return fr
    }
}

// MARK: - Bilder schreiben/lesen

enum MCImageIO {
    static func writeJPEG(_ img: CGImage, to url: URL, quality: Double, maxSide: Int? = nil) -> Bool {
        var image = img
        if let m = maxSide, max(img.width, img.height) > m, let s = scaled(img, maxSide: m) { image = s }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { return false }
        _ = try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.moveItem(at: tmp, to: url) } catch { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    static func scaled(_ img: CGImage, maxSide: Int) -> CGImage? {
        let k = Double(maxSide) / Double(max(img.width, img.height))
        let w = max(1, Int(Double(img.width) * k)), h = max(1, Int(Double(img.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Verkleinert laden (nie das Vollbild im RAM für Listen)
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - Optionales Video (1 Bild/s, H.264, ~50 MB/Std.)

final class MCVideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var lastT: Double = -1

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 110_000,            // ≈ 50 MB pro Stunde
                AVVideoExpectedSourceFrameRateKey: 1,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw NSError(domain: "MCVideo", code: 1) }
        writer.add(input)
    }

    func append(_ pb: CVPixelBuffer, at t: Double) {
        guard t > lastT + 0.5 else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMTime(seconds: t, preferredTimescale: 600))
            started = true
        }
        guard input.isReadyForMoreMediaData else { return }
        // Größe muss zur Ausgabe passen (nach Fensterwechsel evtl. anders) – sonst Bild auslassen
        if adaptor.append(pb, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) { lastT = t }
    }

    func finish() async {
        guard started else { writer.cancelWriting(); return }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { log("Meeting-Kontext: Video nicht fertig geschrieben: \(writer.error?.localizedDescription ?? "?")") }
    }
}
