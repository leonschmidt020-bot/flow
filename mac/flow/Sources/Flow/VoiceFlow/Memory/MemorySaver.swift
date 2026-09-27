import AppKit
import SwiftUI

/// „Speicher sparen“: große Modelle nur im Speicher halten, solange sie gebraucht werden.
///
/// Gemessen auf einem M4 Pro (26.09.2026, `Flow --mem-probe` / `--mem-idle-test`):
/// - whisper-server (large-v3-turbo q5_0, Metal) belegt 0,7–0,85 GB. Kaltstart 0,25–0,45 s (auch ohne Datei-Cache),
///   die erste Erkennung danach ist NICHT langsamer als warm → Parken + Start beim Fn-Druck (parallel zum Sprechen) kostet
///   praktisch nichts.
/// - Sprechertrennung (pyannote + VBx) wird nur für die Meeting-Auswertung gebraucht → danach freigeben (~40–55 MB).
/// - Parakeet bleibt geladen: seine ~0,58 GB Neural-Engine-Speicher sind laut `footprint` „Reclaimable“ (macOS nimmt sie
///   bei Speicherdruck selbst weg, zählt nicht zum Footprint) und werden durch Entladen (AsrManager.cleanup) NICHT frei –
///   gemessen wurden nur ~35 MB. Das lohnt das Risiko nicht.
enum SpeicherModus: String, Codable, CaseIterable, Hashable {
    case auto, aus, stark

    var label: String {
        switch self {
        case .auto: return "Automatisch (empfohlen)"
        case .aus: return "Aus – alles bleibt geladen"
        case .stark: return "Stark sparen"
        }
    }
}

struct SpeicherProfil: Equatable {
    /// Whisper-Server nach so vielen Sekunden ohne Diktat parken (nil = nie)
    var whisperIdle: TimeInterval?
    /// Sprechertrennung nach der Meeting-Auswertung freigeben
    var diarizerIdle: TimeInterval
}

final class MemorySaver {
    static let shared = MemorySaver()

    static let fileURL = Paths.base.appendingPathComponent("speicher.json")
    private struct Stored: Codable { var modus: SpeicherModus }

    private(set) var modus: SpeicherModus = .auto
    private var timer: Timer?
    private var lastTrim = Date.distantPast

    static var ramGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }
    /// 8/16-GB-Macs (z. B. MacBook Air M4) sparen stärker als 24/36/48-GB-Macs.
    static var smallMac: Bool { ramGB < 20 }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Stored.self, from: d) { modus = s.modus }
    }

    static func profil(for modus: SpeicherModus, smallMac: Bool = MemorySaver.smallMac) -> SpeicherProfil {
        switch modus {
        // Sprechertrennung wird in jedem Modus nach der Meeting-Auswertung freigegeben (kein Nachteil messbar).
        case .aus: return SpeicherProfil(whisperIdle: nil, diarizerIdle: 120)
        case .auto: return smallMac ? SpeicherProfil(whisperIdle: 3 * 60, diarizerIdle: 60)
                                    : SpeicherProfil(whisperIdle: 10 * 60, diarizerIdle: 120)
        case .stark: return SpeicherProfil(whisperIdle: 45, diarizerIdle: 30)
        }
    }

    var profil: SpeicherProfil { Self.profil(for: modus) }

    func setModus(_ m: SpeicherModus) {
        modus = m
        if let d = try? JSONEncoder().encode(Stored(modus: m)) {
            try? d.write(to: Self.fileURL, options: .atomic)
            chmod(Self.fileURL.path, 0o600)
        }
        log("Speicher sparen: \(m.rawValue) (\(String(format: "%.0f", Self.ramGB)) GB RAM)")
        tick()
    }

    /// Einmal beim App-Start (nach dem Laden der Modelle).
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let p = profil
        log("Speicher sparen: \(modus.rawValue), \(String(format: "%.0f", Self.ramGB)) GB RAM – Whisper parken nach \(p.whisperIdle.map { "\(Int($0))s" } ?? "nie")")
    }

    /// Hotkey-Ereignis (kommt vom Event-Tap-Thread – nur billige, threadsichere Aufrufe).
    func hotkey(_ e: HotkeyMonitor.Event) {
        switch e {
        case .pressStart, .doubleTap, .commandStart: dictationWillStart()
        default: break
        }
    }

    /// Diktat beginnt gleich: geparkte Modelle jetzt starten – parallel zum Sprechen.
    func dictationWillStart() {
        WhisperEngine.shared.noteActivity()
    }

    private func tick() {
        let p = profil
        let app = NSApp?.delegate as? AppDelegate
        let dictating = app?.dictation?.isBusy ?? false
        Task.detached(priority: .utility) { await Diarizer.shared.releaseIfIdle(after: p.diarizerIdle) }
        guard !dictating else { return }
        if let w = p.whisperIdle { WhisperEngine.shared.parkIfIdle(after: w) }
        // Höchstens einmal pro Minute und nie während eines Diktats/einer Auswertung (kostet ~1 ms)
        let meetingBusy = MeetingStore.shared.meetings.contains { $0.status == .processing }
        if !meetingBusy, Date().timeIntervalSince(lastTrim) >= 60 {
            lastTrim = Date()
            let freed = Self.trimMalloc()
            if freed > 32 << 20 { log(String(format: "Speicher sparen: %.0f MB freie Blöcke an macOS zurückgegeben", Double(freed) / 1_048_576)) }
        }
    }

    /// Freigegebene, aber noch belegte malloc-Blöcke an macOS zurückgeben („MALLOC_LARGE (empty)“).
    /// Nach einer 30-min-Meeting-Auswertung gemessen: ~370 MB große + ~100 MB kleine leere Blöcke blieben sonst im Footprint,
    /// bis macOS selbst unter Speicherdruck aufräumt. Liefert die freigegebenen Bytes.
    @discardableResult
    static func trimMalloc() -> Int { Int(malloc_zone_pressure_relief(nil, 0)) }

    /// Kurzer Zustand für die Einstellungen.
    var statusLine: String {
        let p = profil
        func dur(_ s: TimeInterval?) -> String {
            guard let s else { return "nie" }
            return s < 120 ? "\(Int(s)) s" : "\(Int(s / 60)) Min."
        }
        var parts = [String(format: "Dieser Mac: %.0f GB.", Self.ramGB)]
        switch modus {
        case .aus:
            parts.append("Whisper (~0,7–0,85 GB) bleibt immer geladen.")
        case .auto, .stark:
            parts.append("Whisper (~0,7–0,85 GB) pausiert nach \(dur(p.whisperIdle)) ohne Diktat und startet beim Fn-Druck in ~0,3 s – während du sprichst.")
        }
        if WhisperEngine.shared.parked { parts.append("Gerade pausiert.") }
        return parts.joined(separator: " ")
    }
}

/// Zeile „Speicher sparen“ für Einstellungen → Allgemein.
struct MemorySaverSettingRow: View {
    @State private var modus = MemorySaver.shared.modus
    @State private var status = MemorySaver.shared.statusLine

    var body: some View {
        PGSettingRow(title: "Speicher sparen", detail: detail) {
            PGChoiceMenu(selection: $modus, options: SpeicherModus.allCases, label: { $0.label }) { m in
                MemorySaver.shared.setModus(m)
                status = MemorySaver.shared.statusLine
            }
        }
        .onAppear { modus = MemorySaver.shared.modus; status = MemorySaver.shared.statusLine }
    }

    private var detail: String {
        let head: String
        switch modus {
        case .auto: head = MemorySaver.smallMac ? "Automatisch: spart kräftig, weil dieser Mac wenig Arbeitsspeicher hat." : "Automatisch: spart nur bei längeren Pausen."
        case .aus: head = "Aus: Whisper bleibt dauerhaft im Speicher."
        case .stark: head = "Stark: pausiert Whisper schon nach kurzer Pause. Genauigkeit und Tempo bleiben gleich."
        }
        return head + " " + status
    }
}
