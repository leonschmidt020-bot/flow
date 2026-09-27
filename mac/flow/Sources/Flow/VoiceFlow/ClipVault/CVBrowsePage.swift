import AppKit
import SwiftUI

// MARK: - Wurzel: welche ClipVault-Seite ist offen

struct CVRootPage: View {
    @ObservedObject var state = CVHubState.shared
    @ObservedObject var cv = ClipVaultClient.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            VF.panel
            page.id(pageID)
            if let t = cv.toast {
                CVToastView(toast: t)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
            }
            CVImageViewerOverlay().zIndex(10)   // Bild groß ansehen (Leuchtkasten)
        }
        .onAppear { cv.start(); CVShared.shared.start() }
        .onChange(of: pageID) { _, _ in CVImageViewer.shared.close() }
    }

    private var pageID: String { state.section.rawValue + (state.openCollection ?? "") }

    @ViewBuilder private var page: some View {
        switch state.section {
        case .verlauf: CVBrowsePage(scope: .verlauf)
        case .angeheftet: CVBrowsePage(scope: .angeheftet)
        case .bilder: CVBrowsePage(scope: .bilder)
        case .links: CVBrowsePage(scope: .links)
        case .dateien: CVBrowsePage(scope: .dateien)
        case .bereiche:
            if let id = state.openCollection { CVBrowsePage(scope: .collection(id)) } else { CVCollectionsPage() }
        case .geteilt: CVSharedPage()
        case .einstellungen: CVSettingsPage()
        }
    }
}

enum CVScope: Equatable {
    case verlauf, angeheftet, bilder, links, dateien
    case collection(String)
}

enum CVTypeFilter: String, CaseIterable, Identifiable {
    case alle, text, links, bilder, dateien, ki, diktat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .alle: return "Alle"
        case .text: return "Text"
        case .links: return "Links"
        case .bilder: return "Bilder"
        case .dateien: return "Dateien"
        case .ki: return "KI"
        case .diktat: return "Diktat"
        }
    }
    var symbol: String? {
        switch self {
        case .alle: return nil
        case .text: return "text.alignleft"
        case .links: return "link"
        case .bilder: return "photo"
        case .dateien: return "doc"
        case .ki: return "sparkles"
        case .diktat: return "waveform"
        }
    }
    func matches(_ i: CVItem) -> Bool {
        switch self {
        case .alle: return true
        case .text: return i.kind == .text
        case .links: return i.hasLink
        case .bilder: return i.kind == .image
        case .dateien: return i.kind == .file
        case .ki: return i.isAI
        case .diktat: return i.isVoice
        }
    }
}

// MARK: - Liste + Vorschau

struct CVBrowsePage: View {
    let scope: CVScope
    @ObservedObject var cv = ClipVaultClient.shared
    @ObservedObject var state = CVHubState.shared
    @AppStorage("vf.cv.banner.hidden") private var bannerHidden = false
    @State private var query = ""
    @State private var filter: CVTypeFilter = .alle
    @State private var adding = false
    @State private var narrow = false
    @State private var sheetItem: CVItem?
    @FocusState private var listFocused: Bool

    var body: some View {
        GeometryReader { g in
            let previewW: CGFloat = g.size.width > 1100 ? 400 : (g.size.width > 860 ? 340 : 0)
            HStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity)
                if previewW > 0 {
                    Rectangle().fill(VF.hairline).frame(width: 1)
                    CVPreviewPane(item: selected, imageList: imageEntries)
                        .frame(width: previewW)
                        .id(selected?.id ?? "none")
                        .transition(.opacity)
                }
            }
            .onAppear { narrow = previewW == 0 }
            .onChange(of: previewW) { _, w in narrow = w == 0 }
        }
        .sheet(item: $sheetItem) { it in
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Fertig") { sheetItem = nil }.buttonStyle(HubSoftButton(height: 30)).keyboardShortcut(.cancelAction) }
                    .padding(12)
                CVPreviewPane(item: cv.item(it.id) ?? it, imageList: imageEntries) { list, id in
                    sheetItem = nil   // Leuchtkasten liegt über der Seite, nicht über dem Blatt
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CVImageViewer.shared.open(list, id: id, onShow: selectEntry) }
                }
            }
            .frame(width: 440, height: 620)
            .background(VF.card)
            .environment(\.colorScheme, .light)
        }
        .sheet(isPresented: $adding) { CVAddTextSheet(isPresented: $adding, collection: collectionID) }
        .onAppear(perform: ensureSelection)
        .onChange(of: cv.items) { _, _ in ensureSelection() }
    }

    // MARK: Daten

    private var collectionID: String? { if case .collection(let id) = scope { return id }; return nil }

    private var base: [CVItem] {
        switch scope {
        case .verlauf: return cv.items.filter { $0.collection == nil }
        case .angeheftet: return cv.items.filter(\.pinned)
        case .bilder: return cv.items.filter { $0.kind == .image && !cv.isSecret($0) }
        case .links: return cv.items.filter { $0.hasLink && !cv.isSecret($0) }
        case .dateien: return cv.items.filter { $0.kind == .file && !cv.isSecret($0) }
        case .collection(let id): return cv.items.filter { $0.collection == id }
        }
    }

    private var showsTypeChips: Bool {
        switch scope { case .verlauf, .angeheftet, .collection: return true; default: return false }
    }

    private var visible: [CVItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return base.filter { filter.matches($0) && (q.isEmpty || $0.searchBlob.localizedCaseInsensitiveContains(q)) }
    }

    private var selected: CVItem? { cv.item(state.selectedID).flatMap { i in visible.contains(i) ? i : nil } }

    /// Alle sichtbaren Bilder in Listen-Reihenfolge (← → im Leuchtkasten / Quick Look); Passwort-Bereich nie
    private var imageEntries: [CVViewerEntry] {
        groups.flatMap(\.items).filter { !cv.isSecret($0) }.compactMap(CVViewerEntry.from)
    }

    private func selectEntry(_ e: CVViewerEntry) { state.selectedID = e.id }

    /// Leertaste = Quick Look auf dem gewählten Bild (wie im Finder)
    private func quickLookSelected() -> KeyPress.Result {
        guard let s = selected, s.kind == .image else { return .ignored }
        var list = imageEntries
        if !list.contains(where: { $0.id == s.id }), let one = CVViewerEntry.from(s) { list = [one] }
        guard !list.isEmpty else { return .ignored }
        CVQuickLook.shared.toggle(list, id: s.id, onShow: selectEntry)
        return .handled
    }

    private func ensureSelection() {
        if selected == nil { state.selectedID = visible.first?.id }
    }

    private var title: String {
        switch scope {
        case .verlauf: return "Verlauf"
        case .angeheftet: return "Angeheftet"
        case .bilder: return "Bilder"
        case .links: return "Links"
        case .dateien: return "Dateien"
        case .collection(let id): return cv.collection(id)?.name ?? "Bereich"
        }
    }

    private var groups: [(key: String, label: String, items: [CVItem])] {
        let v = visible
        var out: [(String, String, [CVItem])] = []
        var rest = v
        if scope == .verlauf && query.isEmpty {
            let pinned = v.filter(\.pinned)
            if !pinned.isEmpty { out.append(("pinned", "Angeheftet", pinned)); rest = v.filter { !$0.pinned } }
        }
        let cal = Calendar.current
        var order: [Date] = []
        var map: [Date: [CVItem]] = [:]
        for i in rest.sorted(by: { $0.date > $1.date }) {
            let d = cal.startOfDay(for: i.date)
            if map[d] == nil { order.append(d) }
            map[d, default: []].append(i)
        }
        for d in order { out.append((d.description, CVFormat.dayLabel(d), map[d]!)) }
        return out
    }

    // MARK: Linke Spalte

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 22)
                    if scope == .verlauf && !bannerHidden {
                        banner.padding(.bottom, 26)
                    }
                    toolbar.padding(.bottom, 22)
                    content
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 34).padding(.bottom, 60)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.return) { if let s = selected { cv.copy(s) }; return .handled }
            .onKeyPress(.space) { quickLookSelected() }
        }
    }

    private func move(_ d: Int, _ proxy: ScrollViewProxy) {
        let flat = groups.flatMap(\.items)
        guard !flat.isEmpty else { return }
        let idx = flat.firstIndex { $0.id == state.selectedID } ?? -1
        let n = max(0, min(flat.count - 1, idx + d))
        state.selectedID = flat[n].id
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(flat[n].id, anchor: .center) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if case .collection(let id) = scope {
                Button { state.go(.bereiche) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(VF.muted)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Alle Bereiche")
                if let c = cv.collection(id) { CVCollectionIcon(collection: c, size: 20).foregroundStyle(VF.ink) }
            }
            Text(title).font(HubFont.title).foregroundStyle(VF.ink)
            Text("\(base.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(VF.muted).monospacedDigit()
                .padding(.top, 3)
            Spacer()
            if scope == .verlauf || collectionID != nil {
                Button { adding = true } label: {
                    HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)); Text("Neuer Eintrag") }
                }
                .buttonStyle(HubBlackButton(height: 34))
            }
        }
    }

    private var banner: some View {
        let stats = "\(cv.items.count) Einträge, \(cv.items.filter(\.pinned).count) angeheftet"
        return CVBanner(headline: "Alles, was du *kopierst*, an einem Ort.",
                        sub: "Zwei Tage lang alles, Angeheftetes und Bereiche für immer · \(stats)",
                        onClose: { withAnimation { bannerHidden = true } }) {
            Button("Bereiche ansehen") { state.go(.bereiche) }.buttonStyle(HubBannerButton())
            HStack(spacing: 5) {
                HubKeycap("⌘"); HubKeycap("⇧"); HubKeycap("V")
                Text("überall").font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white.opacity(0.9)).padding(.leading, 3)
            }
            .padding(.leading, 8)
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            CVSearchField(text: $query, prompt: "\(title) durchsuchen …")
            if showsTypeChips {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(CVTypeFilter.allCases) { f in
                            let n = f == .alle ? base.count : base.filter { f.matches($0) }.count
                            if f == .alle || n > 0 {
                                CVChip(title: f.title, symbol: f.symbol, count: f == .alle ? nil : n, selected: filter == f) {
                                    withAnimation(.easeOut(duration: 0.15)) { filter = f }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder private var content: some View {
        let gs = groups
        if gs.isEmpty {
            emptyCard
        } else if scope == .bilder {
            imageGrid(gs)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(gs.enumerated()), id: \.element.key) { i, g in
                    HStack(spacing: 6) {
                        if g.key == "pinned" { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(VF.muted) }
                        HubLabel(g.label)
                        Spacer()
                        Text("\(g.items.count)").font(.system(size: 12)).foregroundStyle(VF.muted.opacity(0.8)).monospacedDigit()
                    }
                    .frame(height: 22).padding(.bottom, 10)
                    .padding(.top, i == 0 ? 0 : 28)
                    VStack(spacing: 0) {
                        ForEach(Array(g.items.enumerated()), id: \.element.id) { j, item in
                            if j > 0 { Rectangle().fill(VF.hairline).frame(height: 1) }
                            CVItemRow(item: item, selected: item.id == state.selectedID,
                                      showCollection: collectionID == nil, fresh: cv.freshIDs.contains(item.id)) {
                                state.selectedID = item.id
                                listFocused = true
                                if narrow { sheetItem = item }
                            }
                            .id(item.id)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .hubCard(VF.card, radius: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func imageGrid(_ gs: [(key: String, label: String, items: [CVItem])]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(gs.enumerated()), id: \.element.key) { i, g in
                HubLabel(g.label).frame(height: 22).padding(.bottom, 10).padding(.top, i == 0 ? 0 : 26)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                    ForEach(g.items) { item in
                        CVImageTile(item: item, selected: item.id == state.selectedID) {
                            state.selectedID = item.id
                            listFocused = true
                            if narrow { sheetItem = item }
                        } onOpen: {
                            state.selectedID = item.id
                            let list = imageEntries
                            CVImageViewer.shared.open(list.isEmpty ? CVViewerEntry.from(item).map { [$0] } ?? [] : list, id: item.id, onShow: selectEntry)
                        }
                            .id(item.id)
                    }
                }
            }
        }
    }

    private var emptyCard: some View {
        let searching = !query.isEmpty || filter != .alle
        let (t, s): (String, String) = {
            if searching { return ("Nichts gefunden", "Versuch ein anderes Wort oder einen anderen Filter.") }
            switch scope {
            case .verlauf: return ("Noch nichts kopiert", "Kopier irgendwas mit ⌘C – es erscheint sofort hier.")
            case .angeheftet: return ("Nichts angeheftet", "Fahr über einen Eintrag und klick die Nadel – Angeheftetes bleibt für immer.")
            case .bilder: return ("Keine Bilder", "Kopierte Bilder und Screenshots landen hier.")
            case .links: return ("Keine Links", "Kopierte Links erscheinen hier mit Vorschau.")
            case .dateien: return ("Keine Dateien", "Kopier eine Datei im Finder – ClipVault behält eine Kopie.")
            case .collection: return ("Dieser Bereich ist leer", "Rechtsklick auf einen Eintrag → In Bereich legen.")
            }
        }()
        return HStack(spacing: 18) {
            HubIllustration(name: "illu_leer", fallback: "tray", size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(t).font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                Text(s).font(HubFont.small).foregroundStyle(VF.muted)
            }
            Spacer()
        }
        .padding(18)
        .hubCard(VF.card, radius: 12)
    }
}

/// Kachel auf der Bilder-Seite
struct CVImageTile: View {
    let item: CVItem
    let selected: Bool
    let onSelect: () -> Void
    /// Doppelklick: groß ansehen
    var onOpen: () -> Void = {}
    @ObservedObject var cv = ClipVaultClient.shared
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CVThumb(url: cv.imageURL(item), maxPixel: 320)
                .frame(height: 118)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if hover {
                        HStack(spacing: 4) {
                            tileButton("arrow.up.left.and.arrow.down.right", "Groß ansehen (Doppelklick)", onOpen)
                            tileButton("doc.on.doc", "Kopieren") { cv.copy(item) }
                            tileButton(item.pinned ? "pin.slash" : "pin", item.pinned ? "Lösen" : "Anheften") { cv.setPinned(item, !item.pinned) }
                        }
                        .padding(7)
                    } else if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 10.5)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(.black.opacity(0.45), in: Circle()).padding(7)
                    }
                }
            HStack(spacing: 6) {
                Text(HubFormat.time(item.date)).font(.system(size: 12)).monospacedDigit().foregroundStyle(VF.muted)
                if item.ocr != nil { Image(systemName: "text.viewfinder").font(.system(size: 11)).foregroundStyle(VF.muted).help("Text erkannt") }
                Spacer(minLength: 0)
                if let c = cv.collection(item.collection) { CVCollectionIcon(collection: c, size: 11).foregroundStyle(VF.muted) }
            }
            .padding(.horizontal, 10).frame(height: 30)
        }
        .background(VF.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? VF.ink : VF.hairline, lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(hover ? 0.07 : 0), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .contextMenu { CVItemMenu(item: item) }
    }

    private func tileButton(_ s: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: s).font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.ink)
                .frame(width: 26, height: 26).background(.white.opacity(0.92), in: Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}
