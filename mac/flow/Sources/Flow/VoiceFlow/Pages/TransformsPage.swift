import AppKit
import Combine
import SwiftUI

// MARK: - Transforms: markierten Text per Sprachbefehl umschreiben

struct TransformPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Anweisung an die KI (Claude/Apple Intelligence)
    var instruction: String
    /// Gesprochene Befehle, die dieses Preset auslösen („kürzer“, „mach das kürzer“ …)
    var spokenTriggers: [String]
}

final class TransformStore: ObservableObject {
    static let shared = TransformStore()
    static let file = "transforms.json"

    @Published var presets: [TransformPreset] = [] { didSet { if persist, presets != oldValue { PGFile.save(presets, Self.file) } } }
    private let persist: Bool

    static var defaults: [TransformPreset] { [
        TransformPreset(name: "Kürzer fassen",
                        instruction: "Kürze den Text deutlich, ohne wichtige Informationen zu verlieren. Behalte Sprache, Ton und Anrede bei.",
                        spokenTriggers: ["kürzer", "kürzen", "kürz", "kurz fassen", "knapper", "kompakter", "shorter", "make it shorter", "shorten"]),
        TransformPreset(name: "Professioneller",
                        instruction: "Formuliere den Text professioneller und sachlicher, wie für eine geschäftliche Nachricht. Inhalt und Sprache bleiben gleich.",
                        spokenTriggers: ["professioneller", "professionell", "förmlicher", "formeller", "seriöser", "geschäftlich", "more professional", "professional", "formal"]),
        TransformPreset(name: "Lockerer",
                        instruction: "Formuliere den Text lockerer und freundlicher, wie unter Freunden. Inhalt und Sprache bleiben gleich.",
                        spokenTriggers: ["lockerer", "locker", "entspannter", "weniger förmlich", "freundlicher", "lässiger", "casual", "more casual", "friendlier"]),
        TransformPreset(name: "Auf Englisch",
                        instruction: "Übersetze den Text ins natürliche, idiomatische Englisch. Behalte Ton und Formatierung bei.",
                        spokenTriggers: ["auf englisch", "ins englische", "englisch", "übersetz ins englische", "in english", "to english", "translate to english", "english"]),
        TransformPreset(name: "Auf Deutsch",
                        instruction: "Übersetze den Text ins natürliche Deutsch (Du-Form, wenn nicht anders erkennbar). Behalte Ton und Formatierung bei.",
                        spokenTriggers: ["auf deutsch", "ins deutsche", "deutsch", "übersetz ins deutsche", "in german", "to german", "translate to german", "german"]),
        TransformPreset(name: "Rechtschreibung korrigieren",
                        instruction: "Korrigiere nur Rechtschreibung, Grammatik und Zeichensetzung. Ändere keine Formulierungen.",
                        spokenTriggers: ["rechtschreibung", "korrigier", "korrigieren", "korrektur", "fehler", "tippfehler", "grammatik", "fix spelling", "fix grammar", "fix typos", "proofread"]),
        TransformPreset(name: "Als Stichpunkte",
                        instruction: "Wandle den Text in eine übersichtliche Stichpunktliste um (mit „- “ am Zeilenanfang). Keine Einleitung.",
                        spokenTriggers: ["stichpunkte", "stichpunkten", "stichpunktartig", "aufzählung", "als liste", "liste", "bullet points", "bullets", "bullet list"]),
        TransformPreset(name: "E-Mail daraus machen",
                        instruction: "Mach aus dem Text eine vollständige, freundliche E-Mail mit Anrede, klarem Hauptteil und Grußformel („Viele Grüße, \(Identity.myName)“). Sprache des Textes beibehalten.",
                        spokenTriggers: ["e-mail", "email", "mail daraus", "als mail", "eine mail", "write an email", "turn into an email", "make it an email"]),
    ] }

    private init() {
        persist = true
        if let list = PGFile.load(Self.file, as: [TransformPreset].self), !list.isEmpty {
            presets = list
        } else {
            presets = Self.defaults
            PGFile.save(presets, Self.file)
        }
    }

    init(testing list: [TransformPreset]) { persist = false; presets = list }

    func upsert(_ p: TransformPreset) {
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
    }
    func delete(_ id: UUID) { presets.removeAll { $0.id == id } }
    func resetToDefaults() { presets = Self.defaults }

    /// Gesprochenen Befehl („mach das bitte kürzer“) einem Preset zuordnen. nil → freier Befehl (direkt an die KI).
    func match(_ spoken: String) -> TransformPreset? {
        let said = Self.normalize(spoken)
        guard !said.isEmpty else { return nil }
        let saidWords = said.split(separator: " ").map(String.init)
        var best: (TransformPreset, Int)? = nil
        for p in presets {
            var score = 0
            for trig in p.spokenTriggers + [p.name] {
                let t = Self.normalize(trig)
                guard !t.isEmpty else { continue }
                if said == t {
                    score = max(score, 1000 + t.count)
                } else if (" " + said + " ").contains(" " + t + " ") || (t.count >= 6 && said.contains(t)) {
                    score = max(score, 100 + t.count)   // längster passender Befehl gewinnt
                } else {
                    // Wortstamm-Vergleich (erste 5 Buchstaben), z. B. „stichpunktliste“ ↔ „stichpunkte“
                    let tw = t.split(separator: " ").map(String.init)
                    let hits = tw.filter { w in w.count >= 5 && saidWords.contains { $0.count >= 5 && $0.prefix(5) == w.prefix(5) } }.count
                    if hits == tw.count, hits > 0 { score = max(score, 50 + t.count) }
                }
            }
            if score > 0, score > (best?.1 ?? 0) { best = (p, score) }
        }
        return best?.0
    }

    /// klein, ohne Satzzeichen, Füllwörter („mach“, „das“, „bitte“ …) raus
    static func normalize(_ s: String) -> String {
        let fill: Set<String> = ["mach", "mache", "machs", "das", "den", "die", "der", "text", "es", "mal", "bitte", "doch", "etwas", "ein", "bisschen",
                                 "noch", "hier", "daraus", "draus", "davon", "make", "this", "it", "that", "please", "a", "bit", "the", "schreib", "formulier", "um"]
        let cleaned = s.lowercased().unicodeScalars.map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" ? Character($0) : " " }
        let words = String(cleaned).split(separator: " ").map(String.init).filter { !fill.contains($0) }
        return words.joined(separator: " ")
    }
}

// MARK: - Seite

struct VFTransformsPage: View {
    @ObservedObject private var store: TransformStore
    @State private var editing: TransformPreset? = nil
    @State private var showSheet = false
    @State private var tryText = ""
    @AppStorage("vf.pages.bannerHidden.transforms") private var bannerHidden = false

    init() { self.store = TransformStore.shared }
    init(store: TransformStore) { self.store = store }

    var body: some View {
        PGPage(title: "Transforms") {
            PGPrimaryButton("Neu hinzufügen") { editing = nil; showSheet = true }
        } content: {
            PGTabBar(tabs: [PGTab(id: "alle", title: "Alle")], selection: .constant("alle")) {
                PGIconButton(symbol: "arrow.counterclockwise", help: "Standard-Transforms wiederherstellen") { store.resetToDefaults() }
            }

            if !bannerHidden {
                PGBanner(image: "banner_transforms", palette: PGBannerPalette.forest, onClose: { bannerHidden = true }) {
                    PG.headline("Markiere Text – und *sag*, was daraus werden soll.", size: 48).lineLimit(2)
                    keysLine.padding(.top, 18)
                    PGFlow {
                        ForEach(["„mach das kürzer“", "„auf Englisch“", "„als Stichpunkte“", "„klingt zu steif, lockerer“"], id: \.self) {
                            PGBannerChip(title: $0, italic: true)
                        }
                    }
                    .padding(.top, 22)
                }
                .padding(.top, 32)
            }

            tester.padding(.top, 32)

            PGListCard(items: store.presets) { p in
                PGRow {
                    HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(p.name).font(PG.rowFont).foregroundStyle(VF.ink)
                        Text(p.instruction).font(.system(size: 14.5)).foregroundStyle(VF.muted).lineLimit(1)
                    }
                    .padding(.vertical, 12)
                    Spacer(minLength: 0)
                    Text(p.spokenTriggers.prefix(2).map { "„\($0)“" }.joined(separator: "  "))
                        .font(.system(size: 14, weight: .medium).italic()).foregroundStyle(VF.muted).lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(VF.cardSoft))
                    }
                    .frame(maxWidth: .infinity)
                } actions: {
                    PGIconButton(symbol: "pencil", help: "Bearbeiten") { editing = p; showSheet = true }
                    PGIconButton(symbol: "trash", help: "Löschen") { store.delete(p.id) }
                } onTap: { editing = p; showSheet = true }
            }
            .padding(.top, 20)

            Text("Was nicht in der Liste steht, geht als freier Befehl direkt an die KI – z. B. „schreib das als Haiku“.")
                .font(.system(size: 14.5)).foregroundStyle(VF.muted).padding(.top, 14).padding(.leading, 4)
        }
        .sheet(isPresented: $showSheet) {
            TransformEditor(preset: editing) { store.upsert($0); showSheet = false } onClose: { showSheet = false }
        }
    }

    private var keysLine: some View {
        HStack(spacing: 8) {
            Text("Text markieren,").font(PG.body)
            key("fn"); Text("+").font(PG.body); key("⌃")
            Text("halten und z. B. „mach das kürzer“ sagen.").font(PG.body)
        }
    }

    private func key(_ k: String) -> some View {
        Text(k).font(.system(size: 16, weight: .semibold)).foregroundStyle(VF.ink)
            .padding(.horizontal, 9).frame(minWidth: 30, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.88)))
    }

    /// Befehl ausprobieren: zeigt, welches Preset ein gesprochener Satz trifft.
    private var tester: some View {
        let hit = store.match(tryText)
        return HStack(spacing: 14) {
            Image(systemName: "waveform").foregroundStyle(VF.muted)
            TextField("Befehl ausprobieren, z. B. „mach das bitte etwas kürzer“", text: $tryText)
                .textFieldStyle(.plain).font(.system(size: 17))
            if !tryText.pgTrimmed.isEmpty {
                Text(hit.map { "→ \($0.name)" } ?? "→ freier Befehl")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hit == nil ? VF.muted : VF.purple)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(hit == nil ? VF.cardSoft : VF.purple.opacity(0.1)))
            }
        }
        .padding(.horizontal, 20).frame(height: 58)
        .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.card))
        .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
    }
}

private struct TransformEditor: View {
    let preset: TransformPreset?
    let onSave: (TransformPreset) -> Void
    let onClose: () -> Void
    @State private var name = ""
    @State private var instruction = ""
    @State private var triggers = ""

    var body: some View {
        PGSheet(title: preset == nil ? "Neuer Transform" : "Transform bearbeiten",
                subtitle: "Markierter Text + dein Sprachbefehl → die KI schreibt ihn nach dieser Anweisung um.",
                confirm: "Speichern", canConfirm: !name.pgTrimmed.isEmpty && !instruction.pgTrimmed.isEmpty,
                onCancel: onClose,
                onConfirm: {
                    var p = preset ?? TransformPreset(name: "", instruction: "", spokenTriggers: [])
                    p.name = name.pgTrimmed
                    p.instruction = instruction.pgTrimmed
                    p.spokenTriggers = triggers.split(separator: ",").map { String($0).pgTrimmed }.filter { !$0.isEmpty }
                    if p.spokenTriggers.isEmpty { p.spokenTriggers = [p.name.lowercased()] }
                    onSave(p)
                }) {
            PGField(label: "Name", text: $name, placeholder: "z. B. Freundlicher")
            PGField(label: "Anweisung an die KI", text: $instruction, multiline: true)
            PGField(label: "Gesprochene Befehle", hint: "Mit Komma getrennt. Es reicht, wenn einer davon im Gesagten vorkommt.",
                    text: $triggers, placeholder: "freundlicher, netter, wärmer")
        }
        .onAppear {
            name = preset?.name ?? ""
            instruction = preset?.instruction ?? ""
            triggers = preset?.spokenTriggers.joined(separator: ", ") ?? ""
        }
    }
}
