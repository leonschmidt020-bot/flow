// Test vectors for the Windows ClipVault sync client. Code copied 1:1 from clipvault/sync.swift,
// vocab.swift and shared.swift (27.09.2026); only the random parts are replaced by fixed inputs.
import Foundation
import CryptoKit

struct VocabWire: Codable { var word: String; var type: String }
struct Header: Codable {
    var v = 1
    var id: String; var kind: String; var text: String?; var fileName: String?
    var createdBy: String; var createdAt: Double; var updatedAt: Double; var pinned: Bool; var deleted: Bool
    var big: String? = nil
    var size: Int64? = nil
    var parts: Int? = nil
    var partSize: Int? = nil
    var content: String? = nil
    var sourceId: String? = nil
    var vocab: VocabWire? = nil
}
func aad(vault: String, id: String) -> Data { Data("clipvault-item|v1|\(vault.lowercased())|\(id.lowercased())".utf8) }
func partAAD(vault: String, id: String, content: String, idx: Int, count: Int) -> Data {
    Data("clipvault-part|v2|\(vault.lowercased())|\(id.lowercased())|\(content.lowercased())|\(idx)/\(count)".utf8)
}
func frame(_ h: Header, body: Data) throws -> Data {
    let head = try JSONEncoder().encode(h)
    var d = Data("CVS1".utf8)
    var n = UInt32(head.count).bigEndian
    withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
    d.append(head); d.append(body)
    return d
}
func hexData(_ h: String) -> Data {
    var d = Data(); var i = h.startIndex
    while i < h.endIndex, let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex), let v = UInt8(h[i..<j], radix: 16) { d.append(v); i = j }
    return d
}
extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
func uuidBytes(_ s: String) -> Data { let u = UUID(uuidString: s)!; return withUnsafeBytes(of: u.uuid) { Data($0) } }
func pairEncode(url: String, vaultId: String, secret: String, key: Data) -> String {
    var d = Data([1])
    d.append(uuidBytes(vaultId)); d.append(hexData(secret)); d.append(key); d.append(Data(url.utf8))
    return "cvpair1." + d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func vkey(_ w: String) -> String { w.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
func vocabId(_ word: String, idKey: SymmetricKey) -> String {
    var b = [UInt8](HMAC<SHA256>.authenticationCode(for: Data("clipvault-vocab|v1|\(vkey(word))".utf8), using: idKey).prefix(16))
    b[6] = (b[6] & 0x0F) | 0x50; b[8] = (b[8] & 0x3F) | 0x80
    let t: uuid_t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    return UUID(uuid: t).uuidString
}
func derivedId(_ base: String, _ n: Int) -> String {
    if n == 0 { return base }
    var b = [UInt8](SHA256.hash(data: Data("clipvault-multi|\(base.lowercased())|\(n)".utf8)).prefix(16))
    b[6] = (b[6] & 0x0F) | 0x50; b[8] = (b[8] & 0x3F) | 0x80
    let t: uuid_t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    return UUID(uuid: t).uuidString
}
func seal(_ plain: Data, key: SymmetricKey, aad: Data, nonce: Data) -> Data {
    try! AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad).combined!
}

let keyData = Data((0..<32).map { UInt8($0) })                 // 00 01 … 1f
let key = SymmetricKey(data: keyData)
let vault = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
let nonce1 = Data((0..<12).map { UInt8(0xa0 + $0) })
let nonce2 = Data((0..<12).map { UInt8(0xb0 + $0) })
let nonce3 = Data((0..<12).map { UInt8(0xc0 + $0) })
let nonce4 = Data((0..<12).map { UInt8(0xd0 + $0) })

var out: [String: Any] = ["key": keyData.hex, "vault": vault]

// 1. text item
let tid = "6FA459EA-EE8A-3CA4-894E-DB77E160355E"
let th = Header(id: tid, kind: "text", text: "Hallo Nico – ünïcødé ✓ https://example.com/a?b=c", fileName: nil, createdBy: "Lena",
                createdAt: 1790438950.7, updatedAt: 1790438951.25, pinned: false, deleted: false)
let tplain = try! frame(th, body: Data())
out["text"] = ["id": tid, "plain": tplain.hex, "nonce": nonce1.hex, "sealed": seal(tplain, key: key, aad: aad(vault: vault, id: tid), nonce: nonce1).hex]

// 2. image item (small body)
let iid = "1B4E28BA-2FA1-41D2-883F-0016D3CCA427"
let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5])
var ih = Header(id: iid, kind: "image", text: "OCR-Text", fileName: nil, createdBy: "Nico", createdAt: 1790000000, updatedAt: 1790000000.5, pinned: true, deleted: false)
ih.size = Int64(png.count)
let iplain = try! frame(ih, body: png)
out["image"] = ["id": iid, "plain": iplain.hex, "nonce": nonce2.hex, "sealed": seal(iplain, key: key, aad: aad(vault: vault, id: iid), nonce: nonce2).hex]

// 3. big file manifest + one part
let bid = "C823F321-9C4B-4F7E-8D3A-2B1C0D9E8F7A"
let content = "00112233445566778899aabbccddeeff"
var bh = Header(id: bid, kind: "bigfile", text: "Datei „Video.mp4\" (5,2 MB) — zum Öffnen ClipVault aktualisieren.", fileName: "Video.mp4", createdBy: "Lena",
                createdAt: 1790100000.125, updatedAt: 1790100001.5, pinned: false, deleted: false)
bh.v = 2; bh.big = "file"; bh.size = 5 * 1024 * 1024 + 12345; bh.parts = 6; bh.partSize = 1024 * 1024; bh.content = content
bh.sourceId = "6FA459EA-EE8A-3CA4-894E-DB77E160355E"
let bplain = try! frame(bh, body: Data())
let part = Data((0..<64).map { UInt8($0 ^ 0x5a) })
out["big"] = ["id": bid, "plain": bplain.hex, "nonce": nonce3.hex, "sealed": seal(bplain, key: key, aad: aad(vault: vault, id: bid), nonce: nonce3).hex,
              "part": ["idx": 5, "count": 6, "plain": part.hex, "nonce": nonce4.hex,
                       "aad": String(data: partAAD(vault: vault, id: bid, content: content, idx: 5, count: 6), encoding: .utf8)!,
                       "sealed": seal(part, key: key, aad: partAAD(vault: vault, id: bid, content: content, idx: 5, count: 6), nonce: nonce4).hex]]

// 4. tombstone
let dh = Header(id: tid, kind: "text", text: nil, fileName: nil, createdBy: "Lena", createdAt: 1790438950.7, updatedAt: 1790439000, pinned: false, deleted: true)
out["tombstone"] = ["id": tid, "plain": try! frame(dh, body: Data()).hex]

// 5. vocab
let idKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("clipvault-vocab-id|v1".utf8), outputByteCount: 32)
let words = ["Brandauer", "  Karl   Mustermann ", "Müller", "Mu\u{0308}ller", "ÄRZTE"]
out["vocab"] = ["idKey": idKey.withUnsafeBytes { Data($0) }.hex,
                "words": words.map { ["word": $0, "key": vkey($0), "id": vocabId($0, idKey: idKey)] }]
var vh = Header(id: vocabId("Brandauer", idKey: idKey), kind: "vocab", text: nil, fileName: nil, createdBy: "Lena", createdAt: 1790456424.33, updatedAt: 1790456424.33, pinned: false, deleted: true)
vh.vocab = VocabWire(word: "Brandauer", type: "person")
out["vocabItem"] = ["plain": try! frame(vh, body: Data()).hex]

// 6. pairing code
let secret = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
out["pair"] = ["url": "https://clipvault-sync.example.workers.dev", "vault": vault, "secret": secret, "key": keyData.hex,
               "code": pairEncode(url: "https://clipvault-sync.example.workers.dev", vaultId: vault, secret: secret, key: keyData)]

// 7. derived ids for multi-file shares
out["derived"] = [["base": tid, "n": 1, "id": derivedId(tid, 1)], ["base": tid, "n": 2, "id": derivedId(tid, 2)]]

// 8. decode a TS-produced vector if given (argv[1] = hex frame sealed, argv[2] = id)
if CommandLine.arguments.count >= 3 {
    let box = hexData(CommandLine.arguments[1]); let id = CommandLine.arguments[2]
    do {
        let p = try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: aad(vault: vault, id: id))
        let n = p.subdata(in: 4..<8).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        let h = try JSONDecoder().decode(Header.self, from: p.subdata(in: 8..<(8 + n)))
        print("SWIFT-DECODE-OK kind=\(h.kind) text=\(h.text ?? "-") by=\(h.createdBy) body=\(p.count - 8 - n)")
    } catch { print("SWIFT-DECODE-FAIL \(error)") }
    exit(0)
}
let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
