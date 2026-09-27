import AppKit
import Foundation

// MARK: - Test-Befehle (nie App-Modus; alles mit Daten nur mit FLOW_HOME=<Testordner>)
//
//   Flow --audio-decode-test a.mp3 b.opus …          welche Dekoder lesen welche Datei (Dauer, Zeit, Fehlertext)
//   Flow --audio-import f.mp3 [--ref f.json] [--no-whisper] [--summary] [--stop-after N] [--keep]
//                                                     ganze Auswertung wie in der App: Echtzeitfaktor, Spitzenspeicher,
//                                                     Sprecher, Sprache je Stück, WER gegen Referenz
//   Flow --audio-import-resume <id> [--ref f.json]   Fortsetzen (nach --stop-after oder kill -9)
//   Flow --audio-import-cancel-test f.mp3            abbrechen nach 2 Stücken → Zustand prüfen → fortsetzen → fertig
//   Flow --audio-import-inbox-test f.mp3 kaputt.mp3  Eingangsordner (FLOW_EINGANG=<Ordner>): annehmen, Erledigt/Nicht lesbar
//   Flow --audio-export <id> <ordner>               md/txt/srt schreiben
//   Flow --audio-import-render <ordner>             Sichtprüfung (Karte, Zeile, Notiz, Hub-Ablage, Pille, Meldungen)

enum AudioImportCLI {
    static func run(_ args: [String]) -> Int32? {
        switch args[1] {
        case "--audio-decode-test": return decodeTest(Array(args.dropFirst(2)))
        case "--audio-import": return SelfTestCLI.guardedHome { wait { try await importFile(args) } }
        case "--audio-import-resume": return SelfTestCLI.guardedHome { wait { try await resume(args) } }
        case "--audio-import-cancel-test": return SelfTestCLI.guardedHome { wait { try await cancelTest(args) } }
        case "--audio-import-inbox-test": return SelfTestCLI.guardedHome { wait { try await inboxTest(args) } }
        case "--audio-export": return SelfTestCLI.guardedHome { export(args) }
        case "--audio-drop-test": return SelfTestCLI.guardedHome { wait { try await dropTest(args) } }
        case "--audio-import-render": return AudioImportRender.run(dir: args.count > 2 ? args[2] : "/tmp/audioimport-render")
        default: return nil
        }
    }

    static func wait(_ body: @escaping () async throws -> Void) -> Int32 {
        var code: Int32 = 0
        var done = false
        Task {
            do { try await body() } catch { print("Fehler: \(error)"); code = 1 }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }

    private static func opt(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: Dekoder-Matrix

    static func decodeTest(_ files: [String]) -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vf-decode-\(getpid()).pcm")
        defer { try? FileManager.default.removeItem(at: tmp) }
        print("Datei".padding(toLength: 26, withPad: " ", startingAt: 0) + "Ergebnis")
        for f in files {
            let u = URL(fileURLWithPath: f)
            let t0 = Date()
            let name = u.lastPathComponent.padding(toLength: 26, withPad: " ", startingAt: 0)
            do {
                let r = try AudioDecoder.decode(u, to: tmp)
                let src = PCMSource(tmpOrNil: tmp)
                print(name + String(format: "OK  %6.2f s  %-13@ %4.0f ms  Sprache %.1f s", r.seconds, r.decoder, Date().timeIntervalSince(t0) * 1000, src?.speechSeconds() ?? 0))
            } catch {
                print(name + "FEHLER  " + error.localizedDescription)
            }
        }
        print("ffmpeg vorhanden: \(AudioImportFormats.ffmpeg ?? "nein") (wird nur für webm/mkv/wma … gebraucht)")
        return 0
    }

    // MARK: Ganze Auswertung

    final class Peak: @unchecked Sendable {
        var app = 0.0, appFootprint = 0.0, whisper = 0.0
        var run = true
    }

    static func prepareEngines(whisper: Bool) async {
        _ = Settings.shared
        try? await Transcriber.shared.load()
        if whisper, WhisperEngine.available {
            WhisperEngine.shared.start()
            let t0 = Date()
            while !WhisperEngine.shared.serverUp, Date().timeIntervalSince(t0) < 40 { try? await Task.sleep(nanoseconds: 100_000_000) }
            print(WhisperEngine.shared.serverUp ? "Whisper-Server bereit" : "Whisper-Server NICHT bereit – nur Parakeet")
        }
    }

    private static func sampler(_ peak: Peak) -> Task<Void, Never> {
        Task.detached {
            while peak.run {
                let s = MemProbe.snap()
                peak.app = max(peak.app, s.totalMB); peak.appFootprint = max(peak.appFootprint, s.footprintMB)
                if let pid = WhisperEngine.shared.serverPID { peak.whisper = max(peak.whisper, MemProbe.snap(pid).footprintMB) }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func waitIdle(showProgress: Bool = true) async {
        var last = ""
        while await MainActor.run(body: { AudioImport.shared.isBusy }) {
            if showProgress {
                let line = await MainActor.run { () -> String in
                    guard let id = AudioImport.shared.runningID, let l = AudioImport.shared.live[id] else { return "" }
                    return "  \(Int(l.fraction * 100)) % \(l.label)"
                }
                if line != last && !line.isEmpty && !line.contains("… 1") { last = line }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    static func importFile(_ args: [String]) async throws {
        guard args.count > 2 else { print("Aufruf: --audio-import datei [--ref ref.json] [--no-whisper] [--summary] [--stop-after N]"); return }
        let url = URL(fileURLWithPath: args[2])
        let whisper = !args.contains("--no-whisper")
        await MainActor.run {
            AudioImportSettings.shared.whisperAssist = whisper
            Settings.shared.autoSummary = args.contains("--summary")
        }
        if let s = opt(args, "--stop-after"), let n = Int(s) { AudioImportProcessor.testStopAfterChunks = n }
        if let c = opt(args, "--chunk"), let v = Double(c) { AudioImportProcessor.chunkTarget = v }
        await prepareEngines(whisper: whisper)
        let base = await MemProbe.step("Leerlauf (Parakeet geladen)")
        let peak = Peak()
        let sam = sampler(peak)
        let t0 = Date()
        let ids = await MainActor.run { AudioImport.shared.open([url], origin: .cli) }
        guard let id = ids.first else { print("nicht angenommen"); peak.run = false; return }
        await waitIdle()
        let wall = Date().timeIntervalSince(t0)
        // Zusammenfassung läuft danach im Hintergrund – im Test abwarten
        if args.contains("--summary") {
            let ts = Date()
            while await MainActor.run(body: { AudioImportFiles.loadJob(id)?.phase == .summarizing }) { try? await Task.sleep(nanoseconds: 300_000_000) }
            print(String(format: "Zusammenfassung: %.1f s", Date().timeIntervalSince(ts)))
        }
        peak.run = false
        _ = await sam.value
        await report(id: id, wall: wall, peak: peak, base: base, ref: opt(args, "--ref"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // Freigabe nach leerer Warteschlange abwarten
        _ = await MemProbe.step("nach Freigabe (Sprechertrennung weg, malloc aufgeräumt)")
        stopWhisper()
    }

    /// Test-Server wirklich beenden (terminate ist asynchron – sonst bliebe er nach dem Test-Ende hängen)
    static func stopWhisper() {
        let pid = WhisperEngine.shared.serverPID
        WhisperEngine.shared.stop()
        guard let pid else { return }
        for _ in 0..<30 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    static func resume(_ args: [String]) async throws {
        guard args.count > 2 else { return }
        let id = args[2]
        AudioImportProcessor.testStopAfterChunks = nil
        let whisper = !args.contains("--no-whisper")
        await MainActor.run { AudioImportSettings.shared.whisperAssist = whisper; Settings.shared.autoSummary = false }
        await prepareEngines(whisper: whisper)
        let base = await MemProbe.step("Leerlauf (Parakeet geladen)")
        let before = AudioImportFiles.loadJob(id)
        print("Vorher: Phase \(before?.phase.rawValue ?? "?"), \(before?.chunksDone ?? 0)/\(before?.chunks.count ?? 0) Stücke")
        let peak = Peak()
        let sam = sampler(peak)
        let t0 = Date()
        // wie beim App-Start: Unterbrochenes wird fortgesetzt
        await MainActor.run { AudioImport.shared.start(pill: nil) }
        if await MainActor.run(body: { !AudioImport.shared.isBusy }) { await MainActor.run { AudioImport.shared.resume(id) } }
        await waitIdle()
        peak.run = false
        _ = await sam.value
        await report(id: id, wall: Date().timeIntervalSince(t0), peak: peak, base: base, ref: opt(args, "--ref"))
        stopWhisper()
    }

    // MARK: Abbrechen / Fortsetzen

    static func cancelTest(_ args: [String]) async throws {
        guard args.count > 2 else { return }
        var ok = 0, total = 0
        func check(_ c: Bool, _ s: String) { total += 1; if c { ok += 1 }; print((c ? "ok      " : "FEHLER  ") + s) }
        await MainActor.run { AudioImportSettings.shared.whisperAssist = false; Settings.shared.autoSummary = false }
        await prepareEngines(whisper: false)
        let ids = await MainActor.run { AudioImport.shared.open([URL(fileURLWithPath: args[2])], origin: .cli) }
        guard let id = ids.first else { print("nicht angenommen"); return }
        // warten bis 2 Stücke fertig, dann abbrechen
        while (AudioImportFiles.loadJob(id)?.chunksDone ?? 0) < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
        let tc = Date()
        await MainActor.run { AudioImport.shared.cancel(id) }
        await waitIdle(showProgress: false)
        let stopMs = Date().timeIntervalSince(tc) * 1000
        let j = AudioImportFiles.loadJob(id)
        let m = await MainActor.run { MeetingStore.shared.meeting(id) }
        check(j?.phase == .cancelled, "Phase nach Abbruch = cancelled (\(j?.phase.rawValue ?? "?")), \(String(format: "%.0f", stopMs)) ms bis Stopp")
        check(m?.status == .failed && (m?.progressNote ?? "").contains("Abgebrochen"), "Notiz zeigt „\(m?.progressNote ?? "-")“")
        let doneAtCancel = j?.chunksDone ?? 0
        check(doneAtCancel >= 2 && doneAtCancel < (j?.chunks.count ?? 0), "Zwischenstand bleibt: \(doneAtCancel)/\(j?.chunks.count ?? 0) Stücke")
        check(FileManager.default.fileExists(atPath: AudioImportFiles.pcmURL(id).path), "dekodierter Ton bleibt für „Fortsetzen“")
        check((m?.segments.count ?? 0) > 0, "bisheriges Transkript sichtbar (\(m?.segments.count ?? 0) Abschnitte)")
        // Fortsetzen über den gleichen Weg wie „Neu auswerten“ im Menü
        let tr = Date()
        await MainActor.run { AppReprocess.reprocess(id) }
        await waitIdle(showProgress: false)
        let j2 = AudioImportFiles.loadJob(id)
        let m2 = await MainActor.run { MeetingStore.shared.meeting(id) }
        check(j2?.phase == .done && m2?.status == .done, "fortgesetzt und fertig in \(String(format: "%.1f", Date().timeIntervalSince(tr))) s")
        check((j2?.resumes ?? 0) == 1, "1× fortgesetzt, nicht neu begonnen (decoded/diarized blieben)")
        check(!FileManager.default.fileExists(atPath: AudioImportFiles.pcmURL(id).path), "Zwischendateien nach Erfolg gelöscht")
        print("\(ok)/\(total) ok")
    }

    // MARK: Eingangsordner

    static func inboxTest(_ args: [String]) async throws {
        guard ProcessInfo.processInfo.environment["FLOW_EINGANG"] != nil else { print("Abbruch: FLOW_EINGANG=<Testordner> setzen"); return }
        var ok = 0, total = 0
        func check(_ c: Bool, _ s: String) { total += 1; if c { ok += 1 }; print((c ? "ok      " : "FEHLER  ") + s) }
        await MainActor.run { AudioImportSettings.shared.whisperAssist = false; Settings.shared.autoSummary = false }
        await prepareEngines(whisper: false)
        let st = AudioImportSettings.shared
        try? FileManager.default.removeItem(at: st.inboxURL)
        await MainActor.run {
            AudioImport.shared.start(pill: nil)
            st.inboxEnabled = true
        }
        check(FileManager.default.fileExists(atPath: st.doneURL.path), "Eingang/ + Erledigt/ beim Einschalten angelegt (\(st.inboxDisplay))")
        let t0 = Date()
        // Dateien „langsam“ hineinkopieren (wie ein Download): erst halb, dann fertig
        var names: [String] = []
        for f in args.dropFirst(2) {
            let src = URL(fileURLWithPath: f)
            let dst = st.inboxURL.appendingPathComponent(src.lastPathComponent)
            let data = try Data(contentsOf: src)
            try data.prefix(data.count / 2).write(to: dst)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            try data.write(to: dst)
            names.append(src.lastPathComponent)
        }
        // warten, bis alles aus dem Eingang verschwunden ist
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let left = (try? FileManager.default.contentsOfDirectory(atPath: st.inboxURL.path))?.filter { names.contains($0) } ?? []
            let busy = await MainActor.run { AudioImport.shared.isBusy }
            if left.isEmpty && !busy { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let done = (try? FileManager.default.contentsOfDirectory(atPath: st.doneURL.path)) ?? []
        let failed = (try? FileManager.default.contentsOfDirectory(atPath: st.failedURL.path)) ?? []
        let notes = await MainActor.run { MeetingStore.shared.meetings.filter { $0.app == "Datei" } }
        for n in names {
            let good = !n.contains("kaputt")
            if good {
                check(done.contains(n), "\(n) → Erledigt/ (nicht gelöscht)")
                let note = notes.first { AudioImportFiles.loadJob($0.id)?.fileName == n }
                check(note?.status == .done && !(note?.segments.isEmpty ?? true), "Notiz „\(note?.title ?? "-")“ fertig, \(note?.segments.count ?? 0) Abschnitte, Quelle „\(note?.app ?? "-")“")
                if let note, let j = AudioImportFiles.loadJob(note.id) { check(j.source.contains("/Erledigt/"), "Notiz verweist auf den neuen Ort in Erledigt/") }
            } else {
                check(failed.contains(n), "\(n) → „Nicht lesbar/“ (kein Endlos-Versuch)")
                check(!notes.contains { AudioImportFiles.loadJob($0.id)?.fileName == n }, "keine leere Notiz für \(n)")
                let err = await MainActor.run { AudioImport.shared.errors.first { $0.fileName == n }?.message }
                check(err != nil, "Fehlerkarte: „\(err ?? "-")“")
            }
        }
        print(String(format: "Eingangsordner-Test in %.1f s", Date().timeIntervalSince(t0)))
        print("\(ok)/\(total) ok")
    }

    // MARK: Export

    static func export(_ args: [String]) -> Int32 {
        guard args.count > 3, let m = MeetingStore.shared.meeting(args[2]) else { print("Aufruf: --audio-export <id> <ordner>"); return 2 }
        let dir = URL(fileURLWithPath: args[3])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for k in NoteExport.Kind.allCases {
            let u = dir.appendingPathComponent("notiz.\(k.ext)")
            try? NoteExport.content(m, k).write(to: u, atomically: true, encoding: .utf8)
            print(u.path)
        }
        return 0
    }

    // MARK: Bericht

    struct RefTurn: Decodable { let speaker: String; let lang: String; let start: Double; let end: Double; let text: String }

    private static func report(id: String, wall: Double, peak: Peak, base: MemProbe.Snap, ref: String?) async {
        let m = await MainActor.run { MeetingStore.shared.meeting(id) ?? AudioImportProcessor.loadMeetingFromDisk(id) }
        let j = AudioImportFiles.loadJob(id)
        guard let m, let j else { print("keine Notiz (gelöscht? Fehler: \(AudioImport.shared.errors.first?.message ?? "-"))"); return }
        print("─────────────────────────────────────────────")
        print("Notiz \(id): „\(m.title)“ · Quelle \(m.app ?? "-") · Status \(m.status.rawValue) · Phase \(j.phase.rawValue)")
        print(String(format: "Ton %.1f min · Dekoder %@ · %d Stücke", j.duration / 60, j.decoder ?? "-", j.chunks.count))
        let t = j.timings
        print(String(format: "Zeiten: lesen %.1f s · Sprecher %.1f s · Parakeet %.1f s · Whisper %.1f s (%d×, %.0f s Ton = %.0f %%) · Erkennung gesamt %.1f s",
                     t["decode"] ?? 0, t["diarize"] ?? 0, t["asr"] ?? 0, t["whisper"] ?? 0, j.whisperCalls, j.whisperSeconds,
                     j.whisperSeconds / max(j.duration, 1) * 100, t["transcribe"] ?? 0))
        print(String(format: "GESAMT %.1f s für %.1f min → Echtzeitfaktor %.4f (%.0f× schneller als Echtzeit)", wall, j.duration / 60, wall / max(j.duration, 1), max(j.duration, 1) / max(wall, 0.01)))
        print(String(format: "Spitzenspeicher App: %.0f MB (Footprint %.0f MB, +%.0f MB über Leerlauf %.0f MB) · Whisper-Server: %.0f MB",
                     peak.app, peak.appFootprint, peak.app - base.totalMB, base.totalMB, peak.whisper))
        let langs = j.chunks.map { $0.language ?? "?" }
        print("Sprache je Stück: " + langs.joined(separator: " "))
        print("Sprecher erkannt: \(m.speakerKeys.count) (\(m.speakerKeys.joined(separator: ", "))) · \(m.segments.count) Abschnitte")
        if let first = m.segments.first { print("Anfang: [\(Meeting.stamp(first.start))] \(m.name(for: first.speaker)): \(first.text.prefix(120))") }
        if let ref, let d = try? Data(contentsOf: URL(fileURLWithPath: ref)), let turns = try? JSONDecoder().decode([RefTurn].self, from: d) {
            let refText = turns.map(\.text).joined(separator: " ")
            let hyp = m.segments.map(\.text).joined(separator: " ")
            print(String(format: "WER gegen Referenz: %.1f %% (%d Referenzwörter; Zahlen wie „vierundsechzig“ ↔ „64“ zählen als Fehler)", wer(refText, hyp) * 100, words(refText).count))
            // Sprecher-Zuordnung: Überlappung Referenz-Sprecher × erkannter Sprecher
            var ov: [String: [String: Double]] = [:]
            for s in m.segments {
                for r in turns where r.end > s.start && r.start < s.end {
                    ov[s.speaker, default: [:]][r.speaker, default: 0] += min(r.end, s.end) - max(r.start, s.start)
                }
            }
            let matched = ov.values.map { $0.values.max() ?? 0 }.reduce(0, +)
            let all = ov.values.flatMap(\.values).reduce(0, +)
            let mapping = ov.map { k, v in "\(k)→\(v.max { $0.value < $1.value }?.key ?? "?")" }.sorted().joined(separator: " ")
            print(String(format: "Sprecher: %d Referenz-Stimmen, %d erkannt · Zuordnung %.1f %% der Sprechzeit richtig (%@)",
                         Set(turns.map(\.speaker)).count, m.speakerKeys.count, matched / max(all, 1) * 100, mapping))
            // Sprache je Stück gegen Referenz (Mehrheit nach Dauer)
            var right = 0
            for c in j.chunks {
                var de = 0.0, en = 0.0
                for r in turns where r.end > c.start && r.start < c.end {
                    let o = min(r.end, c.end) - max(r.start, c.start)
                    if r.lang == "de" { de += o } else { en += o }
                }
                if (de >= en ? "de" : "en") == c.language { right += 1 }
            }
            print("Sprache je Stück richtig: \(right)/\(j.chunks.count)")
            // Sprechdauer je Sprache: erkannt vs. Referenz
            let pde = j.chunks.compactMap(\.deSeconds).reduce(0, +), pen = j.chunks.compactMap(\.enSeconds).reduce(0, +)
            let rde = turns.filter { $0.lang == "de" }.map { $0.end - $0.start }.reduce(0, +)
            let ren = turns.filter { $0.lang == "en" }.map { $0.end - $0.start }.reduce(0, +)
            print(String(format: "Sprechdauer DE/EN erkannt %.0f/%.0f s · Referenz %.0f/%.0f s", pde, pen, rde, ren))
        }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Wortfehlerrate (Levenshtein über Wörter, O(n·m) Speicher sparsam in zwei Zeilen)
    static func wer(_ ref: String, _ hyp: String) -> Double {
        let r = words(ref), h = words(hyp)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count), cur = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            cur[0] = i
            for k in 1...max(h.count, 1) where h.count > 0 {
                cur[k] = min(prev[k] + 1, cur[k - 1] + 1, prev[k - 1] + (r[i - 1] == h[k - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}

/// „Neu auswerten“ genau wie im Menü (MeetingController.reprocess → AudioImport) – im CLI ohne AppDelegate
enum AppReprocess {
    static func reprocess(_ id: String) {
        if AudioImport.isFileNote(id) { AudioImport.shared.resume(id) }
    }
}

extension PCMSource {
    convenience init?(tmpOrNil url: URL) { try? self.init(url) }
}

// MARK: - Ablegen-Test: Datei-URL + Datei-Versprechen (wie Sprachmemos), ohne App-Modus
//   FLOW_HOME=<test> Flow --audio-drop-test "New Recording 69.qta"

final class TestPromiseSource: NSObject, NSFilePromiseProviderDelegate {
    let file: URL
    init(_ f: URL) { file = f }
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { file.lastPathComponent }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try FileManager.default.copyItem(at: file, to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

extension AudioImportCLI {
    static func dropTest(_ args: [String]) async throws {
        guard args.count > 2 else { print("Aufruf: --audio-drop-test datei.qta"); return }
        let file = URL(fileURLWithPath: args[2]).standardizedFileURL.absoluteURL
        var ok = 0, total = 0
        func check(_ c: Bool, _ s: String) { total += 1; if c { ok += 1 }; print((c ? "ok      " : "FEHLER  ") + s) }
        await MainActor.run { AudioImportSettings.shared.whisperAssist = false; Settings.shared.autoSummary = false }
        await prepareEngines(whisper: false)
        _ = NSApplication.shared
        // 1) Finder: Datei-URL
        let pbURL = NSPasteboard(name: .init("vf-test-url-\(getpid())"))
        pbURL.clearContents(); pbURL.writeObjects([file as NSURL])
        check(AudioDropReader.canAccept(pbURL), "Finder-Zug (Datei-URL) wird angenommen")
        // 2) Sprachmemos: Versprechen für com.apple.quicktime-audio
        let src = TestPromiseSource(file)
        let prov = NSFilePromiseProvider(fileType: "com.apple.quicktime-audio", delegate: src)
        let pbP = NSPasteboard(name: .init("vf-test-promise-\(getpid())"))
        pbP.clearContents(); pbP.writeObjects([prov])
        let peek = AudioDropReader.peek(pbP)
        check(peek.urls.isEmpty && peek.promises.count == 1, "Sprachmemos-Zug: keine URL, 1 Versprechen (Typen \(peek.promiseTypes))")
        check(AudioDropReader.canAccept(pbP), "Versprechen (QuickTime-Audio) wird angenommen")
        // 3) Mail-Anhang als PDF-Versprechen → abgelehnt
        let pdfProv = NSFilePromiseProvider(fileType: "com.adobe.pdf", delegate: src)
        let pbPDF = NSPasteboard(name: .init("vf-test-pdf-\(getpid())"))
        pbPDF.clearContents(); pbPDF.writeObjects([pdfProv])
        check(!AudioDropReader.canAccept(pbPDF), "PDF-Versprechen (Mail-Anhang) wird abgelehnt")
        let pbText = NSPasteboard(name: .init("vf-test-text-\(getpid())"))
        pbText.clearContents(); pbText.setString("nur Text", forType: .string)
        check(!AudioDropReader.canAccept(pbText), "reiner Text wird abgelehnt")
        // 4) Eingelöstes Versprechen importieren. Das Einlösen selbst (NSFilePromiseReceiver.receivePromisedFiles) braucht einen
        //    echten Zug aus der Quell-App – in-process ohne Zug liefert AppKit nichts. Hier: genau der Zustand danach
        //    (Datei liegt in abgelegt/<zufall>/), dann derselbe Weg wie acceptDrop → open(…, ownedCopies: true).
        let dir = AudioDropReader.promiseRoot.appendingPathComponent("test\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let promised = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: promised)
        let ids = await MainActor.run { AudioImport.shared.open([promised], origin: .drop, ownedCopies: true) }
        let id: String? = ids.first
        check(id != nil, "versprochene Datei angenommen → Notiz „\(id.flatMap { i in MeetingStore.shared.meeting(i)?.title } ?? "-")“")
        guard let id else { print("\(ok)/\(total) ok"); return }
        let j0 = AudioImportFiles.loadJob(id)
        check(j0.map { AudioDropReader.isInside($0.source, AudioDropReader.promiseRoot) } == true && j0?.ownedCopy == true, "liegt in abgelegt/ (\(j0?.fileName ?? "-"))")
        while await MainActor.run(body: { AudioImport.shared.isBusy }) { try? await Task.sleep(nanoseconds: 200_000_000) }
        let m = await MainActor.run { MeetingStore.shared.meeting(id) }
        let j = AudioImportFiles.loadJob(id)
        check(m?.status == .done && !(m?.segments.isEmpty ?? true), "transkribiert: „\(m?.title ?? "-")“, \(m?.segments.count ?? 0) Abschnitte, \(m?.speakerKeys.count ?? 0) Sprecher")
        check(j.map { AudioDropReader.isInside($0.source, AudioImportFiles.folder(id)) } == true, "Datei wanderte in den Notiz-Ordner (\(j.map { URL(fileURLWithPath: $0.source).lastPathComponent } ?? "-")) → wird mit der Notiz gelöscht")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: AudioDropReader.promiseRoot.path)) ?? []
        check(leftovers.isEmpty, "abgelegt/ ist wieder leer")
        check(j?.kindLabel == "Sprachmemo", "Art für die Fertig-Karte: \(j?.kindLabel ?? "-")")
        if let n = await MainActor.run(body: { AudioImport.shared.doneNotice(id, summarizing: false) }) {
            print("        Karte: \(n.title) / \(n.text) [\(n.primary?.0 ?? "")] [\(n.secondary?.0 ?? "")]")
        }
        print("\(ok)/\(total) ok")
    }
}
