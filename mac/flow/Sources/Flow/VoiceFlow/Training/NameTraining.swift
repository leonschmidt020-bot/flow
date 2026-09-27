import Foundation
import NaturalLanguage

/// Art des Worts – bestimmt die Übungssätze und den Whisper-Hinweis.
enum NameKind: String, CaseIterable, Codable, Identifiable {
    case person, company, place, term
    var id: String { rawValue }
    var label: String {
        switch self { case .person: return "Person"; case .company: return "Firma"; case .place: return "Ort"; case .term: return "Begriff" }
    }

    /// Grobe Vermutung (NLTagger + Wörterbuch-Regeln); man kann im Blatt umstellen.
    static func guess(_ word: String) -> NameKind {
        let w = word.trimmingCharacters(in: .whitespaces)
        let lower = w.lowercased()
        if ["gmbh", "ag", "inc", "studio", "studios", "ltd", "ug"].contains(where: { lower.hasSuffix(" " + $0) || lower == $0 }) { return .company }
        // Abkürzungen mit Großbuchstaben innen (KiTaNet, IKEA) → eher Firma/Organisation
        if w.dropFirst().contains(where: { $0.isUppercase }) { return .company }
        let tagger = NLTagger(tagSchemes: [.nameType])
        for probe in ["Ich habe mit \(w) gesprochen.", "Ich war gestern in \(w).", "Ich arbeite bei \(w)."] {
            tagger.string = probe
            var found: NameKind?
            tagger.enumerateTags(in: probe.startIndex..<probe.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
                guard probe[r].contains(w.split(separator: " ").first.map(String.init) ?? w) else { return true }
                switch tag {
                case .personalName?: found = .person
                case .placeName?: found = .place
                case .organizationName?: found = .company
                default: break
                }
                return found == nil
            }
            if let found { return found }
        }
        if TrainingText.isRealWord(w) { return .term }
        return w.first?.isUppercase == true ? .person : .term
    }
}

/// Übungssätze: Name vorn, in der Mitte, am Ende; Deutsch und Englisch; kurz und natürlich.
enum TrainingSentences {
    private static let de: [NameKind: [String]] = [
        .person: ["Ich hab heute mit {X} telefoniert.", "{X}, kannst du mir das schicken?", "Das Meeting mit {X} ist am Freitag.",
                  "Schreib bitte {X}, dass ich später komme.", "Morgen treffe ich {X} im Büro.", "Hat {X} sich schon gemeldet?"],
        .company: ["Ich arbeite gerade an einem Projekt für {X}.", "{X} hat die Rechnung schon bezahlt.", "Das Angebot von {X} kam heute.",
                   "Wir fahren nachher noch zu {X}.", "Bei {X} gibt es das günstiger.", "Hast du {X} schon angerufen?"],
        .place: ["Ich bin heute in {X}.", "{X} ist nicht weit von hier.", "Wir fahren am Wochenende nach {X}.",
                 "Das Treffen findet in {X} statt.", "Warst du schon mal in {X}?", "Von {X} aus sind es zwei Stunden."],
        .term: ["Kannst du {X} kurz erklären?", "{X} funktioniert jetzt richtig gut.", "Ich schreibe gerade über {X}.",
                "Das Thema heute ist {X}.", "Hast du {X} schon ausprobiert?", "Mit {X} geht das viel schneller."],
    ]
    private static let en: [NameKind: [String]] = [
        .person: ["I talked to {X} about the budget.", "{X}, can you send me the file?", "Let's set up a call with {X} next week.",
                  "Did {X} reply yet?", "I'll meet {X} at the office.", "Please tell {X} I'm running late."],
        .company: ["I'm working on a project for {X}.", "{X} sent the invoice today.", "We had a meeting with {X} this morning.",
                   "Did you call {X} yet?", "The offer from {X} looks good.", "I'll drive over to {X} later."],
        .place: ["I'm driving to {X} tomorrow.", "{X} is about an hour away.", "We're staying in {X} this weekend.",
                 "Have you ever been to {X}?", "The meeting is in {X}.", "From {X} it's two hours by train."],
        .term: ["{X} works really well now.", "Can you explain {X} to me?", "Today's topic is {X}.",
                "Have you tried {X} yet?", "I'm writing about {X} right now.", "With {X} this is much faster."],
    ]

    /// 6 Sätze. Sprache: "de", "en" oder "both" (4 × Deutsch, 2 × Englisch). Positionen gemischt (Anfang, Mitte, Ende).
    static func make(_ word: String, kind: NameKind, language: String, count: Int = WordTrainer.takesPerWord) -> [String] {
        let d = de[kind] ?? [], e = en[kind] ?? []
        let pick: [String]
        switch language {
        case "en": pick = e
        case "de": pick = d
        default: pick = [d[0], e[0], d[1], d[2], e[1], d[4]]
        }
        return Array(pick.prefix(count)).map { $0.replacingOccurrences(of: "{X}", with: word) }
    }

    /// Sprache eines Übungssatzes (für Whisper)
    static func language(of sentence: String) -> String {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english]
        r.processString(sentence)
        return r.dominantLanguage == .english ? "en" : "de"
    }
}

/// Wort-Ausrichtung: erkannter Text ↔ bekannter Satz. Liefert die Wörter, die dort stehen, wo der Name hingehört.
enum SentenceAlign {
    struct Hit: Equatable {
        /// Index-Bereich im erkannten Text (leer = Name ganz verschluckt)
        let range: Range<Int>
        /// Wörter im erkannten Text an dieser Stelle
        let text: String
        /// Nachbarwörter im bekannten Satz (klein)
        let left: String?
        let right: String?
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func key(_ w: String) -> String { NamePhonetics.letters(w) }

    /// Kosten fürs Gegenüberstellen zweier Wörter (0 = gleich, 1 = ganz anders)
    private static func subCost(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { return 1 }
        let d = Double(VocabTrigger.levenshtein(Array(a), Array(b))) / Double(max(a.count, b.count))
        return min(1, d * 1.2)
    }

    /// Findet die Stelle des Ziels im erkannten Text. nil, wenn der Satz kaum wiederzuerkennen ist.
    static func locate(recognized: [String], sentence: String, target: String) -> Hit? {
        let sw = tokens(sentence), sk = sw.map(key)
        let tk = tokens(target).map(key).filter { !$0.isEmpty }
        let rk = recognized.map(key)
        guard !tk.isEmpty, let tStart = (0...max(0, sk.count - tk.count)).first(where: { Array(sk[$0..<min(sk.count, $0 + tk.count)]) == tk }) else { return nil }
        let tEnd = tStart + tk.count
        // Satz OHNE Ziel gegen erkannten Text ausrichten; Nachbarn des Ziels als Anker
        let n = sk.count, m = rk.count
        var d = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n where i > 0 { d[i][0] = d[i - 1][0] + ((tStart..<tEnd).contains(i - 1) ? 0.3 : 1) }
        for j in 0...m where j > 0 { d[0][j] = d[0][j - 1] + (tStart == 0 ? 0.35 : 1) }
        if n > 0 && m > 0 {
            for i in 1...n { for j in 1...m {
                let inTarget = (tStart..<tEnd).contains(i - 1)
                // Ziel-Wörter dürfen beliebig „falsch“ gehört werden (günstige Ersetzung/Löschung)
                let sub = inTarget ? 0.3 : subCost(sk[i - 1], rk[j - 1])
                let del = inTarget ? 0.3 : 1.0
                d[i][j] = min(d[i - 1][j] + del, d[i][j - 1] + (inTarget || (i < n && (tStart..<tEnd).contains(i)) ? 0.35 : 1), d[i - 1][j - 1] + sub)
            } }
        }
        // Rückverfolgung: für jedes Satzwort die zugeordneten erkannten Indizes
        var owner = [Int](repeating: -1, count: m)   // erkanntes Wort → Satzwort-Index (oder -1 = eingefügt)
        var i = n, j = m
        while i > 0 || j > 0 {
            let inT = i > 0 && (tStart..<tEnd).contains(i - 1)
            if i > 0 && j > 0 {
                let sub = inT ? 0.3 : subCost(sk[i - 1], rk[j - 1])
                if abs(d[i][j] - (d[i - 1][j - 1] + sub)) < 1e-9 { owner[j - 1] = i - 1; i -= 1; j -= 1; continue }
            }
            if i > 0 && abs(d[i][j] - (d[i - 1][j] + (inT ? 0.3 : 1.0))) < 1e-9 { i -= 1; continue }
            if j > 0 {
                // Eingefügtes Wort: gehört zum Ziel, wenn es direkt am Ziel steht
                owner[j - 1] = (inT || (i < n && (tStart..<tEnd).contains(i)) || (i == 0 && tStart == 0)) ? tStart : -1
                j -= 1; continue
            }
            i -= 1
        }
        // Gesamtqualität: zu viel falsch außerhalb des Ziels → Satz nicht wiedererkannt
        let outside = sk.indices.filter { !(tStart..<tEnd).contains($0) }
        let matched = outside.filter { idx in owner.enumerated().contains { $0.element == idx && subCost(sk[idx], rk[$0.offset]) <= 0.4 } }.count
        guard outside.isEmpty || Double(matched) / Double(outside.count) >= 0.5 else { return nil }
        let idx = owner.indices.filter { (tStart..<tEnd).contains(owner[$0]) }
        let range: Range<Int>
        if let a = idx.min(), let b = idx.max() { range = a..<(b + 1) }
        else {
            // Ziel verschluckt: Stelle zwischen den Nachbarn
            let before = owner.indices.filter { owner[$0] >= 0 && owner[$0] < tStart }.max().map { $0 + 1 } ?? 0
            range = before..<before
        }
        let text = recognized[range].joined(separator: " ")
        let left = tStart > 0 ? sk[tStart - 1] : nil
        let right = tEnd < sk.count ? sk[tEnd] : nil
        return Hit(range: range, text: text, left: left, right: right)
    }
}

/// Baut aus den Trainings-Aufnahmen ein Namens-Profil und misst ehrlich (jede Aufnahme mit einem Profil aus den ÜBRIGEN).
enum NameProfileBuilder {
    struct Take {
        var samples: [Float]
        /// bekannter Satz (nil = nur das Wort)
        var sentence: String?
        var parakeet: ScoredText?
        var whisperPlain: String
    }

    struct Piece {
        var variant: String?
        var whisperVariant: String?
        var templates: [[[Float]]]
        var contexts: [String]
        /// Wörter außerhalb des Ziels (Negativ-Beispiele für die Klang-Schwelle): Zeitbereiche
        var others: [(start: Double, end: Double)]
    }

    /// Was aus EINER Aufnahme zu lernen ist
    static func piece(_ t: Take, target: String) -> Piece {
        let targetKey = TrainingText.key(target)
        var p = Piece(variant: nil, whisperVariant: nil, templates: [], contexts: [], others: [])
        let feats = AcousticMatch.features(t.samples)
        if let sentence = t.sentence, let pk = t.parakeet {
            let words = pk.words.map(\.word)
            if let hit = SentenceAlign.locate(recognized: words, sentence: sentence, target: target) {
                let v = TrainingText.normalize(hit.text)
                if !v.isEmpty, TrainingText.key(v) != targetKey { p.variant = v }
                if let l = hit.left { p.contexts.append(l) }
                if let r = hit.right { p.contexts.append(r) }
                if !hit.range.isEmpty, hit.range.upperBound <= pk.times.count {
                    let a = pk.times[hit.range.lowerBound].start, b = pk.times[hit.range.upperBound - 1].end
                    let fr = AcousticMatch.frames(feats, start: a - 0.04, end: b + 0.06)
                    if fr.count >= 12 { p.templates.append(fr) }
                }
                for k in pk.times.indices where !hit.range.contains(k) && k < words.count {
                    // Nur Wörter mit ≥ 3 Buchstaben als Gegenbeispiele
                    if TrainingText.key(words[k]).count >= 3 { p.others.append(pk.times[k]) }
                }
            }
            if let hw = SentenceAlign.locate(recognized: SentenceAlign.tokens(t.whisperPlain), sentence: sentence, target: target) {
                let v = TrainingText.normalize(hw.text)
                if !v.isEmpty, TrainingText.key(v) != targetKey { p.whisperVariant = v }
            }
        } else {
            // Nur das Wort: ganze Ausgabe = Variante, jede Sprach-Insel = Vorlage
            let v = TrainingText.normalize(t.parakeet?.text ?? "")
            if WordTrainer.isUsableVariant(v, target: target, targetKey: targetKey) { p.variant = v }
            let w = TrainingText.normalize(t.whisperPlain)
            if WordTrainer.isUsableVariant(w, target: target, targetKey: targetKey) { p.whisperVariant = w }
            for isl in AcousticMatch.islands(t.samples) {
                let fr = AcousticMatch.frames(feats, start: isl.start, end: isl.end)
                if fr.count >= 12 { p.templates.append(fr) }
            }
        }
        return p
    }

    /// Profil aus Stücken (optional ohne Stück `excluding` – für die ehrliche Nachher-Messung)
    static func build(target: String, kind: NameKind, language: String, pieces: [Piece], samples: [[Float]], parakeet: [ScoredText?],
                      excluding: Int? = nil, extraContexts: [String: Int] = [:], previous: NameProfile? = nil,
                      calibrate: Bool = true) -> NameProfile {
        var counts: [String: (text: String, n: Int, sent: Bool)] = [:]
        for v in previous?.variants ?? [] { counts[TrainingText.key(v.text)] = (v.text, v.count, v.inSentence) }
        var contexts = extraContexts
        var templates: [[[Float]]] = []
        for (i, p) in pieces.enumerated() where i != excluding {
            for v in [p.variant, p.whisperVariant].compactMap({ $0 }) {
                let k = TrainingText.key(v)
                guard k.count >= 2, !TrainingText.functionWords.contains(k) else { continue }
                let old = counts[k]
                counts[k] = (old?.text ?? v, (old?.n ?? 0) + 1, (old?.sent ?? false) || !p.others.isEmpty)
            }
            for c in p.contexts where !c.isEmpty { contexts[c, default: 0] += 1 }
            templates += p.templates
        }
        // Höchstens 12 Vorlagen (die mittellangen zuerst – sehr kurze/lange sind oft abgeschnitten/doppelt)
        if templates.count > 12 {
            let med = templates.map(\.count).sorted()[templates.count / 2]
            templates = Array(templates.sorted { abs($0.count - med) < abs($1.count - med) }.prefix(12))
        }
        var prof = NameProfile(target: target, kind: kind.rawValue, language: language,
                               variants: counts.values.sorted { $0.n > $1.n }.prefix(24).map { NameProfile.Variant(text: $0.text, count: $0.n, inSentence: $0.sent) },
                               contexts: contexts, templates: templates.map(NameProfile.flatten), dtwThreshold: nil, updated: Date())
        if calibrate { prof.dtwThreshold = threshold(pieces: pieces, samples: samples, excluding: excluding) }
        return prof
    }

    /// Klang-Schwelle: Abstand der Namens-Stellen zu den Vorlagen der ANDEREN Aufnahmen (positiv) gegen andere Wörter
    /// aus denselben Aufnahmen (negativ, eigene Stimme). Nur wenn sich beides klar trennt.
    static func threshold(pieces: [Piece], samples: [[Float]], excluding: Int?) -> Float? {
        var pos: [Float] = [], neg: [Float] = []
        let idx = pieces.indices.filter { $0 != excluding }
        for i in idx {
            let others = idx.filter { $0 != i }.flatMap { pieces[$0].templates }
            guard !others.isEmpty else { continue }
            for t in pieces[i].templates {
                let q = t   // Vorlage selbst als Anfrage (enthält etwas Rand)
                pos.append(others.map { AcousticMatch.subDTW($0, in: q) }.min() ?? .infinity)
            }
            let f = AcousticMatch.features(samples[i])
            for o in pieces[i].others {
                let q = AcousticMatch.frames(f, start: o.start - 0.25, end: o.end + 0.25)
                neg.append(others.map { AcousticMatch.subDTW($0, in: q) }.min() ?? .infinity)
            }
        }
        let p = pos.filter { $0.isFinite }.sorted(), n = neg.filter { $0.isFinite }.sorted()
        guard p.count >= 3, n.count >= 5 else { return nil }
        let minNeg = n[0]
        // Schwelle knapp unter dem ähnlichsten Fremdwort; lohnt nur, wenn so mindestens die Hälfte der Namens-Stellen passt
        let thr = minNeg - 0.08
        let hits = p.filter { $0 <= thr }.count
        return hits * 2 >= p.count ? thr : nil
    }
}
