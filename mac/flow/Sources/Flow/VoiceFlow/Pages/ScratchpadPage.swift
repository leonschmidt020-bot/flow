import AppKit
import Combine
import SwiftUI

// MARK: - Scratchpad: Notizen, optional mit allen Diktaten gefüllt

struct ScratchNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
    var updated = Date()

    var title: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?.pgTrimmed ?? ""
        return first.isEmpty ? "Neue Notiz" : String(first.prefix(60))
    }
    var preview: String {
        let lines = text.split(whereSeparator: \.isNewline).dropFirst().map(String.init).joined(separator: " ").pgTrimmed
        return lines
    }
}

final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()
    static let file = "scratchpad.json"

    private struct Stored: Codable {
        var notes: [ScratchNote]
        var selectedID: UUID?
        var collectDictations: Bool
    }

    @Published var notes: [ScratchNote] = [] { didSet { scheduleSave() } }
    @Published var selectedID: UUID? { didSet { scheduleSave() } }
    /// Jedes Diktat zusätzlich an die aktuelle Notiz anhängen
    @Published var collectDictations = false { didSet { scheduleSave() } }

    private let persist: Bool
    private var saveWork: DispatchWorkItem?

    private init() {
        persist = true
        if let s = PGFile.load(Self.file, as: Stored.self) {
            notes = s.notes; selectedID = s.selectedID; collectDictations = s.collectDictations
        }
    }

    init(testing notes: [ScratchNote], collect: Bool = false) {
        persist = false
        self.notes = notes; selectedID = notes.first?.id; collectDictations = collect
    }

    var current: ScratchNote? { notes.first { $0.id == selectedID } ?? notes.first }

    @discardableResult
    func newNote(_ text: String = "") -> ScratchNote {
        let n = ScratchNote(text: text)
        notes.insert(n, at: 0)
        selectedID = n.id
        return n
    }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = notes.first?.id }
    }

    /// Diktat-Pipeline: nach dem Einfügen aufrufen. Hängt nur an, wenn „Diktate hier sammeln“ an ist.
    /// Ohne Notiz wird eine neue angelegt. Gibt zurück, ob angehängt wird. Thread-sicher (hängt auf dem Main-Thread an).
    @discardableResult
    func appendDictation(_ text: String) -> Bool {
        let t = text.pgTrimmed
        guard collectDictations, !t.isEmpty else { return false }
        let work = { [self] in
            if let cur = current, let i = notes.firstIndex(where: { $0.id == cur.id }) {
                let sep = notes[i].text.pgTrimmed.isEmpty ? "" : (notes[i].text.hasSuffix("\n") ? "" : "\n")
                notes[i].text += sep + t
                notes[i].updated = Date()
                selectedID = cur.id
            } else {
                newNote(t)
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
        return true
    }

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveNow() {
        guard persist else { return }
        PGFile.save(Stored(notes: notes, selectedID: selectedID, collectDictations: collectDictations), Self.file)
    }
}

// MARK: - Seite

struct VFScratchpadPage: View {
    @ObservedObject private var store: ScratchpadStore
    @State private var draft = ""
    @State private var copied = false
    @AppStorage("vf.pages.bannerHidden.scratchpad") private var bannerHidden = false

    init() { self.store = ScratchpadStore.shared }
    init(store: ScratchpadStore) { self.store = store }

    var body: some View {
        PGPage(title: "Scratchpad", badge: "Beta") {
            HStack(spacing: 14) {
                Text("Diktate hier sammeln").font(.system(size: 17)).foregroundStyle(VF.ink.opacity(0.8))
                Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(VF.muted)
                    .help("Wenn an, landet jedes Diktat zusätzlich in der gerade offenen Notiz.")
                Toggle("", isOn: $store.collectDictations).toggleStyle(.switch).labelsHidden().tint(VF.black)
                PGPrimaryButton("Neue Notiz") { store.newNote(); draft = "" }
                    .padding(.leading, 8)
            }
        } content: {
            if !bannerHidden {
                PGBanner(image: "banner_scratchpad", palette: PGBannerPalette.sunset, onClose: { bannerHidden = true }) {
                    PG.headline("Deine Gedanken, *einfach* diktiert.", size: 48).lineLimit(2)
                    Text("Ein Ort für lose Ideen, Listen und Entwürfe. Schalte „Diktate hier sammeln“ ein, dann wandert alles, was du sprichst, auch in die offene Notiz.")
                        .font(PG.body).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18).frame(maxWidth: 900, alignment: .leading)
                }
                .padding(.top, 32)
            }

            HStack(spacing: 0) {
                noteList.frame(width: 300)
                Rectangle().fill(VF.hairline).frame(width: 1)
                editor
            }
            .frame(height: 560)
            .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.card))
            .clipShape(RoundedRectangle(cornerRadius: VF.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
            .padding(.top, 40)
        }
        .onAppear { draft = store.current?.text ?? "" }
        .onChange(of: store.selectedID) { draft = store.current?.text ?? "" }
        .onChange(of: store.current?.text) { if let t = store.current?.text, t != draft { draft = t } }
    }

    private var noteList: some View {
        ScrollView {
            VStack(spacing: 4) {
                if store.notes.isEmpty {
                    Text("Noch keine Notizen").font(.system(size: 15)).foregroundStyle(VF.muted).padding(.top, 24)
                }
                ForEach(store.notes) { n in
                    NoteListRow(note: n, selected: n.id == store.current?.id) { store.selectedID = n.id }
                }
            }
            .padding(10)
        }
        .background(VF.panel.opacity(0.6))
    }

    @ViewBuilder private var editor: some View {
        if let cur = store.current {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(cur.updated.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13.5)).foregroundStyle(VF.muted)
                    if store.collectDictations {
                        Label("sammelt Diktate", systemImage: "mic.fill").font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(VF.purple).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(VF.purple.opacity(0.1))).padding(.leading, 6)
                    }
                    Spacer()
                    PGIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Alles kopieren") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    PGIconButton(symbol: "trash", help: "Notiz löschen", tint: Color(red: 0.75, green: 0.25, blue: 0.22)) { store.delete(cur.id) }
                }
                .padding(.horizontal, 22).padding(.top, 14)
                TextEditor(text: $draft)
                    .font(.system(size: 18))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(VF.ink)
                    .padding(.horizontal, 17).padding(.vertical, 10)
                    .onChange(of: draft) { store.update(cur.id, text: draft) }
            }
        } else {
            VStack(spacing: 14) {
                if let img = VFAsset.image("illu_scratchpad") {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 20))
                }
                Text("Leeres Blatt").font(.system(size: 19, weight: .semibold)).foregroundStyle(VF.ink)
                Text("Leg eine Notiz an oder diktiere einfach los, wenn „Diktate hier sammeln“ an ist.")
                    .font(.system(size: 15)).foregroundStyle(VF.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("Neue Notiz") { store.newNote() }.buttonStyle(PGSoftButtonStyle(height: 40)).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NoteListRow: View {
    let note: ScratchNote
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.system(size: 15.5, weight: .medium)).foregroundStyle(VF.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(note.updated.formatted(.relative(presentation: .named))).foregroundStyle(VF.muted)
                    if !note.preview.isEmpty { Text("·").foregroundStyle(VF.muted); Text(note.preview).foregroundStyle(VF.muted).lineLimit(1) }
                }
                .font(.system(size: 13))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? VF.selected : (hover ? VF.buttonSoft.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
