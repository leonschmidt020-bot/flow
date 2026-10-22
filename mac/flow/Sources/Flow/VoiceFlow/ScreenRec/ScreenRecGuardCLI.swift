import AppKit
import AVFoundation
import ScreenCaptureKit

/// Selbsttest Aufnahme-Schutz (18.10.2026): `Flow --selftest-aufnahme-schutz` (braucht FLOW_HOME).
/// Startet NIE eine echte Bildschirmaufnahme – prüft die reine Logik: überlappende Starts (Start-Nummern),
/// veraltete Rückrufe, Speicher-Schwellen, Wachstums-Entscheidung (Papierkorb/Warnung/replayd), Abspiel-Prüfung
/// an echten Test-MP4s im Test-Ordner, Fertig-Karte bei kaputter Datei/automatischem Stopp, Monitore/Takte.
enum ScreenRecGuardCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1, args[1] == "--selftest-aufnahme-schutz" else { return nil }
        guard ProcessInfo.processInfo.environment["FLOW_HOME"] != nil else {
            print("FEHLER --selftest-aufnahme-schutz braucht FLOW_HOME (Test-Ordner)"); return 1
        }
        _ = NSApplication.shared
        let dir = Paths.base.appendingPathComponent("Aufnahme-Schutz-Test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var ok = 0, bad = 0
        func check(_ c: Bool, _ name: String) { if c { ok += 1; print("  ok     \(name)") } else { bad += 1; print("  FEHLER \(name)") } }
        /// Main-RunLoop laufen lassen, bis `done` oder Zeit um (Rückrufe kommen auf dem Main-Thread)
        func spin(_ secs: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(secs)
            while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        // 1) Überlappende Starts: A hängt in SCShareableContent, Stopp, B startet, A wacht mitten in B auf
        let gate = ScreenRecStartGate()
        var phase: ScreenRec.Phase = .starting
        let a = gate.begin()
        gate.cancel(); phase = .idle                        // Stopp während „starting“ (abortStart)
        check(!gate.mayContinue(a, phase: phase), "Stopp während „starting“: Start A bricht nach seinem await ab")
        phase = .starting
        let b = gate.begin()                                // neuer Start B
        check(!gate.mayContinue(a, phase: phase), "A wacht im „starting“ von B auf → verworfen (alter Phasen-Wächter ließ ihn durch)")
        check(gate.mayContinue(b, phase: phase), "B läuft weiter")
        check(a != b && gate.isCurrent(b) && !gate.isCurrent(a), "jeder Start hat eine eigene Nummer (\(a) ≠ \(b))")
        // Sicherheitsnetz: Aufnahme 1 (A′) fertig, Aufnahme 2 (B′) stoppt innerhalb von 6 s → Netz von 1 darf 2 nicht beenden
        let r1 = gate.begin(); let r2 = gate.begin()
        check(!gate.netMayFire(r1, phase: .finishing), "6-s-Sicherheitsnetz der vorigen Aufnahme beendet die nächste nicht")
        check(gate.netMayFire(r2, phase: .finishing) && !gate.netMayFire(r2, phase: .idle), "Netz greift nur für die eigene Aufnahme in „finishing“")

        // 2) Monitore/Takte: zweites Anlegen räumt das erste ab (kein verwaister Monitor, kein zweiter 30-Hz-Takt)
        let tr = ScreenRecTrackers()
        var live = 0, removed = 0
        let install: () -> () -> Void = { live += 1; return { live -= 1; removed += 1 } }
        tr.replace([install, install])
        tr.replace([install, install])                      // zweiter Start ohne Stopp dazwischen
        check(live == 2 && removed == 2 && tr.count == 2, "zweimal anlegen → alte Monitore entfernt (lebend \(live), entfernt \(removed))")
        tr.removeAll()
        check(live == 0 && tr.count == 0, "Stopp/Reset räumt alle ab")
        // Stift: zweimal start → nur EIN 120-Hz-Takt (ohne Panel, zeichnet nichts)
        let base = ScreenRecInk.liveTimers
        let ink = ScreenRecInk()
        ink.start(at: Date()); ink.start(at: Date())
        _ = ink.marks; spin(0.1); _ = ink.marks             // Queue abarbeiten (Abbruch-Rückruf des alten Takts)
        check(ScreenRecInk.liveTimers - base == 1, "Stift zweimal gestartet → ein Takt (\(ScreenRecInk.liveTimers - base))")
        ink.stop(); spin(0.1); _ = ink.marks
        check(ScreenRecInk.liveTimers - base == 0, "Stift gestoppt → kein Takt mehr")

        // 3) Rückrufe einer alten Ausgabe/eines alten Streams werden ignoriert
        let oldOut = NSObject(), curOut = NSObject()
        check(!ScreenRecGuard.accept(.finish, from: oldOut, current: curOut, phase: .finishing), "Fertig-Meldung der alten Ausgabe beendet die neue nicht")
        check(ScreenRecGuard.accept(.finish, from: curOut, current: curOut, phase: .finishing), "Fertig-Meldung der eigenen Ausgabe zählt")
        check(!ScreenRecGuard.accept(.finish, from: curOut, current: curOut, phase: .recording), "Fertig-Meldung mitten in der Aufnahme beendet sie nicht")
        check(!ScreenRecGuard.accept(.finish, from: oldOut, current: nil, phase: .finishing), "nach dem Reset (keine Ausgabe) wird alles ignoriert")
        check(!ScreenRecGuard.accept(.fileError, from: oldOut, current: curOut, phase: .recording), "Datei-Fehler der alten Ausgabe stoppt die neue nicht")
        check(!ScreenRecGuard.accept(.streamStop, from: oldOut, current: curOut, phase: .recording)
              && ScreenRecGuard.accept(.streamStop, from: curOut, current: curOut, phase: .recording), "macOS-Stopp nur für den eigenen Stream")
        // echte Delegate-Methoden auf einer frischen Instanz (nicht `shared`): Ausgabe-Objekt nur gebaut, nie an einen
        // Stream gehängt → keine Aufnahme. Fertig-/Fehler-Meldung einer fremden Ausgabe ändert nichts.
        let rec = ScreenRec()
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = dir.appendingPathComponent("nie-geschrieben.mp4"); rc.outputFileType = .mp4
        let stale = SCRecordingOutput(configuration: rc, delegate: rec)
        rec.recordingOutputDidFinishRecording(stale)
        rec.recordingOutput(stale, didFailWithError: NSError(domain: "Test", code: 1))
        spin(0.15)
        check(rec.phase == .idle && !FileManager.default.fileExists(atPath: rc.outputURL.path),
              "Delegate: Meldungen einer fremden Ausgabe ändern nichts (Phase \(rec.phase), keine Datei)")

        // 4) Speicher-Schwellen (eingespeiste Werte)
        let gb = Int64(1_000_000_000)
        check(!ScreenRecGuard.mayStart(free: 4 * gb + 999_000_000) && ScreenRecGuard.mayStart(free: 5 * gb), "Start unter 5 GB verweigert, ab 5 GB erlaubt")
        check(ScreenRecGuard.mayStart(free: nil), "unbekannter Platz blockiert den Start nicht")
        check(ScreenRecGuard.mustStop(free: 1_999_999_999) && !ScreenRecGuard.mustStop(free: 2 * gb) && !ScreenRecGuard.mustStop(free: nil), "Auto-Stopp unter 2 GB, nicht bei 2 GB/unbekannt")
        check(ScreenRecGuard.gb(3_240_000_000) == "3,2 GB", "Anzeige deutsch: \(ScreenRecGuard.gb(3_240_000_000))")
        let refuse = ScreenRecGuard.refuseText(free: 3_200_000_000)
        check(refuse.contains("3,2 GB") && refuse.contains("5,0 GB"), "Karten-Text nennt frei + nötig: \(refuse)")
        check(ScreenRecGuard.stopText(free: 1_800_000_000).contains("1,8 GB"), "Stopp-Text nennt den Rest")
        check(!ScreenRecGuard.spaceDue(tick: 1) && !ScreenRecGuard.spaceDue(tick: 19) && ScreenRecGuard.spaceDue(tick: 20) && ScreenRecGuard.spaceDue(tick: 40),
              "Speicher-Prüfung im Wächter alle 10 s (jede 20. Runde)")
        let realFree = ScreenRecGuard.freeBytes(at: dir)
        check((realFree ?? 0) > 0, "freier Platz lesbar (Test-Ordner: \(realFree.map(ScreenRecGuard.gb) ?? "?"))")

        // 5) Wachstums-Entscheidung (eingespeiste Größen)
        check(ScreenRecGuard.growth(1000, 5000) == .growing && ScreenRecGuard.growth(-1, 40) == .growing, "wachsend erkannt")
        check(ScreenRecGuard.growth(5000, 5000) == .stable && ScreenRecGuard.growth(0, 0) == .empty && ScreenRecGuard.growth(-1, -1) == .missing,
              "still / leer / fehlt erkannt")
        check(ScreenRecGuard.action(.stable, keep: false) == .trash && ScreenRecGuard.action(.empty, keep: false) == .trash, "Fehlstart-Rest steht still → Papierkorb")
        check(ScreenRecGuard.action(.stable, keep: true) == .none && ScreenRecGuard.action(.empty, keep: true) == .none, "fertige Aufnahme wird nie gelöscht")
        check(ScreenRecGuard.action(.growing, keep: true) == .warn && ScreenRecGuard.action(.growing, keep: false) == .warn, "wachsend → Warnung (auch bei fertiger Datei, ohne Löschen)")
        check(ScreenRecGuard.action(.missing, keep: false) == .none, "keine Datei → nichts zu tun")
        check(ScreenRecGuard.mayKillReplayd(.growing) && !ScreenRecGuard.mayKillReplayd(.stable)
              && !ScreenRecGuard.mayKillReplayd(.empty) && !ScreenRecGuard.mayKillReplayd(.missing), "replayd nur beenden, wenn die Datei nachweislich wächst")
        // echte Messung an einer Datei im Test-Ordner: wächst, während ein Faden anhängt; danach still
        let grow = dir.appendingPathComponent("wachsend.bin")
        FileManager.default.createFile(atPath: grow.path, contents: Data(count: 1000))
        let writer = DispatchQueue(label: "test.wachsen")
        let stopWriting = StopFlag()
        writer.async {
            guard let h = try? FileHandle(forWritingTo: grow) else { return }
            while !stopWriting.isSet {
                h.seekToEndOfFile(); h.write(Data(count: 4096)); Thread.sleep(forTimeInterval: 0.02)
            }
            try? h.close()
        }
        var g1: ScreenRecGuard.Growth?
        ScreenRecGuard.sampleGrowth(grow, after: 0.05, gap: 0.3) { g, _, _ in g1 = g }
        spin(3) { g1 != nil }
        stopWriting.set()
        writer.sync {}
        check(g1 == .growing, "Messung: Datei, in die geschrieben wird → wächst (\(g1.map { "\($0)" } ?? "?"))")
        var g2: ScreenRecGuard.Growth?
        ScreenRecGuard.sampleGrowth(grow, after: 0.05, gap: 0.3) { g, _, _ in g2 = g }
        spin(3) { g2 != nil }
        check(g2 == .stable, "Messung: danach steht sie still (\(g2.map { "\($0)" } ?? "?"))")

        // 6) Abspiel-Prüfung: echtes kleines MP4 (im Test-Ordner gebaut) gegen abgeschnittene/kaputte/leere Datei
        check(ScreenRecGuard.playable(hasVideo: true, duration: 1.2) && !ScreenRecGuard.playable(hasVideo: true, duration: 0)
              && !ScreenRecGuard.playable(hasVideo: false, duration: 3) && !ScreenRecGuard.playable(hasVideo: true, duration: .nan), "Regel: Video-Spur + Dauer > 0")
        let good = dir.appendingPathComponent("gut.mp4"), cut = dir.appendingPathComponent("abgeschnitten.mp4")
        let junk = dir.appendingPathComponent("muell.mp4"), zero = dir.appendingPathComponent("leer.mp4")
        var built: Bool?
        Task { built = await writeTestMP4(good) }
        spin(15) { built != nil }
        check(built == true, "Test-MP4 gebaut (\(ScreenRecGuard.size(good)) B)")
        if let d = try? Data(contentsOf: good) { try? d.prefix(d.count / 2).write(to: cut) }   // moov liegt am Ende → fehlt
        try? Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: junk)
        FileManager.default.createFile(atPath: zero.path, contents: Data())
        var res: [Bool]?
        Task {
            var r: [Bool] = []
            for u in [good, cut, junk, zero] { r.append(await ScreenRecGuard.playable(u)) }
            res = r
        }
        spin(15) { res != nil }
        check(res?[0] == true, "fertiges MP4 → abspielbar")
        check(res?[1] == false, "abgeschnittenes MP4 (ohne Abschluss) → nicht abspielbar")
        check(res?[2] == false && res?[3] == false, "Müll / 0 Byte → nicht abspielbar")

        // 7) Fertig-Karte: kaputte Datei → kein „Kopieren“; automatischer Stopp → Grund steht drin, Karte bleibt
        let url = dir.appendingPathComponent("Bildschirmaufnahme test.mp4")
        let bd = ScreenRecDone(url: url, duration: 83, screen: "Externer Monitor", sound: .mic)
        bd.markBroken()
        let bc = ScreenRec.doneNotice(bd, copy: {}, again: {})
        check(bc.primary?.0 != "Kopieren" && bc.choices.isEmpty && bc.title.hasPrefix("Aufnahme beschädigt"),
              "kaputte Datei: „\(bc.title)“, Knopf „\(bc.primary?.0 ?? "-")“ statt Kopieren")
        check(bc.text.contains("nicht abspielen"), "Karte sagt, dass die Datei nicht abspielbar ist")
        check(!bd.ready, "kaputte Datei wird nie „bereit“ (Kopieren wartet nicht auf sie)")
        let sd = ScreenRecDone(url: url, duration: 20, screen: "Externer Monitor", sound: .none)
        sd.stopReason = ScreenRecGuard.stopText(free: 1_800_000_000)
        let sc = ScreenRec.doneNotice(sd, copy: {}, again: {})
        check(sc.text.hasPrefix("Automatisch gestoppt: nur noch 1,8 GB frei.") && sc.timeout == nil && sc.primary?.0 == "Kopieren",
              "Auto-Stopp: Grund vorn in der Karte, bleibt stehen")
        let nd = ScreenRec.doneNotice(ScreenRecDone(url: url, duration: 20, screen: "Externer Monitor", sound: .none), copy: {}, again: {})
        check(nd.timeout == 45 && nd.title.hasPrefix("Aufnahme fertig"), "normaler Stopp unverändert (45 s, „Aufnahme fertig“)")

        print("Aufnahme-Schutz: \(ok)/\(ok + bad) ok")
        return bad == 0 ? 0 : 1
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func set() { lock.lock(); on = true; lock.unlock() }
    }

    /// 0,5 s H.264-MP4 (128×128, 15 Bilder) – Abschluss (moov) am Dateiende wie bei replayd
    private static func writeTestMP4(_ url: URL) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128])
        input.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 128])
        guard w.canAdd(input) else { return false }
        w.add(input)
        guard w.startWriting() else { return false }
        w.startSession(atSourceTime: .zero)
        for i in 0..<15 {
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 400 { try? await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
            guard let pool = ad.pixelBufferPool else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            if let p = CVPixelBufferGetBaseAddress(pb) { memset(p, Int32(i * 16), CVPixelBufferGetDataSize(pb)) }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)) else { return false }
        }
        input.markAsFinished()
        await w.finishWriting()
        return w.status == .completed
    }
}
