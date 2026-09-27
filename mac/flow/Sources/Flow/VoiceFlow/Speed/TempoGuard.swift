import Foundation
import SwiftUI

/// „Tempo-Garantie“ (Agent SPEED, 27.09.2026): Text steht spätestens ~1 s nach dem Loslassen von fn.
///
/// Gemessen (Log + `--speed-lat`): Parakeet braucht 40–150 ms, Whisper large-v3-turbo IMMER ≥ 0,55–0,8 s
/// (festes 30-s-Encoder-Fenster; auf dem MacBook Air M4 ~1,2–1,6 s, nach dem Parken bis +1,4 s Aufwachen, bei
/// Temperatur-Rückfall bis 2,4 s). Kürzere Encoder-Fenster (audio_ctx) sind KEIN Ausweg: WER 7 % → 30–37 %
/// und sie verschlechtern danach sogar normale Anfragen auf demselben Server.
///
/// Deshalb, nur wenn eingeschaltet: Whisper-Bestätigungen haben eine Frist (Standard 0,85 s ab Loslassen). Kommt Whisper
/// nicht rechtzeitig, gilt das Parakeet-Ergebnis (+ direkt/klanglich bestätigte Namen, Wörterbuch-Regeln) – Whisper
/// rechnet im Hintergrund zu Ende, das Ergebnis wird nur protokolliert (kein nachträgliches Ersetzen im Zielfeld:
/// in Terminal/VS Code/Browser nicht sicher machbar). Apple-Intelligence-Feinschliff bekommt nur die Restzeit,
/// Claude-Feinschliff („Gründlich“) wird übersprungen. Aus = exakt das bisherige Verhalten.
enum TempoGuard {
    /// Frist für Whisper ab Loslassen (danach bleiben ~0,1 s für Nachbearbeitung + Einfügen)
    nonisolated(unsafe) static var whisperBudget: TimeInterval = 0.85
    /// Frist für den KI-Feinschliff ab Loslassen
    nonisolated(unsafe) static var polishBudget: TimeInterval = 0.92
    /// Kürzer lohnt Apple Intelligence nicht
    nonisolated(unsafe) static var minPolishSlot: TimeInterval = 0.15

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _enabled: Bool = load()
    nonisolated(unsafe) private static var release: Date?
    nonisolated(unsafe) private static var expired = 0
    nonisolated(unsafe) private static var token = 0

    static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock(); save(newValue) }
    }

    /// Nur für Messläufe: ein/aus ohne Datei
    static func setForTest(_ on: Bool) { lock.lock(); _enabled = on; lock.unlock() }

    // MARK: Einstellung (eigene Datei wie „Speicher sparen“)

    static var fileURL: URL { Paths.base.appendingPathComponent("tempo.json") }
    private struct Stored: Codable { var garantie: Bool }

    private static func load() -> Bool {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Stored.self, from: d) else { return false }
        return s.garantie
    }

    private static func save(_ on: Bool) {
        guard let d = try? JSONEncoder().encode(Stored(garantie: on)) else { return }
        try? d.write(to: fileURL, options: .atomic)
        chmod(fileURL.path, 0o600)
        log("Tempo-Garantie: \(on ? "an" : "aus")")
    }

    // MARK: Ablauf je Diktat

    /// fn losgelassen (DictationController.finish). Liefert eine Marke für `disarm`.
    @discardableResult
    static func arm(release at: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        release = at; expired = 0; token += 1
        return token
    }

    /// Diktat fertig/abgebrochen → keine Frist mehr (Stücke des nächsten Diktats laufen wieder ohne).
    /// Mit Marke: nur, wenn inzwischen kein neueres Diktat losgelassen wurde.
    static func disarm(_ mark: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let mark, mark != token { return }
        release = nil
    }

    /// Wie oft in diesem Diktat die Frist gegriffen hat
    static var expiredCount: Int { lock.lock(); defer { lock.unlock() }; return expired }

    private static func deadline(_ budget: TimeInterval) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard _enabled, let r = release else { return nil }
        return r.addingTimeInterval(budget)
    }

    struct Expired: Error {}

    private final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        var cont: CheckedContinuation<T, Error>?
        var done = false
        /// true = die Frist hat gewonnen
        var late = false
        func finish(_ r: Result<T, Error>, late l: Bool = false) -> Bool {
            lock.lock()
            guard !done, let c = cont else { lock.unlock(); return false }
            done = true; late = l; cont = nil
            lock.unlock()
            c.resume(with: r)
            return true
        }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    /// Whisper-Aufruf mit Frist. Aus (oder kein Diktat losgelassen) = direkt durchreichen.
    /// Die Frist wird laufend neu gelesen: ein Stück, dessen Whisper schon VOR dem Loslassen lief, bekommt sie auch.
    static func race(_ what: String, _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        guard enabled else { return try await op() }
        if let d = deadline(whisperBudget), Date() >= d {
            lock.lock(); expired += 1; lock.unlock()
            throw Expired()
        }
        let t0 = Date()
        let box = Box<String>()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            box.lock.lock(); box.cont = c; box.lock.unlock()
            Task {
                let r: Result<String, Error>
                do { r = .success(try await op()) } catch { r = .failure(error) }
                if !box.finish(r), case .success(let text) = r {
                    log(String(format: "Tempo-Garantie: %@ kam nach %.2f s – zu spät, Parakeet-Ergebnis gilt", what, Date().timeIntervalSince(t0))
                        + (Settings.frozen.logTexts ? ": „\(text)“" : ""))
                }
            }
            Task {
                while !box.isDone {
                    if let d = deadline(whisperBudget), Date() >= d {
                        if box.finish(.failure(Expired()), late: true) {
                            lock.lock(); expired += 1; lock.unlock()
                            log(String(format: "Tempo-Garantie: Frist für %@ nach %.2f s erreicht", what, Date().timeIntervalSince(t0)))
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
            }
        }
    }

    /// Zeitlimit für Apple Intelligence: Standard, oder (Garantie an, Diktat losgelassen) nur die Restzeit.
    /// nil = gar nicht erst versuchen.
    static func polishTimeout(default t: TimeInterval) -> TimeInterval? {
        guard let d = deadline(polishBudget) else { return t }
        let left = d.timeIntervalSinceNow
        return left >= minPolishSlot ? min(t, left) : nil
    }

    /// Claude-Feinschliff (3–6 s) passt nicht in die Garantie
    static var skipSlowPolish: Bool { deadline(polishBudget) != nil }

    /// Einmal beim App-Start: Frist in Whisper-Aufrufe und Feinschliff einklinken (Aus = Verhalten unverändert)
    static func install() {
        HybridRecognizer.whisperGuard = { what, op in try await TempoGuard.race(what, op) }
        let claude = Polisher.claude
        Polisher.claude = { text in TempoGuard.skipSlowPolish ? nil : await claude(text) }
        Polisher.fm = { text, terms in
            guard let t = TempoGuard.polishTimeout(default: FMPolish.timeout) else { return nil }
            return await FMPolish.polish(text, terms: terms, timeout: t)
        }
    }
}

/// Zeile „Tempo-Garantie“ für Einstellungen → Allgemein
struct TempoGuardSettingRow: View {
    @State private var on = TempoGuard.enabled

    var body: some View {
        PGSettingRow(title: "Tempo-Garantie (unter 1 s)", detail: detail) {
            PGChoiceMenu(selection: $on, options: [false, true], label: { $0 ? "An – immer unter 1 s" : "Aus – immer Whisper (genauer)" }) { v in
                TempoGuard.enabled = v
            }
        }
        .onAppear { on = TempoGuard.enabled }
    }

    private var detail: String {
        on ? "Braucht Whisper länger als 0,85 s (z. B. auf dem MacBook Air oder direkt nach dem Aufwachen), wird sofort das schnelle Ergebnis eingefügt. Seltene Namen/Wörter können dann falsch geschrieben sein."
           : "Unsichere Stellen und Wörterbuch-Namen prüft immer Whisper – genauer, kann aber 1–2 s dauern (vor allem auf dem MacBook Air)."
    }
}
