import AppKit
import SwiftUI

/// Wörterbuch : Titel + „Neu hinzufügen“, Reiter, Foto-Banner mit Chips, Liste der Wörter (✨ = gelernt).
struct VFDictionaryPage: View {
    @ObservedObject private var s: Settings
    @State private var tab = "alle"
    @State private var searching = false
    @State private var query = ""
    @State private var sortAZ = false
    @State private var editing: DictEntry? = nil
    @State private var showSheet = false
    @AppStorage("vf.pages.bannerHidden.dictionary") private var bannerHidden = false

    init() { self.s = Settings.shared }
    init(settings: Settings) { self.s = settings }

    private var entries: [DictEntry] {
        var list = s.dictionary.filter { !$0.write.pgTrimmed.isEmpty }
        switch tab {
        case "gelernt": list = list.filter { $0.learned == true }
        case "eigene": list = list.filter { $0.learned != true }
        default: break
        }
        if !query.pgTrimmed.isEmpty {
            let q = query.lowercased()
            list = list.filter { $0.write.lowercased().contains(q) || $0.heard.lowercased().contains(q) }
        }
        return sortAZ ? list.sorted { $0.write.localizedCaseInsensitiveCompare($1.write) == .orderedAscending } : list.reversed()
    }

    /// Bis zu 5 Beispielwörter für die Chips im Banner (gelernte zuerst, jedes Wort nur einmal)
    private var exampleWords: [String] {
        var seen = Set<String>(), out: [String] = []
        let ordered = s.dictionary.reversed().sorted { ($0.learned == true ? 0 : 1) < ($1.learned == true ? 0 : 1) }
        for e in ordered {
            let w = e.write.pgTrimmed
            guard !w.isEmpty, w.count <= 18, seen.insert(w.lowercased()).inserted else { continue }
            out.append(w)
            if out.count == 5 { break }
        }
        return out
    }

    var body: some View {
        PGPage(title: "Wörterbuch") {
            PGPrimaryButton("Neu hinzufügen") { openEditor(nil) }
        } content: {
            PGTabBar(tabs: [PGTab(id: "alle", title: "Alle"), PGTab(id: "gelernt", title: "Gelernt ✨"), PGTab(id: "eigene", title: "Eigene")],
                     selection: $tab) {
                PGIconButton(symbol: "magnifyingglass", help: "Suchen") { searching.toggle(); if !searching { query = "" } }
                PGIconButton(symbol: "arrow.up.arrow.down", help: sortAZ ? "Neueste zuerst" : "A–Z sortieren", tint: sortAZ ? VF.ink : VF.muted) { sortAZ.toggle() }
            }
            if searching { PGSearchField(text: $query, prompt: "Wort suchen …") }

            if !bannerHidden {
                PGBanner(image: "banner_woerterbuch", palette: PGBannerPalette.warm, onClose: { bannerHidden = true }) {
                    PG.headline("Flow schreibt, wie *du* schreibst.", size: 48)
                        .lineLimit(2)
                    PG.richBody("Korrigiere ein Wort einmal oder trag es hier ein – **Namen, Fachbegriffe und Firmenwörter** stimmen dann in Diktaten und Meeting-Notizen.")
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                        .frame(maxWidth: 930, alignment: .leading)
                    PGFlow {
                        PGBannerChip(title: "Neues Wort", prominent: true) { openEditor(nil) }
                        ForEach(exampleWords, id: \.self) { w in
                            PGBannerChip(title: w) { searching = true; query = w }
                        }
                    }
                    .padding(.top, 22)
                }
                .padding(.top, 32)
            }

            Group {
                if entries.isEmpty {
                    PGEmptyState(illustration: "illu_wort_gelernt",
                                 title: query.isEmpty ? (tab == "gelernt" ? "Noch nichts gelernt" : "Noch keine Wörter") : "Nichts gefunden",
                                 text: tab == "gelernt"
                                    ? "Korrigierst du ein diktiertes Wort direkt im Textfeld, merkt sich Flow die richtige Schreibweise und zeigt sie hier mit ✨."
                                    : "Trag Namen und Fachbegriffe ein, die Flow richtig schreiben soll.")
                } else {
                    PGListCard(items: entries) { e in row(e) }
                }
            }
            .padding(.top, 48)

            PartnerVocabSection().padding(.top, 56)
        }
        .sheet(isPresented: $showSheet) {
            DictEntryEditor(entry: editing) { heard, write in save(heard: heard, write: write) } onClose: { showSheet = false }
        }
    }

    private func row(_ e: DictEntry) -> some View {
        let isVocab = e.heard.pgTrimmed.isEmpty || e.heard.pgKey == e.write.pgKey
        return PGRow {
            HStack(spacing: 8) {
                Text(e.write).font(PG.rowFont).foregroundStyle(VF.ink).lineLimit(1)
                if e.learned == true {
                    Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(PG.sparkle)
                        .help(e.vocabOnly == true ? "Gelernt – nur als Hinweis für die Erkennung" : "Gelernt aus deiner Korrektur")
                }
                if !isVocab {
                    Text("← gehört: \(e.heard)").font(.system(size: 14.5)).foregroundStyle(VF.muted).lineLimit(1).padding(.leading, 6)
                }
            }
        } actions: {
            PGIconButton(symbol: "pencil", help: "Bearbeiten") { openEditor(e) }
            PGIconButton(symbol: "trash", help: "Löschen") { s.dictionary.removeAll { $0.id == e.id }; s.save() }
        } onTap: { openEditor(e) }
    }

    private func openEditor(_ e: DictEntry?) { editing = e; showSheet = true }

    private func save(heard rawHeard: String, write rawWrite: String) {
        let write = rawWrite.pgTrimmed, heard = rawHeard.pgTrimmed
        guard !write.isEmpty else { return }
        // Ohne „gehört“ = reines Vokabular: nur als Hinweis an die Erkennung, nicht blind ersetzen.
        let vocab = heard.isEmpty || heard.pgKey == write.pgKey
        var entry = editing ?? DictEntry(heard: "", write: "")
        entry.write = write
        entry.heard = vocab ? write : heard
        entry.vocabOnly = vocab ? true : (editing?.learned == true ? editing?.vocabOnly : nil)
        if let i = s.dictionary.firstIndex(where: { $0.id == entry.id }) {
            s.dictionary[i] = entry
        } else {
            s.dictionary.append(entry)
            PartnerVocab.shared.learned(write, source: .manual)   // nur die Schreibweise, nie „gehört“
        }
        s.save()
        showSheet = false
    }
}

/// Dialog „Neues Wort“ / „Wort bearbeiten“.
private struct DictEntryEditor: View {
    let entry: DictEntry?
    let onSave: (String, String) -> Void
    let onClose: () -> Void
    @State private var write = ""
    @State private var heard = ""

    var body: some View {
        PGSheet(title: entry == nil ? "Neues Wort" : "Wort bearbeiten",
                subtitle: "Flow schreibt dieses Wort ab jetzt so – in Diktaten und Meeting-Notizen.",
                confirm: "Speichern", canConfirm: !write.pgTrimmed.isEmpty,
                onCancel: onClose, onConfirm: { onSave(heard, write) }) {
            PGField(label: "Richtige Schreibweise", text: $write, placeholder: "z. B. ClipVault")
            PGField(label: "Wird oft so erkannt (optional)",
                    hint: "Leer lassen, wenn das Wort nur bekannt sein soll. Mit Eintrag wird die falsche Erkennung automatisch ersetzt.",
                    text: $heard, placeholder: "z. B. Kita Net")
        }
        .onAppear {
            guard let e = entry else { return }
            write = e.write
            heard = e.heard.pgKey == e.write.pgKey ? "" : e.heard
        }
    }
}
