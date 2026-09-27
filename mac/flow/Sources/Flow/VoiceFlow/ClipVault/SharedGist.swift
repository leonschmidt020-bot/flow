import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Worum geht's? Kurzfassung für Geteiltes vom Partner
//
// Lange geteilte Texte (Agent-Aufträge, Fehlerberichte …) waren in Karte und Liste unlesbar: die erste Zeile
// war meist „Hey Lena,“ oder eine Markdown-Überschrift. Jetzt: Art + Kernaussage in einer Zeile, z. B.
//   „Auftrag für deinen Agent · Flow updaten“ · „Fehlerbericht · Flow 1.7.1“ · „Link · example.com“
//   „Notiz · Einkaufsliste (5 Punkte)“ · „Bild · Screenshot VS Code“ · „Datei · Video 30 MB“
// Rein lokal, ohne Netz, ein paar hundert Mikrosekunden (Regeln unten). Ist Apple Intelligence an, darf sie die
// Kernaussage im Hintergrund schöner formulieren (`SharedGistAI`) – die Regeln müssen aber allein gut sein.
// NIE die Claude-CLI dafür (zu langsam, kostet).

struct SharedGist: Equatable {
    enum Kind: String, CaseIterable { case task, report, log, link, list, todo, code, question, message, image, file }
    var kind: Kind
    /// Art, z. B. „Auftrag für deinen Agent“
    var label: String
    /// Kernaussage, z. B. „Flow updaten“ (kann leer sein)
    var gist: String

    /// „Art · Kernaussage“ in einer Zeile
    var line: String { gist.isEmpty ? label : "\(label) · \(gist)" }

    var symbol: String {
        switch kind {
        case .task: return "sparkles"
        case .report: return "stethoscope"
        case .log: return "terminal"
        case .link: return "link"
        case .list: return "list.bullet"
        case .todo: return "checklist"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .question: return "questionmark.bubble"
        case .message: return "text.bubble"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// Akzentfarbe je Art (auf dunklem Grund gut lesbar)
    var tint: Color {
        switch kind {
        case .task: return Color(red: 0.72, green: 0.60, blue: 1.0)       // lila (KI)
        case .report: return Color(red: 1.0, green: 0.55, blue: 0.45)     // koralle
        case .log: return Color(red: 0.62, green: 0.70, blue: 0.80)       // grau-blau
        case .link: return Color(red: 0.45, green: 0.72, blue: 1.0)       // blau
        case .list, .todo: return Color(red: 1.0, green: 0.80, blue: 0.40) // butter
        case .code: return Color(red: 0.55, green: 0.85, blue: 0.80)      // mint
        case .question: return Color(red: 1.0, green: 0.70, blue: 0.35)   // orange
        case .message: return Color(red: 0.36, green: 0.84, blue: 0.50)   // grün (wie der Rahmen)
        case .image: return Color(red: 0.95, green: 0.62, blue: 0.85)     // rosa
        case .file: return Color(red: 0.70, green: 0.78, blue: 0.90)      // stahlblau
        }
    }
}

enum SharedGistMaker {
    static let maxGist = 52

    // MARK: Einstieg

    /// me/partner: Vornamen (für „Auftrag für deinen Agent“ vs. „… für Nicos Agent“)
    static func make(_ item: SharedVaultItem, me: String = Identity.myName, partner: String = Identity.partner(.nominative, capitalized: true)) -> SharedGist {
        switch item.kind {
        case .image: return image(item)
        case .file: return file(name: item.fileName, size: item.size)
        case .link, .text:
            let fromMe = Identity.isMe(item.createdBy)
            return forText(item.text ?? "", sender: fromMe ? me : item.createdBy, viewer: me, other: fromMe ? partner : item.createdBy)
        }
    }

    // MARK: Text

    /// sender = wer es geschickt hat, viewer = wer es liest (ich), other = der jeweils andere
    static func forText(_ raw: String, sender: String = "Nico", viewer: String = "Lena", other: String = "Nico") -> SharedGist {
        // Nur den Anfang untersuchen – Fehlerberichte haben 13 000 Zeichen, die Art steht immer vorne
        let t = String(raw.prefix(6000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return SharedGist(kind: .message, label: "Nachricht", gist: "") }
        let lines = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmpty = lines.filter { !$0.isEmpty }

        // 1) Flow-Fehlerbericht (Diagnose.report): „# Flow-Fehlerbericht“ in der ersten Zeile
        if let first = nonEmpty.first, first.hasPrefix("#"), first.localizedCaseInsensitiveContains("fehlerbericht") {
            return report(nonEmpty)
        }
        // 2) Nur ein Link
        if !t.contains(where: { $0.isWhitespace }), let u = URL(string: t), let host = u.host, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            return SharedGist(kind: .link, label: "Link", gist: linkGist(u, host: host))
        }
        let bullets = nonEmpty.filter { isBullet($0) }
        let checks = nonEmpty.filter { isCheckbox($0) }
        let fenced = t.contains("```")
        let low = t.lowercased()

        // 2b) Protokoll / kopierte Agent-Ausgabe (Zeitstempel-Zeilen, Claude-Code-Zeichen ⏺ ⎿)
        let stamped = nonEmpty.prefix(60).filter { ($0.first.map { $0.isNumber || $0 == "[" || $0 == "=" } ?? false) && match($0, #"^(\[?\d{1,2}[:.]\d{2}|={3,}|\d{4}-\d{2}-\d{2}[ T]\d{2}:)"#) || $0.contains(" CEST ") }.count
        if t.contains("⏺") || t.contains("⎿") {
            let first = nonEmpty.map { clean($0.replacingOccurrences(of: "⏺", with: "").replacingOccurrences(of: "⎿", with: "")) }.first { $0.count >= 6 } ?? ""
            return SharedGist(kind: .log, label: "Agent-Ausgabe", gist: clip(first, maxGist))
        }
        if nonEmpty.count >= 3, Double(stamped) >= Double(min(nonEmpty.count, 60)) * 0.3 {
            let first = nonEmpty.map { clean($0.gsub(#"^[=\s]+|[=\s]+$"#, "")) }
                .first { $0.count >= 6 && !match($0, #"^\w{3} \w{3} \d{1,2} \d{2}:\d{2}"#) } ?? ""
            let n = nonEmpty.count
            return SharedGist(kind: .log, label: "Protokoll", gist: [first.isEmpty ? nil : clip(first, 36), "\(n) Zeilen"].compactMap { $0 }.joined(separator: " · "))
        }

        // 3) Auftrag / Prompt für einen Agenten
        var score = 0
        if match(low, #"\b(auftrag|prompt|aufgabe für|task)\b"#) { score += 3 }
        let forAgent = match(low, #"f(ü|ue)r (deinen|deine|meinen|meine|den|die|euren|unseren) (agent|agenten|claude|codex|ki)"#)
        if forAgent { score += 3 }
        let mentionsAgent = match(low, #"\b(claude|codex|agent|agenten|gpt|cursor|copilot|ki-agent)\b"#)
        if mentionsAgent { score += 2 }
        if fenced { score += 2 }
        if bullets.count >= 3 { score += 2 }
        if nonEmpty.filter({ $0.hasPrefix("#") }).count >= 2 { score += 1 }
        if t.count > 800 { score += 1 }
        let imperative = nonEmpty.prefix(40).filter { startsImperative($0) }.count
        if imperative >= 3 { score += 2 }
        // „Prompt: …“ / „Auftrag: …“ ganz vorne ist ein starkes Zeichen, auch bei kurzen Texten
        let startsAsTask = match(String(low.prefix(40)), #"^\W*(prompt|auftrag|aufgabe)\b[^\n]{0,30}[:–-]"#)
        if startsAsTask { score += 2 }
        if score >= 5 || (forAgent && score >= 3) {
            if startsAsTask && !mentionsAgent && !forAgent && low.hasPrefix("prompt") {
                return SharedGist(kind: .task, label: "Prompt", gist: taskGist(t, nonEmpty))
            }
            return SharedGist(kind: .task, label: taskLabel(low, agent: mentionsAgent || forAgent, sender: sender, viewer: viewer, other: other),
                              gist: taskGist(t, nonEmpty))
        }

        // 4) Code (ohne Auftrags-Merkmale)
        if fenced || isMostlyCode(nonEmpty) {
            let lang = codeLanguage(t, nonEmpty)
            let n = nonEmpty.filter { !$0.hasPrefix("```") }.count
            return SharedGist(kind: .code, label: "Code", gist: [lang, "\(n) Zeile\(n == 1 ? "" : "n")"].compactMap { $0 }.joined(separator: " · "))
        }

        // 5) Liste / To-dos
        let body = nonEmpty.count > 1 && !isBullet(nonEmpty[0]) ? Array(nonEmpty.dropFirst()) : nonEmpty
        if bullets.count >= 2, Double(bullets.count) >= Double(body.count) * 0.6 {
            let items = bullets.map { stripBullet($0) }
            let n = items.count
            var title = !isBullet(nonEmpty[0]) ? clean(nonEmpty[0]).trimmingCharacters(in: CharacterSet(charactersIn: ":")) : ""
            if title.count > 34 { title = clip(title, 34) }
            let isTodo = checks.count >= 2
            let count = "(\(n) \(isTodo ? "Aufgaben" : "Punkte"))"
            let gist = title.isEmpty ? "\(clip(items.prefix(3).joined(separator: ", "), 38)) \(count)" : "\(title) \(count)"
            return SharedGist(kind: isTodo ? .todo : .list, label: isTodo ? "To-dos" : "Notiz", gist: gist)
        }

        // 6) Frage
        let sentence = firstSentence(t)
        if nonEmpty.count <= 4, t.count < 400, sentence.hasSuffix("?") || (t.hasSuffix("?") && t.count < 160) {
            let q = sentence.hasSuffix("?") ? sentence : clean(t)
            return SharedGist(kind: .question, label: "Frage", gist: clip(q, maxGist))
        }

        // 7) Nachricht (ggf. mit Link darin)
        var gist = clip(capitalized(sentence.trimmingCharacters(in: CharacterSet(charactersIn: " ."))), maxGist)
        if let v = versions(t).first, !gist.contains(v), gist.count + v.count < maxGist + 6, match(low, #"flow|clipvault|version|update"#) { gist += " · \(v)" }
        return SharedGist(kind: .message, label: "Nachricht", gist: gist)
    }

    // MARK: Fehlerbericht

    private static func report(_ lines: [String]) -> SharedGist {
        var ver = ""
        if let v = lines.first(where: { $0.hasPrefix("Version:") }) { ver = versions(v).first ?? "" }
        var gist = ver.isEmpty ? "Flow" : "Flow \(ver)"
        // Fehlende Freigaben sind meist die Ursache → gleich mit anzeigen
        let missing = lines.prefix(30).compactMap { l -> String? in
            guard l.hasSuffix(": NEIN") else { return nil }
            return String(l.dropLast(6))
        }
        if let m = missing.first {
            let short = m.gsub(#"fn auf .*"#, "fn-Taste")
            gist += " · ohne \(short)"
        }
        return SharedGist(kind: .report, label: "Fehlerbericht", gist: gist)
    }

    // MARK: Auftrag

    private static let genericHeading = #"^(auftrag|prompt|aufgabe|task|kontext|context|hintergrund|ziel|goal|bitte|todo|to-do|hinweis|info|anleitung|für deinen agent|für claude)\b[^\p{L}]*$"#

    private static func taskGist(_ t: String, _ lines: [String]) -> String {
        var cand: String?
        // a) „Ziel:/Aufgabe:/Thema:“-Zeile
        for l in lines.prefix(30) {
            if let r = l.grange(#"^(\*\*)?(ziel|aufgabe|thema|goal|task|auftrag)(\*\*)?\s*[:–-]\s*(\*\*)?"#, ci: true) {
                let v = clean(String(l[r.upperBound...]))
                if v.count >= 6 { cand = v; break }
            }
        }
        // b) erste aussagekräftige Überschrift
        if cand == nil {
            for l in lines.prefix(40) where l.hasPrefix("#") {
                var h = clean(l)
                h = stripTaskPrefix(h)
                if h.count >= 6, h.grange(genericHeading, ci: true) == nil { cand = h; break }
            }
        }
        // c) erster Satz des ersten Absatzes (ohne Anrede, ohne „Auftrag für deinen Agent:“)
        if cand == nil {
            let paras = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("#") }
            outer: for p in paras.prefix(8) {
                // Absatz in Sätze zerlegen; Rollen-Sätze („Du bist ein Senior-Entwickler“) und Adressen überspringen
                var rest = stripTaskPrefix(clean(p))
                for _ in 0..<4 {
                    let s = stripTaskPrefix(firstSentence(rest))
                    if s.count >= 8, !match(s, #"^(du bist|you are|act as|stell dir vor|kontext|hintergrund)\b"#) { cand = s; break outer }
                    guard let r = rest.range(of: firstSentence(rest)) else { break }
                    rest = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty { break }
                }
            }
        }
        var g = softenImperative(cand ?? "")
        if let v = versions(t).first, !g.contains(v), g.count < maxGist - 6 { g += " \(v)" }
        return clip(g, maxGist)
    }

    /// „Auftrag für deinen Agent: …“, „Prompt:“, „Hey Lena,“ vorne weg
    private static func stripTaskPrefix(_ s: String) -> String {
        var s = stripSalutation(s)
        let pats = [
                    // Adresse: „Von Nico für Lenas Claude-Code-Agent:“, „Für Nicos Claude-Code-Agent (von Lena):“
                    #"^(von\s+\p{L}+\s*[:,]?\s*)?(f(ü|ue)r\s+(\p{L}+s|deinen|deine|meinen|meine|den|die)\s+(claude[- ]code[- ]agent(en)?|claude[- ]code|claude|agent(en)?|codex|ki)(\s*\([^)]*\))?)?\s*[:–—-]?\s*"#,
                    #"^von\s+\p{L}+\s*:\s*"#,
#"^(hier\s+(ist|kommt)\s+)?(ein|der|dein|mein)?\s*(neuer\s+)?(auftrag|prompt|aufgabe|task)(\s+f(ü|ue)r\s+(deinen|deine|meinen|den|die|euren)\s+(agent|agenten|claude|codex|ki))?\s*[:–—-]*\s*"#,
                    #"^f(ü|ue)r\s+(deinen|deine|meinen|den|die)\s+(agent|agenten|claude|codex|ki)\s*[:–—-]*\s*"#,
                    #"^(kannst du|könntest du|bitte|du sollst|ich möchte,? dass du|ich will,? dass du|wir wollen)\s+"#]
        // Adresse auch mitten im Satz: „Auftrag: Von Nico für Lenas Claude-Code-Agent: Flow …“
        s = s.gsub(#"\s*[–—:-]?\s*\bvon\s+\p{L}+\s+f(ü|ue)r\s+(\p{L}+s|deinen|deine|meinen|meine)\s+(claude[- ]code[- ]agent(en)?|claude[- ]code|claude|agent(en)?|codex|ki)(\s*\([^)]*\))?\s*[:–—-]?"#,
                                   ":", ci: true)
        // Vorsätze wiederholt abziehen, bis nichts mehr passt („Auftrag: Für deinen Agent: …“)
        for _ in 0..<3 {
            let before = s
            for p in pats { s = s.gsub(p, "", ci: true) }
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " :–—-"))
            if s == before { break }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Für wessen Agent? „für Lenas Claude-Code-Agent“ / „für deinen Agent“ / „an meinen Claude“ – aus Sicht des Lesers
    private static func taskLabel(_ low: String, agent: Bool, sender: String, viewer: String, other: String) -> String {
        guard agent else { return "Auftrag" }
        let who = #"(f(ü|ue)r|an)\s+(deinen|deine|dein|dich|meinen|meine|mein|(\p{L}+)s)\s+(claude|agent|agenten|codex|ki)"#
        guard let re = gistRegex(who, ci: true),
              let m = re.firstMatch(in: low, range: NSRange(low.startIndex..., in: low)),
              let r = Range(m.range(at: 3), in: low) else { return sender.lowercased() == viewer.lowercased() ? "Agent-Auftrag" : "Auftrag für deinen Agent" }
        let w = String(low[r])
        let target: String
        if ["deinen", "deine", "dein", "dich"].contains(w) { target = sender.lowercased() == viewer.lowercased() ? other : viewer }
        else if ["meinen", "meine", "mein"].contains(w) { target = sender }
        else { target = String(w.dropLast()) }
        if target.lowercased() == viewer.lowercased() { return "Auftrag für deinen Agent" }
        return "Auftrag für \(target.prefix(1).uppercased() + target.dropFirst())s Agent"
    }

    static func capitalized(_ s: String) -> String {
        guard let f = s.first, f.isLowercase else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// „kannst du Flow updaten?“ → „Flow updaten“ (Satzzeichen am Ende weg, erster Buchstabe groß)
    private static func softenImperative(_ s: String) -> String {
        var s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!?:;,"))
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }

    // MARK: Link

    private static func linkGist(_ u: URL, host: String) -> String {
        let h = host.lowercased().gsub(#"^(www\d?|m)\."#, "")
        let parts = u.path.split(separator: "/").map(String.init)
        switch h {
        case "youtube.com", "youtu.be": return "YouTube-Video"
        case "github.com": return parts.count >= 2 ? "GitHub · \(parts[0])/\(parts[1])" : "GitHub"
        case "maps.apple.com", "maps.google.com": return "Karte"
        case "instagram.com": return "Instagram"
        case "docs.google.com": return "Google Docs"
        default: return h
        }
    }

    // MARK: Bild

    private static let apps: [(String, String)] = [
        ("visual studio code", "VS Code"), ("vs code", "VS Code"), ("vscode", "VS Code"), ("xcode", "Xcode"),
        ("terminal", "Terminal"), ("iterm", "Terminal"), ("zsh", "Terminal"), ("claude code", "Claude Code"), ("claude", "Claude"),
        ("chatgpt", "ChatGPT"), ("codex", "Codex"), ("whatsapp", "WhatsApp"), ("imessage", "Nachrichten"), ("slack", "Slack"),
        ("discord", "Discord"), ("figma", "Figma"), ("notion", "Notion"), ("obsidian", "Obsidian"), ("safari", "Safari"),
        ("chrome", "Chrome"), ("github", "GitHub"), ("youtube", "YouTube"), ("instagram", "Instagram"), ("finder", "Finder"),
        ("mail", "Mail"), ("kalender", "Kalender"), ("calendar", "Kalender"), ("clipvault", "ClipVault"),
        ("vercel", "Vercel"), ("supabase", "Supabase"), ("canva", "Canva"), ("suno", "Suno"), ("godot", "Godot"), ("blender", "Blender"),
        ("unreal", "Unreal"), ("zoom", "Zoom"), ("teams", "Teams"), ("excel", "Excel"), ("word", "Word"), ("keynote", "Keynote"),
    ]

    private static func image(_ item: SharedVaultItem) -> SharedGist {
        let ocr = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let px = item.image.flatMap { pixelSize($0) }
        let screenshotLike: Bool = {
            guard let (w, h) = px else { return !ocr.isEmpty }
            return item.image?.pathExtension.lowercased() == "png" && (ocr.count > 40 || w >= 600 || h >= 600)
        }()
        let what = screenshotLike ? "Screenshot" : "Foto"
        guard !ocr.isEmpty else {
            if let (w, h) = px { return SharedGist(kind: .image, label: "Bild", gist: "\(what) · \(w)×\(h)") }
            return SharedGist(kind: .image, label: "Bild", gist: item.image == nil ? "noch nicht geladen" : "")   // nichts erfinden
        }
        let low = ocr.lowercased()
        // Bekannte App im erkannten Text? Die zuerst genannte gewinnt (Fenstertitel/Menüleiste stehen oben)
        var best: (Int, String)?
        for (key, name) in apps {
            if let r = low.range(of: key) {
                let pos = low.distance(from: low.startIndex, to: r.lowerBound)
                if best == nil || pos < best!.0 { best = (pos, name) }
            }
        }
        if let app = best?.1 { return SharedGist(kind: .image, label: "Bild", gist: "\(what) \(app)") }
        // sonst: erste aussagekräftige Textzeile
        let line = ocr.components(separatedBy: .newlines).map { clean($0) }
            .first { $0.count >= 8 && $0.filter(\.isLetter).count >= 5 } ?? ""
        return SharedGist(kind: .image, label: "Bild", gist: line.isEmpty ? what : "\(what) · „\(clip(line, 36))“")
    }

    private static func pixelSize(_ u: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    // MARK: Datei

    static func file(name: String?, size: Int64?) -> SharedGist {
        let ext = ((name ?? "") as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let what: String = {
            guard let t = type else { return ext.isEmpty ? "Datei" : ext.uppercased() }
            if t.conforms(to: .movie) || t.conforms(to: .video) { return "Video" }
            if t.conforms(to: .audio) { return "Audio" }
            if t.conforms(to: .image) { return "Bild" }
            if t.conforms(to: .pdf) { return "PDF" }
            if t.conforms(to: .presentation) { return "Präsentation" }
            if t.conforms(to: .spreadsheet) { return "Tabelle" }
            if t.conforms(to: .archive) || ["zip", "rar", "7z", "gz", "tar"].contains(ext) { return "Archiv" }
            if t.conforms(to: .sourceCode) || t.conforms(to: .script) { return "Code" }
            if t.conforms(to: .text) || t.conforms(to: .rtf) || ["doc", "docx", "pages", "md"].contains(ext) { return "Dokument" }
            if t.conforms(to: .diskImage) { return "Installer" }
            if t.conforms(to: .applicationBundle) { return "App" }
            return ext.isEmpty ? "Datei" : ext.uppercased()
        }()
        let sz = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return SharedGist(kind: .file, label: "Datei", gist: [what, sz].compactMap { $0 }.joined(separator: " "))
    }

    // MARK: Bausteine

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()
    static func match(_ s: String, _ pattern: String) -> Bool {
        regexLock.lock()
        let re: NSRegularExpression? = regexCache[pattern] ?? {
            let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            regexCache[pattern] = r
            return r
        }()
        regexLock.unlock()
        guard let re else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func isBullet(_ l: String) -> Bool {
        l.grange(#"^([-*•–]|\d{1,2}[.)]|\[[ xX]\]|[-*] \[[ xX]\])\s+\S"#) != nil
    }
    static func isCheckbox(_ l: String) -> Bool {
        l.grange(#"^([-*] )?\[[ xX]\]\s"#) != nil
    }
    static func stripBullet(_ l: String) -> String {
        clean(l.gsub(#"^([-*•–]|\d{1,2}[.)])?\s*(\[[ xX]\])?\s*"#, ""))
    }

    /// Deutsche/englische Befehlsformen am Zeilenanfang („Baue …“, „Prüfe …“, „- Füge … hinzu“)
    private static let verbs: Set<String> = ["baue", "bau", "prüfe", "prüf", "füge", "fuege", "erstelle", "mach", "mache", "schreibe", "schreib",
        "ändere", "aendere", "entferne", "lösche", "loesche", "teste", "starte", "installiere", "update", "aktualisiere", "lies", "lese",
        "nutze", "verwende", "achte", "zeige", "zeig", "sorge", "stelle", "implementiere", "ergänze", "ersetze", "verschiebe", "committe",
        "pushe", "öffne", "klicke", "suche", "recherchiere", "analysiere", "fixe", "behebe", "repariere", "halte", "rendere", "liefere",
        "add", "build", "create", "fix", "make", "write", "use", "check", "run", "update", "remove", "implement", "test", "ensure", "read"]
    private static func startsImperative(_ l: String) -> Bool {
        // ohne Regex (läuft für bis zu 40 Zeilen): erstes Wort aus Buchstaben nach Aufzählungszeichen/Nummer
        guard let w = l.lowercased().split(whereSeparator: { !$0.isLetter }).first else { return false }
        return verbs.contains(String(w))
    }

    private static func isMostlyCode(_ lines: [String]) -> Bool {
        guard lines.count >= 3 else { return false }
        let codeish = lines.filter { l in
            l.hasSuffix(";") || l.hasSuffix("{") || l == "}" || l.hasSuffix(")") && l.contains("(") && !l.contains(" ") ||
            l.grange(#"^(import|func|let|var|const|def|class|struct|enum|return|if \(|for \(|#include|public|private|<\w+|\}|\$ |npm |git |cd |sudo )"#) != nil
        }.count
        return Double(codeish) >= Double(lines.count) * 0.6
    }

    private static func codeLanguage(_ t: String, _ lines: [String]) -> String? {
        if let r = t.grange(#"```([A-Za-z+#]+)"#) {
            let tag = t[r].dropFirst(3).lowercased()
            let map = ["swift": "Swift", "py": "Python", "python": "Python", "js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript",
                       "typescript": "TypeScript", "bash": "Shell", "sh": "Shell", "zsh": "Shell", "json": "JSON", "html": "HTML", "css": "CSS",
                       "sql": "SQL", "lua": "Lua", "gdscript": "GDScript", "rust": "Rust", "go": "Go"]
            return map[String(tag)] ?? String(tag).uppercased()
        }
        let s = lines.prefix(20).joined(separator: "\n")
        if match(s, #"\b(func |let |var |guard |import (SwiftUI|AppKit|Foundation))"#) { return "Swift" }
        if match(s, #"\b(def |import \w+$|print\()"#) { return "Python" }
        if match(s, #"\b(const |function |=> |console\.)"#) { return "JavaScript" }
        if match(s, #"^(\$ |npm |git |cd |brew |sudo )"#) { return "Shell" }
        return nil
    }

    /// Versionsnummern wie 1.7.1 (keine Datumsangaben, keine IPs)
    static func versions(_ t: String) -> [String] {
        guard let re = gistRegex(#"(?<![\d.])v?(\d{1,2}\.\d{1,2}(?:\.\d{1,3})?)(?![\d.]*\d)"#, ci: false) else { return [] }
        let ns = t as NSString
        var out: [String] = []
        for m in re.matches(in: t, range: NSRange(location: 0, length: min(ns.length, 4000))) {
            let v = ns.substring(with: m.range(at: 1))
            let parts = v.split(separator: ".").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 12 || parts[1] > 31 { continue }   // eher „27.09“ oder Uhrzeit
            if parts.count == 2 && t.contains("\(v).20") { continue }            // Datum 27.09.2026
            if !out.contains(v) { out.append(v) }
        }
        return out.filter { $0.split(separator: ".").count == 3 } + out.filter { $0.split(separator: ".").count == 2 && !t.contains(":\($0)") }
    }

    /// Anrede vorne weg: „Hey Lena,“ „Hallo!“ „Moin Lena –“
    static func stripSalutation(_ s: String) -> String {
        s.gsub(#"^(hey|hi|hallo|moin|servus|yo|na|lieber|liebe|guten (morgen|tag|abend))\b[^,.!:\n–—-]{0,24}[,.!:–—-]+\s*"#,
                               "", ci: true)
    }

    /// Markdown und doppelte Leerzeichen raus
    static func clean(_ s: String) -> String {
        var s = s.gsub(#"^\s*(#{1,6}|>|[-*•–]|\d{1,2}[.)])\s+"#, "")
        s = s.gsub(#"\*\*|__|`|\[([^\]]*)\]\([^)]*\)"#, "$1")
        s = s.gsub(#"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Erster Satz (ohne Anrede), Zeilenumbrüche zählen als Satzende
    static func firstSentence(_ t: String) -> String {
        // nur die ersten Zeilen säubern (lange Texte: sonst wird jede Zeile dreimal durch Regex gejagt)
        var paras: [String] = []
        for raw in t.prefix(3000).split(separator: "\n", omittingEmptySubsequences: true).prefix(12) {
            let c = clean(String(raw))
            if !c.isEmpty && !c.hasPrefix("```") { paras.append(c) }
            if paras.count >= 4 { break }
        }
        for p in paras.prefix(4) {
            let s = stripSalutation(p)
            guard s.count >= 3 else { continue }
            // bis zum ersten Satzende, das nicht zu einer Zahl/Abkürzung gehört
            if let r = s.grange(#"^.{8,}?[.!?](?=\s|$)(?<!\b(z\.B|bzw|ca|usw|etc|d\.h|u\.a|Nr|vgl)\.)"#) {
                return String(s[r])
            }
            return s
        }
        return clean(paras.first ?? t)
    }

    /// Auf ~max Zeichen an einer Wortgrenze kürzen, mit „…“
    static func clip(_ s: String, _ max: Int) -> String {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard s.count > max else { return s }
        var cut = String(s.prefix(max))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > max / 2 { cut = String(cut[..<sp]) }
        cut = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–—-·("))
        for w in [" und", " oder", " mit", " für", " die", " der", " das", " den", " in", " im", " auf", " zu", " von", " the", " and", " to"] where cut.hasSuffix(w) {
            cut = String(cut.dropLast(w.count))
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–—-·(")) + "…"
    }
}

// MARK: - Regex mit Zwischenspeicher (String.replacingOccurrences(.regularExpression) übersetzt jedes Mal neu)

private var gistRegexCache: [String: NSRegularExpression] = [:]
private let gistRegexLock = NSLock()
private func gistRegex(_ p: String, ci: Bool) -> NSRegularExpression? {
    let key = (ci ? "i:" : "c:") + p
    gistRegexLock.lock(); defer { gistRegexLock.unlock() }
    if let r = gistRegexCache[key] { return r }
    let r = try? NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : [])
    gistRegexCache[key] = r
    return r
}
extension String {
    func gsub(_ p: String, _ t: String, ci: Bool = false) -> String {
        guard let re = gistRegex(p, ci: ci) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: t)
    }
    func grange(_ p: String, ci: Bool = false) -> Range<String.Index>? {
        guard let re = gistRegex(p, ci: ci), let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return Range(m.range, in: self)
    }
}

// MARK: - Zwischenspeicher + optional Apple Intelligence

final class SharedGistStore: ObservableObject {
    static let shared = SharedGistStore()
    /// Schönere Kernaussagen von Apple Intelligence (nur wenn verfügbar), je Eintrag
    @Published private(set) var refined: [String: String] = [:]
    private var cache: [String: SharedGist] = [:]
    private var asked: Set<String> = []

    func gist(for item: SharedVaultItem) -> SharedGist {
        var g = cache[item.id] ?? {
            let g = SharedGistMaker.make(item)
            cache[item.id] = g
            return g
        }()
        if let r = refined[item.id], !r.isEmpty { g.gist = r }
        return g
    }

    /// Im Hintergrund von Apple Intelligence formulieren lassen (nur lange Texte, nur wenn das Modell bereit ist)
    func refineIfPossible(_ item: SharedVaultItem) {
        guard !asked.contains(item.id), let text = item.text, text.count > 160, item.kind == .text || item.kind == .link else { return }
        asked.insert(item.id)
        let base = gist(for: item)
        guard base.kind == .task || base.kind == .message || base.kind == .report || base.kind == .list else { return }
        SharedGistAI.refine(text: text, rule: base) { [weak self] s in
            guard let s, !s.isEmpty else { return }
            DispatchQueue.main.async { self?.refined[item.id] = s }
        }
    }
}

enum SharedGistAI {
    static var available: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Höchstens ~7 Wörter, deutsch, ohne Anführungszeichen. `done` auf irgendeinem Thread; nil = nicht verfügbar/Fehler.
    static func refine(text: String, rule: SharedGist, done: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        guard available else { return done(nil) }
        Task.detached(priority: .utility) {
            do {
                let session = LanguageModelSession(instructions: """
                    Du bekommst eine Nachricht, die jemand geteilt hat (Art: \(rule.label)). \
                    Antworte NUR mit ihrer Kernaussage in höchstens 7 deutschen Wörtern, ohne Anführungszeichen, ohne Satzzeichen am Ende. \
                    Versionsnummern und Produktnamen behalten.
                    """)
                let r = try await session.respond(to: String(text.prefix(2500)))
                var s = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"„“”'.!"))
                done(s.count >= 3 && s.count <= 70 ? SharedGistMaker.clip(s, SharedGistMaker.maxGist) : nil)
            } catch { done(nil) }
        }
        #else
        done(nil)
        #endif
    }
}

// MARK: - Bausteine für die Oberfläche

/// Kleine farbige Art-Marke: Symbol + „Auftrag für deinen Agent“
struct SharedGistChip: View {
    let gist: SharedGist
    var size: CGFloat = 11
    /// Heller Hintergrund (Hub-Fenster): Farbe abdunkeln, sonst zu wenig Kontrast
    var onLight = false
    var body: some View {
        let ink = onLight ? Color(nsColor: NSColor(gist.tint).blended(withFraction: 0.45, of: .black) ?? NSColor(gist.tint)) : gist.tint
        HStack(spacing: 4) {
            Image(systemName: gist.symbol).font(.system(size: size - 1, weight: .semibold))
            Text(gist.label).font(.system(size: size, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7).frame(height: size + 9)
        .background(Capsule().fill(gist.tint.opacity(0.14)))
        .fixedSize()
    }
}
