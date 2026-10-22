import AVFoundation
import Foundation

/// Selbsttest „Meeting-Ton komprimieren“ (18.10.2026): `--selftest-meeting-audio` – nur mit FLOW_HOME (Test-Ordner).
/// Legt eigene Test-Meetings mit künstlichem Ton an (Sinus/Rauschen, nichts wird abgespielt), komprimiert, prüft und
/// räumt die Test-Ordner wieder weg. Echte Meetings werden nie angefasst.
enum MeetingAudioCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1, args[1] == "--selftest-meeting-audio" else { return nil }
        let env = ProcessInfo.processInfo.environment["FLOW_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flow").standardizedFileURL.path
        guard !env.isEmpty, Paths.base.standardizedFileURL.path != real else {
            print("FEHLER --selftest-meeting-audio braucht FLOW_HOME (Test-Ordner)"); return 1
        }
        return selftest()
    }

    /// Gleichbleibendes Rauschen (Test soll jedes Mal dasselbe messen)
    private struct Noise {
        var s: UInt64
        mutating func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: s >> 11) % 2_000_001 - 1_000_000) / 1_000_000
        }
    }

    private static func selftest() -> Int32 {
        var ok = 0, bad = 0
        func check(_ c: Bool, _ name: String) { if c { ok += 1; print("  ok     \(name)") } else { bad += 1; print("  FEHLER \(name)") } }
        let fm = FileManager.default
        let prefix = "selbsttest-ton-"
        func cleanup() {
            for d in (try? fm.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? [] where d.lastPathComponent.hasPrefix(prefix) {
                try? fm.removeItem(at: d)
            }
            try? fm.removeItem(at: Paths.base.appendingPathComponent("selbsttest-ton-extern"))
        }
        cleanup()
        defer { cleanup(); MeetingStore.shared.reload() }

        // Testsignale (60 s, 16 kHz): Mikro = Sinus-Silben + leises Rauschen, Systemton = Rauschstöße mit Pausen
        let n = 16000 * 60
        var noise = Noise(s: 7)
        let mic: [Float] = (0..<n).map { i in
            let on = (i / 8000) % 3 != 2
            return (on ? Float(sin(Double(i) * 2 * .pi * 220 / 16000) * 0.25) : 0) + noise.next() * 0.01
        }
        let sys: [Float] = (0..<n).map { i in ((i / 12000) % 2 == 0 ? noise.next() * 0.3 : noise.next() * 0.003) }

        func writeWav(_ s: [Float], _ url: URL) {
            guard let w = try? WavWriter(url: url) else { return }
            w.write(s); w.close()
        }
        func meeting(_ tag: String, _ status: Meeting.Status, tracks: Bool = true) -> Meeting {
            var m = Meeting(id: prefix + tag, title: "Selbsttest \(tag)", date: Date(), app: "Teams")
            m.status = status
            try? fm.createDirectory(at: m.folder, withIntermediateDirectories: true)
            if tracks { writeWav(mic, m.micURL); writeWav(sys, m.systemURL) }
            MeetingStore.shared.save(m)
            return m
        }
        func seconds(_ u: URL) -> Double {
            guard let f = try? AVAudioFile(forReading: u) else { return -1 }
            return Double(f.length) / f.fileFormat.sampleRate
        }
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        func mb(_ b: Int64) -> String { String(format: "%.2f MB", Double(b) / 1_048_576) }
        func pump(until: () -> Bool, timeout: Double = 30) {
            let t0 = Date()
            while !until() && Date().timeIntervalSince(t0) < timeout { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func waitIdle() {
            var idle = false
            MeetingAudioCompressor.shared.whenIdle { idle = true }
            pump(until: { idle })
        }

        // 1) Lesen + Angleichen: neue Wege liefern exakt dasselbe wie bisher
        let probeURL = Paths.meetings.appendingPathComponent(prefix + "lesen.wav")
        try? fm.createDirectory(at: Paths.meetings, withIntermediateDirectories: true)
        writeWav(mic, probeURL)
        check(WavWriter.read(probeURL) == legacyRead(probeURL) && WavWriter.read(probeURL).count == n, "WAV lesen in Blöcken = bisheriges Ergebnis (\(n) Samples)")
        try? fm.removeItem(at: probeURL)
        var same = true
        for scale in [Float(0.002), 0.2, 0.9] {   // leise (24-fach gedeckelt), mittel, laut (bleibt)
            let x = mic.map { $0 * scale }
            var y = x
            Transcriber.normalizeInPlace(&y)
            let old = legacyNormalized(x)
            same = same && y == old && Transcriber.normalized(x) == old
            var yy = y; Transcriber.normalizeInPlace(&yy)
            same = same && yy == legacyNormalized(old)   // zweimal angleichen (Meeting-Mikro) wie bisher
        }
        check(same, "Angleichen an Ort und Stelle (vDSP) bitgleich zum bisherigen Ergebnis, auch zweifach")

        // 2) Fertiges Meeting, 60 s, zwei Spuren → komprimieren
        let m1 = meeting("fertig", .done)
        let wavBytes = MeetingAudio.size(m1.micURL) + MeetingAudio.size(m1.systemURL)
        let t0 = Date()
        let r1 = MeetingAudio.compressTracks(of: m1)
        let took = Date().timeIntervalSince(t0)
        let micM4A = MeetingAudio.compressedURL(m1.micURL), sysM4A = MeetingAudio.compressedURL(m1.systemURL)
        check(r1.done == 2 && r1.failed == 0, "beide Spuren umgewandelt (\(r1.done) ok, \(r1.failed) Fehler, \(String(format: "%.2f", took)) s)")
        check(exists(micM4A) && exists(sysM4A), "ich.m4a + andere.m4a liegen im Meeting-Ordner")
        check(!exists(m1.micURL) && !exists(m1.systemURL), "WAVs nach der Prüfung entfernt")
        check(abs(seconds(micM4A) - 60) <= 0.5 && abs(seconds(sysM4A) - 60) <= 0.5,
              String(format: "Länge stimmt (%.3f s / %.3f s statt 60 s)", seconds(micM4A), seconds(sysM4A)))
        check(m1.micTrack == micM4A && m1.systemTrack == sysM4A && MeetingAudio.hasTrack(m1.micURL), "Spur-Auflöser liefert die .m4a")
        let back = WavWriter.read(m1.micTrack)
        let rate = (try? AVAudioFile(forReading: micM4A))?.processingFormat.sampleRate ?? 0
        check(rate == 16000 && abs(back.count - n) <= 16, "zurückgelesen: \(back.count) Samples bei \(Int(rate)) Hz (erwartet \(n))")
        var dot = 0.0, ea = 0.0, eb = 0.0
        for i in 0..<min(back.count, n) { dot += Double(mic[i] * back[i]); ea += Double(mic[i] * mic[i]); eb += Double(back[i] * back[i]) }
        let corr = dot / max(sqrt(ea * eb), 1e-9)
        check(corr > 0.95, String(format: "Inhalt stimmt (Korrelation %.3f, kein Versatz)", corr))
        let perms = (try? fm.attributesOfItem(atPath: micM4A.path)[.posixPermissions] as? Int) ?? 0
        check(perms == 0o600, "nur für den Benutzer lesbar (\(String(perms, radix: 8)))")
        check(!exists(m1.folder.appendingPathComponent(MeetingAudio.tempDirName)), "keine Zwischendatei übrig")
        let m4aBytes = MeetingAudio.size(micM4A) + MeetingAudio.size(sysM4A)
        let ratio = Double(wavBytes) / Double(max(m4aBytes, 1))
        check(ratio >= 4, "60-s-Meeting, 2 Spuren: \(mb(wavBytes)) WAV → \(mb(m4aBytes)) m4a (\(String(format: "%.1f", ratio))× kleiner, −\(Int((1 - 1 / ratio) * 100)) %) ≈ \(Int(Double(wavBytes) * 60 / 1_048_576)) → \(Int(Double(m4aBytes) * 60 / 1_048_576)) MB je Stunde")
        print("         je Spur: ich \(MeetingAudio.size(micM4A)) B, andere \(MeetingAudio.size(sysM4A)) B (WAV je \(wavBytes / 2) B)")
        check(MeetingContextPackage.audioLabel(micM4A) == "dein Mikrofon" && MeetingContextPackage.audioLabel(sysM4A).hasPrefix("Ton der anderen"),
              "Agent-Paket benennt die .m4a-Spuren wie die WAVs")

        // 3) Scheitern lässt die Quelle stehen
        let m2 = meeting("kaputt", .done, tracks: false)
        var junk = Data(count: 100_000); for i in 0..<junk.count { junk[i] = UInt8(truncatingIfNeeded: i &* 37 &+ 11) }
        try? junk.write(to: m2.micURL)
        let r2 = MeetingAudio.compressTracks(of: m2)
        check(r2.failed == 1 && exists(m2.micURL) && MeetingAudio.size(m2.micURL) == 100_000 && !exists(MeetingAudio.compressedURL(m2.micURL)),
              "unlesbare Eingabe: Fehler gemeldet, Quelle bleibt unverändert, keine .m4a")
        check(!exists(m2.folder.appendingPathComponent(MeetingAudio.tempDirName)), "nach dem Fehler keine Zwischendatei übrig")
        let m2b = meeting("schreibschutz", .done)
        chmod(m2b.folder.path, 0o500)
        let r2b = MeetingAudio.compressTracks(of: m2b)
        chmod(m2b.folder.path, 0o700)
        check(r2b.failed == 2 && exists(m2b.micURL) && exists(m2b.systemURL) && MeetingAudio.size(m2b.micURL) > Int64(2 * n)
              && !exists(MeetingAudio.compressedURL(m2b.micURL)),
              "gültige WAV, aber Ordner nicht beschreibbar: beide WAVs bleiben (\(r2b.failed) Fehler gemeldet)")
        do {
            try MeetingAudio.compress(m2b.micURL, to: MeetingAudio.compressedURL(m2b.micURL), sampleRate: MeetingAudio.trackRate,
                                      bitRate: MeetingAudio.trackBitRate, gate: { false })
            check(false, "Freigabe verweigert → nichts umgestellt")
        } catch {
            check(exists(m2b.micURL) && !exists(MeetingAudio.compressedURL(m2b.micURL)), "Freigabe kurz vor dem Löschen verweigert → WAV bleibt, .m4a wieder weg")
        }
        let m2c = meeting("leer", .done, tracks: false)
        writeWav([], m2c.micURL)
        let r2c = MeetingAudio.compressTracks(of: m2c)
        check(r2c.done == 0 && r2c.failed == 0 && exists(m2c.micURL), "leere Spur (Kopf ohne Ton) bleibt still liegen")

        // 4) Hintergrund-Warteschlange: nur fertige Meetings; Aufnahme + Unterbrochenes behalten die WAV
        let m3 = meeting("warteschlange", .done)
        let m4 = meeting("unterbrochen", .processing)
        let m5 = meeting("aufnahme", .recording)
        MeetingController.activeID = m5.id            // so tun, als liefe diese Aufnahme gerade
        MeetingStore.shared.reload()                   // wie beim App-Start: hängen gebliebene Auswertung → „Unterbrochen“
        let m4Note = MeetingStore.shared.meeting(m4.id)?.progressNote ?? ""
        for id in [m3.id, m4.id, m5.id] { MeetingAudioCompressor.shared.enqueue(id) }
        waitIdle()
        check(!exists(m3.micURL) && exists(MeetingAudio.compressedURL(m3.micURL)) && exists(MeetingAudio.compressedURL(m3.systemURL)),
              "Warteschlange: fertiges Meeting komprimiert (im Hintergrund)")
        check(exists(m4.micURL) && exists(m4.systemURL) && !exists(MeetingAudio.compressedURL(m4.micURL)) && m4Note.hasPrefix("Unterbrochen"),
              "unterbrochenes Meeting behält seine WAVs bis zur Auswertung")
        check(exists(m5.micURL) && !exists(MeetingAudio.compressedURL(m5.micURL)), "laufende Aufnahme wird nicht angefasst")
        check(MeetingAudio.hasTrack(m3.micURL) && MeetingAudio.hasTrack(m4.micURL), "Start-Fortsetzung findet die Spur (WAV oder .m4a)")
        MeetingController.activeID = nil

        // 5) Umstellung beim Start: vorhandene Meetings + Reste abgebrochener Läufe
        let m6 = meeting("alt", .done)
        let leftover = m6.folder.appendingPathComponent(MeetingAudio.tempDirName, isDirectory: true)
        try? fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try? Data("halb".utf8).write(to: leftover.appendingPathComponent("ich.m4a"))
        MeetingAudioCompressor.shared.scheduleMigration(after: 0)
        pump(until: { !exists(m6.micURL) && !exists(m6.systemURL) }, timeout: 20)
        waitIdle()
        check(!exists(m6.micURL) && exists(MeetingAudio.compressedURL(m6.micURL)) && exists(MeetingAudio.compressedURL(m6.systemURL)),
              "Umstellung beim Start: altes Meeting komprimiert")
        check(!exists(leftover), "Rest einer abgebrochenen Umwandlung weggeräumt")
        check(exists(m4.micURL) && !exists(MeetingAudio.compressedURL(m4.micURL)), "Umstellung lässt das unterbrochene Meeting in Ruhe")
        check(exists(m2.micURL) && MeetingAudio.size(m2.micURL) == 100_000, "Umstellung lässt die unlesbare Spur unverändert")

        // 6) Importierte Datei: übernommene Kopie (original.caf, 44,1 kHz Stereo) → original.m4a; fremde Dateien bleiben
        let imp = meeting("import_datei", .done, tracks: false)
        let orig = imp.folder.appendingPathComponent("original.caf")
        let impSeconds = 20.0
        writeStereo44k(orig, seconds: impSeconds, noise: &noise)
        var job = AudioImportJob(id: imp.id, source: orig.path, fileName: "New Recording 7.qta", origin: .drop, bytes: MeetingAudio.size(orig), added: Date())
        job.phase = .done; job.ownedCopy = true
        AudioImportFiles.saveJob(job)
        let ext = Paths.base.appendingPathComponent("selbsttest-ton-extern", isDirectory: true)
        try? fm.createDirectory(at: ext, withIntermediateDirectories: true)
        let extFile = ext.appendingPathComponent("memo.caf")
        writeStereo44k(extFile, seconds: 5, noise: &noise)
        let imp2 = meeting("fremd_datei", .done, tracks: false)
        var job2 = AudioImportJob(id: imp2.id, source: extFile.path, fileName: "memo.caf", origin: .picker, bytes: MeetingAudio.size(extFile), added: Date())
        job2.phase = .done
        AudioImportFiles.saveJob(job2)
        let origBytes = MeetingAudio.size(orig), extBytes = MeetingAudio.size(extFile)
        MeetingAudioCompressor.shared.enqueue(imp.id)
        MeetingAudioCompressor.shared.enqueue(imp2.id)
        waitIdle()
        let newOrig = imp.folder.appendingPathComponent("original.m4a")
        let j = AudioImportFiles.loadJob(imp.id)
        check(exists(newOrig) && !exists(orig), "Import: original.caf → original.m4a, Quelle danach entfernt")
        check(j?.source == newOrig.path && j?.fileName == "New Recording 7.qta" && j?.kindLabel == "Sprachmemo",
              "import.json zeigt auf die neue Datei („Originaldatei im Finder zeigen“, „Neu auswerten“)")
        let pcm = imp.folder.appendingPathComponent("selbsttest.pcm")
        let dec = try? AudioDecoder.decode(newOrig, to: pcm)
        try? fm.removeItem(at: pcm)
        check(abs((dec?.seconds ?? 0) - impSeconds) <= 0.5, String(format: "„Neu auswerten“ kann die .m4a dekodieren (%.2f s statt %.0f s)", dec?.seconds ?? 0, impSeconds))
        let impRatio = Double(origBytes) / Double(max(MeetingAudio.size(newOrig), 1))
        check(impRatio >= 4, "Import \(Int(impSeconds)) s Stereo 44,1 kHz: \(mb(origBytes)) → \(mb(MeetingAudio.size(newOrig))) (\(String(format: "%.0f", impRatio))× kleiner)")
        check(exists(extFile) && MeetingAudio.size(extFile) == extBytes && AudioImportFiles.loadJob(imp2.id)?.source == extFile.path,
              "Datei außerhalb des Notiz-Ordners (eigene des Nutzers) bleibt unberührt")
        let before = MeetingAudio.size(newOrig)
        MeetingAudioCompressor.shared.enqueue(imp.id)
        waitIdle()
        check(exists(newOrig) && MeetingAudio.size(newOrig) == before, "schon kompakte original.m4a wird nicht noch einmal umgewandelt")

        print("Meeting-Audio: \(ok)/\(ok + bad) ok")
        return bad == 0 ? 0 : 1
    }

    /// Bisheriges WavWriter.read (ganzer Puffer + Kopie) – Vergleich für Test 1
    private static func legacyRead(_ url: URL) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        do { try f.read(into: buf) } catch { return [] }
        guard let ch = buf.floatChannelData else { return [] }
        if f.processingFormat.sampleRate == 16000 { return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength))) }
        return []
    }

    /// Bisheriges Transcriber.normalized (skalar) – Vergleich für Test 1
    private static func legacyNormalized(_ s: [Float]) -> [Float] {
        guard s.count > 100 else { return s }
        var probe = stride(from: 0, to: s.count, by: 4).map { abs(s[$0]) }
        probe.sort()
        let peak = probe[min(probe.count - 1, Int(Double(probe.count) * 0.999))]
        guard peak > 1e-4 else { return s }
        let gain = min(0.7 / peak, 24)
        if gain <= 1.05 { return s }
        return s.map { max(-1, min(1, $0 * gain)) }
    }

    /// Stereo-Testdatei wie aus Sprachmemos (44,1 kHz, 16 bit, CAF) – Rauschsilben, nichts wird abgespielt
    private static func writeStereo44k(_ url: URL, seconds: Double, noise: inout Noise) {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
        let total = Int(44100 * seconds), chunk = 44100
        var pos = 0
        while pos < total {
            let c = min(chunk, total - pos)
            guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(c)) else { return }
            b.frameLength = AVAudioFrameCount(c)
            for i in 0..<c {
                let t = pos + i
                let on = (t / 22050) % 3 != 2
                let v = on ? Float(sin(Double(t) * 2 * .pi * 180 / 44100) * 0.2) + noise.next() * 0.05 : noise.next() * 0.002
                b.floatChannelData![0][i] = v
                b.floatChannelData![1][i] = v * 0.8
            }
            try? f.write(from: b)
            pos += c
        }
        f.close()
    }
}
