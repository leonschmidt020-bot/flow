import AppKit
import Foundation

/// Lernt still aus sicheren Diktaten (Stimme passt sich an Mikro/Raum/Tagesform an) und zeigt einmal den
/// Hinweis „Flüstern einlernen?“.
///
/// Regeln der Anpassung:
/// - nur Diktate, in denen JEDES bewertete Fenster klar ich war (≥ 0,72 auf der VoiceID-Skala), nichts stummgeschaltet,
///   mindestens 3 Fenster; höchstens 4 Fenster pro Diktat,
/// - erst übernehmen, wenn 3 Minuten lang keine Korrektur kam (`dictationCorrected()` verwirft die jüngsten),
/// - höchstens eine Übernahme pro 10 Minuten und 12 pro Tag,
/// - Drift-Schutz in `VoiceTrainer.applyAdaptation` (eigene Level-Fenster, Vergleichsstimmen, Anker), vorher eine Sicherung
///   (`VoiceTrainer.rollback()` nimmt die letzte Übernahme zurück).
final class VoiceAdapter: @unchecked Sendable {
    static let shared = VoiceAdapter()
    /// In Messungen/Tests aus
    nonisolated(unsafe) static var enabled = true

    static let confident: Float = 0.72
    static let holdSeconds: TimeInterval = 190
    static let minGap: TimeInterval = 600
    static let maxPerDay = 12
    static let maxPerDictation = 4

    private struct Pending { let date: Date; let normal: [[Float]]; let whisper: [[Float]] }
    private var pending: [Pending] = []
    private let lock = NSLock()
    private var timerArmed = false
    var trainer: VoiceTrainer { VoiceTrainer.shared }

    func observe(_ v: FastVoiceMask.Verdict) {
        guard VoiceAdapter.enabled else { return }
        let model = trainer.model
        // Flüster-Hinweis: überwiegend geflüstert, aber noch kein Flüster-Profil
        let w = v.windows.filter(\.whisper).count
        if !v.windows.isEmpty, w * 2 >= v.windows.count, !model.hasWhisper, model.hasNormal { WhisperHint.showOnce() }
        // Anpassung
        guard v.kind == .mine, v.windows.count >= 3 else { return }
        let scored = v.windows.filter { !$0.whisper || model.hasWhisper }
        guard scored.count >= 3, scored.allSatisfy({ $0.sim >= VoiceAdapter.confident }) else { return }
        let step = max(1, scored.count / VoiceAdapter.maxPerDictation)
        let pick = stride(from: 0, to: scored.count, by: step).prefix(VoiceAdapter.maxPerDictation).map { scored[$0] }
        let p = Pending(date: Date(), normal: pick.filter { !$0.whisper }.map { Vec.norm($0.emb) },
                        whisper: pick.filter(\.whisper).map { Vec.norm($0.emb) })
        lock.lock(); pending.append(p); if pending.count > 40 { pending.removeFirst(pending.count - 40) }; lock.unlock()
        armTimer()
    }

    /// Eine Korrektur wurde erkannt → die jüngsten Diktate (noch in der Beobachtung) nicht lernen
    func dictationCorrected() {
        lock.lock()
        let cut = Date().addingTimeInterval(-VoiceAdapter.holdSeconds)
        pending.removeAll { $0.date > cut }
        lock.unlock()
    }

    private func armTimer() {
        lock.lock(); let armed = timerArmed; timerArmed = true; lock.unlock()
        guard !armed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceAdapter.holdSeconds + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.timerArmed = false; self.lock.unlock()
            self.commit()
        }
    }

    /// Reife Fenster übernehmen (Main-Thread). Gibt das Ergebnis zurück (nil = nichts zu tun / noch nicht dran).
    @discardableResult
    func commit(now: Date = Date()) -> VoiceTrainer.AdaptOutcome? {
        let st = trainer.store
        if let last = st.adaptiveCommits.last, now.timeIntervalSince(last) < VoiceAdapter.minGap { armTimer(); return nil }
        let today = st.adaptiveCommits.filter { Calendar.current.isDate($0, inSameDayAs: now) }.count
        guard today < VoiceAdapter.maxPerDay else { return nil }
        lock.lock()
        let ripe = pending.filter { now.timeIntervalSince($0.date) >= VoiceAdapter.holdSeconds }
        pending.removeAll { now.timeIntervalSince($0.date) >= VoiceAdapter.holdSeconds }
        let more = !pending.isEmpty
        lock.unlock()
        if more { armTimer() }
        guard !ripe.isEmpty else { return nil }
        let r = trainer.applyAdaptation(normal: ripe.flatMap(\.normal), whisper: ripe.flatMap(\.whisper))
        switch r {
        case .applied(let n, let w): tlog("Stimme: \(n) normale + \(w) geflüsterte Fenster aus \(ripe.count) Diktat(en) übernommen")
        case .rejected(let why): tlog("Stimme: Anpassung verworfen (\(why))")
        case .skipped: break
        }
        return r
    }
}

/// Einmalige Karte „Flüstern einlernen?“ (wächst aus der Pille)
enum WhisperHint {
    static func showOnce() {
        DispatchQueue.main.async {
            let t = VoiceTrainer.shared
            guard !t.store.whisperHintShown else { return }
            t.markWhisperHintShown()
            tlog("Flüstern ohne Flüster-Profil erkannt → Hinweis „Flüstern einlernen?“")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { VFNotify.shared.show(notice) }
        }
    }

    static var notice: VFNotice {
        VFNotice(id: "fluestern_einlernen", title: "Flüstern einlernen?",
                 text: "Drei kurze Flüster-Sätze – dann erkennt Flow dich auch leise.",
                 illustration: "illu_stimme", fallbackSymbol: "mouth",
                 primary: ("Jetzt einlernen", { VoiceFlowWindow.shared.show(.training) }), secondary: ("Später", {}), timeout: 20)
    }
}
