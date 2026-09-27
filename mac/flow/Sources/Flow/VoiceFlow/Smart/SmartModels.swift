import Foundation

// MARK: - „Flow lernt mit“: Datenmodell
//
// wissen.json  (0600) – NUR abgeleitete Merkmale/Zähler, nie ganze Texte:
//                       Formulierungen je App-Art, Namen/Begriffe, Grüße, Register (Sie/du), Korrekturen,
//                       Personen/Themen aus Meeting-ZUSAMMENFASSUNGEN, Nutzungszeiten, offene Vorschläge.
//                       Einmalige Bruchstücke (n = 1) verfallen mit der normalen Löschfrist (Standard 3 Tage).
// lernen.json  (0600) – Einstellungen: an/aus, Vorschlagsarten, „Nein“-Zähler, Claude-Überblick (aus).
// „Alles vergessen“ löscht wissen.json komplett; lernen.json (deine Entscheidungen) bleibt.

/// Arten von Vorschlägen (jede einzeln abschaltbar, jede lernt aus „Nein“)
enum SmartKind: String, Codable, CaseIterable, Identifiable {
    case snippet, dictionary, style, reminders, calendar, transform
    var id: String { rawValue }

    var label: String {
        switch self {
        case .snippet: return "Snippets aus häufigen Sätzen"
        case .dictionary: return "Namen & Begriffe fürs Wörterbuch"
        case .style: return "Stil je App-Art"
        case .reminders: return "Aufgaben aus Meetings"
        case .calendar: return "Termine aus Diktaten"
        case .transform: return "Wiederholte Anweisungen als Transform"
        }
    }

    var detail: String {
        switch self {
        case .snippet: return "„Liebe Grüße, \(Identity.myName)“ kommt oft vor → als Snippet „lg“ speichern."
        case .dictionary: return "Ein Name taucht immer wieder auf und steht noch nicht im Wörterbuch."
        case .style: return "In Mails schreibst du formell, in Chats locker → Stil anpassen."
        case .reminders: return "Nach einem Meeting: deine Aufgaben in Erinnerungen übernehmen."
        case .calendar: return "„Freitag um 14 Uhr“ im Diktat → Termin im Kalender eintragen."
        case .transform: return "Du diktierst dieselbe lange Anweisung öfter → als Transform speichern."
        }
    }

    var symbol: String {
        switch self {
        case .snippet: return "scissors"
        case .dictionary: return "text.book.closed"
        case .style: return "textformat.size"
        case .reminders: return "checklist"
        case .calendar: return "calendar.badge.plus"
        case .transform: return "wand.and.stars"
        }
    }

    /// Illustration der Karte (Resources/Assets) – fehlt sie, zeichnet VFNotify das Symbol
    var illustration: String {
        switch self {
        case .snippet: return "illu_snippet"
        case .dictionary: return "illu_wort_gelernt"
        case .style: return "illu_insights"
        case .reminders: return "illu_meeting_vorbei"
        case .calendar: return "illu_kalender"
        case .transform: return "illu_transforms"
        }
    }

    /// Ab dieser Sicherheit darf eine Karte aus der Pille wachsen (sonst nur leise in der Liste).
    var cardThreshold: Double {
        switch self {
        case .reminders: return 0.6
        case .style: return 0.75
        default: return 0.7
        }
    }

    /// Mindestabstand zwischen zwei Karten derselben Art (wird mit jedem „Nein“ länger)
    var cooldown: TimeInterval {
        switch self {
        case .snippet: return 6 * 3600
        case .dictionary: return 2 * 3600
        case .style: return 24 * 3600
        case .reminders, .calendar: return 0
        case .transform: return 12 * 3600
        }
    }
}

struct SmartTask: Codable, Equatable, Hashable {
    var title: String
    var owner: String?
    var due: Date?
}

/// Was beim „Ja“ passiert – nur die nötigen Daten.
struct SmartPayload: Codable, Equatable {
    var term: String?
    var trigger: String?
    var triggerOptions: [String]?
    var text: String?
    var category: String?
    var style: String?
    var tasks: [SmartTask]?
    var date: Date?
    var eventTitle: String?
    var meetingID: String?
    var correctionOld: String?
}

struct SmartSuggestion: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: SmartKind
    /// Doppelte erkennen („dict:brenninkmeyer“) – einmal entschieden, nie wieder gefragt
    var key: String
    var title: String
    var text: String
    /// 0…1
    var confidence: Double
    var created = Date()
    /// Offene Vorschläge verfallen (spätestens mit der Löschfrist, weil sie Textstücke enthalten können)
    var expires: Date
    var payload = SmartPayload()
    /// Schon einmal als Karte gezeigt (dann nur noch in der Liste)
    var shownAsCard = false
}

/// Ein gezählter Ausdruck (Formulierung, Gruß …). `form` = zuletzt gesehene Schreibweise.
struct SmartCount: Codable, Equatable {
    var form: String
    var n: Int = 0
    var days: Int = 0
    var first = Date()
    var last = Date()
    /// yyyy-MM-dd des letzten Vorkommens (für „an wie vielen Tagen“)
    var lastDay = ""

    mutating func hit(_ f: String, at d: Date, day: String) {
        form = f
        n += 1
        if day != lastDay { days += 1; lastDay = day }
        if d > last { last = d }
        if d < first { first = d }
    }
}

enum SmartTermKind: String, Codable { case person, place, org, term }

struct SmartTerm: Codable, Equatable {
    var form: String
    var kind: SmartTermKind
    var n: Int = 0
    var days: Int = 0
    var lastDay = ""
    var first = Date()
    var last = Date()
    /// Verschiedene Diktate, in denen es vorkam
    var dictations: Int = 0
    /// nil = noch nicht geprüft; true = macOS-Rechtschreibung kennt es (braucht kein Wörterbuch)
    var spellKnown: Bool?
    /// Aus Meetings (Sprecher/Zusammenfassung)
    var fromMeetings: Int = 0
}

/// Sie/du-Zählung je App-Art
struct SmartRegister: Codable, Equatable {
    var formal = 0
    var casual = 0
    var total: Int { formal + casual }
}

struct SmartCorrection: Codable, Equatable {
    var old: String
    var new: String
    var n: Int = 0
    var last = Date()
    var saved = false
}

struct SmartMeetingDigest: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var title: String
    var people: [String]
    var topics: [String]
    var tasks: Int
}

/// Fingerabdruck eines langen Diktats (MinHash) – kein Text.
struct SmartPrint: Codable, Equatable {
    var date: Date
    var category: String
    var words: Int
    var sig: [UInt32]
    var seen: Int = 1
}

struct SmartDigestNote: Codable, Equatable {
    var date: Date
    var text: String
}

/// wissen.json
struct SmartWissen: Codable, Equatable {
    var version = 1
    var createdAt = Date()
    var dictations = 0
    var words = 0
    var meetings = 0
    /// Diktate je App-Art
    var categories: [String: Int] = [:]
    /// Neuester schon ausgewerteter Verlaufseintrag (damit nichts doppelt zählt)
    var lastRecordDate: Date?
    /// App-Art → normierter Schlüssel → Formulierung
    var phrases: [String: [String: SmartCount]] = [:]
    /// klein geschriebener Schlüssel → Begriff
    var terms: [String: SmartTerm] = [:]
    var signOffs: [String: [String: SmartCount]] = [:]
    var greetings: [String: [String: SmartCount]] = [:]
    var register: [String: SmartRegister] = [:]
    /// „alt\u{1}neu“ → Korrektur
    var corrections: [String: SmartCorrection] = [:]
    var meetingPeople: [String: SmartCount] = [:]
    var meetingTopics: [String: SmartCount] = [:]
    var meetingDigests: [SmartMeetingDigest] = []
    var ingestedMeetings: [String] = []
    /// Diktate je Stunde (0–23) und Wochentag (0 = Mo)
    var hours = [Int](repeating: 0, count: 24)
    var weekdays = [Int](repeating: 0, count: 7)
    var prints: [SmartPrint] = []
    /// Einmal gesehene Formulierungen nur als Prüfsumme (kein Text) → Tagnummer. Verfallen mit der Löschfrist.
    var seeds: [String: Int] = [:]
    var pending: [SmartSuggestion] = []
    /// Schon entschiedene Vorschläge (Schlüssel → Datum) – werden nie wieder angeboten
    var decided: [String: Date] = [:]
    var lastCardAt: Date?
    var digest: SmartDigestNote?
}

/// Pro Vorschlagsart: wie oft gezeigt / angenommen / abgelehnt
struct SmartKindStat: Codable, Equatable {
    var shown = 0
    var accepted = 0
    var dismissed = 0
    var lastCard: Date?
    /// Nach 3× „Nein“ gestoppt
    var stopped: Bool { dismissed >= SmartPolicy.stopAfter }
}

/// lernen.json
struct SmartPrefs: Codable, Equatable {
    var enabled = true
    /// Karten aus der Pille (aus = nur der leise Punkt an der Pille)
    var cards = true
    var kinds: [String: Bool] = [:]
    var stats: [String: SmartKindStat] = [:]
    /// Nächtlicher Überblick über Claude (schickt nur Zähler, keine Texte). Standard AUS.
    var nightlyDigest = false
    var lastDigestDay: String?

    func isOn(_ k: SmartKind) -> Bool { kinds[k.rawValue] ?? true }
    func stat(_ k: SmartKind) -> SmartKindStat { stats[k.rawValue] ?? SmartKindStat() }
}

/// Regeln fürs Zeigen (nicht aufdringlich)
enum SmartPolicy {
    /// Höchstens eine Karte pro 30 Minuten (über alle Arten)
    static let cardInterval: TimeInterval = 30 * 60
    /// 3× „Nein“ → diese Art hört auf
    static let stopAfter = 3
    /// Leise Liste (Punkt an der Pille) ab dieser Sicherheit
    static let listThreshold = 0.45
    /// Jedes „Nein“ hebt die Schwelle an → Art wird seltener
    static let dismissPenalty = 0.1
    /// Karte schließt sich nach … (Maus darauf hält sie offen)
    static let cardTimeout: TimeInterval = 14
    /// So lange nach einem Diktat warten, bevor eine Karte kommen darf
    static let quietAfterDictation: TimeInterval = 6
    /// Offene Vorschläge verfallen spätestens nach … (oder mit der Löschfrist, falls kürzer)
    static let maxPendingAge: TimeInterval = 7 * 86400
    static let maxPending = 20
    static func maxPendingPerKind(_ k: SmartKind) -> Int {
        switch k {
        case .dictionary: return 5
        case .snippet, .calendar, .reminders: return 3
        case .style, .transform: return 2
        }
    }

    static func cardThreshold(_ k: SmartKind, dismissed: Int) -> Double { k.cardThreshold + dismissPenalty * Double(dismissed) }
    static func listThreshold(dismissed: Int) -> Double { listThreshold + 0.05 * Double(dismissed) }
    static func cooldown(_ k: SmartKind, dismissed: Int) -> TimeInterval { k.cooldown * Double(1 + dismissed) }
}

/// Größen-Obergrenzen, damit wissen.json klein bleibt
enum SmartLimits {
    static let phrasesPerCategory = 400
    static let terms = 600
    static let signOffsPerCategory = 30
    static let corrections = 200
    static let meetingPeople = 200
    static let meetingTopics = 200
    static let meetingDigests = 60
    static let ingestedMeetings = 300
    static let prints = 150
    static let decided = 800
    static let seeds = 8000
}
