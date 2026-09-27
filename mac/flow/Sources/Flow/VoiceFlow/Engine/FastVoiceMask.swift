import FluidAudio
import Foundation

/// Schneller Stimmabgleich für „Nur meine Stimme“ – rechnet schon WÄHREND der Aufnahme.
///
/// Gemessen (MacBook Air M4, 26.09.2026): CAM++ braucht 67 ms pro 1,5-s-Fenster, die Fenster laufen nacheinander.
/// Nach dem Loslassen war der Abgleich der Engpass (8,2 s Ton → ~650 ms, 16 s → ~1,1 s, 28 s mit Rest-Stück → ~3,8 s).
///
/// Jetzt:
/// - **Sitzung**: Das Diktat bekommt eine Nummer. `prefeed` rechnet alle 0,5 s die neu vollständigen groben Fenster
///   (1,5 s, Raster 1,0 s) und – bei verdächtigen Stellen – gleich das feine 0,5-s-Raster darum. Gespeichert wird der
///   Fingerabdruck (nicht die Ähnlichkeit): so zählt beim Urteil immer das aktuelle Stimmmodell.
/// - **Urteil** (`mask`): nimmt die gespeicherten Fenster, rechnet nur noch die letzten 1–2 Fenster und fehlende feine
///   Stellen. Stücke (`processChunk`) und das Rest-Stück finden ihre Fenster über `offset` (Positionen ab `tap.begin()`).
/// - Stummschalt-Regeln unverändert wie VoiceID.mask: 50-ms-Raster, ±0,3 s gemittelt, nur Stücke ≥ 0,6 s unter 0,45.
///
/// Das Raster liegt absolut (Vielfache von 1,0 s bzw. 0,5 s ab Aufnahme-Beginn). Für `offset == 0` sind die Fenster
/// damit genau die der früheren Fassung (gleiches Urteil); bei Stücken liegen sie bis zu 0,5 s anders.
actor FastVoiceMask {
    static let shared = FastVoiceMask()
    private var embedder: CampPlusEmbedder?
    /// Grobes Raster
    var hop = 16_000
    static let win = 24_000
    let win = FastVoiceMask.win
    /// Feines Raster (wie VoiceID.mask)
    let fine = 8_000
    /// Sicherheitsabstand über der Stumm-Schwelle 0,45
    var margin: Float = 0.12

    /// Ähnlichkeit eines Fensters zur eigenen Stimme (austauschbar für Tests/Stimmmodell).
    /// (Fingerabdruck, Fenster geflüstert?) → Ähnlichkeit auf der Skala von VoiceID (0,6 = Schwelle, 0,45 = Stummschalten)
    /// Standard: Stimmmodell (geflüsterte Fenster → Flüster-Profil; ohne Flüster-Profil neutral = nie „fremd“)
    nonisolated(unsafe) static var scorer: @Sendable ([Float], Bool) -> Float = { e, w in VoiceTrainer.shared.score(e, whisper: w).effective }
    /// Merkmal pro Fenster: geflüstert? (WhisperDetector, ~0,3 ms) – wird mit dem Fingerabdruck gespeichert
    nonisolated(unsafe) static var windowFlag: @Sendable ([Float]) -> Bool = { WhisperDetector.isWhisper($0) }
    /// Zählt ein Fenster als „Ton da“? Wie VoiceID (EchoFilter.hasSound) – geflüsterte Fenster zählen auch, wenn sie leiser sind
    nonisolated(unsafe) static var hasSound: @Sendable ([Float], Bool) -> Bool = { s, w in w || EchoFilter.hasSound(s) }
    /// Nach jedem Urteil im Diktat (mit Sitzung): Fenster + Ergebnis → Flüster-Hinweis und Anpassung aus Diktaten
    nonisolated(unsafe) static var onVerdict: (@Sendable (Verdict) -> Void)? = { VoiceAdapter.shared.observe($0) }

    struct Verdict: Sendable {
        /// (Fingerabdruck, geflüstert?, Ähnlichkeit)
        let windows: [(emb: [Float], whisper: Bool, sim: Float)]
        let kind: Kind
        let seconds: Double
        enum Kind: Sendable { case mine, masked, notMe }
    }

    private func load() async throws -> CampPlusEmbedder {
        if let e = embedder { return e }
        let e = try await CampPlusEmbedder.load()
        embedder = e
        return e
    }

    func prepare() async { _ = try? await load() }

    // MARK: Sitzung (ein Diktat)

    /// Gespeichertes Fenster: nil-Fingerabdruck = kein Ton (wird übersprungen)
    struct Window: Sendable { let emb: [Float]?; let flag: Bool }
    private var session: Int?
    private var cache: [Int: Window] = [:]
    /// Nächstes grobes Fenster, das `prefeed` rechnen soll
    private var nextCoarse = 0
    /// Feine Stellen, die noch auf Ton warten
    private var pendingFine = Set<Int>()
    /// Gerade laufende Berechnungen (Vorlauf und Urteil können sich überschneiden → nie doppelt rechnen)
    private var inFlight: [Int: Task<Window, Never>] = [:]

    private func use(_ id: Int) {
        guard session != id else { return }
        session = id
        cache = [:]
        nextCoarse = 0
        pendingFine = []
        inFlight = [:]
    }

    /// Sitzung verwerfen (Abbruch, Befehlsmodus, fertig)
    func discard(session id: Int) {
        guard session == id else { return }
        session = nil
        cache = [:]
        pendingFine = []
        inFlight = [:]
    }

    /// Während der Aufnahme: `seg` = Aufnahme ab Position `base` (Samples ab `tap.begin()`).
    /// Rechnet die neu vollständigen groben Fenster (+ feines Raster um verdächtige). Gibt zurück, ab welcher
    /// Position der nächste Aufruf Ton braucht (für `tap.peek(from:)`).
    @discardableResult
    func prefeed(_ seg: [Float], base: Int, session id: Int) async -> Int {
        use(id)
        let end = base + seg.count
        guard let e = try? await load() else { return nextNeeded() }
        var computed = 0
        // 1) Feine Stellen, deren Ton jetzt da ist
        for k in pendingFine.sorted() where k >= base && k + win <= end {
            pendingFine.remove(k)
            _ = await window(at: k, samples: seg, base: base, e: e)
            computed += 1
            if session != id { return 0 }
        }
        // 2) Neue grobe Fenster
        while nextCoarse + win <= end {
            let g = nextCoarse
            nextCoarse += hop
            guard g >= base else { continue }
            let w = await window(at: g, samples: seg, base: base, e: e)
            computed += 1
            if session != id { return 0 }
            if let emb = w.emb, FastVoiceMask.scorer(emb, w.flag) < 0.45 + margin {
                // verdächtig → feines Raster ±1 s gleich mitrechnen (was schon Ton hat), Rest später
                var k = max(0, g - hop)
                while k <= g + hop {
                    if cache[k] == nil {
                        if k >= base, k + win <= end { _ = await window(at: k, samples: seg, base: base, e: e); computed += 1 }
                        else if k + win > end { pendingFine.insert(k) }
                    }
                    if session != id { return 0 }
                    k += fine
                }
            }
        }
        return nextNeeded()
    }

    private func nextNeeded() -> Int { max(0, min(nextCoarse, pendingFine.min() ?? Int.max)) }

    /// Fenster ab absoluter Position `at` – aus dem Speicher, aus einer laufenden Berechnung oder neu.
    /// `shared` = Sitzungs-Speicher benutzen (nur für die laufende Sitzung).
    private func window(at: Int, samples: [Float], base: Int, e: CampPlusEmbedder, shared: Bool = true) async -> Window {
        if shared {
            if let w = cache[at] { return w }
            if let t = inFlight[at] { return await t.value }
        }
        let a = at - base
        guard a >= 0, a + win <= samples.count else { return Window(emb: nil, flag: false) }
        let chunk = Array(samples[a..<(a + win)])
        let t = Task { () -> Window in
            let flag = FastVoiceMask.windowFlag(chunk)
            guard FastVoiceMask.hasSound(chunk, flag), let v = try? await e.embed(audio: chunk) else { return Window(emb: nil, flag: flag) }
            return Window(emb: v, flag: flag)
        }
        guard shared else { return await t.value }
        let sid = session
        inFlight[at] = t
        let w = await t.value
        if session == sid, sid != nil { inFlight[at] = nil; cache[at] = w }
        return w
    }

    struct Stats: Sendable {
        let windows: Int; let minSim: Float; let best: Float; let fast: Bool
        /// davon aus dem Vorlauf / neu gerechnet
        var cached = 0, computed = 0
        var ms = 0
    }
    private(set) var lastStats: Stats?

    /// Urteil über ein Stück. `offset` = Position des Stücks ab `tap.begin()`; `session` = Diktat-Nummer (nil = ohne Speicher).
    func mask(_ samples: [Float], clipThreshold: Float = VoiceID.threshold, session sid: Int? = nil, offset: Int = 0) async -> VoiceID.MaskResult {
        let t0 = Date()
        guard VoiceID.profile() != nil, let e = try? await load() else { return .unchanged }
        // Nur mit passender Sitzung den Speicher benutzen (sonst rechnet dieser Aufruf alles selbst)
        let withCache = sid != nil && sid == session
        var track: [Int: Float] = [:]   // absolute Fensterposition → Ähnlichkeit
        var seen: [(emb: [Float], whisper: Bool, sim: Float)] = []
        var info: [Int: (emb: [Float], whisper: Bool)] = [:]
        var cachedHits = 0, computed = 0
        func sim(at s: Int) async -> Float? {
            if let v = track[s] { return v }
            let had = withCache && cache[s] != nil
            let w = await window(at: s, samples: samples, base: offset, e: e, shared: withCache)
            if had { cachedHits += 1 } else { computed += 1 }
            guard let emb = w.emb else { return nil }
            let c = FastVoiceMask.scorer(emb, w.flag)
            track[s] = c
            info[s] = (emb, w.flag)
            seen.append((emb, w.flag, c))
            return c
        }
        if samples.count < win {
            guard let v = try? await e.embed(audio: samples) else { return .unchanged }
            let flag = FastVoiceMask.windowFlag(samples)
            let c = FastVoiceMask.scorer(v, flag)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            lastStats = Stats(windows: 1, minSim: c, best: c, fast: true, cached: 0, computed: 1, ms: ms)
            let notMe = c < clipThreshold
            if sid != nil {
                FastVoiceMask.onVerdict?(Verdict(windows: [(v, flag, c)], kind: notMe ? .notMe : .mine, seconds: Double(samples.count) / 16000))
                log(String(format: "Stimmabgleich: bestes %.2f, %@ (kurz, %d ms)", c, notMe ? "klingt nicht nach dir" : "alles eigene Stimme", ms))
            }
            return notMe ? .notMe(bestSim: c) : .unchanged
        }
        let end = offset + samples.count
        // 1) Grobes Raster (absolut, jedes 2. Fenster des feinen Rasters) + ein Fenster bündig am Ende
        var coarse: [Int] = []
        var g = (offset + hop - 1) / hop * hop
        // Stück beginnt zwischen zwei groben Fenstern → erstes feines Fenster ab Stück-Anfang dazu
        let firstFine = (offset + fine - 1) / fine * fine
        if firstFine < g, firstFine + win <= end { coarse.append(firstFine) }
        while g + win <= end { coarse.append(g); g += hop }
        let lastFine = (end - win) / fine * fine
        if lastFine >= offset, coarse.last.map({ $0 < lastFine }) ?? true { coarse.append(lastFine) }
        var suspicious: [Int] = []
        for s in coarse { if let v = await sim(at: s), v < 0.45 + margin { suspicious.append(s) } }
        // 2) Nur um verdächtige Stellen fein nachrechnen (±1 s, 0,5-s-Raster wie VoiceID)
        for s in suspicious {
            var k = max(firstFine, s - hop)
            while k <= min(lastFine, s + hop) { _ = await sim(at: k); k += fine }
        }
        // Fenster, deren Art (geflüstert/normal) nicht zur Mehrheit des Stücks passt, sind oft falsch eingeordnet
        // (stimmlose Laute im normalen Sprechen, kurz stimmhafte Stellen im Flüstern) → bestes aus beiden Arten
        if !info.isEmpty {
            let wMajority = info.values.filter(\.whisper).count * 2 >= info.count
            for (pos, v) in info where v.whisper != wMajority {
                track[pos] = max(track[pos] ?? 0, FastVoiceMask.scorer(v.emb, wMajority))
            }
        }
        let pts = track.map { (t: Double($0.key - offset + win / 2) / 16000, sim: $0.value) }.sorted { $0.t < $1.t }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard !pts.isEmpty else {
            lastStats = Stats(windows: 0, minSim: 0, best: 0, fast: true, cached: cachedHits, computed: computed, ms: ms)
            return .unchanged
        }
        let best = pts.map(\.sim).max() ?? 0
        lastStats = Stats(windows: pts.count, minSim: pts.map(\.sim).min() ?? 0, best: best, fast: suspicious.isEmpty,
                          cached: cachedHits, computed: computed, ms: ms)
        // Protokoll nur im Diktat (mit Sitzung) – gleiches Format wie VoiceID („bestes 0.87“ zählt fürs Training)
        func report(_ what: String, _ kind: Verdict.Kind) {
            guard sid != nil else { return }
            FastVoiceMask.onVerdict?(Verdict(windows: seen, kind: kind, seconds: Double(samples.count) / 16000))
            log(String(format: "Stimmabgleich: bestes %.2f, %@ (%d Fenster, %d vorab, %d ms)", best, what, pts.count, cachedHits, ms))
        }
        if best < clipThreshold { report("klingt nicht nach dir", .notMe); return .notMe(bestSim: best) }
        // 3) Stummschalten – gleiche Regeln wie VoiceID.mask (50-ms-Raster, ±0,3 s gemittelt, nur Stücke ≥ 0,6 s unter 0,45)
        let runs = FastVoiceMask.muteRuns(pts: pts, count: samples.count)
        guard !runs.isEmpty else { report("alles eigene Stimme", .mine); return .unchanged }
        var out = samples
        var muted = 0
        for (a, b) in runs {
            for j in a..<min(b, out.count) { out[j] = 0 }
            muted += min(b, out.count) - a
        }
        report(String(format: "%.1f s fremde Stimme stummgeschaltet", Double(muted) / 16000), .masked)
        return .masked(out, mutedSeconds: Double(muted) / 16000)
    }

    /// Rand-Zugabe: ein Stumm-Stück wird an jedem Ende um bis zu so viele Sekunden verlängert, solange die (gemittelte)
    /// Ähnlichkeit dort noch unter `edgeSim` liegt. Grund: 1,5-s-Fenster über der Grenze fremd/ich mischen beide Stimmen,
    /// dadurch blieb vom Rand der fremden Stimme oft ein Wort übrig (gemessen: 3 s `say` → nur 1,1–1,9 s gestummt).
    /// Gemessen (`--mask-edges`, 10 Fälle à 3 s fremd, neues Modell): 0 s → 19,5 s gestummt innen / 0,1 s außen;
    /// 0,25 s @ 0,50 → 21,0 s / 0,3 s, verlorene eigene Wörter gleich (4 = Erkennungs-Schwankung auch ohne Zugabe);
    /// 0,25 s @ 0,55 kostete 2 eigene Wörter mehr → nicht genommen.
    nonisolated(unsafe) static var edgeExtend: Double = 0.25
    nonisolated(unsafe) static var edgeSim: Float = 0.50

    /// Stumm-Stücke (Sample-Bereiche) aus der Ähnlichkeits-Spur – Regeln wie VoiceID.mask
    /// (50-ms-Raster, ±0,3 s gemittelt, nur Stücke ≥ 0,6 s unter 0,45), dann Rand-Zugabe.
    static func muteRuns(pts: [(t: Double, sim: Float)], count: Int) -> [(Int, Int)] {
        let step = 800, n = count / step + 1
        var mute = [Bool](repeating: false, count: n)
        var val = [Float](repeating: 1, count: n)
        for k in 0..<n {
            let t = Double(k * step) / 16000
            let near = pts.filter { abs($0.t - t) <= 0.3 }.map(\.sim)
            let v = near.isEmpty ? pts.min { abs($0.t - t) < abs($1.t - t) }!.sim : near.reduce(0, +) / Float(near.count)
            val[k] = v
            mute[k] = v < 0.45
        }
        var runs: [(Int, Int)] = []
        var k = 0
        while k < n {
            if mute[k] { let a = k; while k < n && mute[k] { k += 1 }; if (k - a) * step >= 9600 { runs.append((a, k)) } } else { k += 1 }
        }
        let ext = Int((edgeExtend * 16000 / Double(step)).rounded())
        var out: [(Int, Int)] = []
        for (i, r) in runs.enumerated() {
            var a = r.0, b = r.1
            let lo = i > 0 ? runs[i - 1].1 : 0, hi = i + 1 < runs.count ? runs[i + 1].0 : n
            var e = 0
            while e < ext, a - 1 >= lo, val[a - 1] < edgeSim { a -= 1; e += 1 }
            e = 0
            while e < ext, b < hi, val[b] < edgeSim { b += 1; e += 1 }
            out.append((a * step, min(count, b * step)))
        }
        return out
    }

    /// Stumm geschaltete Bereiche (in Sekunden) aus einer maskierten Aufnahme: Folgen exakter Nullen ≥ 0,6 s.
    static func mutedSpans(_ masked: [Float]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var i = 0
        let n = masked.count
        while i < n {
            if masked[i] == 0 {
                let a = i
                while i < n && masked[i] == 0 { i += 1 }
                if i - a >= 9600 { out.append((Double(a) / 16000, Double(i) / 16000)) }
            } else { i += 1 }
        }
        return out
    }

    /// Wörter (mit Zeiten aus der ersten Erkennung) ohne die stumm geschalteten Bereiche – statt ein zweites Mal zu erkennen.
    /// Ein Wort fällt weg, wenn seine Mitte in einem stummen Bereich liegt.
    static func cut(_ words: [TimedWord], muted: [(Double, Double)]) -> String {
        words.filter { w in
            let m = (w.start + w.end) / 2
            return !muted.contains { m >= $0.0 && m <= $0.1 }
        }.map(\.word).joined(separator: " ")
    }
}

/// Wort mit Zeit (Sekunden ab Anfang der erkannten Samples)
struct TimedWord: Sendable, Equatable {
    let word: String
    let start: Double
    let end: Double
}
