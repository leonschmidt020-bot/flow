import AppKit
import CoreText

// MARK: - Künstliches Meeting zum Testen (Zoom-ähnliches Fenster)
//
// Oben Leiste mit tickender Uhr, rechts 3 Teilnehmer-Videos (Rauschen + Bewegung + Sprecher-Rahmen), unten Knopfleiste,
// Mitte: geteilter Inhalt – Folien (teils mit Aufbau-Stufen), Diagramme/Tabellen, ein Dokument, das gescrollt wird,
// Code, der Zeile für Zeile getippt wird, und Galerie-Ansicht (nur Videos, nichts geteilt).
// Zeitplan deterministisch (fester Zufallswert) → wiederholbare Messungen. `speed` staucht alle Dauern.

final class MCSynthMeeting {
    enum Content: Equatable {
        case gallery
        case slide(Int, build: Int)
        case doc(offset: Double)
        case code(lines: Int)
    }

    struct Span { var t0: Double; var t1: Double; var content: Content; var key: String; var scrolling = false }

    struct Slide {
        var title: String
        var bullets: [String]
        var kind: Kind
        var builds: Int
        enum Kind { case bullets, chart, table, design }
    }

    let duration: Double
    private(set) var spans: [Span] = []
    let slides: [Slide]
    private var rng: UInt64 = 0x9E3779B97F4A7C15

    init(duration: Double = 3600, speed: Double = 1, seed: UInt64 = 7) {
        self.duration = duration
        rng = seed &* 0x9E3779B97F4A7C15 | 1
        slides = MCSynthMeeting.deck
        build(speed: speed)
    }

    private func rand() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng % 1_000_000) / 1_000_000
    }

    private func build(speed: Double) {
        var t = 0.0
        func add(_ d: Double, _ c: Content, _ key: String, scrolling: Bool = false) {
            spans.append(Span(t0: t, t1: t + d / speed, content: c, key: key, scrolling: scrolling)); t += d / speed
        }
        func slideDur() -> Double { 25 + pow(rand(), 1.6) * 190 }   // 25 … 215 s, meist ~70
        func slidesBlock(_ r: Range<Int>) {
            for i in r {
                let s = slides[i % slides.count]
                if s.builds > 1 {
                    for b in 1..<s.builds { add(4 + rand() * 6, .slide(i, build: b), "slide-\(i)") }
                }
                add(slideDur(), .slide(i, build: s.builds), "slide-\(i)")
            }
        }
        add(110, .gallery, "gallery")
        slidesBlock(0..<11)
        // Dokument scrollen: 4 Ruhe-Positionen, dazwischen 5 s Scrollen
        var off = 0.0
        for k in 0..<5 {
            add(35 + rand() * 40, .doc(offset: off), "doc-\(k)")
            if k < 4 { for s in 0..<5 { add(1, .doc(offset: off + Double(s + 1) * 0.07), "doc-scroll", scrolling: true) }; off += 0.35 }
        }
        slidesBlock(11..<19)
        // Code live tippen: alle 2,5 s eine Zeile, dann stehen lassen
        for l in 1...30 { add(2.5, .code(lines: l), "code-typing") }
        add(70, .code(lines: 30), "code-final")
        add(170, .gallery, "gallery")
        slidesBlock(19..<60)
        spans = spans.filter { $0.t0 < duration }
        if let last = spans.indices.last { spans[last].t1 = min(spans[last].t1, duration) }
    }

    func span(at t: Double) -> Span {
        var lo = 0, hi = spans.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if spans[mid].t0 <= t { lo = mid } else { hi = mid - 1 } }
        return spans[max(0, lo)]
    }

    /// Wichtige Inhalte, die als Bild auftauchen sollten (Folien, Dokument-Positionen, fertiger Code) – ≥ 8 s sichtbar
    var targets: [(key: String, t0: Double, t1: Double)] {
        var map: [String: (Double, Double)] = [:]
        var order: [String] = []
        for s in spans where s.key != "gallery" && s.key != "doc-scroll" && s.key != "code-typing" {
            if let e = map[s.key] { map[s.key] = (e.0, max(e.1, s.t1)) } else { map[s.key] = (s.t0, s.t1); order.append(s.key) }
        }
        return order.compactMap { k in map[k].flatMap { $0.1 - $0.0 >= 8 ? (k, $0.0, $0.1) : nil } }
    }

    // MARK: Zeichnen

    /// Zeichnet das Fenster zum Zeitpunkt t (Koordinaten oben links, Größe w×h) in einen BGRA-Kontext
    func render(t: Double, frameNo: Int, into ctx: CGContext, w: CGFloat, h: CGFloat) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
        let k = w / 1280
        ctx.scaleBy(x: k, y: k)
        let W: CGFloat = 1280, H: CGFloat = h / k
        fill(ctx, CGRect(x: 0, y: 0, width: W, height: H), gray: 0.11)
        // Kopfleiste mit Uhr
        fill(ctx, CGRect(x: 0, y: 0, width: W, height: 36), gray: 0.16)
        text("Zoom-Meeting (Test) · Wochenplanung", at: CGPoint(x: 16, y: 9), size: 13, color: .white)
        text(String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60), at: CGPoint(x: W - 70, y: 9), size: 13, color: NSColor(white: 0.8, alpha: 1), mono: true)
        // Knopfleiste
        fill(ctx, CGRect(x: 0, y: H - 56, width: W, height: 56), gray: 0.14)
        for (i, l) in ["Stumm", "Video", "Teilnehmer", "Chat", "Teilen", "Aufnahme"].enumerated() {
            text(l, at: CGPoint(x: 330 + CGFloat(i) * 105, y: H - 36), size: 12, color: NSColor(white: 0.85, alpha: 1))
        }
        text("Verlassen", at: CGPoint(x: W - 100, y: H - 36), size: 12, color: .systemRed)
        let sp = span(at: t)
        let main = CGRect(x: 0, y: 36, width: W, height: H - 92)
        switch sp.content {
        case .gallery:
            let cw = main.width / 2, ch = main.height / 2
            for i in 0..<4 { videoTile(ctx, CGRect(x: CGFloat(i % 2) * cw + 4, y: main.minY + CGFloat(i / 2) * ch + 4, width: cw - 8, height: ch - 8), i: i, t: t, frameNo: frameNo) }
        default:
            let content = CGRect(x: main.minX + 12, y: main.minY + 12, width: main.width - 290, height: main.height - 24)
            fill(ctx, content, gray: 0.07)
            for i in 0..<3 { videoTile(ctx, CGRect(x: main.maxX - 266, y: main.minY + 12 + CGFloat(i) * 170, width: 254, height: 160), i: i, t: t, frameNo: frameNo) }
            // 16:9-Folie in den Inhaltsbereich einpassen
            let sw = min(content.width, content.height * 16 / 9), sh = sw * 9 / 16
            let slideR = CGRect(x: content.midX - sw / 2, y: content.midY - sh / 2, width: sw, height: sh)
            ctx.saveGState(); ctx.clip(to: content)
            switch sp.content {
            case .slide(let i, let b): drawSlide(ctx, slideR, slides[i % slides.count], index: i, build: b)
            case .doc(let off): drawDoc(ctx, content, offset: off)
            case .code(let n): drawCode(ctx, content, lines: n)
            case .gallery: break
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func videoTile(_ ctx: CGContext, _ r: CGRect, i: Int, t: Double, frameNo: Int) {
        let base: [(CGFloat, CGFloat, CGFloat)] = [(0.35, 0.28, 0.22), (0.22, 0.30, 0.36), (0.30, 0.34, 0.26), (0.34, 0.25, 0.32)]
        let c = base[i % base.count]
        // Beleuchtung schwankt leicht (Kamera-Automatik)
        let flick = CGFloat(0.03 * sin(t * 1.3 + Double(i)))
        ctx.setFillColor(CGColor(red: c.0 + flick, green: c.1 + flick, blue: c.2 + flick, alpha: 1)); ctx.fill(r)
        // Kopf + Schultern bewegen sich
        let hx = r.midX + CGFloat(sin(t * 0.9 + Double(i) * 2)) * r.width * 0.06
        let hy = r.minY + r.height * 0.42 + CGFloat(sin(t * 1.7 + Double(i))) * r.height * 0.03
        ctx.setFillColor(CGColor(red: 0.85, green: 0.68, blue: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: hx - r.width * 0.11, y: hy - r.height * 0.2, width: r.width * 0.22, height: r.height * 0.36))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.25, blue: 0.4, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: hx - r.width * 0.25, y: hy + r.height * 0.15, width: r.width * 0.5, height: r.height * 0.5))
        // Mund bewegt sich beim Sprechen, Kompressionsrauschen in Blöcken
        var s = UInt64(frameNo &* 2654435761 &+ i &* 97) | 1
        for _ in 0..<26 {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            let bx = r.minX + CGFloat(s % 1000) / 1000 * (r.width - 16)
            let by = r.minY + CGFloat((s >> 12) % 1000) / 1000 * (r.height - 16)
            let v = CGFloat((s >> 24) % 100) / 100
            ctx.setFillColor(CGColor(gray: v, alpha: 0.10)); ctx.fill(CGRect(x: bx, y: by, width: 16, height: 16))
        }
        // aktiver Sprecher wechselt alle ~11 s
        if Int(t / 11) % 3 == i { ctx.setStrokeColor(CGColor(red: 0.3, green: 0.85, blue: 0.3, alpha: 1)); ctx.setLineWidth(3); ctx.stroke(r.insetBy(dx: 1.5, dy: 1.5)) }
        let names = ["Alex", "Sophie", "Mika", "Jonas"]
        fill(ctx, CGRect(x: r.minX + 6, y: r.maxY - 24, width: 60, height: 18), gray: 0, alpha: 0.5)
        text(names[i % names.count], at: CGPoint(x: r.minX + 10, y: r.maxY - 22), size: 11, color: .white)
    }

    private func drawSlide(_ ctx: CGContext, _ r: CGRect, _ s: Slide, index: Int, build: Int) {
        let k = r.width / 960
        fill(ctx, r, gray: 1)
        ctx.setFillColor(CGColor(red: 0.20, green: 0.33, blue: 0.62, alpha: 1)); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 8 * k))
        text(s.title, at: CGPoint(x: r.minX + 48 * k, y: r.minY + 36 * k), size: 38 * k, color: NSColor(white: 0.1, alpha: 1), bold: true)
        switch s.kind {
        case .bullets, .design:
            let shown = s.builds > 1 ? Array(s.bullets.prefix(max(1, Int(ceil(Double(s.bullets.count) * Double(build) / Double(s.builds)))))) : s.bullets
            for (i, b) in shown.enumerated() {
                text("•  " + b, at: CGPoint(x: r.minX + 60 * k, y: r.minY + (120 + CGFloat(i) * 52) * k), size: 25 * k, color: NSColor(white: 0.2, alpha: 1))
            }
            if s.kind == .design {
                ctx.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1))
                ctx.fill(CGRect(x: r.minX + 620 * k, y: r.minY + 130 * k, width: 280 * k, height: 180 * k))
                text("Jetzt anmelden", at: CGPoint(x: r.minX + 670 * k, y: r.minY + 200 * k), size: 24 * k, color: .white, bold: true)
            }
        case .chart:
            let vals = s.bullets.compactMap { b -> (String, Double)? in
                let p = b.split(separator: ":"); guard p.count == 2, let v = Double(p[1].trimmingCharacters(in: .whitespaces)) else { return nil }
                return (String(p[0]), v)
            }
            let mx = vals.map(\.1).max() ?? 1
            for (i, (l, v)) in vals.enumerated() {
                let bh = CGFloat(v / mx) * 300 * k
                let x = r.minX + (90 + CGFloat(i) * 140) * k
                ctx.setFillColor(CGColor(red: 0.25, green: 0.45, blue: 0.75, alpha: 1))
                ctx.fill(CGRect(x: x, y: r.minY + 470 * k - bh, width: 90 * k, height: bh))
                text(l, at: CGPoint(x: x, y: r.minY + 480 * k), size: 20 * k, color: NSColor(white: 0.2, alpha: 1))
                text(String(Int(v)), at: CGPoint(x: x + 8 * k, y: r.minY + 440 * k - bh), size: 20 * k, color: NSColor(white: 0.2, alpha: 1), bold: true)
            }
        case .table:
            for (i, row) in s.bullets.enumerated() {
                let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if i == 0 { ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: r.minX + 48 * k, y: r.minY + (112 + CGFloat(i) * 46) * k, width: 860 * k, height: 44 * k)) }
                for (j, c) in cells.enumerated() {
                    text(c, at: CGPoint(x: r.minX + (60 + CGFloat(j) * 215) * k, y: r.minY + (122 + CGFloat(i) * 46) * k), size: 21 * k,
                         color: NSColor(white: 0.15, alpha: 1), bold: i == 0)
                }
            }
        }
        text("Folie \(index + 1)", at: CGPoint(x: r.maxX - 110 * k, y: r.maxY - 36 * k), size: 14 * k, color: .gray)
    }

    static let docLines: [String] = {
        var out: [String] = []
        let heads = ["1. Ziel des Projekts", "2. Anforderungen", "3. Datenmodell", "4. Schnittstellen", "5. Zeitplan", "6. Risiken"]
        let body = ["Die App soll Meetings lokal mitschreiben und Folien als Bilder sichern.", "Alle Daten bleiben auf dem Mac, nichts geht an Server.",
                    "Pro Stunde sollen 30 bis 80 Schlüsselbilder entstehen.", "Texterkennung auf Deutsch und Englisch mit Vision.",
                    "Das Kontext-Paket enthält meeting.md und einen Ordner bilder.", "Aufbewahrung: drei Tage, außer das Meeting ist angeheftet."]
        for (i, h) in heads.enumerated() {
            out.append("#" + h)
            for j in 0..<7 { out.append(body[(i + j) % body.count] + " (Abschnitt \(i + 1).\(j + 1))") }
            out.append("")
        }
        return out
    }()

    private func drawDoc(_ ctx: CGContext, _ r: CGRect, offset: Double) {
        fill(ctx, r, gray: 1)
        let lineH: CGFloat = 30
        let start = CGFloat(offset) * r.height
        for (i, l) in MCSynthMeeting.docLines.enumerated() {
            let y = r.minY + 30 + CGFloat(i) * lineH - start
            guard y > r.minY - lineH, y < r.maxY else { continue }
            if l.hasPrefix("#") { text(String(l.dropFirst()), at: CGPoint(x: r.minX + 40, y: y), size: 22, color: NSColor(white: 0.1, alpha: 1), bold: true) }
            else { text(l, at: CGPoint(x: r.minX + 40, y: y), size: 17, color: NSColor(white: 0.25, alpha: 1)) }
        }
    }

    static let codeLines: [String] = [
        "import ScreenCaptureKit", "", "final class MeetingCapture {", "    private var stream: SCStream?", "    private let fps = 1",
        "    var keyframes: [Keyframe] = []", "", "    func start(window: SCWindow) async throws {",
        "        let filter = SCContentFilter(desktopIndependentWindow: window)", "        let config = SCStreamConfiguration()",
        "        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)", "        config.showsCursor = false",
        "        stream = SCStream(filter: filter, configuration: config, delegate: nil)", "        try await stream?.startCapture()", "    }", "",
        "    func isKeyframe(_ diff: Double) -> Bool {", "        return diff > 0.045   // Schwelle", "    }", "",
        "    func stop() async {", "        try? await stream?.stopCapture()", "        stream = nil", "    }", "}", "",
        "// TODO: OCR im Kindprozess", "// TODO: Budget-Folie pruefen", "let version = \"1.6.0\"", "print(\"fertig\")",
    ]

    private func drawCode(_ ctx: CGContext, _ r: CGRect, lines: Int) {
        ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)); ctx.fill(r)
        text("MeetingCapture.swift", at: CGPoint(x: r.minX + 16, y: r.minY + 10), size: 13, color: NSColor(white: 0.7, alpha: 1))
        for (i, l) in MCSynthMeeting.codeLines.prefix(lines).enumerated() {
            text(String(format: "%2d  ", i + 1) + l, at: CGPoint(x: r.minX + 16, y: r.minY + 40 + CGFloat(i) * 19), size: 14,
                 color: NSColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 1), mono: true)
        }
    }

    private func fill(_ ctx: CGContext, _ r: CGRect, gray: CGFloat, alpha: CGFloat = 1) {
        ctx.setFillColor(CGColor(gray: gray, alpha: alpha)); ctx.fill(r)
    }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, bold: Bool = false, mono: Bool = false) {
        let f: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: color])
    }

    /// Transkript passend zum Zeitplan (für Zusammenfassungs-Tests)
    func transcript() -> [Segment] {
        var out: [Segment] = []
        var lastKey = ""
        for s in spans where s.key != lastKey {
            lastKey = s.key
            let t = s.t0 + 2
            switch s.content {
            case .gallery: out.append(Segment(speaker: "S1", start: t, end: t + 8, text: "Hallo zusammen, schön dass ihr alle da seid. Ich teile gleich meinen Bildschirm."))
            case .slide(let i, _):
                let sl = slides[i % slides.count]
                let sp = i % 3 == 0 ? "me" : (i % 3 == 1 ? "S1" : "S2")
                out.append(Segment(speaker: sp, start: t, end: t + 12, text: "Nächste Folie: \(sl.title). \(sl.kind == .chart || sl.kind == .table ? "Schaut euch die Zahlen an, das ist wichtig." : "Das sind die wichtigsten Punkte dazu.")"))
            case .doc: out.append(Segment(speaker: "S2", start: t, end: t + 10, text: "Ich scrolle mal durch das Konzeptdokument, damit ihr die Anforderungen seht."))
            case .code: out.append(Segment(speaker: "me", start: t, end: t + 10, text: "Ich zeig euch kurz den Code für die Aufnahme, ich tippe das mal live."))
            }
        }
        return out
    }

    // MARK: Foliensatz

    static let deck: [Slide] = [
        Slide(title: "Budget Q4", bullets: ["Marketing: 42", "Personal: 118", "Technik: 67", "Events: 25"], kind: .chart, builds: 1),
        Slide(title: "Roadmap 2027", bullets: ["Januar: Beta für 50 Nutzer", "März: Zahlungen mit Stripe", "Mai: iPhone-App", "Juli: Version 2.0"], kind: .bullets, builds: 3),
        Slide(title: "Nutzerzahlen September", bullets: ["Monat | Nutzer | Aktiv | Umsatz", "Juli | 1.240 | 610 | 3.100 EUR", "August | 1.980 | 1.020 | 5.480 EUR", "September | 2.760 | 1.530 | 8.020 EUR"], kind: .table, builds: 1),
        Slide(title: "Camp-Planung Herbst", bullets: ["64 Anmeldungen, 12 auf der Warteliste", "Zweiter Bus wird angefragt", "Andacht am Samstag noch offen", "Budget-Freigabe bis Freitag"], kind: .bullets, builds: 2),
        Slide(title: "Startseite Entwurf B", bullets: ["Großes Foto oben", "Ein klarer Knopf", "Preise erst unten"], kind: .design, builds: 1),
        Slide(title: "API-Design /v2/meetings", bullets: ["GET /v2/meetings?since=", "POST /v2/meetings/{id}/frames", "Antwort in JSON, max. 200 Einträge", "Authentifizierung per Token"], kind: .bullets, builds: 1),
        Slide(title: "Risiken", bullets: ["Datenschutz: nur lokal speichern", "Speicherplatz: 60 MB pro Stunde", "CPU-Last unter 3 Prozent halten"], kind: .bullets, builds: 3),
        Slide(title: "Umsatz nach Kanal", bullets: ["Web: 54", "App: 31", "Partner: 12", "Sonstige: 3"], kind: .chart, builds: 1),
        Slide(title: "Team und Rollen", bullets: ["Alex: Produkt und Design", "Sophie: Backend und Daten", "Mika: iOS-App", "Jonas: Vertrieb"], kind: .bullets, builds: 1),
        Slide(title: "Nächste Schritte", bullets: ["Prototyp bis 15. Oktober", "Nutzertests mit 8 Personen", "Entscheidung über Preise im November"], kind: .bullets, builds: 2),
        Slide(title: "Preismodell", bullets: ["Plan | Preis | Nutzer | Speicher", "Basis | 0 EUR | 1 | 1 GB", "Pro | 12 EUR | 5 | 50 GB", "Team | 39 EUR | 20 | 500 GB"], kind: .table, builds: 1),
        Slide(title: "Fragen und Antworten", bullets: ["Warum lokal? Datenschutz und Tempo", "Warum 1 Bild pro Sekunde? Reicht für Folien", "Wann kommt Windows? Nicht geplant"], kind: .bullets, builds: 1),
    ]
}
