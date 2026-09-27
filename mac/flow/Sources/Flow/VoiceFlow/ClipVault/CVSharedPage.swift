import AppKit
import SwiftUI

// MARK: - Geteilt mit dem Partner (Name aus Einstellungen/ClipVault-Kopplung)

struct CVSharedPage: View {
    @ObservedObject var shared = CVShared.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Geteilt mit \(Identity.partner(.dative))").font(HubFont.title).foregroundStyle(VF.ink)
                    statusPill
                    Spacer()
                }
                .padding(.bottom, 22)

                CVBanner(image: "banner_clipvault_geteilt", palette: CVPalette.shared,
                         headline: "Ein Tresor für *zwei*.",
                         sub: "Was einer von euch teilt, liegt beim anderen sofort in der Zwischenablage-Liste – live, ohne Chat.") {
                    HStack(spacing: -8) {
                        CVAvatar(name: Identity.myName, size: 34).overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                        CVAvatar(name: Identity.partnerName ?? "Partner", size: 34).overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                    }
                }
                .padding(.bottom, 30)

                if !shared.status.isConnected {
                    CVPairingCard().padding(.bottom, 30)
                }
                itemsSection
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .onAppear { shared.start() }
    }

    private var statusPill: some View {
        let on = shared.status.isConnected
        return HStack(spacing: 6) {
            Circle().fill(on ? CVPalette.green : VF.muted.opacity(0.5)).frame(width: 7, height: 7)
                .overlay { if on { CVPulse() } }
            Text(shared.status.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(on ? VF.ink : VF.muted)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(VF.buttonSoft, in: Capsule())
        .padding(.top, 3)
    }

    @ViewBuilder private var itemsSection: some View {
        if shared.items.isEmpty {
            VStack(spacing: 14) {
                HubIllustration(name: "illu_snippet", fallback: "person.2", size: 110)
                Text("Noch nichts geteilt").font(VF.serif(30)).foregroundStyle(VF.ink)
                HStack(spacing: 6) {
                    Text("Rechtsklick auf einen Eintrag")
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    Text("Mit \(Identity.partner(.dative)) teilen").fontWeight(.semibold)
                }
                .font(.system(size: 14.5)).foregroundStyle(VF.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
            .hubCard(VF.card, radius: 14)
        } else {
            let pinned = shared.items.filter(\.pinned)
            let rest = shared.items.filter { !$0.pinned }
            LazyVStack(alignment: .leading, spacing: 0) {
                if !pinned.isEmpty { group("Angeheftet", pinned, first: true) }
                ForEach(Array(days(rest).enumerated()), id: \.element.0) { i, g in
                    group(CVFormat.dayLabel(g.0), g.1, first: pinned.isEmpty && i == 0)
                }
            }
        }
    }

    private func days(_ list: [SharedVaultItem]) -> [(Date, [SharedVaultItem])] {
        let cal = Calendar.current
        var order: [Date] = []; var map: [Date: [SharedVaultItem]] = [:]
        for i in list.sorted(by: { $0.createdAt > $1.createdAt }) {
            let d = cal.startOfDay(for: i.createdAt)
            if map[d] == nil { order.append(d) }
            map[d, default: []].append(i)
        }
        return order.map { ($0, map[$0]!) }
    }

    private func group(_ label: String, _ items: [SharedVaultItem], first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HubLabel(label).frame(height: 22).padding(.bottom, 10).padding(.top, first ? 0 : 28)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { j, it in
                    if j > 0 { Rectangle().fill(VF.hairline).frame(height: 1) }
                    CVSharedRow(item: it, fresh: shared.freshIDs.contains(it.id))
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
            }
            .hubCard(VF.card, radius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct CVSharedRow: View {
    let item: SharedVaultItem
    var fresh = false
    @ObservedObject var shared = CVShared.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            Text(HubFormat.time(item.createdAt)).font(.system(size: 13.5)).monospacedDigit().foregroundStyle(VF.muted)
                .frame(width: 62, alignment: .leading)
            CVAvatar(name: item.createdBy, size: 30).padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 3) {
                if let u = item.image {
                    CVThumb(url: u, maxPixel: 320).frame(width: 120, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if hover {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20).background(.black.opacity(0.5), in: Circle()).padding(5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showLarge() }
                        .help("Klick: groß ansehen")
                }
                if item.kind == .file {   // Datei: Icon, Name, Größe
                    HStack(spacing: 10) {
                        Image(nsImage: item.fileIcon).resizable().interpolation(.high).frame(width: 34, height: 34)
                            .opacity(item.file == nil ? 0.6 : 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: item.fileName ?? "Datei").font(.system(size: 14.5)).foregroundStyle(VF.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Text(item.sizeLabel).font(.system(size: 12)).foregroundStyle(VF.muted)
                        }
                    }
                } else if let t = item.text ?? item.fileName {
                    // Worum geht's? Art + Kernaussage fett, der Rohtext gedimmt darunter (lange Aufträge/Berichte waren unlesbar)
                    let g = SharedGistStore.shared.gist(for: item)
                    // nur bei langen/mehrzeiligen Texten – kurze stehen schon vollständig da (sonst doppelt)
                    if !g.gist.isEmpty && item.kind != .link && (t.count > 140 || t.contains("\n") || item.kind == .image) {
                        HStack(spacing: 7) {
                            SharedGistChip(gist: g, size: 10.5, onLight: true)
                            Text(verbatim: g.gist).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(VF.ink).lineLimit(1)
                        }
                        if item.kind != .image {
                            Text(verbatim: SharedGistMaker.clean(String(t.prefix(400))))
                                .font(.system(size: 13)).foregroundStyle(VF.muted).lineLimit(2)
                        }
                    } else {
                        Text(verbatim: t).font(.system(size: 14.5)).foregroundStyle(item.kind == .link ? CVPalette.link : VF.ink).lineLimit(2)
                    }
                }
                Text(item.fromMe ? "Du hast geteilt" : "\(item.createdBy) hat geteilt")
                    .font(.system(size: 12)).foregroundStyle(VF.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if hover {
                    if item.kind == .image, item.image != nil {
                        HubIconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 13, color: VF.muted, help: "Groß ansehen") { showLarge() }
                    }
                    HubIconButton(symbol: "doc.on.doc", size: 13, color: VF.muted, help: "Kopieren") { shared.copy(item) }
                    HubIconButton(symbol: item.pinned ? "pin.slash" : "pin", size: 13, color: VF.muted, help: item.pinned ? "Lösen" : "Anheften") {
                        shared.setPinned(item.id, !item.pinned)
                    }
                    HubIconButton(symbol: "trash", size: 13, color: VF.muted, help: "Für beide entfernen") { shared.remove(item.id) }
                } else if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(VF.ink.opacity(0.55)).frame(width: 27, height: 27)
                }
            }
            .frame(minWidth: 86, alignment: .trailing)
        }
        .padding(.leading, 17).padding(.trailing, 10).padding(.vertical, 12)
        .background(fresh ? VF.teal4 : (hover ? VF.panel : VF.card))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { shared.copy(item) }
    }

    /// Alle geteilten Bilder (neueste zuerst, wie die Liste) – ← → blättert
    private func showLarge() {
        let all = shared.items.sorted { ($0.pinned ? 1 : 0, $0.createdAt) > ($1.pinned ? 1 : 0, $1.createdAt) }.compactMap(CVViewerEntry.from)
        CVImageViewer.shared.open(all.isEmpty ? CVViewerEntry.from(item).map { [$0] } ?? [] : all, id: item.id)
    }
}

/// Kopplungskarte „Mit <Partner> verbinden“ – Code + QR (echter Ablauf kommt vom Sync-Agenten)
struct CVPairingCard: View {
    @ObservedObject var shared = CVShared.shared

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mit \(Identity.partner(.dative)) verbinden").font(VF.serif(30)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(VF.ink)
                Text("Einmal koppeln, danach teilt ihr mit einem Rechtsklick.")
                    .font(.system(size: 14.5)).foregroundStyle(VF.muted).padding(.top, 4)
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Klick auf **Code anzeigen**.")
                    step(2, "\(Identity.partner(.nominative, capitalized: true)) öffnet bei sich **ClipVault → Geteilt → Code eingeben** – oder scannt den QR-Code.")
                    step(3, "Fertig. Neue geteilte Einträge erscheinen bei euch beiden sofort.")
                }
                .padding(.top, 22)
                HStack(spacing: 10) {
                    if case .pairing = shared.status {
                        Button("Abbrechen") { shared.cancelPairing() }.buttonStyle(HubSoftButton(height: 36))
                    } else {
                        Button("Code anzeigen") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { shared.beginPairing() } }
                            .buttonStyle(HubBlackButton(height: 36))
                    }
                    Text("Ende-zu-Ende verschlüsselt").font(.system(size: 12)).foregroundStyle(VF.muted)
                        .padding(.leading, 4)
                }
                .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            codeBox
        }
        .padding(28)
        .hubCard(VF.cardSoft, radius: 14)
    }

    @ViewBuilder private var codeBox: some View {
        VStack(spacing: 12) {
            if case .pairing(let code, let payload) = shared.status {
                if let qr = CVQR.image(payload, size: 150) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                }
                // echter Code ist lang (traegt Server, Tresor und Schluessel) -> klein + Kopier-Knopf
                Text(code).font(.system(size: code.count > 16 ? 9 : 24, weight: .semibold, design: .monospaced))
                    .tracking(code.count > 16 ? 0 : 2).foregroundStyle(VF.ink)
                    .lineLimit(code.count > 16 ? 6 : 1).textSelection(.enabled)
                if code.count > 16 {
                    Button("Code kopieren") {
                        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(code, forType: .string)
                        pb.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))   // nicht in den Verlauf
                        ClipVaultClient.shared.show(CVToast(text: "Code kopiert – nur privat an \(Identity.partner(.accusative)) schicken", symbol: "doc.on.doc"))
                    }.buttonStyle(HubSoftButton(height: 30))
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Warte auf \(Identity.partner(.accusative)) …").font(.system(size: 12)).foregroundStyle(VF.muted)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(VF.beige, style: StrokeStyle(lineWidth: 1.3, dash: [5, 4]))
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode").font(.system(size: 44, weight: .light)).foregroundStyle(VF.muted.opacity(0.7))
                        Text("Code erscheint hier").font(.system(size: 12)).foregroundStyle(VF.muted)
                    }
                }
                .frame(width: 150, height: 150)
                Text("––– –––").font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(VF.muted.opacity(0.4))
            }
        }
        .padding(20)
        .frame(width: 214)
        .background(VF.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(VF.hairline))
    }

    private func step(_ n: Int, _ md: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(VF.black, in: Circle())
            PG.richBody(md.replacingOccurrences(of: "**", with: "**"), size: 14.5).foregroundStyle(VF.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CVAvatar: View {
    let name: String
    var size: CGFloat = 30
    var body: some View {
        // Ich = lila, Partner = grün; gleicher Anfangsbuchstabe (Lena/Nico) → Partner mit zwei Buchstaben („Ja“)
        let me = Identity.isMe(name)
        let other = me ? (Identity.partnerName ?? "") : Identity.myName
        let clash = !me && !other.isEmpty && other.prefix(1).lowercased() == name.prefix(1).lowercased()
        Text(clash ? String(name.prefix(2)) : String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(me ? VF.purple : VF.teal2, in: Circle())
    }
}

/// Pulsierender Ring für „live“
struct CVPulse: View {
    @State private var on = false
    var body: some View {
        Circle().stroke(CVPalette.green, lineWidth: 1.5)
            .scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.8)
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true } }
    }
}
