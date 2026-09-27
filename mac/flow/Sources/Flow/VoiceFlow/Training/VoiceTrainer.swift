import Combine
import Foundation

/// Ein Stimm-Level: kurze geführte Aufnahme mit eigener Aufgabe.
struct VoiceLevel: Identifiable, Equatable {
    let id: Int
    let title: String
    let short: String
    let instruction: String
    /// Vorlese-Text; „{NAME}“ wird durch den eigenen Namen ersetzt
    let template: String
    let language: String
    let seconds: Double
    let difficulty: Int
    let symbol: String
    /// Mehrere kurze Aufnahmen statt einer langen (Flüstern): Texte je Aufnahme, `seconds` gilt pro Aufnahme
    let takeTemplates: [String]?
    /// Geflüstert – eigener Teil im Stimmmodell
    var whisper: Bool { takeTemplates != nil && id == VoiceLevel.whisperID }

    /// Text zum Vorlesen mit dem eigenen Namen
    var text: String { text(name: Identity.myNameFrozen) }
    func text(name: String) -> String { template.replacingOccurrences(of: "{NAME}", with: name) }
    var takes: [String]? { takeTemplates?.map { $0.replacingOccurrences(of: "{NAME}", with: Identity.myNameFrozen) } }
    var takeCount: Int { takeTemplates?.count ?? 1 }

    init(id: Int, title: String, short: String, instruction: String, text: String, language: String,
         seconds: Double, difficulty: Int, symbol: String, takes: [String]? = nil) {
        self.id = id; self.title = title; self.short = short; self.instruction = instruction; self.template = text
        self.language = language; self.seconds = seconds; self.difficulty = difficulty; self.symbol = symbol; self.takeTemplates = takes
    }

    static let whisperID = 6

    static let all: [VoiceLevel] = [
        VoiceLevel(id: 1, title: "Normal vorlesen", short: "Ruhig, in deiner normalen Stimme.",
                   instruction: "Lies den Text ganz normal vor – so, wie du sonst diktierst, an deinem gewohnten Platz.",
                   text: "Hallo, ich bin {NAME}. Ich lese diesen Text ganz normal vor, so wie ich sonst auch diktiere. Heute schreibe ich ein paar Nachrichten, plane die nächste Woche und schicke danach noch eine E-Mail an das Team. Flow soll meine Stimme dabei genau kennenlernen.",
                   language: "de", seconds: 18, difficulty: 1, symbol: "text.book.closed"),
        VoiceLevel(id: 2, title: "Englisch", short: "Dieselbe Stimme – auf Englisch.",
                   instruction: "Read this in English, the way you'd talk in a meeting. Deine Stimme klingt auf Englisch anders – genau das soll Flow lernen.",
                   text: "Hi, this is {NAME}. Now I'm reading a few sentences in English, the way I'd normally talk in a meeting. Let's go over the numbers for next week, send the update to the team, and make sure everything is ready before Friday. Flow should recognize my voice in both languages.",
                   language: "en", seconds: 18, difficulty: 2, symbol: "globe"),
        VoiceLevel(id: 3, title: "Schnell & locker", short: "Wie eine Sprachnachricht.",
                   instruction: "Sprich schnell und locker, wie in einer Sprachnachricht an einen Freund. Versprecher sind egal – einfach weiterreden.",
                   text: "Okay, ganz kurz: Ich bin gleich los, hab noch schnell was im Lidl geholt, und dann schauen wir mal, ob wir das heute Abend noch fertig kriegen. Also, keine Ahnung, vielleicht so gegen acht? Schreib mir einfach, wenn's bei dir passt, dann ruf ich dich an.",
                   language: "de", seconds: 15, difficulty: 3, symbol: "hare"),
        VoiceLevel(id: 4, title: "Leise / Abstand", short: "Leiser, etwa 1 m vom MacBook weg.",
                   instruction: "Lehn dich zurück oder geh etwa einen Meter vom MacBook weg und sprich etwas leiser als sonst.",
                   text: "Jetzt spreche ich etwas leiser und sitze ein Stück weiter weg vom Mikrofon. Auch so soll Flow merken, dass ich es bin – zum Beispiel abends, wenn ich nicht laut reden will, oder wenn ich mich zurücklehne und nebenbei eine Notiz diktiere.",
                   language: "de", seconds: 18, difficulty: 4, symbol: "speaker.wave.1"),
        VoiceLevel(id: 5, title: "Mit Geräusch", short: "Musik oder Café im Hintergrund.",
                   instruction: "Mach leise Musik (am besten ohne Gesang), ein Café-Video oder den Ventilator an – und lies ganz normal.",
                   text: "Im Hintergrund läuft gerade etwas Musik, aber ich spreche einfach weiter. Flow soll trotzdem nur meine Stimme hören und alles andere ignorieren. Stell dir vor, ich sitze im Café oder im Zug und diktiere trotzdem schnell eine Antwort an einen Freund.",
                   language: "de", seconds: 18, difficulty: 5, symbol: "music.note"),
        VoiceLevel(id: 6, title: "Flüstern", short: "Ganz leise flüstern, ohne Stimme.",
                   instruction: "Flüstere leise, wie in der Bibliothek – ohne Stimme, nur mit Luft. Bleib an deinem normalen Platz. Drei kurze Sätze, jeder etwa 6 Sekunden.",
                   text: "Ich flüstere jetzt, damit mich niemand hört. Kannst du mir bitte die Notizen von heute schicken? Flow soll mich auch leise erkennen, wenn alle schlafen.",
                   language: "de", seconds: 6.5, difficulty: 5, symbol: "mouth",
                   takes: ["Ich flüstere jetzt, damit mich niemand hört.",
                           "Kannst du mir bitte die Notizen von heute schicken?",
                           "Flow soll mich auch leise erkennen, wenn alle schlafen."]),
    ]

    /// Die normalen Stimm-Level (1–5)
    static var voiced: [VoiceLevel] { all.filter { !$0.whisper } }
    static func level(_ id: Int) -> VoiceLevel? { all.first { $0.id == id } }
}

/// Aufgeschlüsselter Stimm-Kenntnisstand (gemessen).
struct VoiceKnowledge: Equatable {
    var percent: Int
    /// Normale Level (1–5) geschafft
    var levelsDone: Int
    var levelPoints: Int          // 0–40
    var separationPoints: Int     // 0–30
    var whisperPoints: Int        // 0–15
    var adaptivePoints: Int       // 0–10
    var negativePoints: Int       // 0–5
    /// Mittlere (Kohorten-)Ähnlichkeit zurückgehaltener eigener Fenster
    var ownMean: Float?
    /// Ähnlichste fremde Stimme (gleiche Skala)
    var impostorMax: Float?
    var impostorCount: Int
    var adaptiveSamples: Int
    var legacyProfile: Bool
    /// Rohe Schwelle (für den Fall ohne Vergleichsstimmen), begrenzt auf 0,55…0,72
    var suggestedThreshold: Float?
    // Flüstern
    var whisperDone: Bool = false
    var whisperOwnMean: Float? = nil
    var whisperImpostorMax: Float? = nil
    // Negativ-Stimmen
    var negativeNames: [String] = []
    /// Anteil eigener Fenster, die gegen die Negativ-Stimmen bestehen
    var negativeOwnAccept: Float? = nil
    /// Gelernte Diktat-Fenster im Modell
    var adaptivePool: Int = 0
    var canRollback: Bool = false

    static let levelKey = "Stimm-Level", separationKey = "Trennschärfe", adaptiveKey = "Aus Diktaten",
               whisperKey = "Flüstern", negativeKey = "Andere Stimmen"

    var parts: [String: Int] {
        [VoiceKnowledge.levelKey: levelPoints, VoiceKnowledge.separationKey: separationPoints, VoiceKnowledge.adaptiveKey: adaptivePoints,
         VoiceKnowledge.whisperKey: whisperPoints, VoiceKnowledge.negativeKey: negativePoints]
    }

    static let empty = VoiceKnowledge(percent: 0, levelsDone: 0, levelPoints: 0, separationPoints: 0, whisperPoints: 0, adaptivePoints: 0,
                                      negativePoints: 0, ownMean: nil, impostorMax: nil, impostorCount: 0, adaptiveSamples: 0,
                                      legacyProfile: false, suggestedThreshold: nil)
}

/// Eine fremde Stimme, die NICHT als „ich“ gelten soll (z. B. Geschwister) – nur Fingerabdrücke, kein Ton.
struct NegativeVoice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var date: Date
    /// "aufnahme" | "import"
    var source: String
    var normal: [[Float]]
    var whisper: [[Float]]
}

/// Stimm-Training in 6 Levels (5 × normal + Flüstern). Speichert pro Level den mittleren CAM++-Fingerabdruck + Fenster,
/// baut daraus das Stimmmodell (mehrere Mittelpunkte je Art, Kohorte, Negativ-Stimmen), schreibt das Hauptprofil
/// (meine-stimme.json, gleiches Format wie VoiceID) und misst, wie gut man von fremden Stimmen zu unterscheiden ist.
final class VoiceTrainer: ObservableObject {
    static let shared = VoiceTrainer()

    struct LevelData: Codable, Equatable {
        var date: Date
        var seconds: Double
        var speechSeconds: Double
        var centroid: [Float]
        var windows: [[Float]]
        /// Mittlere Ähnlichkeit der Fenster zum eigenen Level-Mittel (Aufnahme-Qualität)
        var consistency: Float
        /// Fenster je Aufnahme (Flüster-Level: 3 Aufnahmen) – für die ehrliche Messung
        var takeSizes: [Int]? = nil
    }

    /// stimm-training.json. Version 1 (bis 1.5.x): Level 1–5, Vergleichsstimmen flach. Version 2: + Flüstern (Level 6),
    /// Vergleichsstimmen je Stimme (normal + geflüstert), Negativ-Stimmen, gelernte Diktat-Fenster.
    struct Store: Codable, Equatable {
        var version = 2
        var levels: [String: LevelData] = [:]
        var impostors: [[Float]] = []
        var impostorVoices: [String] = []
        var adaptiveSamples = 0
        var adaptiveLastScan: Date?
        // — Version 2 —
        /// Vergleichsstimmen je Stimme (normal) / geflüstert
        var cohort: [[[Float]]] = []
        var cohortWhisper: [[[Float]]] = []
        var negatives: [NegativeVoice] = []
        /// Sichere Diktat-Fenster (Anpassung), je Art
        var adaptiveNormal: [[Float]] = []
        var adaptiveWhisper: [[Float]] = []
        var adaptiveCommits: [Date] = []
        var whisperHintShown = false

        init() {}

        enum CodingKeys: String, CodingKey {
            case version, levels, impostors, impostorVoices, adaptiveSamples, adaptiveLastScan
            case cohort, cohortWhisper, negatives, adaptiveNormal, adaptiveWhisper, adaptiveCommits, whisperHintShown
        }

        /// Liest Version 1 und 2 (fehlende Felder = leer) → Migration beim nächsten Speichern
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            levels = try c.decodeIfPresent([String: LevelData].self, forKey: .levels) ?? [:]
            impostors = try c.decodeIfPresent([[Float]].self, forKey: .impostors) ?? []
            impostorVoices = try c.decodeIfPresent([String].self, forKey: .impostorVoices) ?? []
            adaptiveSamples = try c.decodeIfPresent(Int.self, forKey: .adaptiveSamples) ?? 0
            adaptiveLastScan = try c.decodeIfPresent(Date.self, forKey: .adaptiveLastScan)
            cohort = try c.decodeIfPresent([[[Float]]].self, forKey: .cohort) ?? []
            cohortWhisper = try c.decodeIfPresent([[[Float]]].self, forKey: .cohortWhisper) ?? []
            negatives = try c.decodeIfPresent([NegativeVoice].self, forKey: .negatives) ?? []
            adaptiveNormal = try c.decodeIfPresent([[Float]].self, forKey: .adaptiveNormal) ?? []
            adaptiveWhisper = try c.decodeIfPresent([[Float]].self, forKey: .adaptiveWhisper) ?? []
            adaptiveCommits = try c.decodeIfPresent([Date].self, forKey: .adaptiveCommits) ?? []
            whisperHintShown = try c.decodeIfPresent(Bool.self, forKey: .whisperHintShown) ?? false
            let v = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            version = max(v, 2)
            // v1: flache Vergleichsstimmen in Gruppen zu 4 (so wurden sie erzeugt) – bis sie neu berechnet sind
            if v < 2, cohort.isEmpty, !impostors.isEmpty {
                cohort = stride(from: 0, to: impostors.count, by: 4).map { Array(impostors[$0..<min($0 + 4, impostors.count)]) }
            }
        }
    }

    struct LevelResult {
        let level: Int
        let speechSeconds: Double
        let consistency: Float
        let before: Int
        let after: VoiceKnowledge
    }

    @Published private(set) var store: Store
    @Published private(set) var detail: VoiceKnowledge
    @Published private(set) var preparingImpostors = false

    let storeURL: URL
    let profileURL: URL
    let logURL: URL
    /// Sicherung vor jeder Anpassung aus Diktaten (Zurücknehmen)
    let snapshotURL: URL

    private let lock = NSLock()
    private var modelCache = VoiceModel.empty
    private var legacyCentroids: [[Float]] = []
    private var profileCache: [Float]?
    private var profileCheck = Date.distantPast

    /// Profil-Format von VoiceID (Standard-JSONEncoder, damit VoiceID es weiter lesen kann)
    private struct MainProfile: Codable { var embedding: [Float]; var seconds: Double; var date: Date }

    init(base: URL = Paths.base, profileURL: URL = VoiceID.profileURL, logURL: URL = Paths.log) {
        storeURL = base.appendingPathComponent("stimm-training.json")
        snapshotURL = base.appendingPathComponent("stimm-training.vorher.json")
        self.profileURL = profileURL
        self.logURL = logURL
        let s = TrainingFiles.read(Store.self, from: storeURL) ?? Store()
        store = s
        detail = .empty
        rebuildCache()
        detail = computeKnowledge()
    }

    // MARK: Level-Status

    func isDone(_ level: Int) -> Bool { store.levels[String(level)] != nil }
    /// Level 1–5 nacheinander; Flüstern ist frei, sobald Level 1 geschafft ist
    func isUnlocked(_ level: Int) -> Bool {
        if level == VoiceLevel.whisperID { return isDone(1) || isDone(level) }
        return level <= 1 || isDone(level - 1) || isDone(level)
    }
    /// Geschaffte normale Level (1–5)
    var levelsDone: Int { VoiceLevel.voiced.filter { isDone($0.id) }.count }
    var whisperDone: Bool { isDone(VoiceLevel.whisperID) }
    func data(_ level: Int) -> LevelData? { store.levels[String(level)] }
    var model: VoiceModel { lock.lock(); defer { lock.unlock() }; return modelCache }

    // MARK: Öffentliche Schnittstelle für VoiceID / FastVoiceMask

    /// Ähnlichkeit eines Fingerabdrucks zu meiner NORMALEN Stimme auf der Skala von VoiceID (0,6 = Grenze, < 0,45 stumm).
    /// Mit Stimmmodell: Kohorten-Abgleich + Negativ-Stimmen; ohne Level: wie früher das Hauptprofil (roh).
    /// Thread-sicher und schnell (für jedes 1,5-s-Fenster aufrufbar).
    func bestSimilarity(to embedding: [Float]) -> Float { score(embedding, whisper: false).effective }

    /// Wie `bestSimilarity`, aber mit Art (geflüstertes Fenster → Flüster-Profil bzw. neutral ohne Profil)
    func score(_ embedding: [Float], whisper: Bool) -> VoiceModel.Score {
        lock.lock()
        if Date().timeIntervalSince(profileCheck) > 5 {
            profileCheck = Date()
            profileCache = Self.readProfile(profileURL)
        }
        let m = modelCache
        let extra = profileCache.map { [$0] } ?? []
        lock.unlock()
        return m.score(embedding, whisper: whisper, extra: extra)
    }

    /// Frühere Bewertung (bis 1.5.x): höchste rohe Ähnlichkeit zu Level-Mitteln + Hauptprofil. Nur für Vergleichsmessungen.
    func legacySimilarity(to e: [Float]) -> Float {
        lock.lock(); let c = legacyCentroids + (profileCache.map { [$0] } ?? []); lock.unlock()
        return c.isEmpty ? 0 : c.map { Vec.cos(e, $0) }.max() ?? 0
    }

    /// Gemessener Kenntnisstand (0–100 %) mit Aufschlüsselung.
    func knowledge() -> (percent: Int, parts: [String: Int]) {
        let k = computeKnowledge()
        return (k.percent, k.parts)
    }

    /// Neu messen (inkl. Diktat-Protokoll) und `detail` aktualisieren. Fehlen Vergleichsstimmen der Version 2, werden sie nachgerechnet.
    func refresh() {
        scanLogForAdaptiveSamples()
        let k = computeKnowledge()
        DispatchQueue.main.async { self.detail = k }
        if !store.levels.isEmpty, store.cohortWhisper.isEmpty || store.cohort.count < 4, !preparingImpostors {
            Task { try? await self.prepareImpostors(force: true) }
        }
    }

    // MARK: Level abschließen

    /// Wertet eine Level-Aufnahme aus (ein Stück; beim Flüster-Level alle Aufnahmen hintereinander über `takes`).
    func completeLevel(_ level: Int, samples raw: [Float]) async throws -> LevelResult {
        try await completeLevel(level, takes: [raw])
    }

    func completeLevel(_ level: Int, takes rawTakes: [[Float]]) async throws -> LevelResult {
        guard let lv = VoiceLevel.level(level) else { throw TrainingError.cancelled }
        let speech = rawTakes.map { SpeechMeter.speechSeconds($0) }.reduce(0, +)
        let minSpeech = lv.whisper ? 4.0 : (level == 4 ? 4.0 : 5.0)
        guard speech >= minSpeech else { throw TrainingError.tooLittleSpeech(speech) }
        var windows: [[Float]] = []
        var sizes: [Int] = []
        var centroid: [Float]
        if lv.whisper {
            // Wirklich geflüstert? (mind. 2 von 3 Aufnahmen)
            let flags = rawTakes.map { WhisperDetector.analyze($0) }
            let whispered = flags.filter(\.isWhisper).count
            if whispered * 3 < rawTakes.count * 2 {
                let vr = flags.map(\.voicedRatio).reduce(0, +) / Float(max(1, flags.count))
                throw TrainingError.notWhisper(vr)
            }
            for t in rawTakes where SpeechMeter.speechSeconds(t) >= 1.0 {
                // 1,5-s-Fenster wie im Diktat (Flüstern hat wenig Stimme – kürzere Fenster, mehr davon)
                let w = try await TrainingEmbedder.shared.windows(t, win: 24_000, hop: 12_000, limit: 10)
                windows += w
                sizes.append(w.count)
            }
            guard windows.count >= 3, let m = Vec.mean(windows) else { throw TrainingError.tooLittleSpeech(speech) }
            centroid = m
        } else {
            let samples = Transcriber.normalizedGentle(rawTakes[0])
            centroid = try await VoiceID.shared.embedding(of: samples)
            windows = try await TrainingEmbedder.shared.windows(samples)
            guard windows.count >= 2 else { throw TrainingError.tooLittleSpeech(speech) }
            sizes = [windows.count]
            // Schutz: klingt die Aufnahme gar nicht nach den schon trainierten Levels (z. B. jemand anderes liest vor)?
            let others = store.levels.filter { $0.key != String(level) && $0.key != String(VoiceLevel.whisperID) }.map(\.value.centroid)
            if !others.isEmpty {
                let sim = others.map { Vec.cos(centroid, $0) }.max() ?? 0
                if sim < VoiceTrainer.sameSpeakerMin { throw TrainingError.notYou(sim) }
            }
            // … oder genau nach einer eingelernten Negativ-Stimme?
            if let n = store.negatives.first(where: { neg in neg.normal.contains { Vec.cos(centroid, $0) > 0.9 } }) {
                throw TrainingError.negativeVoice(n.name)
            }
        }

        if Task.isCancelled { throw TrainingError.cancelled }
        let consistency = windows.map { Vec.cos($0, centroid) }.reduce(0, +) / Float(windows.count)
        let before = detail.percent
        var s = store
        s.levels[String(level)] = LevelData(date: Date(), seconds: rawTakes.map { Double($0.count) / 16000 }.reduce(0, +),
                                            speechSeconds: speech, centroid: centroid, windows: windows, consistency: consistency,
                                            takeSizes: lv.whisper ? sizes : nil)
        let snap = s
        await MainActor.run { self.store = snap }
        save()
        rebuildCache()
        if !lv.whisper { writeMainProfile() }
        tlog(String(format: "Training: Level %d gespeichert (%.0f s Sprache, %d Fenster, Konsistenz %.2f)", level, speech, windows.count, consistency))
        if store.cohort.count < 4 || store.cohortWhisper.isEmpty { try? await prepareImpostors(force: true) }
        scanLogForAdaptiveSamples()
        let k = computeKnowledge()
        await MainActor.run { self.detail = k }
        return LevelResult(level: level, speechSeconds: speech, consistency: consistency, before: before, after: k)
    }

    func resetLevel(_ level: Int) {
        var s = store
        s.levels[String(level)] = nil
        store = s
        save()
        rebuildCache()
        if s.levels.keys.contains(where: { $0 != String(VoiceLevel.whisperID) }) { writeMainProfile() }
        detail = computeKnowledge()
    }

    // MARK: Vergleichsstimmen (einmalig, nur Fingerabdrücke werden gespeichert)

    static let impostorVoices: [(voice: String, lang: String)] = [
        ("Anna", "de"), ("Eddy (Deutsch (Deutschland))", "de"), ("Grandpa (Deutsch (Deutschland))", "de"), ("Flo (Deutsch (Deutschland))", "de"),
        ("Eddy (Englisch (USA))", "en"), ("Grandpa (Englisch (USA))", "en"), ("Flo (Englisch (USA))", "en"), ("Samantha", "en"),
    ]

    /// Vergleichsstimmen: macOS-Sprachausgabe, normal und geflüstert (LPC). Nur Fingerabdrücke werden gespeichert.
    func prepareImpostors(force: Bool = false) async throws {
        if !force, !store.impostors.isEmpty, !store.cohortWhisper.isEmpty { return }
        await MainActor.run { self.preparingImpostors = true }
        defer { DispatchQueue.main.async { self.preparingImpostors = false } }
        let installed = TTS.installedVoices()
        var flat: [[Float]] = [], groups: [[[Float]]] = [], wgroups: [[[Float]]] = []
        var used: [String] = []
        let deText = VoiceLevel.level(1)!.text(name: "Sam")
        let enText = VoiceLevel.level(2)!.text(name: "Sam")
        for (i, (voice, lang)) in VoiceTrainer.impostorVoices.enumerated() where installed.contains(voice) {
            guard let smp = try? TTS.synth(lang == "de" ? deText : enText, voice: voice) else { continue }
            let w = try await TrainingEmbedder.shared.windows(smp, limit: 4)
            // geflüstert: gleiche Fenster wie das Flüster-Level (1,5 s)
            let ws = try await TrainingEmbedder.shared.windows(Whisperizer.make(smp, seed: UInt64(11 + i)), win: 24_000, hop: 12_000, limit: 6)
            if !w.isEmpty { flat += w; groups.append(w); used.append(voice) }
            if !ws.isEmpty { wgroups.append(ws) }
        }
        guard !flat.isEmpty else { tlog("Training: keine Vergleichsstimmen verfügbar"); return }
        var s = store
        s.impostors = flat
        s.impostorVoices = used
        s.cohort = groups
        s.cohortWhisper = wgroups
        let snap = s
        await MainActor.run { self.store = snap }
        save()
        rebuildCache()
        tlog("Training: \(flat.count) Vergleichs-Fingerabdrücke aus \(used.count) Stimmen (+ \(wgroups.flatMap { $0 }.count) geflüstert)")
        let k = computeKnowledge()
        await MainActor.run { self.detail = k }
    }

    // MARK: Andere Stimmen (Negativ-Profil)

    /// 30 s einer anderen Person → nur Fingerabdrücke. Gibt die gespeicherte Stimme zurück.
    @discardableResult
    func addNegative(name: String, samples raw: [Float]) async throws -> NegativeVoice {
        let speech = SpeechMeter.speechSeconds(raw)
        guard speech >= 6 else { throw TrainingError.tooLittleSpeech(speech) }
        let w = try await TrainingEmbedder.shared.windows(Transcriber.normalizedGentle(raw), win: 24_000, hop: 16_000, limit: 40)
        guard w.count >= 4 else { throw TrainingError.tooLittleSpeech(speech) }
        // Klingt das nach MIR? (Dann wäre ich danach mein eigener Gegner)
        let mine = VoiceLevel.voiced.compactMap { store.levels[String($0.id)]?.centroid }
        if let m = Vec.mean(w), !mine.isEmpty {
            let sim = mine.map { Vec.cos(m, $0) }.max() ?? 0
            if sim > 0.9 { throw TrainingError.soundsLikeYou(sim) }
        }
        let n = NegativeVoice(id: UUID().uuidString, name: name.isEmpty ? "Andere Stimme" : name, date: Date(), source: "aufnahme",
                              normal: VoiceModel.kmeans(w, k: min(4, max(1, w.count / 6))), whisper: [])
        try await storeNegative(n)
        return n
    }

    func removeNegative(_ id: String) {
        var s = store
        s.negatives.removeAll { $0.id == id }
        store = s
        save(); rebuildCache(); detail = computeKnowledge()
    }

    private func storeNegative(_ n: NegativeVoice) async throws {
        var s = store
        s.negatives.removeAll { $0.name.lowercased() == n.name.lowercased() && $0.source == n.source }
        s.negatives.append(n)
        let snap = s
        await MainActor.run { self.store = snap }
        save(); rebuildCache()
        let k = computeKnowledge()
        await MainActor.run { self.detail = k }
        tlog("Training: andere Stimme „\(n.name)“ eingelernt (\(n.normal.count) normal, \(n.whisper.count) geflüstert)")
    }

    /// Stimmabdruck zum Austauschen (z. B. zwischen Geschwistern): nur Mittelpunkte, kein Ton.
    struct Voiceprint: Codable {
        var format = "flow-stimmabdruck"
        var version = 1
        var name: String
        var created: Date
        var normal: [[Float]]
        var whisper: [[Float]]
    }

    static let voiceprintExtension = "flowstimme"

    func exportVoiceprint(name: String) -> Data? {
        let m = model
        guard let n = m.normal, !n.centroids.isEmpty else { return nil }
        let vp = Voiceprint(name: name, created: Date(), normal: n.centroids, whisper: m.whisper?.centroids ?? [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        return try? enc.encode(vp)
    }

    @discardableResult
    func importVoiceprint(_ data: Data) async throws -> NegativeVoice {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let vp = try? dec.decode(Voiceprint.self, from: data), vp.format == "flow-stimmabdruck",
              !vp.normal.isEmpty, vp.normal.allSatisfy({ $0.count == 192 }), vp.whisper.allSatisfy({ $0.count == 192 }) else {
            throw TrainingError.badVoiceprint
        }
        // Eigener Abdruck? (fast gleiche Mittelpunkte)
        if let mine = model.normal?.centroids, !mine.isEmpty {
            let sim = vp.normal.map { v in mine.map { Vec.cos(v, $0) }.max() ?? 0 }.max() ?? 0
            if sim > 0.97 { throw TrainingError.soundsLikeYou(sim) }
        }
        let n = NegativeVoice(id: UUID().uuidString, name: vp.name, date: Date(), source: "import",
                              normal: vp.normal.map(Vec.norm), whisper: vp.whisper.map(Vec.norm))
        try await storeNegative(n)
        return n
    }

    // MARK: Anpassung aus Diktaten (VoiceAdapter ruft das auf)

    enum AdaptOutcome: Equatable { case applied(Int, Int), rejected(String), skipped(String) }

    static let poolMaxNormal = 48, poolMaxWhisper = 24
    /// Grenzen für die gemessene Schwelle (ich − Kohorte). Die Messung im Training ist zu optimistisch (2,5-s-Fenster,
    /// TTS-Stimmen untereinander sehr verschieden → fremd max ≈ −0,15); echte fremde Stimmen in 1,5-s-Diktat-Fenstern
    /// (14 andere TTS-Stimmen, eine Geschwister-Stimme) erreichen bis ~0,26. Untergrenze 0,12 (normal) / 0,10 (Flüstern) aus der Messung am 26.09.2026.
    static let normalClamp: ClosedRange<Float> = 0.12...0.22
    static let whisperClamp: ClosedRange<Float> = 0.10...0.22
    /// Flüstern: Negativ-Stimmen nur „näher an mir als am anderen“ (Marge 0) – geflüstert unterscheiden sich selbst
    /// Geschwister kaum; jede Marge kostet sofort eigene Flüster-Diktate (gemessen: 0,05 → eigene 91 % → 55 %).
    nonisolated(unsafe) static var whisperNegMargin: Float = 0
    /// Geflüsterte Negativ-Stimmen (aus importierten Abdrücken) beim Flüstern benutzen? Aus: gemessen an einer Geschwister-Stimme kostet es
    /// mehr eigene Flüster-Diktate (83 % → 75 % angenommen) als es fremde abwehrt (22 % → 44 % abgewiesen).
    /// Die geflüsterten Mittelpunkte werden trotzdem gespeichert und ausgetauscht (für später / eigene Messung).
    nonisolated(unsafe) static var useWhisperNegatives = false

    /// Sichere Diktat-Fenster ins Modell übernehmen – mit Drift-Schutz und Sicherung (Zurücknehmen).
    func applyAdaptation(normal: [[Float]], whisper: [[Float]]) -> AdaptOutcome {
        guard !normal.isEmpty || !whisper.isEmpty else { return .skipped("leer") }
        let old = store
        guard old.levels.keys.contains(where: { $0 != String(VoiceLevel.whisperID) }) else { return .skipped("kein Level") }
        // Jedes Fenster muss schon mit dem JETZIGEN Modell klar ich sein (sonst könnte sich eine fremde Stimme einschleichen)
        let current = VoiceTrainer.buildModel(old)
        let okN = normal.filter { current.score($0, whisper: false).effective >= 0.66 }
        let okW = whisper.filter { current.hasWhisper && current.score($0, whisper: true).effective >= 0.66 }
        if okN.count * 2 < normal.count || (!whisper.isEmpty && okW.count * 2 < whisper.count && current.hasWhisper) {
            return .rejected("\(normal.count - okN.count + whisper.count - okW.count) Fenster klingen nicht sicher nach dir")
        }
        var s = old
        s.adaptiveNormal = Array((s.adaptiveNormal + okN).suffix(VoiceTrainer.poolMaxNormal))
        if s.levels[String(VoiceLevel.whisperID)] != nil { s.adaptiveWhisper = Array((s.adaptiveWhisper + okW).suffix(VoiceTrainer.poolMaxWhisper)) }
        s.adaptiveCommits = Array((s.adaptiveCommits + [Date()]).suffix(50))
        // Drift-Schutz: (1) eigene Level-Fenster weiter sicher erkannt, (2) Vergleichsstimmen nicht leichter angenommen,
        // (3) kein Mittelpunkt wandert vom Level-Anker weg
        let before = current, after = VoiceTrainer.buildModel(s)
        let anchor = Vec.mean(VoiceLevel.voiced.compactMap { old.levels[String($0.id)]?.centroid }) ?? []
        // Anker: kein Mittelpunkt darf deutlich weiter vom Level-Mittel weg liegen als der entfernteste bisherige (Level 4 „leise“ liegt schon bei ~0,7)
        func minAnchor(_ m: VoiceModel) -> Float { (m.normal?.centroids ?? []).map { Vec.cos($0, anchor) }.min() ?? 1 }
        if minAnchor(after) < min(0.75, minAnchor(before)) - 0.05 {
            return .rejected(String(format: "Mittelpunkt driftet weg (%.2f → %.2f)", minAnchor(before), minAnchor(after)))
        }
        let ownB = VoiceTrainer.acceptRate(before, windows: VoiceTrainer.levelWindows(old, whisper: false), whisper: false)
        let ownA = VoiceTrainer.acceptRate(after, windows: VoiceTrainer.levelWindows(old, whisper: false), whisper: false)
        let impB = VoiceTrainer.acceptRate(before, windows: old.cohort.flatMap { $0 }, whisper: false)
        let impA = VoiceTrainer.acceptRate(after, windows: old.cohort.flatMap { $0 }, whisper: false)
        if ownA < ownB - 0.03 { return .rejected(String(format: "eigene Fenster %.0f → %.0f %%", ownB * 100, ownA * 100)) }
        if impA > impB + 0.02 { return .rejected(String(format: "Vergleichsstimmen %.0f → %.0f %%", impB * 100, impA * 100)) }
        TrainingFiles.write(old, to: snapshotURL)
        store = s
        save(); rebuildCache()
        detail = computeKnowledge()
        return .applied(okN.count, okW.count)
    }

    var canRollback: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }

    /// Letzte Anpassung zurücknehmen (Stand vor der letzten Übernahme)
    @discardableResult
    func rollback() -> Bool {
        guard let old = TrainingFiles.read(Store.self, from: snapshotURL) else { return false }
        var s = store
        s.adaptiveNormal = old.adaptiveNormal
        s.adaptiveWhisper = old.adaptiveWhisper
        s.adaptiveCommits = old.adaptiveCommits
        store = s
        save(); rebuildCache()
        try? FileManager.default.removeItem(at: snapshotURL)
        detail = computeKnowledge()
        tlog("Training: letzte Anpassung aus Diktaten zurückgenommen")
        return true
    }

    func markWhisperHintShown() {
        var s = store; s.whisperHintShown = true
        if Thread.isMainThread { store = s } else { DispatchQueue.main.sync { self.store = s } }
        save()
    }

    // MARK: Modell bauen

    static func levelWindows(_ st: Store, whisper: Bool) -> [[Float]] {
        VoiceLevel.all.filter { $0.whisper == whisper }.compactMap { st.levels[String($0.id)]?.windows }.flatMap { $0 }
    }

    /// Eigene Fenster je Gruppe (Level bzw. Flüster-Aufnahme) für die ehrliche Messung
    static func levelGroups(_ st: Store, whisper: Bool) -> [[[Float]]] {
        var out: [[[Float]]] = []
        for lv in VoiceLevel.all where lv.whisper == whisper {
            guard let d = st.levels[String(lv.id)] else { continue }
            if let sizes = d.takeSizes, sizes.reduce(0, +) == d.windows.count, sizes.count > 1 {
                var i = 0
                for n in sizes { out.append(Array(d.windows[i..<(i + n)])); i += n }
            } else { out.append(d.windows) }
        }
        return out
    }

    static func buildModel(_ st: Store) -> VoiceModel {
        var m = VoiceModel.empty
        let nMeans = VoiceLevel.voiced.compactMap { st.levels[String($0.id)]?.centroid }
        let nWin = levelWindows(st, whisper: false)
        if !nMeans.isEmpty {
            let cents = VoiceModel.centroids(windows: nWin + st.adaptiveNormal, levelMeans: nMeans)
            let cal = VoiceModel.calibrate(groups: levelGroups(st, whisper: false) + (st.adaptiveNormal.isEmpty ? [] : [st.adaptiveNormal]),
                                           cohortGroups: st.cohort, clamp: VoiceTrainer.normalClamp)
            let neg = st.negatives.flatMap(\.normal)
            m.normal = VoiceModel.Part(centroids: cents, cohort: st.cohort.flatMap { $0 }, negatives: neg,
                                       threshold: cal?.threshold ?? 0.14,
                                       negMargin: VoiceModel.negativeMargin(own: nWin, model: cents, negatives: neg))
        }
        if let wl = st.levels[String(VoiceLevel.whisperID)] {
            let wWin = wl.windows
            let cents = VoiceModel.centroids(windows: wWin + st.adaptiveWhisper, levelMeans: [wl.centroid], perCluster: 6, maxK: 3)
            let cal = VoiceModel.calibrate(groups: levelGroups(st, whisper: true), cohortGroups: st.cohortWhisper, clamp: VoiceTrainer.whisperClamp)
            let neg = VoiceTrainer.useWhisperNegatives ? st.negatives.flatMap(\.whisper) : []
            m.whisper = VoiceModel.Part(centroids: cents, cohort: st.cohortWhisper.flatMap { $0 }, negatives: neg,
                                        threshold: cal?.threshold ?? 0.12,
                                        negMargin: VoiceTrainer.whisperNegMargin)
        }
        m.rawThreshold = rawSuggestion(st).map { min(0.72, max(0.55, $0)) } ?? VoiceModel.defaultRaw
        return m
    }

    static func acceptRate(_ m: VoiceModel, windows: [[Float]], whisper: Bool) -> Float {
        guard !windows.isEmpty else { return 0 }
        return Float(windows.filter { m.score($0, whisper: whisper).effective >= VoiceModel.boundary }.count) / Float(windows.count)
    }

    /// Früherer roher Schwellen-Vorschlag: Mitte zwischen den schwächsten 10 % der eigenen Fenster und der ähnlichsten TTS-Stimme
    static func rawSuggestion(_ st: Store) -> Float? {
        let keys = VoiceLevel.voiced.map { String($0.id) }.filter { st.levels[$0] != nil }
        var own: [Float] = []
        for k in keys {
            guard let l = st.levels[k], l.windows.count >= 2 else { continue }
            let others = keys.filter { $0 != k }.compactMap { st.levels[$0]?.centroid }
            for (i, w) in l.windows.enumerated() {
                var rest = l.windows; rest.remove(at: i)
                guard let held = Vec.mean(rest) else { continue }
                own.append(([held] + others).map { Vec.cos(w, $0) }.max() ?? 0)
            }
        }
        let model = keys.compactMap { st.levels[$0]?.centroid }
        guard own.count >= 3, !model.isEmpty, !st.impostors.isEmpty else { return nil }
        let i = st.impostors.map { imp in model.map { Vec.cos(imp, $0) }.max() ?? 0 }.max() ?? 0
        let low = own.sorted()[own.count / 10]
        return (low + i) / 2
    }

    // MARK: Messung

    /// Kenntnisstand 0–100:
    /// Level 1–5 je 8 (40) · Trennschärfe 0–30 (eigene Fenster erkannt × fremde abgewiesen) · Flüstern 0–15 (7 fürs Level + bis 8 Trennschärfe)
    /// · aus Diktaten 0–10 · andere Stimme eingelernt 5.
    func computeKnowledge() -> VoiceKnowledge {
        let st = store
        let done = VoiceLevel.voiced.filter { st.levels[String($0.id)] != nil }.count
        let levelPts = done * 8
        var sepPts = 0
        var ownMean: Float?, impMax: Float?
        if done > 0, let cal = VoiceModel.calibrate(groups: VoiceTrainer.levelGroups(st, whisper: false), cohortGroups: st.cohort, clamp: VoiceTrainer.normalClamp) {
            ownMean = cal.ownMean; impMax = cal.impostorMax
            sepPts = Int((30 * cal.ownAccept * (1 - cal.impostorAccept)).rounded(.down))
        }
        var wPts = 0
        var wJ: Float?, wI: Float?
        let wDone = st.levels[String(VoiceLevel.whisperID)] != nil
        if wDone {
            wPts = 7
            if let cal = VoiceModel.calibrate(groups: VoiceTrainer.levelGroups(st, whisper: true), cohortGroups: st.cohortWhisper, clamp: VoiceTrainer.whisperClamp) {
                wJ = cal.ownMean; wI = cal.impostorMax
                wPts += Int((8 * cal.ownAccept * (1 - cal.impostorAccept)).rounded(.down))
            }
        }
        let pool = st.adaptiveNormal.count + st.adaptiveWhisper.count
        let adaptivePts = min(10, st.adaptiveSamples / 3 + pool / 6)
        let negPts = st.negatives.isEmpty ? 0 : 5
        var negAcc: Float?
        let m = model
        if !st.negatives.isEmpty {
            negAcc = VoiceTrainer.acceptRate(m, windows: VoiceTrainer.levelWindows(st, whisper: false), whisper: false)
        }
        let legacy = done == 0 && FileManager.default.fileExists(atPath: profileURL.path)
        let raw = VoiceTrainer.rawSuggestion(st).map { min(0.72, max(0.55, $0)) }
        var k = VoiceKnowledge(percent: min(100, levelPts + sepPts + wPts + adaptivePts + negPts), levelsDone: done, levelPoints: levelPts,
                               separationPoints: sepPts, whisperPoints: wPts, adaptivePoints: adaptivePts, negativePoints: negPts,
                               ownMean: ownMean, impostorMax: impMax, impostorCount: st.cohort.flatMap { $0 }.count,
                               adaptiveSamples: st.adaptiveSamples, legacyProfile: legacy, suggestedThreshold: raw)
        k.whisperDone = wDone
        k.whisperOwnMean = wJ
        k.whisperImpostorMax = wI
        k.negativeNames = st.negatives.map(\.name)
        k.negativeOwnAccept = negAcc
        k.adaptivePool = pool
        k.canRollback = canRollback
        return k
    }

    /// Gemessen an echten Diktaten: eigene Level-Mittel untereinander 0,93–0,99, fremde Stimmen 0,38–0,66.
    static let sameSpeakerMin: Float = 0.72

    /// Trennschärfe-Punkte: Anteil eigener zurückgehaltener Fenster über der Schwelle × Anteil fremder darunter (× 30 bzw. × 8)

    /// Echte Diktate mit sicherem Stimm-Treffer (≥ 0,72) aus dem Protokoll zählen – dauerhaft, auch wenn das Protokoll gekürzt wird.
    func scanLogForAdaptiveSamples() {
        guard let txt = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let fmt = ISO8601DateFormatter()
        let last = store.adaptiveLastScan ?? .distantPast
        var newest = last
        var add = 0
        for line in txt.split(separator: "\n") where line.contains("Stimmabgleich: bestes ") {
            guard let sp = line.firstIndex(of: " "), let d = fmt.date(from: String(line[..<sp])), d > last else { continue }
            newest = max(newest, d)
            guard let r = line.range(of: "bestes ") else { continue }
            let num = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
            if let v = Float(String(num).trimmingCharacters(in: CharacterSet(charactersIn: "."))), v >= 0.72 { add += 1 }
        }
        guard newest > last else { return }
        var s = store
        s.adaptiveSamples += add
        s.adaptiveLastScan = newest
        if Thread.isMainThread { store = s } else { DispatchQueue.main.sync { self.store = s } }
        save()
    }

    // MARK: Speichern

    private func save() { TrainingFiles.write(store, to: storeURL) }

    private func rebuildCache() {
        let m = VoiceTrainer.buildModel(store)
        let legacy = VoiceLevel.voiced.compactMap { store.levels[String($0.id)]?.centroid }
        lock.lock()
        modelCache = m
        legacyCentroids = legacy
        profileCache = Self.readProfile(profileURL)
        profileCheck = Date()
        lock.unlock()
    }

    private static func readProfile(_ url: URL) -> [Float]? {
        guard let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(MainProfile.self, from: d) else { return nil }
        return p.embedding
    }

    /// Hauptprofil = normalisiertes Mittel der normalen Level-Mittel → VoiceID.isEnrolled + alte Pfade profitieren sofort.
    private func writeMainProfile() {
        let cs = VoiceLevel.voiced.compactMap { store.levels[String($0.id)]?.centroid }
        guard let m = Vec.mean(cs) else { return }
        let secs = store.levels.values.reduce(0) { $0 + $1.seconds }
        let p = MainProfile(embedding: m, seconds: secs, date: Date())
        guard let d = try? JSONEncoder().encode(p) else { return }
        do { try d.write(to: profileURL, options: .atomic) } catch { tlog("Training: Hauptprofil nicht speicherbar: \(error)") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
        lock.lock(); profileCache = m; profileCheck = Date(); lock.unlock()
        tlog(String(format: "Training: Hauptprofil aus %d Level(s) neu geschrieben", cs.count))
    }
}
