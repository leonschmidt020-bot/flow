import AppKit
import Combine
import SwiftUI

// MARK: - Stil je App-Art (Formell / Locker / Sehr locker / Aufgeregt)

enum StyleKind: String, Codable, CaseIterable, Identifiable {
    case formal, casual, veryCasual, excited
    var id: String { rawValue }
    /// Kartenüberschrift – schon im jeweiligen Stil geschrieben
    var title: String {
        switch self {
        case .formal: return "Formell."
        case .casual: return "Locker"
        case .veryCasual: return "sehr locker"
        case .excited: return "Aufgeregt!"
        }
    }
    var subtitle: String {
        switch self {
        case .formal: return "Groß + Satzzeichen"
        case .casual: return "Groß + weniger Satzzeichen"
        case .veryCasual: return "Klein + weniger Satzzeichen"
        case .excited: return "Mehr Ausrufezeichen!"
        }
    }
}

final class StyleStore: ObservableObject {
    static let shared = StyleStore()
    static let file = "stil.json"

    /// Stil je App-Art; KI-Prompts laufen unter „Sonstiges“.
    @Published var styles: [String: StyleKind] = StyleStore.defaults { didSet { if persist, styles != oldValue { PGFile.save(styles, Self.file) } } }
    private let persist: Bool

    static let defaults: [String: StyleKind] = [
        AppCategory.personal.rawValue: .casual,
        AppCategory.work.rawValue: .formal,
        AppCategory.email.rawValue: .formal,
        AppCategory.other.rawValue: .formal,
    ]

    private init() {
        persist = true
        if let s = PGFile.load(Self.file, as: [String: StyleKind].self) { styles = Self.defaults.merging(s) { _, new in new } }
    }

    init(testing: [String: StyleKind]) { persist = false; styles = Self.defaults.merging(testing) { _, new in new } }

    static func settingsKey(_ c: AppCategory) -> String { (c == .ai ? AppCategory.other : c).rawValue }

    func style(for c: AppCategory) -> StyleKind { styles[Self.settingsKey(c)] ?? .formal }
    func set(_ k: StyleKind, for c: AppCategory) { styles[Self.settingsKey(c)] = k }

    /// Diktat-Pipeline: Text im Stil der App-Art formatieren (nach TextCleaner, vor dem Einfügen).
    func apply(_ text: String, category: AppCategory) -> String {
        Self.transform(text, style(for: category))
    }

    // MARK: Regeln

    private static let greetings = ["hey", "hi", "hallo", "hello", "moin", "servus", "na", "ja", "nein", "nee", "okay", "ok", "yes", "yeah", "no", "danke", "thanks", "super", "cool", "gut"]
    private static let abbreviations: Set<String> = ["usw", "etc", "bzw", "ca", "z. b", "z.b", "d. h", "d.h", "u. a", "u.a", "nr", "dr", "prof", "vs", "inkl", "evtl", "ggf", "bspw", "mr", "mrs", "ms", "jr", "sr", "st", "str"]

    /// Listenzeilen („- Banane“, „• Milch“, „1. …“, „- [ ] …“) und Überschriften („Einkaufen:“) nie umstylen
    private static func isListLine(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("• ") || t.hasPrefix("* ") { return true }
        if t.range(of: #"^\d{1,2}\. "#, options: .regularExpression) != nil { return true }
        return t.hasSuffix(":") && t.count <= 60
    }

    static func transform(_ input: String, _ kind: StyleKind) -> String {
        if kind == .formal || input.pgTrimmed.isEmpty { return input }
        let lines = input.components(separatedBy: "\n")
        if lines.count > 1, lines.contains(where: isListLine) {
            var out: [String] = [], buf: [String] = []
            func flush() { if !buf.isEmpty { out.append(transform(buf.joined(separator: "\n"), kind)); buf = [] } }
            for l in lines { if isListLine(l) { flush(); out.append(l) } else { buf.append(l) } }
            flush()
            return out.joined(separator: "\n")
        }
        // Kurzes Code-Diktat nie anfassen (mehrere Zeilen mit Einrückung/Code-Zeichen)
        if looksLikeCode(input) { return input }
        var (s, saved) = protect(input)
        switch kind {
        case .formal: break
        case .casual:
            s = dropGreetingComma(s)
            s = dropFinalPeriods(s)
        case .veryCasual:
            s = dropGreetingComma(s)
            s = dropFinalPeriods(s)
            s = lowercaseSentenceStarts(s)
        case .excited:
            s = excite(s)
        }
        return restore(s, saved)
    }

    /// URLs, E-Mail-Adressen, Domains, Pfade, `Code` durch Platzhalter ersetzen.
    private static func protect(_ s: String) -> (String, [String]) {
        let patterns = [
            "```[\\s\\S]*?```",
            "`[^`\\n]+`",
            "(?i)\\b(?:https?://|www\\.)[^\\s]*[^\\s.,!?;:)\\]\"'“”]",
            "[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)*\\.[a-zA-Z]{2,}",
            "(?i)\\b[\\w-]+(?:\\.[\\w-]+)*\\.(?:com|de|ai|org|net|io|app|dev|co|eu|at|ch|me|gg|so|sh|md|swift|py|js|ts|json|txt|pdf)\\b(?:/[^\\s]*[^\\s.,!?;:)])?",
            "(?:~|\\.{1,2})?/[\\w.@-]+(?:/[\\w.@-]+)+",
        ]
        var saved: [String] = []
        var out = s
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                result += "\u{E000}\(saved.count)\u{E001}"
                saved.append(ns.substring(with: m.range))
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return (out, saved)
    }

    private static func restore(_ s: String, _ saved: [String]) -> String {
        var out = s
        for (i, v) in saved.enumerated().reversed() { out = out.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: v) }
        return out
    }

    private static func looksLikeCode(_ s: String) -> Bool {
        let codeHints = ["{", "}", "();", "=>", "->", "==", "!=", "func ", "def ", "let ", "const ", "import "]
        let hits = codeHints.filter { s.contains($0) }.count
        return hits >= 2
    }

    /// „Hey, hast du …“ → „Hey hast du …“ (am Anfang jeder Zeile)
    private static func dropGreetingComma(_ s: String) -> String {
        let alt = greetings.joined(separator: "|")
        return s.replacingOccurrences(of: "(?im)^(\\s*(?:\(alt)))\\s*,\\s+", with: "$1 ", options: .regularExpression)
    }

    /// Einzelner Schlusspunkt am Textende und an Zeilenenden weg („…“, „?“, „!“ bleiben; Abkürzungen bleiben).
    private static func dropFinalPeriods(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.last == " " { l.removeLast() }
            guard l.hasSuffix("."), !l.hasSuffix("..") else { return line }
            let body = String(l.dropLast())
            let lastWord = body.split(whereSeparator: { $0 == " " }).last.map(String.init)?.lowercased() ?? ""
            let tail2 = body.split(separator: " ").suffix(2).joined(separator: " ").lowercased()
            if abbreviations.contains(lastWord) || abbreviations.contains(tail2) { return line }
            if lastWord.count == 1, lastWord.first?.isLetter == true { return line }   // „z. B.“, Initialen
            return body
        }
        return lines.joined(separator: "\n")
    }

    /// Erstes Wort jedes Satzes klein – außer Abkürzungen/Namen mit Binnen-Großbuchstaben (KiTaNet, iPhone, ID).
    private static func lowercaseSentenceStarts(_ s: String) -> String {
        var chars = Array(s)
        var atStart = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if atStart, c.isLetter {
                // Wort bestimmen
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j] == "-" || chars[j] == "'" || chars[j] == "’" { j += 1 }
                let word = String(chars[i..<j])
                let rest = word.dropFirst()
                let keep = word.count == 1 ? word == "I" : rest.contains(where: { $0.isUppercase })
                if !keep, c.isUppercase { chars[i] = Character(String(c).lowercased()) }
                atStart = false
                i = j
                continue
            }
            if c == "\u{E000}" {   // Platzhalter (URL, Code) am Satzanfang → nicht anfassen
                atStart = false
                while i < chars.count, chars[i] != "\u{E001}" { i += 1 }
                i += 1
                continue
            }
            if ".!?".contains(c) {
                if i + 1 == chars.count || chars[i + 1].isWhitespace { atStart = true }
            } else if c == "\n" {
                atStart = true
            } else if !c.isWhitespace, !"\"'„“”‚‘(-–".contains(c) {
                atStart = false
            }
            i += 1
        }
        return String(chars)
    }

    /// Schlusspunkt → „!“
    private static func excite(_ s: String) -> String {
        var l = s
        var trailing = ""
        while let c = l.last, c.isWhitespace { trailing.insert(c, at: trailing.startIndex); l.removeLast() }
        if l.hasSuffix("."), !l.hasSuffix("..") {
            let lastWord = l.dropLast().split(separator: " ").last.map { String($0).lowercased() } ?? ""
            if !abbreviations.contains(lastWord) { l = String(l.dropLast()) + "!" }
        } else if let c = l.last, c.isLetter || c.isNumber {
            l += "!"
        }
        return l + trailing
    }
}

// MARK: - Seite

struct VFStylePage: View {
    @ObservedObject private var store: StyleStore
    @ObservedObject private var settings: Settings
    @State private var tab = AppCategory.personal.rawValue

    init() { self.store = StyleStore.shared; self.settings = Settings.shared }
    init(store: StyleStore, settings: Settings) { self.store = store; self.settings = settings }
    /// Direkt auf einem Reiter öffnen (AppCategory.rawValue oder "cleanup")
    init(tab: String) { self.store = StyleStore.shared; self.settings = Settings.shared; _tab = State(initialValue: tab) }

    private let tabs: [PGTab] = [
        PGTab(id: AppCategory.personal.rawValue, title: "Persönliche Nachrichten"),
        PGTab(id: AppCategory.work.rawValue, title: "Arbeitsnachrichten"),
        PGTab(id: AppCategory.email.rawValue, title: "E-Mail"),
        PGTab(id: AppCategory.other.rawValue, title: "Sonstiges"),
        PGTab(id: "cleanup", title: "Automatisch aufräumen", badge: "Beta"),
    ]

    var body: some View {
        PGPage(title: "Stil") { EmptyView() } content: {
            PGTabBar(tabs: tabs, selection: $tab)
            if tab == "cleanup" {
                cleanup
            } else if let cat = AppCategory(rawValue: tab) {
                categoryView(cat)
            }
        }
    }

    // MARK: App-Art

    private func headline(_ c: AppCategory) -> String {
        switch c {
        case .personal: return "Dieser Stil gilt in *persönlichen* Nachrichten"
        case .work: return "Dieser Stil gilt bei der *Arbeit*"
        case .email: return "Dieser Stil gilt in *E-Mails*"
        default: return "Dieser Stil gilt in *allen anderen* Apps"
        }
    }

    private func sample(_ c: AppCategory) -> String {
        switch c {
        case .email: return "Hallo Anna, danke für deine Nachricht. Ich schicke dir die Unterlagen bis Freitag."
        case .work: return "Kurzes Update: Das Design ist fertig. Kannst du heute noch drüberschauen?"
        case .other: return "Heute fertig geworden: Wörterbuch, Snippets und Stil. Morgen kommen die Tests."
        default: return "Hey, hast du morgen Zeit zum Mittagessen? Sagen wir 12, wenn’s passt."
        }
    }

    private func kinds(_ c: AppCategory) -> [StyleKind] { c == .email ? [.formal, .casual, .excited] : [.formal, .casual, .veryCasual] }

    private func categoryView(_ c: AppCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PGBanner(image: "banner_stil", palette: PGBannerPalette.slate) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        PG.headline(headline(c), size: 38).lineLimit(1).minimumScaleFactor(0.7)
                        Text("Flow erkennt die App im Vordergrund und formatiert dein Diktat passend – auf Deutsch und Englisch.")
                            .font(PG.body).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14).frame(maxWidth: 590, alignment: .leading)
                    }
                    Spacer(minLength: 10)
                    StyleAppIcons(category: c)
                }
            }
            .padding(.top, 32)

            HStack(alignment: .top, spacing: 33) {
                ForEach(kinds(c)) { k in
                    StyleCard(kind: k, preview: StyleStore.transform(sample(c), k), selected: store.style(for: c) == k) {
                        store.set(k, for: c)
                    }
                }
            }
            .padding(.top, 33)
        }
    }

    // MARK: Automatisch aufräumen (vorhandene Einstellungen)

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 0) {
            PGBanner(image: "banner_stil", palette: PGBannerPalette.slate) {
                PG.headline("Sag es, wie es *kommt*.", size: 38)
                Text("Flow räumt dein Diktat vor dem Einfügen auf: Füllwörter raus, Selbstkorrekturen („nein warte …“) aufgelöst.")
                    .font(PG.body).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14).frame(maxWidth: 760, alignment: .leading)
            }
            .padding(.top, 32)

            VStack(spacing: 0) {
                PGSettingRow(title: "Füllwörter entfernen", detail: "„ähm“, „äh“, „uh“ und direkte Wortwiederholungen verschwinden.") {
                    Toggle("", isOn: $settings.removeFillers).toggleStyle(.switch).labelsHidden().tint(VF.black)
                }
                Divider().overlay(VF.hairline)
                PGSettingRow(title: "KI-Feinschliff", detail: settings.aiPolish.label + " · " + Polisher.statusLine(settings.aiPolish, short: true)) {
                    PGChoiceMenu(selection: $settings.aiPolish, options: AIPolish.allCases) { $0.label }
                }
            }
            .padding(.horizontal, 26)
            .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.card))
            .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
            .padding(.top, 33)

            HStack(alignment: .top, spacing: 33) {
                beforeAfter(title: "Vorher", text: "Ähm, ich nehme den Käsetoast, nein warte, die Dino-Nuggets.", muted: true)
                beforeAfter(title: "Nachher", text: "Ich nehme die Dino-Nuggets.", muted: false)
            }
            .padding(.top, 33)
        }
    }

    private func beforeAfter(title: String, text: String, muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold)).tracking(1.2).textCase(.uppercase).foregroundStyle(VF.muted)
            Text(text).font(.system(size: 18)).foregroundStyle(muted ? VF.muted : VF.ink)
                .strikethrough(muted, color: VF.muted.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(muted ? VF.cardSoft : VF.card))
        .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
    }
}

/// Stil-Karte: Titel, Chat-Blase mit Vorschau, rundes „J“.
private struct StyleCard: View {
    let kind: StyleKind
    let preview: String
    let selected: Bool
    let onSelect: () -> Void
    @State private var hover = false

    private var avatar: (Color, Color) {
        switch kind {
        case .formal: return (Color(red: 0.91, green: 0.85, blue: 0.97), .white)
        case .casual: return (Color(red: 0.95, green: 0.76, blue: 0.93), .white)
        case .veryCasual: return (Color(red: 0.47, green: 0.12, blue: 0.23), .white)
        case .excited: return (Color(red: 0.96, green: 0.62, blue: 0.30), .white)
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.title).font(.system(size: 18.5, weight: .medium)).foregroundStyle(VF.ink)
                Text(kind.subtitle).font(.system(size: 18.5, weight: .medium)).foregroundStyle(VF.ink).padding(.top, 8)
                Spacer(minLength: 90)
                Text(preview)
                    .font(.system(size: 18.5)).foregroundStyle(VF.ink).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 19).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StyleBubble().fill(Color(red: 0.972, green: 0.965, blue: 0.988)))
                HStack {
                    Spacer()
                    Text("J").font(.system(size: 24, weight: .medium)).foregroundStyle(avatar.1)
                        .frame(width: 68, height: 68).background(Circle().fill(avatar.0))
                }
                .padding(.top, 16)
                Spacer(minLength: 60)
            }
            .padding(.horizontal, 23).padding(.top, 26)
            .frame(maxWidth: .infinity, minHeight: 460, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(VF.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? VF.purple : (hover ? VF.beige : VF.hairline), lineWidth: selected ? 2.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Sprechblase mit kleiner Spitze unten rechts (zum Avatar hin)
private struct StyleBubble: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: 12)
        p.move(to: CGPoint(x: r.maxX - 34, y: r.maxY - 1))
        p.addLine(to: CGPoint(x: r.maxX - 4, y: r.maxY - 1))
        p.addLine(to: CGPoint(x: r.maxX - 4, y: r.maxY + 14))
        p.closeSubpath()
        return p
    }
}

/// Runde App-Symbole im Banner (echte Icons, wenn installiert, sonst SF Symbols) + „+“
private struct StyleAppIcons: View {
    let category: AppCategory

    private var apps: [(String, String)] {   // (Bundle-ID, Ersatz-Symbol)
        switch category {
        case .personal: return [("net.whatsapp.WhatsApp", "phone.bubble.fill"), ("ru.keepcoder.Telegram", "paperplane.fill"),
                                ("com.hnc.Discord", "gamecontroller.fill"), ("org.whispersystems.signal-desktop", "lock.circle.fill"),
                                ("com.apple.MobileSMS", "message.fill")]
        case .work: return [("com.tinyspeck.slackmacgap", "number"), ("com.microsoft.teams2", "person.3.fill"),
                            ("notion.id", "doc.text.fill"), ("com.linear", "line.3.horizontal"), ("us.zoom.xos", "video.fill")]
        case .email: return [("com.apple.mail", "envelope.fill"), ("com.microsoft.Outlook", "envelope.badge.fill"),
                             ("com.readdle.SparkDesktop", "paperplane"), ("com.superhuman.electron", "bolt.fill")]
        default: return [("com.apple.Notes", "note.text"), ("com.apple.Safari", "safari.fill"),
                          ("com.google.Chrome", "globe"), ("com.apple.iWork.Pages", "doc.richtext.fill")]
        }
    }

    var body: some View {
        // Installierte Apps mit echtem Icon zuerst, dann mit SF-Symbol auffüllen (max. 4)
        let items: [(NSImage?, String)] = apps.map { a in
            (NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.0).map { NSWorkspace.shared.icon(forFile: $0.path) }, a.1)
        }.sorted { ($0.0 != nil ? 0 : 1) < ($1.0 != nil ? 0 : 1) }
        HStack(spacing: -16) {
            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, it in
                circle {
                    if let img = it.0 {
                        Image(nsImage: img).resizable().interpolation(.high).frame(width: 46, height: 46)
                    } else {
                        Image(systemName: it.1).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                    }
                }
            }
            circle { Image(systemName: "plus").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.8)) }
        }
    }

    private func circle<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(width: 72, height: 72)
            .background(Circle().fill(Color(white: 0.35).opacity(0.55)))
            .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1.5))
    }
}

// MARK: - Zeilen im Einstellungs-Stil (auch vom Einstellungs-Modal genutzt)

struct PGSettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 18, weight: .medium)).foregroundStyle(VF.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 16.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 22)
    }
}

/// „Ändern“-Knopf, der eine Auswahlliste öffnet (Häkchen bei der aktuellen Wahl).
struct PGChoiceMenu<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var title = "Ändern"
    var onChange: ((T) -> Void)? = nil

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { selection = o; onChange?(o) } label: {
                    if o == selection { Label(label(o), systemImage: "checkmark") } else { Text(label(o)) }
                }
            }
        } label: {
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(VF.ink)
                .frame(width: 216, height: 47)
                .background(RoundedRectangle(cornerRadius: VF.buttonRadius).fill(Color(red: 0.925, green: 0.918, blue: 0.898)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
