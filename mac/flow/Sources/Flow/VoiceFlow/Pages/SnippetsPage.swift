import AppKit
import Combine
import SwiftUI

// MARK: - Snippets: Auslöser-Wort → gespeicherter Text

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String
}

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    static let file = "snippets.json"

    @Published var snippets: [Snippet] = [] { didSet { if persist, snippets != oldValue { PGFile.save(snippets, Self.file) } } }
    private let persist: Bool

    /// Startbestand für einen neuen Benutzer – nichts Persönliches (eigene E-Mail/Adresse legt jeder selbst an)
    static let seed: [Snippet] = [
        Snippet(trigger: "Gedanken ordnen", text: "Ordne diese unsortierten Gedanken zu einer klaren, gut lesbaren Fassung, ohne Inhalt wegzulassen:"),
    ]

    private init() {
        persist = true
        if let list = PGFile.load(Self.file, as: [Snippet].self) {
            snippets = list
        } else {
            snippets = Self.seed
            PGFile.save(snippets, Self.file)
        }
    }

    /// Für Tests/Vorschau: ohne Datei
    init(testing list: [Snippet]) { persist = false; snippets = list }

    func upsert(_ s: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s } else { snippets.append(s) }
    }

    func delete(_ id: UUID) { snippets.removeAll { $0.id == id } }

    /// Diktat-Pipeline: Ist das ganze Diktat ein Auslöser („Meine E-Mail.“) → Snippet-Text.
    /// In längerem Text: „Snippet <Auslöser>“, „<Auslöser> einfügen“ oder „füge <Auslöser> ein“ → an der Stelle ersetzen.
    /// Groß-/Kleinschreibung und Satzzeichen egal. Sonst unverändert.
    func expand(_ text: String) -> String {
        let usable = snippets.filter { !$0.trigger.pgKey.isEmpty && !$0.text.isEmpty }
            .sorted { $0.trigger.pgKey.count > $1.trigger.pgKey.count }   // längster Auslöser gewinnt
        guard !usable.isEmpty else { return text }

        // 1) Ganzes Diktat = Auslöser (auch mit „Snippet …“ / „… einfügen“ drumherum)
        let whole = text.pgKey
        for sn in usable {
            let k = sn.trigger.pgKey
            if whole == k || whole == "snippet" + k || whole == k + "einfügen" || whole == "füge" + k + "ein" || whole == "insert" + k {
                return sn.text
            }
        }

        // 2) Eingebettet mit ausdrücklichem Befehl
        var out = text
        for sn in usable {
            let trig = Self.triggerPattern(sn.trigger)
            let tpl = NSRegularExpression.escapedTemplate(for: sn.text)
            let patterns = [
                "(?i)(?<![\\p{L}\\d])snippet[\\s,:]+\(trig)(?![\\p{L}\\d])",
                "(?i)(?<![\\p{L}\\d])\(trig)[\\s,]+einfügen(?![\\p{L}\\d])",
                "(?i)(?<![\\p{L}\\d])füg(?:e)?[\\s,]+\(trig)[\\s,]+ein(?![\\p{L}\\d])",
                "(?i)(?<![\\p{L}\\d])insert[\\s,]+\(trig)(?![\\p{L}\\d])",
            ]
            for p in patterns {
                out = out.replacingOccurrences(of: p, with: tpl, options: .regularExpression)
            }
        }
        return out
    }

    /// „meine E-Mail“ → meine[^\p{L}\d]*e[^\p{L}\d]*mail (passt auch auf „Meine Email“, „meine e mail“)
    static func triggerPattern(_ trigger: String) -> String {
        let tokens = trigger.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return tokens.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "[^\\p{L}\\d]*")
    }
}

// MARK: - Seite

struct VFSnippetsPage: View {
    @ObservedObject private var store: SnippetStore
    @State private var searching = false
    @State private var query = ""
    @State private var sortAZ = false
    @State private var editing: Snippet? = nil
    @State private var showSheet = false
    @AppStorage("vf.pages.bannerHidden.snippets") private var bannerHidden = false

    init() { self.store = SnippetStore.shared }
    init(store: SnippetStore) { self.store = store }

    private var items: [Snippet] {
        var l = store.snippets
        if !query.pgTrimmed.isEmpty {
            let q = query.lowercased()
            l = l.filter { $0.trigger.lowercased().contains(q) || $0.text.lowercased().contains(q) }
        }
        return sortAZ ? l.sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending } : l.reversed()
    }

    var body: some View {
        PGPage(title: "Snippets") {
            PGPrimaryButton("Neu hinzufügen") { open(nil) }
        } content: {
            PGTabBar(tabs: [PGTab(id: "alle", title: "Alle")], selection: .constant("alle")) {
                PGIconButton(symbol: "magnifyingglass", help: "Suchen") { searching.toggle(); if !searching { query = "" } }
                PGIconButton(symbol: "arrow.up.arrow.down", help: sortAZ ? "Neueste zuerst" : "A–Z sortieren", tint: sortAZ ? VF.ink : VF.muted) { sortAZ.toggle() }
            }
            if searching { PGSearchField(text: $query, prompt: "Snippet suchen …") }

            if !bannerHidden {
                PGBanner(image: "banner_snippets", palette: PGBannerPalette.dusk, onClose: { bannerHidden = true }) {
                    PG.headline("Was *du* nicht ständig neu tippen solltest.", size: 48).lineLimit(2)
                    Text("Speichere Texte, die du oft brauchst – eine E-Mail, eine Vorstellung, einen Prompt – und sag ein Wort, um sie einzufügen.")
                        .font(PG.body).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18).frame(maxWidth: 930, alignment: .leading)
                    VStack(alignment: .leading, spacing: 11) {
                        example("meine E-Mail", "vorname@beispiel.de")
                        example("meine Adresse", "\(Identity.myName) Mustermann, Musterstraße 1, 12345 Musterstadt")
                        example("Prompt aufräumen", "Ordne diese Gedanken klar und knapp …")
                    }
                    .padding(.top, 22)
                    Button("Neues Snippet") { open(nil) }
                        .buttonStyle(PGSoftButtonStyle(fill: .white.opacity(0.92)))
                        .padding(.top, 32)
                }
                .padding(.top, 32)
            }

            Group {
                if items.isEmpty {
                    PGEmptyState(illustration: "illu_snippet", title: query.isEmpty ? "Noch keine Snippets" : "Nichts gefunden",
                                 text: "Leg ein Snippet an und sag später einfach den Auslöser – Flow fügt den ganzen Text ein.")
                } else {
                    PGListCard(items: items) { sn in
                        PGRow {
                            Text("\(Text(verbatim: sn.trigger))\(Text(verbatim: "  →  ").foregroundStyle(VF.muted))\(Text(verbatim: sn.text.replacingOccurrences(of: "\n", with: " ")))")
                                .font(PG.rowFont).foregroundStyle(VF.ink).lineLimit(1).truncationMode(.tail)
                        } actions: {
                            PGIconButton(symbol: "doc.on.doc", help: "Text kopieren") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sn.text, forType: .string)
                            }
                            PGIconButton(symbol: "pencil", help: "Bearbeiten") { open(sn) }
                            PGIconButton(symbol: "trash", help: "Löschen") { store.delete(sn.id) }
                        } onTap: { open(sn) }
                    }
                }
            }
            .padding(.top, 48)
        }
        .sheet(isPresented: $showSheet) {
            SnippetEditor(snippet: editing) { store.upsert($0); showSheet = false } onClose: { showSheet = false }
        }
    }

    private func example(_ trigger: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("„\(trigger)“").font(.system(size: 18, weight: .semibold).italic()).foregroundStyle(VF.ink.opacity(0.85))
                .padding(.horizontal, 21).frame(height: 47)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.42)))
            Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(text).font(.system(size: 18, weight: .semibold)).foregroundStyle(VF.ink.opacity(0.85)).lineLimit(1)
                .padding(.horizontal, 21).frame(height: 47)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.62)))
        }
    }

    private func open(_ s: Snippet?) { editing = s; showSheet = true }
}

private struct SnippetEditor: View {
    let snippet: Snippet?
    let onSave: (Snippet) -> Void
    let onClose: () -> Void
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        PGSheet(title: snippet == nil ? "Neues Snippet" : "Snippet bearbeiten",
                subtitle: "Sag den Auslöser als ganzes Diktat – oder mitten im Satz „Snippet …“ bzw. „… einfügen“.",
                confirm: "Speichern", canConfirm: !trigger.pgKey.isEmpty && !text.pgTrimmed.isEmpty,
                onCancel: onClose,
                onConfirm: {
                    var s = snippet ?? Snippet(trigger: "", text: "")
                    s.trigger = trigger.pgTrimmed; s.text = text.trimmingCharacters(in: .newlines)
                    onSave(s)
                }) {
            PGField(label: "Auslöser (das sagst du)", text: $trigger, placeholder: "z. B. meine Adresse")
            PGField(label: "Text (das wird eingefügt)", text: $text, multiline: true)
        }
        .onAppear { trigger = snippet?.trigger ?? ""; text = snippet?.text ?? "" }
    }
}
