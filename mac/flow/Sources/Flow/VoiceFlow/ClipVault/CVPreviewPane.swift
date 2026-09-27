import AppKit
import SwiftUI

// MARK: - Vorschau rechts: ganzer Inhalt, Metadaten, Aktionen

struct CVPreviewPane: View {
    let item: CVItem?
    /// Bilder der Liste (← → im Leuchtkasten)
    var imageList: [CVViewerEntry] = []
    /// Anders öffnen (z. B. aus dem Blatt im schmalen Fenster); Standard: Leuchtkasten über der Seite
    var openImage: (([CVViewerEntry], String) -> Void)? = nil
    @ObservedObject var cv = ClipVaultClient.shared
    @State private var editing = false
    @State private var draft = ""
    @State private var revealed = false
    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            VF.card
            if let item {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            top(item).padding(.bottom, 18)
                            content(item)
                            meta(item).padding(.top, 24)
                        }
                        .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 20)
                    }
                    .scrollIndicators(.automatic)
                    Rectangle().fill(VF.hairline).frame(height: 1)
                    actions(item).padding(.horizontal, 20).padding(.vertical, 16)
                }
            } else {
                VStack(spacing: 12) {
                    HubIllustration(name: "illu_leer", fallback: "doc.on.clipboard", size: 92)
                    Text("Wähl einen Eintrag").font(VF.serif(26)).foregroundStyle(VF.ink)
                    Text("Hier siehst du ihn ganz – mit allem, was du damit tun kannst.")
                        .font(HubFont.small).foregroundStyle(VF.muted).multilineTextAlignment(.center).frame(maxWidth: 240)
                }
            }
        }
        .alert("Eintrag löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { if let item { cv.delete(item) } }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Er verschwindet aus ClipVault. Das lässt sich nicht rückgängig machen.") }
    }

    // MARK: Kopf

    private func top(_ item: CVItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                CVTag(text: item.kind.label, symbol: item.kind.symbol, color: VF.ink.opacity(0.75))
                if item.isAI { CVTag(text: "von KI", symbol: "sparkles", color: CVPalette.ai) }
                if item.isVoice { CVTag(text: item.source ?? "Diktat", symbol: "waveform", color: CVPalette.voice) }
                if item.isPhone { CVTag(text: "iPhone", symbol: "iphone", color: CVPalette.phone) }
                if item.pinned { CVTag(text: "Angeheftet", symbol: "pin.fill", color: VF.ink.opacity(0.75)) }
                if item.shared { CVTag(text: "Geteilt", symbol: "person.2.fill", color: CVPalette.link) }
            }
            Text(HubFormat.date(item.date, "EEEE, d. MMMM yyyy · HH:mm"))
                .font(.system(size: 13)).foregroundStyle(VF.muted)
        }
    }

    // MARK: Inhalt je Art

    @ViewBuilder private func content(_ item: CVItem) -> some View {
        switch item.kind {
        case .text: textBody(item)
        case .link: linkBody(item)
        case .image: imageBody(item)
        case .file: fileBody(item)
        }
    }

    @ViewBuilder private func textBody(_ item: CVItem) -> some View {
        let text = item.text ?? ""
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = cv.isSecret(item)
        if editing {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $draft)
                    .font(.system(size: 14.5))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 220)
                    .background(VF.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(VF.ink.opacity(0.25)))
                HStack {
                    Text("\(draft.count) Zeichen").font(.system(size: 12)).foregroundStyle(VF.muted)
                    Spacer()
                    Button("Abbrechen") { editing = false }.buttonStyle(HubSoftButton(height: 30)).keyboardShortcut(.cancelAction)
                    Button("Speichern") { cv.edit(item, text: draft); editing = false }
                        .buttonStyle(HubBlackButton(height: 30)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft == text)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: shown)
                    .font(looksLikeCode(text) ? .system(size: 13, design: .monospaced) : .system(size: 15))
                    .foregroundStyle(VF.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .cvHidden(secret && !revealed)
                    .overlay {
                        if secret && !revealed {
                            Label("Zum Anzeigen drüberfahren", systemImage: "eye")
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(VF.ink)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(VF.card.opacity(0.9), in: Capsule())
                                .overlay(Capsule().stroke(VF.hairline))
                        }
                    }
                    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { revealed = h } }
                Text("\(text.count) Zeichen · \(CVFormat.wordsLabel(text)) · \(lines(text))")
                    .font(.system(size: 12)).foregroundStyle(VF.muted)
            }
        }
    }

    private func lines(_ t: String) -> String { let n = t.components(separatedBy: "\n").count; return n == 1 ? "1 Zeile" : "\(n) Zeilen" }

    private func looksLikeCode(_ s: String) -> Bool {
        let hits = ["{", "}", "();", "=>", "func ", "let ", "import ", "</", "$ ", "--", "==", "    "].filter { s.contains($0) }.count
        return hits >= 3
    }

    @ViewBuilder private func linkBody(_ item: CVItem) -> some View {
        let url = item.url!
        VStack(alignment: .leading, spacing: 12) {
            if let p = cv.linkPreviewImageURL(url) {
                CVThumb(url: p, maxPixel: 900)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(VF.hairline))
            }
            if let t = cv.linkTitle(url) {
                Text(t).font(.system(size: 17, weight: .semibold)).foregroundStyle(VF.ink).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(CVPalette.link)
                Text(url.host ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(CVPalette.link)
            }
            Text(verbatim: url.absoluteString)
                .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(VF.muted)
                .textSelection(.enabled).lineLimit(4)
            Button { NSWorkspace.shared.open(url) } label: {
                Label("Im Browser öffnen", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(HubOutlineButton(height: 32))
        }
    }

    @ViewBuilder private func imageBody(_ item: CVItem) -> some View {
        let u = cv.imageURL(item)
        VStack(alignment: .leading, spacing: 14) {
            CVThumb(url: u, maxPixel: cv.isSecret(item) && !revealed ? 12 : 1200, contentMode: cv.isSecret(item) && !revealed ? .fill : .fit)
                .onHover { h in if cv.isSecret(item) { withAnimation(.easeOut(duration: 0.15)) { revealed = h } } }
                .aspectRatio(u.flatMap(CVThumbs.pixelSize).map { max(0.4, $0.width / max(1, $0.height)) } ?? 1.4, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 380)
                .background(VF.cardSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(VF.hairline))
                .overlay(alignment: .topTrailing) {
                    if !(cv.isSecret(item) && !revealed), u != nil {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(.black.opacity(0.45), in: Circle())
                            .padding(8).allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showLarge(item) }
                .help("Klick: groß ansehen · Leertaste in der Liste: Quick Look")
            if let e = CVViewerEntry.from(item) {
                ViewThatFits(in: .horizontal) {
                    imageButtons(e, short: false)
                    imageButtons(e, short: true)
                }
            }
            if let ocr = item.ocr {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HubLabel("Erkannter Text")
                        Spacer()
                        Button { cv.copyText(ocr) } label: { Label("Text kopieren", systemImage: "doc.on.doc") }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(VF.muted)
                    }
                    Text(verbatim: ocr).font(.system(size: 13.5)).foregroundStyle(VF.ink).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(VF.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } else {
                HStack(spacing: 10) {
                    Button { cv.requestOCR(item) } label: {
                        Label(item.ocrChecked ? "Nochmal erkennen" : "Text im Bild erkennen", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(HubOutlineButton(height: 32))
                    if item.ocrChecked { Text("Kein Text gefunden").font(.system(size: 12.5)).foregroundStyle(VF.muted) }
                }
            }
        }
    }

    private func imageButtons(_ e: CVViewerEntry, short: Bool) -> some View {
        HStack(spacing: 6) {
            Button { CVImageActions.open(e) } label: { Label("Öffnen", systemImage: "arrow.up.forward.app").lineLimit(1) }
                .buttonStyle(HubOutlineButton(height: 30)).help("Im Standardprogramm öffnen (z. B. Vorschau)")
            Button { CVImageActions.reveal(e) } label: { Label(short ? "Finder" : "Im Finder zeigen", systemImage: "folder").lineLimit(1) }
                .buttonStyle(HubOutlineButton(height: 30)).help("Im Finder zeigen")
            Button { CVImageActions.saveAs(e) } label: { Label(short ? "Sichern …" : "Sichern unter …", systemImage: "square.and.arrow.down").lineLimit(1) }
                .buttonStyle(HubOutlineButton(height: 30)).help("Sichern unter …")
        }
        .font(.system(size: 12.5, weight: .medium))
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }

    /// Bild groß: Leuchtkasten mit allen Bildern der Liste (Passwort-Bereich: nur dieses eine)
    private func showLarge(_ item: CVItem) {
        guard let one = CVViewerEntry.from(item) else { return }
        let list = !cv.isSecret(item) && imageList.contains(where: { $0.id == item.id }) ? imageList : [one]
        if let openImage { openImage(list, item.id) } else {
            CVImageViewer.shared.open(list, id: item.id) { e in CVHubState.shared.selectedID = e.id }
        }
    }

    @ViewBuilder private func fileBody(_ item: CVItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.files, id: \.self) { f in
                let u = cv.fileURL(f)
                HStack(spacing: 12) {
                    Image(nsImage: CVFileIcon.icon(u)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.system(size: 14.5, weight: .medium)).foregroundStyle(VF.ink).lineLimit(2)
                        Text([CVFileIcon.size(u).map(CVFormat.bytes), FileManager.default.fileExists(atPath: f.orig) ? nil : "Original verschoben – Kopie in ClipVault"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(VF.muted)
                    }
                    Spacer(minLength: 0)
                    HubIconButton(symbol: "magnifyingglass", size: 13, color: VF.muted, help: "Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    }
                    HubIconButton(symbol: "arrow.up.forward.app", size: 13, color: VF.muted, help: "Öffnen") { NSWorkspace.shared.open(u) }
                }
                .padding(10)
                .background(VF.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: Metadaten

    private func meta(_ item: CVItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HubLabel("Details").padding(.bottom, 8)
            row("Kopiert", CVFormat.relative(item.date))
            row("Quelle", item.source ?? "Zwischenablage")
            row("Bereich", cv.collection(item.collection)?.name ?? "–")
            if item.kind == .image, let u = cv.imageURL(item) {
                if let s = CVThumbs.pixelSize(u) { row("Größe", "\(Int(s.width)) × \(Int(s.height)) px") }
                if let b = CVFileIcon.size(u) { row("Datei", CVFormat.bytes(b)) }
            }
            if let e = item.edited { row("Bearbeitet", CVFormat.relative(e)) }
            if item.shared { row("Geteilt", "mit \(Identity.partner(.dative))") }
            row("Bleibt", cv.expiry(item).map { "bis \(HubFormat.date($0, "EEE, HH:mm"))" } ?? "für immer")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 13)).foregroundStyle(VF.muted).frame(width: 78, alignment: .leading)
            Text(v).font(.system(size: 13)).foregroundStyle(VF.ink).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .overlay(alignment: .bottom) { Rectangle().fill(VF.hairline.opacity(0.7)).frame(height: 1) }
    }

    // MARK: Aktionen

    private func actions(_ item: CVItem) -> some View {
        VStack(spacing: 10) {
            Button { cv.copy(item) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .semibold))
                    Text("Kopieren")
                    Spacer()
                    Text("⏎").font(.system(size: 13, weight: .medium)).opacity(0.55)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(HubBlackButton(height: 38))
            HStack(spacing: 6) {
                action(item.pinned ? "pin.slash" : "pin", item.pinned ? "Lösen" : "Anheften") { cv.setPinned(item, !item.pinned) }
                Menu {
                    CVCollectionMenu(item: item)
                } label: {
                    actionLabel("square.stack.3d.up", "Bereich ▸")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .help("In Bereich legen")
                if item.shared {
                    action("person.2.slash", "Nicht teilen") { cv.unshare(item) }
                } else {
                    action("person.2", "Teilen") { cv.share(item) }
                }
                if item.kind == .text && !cv.isSecret(item) {
                    action("pencil", "Bearbeiten") { draft = item.text ?? ""; editing = true }
                }
                action("trash", "Löschen", tint: CVPalette.danger) { confirmDelete = true }
            }
        }
    }

    private func action(_ s: String, _ t: String, tint: Color = VF.ink, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { actionLabel(s, t, tint: tint) }.buttonStyle(.plain).help(t == "Teilen" ? "Mit \(Identity.partner(.dative)) teilen" : t)
    }

    private func actionLabel(_ s: String, _ t: String, tint: Color = VF.ink) -> some View {
        VStack(spacing: 4) {
            Image(systemName: s).font(.system(size: 14))
            Text(t).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(VF.buttonSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Untermenü „In Bereich legen“
struct CVCollectionMenu: View {
    let item: CVItem
    @ObservedObject var cv = ClipVaultClient.shared
    var body: some View {
        ForEach(cv.collections) { c in
            Button { cv.setCollection(item, c.id) } label: {
                if item.collection == c.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
            }
        }
        if item.collection != nil {
            Divider()
            Button("Aus Bereich nehmen") { cv.setCollection(item, nil) }
        }
        Divider()
        Button("Neuer Bereich …") { CVHubState.shared.go(.bereiche); CVCollectionsPage.requestCreate = true }
    }
}
