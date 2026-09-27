import AppKit
import Combine
import CoreServices
import SwiftUI

// MARK: - Gemeinsame Namen: was einer von beiden lernt, bekommt der andere als Vorschlag
//
// Lernt Flow einen Namen/Begriff (bestätigte Korrektur, Wort-/Satz-Training, „Flow lernt mit“-Vorschlag,
// von Hand im Wörterbuch), geht NUR das Wort (Schreibweise + Art + „gelernt von <Name>“) über ClipVault an den
// Partner: Befehl `sendVocab`. Nie Stimmprofile, Klang-Vorlagen, eigene Verhörer („Shark Wes“) oder Aliasse.
// Nur echte Namen/Begriffe: Allerweltswörter („Jacke“) und reine Grammatik bleiben privat (WordTrainer.looksLikeName).
//
// Beim Partner legt ClipVault das Wort in ~/.config/flow-clipvault/vocab.json (Posteingang, `inbox: true`) und meldet
// `app.flowdictation.clipvault.vocab`. Flow liest die Datei, merkt sich jedes Wort in partner-vocab.json (0600),
// bestätigt mit `vocabAck` und fragt mit einer Karte aus der Pille („Nico hat ‚Brenninkmeyer‘ gelernt – übernehmen?“).
// Übernehmen = Hinweis-Eintrag im Wörterbuch (vocabOnly): Whisper/NameBooster kennen die Schreibweise, die eigenen
// Verhörer lernt Flow danach selbst dazu. Steht das Wort schon im Wörterbuch → keine Karte.
// Kein Ping-Pong: ClipVault vergibt pro Wort auf beiden Seiten dieselbe id und schickt Bekanntes nie erneut;
// Flow schickt nichts, was vom Partner kam.

enum PartnerVocabSource: String, Codable { case correction, training, suggestion, manual }

struct PartnerWord: Codable, Identifiable, Equatable {
    enum State: String, Codable { case pending, accepted, declined, known, removed }
    var id: String               // ClipVault-Wort-id (gleich auf beiden Macs)
    var word: String
    var type: String             // person | company | place | term
    var by: String
    var receivedAt: Date
    var state: State
    var decidedAt: Date? = nil
    /// Wörterbuch-Eintrag, den „Übernehmen“ angelegt hat (zum Entfernen)
    var dictID: UUID? = nil
}

struct PartnerSentWord: Codable, Equatable {
    enum Status: String, Codable { case waiting, sent, known }
    var word: String
    var type: String
    var source: PartnerVocabSource
    var at: Date
    var status: Status
    var tries: Int = 0
}

final class PartnerVocab: ObservableObject {
    static let shared = PartnerVocab()

    @Published private(set) var received: [PartnerWord] = []
    @Published private(set) var sent: [PartnerSentWord] = []
    /// „Namen vom Partner automatisch übernehmen“ (Standard aus → Karte an der Pille)
    @Published var autoAccept = false { didSet { if !loading && autoAccept != oldValue { save() } } }

    /// Ohne Oberfläche (CLI/Test): Karten werden nicht gezeigt, sondern hier gemeldet
    var headless = false
    var onCards: (([PartnerWord]) -> Void)?

    let fileURL: URL
    private var loading = false
    private var started = false
    private var shownThisSession = Set<String>()
    private var waiting: [String: (Bool, [String: Any], String?) -> Void] = [:]
    private var observers: [NSObjectProtocol] = []

    init(base: URL = Paths.base) {
        fileURL = base.appendingPathComponent("partner-vocab.json")
        load()
    }

    // MARK: Datei

    private struct Disk: Codable {
        var version = 1
        var autoAccept = false
        var received: [PartnerWord] = []
        var sent: [PartnerSentWord] = []
    }
    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .secondsSince1970
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return (e, d)
    }
    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let d = try? PartnerVocab.coder().1.decode(Disk.self, from: data) else { return }
        loading = true
        received = d.received; sent = d.sent; autoAccept = d.autoAccept
        loading = false
    }
    func save() {
        let d = Disk(autoAccept: autoAccept, received: Array(received.suffix(1000)), sent: Array(sent.suffix(1000)))
        guard let data = try? PartnerVocab.coder().0.encode(d) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: Regeln

    static func key(_ w: String) -> String {
        w.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Taugt das Wort zum Teilen? Liefert die bereinigte Schreibweise oder nil.
    /// Nur Namen/Begriffe – Allerweltswörter („Jacke“) und Grammatik bleiben privat. Grundlage ist die Regel des Trainings
    /// (`WordTrainer.looksLikeName`: kein Rechtschreib-Wort oder Großbuchstabe innen wie „KiTaNet“). Weil macOS' Rechtschreibung
    /// aber auch Namen aus den Kontakten kennt („Brenninkmeyer“, „Pierre“, „Lidl“ gelten dort als echt), entscheidet für solche
    /// großgeschriebenen Wörter das Systemwörterbuch: kein Eintrag oder „Eigenname“ → Name; Substantiv/Verb … → Allerweltswort.
    static func shareable(_ raw: String) -> String? {
        let w = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'„“”‚‘’«»()[]{}"))
        guard (2...40).contains(w.count), w.split(separator: " ").count <= 3, w.contains(where: { $0.isLetter }),
              !w.contains(where: { $0.isNewline }) else { return nil }
        guard !TrainingText.functionWords.contains(w.lowercased()) else { return nil }
        let parts = w.split(separator: " ").map(String.init)
        guard WordTrainer.looksLikeName(w) || parts.contains(where: properName) else { return nil }
        return w
    }

    /// Großgeschriebenes Wort, das im Systemwörterbuch fehlt oder dort als Eigenname steht
    static func properName(_ p: String) -> Bool {
        guard let f = p.first, f.isUppercase, p.count >= 2 else { return false }
        guard let def = DCSCopyTextDefinition(nil, p as CFString, CFRange(location: 0, length: (p as NSString).length))?
                .takeRetainedValue() as String?,
              def.lowercased().hasPrefix(p.lowercased()) else { return true }     // kein (passender) Eintrag
        let head = def.prefix(160).lowercased()
        return head.contains("eigenname") || head.contains("proper noun") || head.contains("proper name")
    }

    /// Steht das Wort (als Schreibweise oder als Gehörtes) schon im Wörterbuch?
    static func inDictionary(_ word: String, _ dict: [DictEntry]) -> Bool {
        let k = key(word)
        return dict.contains { key($0.write) == k || key($0.heard) == k }
    }

    static func typeLabel(_ t: String) -> String {
        NameKind(rawValue: t)?.label ?? "Begriff"
    }

    // MARK: Start (App)

    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: CVNames.vocab, object: nil, queue: .main) { [weak self] _ in
            self?.checkInbox()
            self?.retryWaiting()
        })
        observers.append(dnc.addObserver(forName: CVNames.result, object: nil, queue: .main) { [weak self] n in
            self?.handleResult(n.object as? String)
        })
        // Schon Angekommenes (Flow war aus) + noch nicht Verschicktes (ClipVault war aus/zu alt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.checkInbox(reshowPending: true)
            self?.retryWaiting()
        }
    }

    /// Ohne App (CLI): nur den Antwort-Kanal abonnieren
    func startHeadless() {
        headless = true
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: CVNames.result, object: nil, queue: .main) { [weak self] n in
            self?.handleResult(n.object as? String)
        })
    }

    // MARK: Senden (hier gelernt)

    /// Einstieg für alle Lernquellen. Main-Thread oder nicht – egal. Schickt nichts, was vom Partner kam oder schon raus ist.
    func learned(_ raw: String, kind: NameKind? = nil, source: PartnerVocabSource) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.learned(raw, kind: kind, source: source) }; return }
        guard let w = PartnerVocab.shareable(raw) else { return }
        let k = PartnerVocab.key(w)
        if received.contains(where: { PartnerVocab.key($0.word) == k }) { return }          // kam vom Partner
        if let s = sent.first(where: { PartnerVocab.key($0.word) == k }), s.status != .waiting { return }
        let type = (kind ?? NameKind.guess(w)).rawValue
        if let i = sent.firstIndex(where: { PartnerVocab.key($0.word) == k }) {
            sent[i].type = type
        } else {
            sent.append(PartnerSentWord(word: w, type: type, source: source, at: Date(), status: .waiting))
        }
        save()
        push(w, type: type)
    }

    private func push(_ w: String, type: String) {
        let k = PartnerVocab.key(w)
        let ok = send("sendVocab", ["word": w, "type": type]) { [weak self] ok, extra, err in
            guard let self, let i = self.sent.firstIndex(where: { PartnerVocab.key($0.word) == k }) else { return }
            self.sent[i].tries += 1
            if ok {
                let fresh = (extra["sent"] as? Bool) == true
                self.sent[i].status = fresh ? .sent : .known
                log("Gemeinsame Namen: „\(w)“ \(fresh ? "an \(Identity.partner(.accusative)) geschickt" : "schon bekannt – nicht erneut geschickt")")
            } else {
                log("Gemeinsame Namen: „\(w)“ wartet (\(err ?? "keine Antwort von ClipVault"))")
            }
            self.save()
        }
        if !ok { log("Gemeinsame Namen: „\(w)“ wartet (ClipVault-Befehlskanal fehlt)") }
    }

    /// Wartende nochmal versuchen (ClipVault lief nicht / war zu alt / nicht gekoppelt)
    func retryWaiting() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for s in sent where s.status == .waiting && s.at > cutoff && s.tries < 40 { push(s.word, type: s.type) }
    }

    // MARK: Empfangen (vom Partner)

    /// ClipVaults Posteingang lesen (vocab.json, `inbox: true`), ins eigene Protokoll übernehmen, bestätigen, fragen.
    @discardableResult
    func checkInbox(reshowPending: Bool = false) -> [PartnerWord] {
        let url = ClipVaultClient.base.appendingPathComponent("vocab.json")
        var fresh: [PartnerWord] = [], ackIDs: [String] = []
        if let data = try? Data(contentsOf: url),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let arr = o["items"] as? [[String: Any]] {
            let dict = Settings.shared.dictionary
            for d in arr where (d["inbox"] as? Bool) == true && (d["dir"] as? String) == "in" {
                guard let id = d["id"] as? String, let word = d["word"] as? String, !word.isEmpty else { continue }
                ackIDs.append(id)
                if received.contains(where: { $0.id.lowercased() == id.lowercased() || PartnerVocab.key($0.word) == PartnerVocab.key(word) }) { continue }
                let by = (d["by"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Identity.partner(.nominative, capitalized: true)
                var pw = PartnerWord(id: id, word: word, type: (d["type"] as? String) ?? "term", by: by, receivedAt: Date(), state: .pending)
                if PartnerVocab.inDictionary(word, dict) || sent.contains(where: { PartnerVocab.key($0.word) == PartnerVocab.key(word) }) {
                    pw.state = .known; pw.decidedAt = Date()                           // schon bekannt → keine Karte
                    log("Gemeinsame Namen: „\(word)“ von \(by) steht schon im Wörterbuch")
                }
                received.append(pw)
                if pw.state == .pending { fresh.append(pw) }
            }
        }
        if !ackIDs.isEmpty { save(); _ = send("vocabAck", ["ids": ackIDs.joined(separator: ",")], done: nil) }
        if autoAccept, !fresh.isEmpty {
            for w in fresh { accept(w.id, quiet: true) }
            toast(fresh.count == 1 ? "„\(fresh[0].word)“ von \(fresh[0].by) übernommen" : "\(fresh.count) Namen von \(fresh[0].by) übernommen")
            return fresh
        }
        var toShow = fresh
        if reshowPending {
            let week = Date().addingTimeInterval(-7 * 86400)
            toShow += received.filter { $0.state == .pending && $0.receivedAt > week && !fresh.contains($0) }
        }
        toShow = toShow.filter { !shownThisSession.contains($0.id) }
        if !toShow.isEmpty { present(toShow) }
        return fresh
    }

    // MARK: Entscheiden

    func accept(_ id: String, quiet: Bool = false) {
        guard let i = received.firstIndex(where: { $0.id == id }) else { return }
        let w = received[i]
        let st = Settings.shared
        if !PartnerVocab.inDictionary(w.word, st.dictionary) {
            let e = DictEntry(heard: w.word, write: w.word, learned: nil, vocabOnly: true)
            st.dictionary.append(e)
            st.save()
            received[i].dictID = e.id
        }
        received[i].state = .accepted; received[i].decidedAt = Date()
        save()
        VFNotify.shared.dismiss(id: "partner_wort_" + id)
        log("Gemeinsame Namen: „\(w.word)“ von \(w.by) übernommen (Hinweis fürs Wörterbuch)")
        if !quiet && !headless { toast("„\(w.word)“ steht jetzt im Wörterbuch") }
    }

    func decline(_ id: String) {
        guard let i = received.firstIndex(where: { $0.id == id }) else { return }
        received[i].state = .declined; received[i].decidedAt = Date()
        save()
        VFNotify.shared.dismiss(id: "partner_wort_" + id)
        log("Gemeinsame Namen: „\(received[i].word)“ abgelehnt")
    }

    /// „Vom Partner gelernt“ → Entfernen: Hinweis-Eintrag wieder raus (nur den, den das Übernehmen angelegt hat)
    func remove(_ id: String) {
        guard let i = received.firstIndex(where: { $0.id == id }) else { return }
        let w = received[i], st = Settings.shared
        st.dictionary.removeAll { e in
            if let d = w.dictID { return e.id == d }
            return e.vocabOnly == true && PartnerVocab.key(e.write) == PartnerVocab.key(w.word) && PartnerVocab.key(e.heard) == PartnerVocab.key(w.word)
        }
        st.save()
        received[i].state = .removed; received[i].decidedAt = Date(); received[i].dictID = nil
        save()
        log("Gemeinsame Namen: „\(w.word)“ aus dem Wörterbuch entfernt")
    }

    /// Nur Sichtprüfung: Einträge setzen, ohne zu speichern
    func setPreview(_ words: [PartnerWord]) { received = words }

    /// Anzeige im Wörterbuch: offene + übernommene, neueste zuerst
    var visible: [PartnerWord] {
        received.filter { $0.state == .pending || $0.state == .accepted }.sorted { a, b in
            if (a.state == .pending) != (b.state == .pending) { return a.state == .pending }
            return a.receivedAt > b.receivedAt
        }
    }

    // MARK: Karte aus der Pille

    private func present(_ words: [PartnerWord]) {
        if headless { words.forEach { shownThisSession.insert($0.id) }; onCards?(words); return }
        // nie mitten ins Diktat/Meeting
        if SmartFlow.shared.isBusy() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.present(words) }
            return
        }
        let open = words.filter { w in received.contains { $0.id == w.id && $0.state == .pending } }
        guard !open.isEmpty else { return }
        open.forEach { shownThisSession.insert($0.id) }
        if open.count >= 3 {
            VFNotify.shared.show(PartnerVocab.summaryNotice(open, acceptAll: { [weak self] in open.forEach { self?.accept($0.id, quiet: true) }
                self?.toast("\(open.count) Namen übernommen") },
                                                           review: { VoiceFlowWindow.shared.show(.woerterbuch) }))
        } else {
            for w in open {
                VFNotify.shared.show(PartnerVocab.notice(w, accept: { [weak self] in self?.accept(w.id) },
                                                         decline: { [weak self] in self?.decline(w.id) }))
            }
        }
    }

    static func notice(_ w: PartnerWord, accept: @escaping () -> Void, decline: @escaping () -> Void) -> VFNotice {
        let title: String
        switch w.type {
        case "person": title = "Neuer Name von \(w.by)"
        case "company": title = "Neue Firma von \(w.by)"
        case "place": title = "Neuer Ort von \(w.by)"
        default: title = "Neuer Begriff von \(w.by)"
        }
        return VFNotice(id: "partner_wort_" + w.id, title: title,
                        text: "\(w.by) hat „\(w.word)“ gelernt – übernehmen?",
                        illustration: "illu_wort_gelernt", fallbackSymbol: "character.book.closed.fill",
                        primary: ("Übernehmen", accept), secondary: ("Nein", decline),
                        timeout: 25)   // ✕/Zeitablauf: bleibt offen (Wörterbuch → „Vom Partner gelernt“)
    }

    static func summaryNotice(_ words: [PartnerWord], acceptAll: @escaping () -> Void, review: @escaping () -> Void) -> VFNotice {
        let by = Set(words.map(\.by)).count == 1 ? words[0].by : "Dein Partner"
        let list = words.prefix(3).map { "„\($0.word)“" }.joined(separator: ", ") + (words.count > 3 ? " …" : "")
        return VFNotice(id: "partner_wort_sammlung", title: "\(by) hat \(words.count) Namen gelernt",
                        text: "\(list) – alle übernehmen?",
                        illustration: "illu_wort_gelernt", fallbackSymbol: "character.book.closed.fill",
                        primary: ("Alle übernehmen", acceptAll), secondary: ("Ansehen", review), timeout: 30)
    }

    private func toast(_ s: String) {
        guard !headless else { print("Pille: \(s)"); return }
        (NSApp.delegate as? AppDelegate)?.pill?.view.showToast(s, seconds: 2.6)
    }

    // MARK: ClipVault-Befehlskanal (mit Test-Kanal bei CLIPVAULT_HOME)

    @discardableResult
    func send(_ action: String, _ fields: [String: Any], done: ((Bool, [String: Any], String?) -> Void)?) -> Bool {
        guard let t = try? String(contentsOf: ClipVaultClient.base.appendingPathComponent("token"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        let req = UUID().uuidString
        var o = fields; o["token"] = t; o["action"] = action; o["reqId"] = req
        guard let data = try? JSONSerialization.data(withJSONObject: o), let json = String(data: data, encoding: .utf8) else { return false }
        if let done {
            waiting[req] = done
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                if let d = self?.waiting.removeValue(forKey: req) { d(false, [:], "keine Antwort von ClipVault") }
            }
        }
        DistributedNotificationCenter.default().postNotificationName(CVNames.command, object: json, userInfo: nil, deliverImmediately: true)
        return true
    }

    private func handleResult(_ json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let req = o["reqId"] as? String, let done = waiting.removeValue(forKey: req) else { return }
        done((o["ok"] as? Bool) == true, o, o["error"] as? String)
    }
}

/// Meldungsnamen wie ClipVault sie benutzt (Test-Instanzen mit CLIPVAULT_HOME hängen eine Kennung an)
enum CVNames {
    static let suffix: String = {
        guard let raw = ProcessInfo.processInfo.environment["CLIPVAULT_HOME"], !raw.isEmpty else { return "" }
        let p = (raw as NSString).expandingTildeInPath
        var h: UInt64 = 1469598103934665603
        for b in p.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "." + String(UInt32(truncatingIfNeeded: h))
    }()
    static let command = Notification.Name("app.flowdictation.clipvault.cmd" + suffix)
    static let result = Notification.Name("app.flowdictation.clipvault.result" + suffix)
    static let vocab = Notification.Name("app.flowdictation.clipvault.vocab" + suffix)
}

// MARK: - Wörterbuch: „Vom Partner gelernt“

struct PartnerVocabSection: View {
    @ObservedObject var pv: PartnerVocab
    @ObservedObject private var s = Settings.shared
    init(pv: PartnerVocab = .shared) { self.pv = pv }

    private var partner: String { Identity.partner(.nominative, capitalized: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vom Partner gelernt").font(.system(size: 24, weight: .semibold)).foregroundStyle(VF.ink)
            Text("Namen und Begriffe, die \(partner) gelernt hat. Es kommt nur das Wort an – nie Stimme, Aussprache oder Verhörer.")
                .font(.system(size: 16)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)

            VStack(spacing: 0) {
                PGSettingRow(title: "Namen vom Partner automatisch übernehmen",
                             detail: "Aus: Flow fragt kurz an der Pille. An: sofort ins Wörterbuch, nur ein kurzer Hinweis.") {
                    Toggle("", isOn: $pv.autoAccept).toggleStyle(.switch).labelsHidden().tint(VF.black)
                }
                .padding(.horizontal, 22)
            }
            .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.card))
            .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline, lineWidth: 1))
            .padding(.top, 18)

            Group {
                if pv.visible.isEmpty {
                    Text("Noch nichts – sobald \(partner) einen Namen lernt, erscheint er hier.")
                        .font(.system(size: 16)).foregroundStyle(VF.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.vertical, 24)
                        .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.card))
                        .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline, lineWidth: 1))
                } else {
                    PGListCard(items: pv.visible) { w in row(w) }
                }
            }
            .padding(.top, 14)
        }
    }

    private func row(_ w: PartnerWord) -> some View {
        PGRow {
            HStack(spacing: 10) {
                Text(w.word).font(PG.rowFont).foregroundStyle(VF.ink).lineLimit(1)
                Text(PartnerVocab.typeLabel(w.type))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(VF.muted)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(VF.buttonSoft))
                Text("von \(w.by) · \(CVFormat.relative(w.receivedAt))").font(.system(size: 14.5)).foregroundStyle(VF.muted).lineLimit(1)
                if w.state == .pending {
                    Spacer(minLength: 12)
                    Button("Übernehmen") { pv.accept(w.id) }.buttonStyle(PGSoftButtonStyle(height: 36, fill: VF.teal4))
                    Button("Nein") { pv.decline(w.id) }.buttonStyle(PGSoftButtonStyle(height: 36))
                }
            }
        } actions: {
            if w.state == .accepted {
                PGIconButton(symbol: "trash", help: "Aus dem Wörterbuch entfernen") { pv.remove(w.id) }
            }
        }
    }
}
