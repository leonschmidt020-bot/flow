import AppKit
import SwiftUI

/// Test-Befehle für „Gemeinsame Namen“ (ohne App, ohne Zwischenablage). Mit FLOW_HOME + CLIPVAULT_HOME auf Test-Ordner zeigen.
///   Flow --partner-vocab-learn <wort> [correction|training|suggestion|manual] [person|company|place|term]
///   Flow --partner-vocab-inbox [annehmen|ablehnen]      Posteingang abholen (wie die App), Karten ausgeben
///   Flow --partner-vocab-wait <sek> [annehmen]           auf das nächste Wort warten, Laufzeit messen
///   Flow --partner-vocab-render <ordner>                 Karte + Wörterbuch-Abschnitt als PNG
enum PartnerVocabCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2, args[1].hasPrefix("--partner-vocab-") else { return nil }
        let a = Array(args.dropFirst(2))
        _ = NSApplication.shared
        let pv = PartnerVocab.shared
        pv.startHeadless()
        pv.onCards = { cards in
            for c in cards {
                let n = PartnerVocab.notice(c, accept: {}, decline: {})
                print("KARTE: \(n.title) — \(n.text) [\(n.primary?.0 ?? "") / \(n.secondary?.0 ?? "")]")
            }
        }
        switch args[1] {
        case "--partner-vocab-learn":
            guard let w = a.first else { print("Wort fehlt"); return 2 }
            let src = a.count > 1 ? PartnerVocabSource(rawValue: a[1]) ?? .manual : .manual
            let kind = a.count > 2 ? NameKind(rawValue: a[2]) : nil
            guard let clean = PartnerVocab.shareable(w) else { print("NICHT GETEILT: „\(w)“ ist kein Name/Begriff (Allerweltswort/Grammatik)"); return 0 }
            let k = PartnerVocab.key(clean)
            if pv.received.contains(where: { PartnerVocab.key($0.word) == k }) { print("NICHT GESENDET: „\(clean)“ kam vom Partner"); return 0 }
            if let s = pv.sent.first(where: { PartnerVocab.key($0.word) == k }), s.status != .waiting {
                print("NICHT ERNEUT GESENDET: „\(s.word)“ ist schon \(s.status.rawValue)"); return 0
            }
            let tries = pv.sent.first { PartnerVocab.key($0.word) == k }?.tries ?? 0
            pv.learned(w, kind: kind, source: src)
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 16 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let s = pv.sent.first(where: { PartnerVocab.key($0.word) == k }), s.tries > tries {
                    print("GESENDET: „\(s.word)“ (\(s.type), Quelle \(s.source.rawValue)) → \(s.status.rawValue)"); return s.status == .waiting ? 1 : 0
                }
            }
            print("WARTET: keine Antwort von ClipVault"); return 1
        case "--partner-vocab-inbox":
            let fresh = pv.checkInbox()
            decide(pv, fresh, a.first)
            report(pv)
            return 0
        case "--partner-vocab-wait":
            let secs = Double(a.first ?? "") ?? 10
            var got = false
            let t0 = Date()
            let obs = DistributedNotificationCenter.default().addObserver(forName: CVNames.vocab, object: nil, queue: .main) { _ in
                let heard = Date()
                let fresh = pv.checkInbox()
                if let created = createdAt(fresh.first?.id) {
                    print(String(format: "ANGEKOMMEN nach %.0f ms (vom Lernen auf A bis zur Karte auf B)", heard.timeIntervalSince1970 * 1000 - created * 1000))
                }
                decide(pv, fresh, a.count > 1 ? a[1] : nil)
                got = true
            }
            print("warte bis \(Int(secs)) s auf ein Wort …"); fflush(stdout)
            while !got && Date().timeIntervalSince(t0) < secs { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            DistributedNotificationCenter.default().removeObserver(obs)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // vocabAck zustellen
            report(pv)
            return got ? 0 : 1
        case "--partner-vocab-render":
            return render(dir: a.first ?? NSTemporaryDirectory() + "partner-vocab")
        default:
            print("unbekannt: \(args[1])"); return 2
        }
    }

    private static func decide(_ pv: PartnerVocab, _ fresh: [PartnerWord], _ what: String?) {
        guard let what else { return }
        let open = fresh + pv.received.filter { $0.state == .pending && !fresh.contains($0) }
        for w in open {
            if what == "annehmen" { pv.accept(w.id) } else if what == "ablehnen" { pv.decline(w.id) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private static func createdAt(_ id: String?) -> Double? {
        guard let id, let data = try? Data(contentsOf: ClipVaultClient.base.appendingPathComponent("vocab.json")),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let arr = o["items"] as? [[String: Any]] else { return nil }
        return arr.first { ($0["id"] as? String)?.lowercased() == id.lowercased() }?["createdAt"] as? Double
    }

    private static func report(_ pv: PartnerVocab) {
        let dict = Settings.shared.dictionary
        for w in pv.received {
            let e = dict.first { PartnerVocab.key($0.write) == PartnerVocab.key(w.word) }
            print("VOM PARTNER: „\(w.word)“ (\(w.type), von \(w.by)) → \(w.state.rawValue)"
                  + (e.map { " · Wörterbuch: heard=„\($0.heard)“ write=„\($0.write)“ vocabOnly=\($0.vocabOnly == true)" } ?? " · nicht im Wörterbuch"))
        }
    }

    // MARK: Sichtprüfung

    static func render(dir: String) -> Int32 {
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        let brenninkmeyer = PartnerWord(id: "A1", word: "Brenninkmeyer", type: "person", by: "Nico", receivedAt: now.addingTimeInterval(-30), state: .pending)
        let demo = [brenninkmeyer,
                    PartnerWord(id: "A2", word: "Nexora", type: "company", by: "Nico", receivedAt: now.addingTimeInterval(-3600 * 5), state: .accepted),
                    PartnerWord(id: "A3", word: "Hallbauer", type: "person", by: "Nico", receivedAt: now.addingTimeInterval(-86400 * 2), state: .accepted),
                    PartnerWord(id: "A4", word: "Lindenallee", type: "place", by: "Nico", receivedAt: now.addingTimeInterval(-86400 * 3), state: .accepted)]
        var ok = true
        ok = VFNotify.renderPNG(PartnerVocab.notice(brenninkmeyer, accept: {}, decline: {}), to: URL(fileURLWithPath: dir + "/karte.png")) && ok
        ok = VFNotify.renderPNG(PartnerVocab.notice(brenninkmeyer, accept: {}, decline: {}), to: URL(fileURLWithPath: dir + "/karte_wachsen.png"), progress: 0.45) && ok
        ok = VFNotify.renderPNG(PartnerVocab.summaryNotice(demo, acceptAll: {}, review: {}), to: URL(fileURLWithPath: dir + "/karte_sammlung.png")) && ok
        PartnerVocab.shared.setPreview(demo)
        let empty = PartnerVocab(base: URL(fileURLWithPath: dir))
        empty.setPreview([])
        let shots: [(String, AnyView, NSSize)] = [
            ("abschnitt", AnyView(PartnerVocabSection().padding(40).background(VF.panel)), NSSize(width: 1100, height: 640)),
            ("abschnitt_leer", AnyView(PartnerVocabSection(pv: empty).padding(40).background(VF.panel)), NSSize(width: 1100, height: 420)),
            ("woerterbuch", AnyView(VFDictionaryPage()), NSSize(width: 1650, height: 2100)),
        ]
        for (name, view, sz) in shots {
            let host = NSHostingView(rootView: view.frame(width: sz.width, height: sz.height).environment(\.colorScheme, .light))
            host.frame = NSRect(origin: .zero, size: sz)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { ok = false; continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) } else { ok = false }
        }
        print("gerendert nach \(dir)")
        return ok ? 0 : 1
    }
}
