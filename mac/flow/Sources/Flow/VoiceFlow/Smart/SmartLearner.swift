import Foundation

// MARK: - „Flow lernt mit“: Wissen zusammenführen + Vorschläge ableiten (reine Funktionen auf SmartWissen)
//
// Läuft immer auf der Lern-Queue von SmartFlow (niedrige Priorität). Kein UI, keine Dateien.

/// Momentaufnahme der Stores (auf dem Main-Thread eingesammelt, danach nur gelesen)
struct SmartContext {
    var known: Set<String> = []
    var myName = ""
    var snippetTexts: Set<String> = []
    var snippetTriggers: Set<String> = []
    var transformKeys: Set<String> = []
    var styles: [String: StyleKind] = [:]
    var retentionDays = 3
    var prefs = SmartPrefs()

    /// Einmalige Bruchstücke leben so lange wie Rohtexte (Löschfrist); „nie löschen“ → höchstens 30 Tage
    var singletonAge: TimeInterval { Double(retentionDays > 0 ? retentionDays : 30) * 86400 }
    var pendingAge: TimeInterval { min(SmartPolicy.maxPendingAge, singletonAge) }
}

/// Was ein Diktat verändert hat (nur diese Stellen werden neu bewertet)
struct SmartTouched {
    var terms: [String] = []
    var signOffs: [String] = []
    var phrases: [(cat: String, key: String)] = []
    var register: String?
    var similarPrints = 0
    /// Stabile Kennung der Gruppe ähnlicher langer Diktate
    var printKey: String?
    var longText: String?
    var dates: [SmartAnalyzer.DateHit] = []
    var category = AppCategory.other
    var needSpell: [String] = []
}

enum SmartLearner {

    static func dayNumber(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 86400) }

    static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    // MARK: Diktat einarbeiten

    static func merge(_ f: SmartAnalyzer.Features, text: String, date: Date, category: AppCategory,
                      into w: inout SmartWissen, ctx: SmartContext) -> SmartTouched {
        var t = SmartTouched(category: category)
        let cat = category.rawValue
        let day = dayKey.string(from: date)
        w.dictations += 1
        w.words += f.wordCount
        w.categories[cat, default: 0] += 1

        // Nutzungszeiten
        let cal = Calendar(identifier: .gregorian)
        let h = cal.component(.hour, from: date)
        let wd = (cal.component(.weekday, from: date) + 5) % 7   // So=1 → 6, Mo=2 → 0
        if w.hours.count != 24 { w.hours = [Int](repeating: 0, count: 24) }
        if w.weekdays.count != 7 { w.weekdays = [Int](repeating: 0, count: 7) }
        w.hours[h] += 1
        w.weekdays[wd] += 1

        // Namen & Begriffe
        for (form, kind) in f.terms {
            let k = form.lowercased()
            var term = w.terms[k] ?? SmartTerm(form: form, kind: kind, first: date, last: date)
            term.n += 1
            term.dictations += 1
            if term.lastDay != day { term.days += 1; term.lastDay = day }
            term.last = max(term.last, date)
            term.form = form
            if term.kind == .term, kind != .term { term.kind = kind }
            w.terms[k] = term
            t.terms.append(k)
            if term.spellKnown == nil, term.n >= 2 { t.needSpell.append(form) }
        }

        // Formulierungen: erstes Vorkommen nur als Prüfsumme, ab dem zweiten mit Schreibweise
        let today = dayNumber(date)
        for (key, form) in f.phrases {
            if var c = w.phrases[cat]?[key] {
                c.hit(form, at: date, day: day)
                w.phrases[cat]![key] = c
                t.phrases.append((cat, key))
                continue
            }
            let seed = SmartAnalyzer.seedKey(key)
            if let seedDay = w.seeds[seed] {
                w.seeds[seed] = nil
                let c = SmartCount(form: form, n: 2, days: seedDay == today ? 1 : 2, first: date, last: date, lastDay: day)
                w.phrases[cat, default: [:]][key] = c
                t.phrases.append((cat, key))
            } else {
                w.seeds[seed] = today
            }
        }

        if let (key, form) = f.signOff {
            var c = w.signOffs[cat]?[key] ?? SmartCount(form: form, first: date, last: date)
            c.hit(form, at: date, day: day)
            w.signOffs[cat, default: [:]][key] = c
            t.signOffs.append(key)
        }
        if let (key, form) = f.greeting {
            var c = w.greetings[cat]?[key] ?? SmartCount(form: form, first: date, last: date)
            c.hit(form, at: date, day: day)
            w.greetings[cat, default: [:]][key] = c
        }
        if f.formal != f.casual {
            var r = w.register[cat] ?? SmartRegister()
            if f.formal > f.casual { r.formal += 1 } else { r.casual += 1 }
            w.register[cat] = r
            t.register = cat
        }

        // Lange Diktate: ähnliche frühere Fingerabdrücke zählen
        if let sig = f.print, !sig.isEmpty {
            var hit: Int?
            for (i, p) in w.prints.enumerated() where SmartAnalyzer.similarity(p.sig, sig) >= 0.6 {
                hit = i; break
            }
            if let i = hit {
                w.prints[i].seen += 1
                w.prints[i].date = date
                t.similarPrints = w.prints[i].seen
                t.printKey = w.prints[i].sig.prefix(3).map { String($0, radix: 36) }.joined(separator: "-")
                t.longText = text
            } else {
                w.prints.append(SmartPrint(date: date, category: cat, words: f.wordCount, sig: sig))
            }
        }
        t.dates = f.dates
        return t
    }

    // MARK: Meeting einarbeiten (nur Zusammenfassung)

    static func mergeMeeting(id: String, title: String, date: Date, features mf: SmartAnalyzer.MeetingFeatures,
                             into w: inout SmartWissen) {
        guard !w.ingestedMeetings.contains(id) else { return }
        w.ingestedMeetings.append(id)
        if w.ingestedMeetings.count > SmartLimits.ingestedMeetings { w.ingestedMeetings.removeFirst(w.ingestedMeetings.count - SmartLimits.ingestedMeetings) }
        w.meetings += 1
        let day = dayKey.string(from: date)
        for p in mf.people {
            var c = w.meetingPeople[p.lowercased()] ?? SmartCount(form: p, first: date, last: date)
            c.hit(p, at: date, day: day)
            w.meetingPeople[p.lowercased()] = c
            // Namen aus Meetings stärken auch die Wörterbuch-Kandidaten
            if SmartAnalyzer.isTermShaped(p), !p.contains(" ") {
                var term = w.terms[p.lowercased()] ?? SmartTerm(form: p, kind: .person, first: date, last: date)
                term.fromMeetings += 1
                w.terms[p.lowercased()] = term
            }
        }
        for tp in mf.topics {
            var c = w.meetingTopics[tp.lowercased()] ?? SmartCount(form: tp, first: date, last: date)
            c.hit(tp, at: date, day: day)
            w.meetingTopics[tp.lowercased()] = c
        }
        w.meetingDigests.insert(SmartMeetingDigest(id: id, date: date, title: title, people: Array(mf.people.prefix(6)),
                                                   topics: mf.topics, tasks: mf.tasks.count), at: 0)
        if w.meetingDigests.count > SmartLimits.meetingDigests { w.meetingDigests.removeLast(w.meetingDigests.count - SmartLimits.meetingDigests) }
    }

    static func noteCorrection(old: String, new: String, saved: Bool, date: Date, into w: inout SmartWissen) -> String? {
        let o = old.trimmingCharacters(in: .whitespaces), n = new.trimmingCharacters(in: .whitespaces)
        guard !o.isEmpty, !n.isEmpty, o.lowercased() != n.lowercased() || o != n else { return nil }
        let k = o.lowercased() + "\u{1}" + n
        var c = w.corrections[k] ?? SmartCorrection(old: o, new: n)
        if saved, c.n > 0, date.timeIntervalSince(c.last) < 600 {
            c.saved = true          // gerade erst als Kandidat gezählt → nicht doppelt zählen
        } else {
            c.n += 1
            c.last = date
            if saved { c.saved = true }
        }
        w.corrections[k] = c
        return k
    }

    // MARK: Aufräumen (Löschfrist + Obergrenzen)

    static func prune(_ w: inout SmartWissen, ctx: SmartContext, now: Date = Date()) {
        let singleCut = now.addingTimeInterval(-ctx.singletonAge)
        let todayN = dayNumber(now)
        let seedDays = Int(ceil(ctx.singletonAge / 86400))
        w.seeds = w.seeds.filter { todayN - $0.value <= seedDays }
        if w.seeds.count > SmartLimits.seeds {
            let keep = w.seeds.sorted { $0.value > $1.value }.prefix(SmartLimits.seeds)
            w.seeds = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        // Formulierungen: n=2 verfallen nach 30 Tagen ohne Wiederholung; sonst Obergrenze nach Häufigkeit × Aktualität
        let stale = now.addingTimeInterval(-30 * 86400)
        for (cat, dict) in w.phrases {
            var d = dict.filter { !($0.value.n <= 2 && $0.value.last < stale) }
            if d.count > SmartLimits.phrasesPerCategory {
                let keep = d.sorted { score($0.value, now) > score($1.value, now) }.prefix(SmartLimits.phrasesPerCategory)
                d = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            w.phrases[cat] = d.isEmpty ? nil : d
        }
        w.terms = w.terms.filter { !($0.value.n <= 1 && $0.value.fromMeetings == 0 && $0.value.last < singleCut) }
        if w.terms.count > SmartLimits.terms {
            let keep = w.terms.sorted { ($0.value.n + $0.value.fromMeetings) > ($1.value.n + $1.value.fromMeetings) }.prefix(SmartLimits.terms)
            w.terms = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        for (cat, d) in w.signOffs where d.count > SmartLimits.signOffsPerCategory {
            let keep = d.sorted { $0.value.n > $1.value.n }.prefix(SmartLimits.signOffsPerCategory)
            w.signOffs[cat] = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if w.corrections.count > SmartLimits.corrections {
            let keep = w.corrections.sorted { $0.value.last > $1.value.last }.prefix(SmartLimits.corrections)
            w.corrections = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        func cap(_ d: [String: SmartCount], _ n: Int) -> [String: SmartCount] {
            guard d.count > n else { return d }
            return Dictionary(uniqueKeysWithValues: d.sorted { $0.value.n > $1.value.n }.prefix(n).map { ($0.key, $0.value) })
        }
        w.meetingPeople = cap(w.meetingPeople, SmartLimits.meetingPeople)
        w.meetingTopics = cap(w.meetingTopics, SmartLimits.meetingTopics)
        // Fingerabdrücke langer Diktate: nur solange es auch den Rohtext gibt (einmalige) bzw. 30 Tage (wiederholte)
        w.prints = w.prints.filter { $0.date > ($0.seen > 1 ? stale : singleCut) }
        if w.prints.count > SmartLimits.prints { w.prints.removeFirst(w.prints.count - SmartLimits.prints) }
        // Offene Vorschläge verfallen
        w.pending.removeAll { $0.expires < now }
        if w.decided.count > SmartLimits.decided {
            let keep = w.decided.sorted { $0.value > $1.value }.prefix(SmartLimits.decided)
            w.decided = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private static func score(_ c: SmartCount, _ now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(c.last) / 86400)
        return Double(c.n) / (1 + ageDays / 14)
    }

    // MARK: Vorschläge ableiten

    static func candidates(_ t: SmartTouched, w: SmartWissen, ctx: SmartContext, now: Date = Date()) -> [SmartSuggestion] {
        var out: [SmartSuggestion] = []
        let expires = now.addingTimeInterval(ctx.pendingAge)

        // 1) Namen/Begriffe → Wörterbuch (nur, was macOS nicht kennt und noch nicht im Wörterbuch steht)
        for k in Set(t.terms) {
            guard let term = w.terms[k] else { continue }
            if let s = dictionarySuggestion(term, ctx: ctx, expires: expires) { out.append(s) }
        }

        // 2) Abschiedsformel → Snippet
        for key in Set(t.signOffs) {
            var total = 0, days = 0
            var form = ""
            for (_, d) in w.signOffs { if let c = d[key] { total += c.n; days = max(days, c.days); form = c.form } }
            guard total >= 3, form.count >= 10, !ctx.snippetTexts.contains(form.pgKey) else { continue }
            let options = SmartAnalyzer.triggerOptions(for: form, existing: ctx.snippetTriggers, myName: ctx.myName)
            guard let first = options.first else { continue }
            let conf = min(0.95, 0.5 + 0.08 * Double(total) + 0.05 * Double(days))
            out.append(SmartSuggestion(kind: .snippet, key: "snip:" + key, title: "Als Snippet speichern?",
                                       text: "Du schreibst oft „\(form)“. Mit welchem Kürzel abrufen?",
                                       confidence: conf, expires: expires,
                                       payload: SmartPayload(trigger: first, triggerOptions: options, text: form)))
        }

        // 3) Ganzer Satz, den du immer wieder sagst → Snippet (nicht in KI-Apps: dort sind es Prompts → Transform)
        for (cat, key) in t.phrases where cat != AppCategory.ai.rawValue {
            guard let c = w.phrases[cat]?[key], c.n >= 5, c.days >= 2, key.split(separator: " ").count >= 6, c.form.count >= 30,
                  !ctx.snippetTexts.contains(c.form.pgKey) else { continue }
            let options = SmartAnalyzer.triggerOptions(for: c.form, existing: ctx.snippetTriggers, myName: ctx.myName)
            guard let first = options.first else { continue }
            let conf = min(0.85, 0.35 + 0.06 * Double(c.n))   // 5× nur in der Liste, ab 6× als Karte
            out.append(SmartSuggestion(kind: .snippet, key: "phr:" + key, title: "Als Snippet speichern?",
                                       text: "„\(c.form)“ sagst du oft (\(c.n)×). Als Snippet speichern?",
                                       confidence: conf, expires: expires,
                                       payload: SmartPayload(trigger: first, triggerOptions: options, text: c.form)))
        }

        // 4) Stil je App-Art
        if let cat = t.register, let r = w.register[cat], let category = AppCategory(rawValue: cat), category != .ai {
            let current = ctx.styles[StyleStore.settingsKey(category)] ?? .formal
            let formalRatio = r.total > 0 ? Double(r.formal) / Double(r.total) : 0
            let casualRatio = r.total > 0 ? Double(r.casual) / Double(r.total) : 0
            if r.total >= 6, formalRatio >= 0.75, current != .formal {
                let conf = min(0.95, 0.6 + 0.3 * (formalRatio - 0.75) / 0.25 + min(0.1, Double(r.total) / 100))
                out.append(styleSuggestion(category, .formal, conf, "In \(label(category)) schreibst du meist formell (\(r.formal) von \(r.total)).", expires))
            } else if r.total >= 8, casualRatio >= 0.8, current == .formal, category != .email {
                let conf = min(0.9, 0.55 + 0.3 * (casualRatio - 0.8) / 0.2 + min(0.1, Double(r.total) / 100))
                out.append(styleSuggestion(category, .casual, conf, "In \(label(category)) schreibst du meist locker (\(r.casual) von \(r.total)).", expires))
            }
        }

        // 5) Wiederholtes langes Diktat → Transform (KI-Apps) bzw. Snippet (sonst)
        if t.similarPrints >= 2, let text = t.longText {
            let clipped = text.count > 1200 ? String(text.prefix(1200)) : text
            let key = "rep:" + (t.printKey ?? SmartAnalyzer.seedKey(String(clipped.lowercased().prefix(120))))
            let conf = t.similarPrints >= 3 ? 0.85 : 0.7
            let words = clipped.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let name = words.prefix(4).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            if t.category == .ai || looksLikeInstruction(clipped) {
                if !ctx.transformKeys.contains(String(clipped.pgKey.prefix(60))) {
                    out.append(SmartSuggestion(kind: .transform, key: key, title: "Als Transform speichern?",
                                               text: "Diese Anweisung diktierst du öfter (\(t.similarPrints)×). Künftig mit einem Wort abrufen?",
                                               confidence: conf, expires: expires,
                                               payload: SmartPayload(trigger: name, text: clipped)))
                }
            } else if !ctx.snippetTexts.contains(clipped.pgKey) {
                let options = SmartAnalyzer.triggerOptions(for: clipped, existing: ctx.snippetTriggers, myName: ctx.myName)
                if let first = options.first {
                    out.append(SmartSuggestion(kind: .snippet, key: key, title: "Als Snippet speichern?",
                                               text: "Diesen Text diktierst du öfter (\(t.similarPrints)×). Als Snippet speichern?",
                                               confidence: conf - 0.05, expires: expires,
                                               payload: SmartPayload(trigger: first, triggerOptions: options, text: clipped)))
                }
            }
        }

        // 6) Termin im Diktat → Kalender
        for d in t.dates.prefix(1) {
            var conf = d.meetingWord ? 0.78 : 0.55
            if t.category == .ai { conf -= 0.15 }
            let key = "cal:" + String(Int(d.date.timeIntervalSince1970 / 60)) + ":" + d.title.pgKey.prefix(24)
            out.append(SmartSuggestion(kind: .calendar, key: key, title: "Termin eintragen?",
                                       text: "„\(d.title)“ am \(shortDate(d.date)) in den Kalender eintragen?",
                                       confidence: conf, expires: min(expires, d.date),
                                       payload: SmartPayload(date: d.date, eventTitle: d.title)))
        }
        return out
    }

    static func dictionarySuggestion(_ term: SmartTerm, ctx: SmartContext, expires: Date) -> SmartSuggestion? {
        let k = term.form.lowercased()
        guard term.spellKnown == false, !ctx.known.contains(k) else { return nil }
        let n = term.n + term.fromMeetings
        guard n >= 3, term.dictations + term.fromMeetings >= 2 else { return nil }
        var conf = 0.45 + 0.1 * Double(n) + 0.05 * Double(min(term.days, 4))
        if term.kind == .person || term.kind == .org { conf += 0.05 }
        return SmartSuggestion(kind: .dictionary, key: "dict:" + k, title: "Ins Wörterbuch?",
                               text: "„\(term.form)“ kam \(n)× vor. Soll Flow es sich merken, damit es immer richtig geschrieben wird?",
                               confidence: min(0.95, conf), expires: expires, payload: SmartPayload(term: term.form))
    }

    static func correctionSuggestion(_ c: SmartCorrection, ctx: SmartContext, expires: Date) -> SmartSuggestion? {
        guard !c.saved, c.n >= 2, !ctx.known.contains(c.old.lowercased()) else { return nil }
        let conf = min(0.92, 0.45 + 0.1 * Double(c.n))   // 2× nur leise in der Liste, ab 3× als Karte
        return SmartSuggestion(kind: .dictionary, key: "corr:" + c.old.lowercased() + ">" + c.new,
                               title: "Öfter korrigiert", text: "Du änderst „\(c.old)“ oft in „\(c.new)“ (\(c.n)×). Ins Wörterbuch?",
                               confidence: conf, expires: expires,
                               payload: SmartPayload(term: c.new, correctionOld: c.old))
    }

    static func meetingSuggestion(id: String, title: String, date: Date, tasks: [SmartTask], now: Date = Date()) -> SmartSuggestion? {
        guard !tasks.isEmpty, now.timeIntervalSince(date) < 36 * 3600 else { return nil }
        let n = tasks.count
        let conf = min(0.9, 0.65 + 0.05 * Double(min(4, n)))
        return SmartSuggestion(kind: .reminders, key: "rem:" + id,
                               title: n == 1 ? "1 Aufgabe erkannt" : "\(n) Aufgaben erkannt",
                               text: "Aus „\(title)“ – in Erinnerungen übernehmen?",
                               confidence: conf, expires: now.addingTimeInterval(3 * 86400),
                               payload: SmartPayload(tasks: Array(tasks.prefix(12)), meetingID: id))
    }

    private static func styleSuggestion(_ c: AppCategory, _ k: StyleKind, _ conf: Double, _ why: String, _ expires: Date) -> SmartSuggestion {
        let name = k == .formal ? "Formell" : "Locker"
        return SmartSuggestion(kind: .style, key: "style:\(c.rawValue):\(k.rawValue)", title: "Stil für \(shortLabel(c))",
                               text: "\(why) Auf „\(name)“ stellen?", confidence: conf, expires: expires,
                               payload: SmartPayload(category: c.rawValue, style: k.rawValue))
    }

    static func label(_ c: AppCategory) -> String {
        switch c {
        case .email: return "Mails"
        case .personal: return "Chats"
        case .work: return "Arbeits-Chats"
        case .ai: return "KI-Apps"
        case .other: return "anderen Apps"
        }
    }

    static func shortLabel(_ c: AppCategory) -> String {
        switch c {
        case .email: return "E-Mail"
        case .personal: return "Chats"
        case .work: return "Arbeit"
        case .ai: return "KI"
        case .other: return "Sonstiges"
        }
    }

    static func looksLikeInstruction(_ s: String) -> Bool {
        let l = s.lowercased()
        let cues = ["fasse ", "fass ", "schreib ", "schreibe ", "formuliere", "übersetze", "erstelle", "mach daraus", "mach mir",
                    "ordne", "korrigiere", "summarize", "write ", "rewrite", "translate", "create ", "make it", "please "]
        return cues.contains { l.hasPrefix($0) || l.contains(". " + $0) }
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE")
        let cal = Calendar.current
        if cal.isDateInToday(d) { f.dateFormat = "'heute' HH:mm" }
        else if cal.isDateInTomorrow(d) { f.dateFormat = "'morgen' HH:mm" }
        else if d.timeIntervalSinceNow < 6 * 86400 { f.dateFormat = "EE HH:mm" }
        else { f.dateFormat = "EE d. MMM HH:mm" }
        return f.string(from: d).replacingOccurrences(of: ".,", with: ",")
    }

    // MARK: In die offene Liste übernehmen

    /// Gibt zurück, welche Vorschläge neu (oder stärker) sind.
    @discardableResult
    static func offer(_ list: [SmartSuggestion], into w: inout SmartWissen, ctx: SmartContext) -> [SmartSuggestion] {
        var added: [SmartSuggestion] = []
        for s in list {
            guard ctx.prefs.isOn(s.kind), !ctx.prefs.stat(s.kind).stopped, w.decided[s.key] == nil else { continue }
            // Gleicher Text schon unter anderem Schlüssel offen (Abschied = Satzteil) → nicht doppelt
            if let t = s.payload.text?.pgKey, !t.isEmpty,
               w.pending.contains(where: { $0.key != s.key && $0.payload.text?.pgKey == t }) { continue }
            guard s.confidence >= SmartPolicy.listThreshold(dismissed: ctx.prefs.stat(s.kind).dismissed) else { continue }
            if let i = w.pending.firstIndex(where: { $0.key == s.key }) {
                // Text/Sicherheit auffrischen, Karten-Status behalten
                var upd = s
                upd.id = w.pending[i].id
                upd.shownAsCard = w.pending[i].shownAsCard
                upd.created = w.pending[i].created
                if upd != w.pending[i] { w.pending[i] = upd }
            } else {
                w.pending.append(s)
                added.append(s)
            }
        }
        // Je Art nur die besten paar offen halten (nicht zuschütten)
        for k in SmartKind.allCases {
            let mine = w.pending.filter { $0.kind == k }
            let cap = SmartPolicy.maxPendingPerKind(k)
            guard mine.count > cap else { continue }
            let drop = Set(mine.sorted { $0.confidence > $1.confidence }.dropFirst(cap).map(\.id))
            w.pending.removeAll { drop.contains($0.id) }
            added.removeAll { drop.contains($0.id) }
        }
        if w.pending.count > SmartPolicy.maxPending {
            w.pending.sort { $0.confidence > $1.confidence }
            w.pending.removeLast(w.pending.count - SmartPolicy.maxPending)
        }
        return added
    }
}
