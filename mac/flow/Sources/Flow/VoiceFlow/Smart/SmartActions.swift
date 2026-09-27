import AppKit
import EventKit

// MARK: - „Flow lernt mit“: Aktionen beim „Ja“ – immer über die vorhandenen Stores/APIs

struct SmartActions {
    /// Erinnerungen anlegen (Standard: EventKit, Zugriff wird erst beim ersten „Ja“ erfragt)
    var addReminders: (_ tasks: [SmartTask], _ note: String, _ done: @escaping (Result<Int, SmartEventKit.Failure>) -> Void) -> Void = SmartEventKit.addReminders
    /// Termin anlegen (1 h)
    var addEvent: (_ title: String, _ start: Date, _ done: @escaping (Result<Void, SmartEventKit.Failure>) -> Void) -> Void = SmartEventKit.addEvent

    /// Main-Thread. `done(ok, Meldung für die Pille)`
    func perform(_ s: SmartSuggestion, choice: String?, done: @escaping (Bool, String) -> Void) {
        let p = s.payload
        switch s.kind {
        case .dictionary:
            if let old = p.correctionOld, let new = p.term {
                CorrectionLearner.remember(old: old, new: new)
                Settings.shared.save()
                done(true, "Gemerkt: „\(old)“ → „\(new)“")
            } else if let term = p.term, !term.isEmpty {
                let st = Settings.shared
                if !st.dictionary.contains(where: { $0.write.lowercased() == term.lowercased() }) {
                    // Nur als Hinweis für die Erkennung – ersetzt nichts blind
                    st.dictionary.append(DictEntry(heard: term, write: term, learned: true, vocabOnly: true))
                    st.save()
                    PartnerVocab.shared.learned(term, source: .suggestion)
                }
                done(true, "„\(term)“ steht jetzt im Wörterbuch")
            } else { done(false, "") }

        case .snippet:
            guard let text = p.text, !text.isEmpty else { return done(false, "") }
            var trigger = (choice ?? p.trigger ?? "").trimmingCharacters(in: .whitespaces)
            let used = Set(SnippetStore.shared.snippets.map { $0.trigger.pgKey })
            if trigger.isEmpty || used.contains(trigger.pgKey) {
                trigger = (p.triggerOptions ?? []).first { !used.contains($0.pgKey) } ?? ""
            }
            guard !trigger.isEmpty else { return done(false, "Kürzel ist schon vergeben") }
            SnippetStore.shared.upsert(Snippet(trigger: trigger, text: text))
            done(true, "Snippet „\(trigger)“ gespeichert")

        case .style:
            guard let c = AppCategory(rawValue: p.category ?? ""), let k = StyleKind(rawValue: p.style ?? "") else { return done(false, "") }
            StyleStore.shared.set(k, for: c)
            done(true, "Stil für \(SmartLearner.shortLabel(c)): \(k == .formal ? "Formell" : "Locker")")

        case .transform:
            guard let text = p.text, !text.isEmpty else { return done(false, "") }
            let name = (p.trigger?.isEmpty == false ? p.trigger! : "Meine Anweisung")
            TransformStore.shared.upsert(TransformPreset(name: name, instruction: text, spokenTriggers: [name.lowercased()]))
            done(true, "Transform „\(name)“ gespeichert")

        case .reminders:
            let tasks = p.tasks ?? []
            let title = s.text.components(separatedBy: "„").dropFirst().first?.components(separatedBy: "“").first ?? "Meeting"
            addReminders(tasks, "Aus dem Meeting „\(title)“ (Flow)") { r in
                DispatchQueue.main.async {
                    switch r {
                    case .success(let n): done(true, n == 1 ? "1 Erinnerung angelegt" : "\(n) Erinnerungen angelegt")
                    case .failure(let f): done(false, f.message)
                    }
                }
            }

        case .calendar:
            guard let d = p.date else { return done(false, "") }
            addEvent(p.eventTitle ?? "Termin", d) { r in
                DispatchQueue.main.async {
                    switch r {
                    case .success: done(true, "Termin eingetragen: \(SmartLearner.shortDate(d))")
                    case .failure(let f): done(false, f.message)
                    }
                }
            }
        }
    }
}

/// Kalender & Erinnerungen. Zugriff wird erst gefragt, wenn du zum ersten Mal „Ja“ sagt – nie vorher.
enum SmartEventKit {
    struct Failure: Error { let message: String }

    static let store = EKEventStore()

    private static func hasUsageText(_ key: String) -> Bool {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false
    }

    static func access(_ type: EKEntityType, _ go: @escaping (Bool, String) -> Void) {
        let status = EKEventStore.authorizationStatus(for: type)
        let what = type == .reminder ? "Erinnerungen" : "Kalender"
        switch status {
        case .fullAccess: go(true, "")
        case .writeOnly: go(type == .event, "Kein Zugriff auf \(what)")
        case .notDetermined:
            // Ohne Begründungstext im App-Paket würde macOS die App beim Fragen beenden
            let key = type == .reminder ? "NSRemindersFullAccessUsageDescription" : "NSCalendarsFullAccessUsageDescription"
            guard hasUsageText(key) else { go(false, "\(what)-Freigabe fehlt im App-Paket"); return }
            let cb: (Bool, Error?) -> Void = { ok, _ in DispatchQueue.main.async { go(ok, ok ? "" : "Kein Zugriff auf \(what)") } }
            if type == .reminder { store.requestFullAccessToReminders(completion: cb) } else { store.requestFullAccessToEvents(completion: cb) }
        default:
            go(false, "Kein Zugriff auf \(what) – in den Systemeinstellungen freigeben")
        }
    }

    static func addReminders(_ tasks: [SmartTask], note: String, done: @escaping (Result<Int, Failure>) -> Void) {
        access(.reminder) { ok, why in
            guard ok else { return done(.failure(Failure(message: why))) }
            guard let cal = store.defaultCalendarForNewReminders() else { return done(.failure(Failure(message: "Keine Erinnerungsliste gefunden"))) }
            var n = 0
            for t in tasks {
                let r = EKReminder(eventStore: store)
                r.title = t.title
                r.calendar = cal
                r.notes = note
                if let due = t.due {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                }
                do { try store.save(r, commit: false); n += 1 } catch { log("Flow lernt mit: Erinnerung nicht gespeichert (\(error.localizedDescription))") }
            }
            do { try store.commit() } catch { return done(.failure(Failure(message: "Erinnerungen nicht gespeichert"))) }
            done(.success(n))
        }
    }

    static func addEvent(_ title: String, _ start: Date, done: @escaping (Result<Void, Failure>) -> Void) {
        access(.event) { ok, why in
            guard ok else { return done(.failure(Failure(message: why))) }
            guard let cal = store.defaultCalendarForNewEvents else { return done(.failure(Failure(message: "Kein Kalender gefunden"))) }
            let e = EKEvent(eventStore: store)
            e.title = title
            e.startDate = start
            e.endDate = start.addingTimeInterval(3600)
            e.calendar = cal
            e.notes = "Aus einem Diktat (Flow)"
            do { try store.save(e, span: .thisEvent, commit: true); done(.success(())) }
            catch { done(.failure(Failure(message: "Termin nicht gespeichert"))) }
        }
    }
}
