import AppKit
import Foundation

/// Ein trainierter Name/Begriff mit allem, was Flow über eigene Aussprache gelernt hat.
struct NameProfile: Codable, Equatable, Sendable {
    struct Variant: Codable, Equatable, Sendable {
        var text: String
        var count: Int
        /// Im Satz gehört (Satz-Training) – realistischer als einzeln gesprochen
        var inSentence: Bool
    }

    var target: String
    /// person | company | place | term
    var kind: String
    var language: String
    var variants: [Variant]
    /// Nachbarwörter (klein) aus Trainingssätzen und eigenen Diktaten → Häufigkeit
    var contexts: [String: Int]
    /// eigene Aussprache als MFCC-Folgen (je `AcousticMatch.coeffs` Werte pro Rahmen, flach gespeichert)
    var templates: [[Float]]
    /// Klang-Schwelle (DTW), gemessen im Training; nil = Klang trennt nicht sicher → nur mit Whisper-Bestätigung
    var dtwThreshold: Float?
    var updated: Date

    var templateFrames: [[[Float]]] {
        templates.map { flat in stride(from: 0, to: flat.count - AcousticMatch.coeffs + 1, by: AcousticMatch.coeffs).map { Array(flat[$0..<($0 + AcousticMatch.coeffs)]) } }
    }

    static func flatten(_ frames: [[Float]]) -> [Float] { frames.flatMap { $0 } }
}

/// Speicher `namen-profil.json` (0600). Das Training schreibt, die Erkennung liest (gecacht, lädt bei Änderung neu).
final class NameStore: @unchecked Sendable {
    static let shared = NameStore(url: Paths.base.appendingPathComponent("namen-profil.json"))

    struct File: Codable { var version = 1; var names: [String: NameProfile] = [:] }

    let url: URL
    private let lock = NSLock()
    private var cache: [NameProfile] = []
    private var stamp: Date?
    private var checked = Date.distantPast

    init(url: URL) { self.url = url }

    /// Alle Profile (höchstens alle 2 s von der Platte nachgeladen)
    func profiles() -> [NameProfile] {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(checked) > 2 {
            checked = Date()
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if m != stamp {
                stamp = m
                cache = Array(readFile().names.values).sorted { $0.target < $1.target }
            }
        }
        return cache
    }

    func profile(_ target: String) -> NameProfile? { readFile().names[target] }

    func readFile() -> File {
        guard let d = try? Data(contentsOf: url) else { return File() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(File.self, from: d)) ?? File()
    }

    func save(_ p: NameProfile) {
        lock.lock(); defer { lock.unlock() }
        var f = readFile()
        f.names[p.target] = p
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(f) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        checked = .distantPast
    }

    func remove(_ target: String) {
        lock.lock(); defer { lock.unlock() }
        var f = readFile()
        f.names[target] = nil
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(f) { try? d.write(to: url, options: .atomic) }
        checked = .distantPast
    }
}

/// Namen, die wirklich hängen bleiben:
/// 1. Parakeet-Text nach Stellen absuchen, die nach einem trainierten Namen KLINGEN (Laut-Code nahe an gelernten
///    Varianten) UND unsicher/unpassend sind (niedrige Token-Sicherheit, Nachbarwörter wie im Training).
/// 2. Nur dann Whisper fragen – mit Sätzen, in denen der Name steht (Messung: 8/8 statt 4/8 mit der Wörterbuch-Liste).
/// 3. Ohne Whisper: nur ersetzen, wenn eigene Klang-Vorlagen (DTW) passen. Echte Wörter mit hoher Sicherheit
///    („Jacke“, „Schock“, „jetzt“) werden nie angefasst.
enum NameBooster {
    struct Candidate: Sendable, Equatable {
        let target: String
        let index: Int
        let length: Int
        let text: String
        let phon: Double
        let conf: Float
        let context: Bool
        let exact: Bool
        /// Bei angeklebten Wörtern („AbsendenQuest“): der echte Wortteil davor, bleibt stehen
        var prefix: String = ""
        /// Stelle besteht nur aus echten Wörtern („Shark Wes“) → braucht immer Bestätigung
        var real: Bool = true
        /// Kunstwort, das genau so schon für den Namen gehört wurde („JarQuest“) → darf direkt ersetzt werden
        var direct: Bool { exact && !real && prefix.isEmpty }
        var score: Double { phon + Double(1 - conf) * 0.5 + (context ? 0.1 : 0) + (exact ? 0.2 : 0) }
    }

    struct Rules: Sendable {
        /// Kunstwort, das genau so schon einmal für den Namen gehört wurde („JarQuest“)
        var exactMaxConf: Float = 0.9
        /// Alle echten Treffer aus den Test-Aufnahmen lagen unter 0,6 Wort-Sicherheit; normale Sätze meist darüber
        var maxConf: Float = 0.62
        /// Stelle nur aus echten Wörtern („Chuck is“, „Jackett“) – strenger
        var realMaxConf: Float = 0.5
        /// … mit passenden Nachbarwörtern aus dem Training („mit ___ telefoniert“) etwas großzügiger
        var contextMaxConf: Float = 0.72
        /// Laut-Ähnlichkeit: nur echte Wörter („Shark Wes“) brauchen mehr, Kunstwörter („Czog Fess“) etwas weniger
        var realPhon = 0.8, unrealPhon = 0.72, contextPhon = 0.72
        /// Mindestlänge der Stelle (Buchstaben) – „at“, „wenn“ sind nie ein Name
        var minLetters = 4
        /// Ohne Whisper: Klang muss passen und die Stelle unsicher sein
        var acousticMaxConf: Float = 0.6
        /// Klang-Veto: Stelle klingt klar anders als alle Vorlagen (DTW-Abstand über dieser Schwelle) → nicht fragen
        var acousticVeto: Float = 3.7
    }
    nonisolated(unsafe) static var rules = Rules()

    static func key(_ s: String) -> String { NamePhonetics.letters(s) }

    private static let stopWords: Set<String> = ["der", "die", "das", "und", "ich", "du", "er", "sie", "es", "wir", "ihr", "ein", "eine",
        "ist", "the", "a", "and", "to", "of", "is", "it", "i", "you", "we", "ja", "nein", "so", "also", "mal", "noch", "dann", "aber"]

    /// Stellen im Parakeet-Ergebnis, die ein trainierter Name sein könnten.
    /// `dictionary`: Hör-Varianten aus deinen eigenen Korrekturen (heard → Name) zählen als zusätzliche Varianten.
    static func candidates(_ p: ScoredText, profiles: [NameProfile], dictionary: [DictEntry] = [], rules: Rules = NameBooster.rules) -> [Candidate] {
        guard !profiles.isEmpty, !p.words.isEmpty else { return [] }
        let words = p.words.map { $0.word }
        let keys = words.map { key($0) }
        var out: [Candidate] = []
        let sentenceLang = words.count >= 4 ? LanguageGuard.guessDeEn(p.text) : nil
        for prof in profiles {
            let tKey = key(prof.target)
            guard tKey.count >= 3 else { continue }
            let tParts = prof.target.split(separator: " ").map { key(String($0)) }
            // Schon richtig geschrieben (ganzes Wort)? Dann nichts tun.
            if keys.count >= tParts.count, (0...(keys.count - tParts.count)).contains(where: { Array(keys[$0..<($0 + tParts.count)]) == tParts }) { continue }
            let dictVariants = dictionary.filter { $0.write == prof.target && $0.heard.lowercased() != prof.target.lowercased() }.map(\.heard)
            // Nur Varianten mit ≥ 4 Buchstaben (kurze wie „ID“, „Fan“ klingen wie halb Deutschland)
            let refs = ([prof.target] + prof.variants.map(\.text) + dictVariants).filter { key($0).count >= 4 }
            let refKeys = Set((prof.variants.map(\.text) + dictVariants).map { key($0) }.filter { $0.count >= 4 })
            var found: [Candidate] = []
            func consider(i: Int, len: Int, span: String, sk: String, conf: Float, prefix: String) {
                guard sk.count >= rules.minLetters else { return }
                let exact = refKeys.contains(sk)
                let parts = span.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 }
                let allReal = !parts.isEmpty && parts.allSatisfy { realWord($0, "de") || realWord($0, "en") }
                let left = i > 0 ? keys[i - 1] : "", right = i + len < keys.count ? keys[i + len] : ""
                let ctx = (!left.isEmpty && (prof.contexts[left] ?? 0) >= 1 && !stopWords.contains(left))
                    || (!right.isEmpty && (prof.contexts[right] ?? 0) >= 1 && !stopWords.contains(right))
                let limit = ctx ? rules.contextMaxConf : (allReal ? rules.realMaxConf : rules.maxConf)
                if exact && !allReal {
                    guard conf < rules.exactMaxConf else { return }
                } else {
                    guard conf < limit else { return }
                }
                let phon = similarity(span, refs: refs)
                let need = ctx ? rules.contextPhon : (allReal ? rules.realPhon : rules.unrealPhon)
                guard exact || phon >= need else { return }
                found.append(Candidate(target: prof.target, index: i, length: len, text: span, phon: phon, conf: conf, context: ctx,
                                       exact: exact, prefix: prefix, real: allReal))
            }
            for i in words.indices {
                for len in 1...min(3, max(tParts.count + 1, 2)) where i + len <= words.count {
                    // Nur Füllwörter? Nie.
                    if keys[i..<(i + len)].allSatisfy({ stopWords.contains($0) }) { continue }
                    consider(i: i, len: len, span: words[i..<(i + len)].joined(separator: " "), sk: keys[i..<(i + len)].joined(),
                             conf: p.words[i..<(i + len)].map(\.conf).min() ?? 1, prefix: "")
                }
                // Angeklebt: „AbsendenQuest“, „AbsendenjarQs“ – unsicheres, unbekanntes Wort = echtes Wort + Name?
                let w = words[i], conf = p.words[i].conf
                let bare = w.trimmingCharacters(in: .punctuationCharacters)
                if conf < rules.maxConf, bare.count >= 7, !realWord(bare, "de"), !realWord(bare, "en") {
                    let chars = Array(bare)
                    for cut in 3...(chars.count - 3) {
                        let head = String(chars[..<cut]), tail = String(chars[cut...])
                        guard head.count >= 3, realWord(head, "de") || realWord(head, "en") else { continue }
                        consider(i: i, len: 1, span: tail, sk: key(tail), conf: conf, prefix: head)
                    }
                }
            }
            // Beste nicht überlappende Stellen (meist eine)
            for c in found.sorted(by: { $0.score > $1.score }) {
                if out.contains(where: { $0.target == c.target && $0.index < c.index + c.length && c.index < $0.index + $0.length }) { continue }
                out.append(c)
            }
        }
        return out
    }

    /// Laut-Ähnlichkeit zur besten Referenz, nur bei ähnlicher Länge
    static func similarity(_ span: String, refs: [String]) -> Double {
        let sl = key(span).count
        var best = 0.0
        for r in refs {
            let rl = key(r).count
            guard rl > 0, Double(sl) >= Double(rl) * 0.6, Double(sl) <= Double(rl) * 1.7 else { continue }
            best = max(best, NamePhonetics.similarity(span, r))
        }
        return best
    }

    /// Sprache einer kurzen Wortfolge, nur wenn eindeutig (alle Wörter echte Wörter genau einer Sprache)
    static func spanLanguage(_ span: String) -> String? {
        let ws = span.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 }
        guard !ws.isEmpty else { return nil }
        var de = true, en = true
        for w in ws {
            de = de && realWord(w, "de")
            en = en && realWord(w, "en")
        }
        if de == en { return nil }
        return de ? "de" : "en"
    }

    private static let spellLock = NSLock()
    private static var spellCache: [String: Bool] = [:]
    static func realWord(_ w: String, _ lang: String) -> Bool {
        // Großbuchstabe mitten im Wort („JarQuest“, „AbsendenjarQs“): die Rechtschreibprüfung überspringt so etwas → nie „echt“
        if w.dropFirst().contains(where: { $0.isUppercase }) { return false }
        let k = lang + ":" + w.lowercased()
        spellLock.lock()
        if let v = spellCache[k] { spellLock.unlock(); return v }
        spellLock.unlock()
        // NSSpellChecker gehört auf den Main-Thread (Ergebnis wird gemerkt, kostet also nur beim ersten Mal)
        func check() -> Bool {
            NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        let v = Thread.isMainThread ? check() : DispatchQueue.main.sync { check() }
        spellLock.lock(); spellCache[k] = v; spellLock.unlock()
        return v
    }

    /// Welche trainierten Namen stehen schon (richtig) im Text? – auch dann bekommt Whisper die Namens-Sätze.
    static func present(_ text: String, profiles: [NameProfile]) -> [String] {
        profiles.map(\.target).filter { contains(text, target: $0) }
    }

    /// Sprache für Whisper, wenn der Namen-Prüfer fragt: Deckt die Stelle fast alles ab (nur der Name gesagt),
    /// entscheidet die Parakeet-Sprache nichts („Come see you“ ≠ Englisch) → Sprache des Profils.
    static func whisperLanguage(_ p: ScoredText, candidates: [Candidate], profiles: [NameProfile], fallback: String?) -> String? {
        let covered = candidates.reduce(0) { $0 + $1.length }
        if p.words.count - covered < 3 {
            return profiles.first { $0.target == candidates.first?.target }?.language
        }
        let rest = p.words.enumerated().filter { i, _ in !candidates.contains { (i >= $0.index) && (i < $0.index + $0.length) } }.map(\.element.word)
        return rest.count >= 3 ? LanguageGuard.guessDeEn(rest.joined(separator: " ")) : fallback
    }

    /// Hinweis-Sätze für Whisper: Name jeweils am Satzende (sonst plappert Whisper bei kurzen Stücken den Satz weiter).
    static func prompt(for targets: [String], profiles: [NameProfile], language: String? = nil, maxLength: Int = 150) -> String {
        var parts: [String] = []
        for t in targets {
            let kind = profiles.first { $0.target == t }?.kind ?? "person"
            let lang = language ?? profiles.first { $0.target == t }?.language ?? "de"
            let s: String
            if lang == "en" {
                switch kind {
                case "company": s = "I'm working for \(t). The invoice came from \(t)."
                case "place": s = "I'm in \(t) right now. Tomorrow we drive to \(t)."
                case "term": s = "Today it's about \(t). We talk about \(t)."
                default: s = "Today I talked to \(t). Tomorrow I'll meet \(t)."
                }
                parts.append(s)
                continue
            }
            switch kind {
            case "company": s = "Ich arbeite gerade für \(t). Die Rechnung kam von \(t)."
            case "place": s = "Ich bin gerade in \(t). Morgen fahren wir nach \(t)."
            case "term": s = "Heute geht es um \(t). Wir sprechen über \(t)."
            default: s = "Heute habe ich mit \(t) gesprochen. Morgen treffe ich \(t)."
            }
            parts.append(s)
        }
        var out = ""
        for p in parts where out.count + p.count + 1 <= maxLength { out += (out.isEmpty ? "" : " ") + p }
        if out.isEmpty, let first = parts.first { out = String(first.prefix(maxLength)) }
        return out
    }

    /// Enthält ein Text den Namen (ganzes Wort, Groß/klein und Akzente egal)?
    static func contains(_ text: String, target: String) -> Bool {
        let pat = "(?<![\\p{L}\\d])" + NSRegularExpression.escapedPattern(for: target) + "(?![\\p{L}\\d])"
        return text.range(of: pat, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Ersetzt die Wörter [index, index+length) im Parakeet-Text durch den Namen (Satzzeichen am Ende bleiben).
    static func replace(_ p: ScoredText, candidate c: Candidate) -> String {
        var ws = p.words.map { $0.word }
        guard c.index + c.length <= ws.count else { return p.text }
        let lastWord = ws[c.index + c.length - 1]
        let trail = String(lastWord.reversed().prefix { ",.;:!?…".contains($0) }.reversed())
        ws.replaceSubrange(c.index..<(c.index + c.length), with: [(c.prefix.isEmpty ? "" : c.prefix + " ") + c.target + trail])
        return ws.joined(separator: " ")
    }

    /// Direkte Ersetzungen anwenden (von hinten); die ersetzten Wörter gelten danach als sicher (für `decide`)
    static func applyDirect(_ p: ScoredText, _ cs: [Candidate]) -> ScoredText {
        var words = p.words, times = p.times
        for c in cs.sorted(by: { $0.index > $1.index }) where c.index + c.length <= words.count {
            let last = words[c.index + c.length - 1].word
            let trail = String(last.reversed().prefix { ",.;:!?…".contains($0) }.reversed())
            words.replaceSubrange(c.index..<(c.index + c.length), with: [(word: c.target + trail, conf: Float(1))])
            if c.index + c.length <= times.count {
                let t = (start: times[c.index].start, end: times[c.index + c.length - 1].end)
                times.replaceSubrange(c.index..<(c.index + c.length), with: [t])
            }
        }
        // Token-Sicherheiten neu aus den Wörtern (Mittel), damit `decide` nicht an der ersetzten Stelle hängen bleibt
        return ScoredText(text: words.map(\.word).joined(separator: " "), tokenConfidences: words.map(\.conf), words: words, times: times)
    }

    /// Klang-Abstand der Kandidaten-Stelle zu eigenen Vorlagen (kleiner = ähnlicher)
    static func acousticDistance(_ samples: [Float], _ p: ScoredText, candidate c: Candidate, profile: NameProfile) -> Float {
        guard !profile.templates.isEmpty, c.index + c.length <= p.times.count else { return .infinity }
        let a = p.times[c.index].start, b = p.times[c.index + c.length - 1].end
        let clip = AcousticMatch.slice(samples, start: a - 0.25, end: b + 0.25, pad: 0)
        let f = AcousticMatch.features(clip)
        return profile.templateFrames.map { AcousticMatch.subDTW($0, in: f) }.min() ?? .infinity
    }

    /// Whisper hat mit Namens-Hinweis geantwortet: Ergebnis übernehmen – außer Whisper hat offensichtlich
    /// weitergeplappert (viel mehr Wörter als Parakeet). Dann nur die Stelle im Parakeet-Text tauschen.
    static func merge(parakeet p: ScoredText, whisper w: String, candidates: [Candidate]) -> (text: String, fixed: [String]) {
        let confirmed = candidates.filter { contains(w, target: $0.target) }
        guard !confirmed.isEmpty else { return (w, []) }
        let pw = p.words.count, ww = w.split(whereSeparator: { $0.isWhitespace }).count
        if ww > pw + max(3, pw / 2) {
            var text = p
            var out = p.text
            // von hinten ersetzen, damit die Wort-Indizes stimmen
            for c in confirmed.sorted(by: { $0.index > $1.index }) {
                out = replace(text, candidate: c)
                text = ScoredText(text: out, tokenConfidences: text.tokenConfidences,
                                  words: out.split(separator: " ").map { (word: String($0), conf: Float(1)) }, times: text.times)
            }
            return (out, confirmed.map(\.target))
        }
        return (w, confirmed.map(\.target))
    }
}
