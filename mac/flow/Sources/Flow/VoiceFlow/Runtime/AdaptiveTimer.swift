import Foundation

/// Main-Run-Loop-Timer, der sein Tempo wechseln kann: schnell, solange etwas passiert (Maus bewegt, Hover, Ziehen,
/// Fortschritt), langsam in Ruhe. Gemessen 18.10.2026: Pille (20 Hz) + Datei-Overlay (30 Hz) liefen ohne Pause und
/// machten ~40 der 47 Aufwach-Vorgänge pro Sekunde im Leerlauf aus.
final class AdaptiveTimer {
    private var timer: Timer?
    private(set) var interval: TimeInterval = 0
    private let block: () -> Void

    init(interval: TimeInterval, _ block: @escaping () -> Void) {
        self.block = block
        set(interval)
    }

    /// Neues Tempo (wirkt ab dem nächsten Takt; gleiches Tempo = nichts tun)
    func set(_ newInterval: TimeInterval) {
        guard newInterval != interval else { return }
        interval = newInterval
        timer?.invalidate()
        let t = Timer(timeInterval: newInterval, repeats: true) { [weak self] _ in self?.block() }
        t.tolerance = newInterval * 0.15   // macOS darf Weckzeiten bündeln
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func invalidate() { timer?.invalidate(); timer = nil; interval = 0 }

    /// Ruhe-Tempo der Pille und ihres Overlays: 4 Hz – erste Mausbewegung schaltet nach ≤0,25 s auf schnell
    static let restInterval: TimeInterval = 0.25
}
