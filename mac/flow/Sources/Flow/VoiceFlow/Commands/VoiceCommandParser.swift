import Foundation

// MARK: - Sprachbefehle: Erkennen (reine Textlogik – ohne App, ohne Zugriffe, testbar)
//
// Ein Befehl zählt NUR am Anfang eines Diktats und nur in einer klaren Befehlsform:
//   „Schick Nico: …“ · „Sende an Nico …“ · „Send Lena …“            → geteilter Tresor
//   „Erinner mich morgen um 9 an …“ · „Remind me in 2 hours to …“    → Erinnerungen
//   „Termin am Freitag 14 Uhr mit Pierre“ · „Kalender: …“           → Kalender (30 min)
//   „Notiz: …“ · „Note: …“                                           → Scratchpad
//   „Such nach …“ · „Search for …“                                   → Websuche
// Alles, was nur so ähnlich aussieht („Schick Nico doch einfach eine Mail“, „Termin am Freitag
// passt mir nicht“, „Erinnerst du dich …“), bleibt normaler Text. Unsicher → normaler Text.

enum VCKind: String, Codable { case send, reminder, event, note, search }

struct VoiceCommand: Equatable {
    var kind: VCKind
    /// Nachricht (send) · Titel (reminder/event) · Notiz (note) · Suchbegriff (search)
    var text: String
    /// Nur send: Name des Partners, so wie er in Flow heißt
    var partner: String? = nil
    /// reminder: fällig (nil = ohne Datum) · event: Beginn
    var date: Date? = nil
    /// event: Ende
    var end: Date? = nil
    /// Nur ein Tag, keine Uhrzeit (ganztägig)
    var allDay = false
    var english = false
    /// Der erkannte Befehlsanfang (für Protokoll/Tests), z. B. „schick nico“
    var trigger = ""
}

/// Ein Wort des Diktats: Original, vereinfachte Form (klein, ohne Akzente, ß→ss) und Stelle im Text.
struct VCToken {
    let raw: String
    let n: String
    let range: Range<String.Index>
    /// Danach steht ein Trennzeichen (: , . ; – -)
    var sep: Bool
    /// Danach steht ausdrücklich ein Doppelpunkt
    var colon: Bool
}

enum VoiceCommandParser {
    struct Options {
        /// Partner-Namen (Einstellungen / ClipVault-Kopplung). Leer = „Schick …“ wird nie erkannt.
        var partners: [String] = []
        /// Eigener Name (an sich selbst schicken ist kein Befehl)
        var me: String = ""
        var search = true
        var calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.locale = Locale(identifier: "de_DE")
            c.timeZone = .current
            return c
        }()
    }

    // MARK: Einstieg

    static func parse(_ text: String, now: Date = Date(), options o: Options = Options()) -> VoiceCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2000 else { return nil }
        // Zitat am Anfang („“Remind me tomorrow” is what she says“) oder wiedergegebene Rede („…, hat er gesagt, …“) → normaler Text
        if let f = t.unicodeScalars.first, "\"“„”«»'‚‘".unicodeScalars.contains(f) { return nil }
        if isReportedSpeech(t) { return nil }
        var toks = tokenize(t)
        guard !toks.isEmpty else { return nil }
        // „Notiz? Die hab ich …“ – Fragezeichen direkt am ersten Wort
        if toks[0].raw.contains("?") { return nil }
        // Höflichkeit vorne weg: „Bitte erinner mich …“, „Please remind me …“
        var start = 0
        while start < toks.count - 1, ["bitte", "please"].contains(toks[start].n) { start += 1 }
        let polite = start > 0
        toks = Array(toks[start...])
        // Termin/Erinnerung/Suche als Frage („Termin Freitag 14 Uhr?“) richtet sich an jemanden → normaler Text
        let question = t.hasSuffix("?")
        // Zusammengezogene Erkennung: „Erinnermich“, „Remindme“
        if toks[0].n == "erinnermich" || toks[0].n == "remindme" { return question ? nil : parseReminder(t, toks, 1, now: now, o: o, en: toks[0].n == "remindme") }

        let w0 = toks[0].n
        if sendVerbsDE.contains(w0) || sendVerbsEN.contains(w0) || w0 == "nachricht" || ((w0 == "an" || w0 == "to") && toks.count > 2 && matchPartner(toks[1].n, o: o) != nil) {
            return parseSend(t, toks, o: o)
        }
        if remindVerbsDE.contains(w0), toks.count > 1, toks[1].n == "mich" { return question ? nil : parseReminder(t, toks, 2, now: now, o: o, en: false) }
        // „Erinnerung morgen 7 Uhr: Tabletten nehmen“ – Nomen nur, wenn direkt eine Zeitangabe mit Doppelpunkt folgt
        if (w0 == "erinnerung" || w0 == "reminder"), !toks[0].sep, !question, let c = parseReminderNoun(t, toks, now: now, o: o, en: w0 == "reminder") { return c }
        if w0 == "remind", toks.count > 1, toks[1].n == "me" { return question ? nil : parseReminder(t, toks, 2, now: now, o: o, en: true) }
        if !question, let c = parseEvent(t, toks, now: now, o: o) { return c }
        // „Please note: …“ / „Bitte Notiz …“ ist eine Redewendung, kein Befehl
        if !polite, let c = parseNote(t, toks) { return c }
        if o.search, !question, let c = parseSearch(t, toks) { return c }
        return nil
    }

    /// „…, hat er gesagt, …“ · „sagte Papa“ · „he said“ · „is what she always says“
    static func isReportedSpeech(_ t: String) -> Bool {
        let l = fold(t)
        let pats = [",\\s*(hat|hatte)\\s+(\\p{L}+\\s+){1,5}(gesagt|gemeint|geschrieben|gefragt|gerufen|behauptet)\\b",
                    "\\b(hat|hatte|haben|hab|habe)\\s+\\p{L}+\\s+(noch\\s+|mal\\s+|immer\\s+|auch\\s+)?(gesagt|gemeint|geschrieben|gefragt|gerufen|behauptet)\\b",
                    ",\\s*(sagte|meinte|schrieb|fragte|rief|sagt|meint)\\s+\\p{L}+",
                    "\\b(he|she|they|mom|dad|mum)\\s+(said|says|wrote|asked|told me)\\b",
                    "\\bis what \\p{L}+ (always |usually |just )?(says|said)\\b",
                    "\\b(sagt|sagte|meinte) (er|sie) (immer|dann|noch)\\b"]
        return pats.contains { l.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: Wortlisten (vereinfachte Form: klein, ohne Akzente, ß → ss)

    static let sendVerbsDE: Set<String> = ["schick", "schicke", "schik", "shick", "sende", "schreib", "schreibe"]
    static let sendVerbsEN: Set<String> = ["send", "text", "message"]
    static let remindVerbsDE: Set<String> = ["erinner", "erinnere", "erinnre", "erinere", "erinner'"]
    /// Nach dem Namen ohne Trennzeichen: so beginnt eher ein Rat an jemand anderen („Schick Nico doch einfach die Datei“)
    static let adviceDE: Set<String> = ["doch", "einfach", "halt", "mal", "eine", "einen", "ein", "einem", "einer", "die", "das", "den", "dem", "der", "des",
                                        "deine", "dein", "deinen", "deinem", "ihm", "ihr", "ihn", "ihnen", "uns", "auch", "lieber", "besser", "noch", "schon",
                                        "endlich", "nochmal", "nochmals", "ruhig", "gerne", "gern", "was", "etwas", "alles", "dieses", "diese", "diesen", "dieser",
                                        "meine", "mein", "meinen", "meinem", "unsere", "unser", "unseren", "seine", "sein", "seinen", "ihre", "ihren",
                                        "heute", "morgen", "gleich", "bald", "sofort", "spater", "vielleicht", "bloss", "nur", "nicht", "kein", "keine", "zuerst",
                                        "bitte", "kurz", "nichts", "niemals", "nie", "bescheid", "sowas", "so", "sie", "es", "dann", "vorher", "bevor"]
    static let adviceEN: Set<String> = ["the", "a", "an", "your", "my", "his", "her", "its", "it", "this", "that", "these", "those", "them", "some", "over",
                                        "back", "me", "him", "just", "maybe", "also", "our", "their", "all", "everything", "something", "anything",
                                        "along", "out", "off", "home", "later", "now", "first", "an email", "one", "any", "no", "nothing", "please", "anything", "stuff", "before"]
    /// Gebeugte Verben: kommen sie im Rest vor, ist es ein normaler Satz („Termin am Freitag passt mir nicht“)
    static let finiteDE: Set<String> = ["ist", "sind", "war", "waren", "wurde", "wurden", "wird", "werden", "hat", "hatte", "hatten", "haben", "habe", "hab", "hast",
                                        "passt", "passte", "fallt", "fiel", "muss", "musste", "mussen", "kann", "konnte", "konnen", "geht", "ging", "klappt", "klappte",
                                        "lauft", "lief", "bleibt", "steht", "stand", "liegt", "lag", "verschiebt", "verschoben", "abgesagt", "gibt", "gab", "findet", "fand",
                                        "beginnt", "begann", "dauert", "dauerte", "soll", "sollte", "sollten", "ware", "bin", "bist", "seid", "gestaltet", "verlauft",
                                        "verlief", "kostet", "zeigt", "macht", "brauche", "brauchst", "braucht", "weiss", "glaube", "denke", "finde", "kommt", "kam",
                                        "gefallt", "fehlt", "fehlen", "reicht", "hilft", "funktioniert", "ergab", "ergibt", "bringt", "lohnt", "nervt",
                                        "kommen", "liegen", "gehen", "laufen", "stehen", "passen", "fehlen", "brauchen", "haben", "sind", "hangt", "hangen", "landet", "wartet", "warten",
                                        "bestatigt", "vereinbart", "ausgemacht", "geplant", "gebucht", "eingetragen", "verlegt", "angesetzt", "gestrichen", "erledigt"]
    static let finiteEN: Set<String> = ["is", "are", "was", "were", "has", "had", "have", "got", "looks", "seems", "works", "worked", "moved", "cancelled", "canceled",
                                        "will", "can", "could", "should", "would", "went", "goes", "did", "does", "am", "starts", "started", "ended", "ends", "isn't",
                                        "wasn't", "doesn't", "didn't", "won't", "keeps", "shows", "showed", "returned", "returns", "announced", "gave", "gives", "takes", "took",
                                        "confirmed", "scheduled", "booked", "planned", "postponed", "rescheduled", "done", "went", "sent", "invites", "means"]
    static let secondPerson: Set<String> = ["du", "dir", "dich", "dein", "deine", "deinen", "deinem", "deiner", "euch", "eure", "euer", "you", "your", "yours",
                                            "you're", "you've", "you'll", "you'd", "thee", "thou", "thy"]
    static let whWords: Set<String> = ["wie", "was", "wer", "wen", "wem", "wo", "warum", "wieso", "weshalb", "wann", "welche", "welcher", "welches", "ob",
                                       "why", "what", "how", "who", "whom", "where", "which", "whose", "when", "if", "whether", "of"]

    // MARK: Schicken („Schick Nico: …“, „Sende an Nico …“, „Send Lena …“, „Nachricht an Nico: …“)

    private static func parseSend(_ t: String, _ toks: [VCToken], o: Options) -> VoiceCommand? {
        guard !o.partners.isEmpty else { return nil }
        let w = toks.map(\.n)
        func at(_ k: Int) -> String { k >= 0 && k < w.count ? w[k] : "" }
        let en = sendVerbsEN.contains(w[0])
        var i = 1
        var sepSeen = false
        let partner: String

        if w[0] == "an" || w[0] == "to" {
            // „An Nico senden: …“ / „To Nico: …“
            guard let p = matchPartner(at(1), o: o) else { return nil }
            partner = p
            if ["senden", "schicken", "schreiben"].contains(at(2)), toks[2].sep { i = 3 }
            else if w[0] == "to", toks[1].colon { i = 2 }
            else { return nil }
            sepSeen = true
        } else {
            if w[0] == "nachricht" {
                // „Nachricht an Nico: …“ – nur mit „an“/„für“ und Trennzeichen
                guard ["an", "fur"].contains(at(1)) else { return nil }
            }
            while i < toks.count, ["mal", "bitte", "please", "kurz", "schnell", "quickly", "das", "dies", "folgendes", "this"].contains(w[i]), !toks[i].sep { i += 1 }
            var viaAn = false
            if ["an", "to", "fur"].contains(at(i)), !toks[i].sep { i += 1; viaAn = true }
            // „Schick dem Nico: …“
            if ["dem", "den"].contains(at(i)), !toks[i].sep, matchPartner(at(i + 1), o: o) != nil { i += 1 }
            guard i < toks.count, let p = matchPartner(w[i], o: o) else { return nil }
            partner = p
            // „Sende an Nico …“ ist eindeutig ein Befehl – wie ein Trennzeichen
            sepSeen = toks[i].sep || viaAn
            i += 1
            // „Schick Nico bitte: …“ / „Schick Nico mal kurz: …“ – Füllwörter zählen nur, wenn danach ein Trennzeichen kommt
            if !sepSeen {
                var k = i
                while k < toks.count, ["bitte", "please", "mal", "kurz", "schnell", "eben", "noch", "quickly", "quick"].contains(w[k]) {
                    if toks[k].sep { sepSeen = true; i = k + 1; break }
                    k += 1
                }
            }
            // „Schick Nico eine Nachricht: …“ / „Schick Nico ein Update: …“ / „Send Lena a message saying …“
            if !sepSeen, ["ein", "eine", "einen", "a", "an"].contains(at(i)), i + 1 < toks.count {
                if toks[i + 1].colon { sepSeen = true; i += 2 }
                else if ["nachricht", "message", "notiz", "note", "text", "info"].contains(at(i + 1)) {
                    sepSeen = true; i += 2
                    while i < toks.count, ["saying", "that", "dass", "mit"].contains(w[i]), !toks[i].sep { i += 1 }
                }
            }
            guard i < toks.count else { return nil }
            // „Nachricht an Nico ist raus“
            if w[0] == "nachricht", !toks[i - 1].sep { return nil }
        }
        guard i < toks.count else { return nil }
        // Ohne Trennzeichen nach dem Namen: beginnt der Rest wie ein Objekt/Rat („die Datei“, „doch mal“), ist es ein normaler Satz –
        // außer es folgt gleich ein ganzer Satz („send nico the meeting got moved“, „schick nico die neue version vom logo ist im ordner“)
        // „schick nico bitte ich komm heute nicht“ – nach „bitte“ beginnt gleich die Nachricht
        if !sepSeen, ["bitte", "please"].contains(w[i]), ["ich", "wir", "i", "we", "i'm"].contains(at(i + 1)) { i += 1; sepSeen = true }
        if !sepSeen, (en ? adviceEN : adviceDE).contains(w[i]) {
            guard startsSentence(toks, i, en: en) else { return nil }
        }
        // „Schick Nico, Micha und Tobi die Einladung“ – eine Empfänger-Liste, keine Nachricht an Nico
        if !toks[i - 1].colon, toks[i].raw.first?.isUppercase == true, !["ich", "wir", "i", "we"].contains(w[i]),
           toks[i...].prefix(4).contains(where: { ["und", "and"].contains($0.n) }) { return nil }
        let body = cleanBody(String(t[toks[i].range.lowerBound...]))
        guard !body.isEmpty, !["true", "false", "null"].contains(body.lowercased()) else { return nil }
        let trig = w[0..<i].joined(separator: " ")
        return VoiceCommand(kind: .send, text: body, partner: partner, english: en, trigger: trig)
    }

    /// Artikel + höchstens 5 Wörter (ohne Komma, ohne „wenn/weil/du/you“) + gebeugtes Verb = ein eigener Satz, keine Anweisung.
    static func startsSentence(_ toks: [VCToken], _ i: Int, en: Bool) -> Bool {
        let articles: Set<String> = en ? ["the", "my", "our", "your", "this", "that"] : ["die", "der", "das", "mein", "meine", "unser", "unsere", "dein", "deine"]
        guard articles.contains(toks[i].n) else { return false }
        let verbs = en ? finiteEN : finiteDE
        let stops: Set<String> = ["wenn", "weil", "dass", "ob", "als", "falls", "bevor", "nachdem", "sobald", "when", "if", "because", "so", "once", "before", "after"]
        var k = i + 1
        while k < toks.count, k <= i + 6 {
            if verbs.contains(toks[k].n) { return k >= i + 2 }
            if toks[k - 1].sep || stops.contains(toks[k].n) || secondPerson.contains(toks[k].n) { return false }
            k += 1
        }
        return false
    }

    /// Passt das Wort (mit typischen Erkennungs-Varianten) zu einem der Partner-Namen?
    static func matchPartner(_ word: String, o: Options) -> String? {
        let k = nameKey(word)
        guard !k.skeleton.isEmpty else { return nil }
        if !o.me.isEmpty, nameKey(o.me) == k, !o.partners.contains(where: { nameKey($0) == k }) { return nil }
        for p in o.partners {
            let first = p.split(separator: " ").first.map(String.init) ?? p
            if nameKey(first) == k { return p }
        }
        return nil
    }

    struct NameKey: Equatable { let skeleton: String; let vowels: Int }

    /// Klang-Schlüssel eines Namens: Mitlaute (vereinheitlicht) + Zahl der Vokal-Gruppen.
    /// „Nico“ = „Niko“ = „Nicco“ = „Nikko“ · „Lena“ = „Léna“ = „Lenna“ = „Jol“ – aber nicht „Mason“, „Jule“, „Joe“.
    static func nameKey(_ s: String) -> NameKey {
        var t = fold(s).replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
        if t.hasPrefix("y"), t.count > 1, "aeiou".contains(t[t.index(after: t.startIndex)]) { t = "j" + t.dropFirst() }
        for (a, b) in [("dsch", "j"), ("dj", "j"), ("sch", "S"), ("ch", "C"), ("ph", "f"), ("ck", "k"), ("qu", "kv"), ("th", "t"),
                       ("c", "k"), ("z", "s"), ("w", "v")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        var skel = "", groups = 0, inVowel = false
        for ch in t {
            if "aeiouy".contains(ch) {
                if !inVowel { groups += 1 }
                inVowel = true
            } else {
                inVowel = false
                if ch == "h" { continue }
                if skel.last != ch { skel.append(ch) }
            }
        }
        return NameKey(skeleton: skel, vowels: groups)
    }

    // MARK: Erinnerungen

    private static func parseReminder(_ t: String, _ toks: [VCToken], _ from: Int, now: Date, o: Options, en: Bool) -> VoiceCommand? {
        var i = from
        while i < toks.count, ["bitte", "please", "mal"].contains(toks[i].n) { i += 1 }
        guard i < toks.count else { return nil }
        let first = toks[i].n
        if ["nicht", "nie", "niemals", "bloss", "not", "never", "no"].contains(first) { return nil }
        // „Erinnere mich, wie das ging“ / „Remind me why …“ → eine Frage an jemanden
        let firstAfterDaran = (first == "daran" || first == "dran") && i + 1 < toks.count ? toks[i + 1].n : first
        if whWords.contains(firstAfterDaran) || whWords.contains(first) { return nil }
        let rest = Array(toks[i...])
        if rest.contains(where: { secondPerson.contains($0.n) }) { return nil }
        // „Remind me, remind me, …“ / „Erinnere mich, erinnere mich …“ – Liedzeile
        if rest.contains(where: { $0.n == "remind" || remindVerbsDE.contains($0.n) }) { return nil }
        var when = VCDateParser.extract(rest, now: now, cal: o.calendar, allowDuration: false)
        if when.date == nil, let dd = VCDataDetector.find(rest, in: t) { when = dd }
        var titleToks = rest.enumerated().filter { !when.used.contains($0.offset) }.map(\.element)
        // Verbindungswörter vorne weg: „an den Zahnarzt“, „daran, dass …“, „to call mom“
        var guardLoop = 0
        while let f = titleToks.first, guardLoop < 6 {
            guardLoop += 1
            if ["an", "ans", "daran", "dran", "dass", "zu", "to", "about", "that", "und", "and", "bitte", "please", "for"].contains(f.n) {
                titleToks.removeFirst()
                if f.n == "an" || f.n == "about", let a = titleToks.first, ["den", "die", "das", "dem", "der", "the"].contains(a.n), titleToks.count > 1 {
                    titleToks.removeFirst()
                }
            } else { break }
        }
        guard !titleToks.isEmpty else { return nil }
        var title = joinTokens(titleToks, in: t)
        title = tidyTask(title, en: en)
        guard title.count >= 2 else { return nil }
        return VoiceCommand(kind: .reminder, text: title, date: when.date, allDay: when.allDay, english: en,
                            trigger: toks[0..<from].map(\.n).joined(separator: " "))
    }

    private static func parseReminderNoun(_ t: String, _ toks: [VCToken], now: Date, o: Options, en: Bool) -> VoiceCommand? {
        // Zeitangabe muss bei Wort 1 beginnen und mit einem Doppelpunkt enden
        guard let c = toks[1...].firstIndex(where: { $0.colon }), c >= 1, c <= 6, c + 1 < toks.count else { return nil }
        let head = Array(toks[1...c])
        let when = VCDateParser.extract(head, now: now, cal: o.calendar, allowDuration: false)
        guard when.date != nil, when.used.count == head.count else { return nil }
        let rest = Array(toks[(c + 1)...])
        if rest.contains(where: { finiteDE.contains($0.n) || finiteEN.contains($0.n) || secondPerson.contains($0.n) }) { return nil }
        let title = tidyTask(joinTokens(rest, in: t), en: en)
        guard title.count >= 2 else { return nil }
        return VoiceCommand(kind: .reminder, text: title, date: when.date, allDay: when.allDay, english: en, trigger: toks[0].n)
    }

    /// „dass ich Milch kaufen muss“ → „Milch kaufen“ · „Pierre anzurufen“ → „Pierre anrufen“ · „die Wäsche zu holen“ → „die Wäsche holen“
    static func tidyTask(_ s: String, en: Bool) -> String {
        var t = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!–-"))
        if !en {
            if t.range(of: "^((dass|das) )?ich .+ (muss|soll|sollte|will|wollte|darf|möchte)$", options: [.regularExpression, .caseInsensitive]) != nil {
                t = t.replacingOccurrences(of: "^((dass|das) )?ich ", with: "", options: [.regularExpression, .caseInsensitive])
                t = t.replacingOccurrences(of: " (muss|soll|sollte|will|wollte|darf|möchte)$", with: "", options: [.regularExpression, .caseInsensitive])
            }
            t = t.replacingOccurrences(of: "\\b(ab|an|auf|aus|bei|ein|mit|nach|vor|weg|zurück|los|fest|her|hin|um|durch|vorbei|zusammen|raus|rein|hoch|runter|weiter|fertig|rüber|heim)zu(\\p{L}+en)$",
                                       with: "$1$2", options: .regularExpression)
            t = t.replacingOccurrences(of: " zu (\\p{L}+en)$", with: " $1", options: .regularExpression)
        }
        return capitalizeFirst(t)
    }

    // MARK: Termine

    private static let eventWordsDE: Set<String> = ["termin", "kalender", "kalendereintrag", "neuer", "trag", "eintragen"]

    private static func parseEvent(_ t: String, _ toks: [VCToken], now: Date, o: Options) -> VoiceCommand? {
        let w = toks.map(\.n)
        var i = 0, en = false
        func at(_ k: Int) -> String { k < w.count ? w[k] : "" }
        switch at(0) {
        case "termin":
            i = 1
            if at(1) == "eintragen" { i = 2 }
        case "neuer" where at(1) == "termin": i = 2
        case "neuer" where ["kalendereintrag", "eintrag"].contains(at(1)): i = 2
        case "trag", "trage":
            // „Trag (mir) (einen) Termin ein …“ · „Trag in den Kalender ein: …“
            var k = 1
            if at(k) == "mir" || at(k) == "es" { k += 1 }
            if at(k) == "in", ["den", "meinen"].contains(at(k + 1)), at(k + 2) == "kalender" {
                k += 3
                guard at(k) == "ein" else { return nil }
                i = k + 1
                break
            }
            if ["einen", "nen", "den"].contains(at(k)) { k += 1 }
            guard at(k) == "termin" else { return nil }
            k += 1
            if at(k) == "ein" { k += 1 }
            i = k
        case "kalender", "kalendereintrag":
            i = 1
        case "calendar" where ["event", "entry"].contains(at(1)): i = 2; en = true
        case "event" where !toks[0].sep || toks[0].colon: i = 1; en = true
        case "calendar":
            guard toks[0].sep else { return nil }
            i = 1; en = true
        case "new" where ["event", "appointment", "meeting"].contains(at(1)): i = 2; en = true
        case "add" where at(1) == "to" && (at(2) == "calendar" || (at(2) == "my" && at(3) == "calendar")):
            i = at(2) == "my" ? 4 : 3; en = true
        case "add" where ["event", "appointment"].contains(at(1)) || (["an", "a"].contains(at(1)) && ["event", "appointment"].contains(at(2))):
            i = at(1) == "an" || at(1) == "a" ? 3 : 2; en = true
        case "schedule":
            // „Schedule for Sunday: …“ / „Schedule is tight“ sind Überschriften/Sätze
            if ["for", "is", "of", "this", "next", "looks", "the", "today", "was", "has"].contains(at(1)) || toks[0].sep { return nil }
            i = 1; en = true
            if ["a", "an"].contains(at(1)) { i = 2 }
            if ["meeting", "call", "appointment", "event"].contains(at(i)) { i += 1 }
        case "appointment": i = 1; en = true
        default: return nil
        }
        guard i < toks.count else { return nil }
        let rest = Array(toks[i...])
        var when = VCDateParser.extract(rest, now: now, cal: o.calendar, allowDuration: true)
        if when.date == nil, let dd = VCDataDetector.find(rest, in: t) { when = dd }
        guard let start = when.date else { return nil }
        var titleToks = rest.enumerated().filter { !when.used.contains($0.offset) }.map(\.element)
        // Normale Sätze („Termin am Freitag passt mir nicht“) → kein Befehl
        let verbs = en ? finiteEN : finiteDE
        if titleToks.contains(where: { verbs.contains($0.n) }) { return nil }
        // Weitere Uhrzeiten im Titel („doors 9:30, worship 10, message 10:40“) = ein Ablaufplan, kein Termin
        if titleToks.contains(where: { $0.n.range(of: "^\\d{1,2}[:.]\\d{2}$", options: .regularExpression) != nil }) { return nil }
        // „… in deinen Kalender“ richtet sich an jemand anderen · „Termin, Termin, ich komme zu nichts“ ist ein Satz über mich
        if titleToks.contains(where: { secondPerson.contains($0.n) || ["ich", "wir", "i", "we", "i'm", "we're"].contains($0.n) }) { return nil }
        while let f = titleToks.first, ["am", "um", "fur", "on", "at", "for", "a", "an", "ein", "einen", "bitte", "please"].contains(f.n) { titleToks.removeFirst() }
        var title = joinTokens(titleToks, in: t).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!–-"))
        if title.isEmpty { title = en ? "Meeting" : "Termin" }
        else if let f = titleToks.first, f.n == "mit" { title = "Termin " + title }
        else if let f = titleToks.first, f.n == "with" { title = "Meeting " + title }
        else { title = capitalizeFirst(title) }
        let end = when.allDay ? start : (when.end ?? start.addingTimeInterval(TimeInterval(when.durationMin ?? 30) * 60))
        return VoiceCommand(kind: .event, text: title, date: start, end: end, allDay: when.allDay, english: en,
                            trigger: w[0..<i].joined(separator: " "))
    }

    // MARK: Notizen

    private static func parseNote(_ t: String, _ toks: [VCToken]) -> VoiceCommand? {
        let w = toks.map(\.n)
        func at(_ k: Int) -> String { k < w.count ? w[k] : "" }
        var i = 0, en = false
        switch at(0) {
        case "notiz", "notitz", "notis":
            // „Notiz am Rande: …“ ist eine Redewendung im normalen Text
            if at(1) == "am" && at(2) == "rande" { return nil }
            i = 1
            if !toks[0].sep {
                if at(1) == "an" && at(2) == "mich" { i = 3; if at(3) == "selbst" { i = 4 } }
                else if at(1) == "fur" && ["mich", "spater"].contains(at(2)) { i = 3 }
                // „Notiz an alle: …“ / „Notiz für Nico: …“ richtet sich an andere
                else if ["an", "fur", "von"].contains(at(1)) { return nil }
                // „Notiz vom Arzt brauche ich noch“ – nur mit Doppelpunkt kurz danach („Notiz zum Uhrenprojekt: …“)
                else if ["vom", "zum", "zur", "aus", "uber", "der", "des", "dem", "im", "in", "auf", "mit", "bei"].contains(at(1)) {
                    if !toks[1...].prefix(4).contains(where: { $0.colon }) { return nil }
                }
                else if finiteDE.contains(at(1)) || looksVerbal(toks[1]) { return nil }
                // ohne Trennzeichen: Frage oder „du/dir“ → ein Satz an jemanden („Notiz gelesen, die ich dir hingelegt hab?“)
                if t.hasSuffix("?") || toks.contains(where: { secondPerson.contains($0.n) }) { return nil }
            }
        case "notizen" where toks[0].colon, "notes" where toks[0].colon: i = 1; en = at(0) == "notes"
        case "neue" where ["notiz", "notitz"].contains(at(1)): i = 2
        // „Notiere: …“ / „Notier dir: …“ nur mit Doppelpunkt (sonst oft an jemanden gerichtet)
        case "notiere", "notier":
            if toks[0].colon { i = 1 } else if ["dir", "mir"].contains(at(1)), toks[1].colon { i = 2 } else { return nil }
        case "note":
            en = true
            if at(1) == "to" && at(2) == "self" { i = 3 }
            else if toks[0].colon {
                i = 1
                // „Note: attachments are too large, I'll send …“ – Hinweis an den Leser einer Mail, keine Notiz (dafür „Note to self“)
                if toks.dropFirst().contains(where: { ["i", "i'll", "i'm", "i've", "you", "your", "you'll", "please", "attached", "attachment", "attachments", "below", "above"].contains($0.n) }) { return nil }
            }
            else if at(1).hasSuffix("ing") || at(1) == "down" || toks.dropFirst().contains(where: { finiteEN.contains($0.n) }) { return nil }
            // „Note that …“, „Note the difference …“, „Note, however, …“ sind normale Sätze
            else if ["that", "the", "this", "these", "those", "how", "what", "however", "though", "also", "well", "to", "it", "a", "an", "that's",
                     "which", "when", "where", "why", "if", "whether", "and", "but", "here", "there", "we", "i", "you", "they", "he", "she"].contains(at(1)) { return nil }
            else { i = 1 }
        case "new" where at(1) == "note": i = 2; en = true
        default: return nil
        }
        guard i < toks.count else { return nil }
        let body = cleanBody(String(t[toks[i].range.lowerBound...]))
        guard !body.isEmpty else { return nil }
        return VoiceCommand(kind: .note, text: body, english: en, trigger: w[0..<i].joined(separator: " "))
    }

    // MARK: Websuche

    private static func parseSearch(_ t: String, _ toks: [VCToken]) -> VoiceCommand? {
        let w = toks.map(\.n)
        func at(_ k: Int) -> String { k < w.count ? w[k] : "" }
        var i = 0, en = false
        switch at(0) {
        case "such", "suche":
            var k = 1
            var qualified = false
            if at(k) == "mal" { k += 1; qualified = true }
            if ["im", "in"].contains(at(k)), ["internet", "netz", "web", "google"].contains(at(k + 1)) { k += 2; qualified = true }
            else if at(k) == "online" { k += 1; qualified = true }
            else if ["bei", "auf"].contains(at(k)), at(k + 1) == "google" { k += 2; qualified = true }
            guard at(k) == "nach" else { return nil }
            // „Suche nach Sponsoren“ ist meist das Nomen (Überschrift, To-do) – nur „such nach“ oder „suche mal/im Internet nach“
            if at(0) == "suche" && !qualified { return nil }
            if at(k + 1) == "wie", at(k + 2) == "vor" { return nil }   // „nach wie vor“
            i = k + 1
        case "websuche", "internetsuche", "googlesuche", "google-suche":
            guard toks[0].colon else { return nil }
            i = 1
        case "google", "googel", "googele", "googl":
            var k = 1
            if at(k) == "mal" { k += 1 }
            if at(k) == "nach" { k += 1 }
            // „Google hat …“: ohne „mal“/„nach“ nur die Verbform „googel/googele“
            if k == 1 && at(0) == "google" { return nil }
            i = k
        case "search":
            en = true
            var k = 1
            if at(k) == "the", ["web", "internet"].contains(at(k + 1)) { k += 2 }
            else if ["google", "online"].contains(at(k)) { k += 1 }
            guard at(k) == "for" else { return nil }
            i = k + 1
        case "look" where at(1) == "up":
            en = true
            if ["at", "to", "and", "there", "here"].contains(at(2)) { return nil }
            i = 2
        default: return nil
        }
        guard i < toks.count else { return nil }
        let rest = Array(toks[i...])
        // „Such nach mir, Herr …“ (Liedzeile) – Pronomen statt Suchbegriff
        if ["mir", "mich", "uns", "ihm", "ihr", "ihn", "me", "us", "him", "her", "them"].contains(rest.first?.n ?? "") { return nil }
        // Fragen als Suchbegriff („such nach wie lange muss hefeteig gehen“) dürfen Verben enthalten
        let asksQuestion = whWords.contains(rest.first?.n ?? "") && !["of", "if", "ob", "whether"].contains(rest.first?.n ?? "")
        if !asksQuestion, rest.contains(where: { finiteDE.contains($0.n) || finiteEN.contains($0.n) || looksVerbal($0) }) { return nil }
        // To-do-Punkt: endet mit einem kleingeschriebenen Infinitiv („… Sponsoren starten“)
        if !asksQuestion, let last = rest.last, rest.count >= 2, last.raw.first?.isLowercase == true, last.n.hasSuffix("en"),
           ["starten", "beginnen", "organisieren", "machen", "planen", "vorbereiten", "abschliessen", "anfangen", "klaren", "erledigen"].contains(last.n) { return nil }
        if rest.contains(where: { secondPerson.contains($0.n) }) { return nil }
        let q = cleanBody(String(t[toks[i].range.lowerBound...])).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !q.isEmpty else { return nil }
        return VoiceCommand(kind: .search, text: q, english: en, trigger: w[0..<i].joined(separator: " "))
    }

    // MARK: Werkzeuge

    /// Sieht nach Partizip/Verb aus („gelesen“, „gemacht“, „beendet“, „erledigt“, „organisiert“) – nur kleingeschriebene Wörter (Nomen sind groß)
    static func looksVerbal(_ tok: VCToken) -> Bool {
        guard let f = tok.raw.first(where: { $0.isLetter }), f.isLowercase else { return false }
        let n = tok.n
        guard n.count >= 6 else { return false }
        if n.range(of: "^ge[a-z]{3,}(t|en)$", options: .regularExpression) != nil { return true }
        if n.range(of: "^(be|er|ver|zer|ent|emp)[a-z]{3,}(et|t)$", options: .regularExpression) != nil { return true }
        if n.hasSuffix("iert") { return true }
        return false
    }

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    private static let trailing = CharacterSet(charactersIn: ",;:!?…\"“”„'’»«)]}*")
    private static let leading = CharacterSet(charactersIn: "\"“”„'’»«([{*¿¡")

    static func tokenize(_ s: String) -> [VCToken] {
        var out: [VCToken] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
            guard idx < s.endIndex else { break }
            var end = idx
            while end < s.endIndex, !s[end].isWhitespace { end = s.index(after: end) }
            let raw = String(s[idx..<end])
            let range = idx..<end
            idx = end
            // Allein stehende Trennzeichen („Nico – ich …“) gehören zum Wort davor
            if raw.allSatisfy({ ":-–—,;.".contains($0) }) {
                if !out.isEmpty { out[out.count - 1].sep = true; if raw.contains(":") { out[out.count - 1].colon = true } }
                continue
            }
            var n = fold(raw)
            n = String(n.unicodeScalars.drop { leading.contains($0) }.map(Character.init))
            var sep = false, colon = false
            while let last = n.unicodeScalars.last, trailing.contains(last) || last == "-" || last == "–" {
                if ":,;–-!?".unicodeScalars.contains(last) { sep = true }
                if last == ":" { colon = true }
                n.removeLast()
            }
            if n.hasSuffix(".") {
                // „3.“ (Tag) und „3.10.“ / „9.30.“ bleiben stehen, sonst ist der Punkt Satzende
                let keep = n.range(of: "^\\d{1,2}\\.(\\d{1,2}\\.)?$", options: .regularExpression) != nil
                if !keep { while n.hasSuffix(".") { n.removeLast() }; sep = true }
            }
            // „Nico's“ / „Nico’s“ bleiben ein Wort; Bindestrich-Namen wie „Jo-El“ werden zusammengezogen erst beim Namensvergleich
            n = n.replacingOccurrences(of: "’", with: "'")
            guard !n.isEmpty else {
                if sep, !out.isEmpty { out[out.count - 1].sep = true; if colon { out[out.count - 1].colon = true } }
                continue
            }
            out.append(VCToken(raw: raw, n: n, range: range, sep: sep, colon: colon))
        }
        return out
    }

    /// Wörter (Teilfolge) wieder als Text – mit ihren Original-Satzzeichen, getrennt durch ein Leerzeichen
    static func joinTokens(_ toks: [VCToken], in t: String) -> String {
        toks.map { String(t[$0.range]) }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–-"))
    }

    /// Nachricht/Notiz: führende Trenner weg, erstes Zeichen groß, Zeilenumbrüche bleiben
    static func cleanBody(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = t.unicodeScalars.first, CharacterSet(charactersIn: ":,;–—-. ").contains(f) { t.removeFirst() }
        return capitalizeFirst(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
