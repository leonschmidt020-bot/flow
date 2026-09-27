import Foundation

// MARK: - „Flow lernt mit“: optionaler Abend-Überblick über Claude (Standard AUS)
//
// Einziger Weg, auf dem etwas vom Mac geht – und nur, wenn du ihn einschaltest.
// Geschickt werden NUR abgeleitete Zahlen + häufige Formulierungen/Namen (je ≥ 3×), nie Diktate oder Transkripte.

enum SmartDigest {
    static let system = """
    Du bist ein freundlicher Coach für eine lokale Diktier-App („Flow“). Du bekommst NUR Zähler und häufige Formulierungen \
    des Nutzers – keine Texte. Gib genau 3 kurze, konkrete Tipps auf Deutsch (je ein Satz, jeweils mit „- “ am Anfang), \
    wie er Flow morgen besser nutzen kann: Snippets, Wörterbuch, Stil je App-Art, Transforms, Notetaker. \
    Beziehe dich auf die Zahlen. Keine Einleitung, kein Schluss, nichts erfinden.
    """

    /// Nur nach 21 Uhr, einmal pro Tag, wenn eingeschaltet
    static func runIfDue(now: Date = Date()) {
        let f = SmartFlow.shared
        guard f.prefs.enabled, f.prefs.nightlyDigest, ClaudeCLI.isAvailable, !f.digestRunning else { return }
        guard Calendar.current.component(.hour, from: now) >= 21 else { return }
        let day = SmartLearner.dayKey.string(from: now)
        guard f.prefs.lastDigestDay != day, f.snapshot.dictations > 0 else { return }
        run()
    }

    static func run() {
        let f = SmartFlow.shared
        let day = SmartLearner.dayKey.string(from: Date())
        f.updatePrefs { $0.lastDigestDay = day }
        let input = payload(f.snapshot, prefs: f.prefs, styles: StyleStore.shared.styles)
        log("Flow lernt mit: Abend-Überblick wird bei Claude angefragt (\(input.count) Zeichen, nur Zähler)")
        Task {
            do {
                let out = try await ClaudeCLI.run(system: system, input: input, model: "sonnet", timeout: 120)
                f.setDigest(SmartDigestNote(date: Date(), text: out.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                log("Flow lernt mit: Abend-Überblick fehlgeschlagen (\(error.localizedDescription))")
            }
        }
    }

    /// Das GANZE Paket, das an Claude ginge (auch zum Anzeigen „Was wird geschickt?“)
    static func payload(_ w: SmartWissen, prefs: SmartPrefs, styles: [String: StyleKind]) -> String {
        func top(_ d: [String: SmartCount], _ n: Int) -> [[String: Any]] {
            d.values.filter { $0.n >= 3 }.sorted { $0.n > $1.n }.prefix(n).map { ["text": $0.form, "anzahl": $0.n] }
        }
        var phrases: [String: SmartCount] = [:]
        for (_, d) in w.phrases { for (k, v) in d where (phrases[k]?.n ?? 0) < v.n { phrases[k] = v } }
        var signOffs: [String: SmartCount] = [:]
        for (_, d) in w.signOffs { for (k, v) in d where (signOffs[k]?.n ?? 0) < v.n { signOffs[k] = v } }
        let terms = w.terms.values.filter { $0.n >= 3 }.sorted { $0.n > $1.n }.prefix(10).map { ["name": $0.form, "anzahl": $0.n] as [String: Any] }
        var reg: [String: Any] = [:]
        for (cat, r) in w.register {
            reg[cat] = ["formell": r.formal, "locker": r.casual, "eingestellt": styles[cat]?.rawValue ?? "formal"]
        }
        let obj: [String: Any] = [
            "diktate": w.dictations, "woerter": w.words, "meetings": w.meetings,
            "diktate_je_app_art": w.categories,
            "register_je_app_art": reg,
            "diktate_je_stunde": w.hours,
            "haeufige_formulierungen": top(phrases, 10),
            "abschiedsformeln": top(signOffs, 5),
            "haeufige_namen": terms,
            "meeting_themen": top(w.meetingTopics, 8),
            "vorschlaege": SmartKind.allCases.reduce(into: [String: Any]()) { r, k in
                let s = prefs.stat(k); r[k.rawValue] = ["angenommen": s.accepted, "abgelehnt": s.dismissed, "an": prefs.isOn(k)]
            },
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
