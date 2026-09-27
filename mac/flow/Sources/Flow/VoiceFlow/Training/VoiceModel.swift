import Foundation

/// Das Stimmmodell für „Nur meine Stimme“ – getrennt für normale Stimme und Flüstern.
///
/// Pro Art:
/// - **mehrere Mittelpunkte** (k-means über die Level-Fenster + sichere Diktat-Fenster) statt eines Mittels,
/// - **Kohorten-Abgleich**: Ähnlichkeit zur eigenen Stimme minus mittlere Ähnlichkeit zu den 3 ähnlichsten Vergleichsstimmen
///   (TTS, bei Flüstern geflüsterte TTS). Das gleicht aus, dass leise/ferne/geflüsterte Aufnahmen zu ALLEN Stimmen
///   weniger ähnlich sind (gemessen: eigene Stimme leise Ø 0,49 roh → wird trotzdem sicher erkannt; fremde TTS 29 % → 4 %),
/// - **Negativ-Stimmen** (z. B. Geschwister): Marge = Ähnlichkeit(ich) − Ähnlichkeit(ähnlichste Negativ-Stimme).
///
/// Ergebnis ist eine Zahl auf der Skala von VoiceID: 0,6 = Grenze „ist meine Stimme“, unter 0,45 wird stummgeschaltet.
/// So bleiben VoiceID/FastVoiceMask/Dictation unverändert gültig.
struct VoiceModel: Sendable, Equatable {
    enum Mode: String, Codable, Sendable, CaseIterable { case normal, whisper }

    struct Part: Sendable, Equatable {
        var centroids: [[Float]]
        /// Vergleichsstimmen (Fingerabdrücke)
        var cohort: [[Float]]
        /// Negativ-Stimmen (Mittelpunkte)
        var negatives: [[Float]]
        /// Grenze für (ich − Kohorte), gemessen
        var threshold: Float
        /// Mindest-Marge gegen Negativ-Stimmen, gemessen
        var negMargin: Float
    }

    var normal: Part?
    var whisper: Part?
    /// Rohe Schwelle, solange es noch keine Vergleichsstimmen gibt: gemessener Vorschlag, begrenzt auf 0,55…0,72
    var rawThreshold: Float = VoiceModel.defaultRaw

    static let defaultRaw: Float = 0.6
    static let boundary: Float = 0.6
    /// Absolute Untergrenze der rohen Ähnlichkeit (gegen Rauschen/Geräusche, die zu allen Stimmen unähnlich sind)
    static let rawFloor: Float = 0.30
    static let empty = VoiceModel(normal: nil, whisper: nil)

    var hasWhisper: Bool { !(whisper?.centroids.isEmpty ?? true) }
    var hasNormal: Bool { !(normal?.centroids.isEmpty ?? true) }

    struct Score: Sendable {
        var me: Float
        var cohort: Float?
        var negative: Float?
        /// Skala wie VoiceID (0,6 = Grenze)
        var effective: Float
        var mode: Mode
        /// Flüstern, aber noch kein Flüster-Profil → neutral (nicht verwerfen)
        var neutral: Bool
    }

    /// Bewertet einen Fingerabdruck. `whisper` = Fenster klingt geflüstert (WhisperDetector).
    func score(_ e: [Float], whisper isW: Bool, extra: [[Float]] = []) -> Score {
        if isW {
            guard let w = whisper, !w.centroids.isEmpty else {
                // Kein Flüster-Profil: geflüsterte Stelle nie als fremd werten
                let me = VoiceModel.maxCos(e, (normal?.centroids ?? []) + extra)
                return Score(me: me, cohort: nil, negative: nil, effective: VoiceModel.boundary, mode: .whisper, neutral: true)
            }
            return score(e, part: w, extra: [], mode: .whisper)
        }
        guard let n = normal, !n.centroids.isEmpty else {
            let me = VoiceModel.maxCos(e, extra)
            return Score(me: me, cohort: nil, negative: nil, effective: me, mode: .normal, neutral: false)
        }
        return score(e, part: n, extra: extra, mode: .normal)
    }

    private func score(_ e: [Float], part p: Part, extra: [[Float]], mode: Mode) -> Score {
        let me = VoiceModel.maxCos(e, p.centroids + extra)
        var eff: Float
        var coh: Float?
        if p.cohort.count >= 3 {
            let c = VoiceModel.topMean(e, p.cohort, k: 3)
            coh = c
            eff = VoiceModel.boundary + (me - c - p.threshold)
        } else {
            eff = VoiceModel.boundary + (me - rawThreshold)
        }
        var neg: Float?
        if !p.negatives.isEmpty {
            let n = VoiceModel.maxCos(e, p.negatives)
            neg = n
            eff = min(eff, VoiceModel.boundary + (me - n - p.negMargin))
        }
        // Zu allen unähnlich (Geräusch, Knacken): nie als „ich“ werten
        if me < VoiceModel.rawFloor { eff = min(eff, VoiceModel.boundary - 0.2) }
        return Score(me: me, cohort: coh, negative: neg, effective: eff, mode: mode, neutral: false)
    }

    // MARK: Mathe

    static func maxCos(_ e: [Float], _ cs: [[Float]]) -> Float {
        var best: Float = -1
        for c in cs { let v = Vec.cos(e, c); if v > best { best = v } }
        return cs.isEmpty ? 0 : best
    }

    static func topMean(_ e: [Float], _ cs: [[Float]], k: Int) -> Float {
        let s = cs.map { Vec.cos(e, $0) }.sorted(by: >)
        let n = min(k, s.count)
        return n == 0 ? 0 : s.prefix(n).reduce(0, +) / Float(n)
    }

    /// Sphärisches k-means (Kosinus), deterministisch: Start mit dem Fenster nahe am Mittel, dann jeweils das entfernteste.
    static func kmeans(_ xs: [[Float]], k: Int, iterations: Int = 25) -> [[Float]] {
        let x = xs.map(Vec.norm)
        guard !x.isEmpty else { return [] }
        let k = max(1, min(k, x.count))
        guard let mean = Vec.mean(x) else { return [] }
        var c: [[Float]] = [x.max { Vec.cos($0, mean) < Vec.cos($1, mean) }!]
        while c.count < k {
            let far = x.max { a, b in maxCos(a, c) > maxCos(b, c) }!
            c.append(far)
        }
        for _ in 0..<iterations {
            var groups = [[[Float]]](repeating: [], count: k)
            for v in x {
                var bi = 0; var bs: Float = -2
                for (i, ci) in c.enumerated() { let s = Vec.cos(v, ci); if s > bs { bs = s; bi = i } }
                groups[bi].append(v)
            }
            var changed = false
            for i in 0..<k where !groups[i].isEmpty {
                let m = Vec.mean(groups[i])!
                if Vec.cos(m, c[i]) < 0.9999 { changed = true }
                c[i] = m
            }
            if !changed { break }
        }
        return c
    }

    /// Mittelpunkte für eine Art: k-means (k nach Datenmenge) + die Level-Mittel selbst
    static func centroids(windows: [[Float]], levelMeans: [[Float]], perCluster: Int = 8, maxK: Int = 4) -> [[Float]] {
        guard !windows.isEmpty else { return levelMeans }
        let k = max(1, min(maxK, windows.count / perCluster))
        return kmeans(windows, k: k) + levelMeans
    }

    // MARK: Schwellen messen

    struct Calibration: Sendable, Equatable {
        /// Grenze (ich − Kohorte)
        var threshold: Float
        /// eigene zurückgehaltene Fenster (ich − Kohorte): 10-%-Wert, Mittel
        var ownLow: Float
        var ownMean: Float
        /// Vergleichsstimmen gegen das Modell (ohne sich selbst in der Kohorte): höchster Wert
        var impostorMax: Float
        /// Anteil der eigenen Fenster über der Grenze / der fremden darüber
        var ownAccept: Float
        var impostorAccept: Float
        /// Trennschärfe = ownMean − impostorMax
        var separation: Float { ownMean - impostorMax }
    }

    /// `groups` = eigene Fenster je Aufnahme (Level/Take): jedes Fenster wird gegen ein Modell OHNE seine Gruppe geprüft.
    /// `cohortGroups` = Vergleichsstimmen je Stimme: jede gegen die Kohorte OHNE sich selbst.
    static func calibrate(groups: [[[Float]]], cohortGroups: [[[Float]]], extra: [[Float]] = [],
                          clamp: ClosedRange<Float>) -> Calibration? {
        let flatCohort = cohortGroups.flatMap { $0 }
        guard flatCohort.count >= 3, groups.flatMap({ $0 }).count >= 3 else { return nil }
        var own: [Float] = []
        for (gi, g) in groups.enumerated() {
            let rest = groups.enumerated().filter { $0.offset != gi }.flatMap { $0.element }
            // Eine einzige Gruppe (z. B. nur Level 6): Fenster einzeln zurückhalten
            if rest.isEmpty {
                for (i, w) in g.enumerated() {
                    var others = g; others.remove(at: i)
                    guard let m = Vec.mean(others) else { continue }
                    own.append(maxCos(w, [m] + extra) - topMean(w, flatCohort, k: 3))
                }
                continue
            }
            let model = centroids(windows: rest, levelMeans: [], perCluster: 8, maxK: 4) + extra
            for w in g { own.append(maxCos(w, model) - topMean(w, flatCohort, k: 3)) }
        }
        let full = centroids(windows: groups.flatMap { $0 }, levelMeans: [], perCluster: 8, maxK: 4) + extra
        var imp: [Float] = []
        for (ci, cg) in cohortGroups.enumerated() {
            let others = cohortGroups.enumerated().filter { $0.offset != ci }.flatMap { $0.element }
            guard others.count >= 3 else { continue }
            for w in cg { imp.append(maxCos(w, full) - topMean(w, others, k: 3)) }
        }
        guard !own.isEmpty, !imp.isEmpty else { return nil }
        let js = own.sorted()
        let low = js[js.count / 10]
        let mean = own.reduce(0, +) / Float(own.count)
        let iMax = imp.max()!
        // Mitte zwischen den schwächsten 10 % von mir und der ähnlichsten fremden Stimme
        let thr = min(clamp.upperBound, max(clamp.lowerBound, (low + iMax) / 2))
        return Calibration(threshold: thr, ownLow: low, ownMean: mean, impostorMax: iMax,
                           ownAccept: Float(own.filter { $0 >= thr }.count) / Float(own.count),
                           impostorAccept: Float(imp.filter { $0 >= thr }.count) / Float(imp.count))
    }

    /// Marge gegen Negativ-Stimmen: halber 5-%-Wert der eigenen Margen (ich − negativ), höchstens 0,05.
    /// Gemessen an einer sehr ähnlichen Stimme (FaceTime, 35 s eingelernt, andere 35 s geprüft): Marge 0,03 → ähnliche Stimme 78 % → 11 % angenommen,
    /// eigene Diktate unverändert.
    static func negativeMargin(own: [[Float]], model: [[Float]], negatives: [[Float]]) -> Float {
        guard !negatives.isEmpty, !own.isEmpty else { return 0.03 }
        let m = own.map { maxCos($0, model) - maxCos($0, negatives) }.sorted()
        let p5 = m[max(0, Int(Double(m.count) * 0.05))]
        return max(0, min(0.05, p5 / 2))
    }
}
