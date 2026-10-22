import Foundation

/// Prüfungen zum Effizienz-Durchgang (18.10.2026): `--selftest-effizienz` (Release-Gate, ohne Hardware)
/// und `--tap-probe` (Entwickler, stumm: läuft das Ausgabegerät, während der Mac-Ton-Tap läuft?).
enum EfficiencyCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1 else { return nil }
        switch args[1] {
        case "--selftest-effizienz": return selftest()
        case "--tap-probe": return tapProbe(seconds: Double(args.count > 2 ? args[2] : "") ?? 8)
        default: return nil
        }
    }

    private static func selftest() -> Int32 {
        var ok = 0, bad = 0
        func check(_ c: Bool, _ name: String) { if c { ok += 1; print("  ok     \(name)") } else { bad += 1; print("  FEHLER \(name)") } }
        let pol = HybridRecognizer.Policy()

        // Wörterbuch: kleingeschriebenes Alltagswort als Ziel löst nicht mehr über Abstand/Klang aus
        let weit = [DictEntry(heard: "Welche", write: "weit", learned: true, vocabOnly: true)]
        for w in ["weil", "zeit", "wert", "weiß"] {
            check(VocabTrigger.hit(in: "Das geht nicht, \(w) es spät ist", dictionary: weit, policy: pol) == nil, "„\(w)“ löst „weit“ nicht mehr aus")
        }
        check(VocabTrigger.hit(in: "Welche Farbe nehmen wir", dictionary: weit, policy: pol) != nil, "Hör-Variante „Welche“ fragt weiter Whisper")
        let lidl = [DictEntry(heard: "Legal", write: "Lidl", learned: true, vocabOnly: true)]
        check(VocabTrigger.hit(in: "Ich gehe zu Liedl einkaufen", dictionary: lidl, policy: pol) != nil, "Marke „Lidl“ (groß) löst weiter über Abstand aus")
        let kitanet = [DictEntry(heard: "Kita Net", write: "KiTaNet", learned: false)]
        check(VocabTrigger.hit(in: "Die Arbeit bei Kitanett ist gut", dictionary: kitanet, policy: pol) != nil, "„KiTaNet“ löst weiter aus")
        check(VocabTrigger.isCommonWordTarget("weit") && !VocabTrigger.isCommonWordTarget("Lidl")
              && !VocabTrigger.isCommonWordTarget("sentry") && !VocabTrigger.isCommonWordTarget("ab cd"), "Regel: nur ein kleines Wort ≤5 Buchstaben")

        // Mac-Ton-Tap: Abfrage des Ausgabegeräts funktioniert (sonst bliebe es beim alten Neuaufbau alle 3 s)
        check(SystemAudioTap.outputRunning() != nil, "Ausgabegerät-Status lesbar (läuft: \(SystemAudioTap.outputRunning().map { $0 ? "ja" : "nein" } ?? "?"))")

        // Update-Prüfung: aktiv = jede Minute, sonst seltener
        check(Updater.checkInterval(idleSeconds: 30) == 60, "Update-Prüfung bei Nutzung jede Minute")
        check(Updater.checkInterval(idleSeconds: 3600) >= 600, "Update-Prüfung ohne Nutzung höchstens alle 10 min")

        // Meeting-Spur nach Absturz während der Aufnahme: Kopf sagt 0 Frames → wird beim Lesen repariert
        let dir = Paths.base.appendingPathComponent("wav-repair-test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("ich.wav")
        let tone: [Float] = (0..<32000).map { Float(sin(Double($0) * 0.03) * 0.4) }
        if let w = try? WavWriter(url: wav) { w.write(tone); w.close() }
        let intact = WavWriter.read(wav).count
        check(intact == tone.count, "WAV-Spur intakt gelesen (\(intact) Frames)")
        let old = Date().addingTimeInterval(-60)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: wav.path)
        check(!WavRepair.repairIfTruncated(wav), "intakte WAV bleibt unangetastet")
        if var d = try? Data(contentsOf: wav), let r = d.range(of: Data("data".utf8)) {
            d.replaceSubrange(r.upperBound..<r.upperBound + 4, with: Data(count: 4))      // data-Größe = 0 (wie nach Absturz)
            d.replaceSubrange(4..<8, with: Data(count: 4))
            try? d.write(to: wav)
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: wav.path)
        }
        let repaired = WavWriter.read(wav).count
        check(repaired == tone.count, "Spur nach Absturz wieder lesbar (\(repaired) von \(tone.count) Frames)")
        try? FileManager.default.removeItem(at: dir)

        print("Effizienz: \(ok)/\(ok + bad) ok")
        return bad == 0 ? 0 : 1
    }

    /// Stumm: startet nur den Tap (nichts wird abgespielt) und zählt Audio-Stücke und Neuaufbauten.
    private static func tapProbe(seconds: Double) -> Int32 {
        let tap = SystemAudioTap()
        let lock = NSLock(); var chunks = 0
        do { try tap.start { _ in lock.lock(); chunks += 1; lock.unlock() } } catch { print("Tap startet nicht: \(error.localizedDescription)"); return 1 }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            lock.lock(); let c = chunks; lock.unlock()
            print(String(format: "%4.1f s  Ausgabegerät läuft: %@  Stücke: %d", Date().timeIntervalSince(t0),
                         SystemAudioTap.outputRunning().map { $0 ? "ja" : "nein" } ?? "?", c))
        }
        tap.stop()
        return 0
    }
}
