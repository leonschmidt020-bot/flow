import AppKit
import Combine
import ImageIO
import SwiftUI

// MARK: - Neu vom Partner: grüner Rahmen an der Pille + Liste „Neu von Nico“
//
// Teilt der Partner etwas in den gemeinsamen ClipVault-Tresor, bekommt die ruhende Pille einen grünen Rahmen (PillRing).
// Maus ~0,4 s auf der Pille (oder Klick auf den Rahmen) → die Liste wächst wie die Meldungskarten aus der Pille (VFMorph).
//
// GESEHEN (27.09.2026, Lenas Meldung „Rahmen geht weg, obwohl ich nichts kopiert habe“):
//   Ein Eintrag gilt NUR als gesehen, wenn er kopiert wurde, „Alle gesehen“ / „In ClipVault öffnen“ geklickt wurde,
//   oder die Maus mindestens 1,5 s IN der Liste war, während der Eintrag sichtbar war. Über die Pille fahren zählt nicht.
//   Vorher reichte „Liste ≥ 1 s offen“ – und die Liste öffnet schon beim Überfahren der Pille.
// STABIL: Ein Korridor aus Pille + Lücke + Liste hält die Liste offen; erst nach 0,8 s außerhalb geht sie zu.
//   Nach dem Schließen öffnet sie erst wieder, wenn die Maus die Pille einmal verlassen hat (keine Auf-zu-Schleifen).
//
// „Gesehen“ steht in ~/.config/flow-clipvault/shared-seen.json – dieselbe Datei nutzt ClipVault (Panel → Geteilt).

struct SharedSeenState: Codable {
    var baseline: Double
    var seen: [String]

    static var url: URL { ClipVaultClient.base.appendingPathComponent("shared-seen.json") }

    static func load() -> SharedSeenState {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(SharedSeenState.self, from: d) { return s }
        // Erster Start: Älteres gilt als gesehen – was der Partner in den letzten 24 h geteilt hat, zählt noch als neu
        // (sonst geht ein Eintrag verloren, der kurz vor dem ersten Start dieser Version ankam)
        let s = SharedSeenState(baseline: Date().timeIntervalSince1970 - 86400, seen: [])
        s.save()
        return s
    }

    func save() {
        var s = self
        if s.seen.count > 1000 { s.seen = Array(s.seen.suffix(1000)) }
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: SharedSeenState.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: SharedSeenState.url.path)
        DistributedNotificationCenter.default().postNotificationName(.init("app.flowdictation.clipvault.changed"), object: nil,
                                                                      userInfo: nil, deliverImmediately: true)
    }

    func isNew(_ i: SharedVaultItem) -> Bool {
        !i.fromMe && i.createdAt.timeIntervalSince1970 > baseline && !seen.contains(i.id)
    }
}

final class SharedInboxModel: ObservableObject {
    @Published var items: [SharedVaultItem] = []
    /// Schon kopiert (bleiben sichtbar mit „Kopiert ✓“, bis die Liste zugeht – nichts rutscht)
    @Published var copied: Set<String> = []
    /// Lang genug angesehen (Maus ≥ 1,5 s in der Liste) → grüner Punkt der Zeile blendet aus, beim Schließen gesehen
    @Published var viewed: Set<String> = []
    /// 0 = Kapsel auf der Pille, 1 = volle Liste (VFMorph)
    @Published var progress: CGFloat = 0
    @Published var layout = VFNotify.Layout(windowFrame: .zero, pill: .zero, card: .zero, side: .above, hitRectsInScreen: [])
    /// Höhe des Zeilenbereichs (mehr als 4 Einträge → scrollt)
    @Published var rowsHeight: CGFloat = 0
    @Published var illustration = "illu_geteilt"
    /// Gerade sichtbare Zeilen (Scroll-Bereich) – nur die zählen beim Verweilen
    var visibleIDs: Set<String> = []
    var copy: (SharedVaultItem) -> Void = { _ in }
    var markAll: () -> Void = {}
    var openHub: () -> Void = {}

    var scrolls: Bool { items.count > SharedInboxList.maxRows }
}

final class SharedInboxBadge {
    static let shared = SharedInboxBadge()

    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)          // Systemgrün
    static let listWidth: CGFloat = 480
    static let hoverDelay: TimeInterval = 0.4
    /// So lange darf die Maus außerhalb von Pille + Lücke + Liste sein, bevor die Liste zugeht
    static let leaveDelay: TimeInterval = 0.8
    /// So lange muss die Maus IN der Liste sein, damit sichtbare Einträge als gesehen gelten
    static let dwellToSee: TimeInterval = 1.5

    private var list: SmartBadgePanel?
    private let model = SharedInboxModel()
    private var timer: Timer?
    private var hoverSince: Date?
    private var leftSince: Date?
    private var lastTick = Date()
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var lastCount = 0
    private var blockedLogged = false
    /// Nach dem Schließen erst wieder per Überfahren öffnen, wenn die Maus die Pille verlassen hat
    private var rearmed = true
    private var openedAt: Date?
    private var closing = false
    private var dwell: [String: TimeInterval] = [:]
    private var knownIDs: Set<String>?       // nil = erster Durchlauf (beim Start keine Karte zeigen)
    private var clickMonitor: Any?
    private var swallowMouseUp = false

    /// Es gibt Neues vom Partner → die Pille gehört beim Überfahren dieser Liste (nicht den Vorschlägen)
    var hasNew: Bool { !model.items.isEmpty }
    var isListOpen: Bool { (list?.isVisible ?? false) && !closing }

    func start() {
        guard !started else { return }
        started = true
        CVShared.shared.start()
        CVShared.shared.$items.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        SharedGistStore.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.model.objectWillChange.send() }
        }.store(in: &bag)
        // ClipVault kann Einträge im Panel als gesehen markieren → neu einlesen
        DistributedNotificationCenter.default().addObserver(forName: .init("app.flowdictation.clipvault.changed"), object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        model.copy = { [weak self] item in
            // Direkt in die Zwischenablage (geteilte Einträge stehen nicht unbedingt im eigenen Verlauf)
            if item.kind == .file && item.file == nil && ClipVaultClient.shared.canSendCommands {
                // große Datei noch nicht geladen: ClipVault lädt sie und legt sie danach selbst in die Zwischenablage
                ClipVaultClient.shared.send("copy", id: item.id)
            } else {
                let pb = NSPasteboard.general
                pb.clearContents()
                if let f = item.file { pb.writeObjects([f as NSURL]) }   // echte Datei-URL → Finder, Mail, WhatsApp
                else if let u = item.image, let img = NSImage(contentsOf: u) { pb.writeObjects([img]) }
                else if let t = item.text { pb.setString(t, forType: .string) }
                else if let f = item.fileName { pb.setString(f, forType: .string) }
            }
            withAnimation(.easeOut(duration: 0.18)) { _ = self?.model.copied.insert(item.id) }
            self?.markSeen([item.id])
        }
        model.markAll = { [weak self] in
            guard let self else { return }
            self.markSeen(self.model.items.map(\.id)); self.closeList(reason: "Alle gesehen")
        }
        model.openHub = { [weak self] in
            self?.markSeen(self?.model.items.map(\.id) ?? [])
            self?.closeList(reason: "In ClipVault öffnen")
            CVHubState.shared.switchTo(.clipvault)
            CVHubState.shared.go(.geteilt)
            VoiceFlowWindow.shared.show()
        }
        installRingClick()
        refresh()
    }

    private func refresh() {
        let st = SharedSeenState.load()
        var new = CVShared.shared.items.filter { st.isNew($0) }
        // Liste offen → nichts herausnehmen (sonst springt sie); nur Neues oben dazu. Aufgeräumt wird beim Schließen.
        if isListOpen {
            let shown = Set(model.items.map(\.id))
            new = new.filter { !shown.contains($0.id) } + model.items      // Neues oben dazu, Angezeigtes bleibt stehen
        }
        if new.map(\.id) != model.items.map(\.id) {
            if new.count > lastCount { log("Geteilt: \(new.count - lastCount) neu von \(Identity.partner(.dative))") }
            lastCount = new.count
            model.items = new
            for i in new { SharedGistStore.shared.refineIfPossible(i) }
            if isListOpen { layoutList() }
        }
        // Gerade eben angekommen (nicht beim Start) → kurz aus der Pille auf sich aufmerksam machen
        let ids = Set(new.map(\.id))
        if let known = knownIDs, let fresh = new.first(where: { !known.contains($0.id) }) { announce(fresh, total: new.count) }
        knownIDs = (knownIDs ?? []).union(ids)
        update()
    }

    /// Jedes Mal ein anderes Bild (Brieftaube, Papierflieger, zwei am Tisch, Postkatze, Kaffeetassen-Fang, Heißluftballon …) – nie zweimal hintereinander dasselbe
    private static var lastIllustration = ""
    static func randomIllustration() -> String {
        let all = ["illu_geteilt"] + (2...7).map { "illu_geteilt_\($0)" }
        let pick = all.filter { $0 != lastIllustration && VFAsset.image($0) != nil }.randomElement() ?? "illu_geteilt"
        lastIllustration = pick
        return pick
    }

    /// Karte aus der Pille für den Neuankömmling: Titel bleibt, darunter Art + Kernaussage
    static func announceNotice(_ item: SharedVaultItem, total: Int, illustration: String,
                               copy: @escaping () -> Void, open: @escaping () -> Void) -> VFNotice {
        let who = Identity.partner(.nominative, capitalized: true)
        let g = SharedGistStore.shared.gist(for: item)
        let text: String = {
            if !g.gist.isEmpty { return g.gist }
            if let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return SharedGistMaker.clip(SharedGistMaker.clean(t), 70) }
            return item.fileName ?? item.kind.label
        }()
        var n = VFNotice(
            id: "geteilt_neu",
            title: total > 1 ? "\(who) hat dir etwas geschickt (\(total) neu)" : "\(who) hat dir etwas geschickt",
            text: text,
            illustration: illustration, fallbackSymbol: "envelope.fill",
            primary: ("Kopieren", copy),
            secondary: ("Ansehen", open),
            timeout: 2.6)
        n.chip = VFNoticeChip(label: g.label, symbol: g.symbol, tint: g.tint)
        return n
    }

    /// Kurze Karte aus der Pille (~2,5 s; bleibt offen, solange die Maus darauf ist). Der grüne Rahmen bleibt danach.
    private func announce(_ item: SharedVaultItem, total: Int) {
        guard !SmartFlow.shared.isBusy(), !isListOpen else { return }       // nie mitten ins Diktat
        VFNotify.shared.show(SharedInboxBadge.announceNotice(item, total: total, illustration: SharedInboxBadge.randomIllustration(),
                                                             copy: { [weak self] in self?.model.copy(item) },
                                                             open: { [weak self] in self?.openList() }))
    }

    private func markSeen(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var st = SharedSeenState.load()
        for id in ids where !st.seen.contains(id) { st.seen.append(id) }
        st.save()
        refresh()
    }

    // MARK: Sichtbarkeit

    private var pillIdle: Bool { SmartFlow.shared.pillIsIdle() && !SmartFlow.shared.isBusy() }
    private var shouldShowRing: Bool { hasNew && pillIdle }

    private func update() {
        PillRing.shared.set(.shared, hasNew)
        // Zeitgeber läuft, solange es Neues gibt (auch während eines Diktats) – sonst reagiert das Überfahren danach nicht
        if hasNew || isListOpen { startTimer() }
        else { closeList(reason: "nichts Neues"); stopTimer() }
        if isListOpen, model.items.isEmpty { closeList(reason: "leer") }
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; hoverSince = nil; leftSince = nil }

    /// Pille + Rahmen (dort nimmt die Pille schon Mausereignisse an: Kapsel ± 6 pt)
    private static func pillZone(_ pill: NSRect) -> NSRect { pill.insetBy(dx: -6, dy: -6) }

    /// Korridor: Pille, Lücke und Liste als ein zusammenhängendes Rechteck (plus etwas Rand) – wer von der Pille
    /// zur Liste fährt, verlässt ihn nie. Reine Berechnung (testbar).
    static func corridor(pill: NSRect, card: NSRect) -> NSRect {
        guard card.width > 0 else { return pillZone(pill) }
        return pill.union(card).insetBy(dx: -10, dy: -10)
    }

    private func tick() {
        let now = Date()
        let dt = min(0.25, now.timeIntervalSince(lastTick)); lastTick = now
        guard let pill = VFNotify.shared.pillAnchor?(), pill.width > 0 else { return }
        PillRing.shared.set(.shared, hasNew)
        let m = NSEvent.mouseLocation
        let onPill = SharedInboxBadge.pillZone(pill).contains(m)
        if isListOpen, let p = list {
            let card = model.layout.hitRectsInScreen.first ?? .zero
            let inCard = card.contains(m)
            let ready = (openedAt.map { now.timeIntervalSince($0) > 0.3 } ?? false)
            if p.ignoresMouseEvents == (inCard && ready) { p.ignoresMouseEvents = !(inCard && ready) }
            // Korridor aus Pille + Lücke + Liste: erst nach 0,8 s draußen schließen
            if onPill || SharedInboxBadge.corridor(pill: pill, card: card).contains(m) { leftSince = nil }
            else {
                if leftSince == nil { leftSince = now }
                if now.timeIntervalSince(leftSince!) > SharedInboxBadge.leaveDelay { closeList(reason: "Maus weg"); return }
            }
            // Gesehen: nur wenn die Maus wirklich IN der Liste ist – je sichtbarem Eintrag mitzählen
            if inCard && ready {
                let visible = model.scrolls ? model.visibleIDs : Set(model.items.map(\.id))
                for id in visible where !model.viewed.contains(id) {
                    dwell[id, default: 0] += dt
                    if dwell[id]! >= SharedInboxBadge.dwellToSee {
                        withAnimation(.easeOut(duration: 0.35)) { _ = model.viewed.insert(id) }
                    }
                }
            }
            if (VFNotify.shared.isShowing && VFNotify.shared.currentID != "geteilt_neu") || SmartFlow.shared.isBusy() {
                closeList(reason: "Diktat/andere Karte")
            }
            return
        }
        if !onPill { rearmed = true }
        if shouldShowRing && onPill && rearmed && PillRing.shared.current == .shared {
            // Eigene Ankündigungskarte darf das Öffnen nicht blockieren – sie macht Platz für die Liste
            if VFNotify.shared.currentID == "geteilt_neu" { VFNotify.shared.dismiss(id: "geteilt_neu") }
            if hoverSince == nil { hoverSince = now; blockedLogged = false }
            if now.timeIntervalSince(hoverSince!) > SharedInboxBadge.hoverDelay { tryOpen() }
        } else { hoverSince = nil }
        if !hasNew && !isListOpen { stopTimer() }
    }

    private func tryOpen() {
        let busyCard = VFNotify.shared.isShowing && VFNotify.shared.currentID != "geteilt_neu"
        if busyCard || SmartPillBadge.shared.isListOpen || UpdateBadge.shared.isOpen {
            if !blockedLogged {
                blockedLogged = true
                log("Geteilt: Liste blockiert (Karte: \(VFNotify.shared.currentID ?? "–"), Vorschläge offen: \(SmartPillBadge.shared.isListOpen), Update offen: \(UpdateBadge.shared.isOpen))")
            }
            return
        }
        openList()
    }

    /// Klick auf den grünen Rahmen öffnet die Liste. Der Rahmen liegt im Mausbereich der Pille (Kapsel ± 6 pt):
    /// den Klick dort abfangen (lokaler Monitor), bevor die Pille ihn als Sprach-/Diktat-Klick nimmt.
    private func installRingClick() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            if e.type == .leftMouseUp {
                if self.swallowMouseUp { self.swallowMouseUp = false; return nil }
                return e
            }
            guard self.hasNew, !self.isListOpen, PillRing.shared.current == .shared,
                  let pill = VFNotify.shared.pillAnchor?(), pill.width > 0 else { return e }
            let m = NSEvent.mouseLocation
            guard SharedInboxBadge.isOnRing(m, pill: pill) else { return e }
            VFNotify.shared.dismiss(id: "geteilt_neu")
            self.swallowMouseUp = true
            self.openList()
            return nil
        }
    }

    /// Auf dem Rahmen (nicht auf der Kapsel selbst)? Rahmen = Kapsel + 3 pt Abstand + Strich, Fangbereich bis 6 pt.
    static func isOnRing(_ m: NSPoint, pill: NSRect) -> Bool {
        pillZone(pill).contains(m) && !pill.insetBy(dx: 1, dy: 1).contains(m)
    }

    // MARK: Liste

    func openList() {
        guard !isListOpen, !model.items.isEmpty else {
            if model.items.isEmpty { log("Geteilt: Liste leer – nichts zu zeigen") }
            return
        }
        guard let pill = VFNotify.shared.pillAnchor?(), pill.width > 0 else { return }
        SmartPillBadge.shared.closeList()
        let p = list ?? SmartBadgePanel(size: NSSize(width: SharedInboxBadge.listWidth, height: 200), acceptsMouse: true)
        list = p
        closing = false
        model.copied = []; model.viewed = []; dwell = [:]
        model.visibleIDs = Set(model.items.prefix(SharedInboxList.maxRows).map(\.id))
        model.illustration = SharedInboxBadge.lastIllustration.isEmpty ? "illu_geteilt" : SharedInboxBadge.lastIllustration
        model.progress = 0
        layoutList(pill: pill)
        p.contentView = VFNotifyHostingView(rootView: SharedInboxStage(model: model))
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        openedAt = Date()
        leftSince = nil; hoverSince = nil
        log("Geteilt: Liste geöffnet (\(model.items.count)) bei \(Int(model.layout.hitRectsInScreen.first?.minX ?? 0)),\(Int(model.layout.hitRectsInScreen.first?.minY ?? 0)) \(Int(model.layout.hitRectsInScreen.first?.width ?? 0))×\(Int(model.layout.hitRectsInScreen.first?.height ?? 0))")
        DispatchQueue.main.async { withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) { self.model.progress = 1 } }
        startTimer()
    }

    func closeList() { closeList(reason: "von außen") }

    private func closeList(reason: String) {
        guard let p = list, p.isVisible, !closing else { return }
        closing = true
        // Gesehen = kopiert (schon markiert) oder mindestens 1,5 s mit der Maus IN der Liste angeschaut
        let viewed = Array(model.viewed)
        let kept = model.items.count - model.viewed.union(model.copied).count
        openedAt = nil
        p.ignoresMouseEvents = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) { model.progress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
            guard let self else { return }
            p.orderOut(nil)
            p.contentView = nil
            self.closing = false
            self.model.copied = []
            if !viewed.isEmpty { self.markSeen(viewed) } else { self.refresh() }   // jetzt erst Gesehenes entfernen (unsichtbar)
        }
        hoverSince = nil
        rearmed = false
        log("Geteilt: Liste zu (\(reason)) – \(viewed.count) angesehen, \(max(0, kept)) bleiben neu")
    }

    private func layoutList(pill: NSRect? = nil) {
        guard let p = list, let pill = pill ?? VFNotify.shared.pillAnchor?() else { return }
        let scr = VFNotify.screen(containing: NSPoint(x: pill.midX, y: pill.midY)) ?? NSScreen.main
        let vis = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 949)
        let sf = scr?.frame ?? vis
        let (size, rows) = SharedInboxList.size(for: model.items, maxHeight: SharedInboxBadge.maxCardHeight(pill: pill, visible: vis))
        model.rowsHeight = rows
        model.layout = SharedInboxBadge.listLayout(card: size, pill: pill, visible: vis, frame: sf)
        p.setFrame(model.layout.windowFrame, display: true)
    }

    // MARK: Geometrie (reine Berechnung, testbar)

    static let gap: CGFloat = 12, inset: CGFloat = 10

    /// Wie hoch darf die Liste werden? Hochkant: ganze Bildschirmhöhe; quer: Platz über/unter der Pille.
    static func maxCardHeight(pill: NSRect, visible vis: NSRect) -> CGFloat {
        if pill.height > pill.width * 1.5 { return vis.height - 2 * inset }
        return pill.midY < vis.midY ? vis.maxY - inset - (pill.maxY + gap) : (pill.minY - gap) - (vis.minY + inset)
    }

    /// Liste zur Bildschirmmitte hin neben/über/unter die Pille, komplett auf EINEM Bildschirm; Fenster = Liste ∪ Pille
    /// (für das Wachsen aus der Pille). Alle Eingaben in Bildschirmkoordinaten.
    static func listLayout(card cs: NSSize, pill: NSRect, visible vis: NSRect, frame sf: NSRect) -> VFNotify.Layout {
        let side: VFNotify.Side
        if pill.height > pill.width * 1.5 {
            side = (pill.midX - vis.minX) / max(vis.width, 1) > 0.5 ? .left : .right
        } else {
            side = pill.midY < vis.midY ? .above : .below
        }
        var card: NSRect
        switch side {
        case .above: card = NSRect(x: pill.midX - cs.width / 2, y: pill.maxY + gap, width: cs.width, height: cs.height)
        case .below: card = NSRect(x: pill.midX - cs.width / 2, y: pill.minY - gap - cs.height, width: cs.width, height: cs.height)
        case .left: card = NSRect(x: pill.minX - gap - cs.width, y: pill.midY - cs.height / 2, width: cs.width, height: cs.height)
        case .right: card = NSRect(x: pill.maxX + gap, y: pill.midY - cs.height / 2, width: cs.width, height: cs.height)
        }
        card.origin.x = min(max(card.minX, vis.minX + inset), vis.maxX - inset - cs.width)
        card.origin.y = min(max(card.minY, vis.minY + inset), vis.maxY - inset - cs.height)
        card = card.integral
        var win = card.union(pill).insetBy(dx: -VFNotify.windowMargin, dy: -VFNotify.windowMargin)
        win.origin.x = max(win.minX, sf.minX); win.origin.y = max(win.minY, sf.minY)
        win.size.width = min(win.maxX, sf.maxX) - win.minX
        win.size.height = min(win.maxY, sf.maxY) - win.minY
        win = win.integral
        func toWin(_ r: NSRect) -> CGRect { CGRect(x: r.minX - win.minX, y: win.maxY - r.maxY, width: r.width, height: r.height) }
        return VFNotify.Layout(windowFrame: win, pill: toWin(pill), card: toWin(card), side: side, hitRectsInScreen: [card])
    }

    // MARK: Offscreen-Bild (Sichtprüfung)

    /// Einzelbild wie früher (Liste über einer Pille unten mittig)
    static func renderPNG(items: [SharedVaultItem], to url: URL) -> Bool {
        let scr = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let pill = NSRect(x: scr.midX - 22, y: 14, width: 44, height: 9)
        return renderScene(items: items, pill: pill, screen: scr, to: url)
    }

    /// Ausschnitt eines Bildschirms: Pille (mit grünem Rahmen) + Liste bei Fortschritt `progress`.
    @discardableResult
    static func renderScene(items: [SharedVaultItem], pill: NSRect, screen scr: NSRect, progress: CGFloat = 1,
                            viewed: Set<String> = [], copied: Set<String> = [], to url: URL) -> Bool {
        _ = NSApplication.shared
        let m = SharedInboxModel(); m.items = items; m.progress = progress; m.viewed = viewed; m.copied = copied
        m.illustration = "illu_geteilt_3"
        let (size, rows) = SharedInboxList.size(for: items, maxHeight: maxCardHeight(pill: pill, visible: scr))
        m.rowsHeight = rows
        m.layout = listLayout(card: size, pill: pill, visible: scr, frame: scr)
        let lay = m.layout
        let ring = PillRingModel(); ring.color = PillRing.Kind.shared.color; ring.progress = 1; ring.pillSize = pill.size
        let pad = PillRing.gap + PillRing.glow
        let root = ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.80, green: 0.84, blue: 0.90), Color(red: 0.90, green: 0.88, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Capsule().fill(Color(white: 0.16).opacity(0.92)).overlay(Capsule().strokeBorder(Color.white.opacity(0.42), lineWidth: 1))
                .frame(width: lay.pill.width, height: lay.pill.height)
                .offset(x: lay.pill.minX, y: lay.pill.minY)
            PillRingView(model: ring).frame(width: lay.pill.width + 2 * pad, height: lay.pill.height + 2 * pad)
                .offset(x: lay.pill.minX - pad, y: lay.pill.minY - pad)
            SharedInboxStage(model: m)
        }
        .frame(width: lay.windowFrame.width, height: lay.windowFrame.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: lay.windowFrame.size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}

// MARK: - Liste „Neu von …“ (Inhalt; Hintergrund/Schatten/Wachsen macht VFMorph wie bei den Meldungskarten)

/// Ganze Fensterfläche; die Liste wird per Fortschritt aus der Pille gemorpht (gleiche Form/Schatten wie VFNotify).
struct SharedInboxStage: View {
    @ObservedObject var model: SharedInboxModel
    var body: some View {
        Color.clear
            .frame(width: model.layout.windowFrame.width, height: model.layout.windowFrame.height)
            .modifier(VFMorph(progress: model.progress, layout: model.layout, content: AnyView(SharedInboxList(model: model))))
            .environment(\.colorScheme, .dark)
    }
}

struct SharedInboxList: View {
    @ObservedObject var model: SharedInboxModel
    static let maxRows = 4
    static let headerHeight: CGFloat = 72
    static let footerHeight: CGFloat = 44

    /// Größe der Liste + Höhe des Zeilenbereichs. Mehr als 4 Einträge (oder zu wenig Platz) → Zeilenbereich scrollt.
    static func size(for items: [SharedVaultItem], maxHeight: CGFloat = 10_000) -> (NSSize, CGFloat) {
        let heights = items.prefix(maxRows).map { rowHeight($0) }   // nur die sichtbaren messen (je eine Hosting-Ansicht)
        var rows = heights.prefix(maxRows).reduce(0, +) + 8
        if items.count > maxRows { rows += 22 }   // ein Stück der nächsten Zeile zeigt: hier geht's weiter
        let chrome = headerHeight + footerHeight + 2
        rows = max(60, min(rows, maxHeight - chrome))
        return (NSSize(width: SharedInboxBadge.listWidth, height: ceil(chrome + rows)), ceil(rows))
    }

    static func rowHeight(_ item: SharedVaultItem) -> CGFloat {
        let m = SharedInboxModel(); m.items = [item]
        let host = NSHostingView(rootView: SharedInboxRow(item: item, model: m)
            .frame(width: SharedInboxBadge.listWidth - 16).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark))
        return ceil(host.fittingSize.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            rows
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        let who = Identity.partner(.dative, capitalized: true)
        let unseen = model.items.filter { !model.viewed.contains($0.id) && !model.copied.contains($0.id) }.count
        return HStack(spacing: 12) {
            illustration
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Neu von \(who)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(model.items.count)")
                        .font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(unseen > 0 ? Color.black.opacity(0.85) : .white.opacity(0.7))
                        .padding(.horizontal, 7).frame(minWidth: 20).frame(height: 19)
                        .background(Capsule().fill(unseen > 0 ? SharedInboxBadge.green : Color.white.opacity(0.14)))
                        .animation(.easeOut(duration: 0.3), value: unseen)
                }
                HStack(spacing: 5) {
                    Text(subtitle).lineLimit(1)
                    Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .semibold)).help("Ende-zu-Ende verschlüsselt")
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            Button(action: model.markAll) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .semibold))
                    Text("Alle gesehen").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 11).frame(height: 28)
                .contentShape(Capsule())
            }
            .buttonStyle(InboxPressStyle(hoverFill: true))
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: SharedInboxList.headerHeight)
    }

    private var subtitle: String {
        guard let newest = model.items.map(\.createdAt).max() else { return "" }
        let ago = SharedInboxRow.ago(newest)
        return "Zuletzt \(ago)"
    }

    @ViewBuilder private var illustration: some View {
        let (bg, ink) = VFNotifyStyle.fallbackColors("illu_geteilt")
        ZStack {
            Color(red: 0.86, green: 0.95, blue: 0.88)
            if let img = VFNotify.imageProvider(model.illustration) ?? VFNotify.imageProvider("illu_geteilt") {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                bg
                Image(systemName: "envelope.fill").font(.system(size: 18, weight: .medium)).foregroundStyle(ink)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private var rows: some View {
        ScrollView(.vertical, showsIndicators: model.scrolls) {
            LazyVStack(spacing: 2) {
                ForEach(model.items) { item in
                    SharedInboxRow(item: item, model: model)
                        .onScrollVisibilityChange(threshold: 0.6) { vis in
                            if vis { model.visibleIDs.insert(item.id) } else { model.visibleIDs.remove(item.id) }
                        }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .scrollDisabled(!model.scrolls)
        .frame(height: model.rowsHeight)
        .mask {
            // unten weich ausblenden, wenn es weitergeht
            VStack(spacing: 0) {
                Color.black
                if model.scrolls { LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 22) }
            }
        }
    }

    private var footer: some View {
        Button(action: model.openHub) {
            HStack(spacing: 6) {
                Text(model.scrolls ? "Alle \(model.items.count) in ClipVault öffnen" : "In ClipVault öffnen")
                    .font(.system(size: 12.5, weight: .medium))
                Image(systemName: "arrow.up.right").font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity).frame(height: SharedInboxList.footerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(InboxPressStyle(hoverFill: false, hoverBright: true))
    }
}

struct SharedInboxRow: View {
    let item: SharedVaultItem
    @ObservedObject var model: SharedInboxModel
    @ObservedObject private var gists = SharedGistStore.shared
    @State private var hover = false

    /// Rohtext ohne Markdown, in einer Zeile – steht gedimmt unter der Kernaussage
    private var preview: String? {
        switch item.kind {
        case .file:
            return item.fileName.map { item.file == nil ? "\($0) · noch nicht geladen" : $0 }
        case .image:
            guard let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return SharedGistMaker.clean(t.components(separatedBy: .newlines).prefix(6).joined(separator: " "))
        default:
            guard let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let g = SharedGistStore.shared.gist(for: item)
            if g.kind == .link { return t }
            // Rohtext ohne Anrede, ohne die Zeile, aus der die Kernaussage stammt, ohne Bericht-Kopfzeilen
            let key = String(g.gist.replacingOccurrences(of: "…", with: "").prefix(18)).lowercased()
            var flat: [String] = []
            for raw in t.prefix(900).components(separatedBy: .newlines) {
                let c = SharedGistMaker.clean(raw)
                if c.isEmpty || c.hasPrefix("```") || SharedGistMaker.stripSalutation(c).isEmpty { continue }
                if g.kind == .report && (raw.hasPrefix("#") || c.hasPrefix("Von:") || c.hasPrefix("App:")) { continue }
                if key.count >= 6, c.lowercased().contains(key) { continue }
                flat.append(c)
                if flat.count >= 6 { break }
            }
            return flat.isEmpty ? nil : flat.joined(separator: " · ")
        }
    }

    var body: some View {
        let copied = model.copied.contains(item.id)
        let seen = copied || model.viewed.contains(item.id)
        let g = gists.gist(for: item)
        HStack(alignment: .top, spacing: 12) {
            visual(g).frame(width: 64, alignment: .center)      // feste Spalte: Texte stehen bündig untereinander
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(SharedInboxBadge.green).frame(width: 7, height: 7)
                        .opacity(seen ? 0 : 1).scaleEffect(seen ? 0.4 : 1)
                        .help(seen ? "Gesehen" : "Neu")
                    SharedGistChip(gist: g, size: 10.5)
                    Text(Self.ago(item.createdAt)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
                        .layoutPriority(-1)                              // bei langer Art-Marke weicht die Zeit, nie der Knopf
                    Spacer(minLength: 4)
                    copyButton(copied)
                }
                Text(g.gist.isEmpty ? g.label : g.gist)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1).truncationMode(.tail)
                if let p = preview, !p.isEmpty {
                    Text(p)
                        .font(.system(size: 12.5)).foregroundStyle(item.kind == .link ? g.tint.opacity(0.8) : .white.opacity(0.5))
                        .lineLimit(item.kind == .file || item.kind == .link ? 1 : 2)
                        .truncationMode(item.kind == .file ? .middle : .tail)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { model.copy(item) }
        .help(item.kind == .text ? "Klicken zum Kopieren" : "")
    }

    private func copyButton(_ copied: Bool) -> some View {
        Button { model.copy(item) } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5, weight: .bold))
                Text(copied ? "Kopiert" : "Kopieren").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(copied ? Color.black.opacity(0.85) : .black)
            .frame(width: 90, height: 26)                       // feste Breite: „Kopiert“ ↔ „Kopieren“ verschiebt nichts
            .background(Capsule().fill(copied ? SharedInboxBadge.green : Color.white.opacity(hover ? 1 : 0.9)))
            .contentShape(Capsule())
        }
        .buttonStyle(InboxPressStyle())
    }

    @ViewBuilder private func visual(_ g: SharedGist) -> some View {
        if let u = item.image, let img = Self.thumbnail(u) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        } else if item.kind == .file {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06))
                Image(nsImage: item.fileIcon).resizable().interpolation(.high).frame(width: 38, height: 38)
                    .opacity(item.file == nil ? 0.65 : 1)
            }
            .frame(width: 52, height: 52)
            .padding(.top, 2)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(g.tint.opacity(0.16))
                Image(systemName: g.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(g.tint)
            }
            .frame(width: 48, height: 48)
            .padding(.top, 2)
        }
    }

    private static var thumbCache: [URL: NSImage] = [:]
    static func thumbnail(_ url: URL) -> NSImage? {
        if let c = thumbCache[url] { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 192] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        thumbCache[url] = img
        return img
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "gerade eben" }
        if s < 3600 { return "vor \(s / 60) Min." }
        if s < 86400 { return "vor \(s / 3600) Std." }
        return "vor \(s / 86400) Tag\(s / 86400 == 1 ? "" : "en")"
    }
}

/// Drücken/Hover für Knöpfe in der Liste
struct InboxPressStyle: ButtonStyle {
    var hoverFill = false
    var hoverBright = false
    func makeBody(configuration: Configuration) -> some View { PressBody(configuration: configuration, hoverFill: hoverFill, hoverBright: hoverBright) }
    struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let hoverFill: Bool, hoverBright: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(Capsule().fill(Color.white.opacity(hoverFill && hover ? 0.10 : 0)))
                .brightness(hoverBright && hover ? 0.25 : 0)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        }
    }
}
