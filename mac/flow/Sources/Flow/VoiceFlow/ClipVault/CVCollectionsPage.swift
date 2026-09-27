import AppKit
import SwiftUI

// MARK: - Bereiche: Übersicht, anlegen, umbenennen, löschen

struct CVCollectionsPage: View {
    /// Aus Menüs heraus „Neuer Bereich …“ öffnen
    static var requestCreate = false

    @ObservedObject var cv = ClipVaultClient.shared
    @ObservedObject var state = CVHubState.shared
    @State private var editing: CVCollectionDraft?
    @State private var deleting: CVCollection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Bereiche").font(HubFont.title).foregroundStyle(VF.ink)
                    Text("\(cv.collections.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(VF.muted).padding(.top, 3)
                    Spacer()
                    Button { editing = CVCollectionDraft(existing: nil) } label: {
                        HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)); Text("Neuer Bereich") }
                    }
                    .buttonStyle(HubBlackButton(height: 34))
                }
                .padding(.bottom, 22)

                CVBanner(image: "banner_clipvault_bereiche", palette: PGBannerPalette.slate,
                         headline: "Ordnung, die *bleibt*.",
                         sub: "Was in einem Bereich liegt, löscht ClipVault nie. Passwörter bleiben verdeckt und verschwinden nach 24 Stunden.") {
                    Button("Neuer Bereich") { editing = CVCollectionDraft(existing: nil) }.buttonStyle(HubBannerButton())
                }
                .padding(.bottom, 30)

                HubLabel("Deine Bereiche").padding(.bottom, 12)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)], spacing: 16) {
                    ForEach(cv.collections) { c in
                        CVCollectionCard(collection: c,
                                         open: { state.go(.bereiche, collection: c.id) },
                                         rename: { editing = CVCollectionDraft(existing: c) },
                                         delete: { deleting = c })
                    }
                    newCard
                }
            }
            .frame(maxWidth: 1046, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { d in CVCollectionSheet(draft: d) { editing = nil } }
        .alert("Bereich „\(deleting?.name ?? "")“ löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Löschen", role: .destructive) { if let d = deleting { cv.deleteCollection(d) }; deleting = nil }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        } message: {
            Text("Die \(deleting.map { cv.count(in: $0.id) } ?? 0) Einträge darin wandern zurück in den Verlauf – ClipVault löscht sie dann nach zwei Tagen.")
        }
        .onAppear {
            if Self.requestCreate { Self.requestCreate = false; editing = CVCollectionDraft(existing: nil) }
        }
    }

    private var newCard: some View {
        Button { editing = CVCollectionDraft(existing: nil) } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                Text("Neuer Bereich").font(.system(size: 14.5, weight: .medium))
            }
            .foregroundStyle(VF.muted)
            .frame(maxWidth: .infinity).frame(height: 196)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(VF.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VF.beige, style: StrokeStyle(lineWidth: 1.3, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CVCollectionCard: View {
    let collection: CVCollection
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @ObservedObject var cv = ClipVaultClient.shared
    @State private var hover = false

    private var items: [CVItem] { cv.items.filter { $0.collection == collection.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CVCollectionIcon(collection: collection, size: 20)
                    .foregroundStyle(VF.ink)
                    .frame(width: 40, height: 40)
                    .background(VF.cardSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(VF.ink).lineLimit(1)
                    Text(items.count == 1 ? "1 Eintrag" : "\(items.count) Einträge").font(.system(size: 12.5)).foregroundStyle(VF.muted)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Öffnen", action: open)
                    Button("Umbenennen …", action: rename)
                    Divider()
                    Button("Löschen …", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.muted)
                        .frame(width: 28, height: 28)
                        .background(hover ? VF.buttonSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 7) {
                let latest = Array(items.prefix(3))
                if latest.isEmpty {
                    Text("Noch leer – Rechtsklick auf einen Eintrag → In Bereich legen.")
                        .font(.system(size: 12.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(latest) { i in
                    HStack(spacing: 8) {
                        Image(systemName: i.kind.symbol).font(.system(size: 10.5)).foregroundStyle(VF.muted).frame(width: 14)
                        Text(i.headline).font(.system(size: 13)).foregroundStyle(VF.ink.opacity(0.85)).lineLimit(1)
                            .cvHidden(collection.isSecret && !hover)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if collection.isSecret { CVTag(text: "Verschwommen", symbol: "eye.slash", color: VF.ink.opacity(0.7)) }
                Spacer()
                Text("Öffnen").font(.system(size: 12.5, weight: .medium)).foregroundStyle(VF.ink.opacity(hover ? 1 : 0.6))
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.ink.opacity(hover ? 1 : 0.6))
            }
        }
        .padding(18)
        .frame(height: 196)
        .hubCard(VF.card, radius: 14)
        .shadow(color: .black.opacity(hover ? 0.06 : 0), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(perform: open)
    }
}

struct CVCollectionDraft: Identifiable {
    let id = UUID()
    let existing: CVCollection?
}

/// Anlegen / Umbenennen
struct CVCollectionSheet: View {
    let draft: CVCollectionDraft
    let close: () -> Void
    @State private var name = ""
    @State private var symbol = "folder.fill"
    @State private var secret = false
    @ObservedObject var cv = ClipVaultClient.shared

    static let symbols = ["img:ki_logo.png", "sparkles", "brain.head.profile", "briefcase.fill", "lock.fill", "key.fill", "terminal.fill",
                          "chevron.left.forwardslash.chevron.right", "cursorarrow.rays", "folder.fill", "star.fill", "bolt.fill",
                          "doc.text.fill", "tag.fill", "person.fill", "heart.fill", "flag.fill", "music.note", "cross.fill", "house.fill"]

    var body: some View {
        PGSheet(title: draft.existing == nil ? "Neuer Bereich" : "Bereich umbenennen",
                subtitle: "Einträge in einem Bereich bleiben für immer. Ein Bereich „Passwörter“ zeigt Inhalte verschwommen.",
                confirm: draft.existing == nil ? "Anlegen" : "Speichern",
                canConfirm: !name.pgTrimmed.isEmpty,
                onCancel: close,
                onConfirm: {
                    if let e = draft.existing { cv.renameCollection(e, name: name.pgTrimmed, symbol: symbol) }
                    else { cv.createCollection(name: name.pgTrimmed, symbol: symbol, secret: secret ? true : nil) }
                    close()
                }) {
            PGField(label: "Name", text: $name, placeholder: "z. B. Arbeit, Prompts, Passwörter")
            if draft.existing == nil {
                Toggle(isOn: $secret) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inhalte verbergen").font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink)
                        Text("Wie „Passwörter“: verdeckt bis zum Drüberfahren, nach 24 h gelöscht (außer angeheftet).")
                            .font(.system(size: 12.5)).foregroundStyle(VF.muted)
                    }
                }
                .toggleStyle(.switch).tint(VF.black)
                .onChange(of: name) { _, n in if CVCollection.looksSecret(n) { secret = true } }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Symbol").font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 10), spacing: 8) {
                    ForEach(Self.symbols, id: \.self) { s in
                        Button { symbol = s } label: {
                            CVCollectionIcon(collection: CVCollection(id: "", name: "", symbol: s), size: 16)
                                .foregroundStyle(VF.ink)
                                .frame(width: 40, height: 40)
                                .background(symbol == s ? VF.selected : VF.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(symbol == s ? VF.ink : VF.hairline, lineWidth: symbol == s ? 1.5 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear {
            if let e = draft.existing { name = e.name; symbol = e.symbol }
        }
    }
}
