import AppKit

// MARK: - RAM-Hygiene (18.10.2026)
// Gemessen auf einem echten Mac: Leerlauf 56–71 MB; was danach dazukam, blieb nach dem Stöbern im Hub liegen:
// dekodierte Bilder in Zwischenspeichern ohne Kostengrenze (ein 3200-px-Bild ≈ 25 MB) und geschlossene Fenster,
// deren versteckter SwiftUI-Baum weiterlief (Bilder in @State, Timer alle 1,5–5 s). Prüfung: Flow --selftest-ram

/// Bild-Zwischenspeicher mit Grenze für Anzahl UND dekodierte Bytes (bytesPerRow × Höhe); das am längsten
/// nicht benutzte Bild fliegt zuerst. Anders als NSCache genau nachprüfbar; bei Speicherdruck wird er geleert.
final class VFImageCache {
    let countLimit: Int
    let costLimit: Int
    private struct Slot { let image: NSImage; let cost: Int; var used: UInt64 }
    private var slots: [String: Slot] = [:]
    private var clock: UInt64 = 0
    private var total = 0
    private let lock = NSLock()
    private var pressure: DispatchSourceMemoryPressure?

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.removeAll() }
        src.resume()
        pressure = src
    }

    deinit { pressure?.cancel() }

    var count: Int { lock.lock(); defer { lock.unlock() }; return slots.count }
    /// Summe der dekodierten Bytes aller gehaltenen Bilder
    var totalCost: Int { lock.lock(); defer { lock.unlock() }; return total }

    func object(_ key: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        guard var s = slots[key] else { return nil }
        clock += 1; s.used = clock; slots[key] = s
        return s.image
    }

    /// Ein Bild, das allein schon über der Kostengrenze liegt, wird gar nicht erst gehalten.
    func set(_ image: NSImage, key: String, cost: Int) {
        guard cost <= costLimit, countLimit > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = slots.removeValue(forKey: key) { total -= old.cost }
        clock += 1
        slots[key] = Slot(image: image, cost: cost, used: clock)
        total += cost
        while slots.count > countLimit || total > costLimit,
              let oldest = slots.min(by: { $0.value.used < $1.value.used }) {
            slots.removeValue(forKey: oldest.key)
            total -= oldest.value.cost
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        slots.removeAll()
        total = 0
    }

    /// Dekodierte Größe eines Bildes in Bytes
    static func cost(_ cg: CGImage) -> Int { cg.bytesPerRow * cg.height }
}

/// Gibt ein geschlossenes Fenster nach einer Frist frei. Wer in der Frist wieder öffnet, bricht sie ab (`cancel()` in show())
/// und bekommt das Fenster sofort zurück; danach baut show() es neu. Der Zustand liegt in Singletons (VFHub, CVHubState …).
final class VFWindowReleaser {
    /// 60 s: kurzes Zu-/Aufmachen bleibt sofort da, danach ist der SwiftUI-Baum samt Bildern und Timern weg.
    static let defaultDelay: TimeInterval = 60
    let delay: TimeInterval
    private var work: DispatchWorkItem?

    init(delay: TimeInterval = VFWindowReleaser.defaultDelay) { self.delay = delay }

    var isPending: Bool { work != nil }

    /// Plant `release` (ersetzt eine schon geplante Freigabe)
    func schedule(_ release: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.work = nil
            release()
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    /// Darf das Fenster jetzt weg? (nicht, wenn es wieder zu sehen ist oder ein Blatt daran hängt)
    static func canDrop(_ w: NSWindow) -> Bool { !w.isVisible && !w.isMiniaturized && w.attachedSheet == nil }

    /// Inhalt und Delegate loslassen. Den Rahmen vorher sichern und den Autosave-Namen freigeben,
    /// sonst lehnt das neu gebaute Fenster denselben Namen ab, solange das alte noch irgendwo lebt.
    static func dismantle(_ w: NSWindow, autosaveName: String? = nil) {
        if let n = autosaveName, !n.isEmpty {
            w.setFrameAutosaveName("")
            if !w.styleMask.contains(.fullScreen) { w.saveFrame(usingName: n) }
        }
        w.delegate = nil
        w.contentView = nil
    }
}
