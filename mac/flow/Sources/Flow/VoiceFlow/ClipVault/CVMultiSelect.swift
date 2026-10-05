import AppKit
import SwiftUI

// MARK: - Mehrfachauswahl im Hub (wie im ClipVault-Panel, 05.10.2026)
// ⌘-Klick wählt einzeln, ⇧-Klick einen Bereich, ⌘A alles Sichtbare; solange etwas gewählt ist, schaltet ein
// normaler Klick um. Unten erscheint „3 ausgewählt · Auswahl aufheben · Alle kopieren“ (auch ⌘C / Enter).
// Kopiert wird über ClipVaults Befehl `copyMany` (PROTOCOL.md): je Bild ein Pasteboard-Item + Klartext mit den
// maskierten Pfaden → Claude Code macht beim Einfügen mit ⌘V aus jedem Bild ein eigenes [Image #n].

/// Reine Auswahl-Logik (gleiches Verhalten wie MultiSelection in ClipVault)
struct CVPickSet: Equatable {
    private(set) var ids: [String] = []
    private(set) var anchor: String?
    var isActive: Bool { !ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// true = Auswahl geändert (nicht wie bisher auswählen/kopieren)
    mutating func click(_ id: String, command: Bool, shift: Bool, order: [String]) -> Bool {
        if shift { extend(to: id, order: order); return true }
        if command || isActive { toggle(id); return true }
        return false
    }
    mutating func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        anchor = ids.isEmpty ? nil : id
    }
    mutating func extend(to id: String, order: [String]) {
        guard let a = anchor, let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: id) else {
            if !ids.contains(id) { ids.append(id) }
            anchor = id; return
        }
        for x in order[min(ia, ib)...max(ia, ib)] where !ids.contains(x) { ids.append(x) }
    }
    mutating func selectAll(_ order: [String]) { ids = order; anchor = order.first }
    mutating func clear() { ids = []; anchor = nil }
    mutating func prune(keep: Set<String>) {
        ids.removeAll { !keep.contains($0) }
        if let a = anchor, !keep.contains(a) { anchor = ids.last }
        if ids.isEmpty { anchor = nil }
    }
    func ordered(by order: [String]) -> [String] {
        let pos = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated().sorted { l, r in
            let a = pos[l.element] ?? Int.max, b = pos[r.element] ?? Int.max
            return a != b ? a < b : l.offset < r.offset
        }.map(\.element)
    }
}

/// Kreis links in der Zeile / oben links auf der Kachel
struct CVPickCircle: View {
    let checked: Bool
    var size: CGFloat = 19
    var onImage = false            // auf einem Vorschaubild: dunkler Grund, damit er sichtbar bleibt
    var body: some View {
        ZStack {
            if checked {
                Circle().fill(VF.ink)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().fill(onImage ? Color.black.opacity(0.35) : VF.card)
                Circle().strokeBorder(onImage ? Color.white.opacity(0.95) : VF.muted.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(onImage ? 0.25 : 0), radius: 2, y: 1)
        .contentShape(Circle())
    }
}

/// Leiste unten: „3 ausgewählt · Auswahl aufheben · Alle kopieren“
struct CVSelectionBar: View {
    let count: Int
    let onClear: () -> Void
    let onCopy: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text("\(count) ausgewählt").font(HubFont.bodyMedium).foregroundStyle(VF.ink).monospacedDigit()
            Spacer(minLength: 12)
            Button("Auswahl aufheben", action: onClear).buttonStyle(HubSoftButton(height: 32)).help("Auswahl aufheben (Esc)")
            Button(action: onCopy) {
                HStack(spacing: 6) { Image(systemName: "doc.on.doc.fill").font(.system(size: 12, weight: .semibold)); Text("Alle kopieren") }
            }
            .buttonStyle(HubBlackButton(height: 32))
            .help("Alle gewählten Einträge kopieren (⌘C) – in Claude Code mit ⌘V einfügen")
        }
        .padding(.leading, 18).padding(.trailing, 10).frame(height: 52)
        .background(VF.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(VF.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
    }
}

extension ClipVaultClient {
    /// „Alle kopieren“: über ClipVault (`copyMany`, legt Bilder als Dateien + Pfade ab). Ohne Befehlskanal: selbst.
    func copyMany(_ list: [CVItem]) {
        guard !list.isEmpty else { return }
        let msg = Self.copyManyMessage(list)
        if canSendCommands {
            send("copyMany", extra: ["ids": list.map(\.id), "toast": false]) { [weak self] err in
                self?.show(CVToast(text: "Kopieren fehlgeschlagen: \(err)", symbol: "exclamationmark.triangle", isError: true))
            }
        } else {
            copyManyLocally(list)
        }
        show(CVToast(text: msg, symbol: "doc.on.doc"))
    }
    static func copyManyMessage(_ list: [CVItem]) -> String {
        let imgs = list.filter { $0.kind == .image }.count
        let files = list.filter { $0.kind == .file }.reduce(0) { $0 + max(1, $1.files.count) }
        let texts = list.count - imgs - list.filter { $0.kind == .file }.count
        func n(_ c: Int, _ one: String, _ many: String) -> String? { c == 0 ? nil : "\(c) \(c == 1 ? one : many)" }
        var s = [n(imgs, "Bild", "Bilder"), n(files, "Datei", "Dateien"), n(texts, "Text", "Texte")].compactMap { $0 }.joined(separator: " + ") + " kopiert"
        if imgs > 0 { s += " – in Claude Code mit ⌘V einfügen" }
        return s
    }
    /// Notweg ohne ClipVault: Datei-URLs je Bild/Datei + Klartext (maskierte Pfade, dann Texte)
    func copyManyLocally(_ list: [CVItem]) {
        func esc(_ p: String) -> String {
            let special = Set(" \t!\"#$&'()*,;<>?[\\]^`{|}~=%")
            return p.reduce(into: "") { o, ch in if special.contains(ch) { o.append("\\") }; o.append(ch) }
        }
        var urls: [URL] = [], texts: [String] = []
        for i in list {
            switch i.kind {
            case .image: if let u = imageURL(i) { urls.append(u) }
            case .file: urls += i.files.map { fileURL($0) }
            case .text, .link: if let t = i.text, !t.isEmpty { texts.append(t) }
            }
        }
        let text = ([urls.isEmpty ? nil : urls.map { esc($0.path) }.joined(separator: " ")].compactMap { $0 } + texts).joined(separator: "\n\n")
        var items: [NSPasteboardItem] = urls.map { u in
            let it = NSPasteboardItem(); it.setString(u.absoluteString, forType: .fileURL)
            if ["png"].contains(u.pathExtension.lowercased()), let d = try? Data(contentsOf: u) { it.setData(d, forType: .png) }
            return it
        }
        if items.isEmpty { items = [NSPasteboardItem()] }
        items[0].setString(text, forType: .string)
        let pb = NSPasteboard.general
        pb.clearContents(); pb.writeObjects(items)
    }
}

// MARK: - Selbsttest:  Flow --cv-pick-test   (reine Logik, fasst nichts an)
enum CVPickDev {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2, args[1] == "--cv-pick-test" else { return nil }
        var fails = 0, n = 0
        func check(_ name: String, _ ok: Bool) { n += 1; print((ok ? "ok    " : "FEHLER ") + name); if !ok { fails += 1 } }
        let order = ["a", "b", "c", "d", "e"]
        var m = CVPickSet()
        check("Klick ohne Auswahl = wie bisher", !m.click("a", command: false, shift: false, order: order) && !m.isActive)
        check("⌘-Klick waehlt", m.click("b", command: true, shift: false, order: order) && m.ids == ["b"])
        check("danach schaltet normaler Klick um", m.click("d", command: false, shift: false, order: order) && m.ids == ["b", "d"])
        _ = m.click("e", command: false, shift: true, order: order)
        check("⇧-Klick ab Anker d bis e", Set(m.ids) == ["b", "d", "e"])
        m.selectAll(["c", "e"]); check("⌘A = sichtbare", m.ids == ["c", "e"])
        check("Reihenfolge = Liste", { var x = CVPickSet(); x.toggle("e"); x.toggle("a"); return x.ordered(by: order) == ["a", "e"] }())
        m.prune(keep: ["e"]); check("Geloeschte fallen raus", m.ids == ["e"])
        m.clear(); check("Esc leert", !m.isActive && m.anchor == nil)
        let img = CVItem(id: "i", rawKind: "image", text: nil, image: "x.png", date: Date(), source: nil, files: [], pinned: false, collection: nil)
        let txt = CVItem(id: "t", rawKind: "text", text: "Hallo", image: nil, date: Date(), source: nil, files: [], pinned: false, collection: nil)
        check("Hinweis Bilder", ClipVaultClient.copyManyMessage([img, img, img]) == "3 Bilder kopiert – in Claude Code mit ⌘V einfügen")
        check("Hinweis gemischt", ClipVaultClient.copyManyMessage([img, txt]) == "1 Bild + 1 Text kopiert – in Claude Code mit ⌘V einfügen")
        check("Hinweis nur Text", ClipVaultClient.copyManyMessage([txt, txt]) == "2 Texte kopiert")
        print(fails == 0 ? "ALLE \(n) PRUEFUNGEN OK" : "\(fails) VON \(n) FEHLGESCHLAGEN")
        return fails == 0 ? 0 : 1
    }
}
