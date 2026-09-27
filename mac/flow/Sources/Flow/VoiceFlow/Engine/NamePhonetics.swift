import Foundation

/// Laut-Codes für Namen, die Parakeet/Whisper in wechselnden Schreibweisen hören („Shark Wes“, „Chuck Res“, „Jar Quest“).
/// Zwei Codes: Kölner Phonetik (deutsch) und ein grober DE/EN/FR-Lautklassen-Code, bei dem ähnliche Laute
/// (sch/ch/j/sh, k/g/q, f/v/w …) nur halb zählen. Verglichen wird immer mit den GELERNTEN Varianten, nicht nur
/// mit der Schreibweise – bei „Pierre“ hilft die Schreibung wenig, eigene Aussprache schon.
enum NamePhonetics {
    /// Buchstaben ohne Akzente, klein, nur a–z
    static func letters(_ s: String) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de"))
            .replacingOccurrences(of: "ß", with: "ss")
        return String(f.unicodeScalars.filter { ("a"..."z").contains(Character($0)) }.map(Character.init))
    }

    /// Lautklassen-Code: Großbuchstaben = Konsonant-Klasse, „a“ = (beliebiger) Vokal-Kern.
    /// S = sch/sh/ch/j/sj/zh (Zischlaute), K = k/c/ck/q/qu/g/gh, T = t/d/th, P = p/b, F = f/v/w/ph, M = m/n,
    /// L = l, R = r, Z = z/tz/ts/c(e,i), X = x (→ KS), H = h am Wortanfang, Y = j vor Vokal im Deutschen wird ebenfalls S (Namen!).
    static func soundCode(_ word: String) -> String {
        let w = Array(letters(word))
        var out: [Character] = []
        func push(_ c: Character) {
            if c == "a" { if out.last != "a" { out.append("a") }; return }
            if out.last != c { out.append(c) }
        }
        var i = 0
        func at(_ k: Int) -> Character? { k >= 0 && k < w.count ? w[k] : nil }
        func isV(_ c: Character?) -> Bool { c.map { "aeiouy".contains($0) } ?? false }
        while i < w.count {
            let c = w[i], n = at(i + 1), n2 = at(i + 2)
            switch c {
            case "a", "e", "i", "o", "u", "y": push("a"); i += 1
            case "t" where n == "s" && n2 == "c" && at(i + 3) == "h": push("S"); i += 4
            case "s" where n == "c" && n2 == "h": push("S"); i += 3
            case "s" where n == "h": push("S"); i += 2
            case "c" where n == "h": push("S"); i += 2
            case "c" where n == "k": push("K"); i += 2
            case "c" where n == "e" || n == "i" || n == "y": push("Z"); i += 1
            case "c": push("K"); i += 1
            case "q": push("K"); i += (n == "u" ? 2 : 1)
            case "k", "g": push("K"); i += (n == "h" ? 2 : 1)
            case "j": push("S"); i += 1
            case "t" where n == "h": push("T"); i += 2
            case "t" where n == "z" || n == "s": push("Z"); i += 2
            case "t", "d": push("T"); i += 1
            case "p" where n == "h": push("F"); i += 2
            case "p", "b": push("P"); i += 1
            case "f", "v", "w": push("F"); i += 1
            case "m", "n": push("M"); i += 1
            case "l": push("L"); i += 1
            case "r": push("R"); i += 1
            case "z": push("Z"); i += 1
            case "s": push("Z"); i += 1
            case "x": push("K"); push("Z"); i += 1
            case "h": if out.isEmpty && isV(n) { push("H") }; i += 1
            default: i += 1
            }
        }
        return String(out)
    }

    /// Klassen, die sich nur „halb“ unterscheiden
    private static let near: [Set<Character>] = [["S", "Z"], ["K", "H"], ["F", "P"], ["T", "Z"], ["R", "L"]]

    private static func subCost(_ a: Character, _ b: Character) -> Double {
        if a == b { return 0 }
        if a == "a" || b == "a" { return 1 }
        return near.contains { $0.contains(a) && $0.contains(b) } ? 0.5 : 1
    }

    /// Gewichteter Abstand: Vokale einfügen/löschen kostet 0,5, ähnliche Konsonanten tauschen 0,5
    static func distance(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return Double(y.count) }
        if y.isEmpty { return Double(x.count) }
        func indel(_ c: Character) -> Double { c == "a" ? 0.5 : 1 }
        var prev = [Double](repeating: 0, count: y.count + 1)
        for j in 1...y.count { prev[j] = prev[j - 1] + indel(y[j - 1]) }
        var cur = prev
        for i in 1...x.count {
            cur[0] = prev[0] + indel(x[i - 1])
            for j in 1...y.count {
                cur[j] = min(prev[j] + indel(x[i - 1]), cur[j - 1] + indel(y[j - 1]), prev[j - 1] + subCost(x[i - 1], y[j - 1]))
            }
            prev = cur
        }
        return prev[y.count]
    }

    /// Ähnlichkeit 0…1 zweier Wortfolgen (Leerzeichen egal) – Maximum aus Lautklassen-Code und Kölner Phonetik
    static func similarity(_ a: String, _ b: String) -> Double {
        let la = letters(a), lb = letters(b)
        guard !la.isEmpty, !lb.isEmpty else { return 0 }
        if la == lb { return 1 }
        let ca = soundCode(la), cb = soundCode(lb)
        let s1 = 1 - distance(ca, cb) / Double(max(weight(ca), weight(cb), 1))
        let ka = VocabTrigger.colognePhonetic(la), kb = VocabTrigger.colognePhonetic(lb)
        let s2 = ka.count >= 2 && kb.count >= 2
            ? 1 - Double(VocabTrigger.levenshtein(Array(ka), Array(kb))) / Double(max(ka.count, kb.count))
            : 0
        return max(0, max(s1, s2 * 0.95))
    }

    private static func weight(_ code: String) -> Double { code.reduce(0) { $0 + ($1 == "a" ? 0.5 : 1) } }
}
