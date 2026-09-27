// ClipVault — Gemeinsame Namen: unsichtbare Eintraege „vocab" im geteilten Tresor
//
// Lernt die Diktat-App auf einem Mac einen Namen/Begriff (Korrektur, Training, Vorschlag, von Hand),
// schickt sie NUR das Wort hierher:  Befehl `sendVocab` (word, type, by). ClipVault verschickt es wie einen
// geteilten Eintrag (Ende-zu-Ende verschluesselt, gleicher Server, gleiche Warteschlange), zeigt es aber
// NIRGENDS an: nicht im Panel, nicht in „Geteilt", kein gruener Punkt, zaehlt nicht bei „Neu".
// Beim Partner landet es in vocab.json (Posteingang) + Meldung `app.flowdictation.clipvault.vocab`.
//
// Rueckwaertskompatibel OHNE Versionsabfrage: fuer aeltere ClipVaults sieht das Paket wie ein Grabstein aus
// (Kopf `kind: "vocab"`, `deleted: true`, kein Text). Alle bisherigen Fassungen machen daraus einen geloeschten
// Text-Eintrag, den sie nie anzeigen (auch nicht in Flows Geteilt-Liste, die geloeschte auslaesst).
// Das Wort steht im Kopf-Feld `vocab`, das aeltere Decoder ueberspringen. Beim Server ist es KEIN Grabstein
// (X-CV-Deleted: 0), damit /since es auch Geraeten liefert, die die id noch nicht kennen.
//
// Gleiches Wort = gleiche id auf beiden Seiten (HMAC mit einem Schluessel aus dem Tresor-Schluessel, der Server kann
// die id also nicht zu einem Wort zurueckraten) -> kein Ping-Pong, keine Doppelten.
import Cocoa
import CryptoKit

struct VocabEntry: Codable, Equatable {
    let id: String
    var word: String
    var type: String             // person | company | place | term
    var by: String               // wer es gelernt hat („Lena")
    var createdAt: Double        // Unix-s
    var updatedAt: Double
    var dir: String              // "out" = selbst gelernt/geschickt · "in" = vom Partner
    var inbox: Bool? = nil       // true = von der Diktat-App noch nicht abgeholt (vocabAck)
    var receivedAt: Double? = nil
}

final class VocabStore {
    static let shared = VocabStore()
    static let types = ["person", "company", "place", "term"]
    static let maxEntries = 2000
    static let notifyName = Notification.Name("app.flowdictation.clipvault.vocab" + CV_NOTIFY_SUFFIX)
    var path: String { CV_DIR + "vocab.json" }
    private(set) var entries: [VocabEntry] = []

    private struct Disk: Codable { var version = 1; var items: [VocabEntry] }

    init() { load() }
    func load() {
        guard let d = FileManager.default.contents(atPath: path), let disk = try? JSONDecoder().decode(Disk.self, from: d) else { return }
        entries = disk.items
    }
    private func persist() {
        guard !CV_READ_ONLY else { return }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(Disk(items: entries)) { SyncFiles.writePrivate(d, path) }
    }

    // ---- Regeln ----
    /// Vergleichs-Schluessel: Unicode-normalisiert, Leerraum vereinheitlicht, klein (Umlaute bleiben verschieden)
    static func key(_ w: String) -> String {
        w.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
    /// Gueltiges Wort? 2–60 Zeichen, hoechstens 4 Woerter, mindestens ein Buchstabe, keine Steuerzeichen
    static func clean(_ raw: String) -> String? {
        let w = raw.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard (2...60).contains(w.count), w.split(separator: " ").count <= 4, w.contains(where: { $0.isLetter }),
              !w.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return w
    }
    static func type(_ t: String?) -> String { let l = (t ?? "").lowercased(); return types.contains(l) ? l : "term" }
    /// id = UUID-Form von HMAC-SHA256(Schluessel aus dem Tresor-Schluessel, Wort-Schluessel)
    static func id(for word: String, idKey: SymmetricKey) -> String {
        var b = [UInt8](HMAC<SHA256>.authenticationCode(for: Data("clipvault-vocab|v1|\(key(word))".utf8), using: idKey).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50; b[8] = (b[8] & 0x3F) | 0x80
        let t: uuid_t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        return UUID(uuid: t).uuidString
    }
    static func idKey(vaultKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data("clipvault-vocab-id|v1".utf8), outputByteCount: 32)
    }

    // ---- Lesen ----
    func entry(_ id: String) -> VocabEntry? { entries.first { $0.id.lowercased() == id.lowercased() } }
    var inbox: [VocabEntry] { entries.filter { $0.inbox == true }.sorted { $0.createdAt > $1.createdAt } }

    // ---- Lokal gelernt -> verschicken ----
    enum SendOutcome { case queued(VocabEntry), known(VocabEntry) }
    /// Legt ein eigenes Wort an. Schon bekannt (selbst geschickt ODER vom Partner bekommen) -> nichts verschicken.
    func learnedLocally(word: String, type: String, by: String, idKey: SymmetricKey) -> SendOutcome {
        let id = VocabStore.id(for: word, idKey: idKey)
        if let e = entry(id) { return .known(e) }
        let now = Date().timeIntervalSince1970
        let e = VocabEntry(id: id, word: word, type: type, by: by, createdAt: now, updatedAt: now, dir: "out")
        entries.append(e); trim(); persist()
        return .queued(e)
    }

    // ---- Vom Backend ----
    /// Wort vom Server uebernehmen. Rueckgabe: true = neu im Posteingang.
    @discardableResult func applyRemote(_ r: VocabEntry, me: String) -> Bool {
        if let i = entries.firstIndex(where: { $0.id.lowercased() == r.id.lowercased() }) {
            guard r.updatedAt > entries[i].updatedAt + 0.000_5 else { return false }
            // Schon bekannt (auch selbst gelernt) -> nur Stand nachziehen, NIE erneut in den Posteingang
            entries[i].word = r.word; entries[i].type = r.type; entries[i].by = r.by; entries[i].updatedAt = r.updatedAt
            persist(); return false
        }
        var e = r
        let mine = r.by.lowercased() == me.lowercased()          // eigenes Wort (anderer Mac / Neuinstallation)
        e.dir = mine ? "out" : "in"; e.inbox = mine ? nil : true; e.receivedAt = Date().timeIntervalSince1970
        entries.append(e); trim(); persist()
        if !mine { cvLog("Gemeinsame Namen: neues Wort von \(r.by)") }
        return !mine
    }
    /// Posteingang geleert (Diktat-App hat gefragt/uebernommen/abgelehnt). Rueckgabe: bestaetigte ids.
    func ack(_ ids: [String]?) -> [String] {
        var out: [String] = []
        for i in entries.indices where entries[i].inbox == true {
            if let ids, !ids.contains(where: { $0.lowercased() == entries[i].id.lowercased() }) { continue }
            entries[i].inbox = nil; out.append(entries[i].id)
        }
        if !out.isEmpty { persist() }
        return out
    }
    private func trim() {
        guard entries.count > VocabStore.maxEntries else { return }
        let drop = entries.enumerated().filter { $0.element.inbox != true }.sorted { $0.element.updatedAt < $1.element.updatedAt }
            .prefix(entries.count - VocabStore.maxEntries).map(\.offset)
        for i in drop.sorted(by: >) { entries.remove(at: i) }
    }
    static func notifyInbox() {
        DistributedNotificationCenter.default().postNotificationName(notifyName, object: nil, userInfo: nil, deliverImmediately: true)
    }
    static func json(_ e: VocabEntry) -> [String: Any] {
        ["id": e.id, "word": e.word, "type": e.type, "by": e.by, "createdAt": e.createdAt, "dir": e.dir, "inbox": e.inbox == true]
    }
}
