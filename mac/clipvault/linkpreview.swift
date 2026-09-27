// ClipVault — Website-Vorschau fuer Link-Eintraege
import Cocoa
import Carbon.HIToolbox
import QuartzCore
import QuickLookThumbnailing
import WebKit
import CryptoKit

// MARK: - LinkPreview — Website-Screenshot fuer Link-Eintraege (offscreen WKWebView, Cache auf Platte)
final class LinkPreview {
    static let shared = LinkPreview()
    let dir = Store.shared.dir.appendingPathComponent("linkprev")
    private var mem = [String: NSImage]()
    private var titles = [String: String]()      // "" = geholt, kein Titel
    private var failed = Set<String>()           // nur fuer diese Session, naechster Start = neuer Versuch
    private var waiting: [(URL, String)] = []
    private var active = [String: PreviewFetch]()
    private var callbacks = [String: [(NSImage?, String?) -> Void]]()
    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // alte Vorschauen aufraeumen (>14 Tage)
        if let fs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-14*24*3600)
            for f in fs { if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < cutoff { try? FileManager.default.removeItem(at: f) } }
        }
    }
    func key(_ url: URL) -> String {
        let d = SHA256.hash(data: Data(url.absoluteString.utf8))
        return d.map { String(format: "%02x", $0) }.prefix(16).joined()
    }
    func cachedImage(_ url: URL) -> NSImage? {
        let k = key(url)
        if let i = mem[k] { return i }
        if let i = NSImage(contentsOf: dir.appendingPathComponent(k + ".png")) {
            if mem.count > 12 { mem.removeAll() }   // RAM-Deckel, Platte bleibt (Nachladen ist billig)
            mem[k] = i; loadTitle(k); return i
        }
        return nil
    }
    func title(_ url: URL) -> String? {
        let k = key(url); loadTitle(k)
        return titles[k].flatMap { $0.isEmpty ? nil : $0 }
    }
    private func loadTitle(_ k: String) {
        if titles[k] == nil, let t = try? String(contentsOf: dir.appendingPathComponent(k + ".txt"), encoding: .utf8) { titles[k] = t }
    }
    func fetch(_ url: URL, _ cb: @escaping (NSImage?, String?) -> Void) {
        let k = key(url)
        if let i = cachedImage(url) { cb(i, title(url)); return }
        if failed.contains(k) { cb(nil, title(url)); return }
        callbacks[k, default: []].append(cb)
        if active[k] != nil || waiting.contains(where: { $0.1 == k }) { return }
        waiting.append((url, k)); pump()
    }
    private func pump() {
        while active.count < 2, !waiting.isEmpty {   // max 2 WebViews gleichzeitig
            let (url, k) = waiting.removeFirst()
            let f = PreviewFetch(url: url) { [weak self] img, title in
                guard let self = self else { return }
                self.active[k] = nil
                if let img = img {
                    if self.mem.count > 12 { self.mem.removeAll() }
                    self.mem[k] = img
                    if let png = img.pngData() { try? png.write(to: self.dir.appendingPathComponent(k + ".png")) }
                } else { self.failed.insert(k) }
                self.titles[k] = title ?? ""
                try? (title ?? "").write(to: self.dir.appendingPathComponent(k + ".txt"), atomically: true, encoding: .utf8)
                let cbs = self.callbacks[k] ?? []; self.callbacks[k] = nil
                for c in cbs { c(img, title) }
                self.pump()
            }
            active[k] = f; f.start()
        }
    }
}
final class PreviewFetch: NSObject, WKNavigationDelegate {
    let url: URL; let done: (NSImage?, String?) -> Void
    var web: WKWebView?
    var finished = false
    var timeout: Timer?
    init(url: URL, done: @escaping (NSImage?, String?) -> Void) { self.url = url; self.done = done }
    func start() {
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760), configuration: cfg)
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        w.navigationDelegate = self; web = w
        w.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10))
        timeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.snap() }  // notfalls Teilstand knipsen
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // kurz warten bis JS/Bilder gemalt sind (Shops laden Produktbilder lazy nach)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in self?.snap() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
    func fail() {
        guard !finished else { return }
        finished = true; timeout?.invalidate()
        let t = web?.title; cleanup(); done(nil, t)
    }
    func snap() {
        guard !finished, let w = web else { return }
        finished = true; timeout?.invalidate()
        let conf = WKSnapshotConfiguration(); conf.snapshotWidth = NSNumber(value: 520)
        let title = w.title
        w.takeSnapshot(with: conf) { [weak self] img, _ in
            self?.cleanup(); self?.done(img, title)
        }
    }
    func cleanup() { web?.navigationDelegate = nil; web?.stopLoading(); web = nil }
}
