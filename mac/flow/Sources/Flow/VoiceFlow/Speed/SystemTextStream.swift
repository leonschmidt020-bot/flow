import Foundation

/// Mac-Ton (Musik, YouTube, Meeting) schon WÄHREND der Aufnahme erkennen – für den Mac-Ton-Filter (`EchoFilter.subtract`).
///
/// Vorher lief Parakeet erst nach dem Loslassen über den GANZEN Mac-Ton: gemessen 0,11 s (17 s) · 0,35 s (37 s) ·
/// 0,6 s (115 s) auf dem M4 Pro, im Betrieb mit dichter Musik/Sprache bis 1,5 s (Log: „Erkennung 0,15 s, gesamt 1,66 s“).
/// Jetzt: alle ~10 s ein Stück (1 s Überlappung, damit keine Dreiwortfolge an der Naht fehlt), nur Stücke mit Ton.
/// Nach dem Loslassen bleibt nur der Rest (≤ 11 s ≈ 50–60 ms, parallel zur Erkennung des Diktats).
final class SystemTextStream: @unchecked Sendable {
    static let piece = 16000 * 10
    static let overlap = 16000

    /// Austauschbar (Messbank)
    nonisolated(unsafe) static var transcribe: @Sendable ([Float]) async -> String = { (try? await Transcriber.shared.transcribe($0).text) ?? "" }

    private var tasks: [Task<String, Never>] = []
    private var from = 0

    /// Neues Diktat / Abbruch
    func reset() {
        tasks.forEach { $0.cancel() }
        tasks = []; from = 0
    }

    /// Alle 0,5 s während der Aufnahme (Main-Thread): liegt ein neues 10-s-Stück vor, im Hintergrund erkennen.
    func poll(count: Int, peek: (Int) -> [Float]) {
        guard count - from >= Self.piece else { return }
        let start = max(0, from - Self.overlap)
        let seg = peek(start)
        from = start + seg.count
        guard EchoFilter.hasSound(seg) else { return }
        let f = Self.transcribe
        tasks.append(Task.detached(priority: .utility) { await f(seg) })
    }

    /// Loslassen: übernimmt die vorab gestarteten Stücke + den Rest von `system` (ganzer Mac-Ton des Diktats).
    /// Liefert eine Arbeit, die den zusammengesetzten Text holt (nil = kein Text).
    func take(_ system: [Float]) -> @Sendable () async -> String? {
        let pieces = tasks
        let tail = Array(system[min(system.count, max(0, from - Self.overlap))...])
        tasks = []; from = 0
        let f = Self.transcribe
        return {
            async let rest: String = EchoFilter.hasSound(tail) ? await f(tail) : ""
            var parts: [String] = []
            for p in pieces { parts.append(await p.value) }
            parts.append(await rest)
            let t = parts.filter { !$0.isEmpty }.joined(separator: " ")
            return t.isEmpty ? nil : t
        }
    }
}
