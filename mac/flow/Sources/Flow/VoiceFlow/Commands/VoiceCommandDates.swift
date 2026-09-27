import Foundation

// MARK: - Sprachbefehle: Datum & Uhrzeit aus gesprochenem Text
//
// Kleiner eigener Parser für Deutsch (und die häufigen englischen Formen), weil NSDataDetector
// „morgen um halb zehn“, „in zwei Stunden“, „nächsten Freitag“ nicht versteht. NSDataDetector
// springt nur ein, wenn der eigene Parser gar nichts findet (z. B. „October 3rd at 5pm“).
//
// Regeln:
//  - Uhrzeit ohne Tag, die heute schon vorbei ist → morgen.
//  - Wochentag = der nächste; heute nur, wenn eine spätere Uhrzeit dabei ist.
//  - „um 1“ … „um 6“ ohne „früh/morgens“ = nachmittags (13–18 Uhr). „um 7“ … „um 12“ bleibt vormittags.
//  - Nur Tag, keine Uhrzeit → ganztägig. Tageszeit ohne Uhrzeit: früh 9, mittags 12, nachmittags 15, abends 19, nachts 21.

struct VCWhen {
    var date: Date?
    var allDay = false
    var end: Date?
    var durationMin: Int?
    /// Indizes der Wörter, die zur Zeitangabe gehören (fallen aus dem Titel heraus)
    var used: Set<Int> = []
}

enum VCDateParser {
    private enum Period { case morning, noon, afternoon, evening, night }

    private struct Acc {
        var dayOffset: Int?
        var weekday: Int?          // 1 = Sonntag … 7 = Samstag (Calendar)
        var weekdayForceNext = false
        var abs: (d: Int, m: Int, y: Int?)?
        var relSeconds: TimeInterval?
        var hour: Int?
        var minute = 0
        var explicitAMPM: Bool?    // true = pm, false = am
        var period: Period?
        var durationMin: Int?
        var endHour: Int?
        var endMinute = 0
        var forceAllDay = false
        var hasDay: Bool { dayOffset != nil || weekday != nil || abs != nil }
    }

    static let weekdays: [String: Int] = [
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]
    static let months: [String: Int] = [
        "januar": 1, "janner": 1, "februar": 2, "marz": 3, "maerz": 3, "april": 4, "mai": 5, "juni": 6, "juli": 7, "august": 8,
        "september": 9, "oktober": 10, "november": 11, "dezember": 12,
        "january": 1, "february": 2, "march": 3, "may": 5, "june": 6, "july": 7, "october": 10, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "okt": 10, "oct": 10, "nov": 11, "dez": 12, "dec": 12,
    ]
    private static let small: [String: Int] = [
        "null": 0, "ein": 1, "eins": 1, "eine": 1, "einer": 1, "einem": 1, "einen": 1, "ner": 1, "zwei": 2, "zwo": 2, "drei": 3, "vier": 4, "funf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwolf": 12, "dreizehn": 13, "vierzehn": 14, "funfzehn": 15,
        "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19, "zwanzig": 20, "dreissig": 30, "vierzig": 40, "funfzig": 50,
        "one": 1, "a": 1, "an": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "fortyfive": 45, "fifty": 50,
    ]
    private static let ordinals: [String: Int] = {
        var m: [String: Int] = [:]
        let stems = ["ers": 1, "zwei": 2, "drit": 3, "vier": 4, "funf": 5, "sechs": 6, "sieb": 7, "siebt": 7, "ach": 8, "neun": 9, "zehn": 10,
                     "elf": 11, "zwolf": 12, "dreizehn": 13, "vierzehn": 14, "funfzehn": 15, "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19]
        for (s, v) in stems { for e in ["te", "ten", "ter", "tem"] { m[s + e] = v } }
        for (s, v) in ["zwanzig": 20, "dreissig": 30] { for e in ["ste", "sten", "ster"] { m[s + e] = v } }
        for (u, v) in ["ein": 1, "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9] {
            for e in ["ste", "sten", "ster"] { m[u + "undzwanzig" + e] = 20 + v }
        }
        for e in ["ste", "sten", "ster"] { m["einunddreissig" + e] = 31 }
        for (w, v) in ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10] { m[w] = v }
        return m
    }()

    /// Zahl aus Ziffern oder Zahlwort („zwei“, „fünfundzwanzig“, „twenty“)
    static func number(_ s: String) -> Int? {
        var t = s
        while t.hasSuffix(".") { t.removeLast() }
        if let v = Int(t) { return v }
        if let v = small[t] { return v }
        if t.hasSuffix("zig") || t.hasSuffix("ssig"), let r = t.range(of: "und") {
            if let a = small[String(t[..<r.lowerBound])], let b = small[String(t[r.upperBound...])] { return a + b }
        }
        return nil
    }

    private static func ordinal(_ s: String) -> Int? {
        if s.hasSuffix("."), let v = Int(s.dropLast()), (1...31).contains(v) { return v }
        if let v = ordinals[s] { return v }
        let m = s.replacingOccurrences(of: "(st|nd|rd|th)$", with: "", options: .regularExpression)
        if m != s, let v = Int(m), (1...31).contains(v) { return v }
        return nil
    }

    // MARK: Suche im Text

    static func extract(_ toks: [VCToken], now: Date, cal: Calendar, allowDuration: Bool) -> VCWhen {
        let w = toks.map(\.n)
        func at(_ k: Int) -> String { k >= 0 && k < w.count ? w[k] : "" }
        var a = Acc()
        var used = Set<Int>()
        var i = 0
        var lastDateEnd = -10
        func take(_ from: Int, _ to: Int) { for k in from..<to { used.insert(k) }; lastDateEnd = to; i = to }

        while i < w.count {
            let s = at(i)
            // --- in N Minuten/Stunden/Tagen/Wochen · in einer halben Stunde · in half an hour
            if ["in", "innerhalb"].contains(s) {
                var k = i + 1
                if at(k) == "einer", at(k + 1) == "halben", ["stunde", "std"].contains(at(k + 2)) { a.relSeconds = 1800; take(i, k + 3); continue }
                if at(k) == "half", ["an", "a"].contains(at(k + 1)), at(k + 2) == "hour" { a.relSeconds = 1800; take(i, k + 3); continue }
                if ["anderthalb", "eineinhalb"].contains(at(k)), ["stunden", "std"].contains(at(k + 1)) { a.relSeconds = 5400; take(i, k + 2); continue }
                if let n = number(at(k)) {
                    k += 1
                    if ["halb", "einhalb"].contains(at(k)) { k += 1 }
                    let u = at(k)
                    var sec: TimeInterval? = nil, days: Int? = nil
                    if ["minute", "minuten", "min", "minutes", "mins", "minute's"].contains(u) { sec = TimeInterval(n) * 60 }
                    else if ["stunde", "stunden", "std", "hour", "hours", "hrs", "h"].contains(u) { sec = TimeInterval(n) * 3600 }
                    else if ["tag", "tagen", "tage", "day", "days"].contains(u) { days = n }
                    else if ["woche", "wochen", "week", "weeks"].contains(u) { days = n * 7 }
                    else if ["monat", "monaten", "month", "months"].contains(u) { days = n * 30 }
                    if let sec { a.relSeconds = sec; take(i, k + 1); continue }
                    if let days { a.dayOffset = days; take(i, k + 1); continue }
                }
            }
            // --- ganztägig
            if ["ganztagig", "ganztags", "all-day", "allday"].contains(s) || (s == "all" && at(i + 1) == "day") {
                a.forceAllDay = true; take(i, s == "all" ? i + 2 : i + 1); continue
            }
            // --- heute / morgen / übermorgen / tomorrow / tonight
            if ["heute", "today"].contains(s) { a.dayOffset = 0; take(i, i + 1); continue }
            if s == "tonight" { a.dayOffset = 0; a.period = .evening; take(i, i + 1); continue }
            if s == "ubermorgen" { a.dayOffset = 2; take(i, i + 1); continue }
            if s == "the", at(i + 1) == "day", at(i + 2) == "after", at(i + 3) == "tomorrow" { a.dayOffset = 2; take(i, i + 4); continue }
            if s == "morgen" || s == "tomorrow" {
                // „heute morgen“ = heute früh
                if lastDateEnd == i, a.dayOffset == 0 { a.period = .morning; take(i, i + 1); continue }
                a.dayOffset = 1; take(i, i + 1); continue
            }
            // --- nächste Woche / next week
            if ["nachste", "kommende", "next"].contains(s), ["woche", "week"].contains(at(i + 1)) { a.dayOffset = 7; take(i, i + 2); continue }
            // --- Wochentag (am / nächsten / kommenden / diesen / on / next / this)
            do {
                var k = i
                var forceNext = false
                if ["am", "on", "diesen", "dieser", "this", "coming"].contains(at(k)), weekdays[at(k + 1)] != nil { k += 1 }
                else if ["nachsten", "nachster", "kommenden", "kommender", "next"].contains(at(k)), weekdays[at(k + 1)] != nil { k += 1; forceNext = true }
                if let wd = weekdays[at(k)] {
                    a.weekday = wd; a.weekdayForceNext = forceNext
                    take(i, k + 1); continue
                }
            }
            // --- Datum: „am 3. Oktober (2026)“, „3.10.“, „03.10.2026“, „October 3rd“, „3rd of October“, „dritten Oktober“
            do {
                var k = i
                if ["am", "on", "the", "den"].contains(at(k)) { k += 1 }
                if at(k) == "the" { k += 1 }
                if let d = ordinal(at(k)) ?? (months[at(k + 1)] != nil ? Int(at(k)) : nil) {
                    var m2 = k + 1
                    if at(m2) == "of" { m2 += 1 }
                    if let mo = months[at(m2)], (1...31).contains(d) {
                        var y: Int? = nil
                        if let yy = Int(at(m2 + 1)), yy >= 2000, yy < 2100 { y = yy; m2 += 1 }
                        a.abs = (d, mo, y); take(i, m2 + 1); continue
                    }
                }
                if let mo = months[at(k)], let d = ordinal(at(k + 1)) ?? Int(at(k + 1)), (1...31).contains(d) {
                    var e = k + 2
                    var y: Int? = nil
                    if let yy = Int(at(e)), yy >= 2000, yy < 2100 { y = yy; e += 1 }
                    a.abs = (d, mo, y); take(i, e); continue
                }
                if at(i) != "um", let r = at(k).range(of: "^(\\d{1,2})\\.(\\d{1,2})\\.(\\d{2,4})?$", options: .regularExpression), r.lowerBound == at(k).startIndex {
                    let p = at(k).split(separator: ".").compactMap { Int($0) }
                    if p.count >= 2, (1...31).contains(p[0]), (1...12).contains(p[1]) {
                        var y: Int? = p.count > 2 ? p[2] : nil
                        if let yy = y, yy < 100 { y = 2000 + yy }
                        a.abs = (p[0], p[1], y); take(i, k + 1); continue
                    }
                }
            }
            // --- Dauer / Ende (nur Termine): „für eine Stunde“, „2 Stunden lang“, „bis 15 Uhr“, „for 45 minutes“, „until 3“
            if allowDuration {
                if ["fur", "for"].contains(s) {
                    var k = i + 1
                    if at(k) == "half", ["an", "a"].contains(at(k + 1)), at(k + 2) == "hour" { a.durationMin = 30; take(i, k + 3); continue }
                    if at(k) == "eine", at(k + 1) == "halbe", at(k + 2) == "stunde" { a.durationMin = 30; take(i, k + 3); continue }
                    if ["anderthalb", "eineinhalb"].contains(at(k)) { a.durationMin = 90; take(i, k + 2); continue }
                    if let n = number(at(k)) {
                        k += 1
                        if ["minute", "minuten", "min", "minutes", "mins"].contains(at(k)) { a.durationMin = n; take(i, k + 1); continue }
                        if ["stunde", "stunden", "std", "hour", "hours"].contains(at(k)) { a.durationMin = n * 60; take(i, k + 1); continue }
                    }
                }
                if let n = number(s), ["stunden", "stunde", "minuten"].contains(at(i + 1)), at(i + 2) == "lang" {
                    a.durationMin = at(i + 1).hasPrefix("stunde") ? n * 60 : n; take(i, i + 3); continue
                }
                if ["bis", "until", "till", "til"].contains(s), a.hour != nil, let t = time(at: i + 1, w) {
                    a.endHour = t.h; a.endMinute = t.m; take(i, t.next); continue
                }
            }
            // --- Uhrzeit: „um 9“, „um 9:30“, „14 Uhr (30)“, „um halb 10“, „viertel nach 9“, „at 5pm“, „noon“
            do {
                var k = i
                let hasPrefix = ["um", "at", "gegen", "ab", "by", "von", "from"].contains(at(k))
                if hasPrefix { k += 1 }
                // „9 bis 11 Uhr“ ohne „um“: die erste Zahl zählt, weil eine Uhrzeit folgt
                let rangeAhead = !hasPrefix && number(at(k)) != nil && at(k + 1) == "bis" && time(at: k + 2, w, bare: false) != nil
                if let t = time(at: k, w, bare: hasPrefix || rangeAhead) {
                    if a.hour == nil {
                        a.hour = t.h; a.minute = t.m
                        if let ap = t.pm { a.explicitAMPM = ap }
                        take(i, t.next)
                        // „von 14 bis 15 Uhr“
                        if allowDuration, ["bis", "until", "to", "till"].contains(at(i)), let e = time(at: i + 1, w, bare: true) {
                            a.endHour = e.h; a.endMinute = e.m; take(i, e.next)
                        }
                        continue
                    }
                }
            }
            // --- Tageszeit („früh“, „abends“, „am Nachmittag“, „in the morning“) – nur direkt an einer Zeitangabe
            do {
                var k = i
                if ["am", "in"].contains(at(k)) && ["abend", "nachmittag", "vormittag", "morgen", "mittag"].contains(at(k + 1)) { k += 1 }
                if at(k) == "in", at(k + 1) == "der", ["fruh", "nacht"].contains(at(k + 2)) { k += 2 }
                if at(k) == "in", at(k + 1) == "the", ["morning", "afternoon", "evening"].contains(at(k + 2)) { k += 2 }
                let p: Period?
                switch at(k) {
                case "fruh", "morgens", "vormittags", "vormittag", "morning": p = .morning
                case "mittags", "mittag", "noon": p = .noon
                case "nachmittags", "nachmittag", "afternoon": p = .afternoon
                case "abends", "abend", "evening": p = .evening
                case "nachts", "nacht", "night": p = .night
                case "mitternacht": a.hour = 0; a.minute = 0; take(i, k + 1); continue
                default: p = nil
                }
                if let p {
                    // nur direkt hinter einer Zeitangabe („morgen früh“, „9 Uhr abends“) – „7pm worship night“ bleibt Titel
                    let near = lastDateEnd == i || k > i
                    if near || ["noon", "mittags"].contains(at(k)) && ["at", "um"].contains(at(i - 1)) {
                        if at(k) == "noon" && a.hour == nil { a.hour = 12 }
                        a.period = p; take(i, k + 1); continue
                    }
                }
            }
            i += 1
        }

        return resolve(a, used: used, now: now, cal: cal)
    }

    /// Uhrzeit ab Wort k. bare = eine nackte Zahl („um 9“) zählt, weil „um/at“ davor stand.
    private static func time(at k: Int, _ w: [String], bare: Bool = true) -> (h: Int, m: Int, pm: Bool?, next: Int)? {
        func at(_ j: Int) -> String { j >= 0 && j < w.count ? w[j] : "" }
        var s = at(k)
        guard !s.isEmpty else { return nil }
        // „halb 10“ = 9:30 · „viertel nach 9“ · „viertel vor 10“ · „dreiviertel 10“
        if s == "halb", let h = number(at(k + 1)), (1...24).contains(h) { return ((h + 23) % 24, 30, nil, skipUhr(k + 2, w)) }
        if s == "viertel", at(k + 1) == "nach", let h = number(at(k + 2)), (0...24).contains(h) { return (h % 24, 15, nil, skipUhr(k + 3, w)) }
        if s == "viertel", at(k + 1) == "vor", let h = number(at(k + 2)), (1...24).contains(h) { return ((h + 23) % 24, 45, nil, skipUhr(k + 3, w)) }
        if s == "dreiviertel", let h = number(at(k + 1)), (1...24).contains(h) { return ((h + 23) % 24, 45, nil, skipUhr(k + 2, w)) }
        if ["noon", "mittag"].contains(s), bare { return (12, 0, nil, k + 1) }
        if s == "midnight" { return (0, 0, nil, k + 1) }
        while s.hasSuffix(".") { s.removeLast() }
        // „5pm“, „5:30pm“, „17h“
        var pm: Bool? = nil
        if let r = s.range(of: "(a\\.?m\\.?|p\\.?m\\.?)$", options: .regularExpression), r.lowerBound != s.startIndex {
            pm = s[r].hasPrefix("p"); s = String(s[..<r.lowerBound])
        } else if s.hasSuffix("h"), Int(s.dropLast()) != nil { s.removeLast() }
        // „9:30“ / „9.30“
        if let r = s.range(of: "^(\\d{1,2})[:.](\\d{2})$", options: .regularExpression), r.lowerBound == s.startIndex {
            let p = s.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
            guard p.count == 2, p[0] < 25, p[1] < 60 else { return nil }
            var next = k + 1
            if pm == nil, let ap = ampm(at(next)) { pm = ap; next += 1 }
            if at(next) == "uhr" { next += 1 }
            return (p[0] % 24, p[1], pm, next)
        }
        guard let h = number(s), (0...24).contains(h), !["a", "an", "ein", "eine", "einen", "einer", "einem", "ner"].contains(s) else { return nil }
        var next = k + 1
        if pm == nil, let ap = ampm(at(next)) { pm = ap; next += 1 }
        if at(next) == "uhr" {
            next += 1
            // „14 Uhr 30“ – aber nicht „15 Uhr an …“ (an = eins im Englischen)
            if let m = number(at(next)), (0...59).contains(m), !["am", "an", "a", "ein", "eine", "einen", "einer", "einem", "ner"].contains(at(next)) {
                return (h % 24, m, pm, next + 1)
            }
            return (h % 24, 0, pm, next)
        }
        if ["o'clock", "oclock"].contains(at(next)) { return (h % 24, 0, pm, next + 1) }
        if pm != nil { return (h % 24, 0, pm, next) }
        return bare ? (h % 24, 0, nil, next) : nil
    }

    private static func ampm(_ s: String) -> Bool? {
        switch s { case "am", "a.m", "a.m.": return false; case "pm", "p.m", "p.m.": return true; default: return nil }
    }
    private static func skipUhr(_ k: Int, _ w: [String]) -> Int { k < w.count && w[k] == "uhr" ? k + 1 : k }

    // MARK: Zusammensetzen

    private static func resolve(_ a: Acc, used: Set<Int>, now: Date, cal: Calendar) -> VCWhen {
        var out = VCWhen(used: used)
        out.durationMin = a.durationMin
        if let rel = a.relSeconds, !a.hasDay, a.hour == nil {
            out.date = now.addingTimeInterval(rel)
            return out
        }
        guard a.hasDay || a.hour != nil || a.period != nil else { return out }
        let today = cal.startOfDay(for: now)
        var day = today
        if let abs = a.abs {
            let y = abs.y ?? cal.component(.year, from: now)
            var dc = DateComponents(); dc.year = y; dc.month = abs.m; dc.day = abs.d
            if let d = cal.date(from: dc) {
                day = d
                if abs.y == nil, d < today, let n = cal.date(byAdding: .year, value: 1, to: d) { day = n }
            }
        } else if let off = a.dayOffset {
            day = cal.date(byAdding: .day, value: off, to: today) ?? today
        }
        // Uhrzeit
        var hour = a.hour, minute = a.minute
        if var h = hour {
            if let pm = a.explicitAMPM { if pm && h < 12 { h += 12 } else if !pm && h == 12 { h = 0 } }
            else if let p = a.period {
                switch p {
                case .afternoon, .evening: if h < 12 { h += 12 }
                case .night: if h < 12 && h >= 5 { h += 12 }
                case .morning, .noon: break
                }
            } else if (1...6).contains(h) { h += 12 }
            hour = h
        } else if let p = a.period {
            switch p { case .morning: hour = 9; case .noon: hour = 12; case .afternoon: hour = 15; case .evening: hour = 19; case .night: hour = 21 }
            minute = 0
        }
        if let wd = a.weekday {
            let cur = cal.component(.weekday, from: today)
            var diff = (wd - cur + 7) % 7
            if diff == 0 {
                var later = false
                if let h = hour, let t = cal.date(bySettingHour: h, minute: minute, second: 0, of: today), t > now { later = true }
                if a.weekdayForceNext || !later { diff = 7 }
            }
            day = cal.date(byAdding: .day, value: diff, to: day) ?? day
        }
        guard let h = hour, !a.forceAllDay else {
            out.date = day; out.allDay = true
            return out
        }
        var start = cal.date(bySettingHour: h, minute: minute, second: 0, of: day) ?? day
        if !a.hasDay, start <= now { start = cal.date(byAdding: .day, value: 1, to: start) ?? start }
        out.date = start
        if var eh = a.endHour {
            if a.explicitAMPM == nil, a.period == nil, eh < h, eh + 12 > h, eh < 12 { eh += 12 }
            if let e = cal.date(bySettingHour: eh % 24, minute: a.endMinute, second: 0, of: start), e > start { out.end = e }
        }
        return out
    }

    // MARK: Anzeige

    /// „Heute 14:00“, „Morgen 09:00“, „Fr 14:00“, „Fr 3.10. 14:00“, „Fr 3.10. (ganztägig)“
    static func label(_ d: Date, allDay: Bool, end: Date? = nil, now: Date = Date(), cal: Calendar = .current, english: Bool = false) -> String {
        let loc = Locale(identifier: english ? "en_US" : "de_DE")
        let today = cal.startOfDay(for: now)
        let day = cal.startOfDay(for: d)
        let diff = cal.dateComponents([.day], from: today, to: day).day ?? 0
        let f = DateFormatter(); f.locale = loc; f.timeZone = cal.timeZone
        var dayText: String
        switch diff {
        case 0: dayText = english ? "Today" : "Heute"
        case 1: dayText = english ? "Tomorrow" : "Morgen"
        case 2...6:
            f.setLocalizedDateFormatFromTemplate("EEE"); dayText = f.string(from: d).replacingOccurrences(of: ".", with: "")
        default:
            f.setLocalizedDateFormatFromTemplate("EEE"); let wd = f.string(from: d).replacingOccurrences(of: ".", with: "")
            let c = cal.dateComponents([.day, .month, .year], from: d)
            dayText = english ? "\(wd) \(c.month!)/\(c.day!)" : "\(wd) \(c.day!).\(c.month!)."
            if c.year != cal.component(.year, from: now) { dayText += english ? "/\(c.year!)" : "\(c.year!)" }
        }
        if allDay { return dayText + (english ? " (all day)" : " (ganztägig)") }
        let tf = DateFormatter(); tf.locale = Locale(identifier: "de_DE"); tf.timeZone = cal.timeZone; tf.dateFormat = "HH:mm"
        var s = "\(dayText) \(tf.string(from: d))"
        if let end { s += "–" + tf.string(from: end) }
        return s
    }
}

// MARK: - NSDataDetector als Rückfall (englische/absolute Formen, die der eigene Parser nicht kennt)

enum VCDataDetector {
    /// Findet ein Datum im Text und gibt die Wort-Indizes zurück, die dazu gehören.
    static func find(_ toks: [VCToken], in text: String) -> VCWhen? {
        guard let first = toks.first, let last = toks.last,
              let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let sub = String(text[first.range.lowerBound..<last.range.upperBound])
        let ns = NSRange(sub.startIndex..., in: sub)
        guard let m = det.firstMatch(in: sub, range: ns), let d = m.date, let r = Range(m.range, in: sub) else { return nil }
        let offset = text.distance(from: text.startIndex, to: first.range.lowerBound)
        let lo = text.index(text.startIndex, offsetBy: offset + sub.distance(from: sub.startIndex, to: r.lowerBound))
        let hi = text.index(text.startIndex, offsetBy: offset + sub.distance(from: sub.startIndex, to: r.upperBound))
        var used = Set<Int>()
        for (k, t) in toks.enumerated() where t.range.overlaps(lo..<hi) { used.insert(k) }
        let matched = String(sub[r]).lowercased()
        let timed = matched.range(of: "\\d[:.]\\d\\d|\\d\\s*(am|pm|a\\.m|p\\.m|uhr|h\\b)|o'clock|noon|midnight", options: .regularExpression) != nil
        var w = VCWhen(date: d, allDay: !timed, used: used)
        if m.duration > 0 { w.end = d.addingTimeInterval(m.duration) }
        if !timed { w.date = Calendar.current.startOfDay(for: d) }
        return w
    }
}
