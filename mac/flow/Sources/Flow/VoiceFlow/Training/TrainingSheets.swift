import AppKit
import SwiftUI

// MARK: - Aufnahme-Blatt für ein Stimm-Level

struct LevelRecordingSheet: View {
    @ObservedObject var session: LevelSession
    @ObservedObject var trainer: VoiceTrainer
    /// Schließen; optional mit dem nächsten Level, das direkt starten soll
    let close: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(session.level.whisper ? "BONUS-LEVEL" : "LEVEL \(session.level.id)").font(VF.sans(11, .semibold)).tracking(1.2)
                            .foregroundStyle(session.level.whisper ? VF.purple : VF.muted)
                        DifficultyDots(n: session.level.difficulty)
                    }
                    Text(session.level.title).font(VF.serif(34)).foregroundStyle(VF.ink)
                }
                Spacer()
                SheetCloseButton { close(nil) }
            }
            Text(session.level.instruction).font(VF.sans(13.5)).foregroundStyle(VF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if session.level.takeCount > 1 {
                HStack(spacing: 8) {
                    TakeDots(done: session.phase == .processing || session.phase == .done ? session.level.takeCount : session.takeIndex,
                             total: session.level.takeCount, listening: session.phase == .recording)
                    Text(session.phase == .processing || session.phase == .done ? "\(session.level.takeCount) Sätze aufgenommen"
                         : "Satz \(min(session.takeIndex + 1, session.level.takeCount)) von \(session.level.takeCount)")
                        .font(VF.sans(12, .medium)).foregroundStyle(VF.muted)
                }
                .padding(.top, 14)
            }
            Text(session.level.takeCount > 1 ? session.currentText : session.level.text)
                .font(session.level.whisper ? VF.serif(28, italic: true) : VF.sans(17))
                .lineSpacing(5)
                .foregroundStyle(textActive ? VF.ink : VF.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VF.card, in: RoundedRectangle(cornerRadius: VF.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(session.phase == .recording ? VF.ink.opacity(0.25) : VF.hairline))
                .padding(.top, 18)

            bottom
                .frame(maxWidth: .infinity)
                .frame(minHeight: 130)
                .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 620)
        .background(VF.panel)
        .environment(\.colorScheme, .light)
    }

    private var textActive: Bool {
        switch session.phase { case .recording, .countdown, .ready: return true; default: return false }
    }

    @ViewBuilder private var bottom: some View {
        switch session.phase {
        case .ready:
            VStack(spacing: 10) {
                TrainingButton("Aufnahme starten", icon: "mic.fill", style: .primary, full: true) { session.start() }
                Text(session.level.takeCount > 1
                     ? "\(session.level.takeCount) kurze Sätze, je etwa \(Int(session.level.seconds)) Sekunden. Nach dem Countdown einfach loslegen."
                     : "Dauer etwa \(Int(session.level.seconds)) Sekunden. Nach dem Countdown einfach loslesen.")
                    .font(VF.sans(12)).foregroundStyle(VF.muted)
            }
        case .countdown(let n):
            VStack(spacing: 4) {
                if n == 0 {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(VF.teal1)
                    Text("Gut! Nächster Satz …").font(VF.sans(13.5, .medium)).foregroundStyle(VF.ink)
                } else {
                    Text("\(n)").font(VF.serif(64)).foregroundStyle(VF.ink).contentTransition(.numericText())
                    Text(session.level.whisper ? "Gleich geht's los – flüstern, nicht sprechen …" : "Gleich geht's los …").font(VF.sans(12.5)).foregroundStyle(VF.muted)
                }
            }
        case .recording:
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    TrainingMeter(levels: session.levels)
                    Spacer(minLength: 0)
                    Text("\(session.remaining) s").font(VF.serif(30)).monospacedDigit().foregroundStyle(VF.ink)
                }
                ProgressView(value: session.progress).tint(VF.ink)
                HStack {
                    TrainingButton("Abbrechen", style: .soft) { session.cancel() }
                    Spacer()
                    TrainingButton("Fertig", icon: "checkmark", style: .primary) { session.finish() }
                        .opacity(session.canFinishEarly ? 1 : 0.35)
                        .disabled(!session.canFinishEarly)
                }
            }
        case .processing:
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text(session.level.whisper ? "Flow lernt dein Flüstern …" : "Flow lernt deine Stimme …").font(VF.sans(13.5, .medium)).foregroundStyle(VF.ink)
                Text(session.level.whisper ? "Prüfen, ob wirklich geflüstert · Fingerabdruck · mit geflüsterten fremden Stimmen vergleichen"
                     : "Fingerabdruck berechnen, mit fremden Stimmen vergleichen").font(VF.sans(12)).foregroundStyle(VF.muted)
            }
        case .done:
            LevelDoneView(session: session, trainer: trainer, close: close)
        case .failed(let msg):
            SheetProblem(icon: "exclamationmark.triangle.fill", title: "Hat nicht geklappt", message: msg,
                         primary: ("Nochmal", { session.start() }), secondary: ("Schließen", { close(nil) }))
        case .micDenied:
            SheetProblem(icon: "mic.slash.fill", title: "Kein Zugriff aufs Mikrofon",
                         message: "Erlaube Flow in den Systemeinstellungen unter Datenschutz › Mikrofon den Zugriff und starte das Level dann nochmal.",
                         primary: ("Systemeinstellungen öffnen", { TrainingMic.openPrivacySettings() }), secondary: ("Schließen", { close(nil) }))
        }
    }
}

private struct LevelDoneView: View {
    @ObservedObject var session: LevelSession
    @ObservedObject var trainer: VoiceTrainer
    let close: (Int?) -> Void

    var body: some View {
        let k = session.result?.after ?? trainer.detail
        let delta = k.percent - (session.result?.before ?? k.percent)
        let next = session.level.id < VoiceLevel.all.count && !trainer.isDone(session.level.id + 1) ? session.level.id + 1 : nil
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                TrainingRing(value: Double(k.percent) / 100, lineWidth: 8) {
                    Text("\(k.percent)").font(VF.serif(30)).foregroundStyle(VF.ink)
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Label(session.level.whisper ? "Flüstern gelernt" : "Level \(session.level.id) geschafft", systemImage: "checkmark.circle.fill")
                        .font(VF.sans(14, .semibold)).foregroundStyle(VF.teal1)
                    Text("Flow kennt deine Stimme jetzt zu \(Text("\(k.percent) %").font(VF.serif(22, italic: true)))")
                        .font(VF.serif(22))
                        .foregroundStyle(VF.ink)
                    if delta > 0 {
                        Text("+\(delta) Prozentpunkte").font(VF.sans(12.5, .semibold)).foregroundStyle(VF.teal2)
                    }
                    if let r = session.result {
                        Text(String(format: "%.0f s Sprache · Aufnahme-Qualität %.0f %%", r.speechSeconds, Double(r.consistency) * 100))
                            .font(VF.sans(12)).foregroundStyle(VF.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                TrainingButton("Schließen", style: .soft) { close(nil) }
                Spacer()
                if let next { TrainingButton(next == VoiceLevel.whisperID ? "Weiter: Flüstern" : "Weiter zu Level \(next)", icon: "arrow.right", style: .primary) { close(next) } }
            }
        }
    }
}

// MARK: - Wort-Training-Blatt

struct WordTrainingSheet: View {
    @ObservedObject var session: WordSession
    let close: () -> Void
    @State private var testing: WordTestSession?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(testing == nil ? "WORT-TRAINING" : "TESTEN").font(VF.sans(11, .semibold)).tracking(1.2).foregroundStyle(VF.muted)
                Spacer()
                SheetCloseButton { testing?.cancel(); close() }
            }
            Group {
                if let t = testing {
                    WordTestPanel(session: t, done: { testing?.cancel(); testing = nil })
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 380)
        }
        .padding(28)
        .frame(width: 580)
        .background(VF.panel)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .intro:
            VStack(spacing: 14) {
                illustration
                Text(session.word).font(VF.serif(54)).foregroundStyle(VF.ink).lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 10) {
                    ModePicker(mode: $session.mode)
                    WhisperToggle(on: $session.whisper)
                }
                if session.whisper {
                    Label("Flüster-Wörter: dieselben Sätze leise flüstern, wie in der Bibliothek.", systemImage: "mouth")
                        .font(VF.sans(12.5, .medium)).foregroundStyle(VF.purple)
                }
                if session.mode == .sentences {
                    HStack(spacing: 6) {
                        Text("Das ist ein(e)").font(VF.sans(12.5)).foregroundStyle(VF.muted)
                        ForEach(NameKind.allCases) { k in
                            Button { session.setKind(k) } label: {
                                Text(k.label).font(VF.sans(12, .semibold))
                                    .foregroundStyle(session.kind == k ? Color.white : VF.ink)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(session.kind == k ? VF.ink : VF.buttonSoft, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("\(session.whisper ? "Flüstere" : "Lies") \(session.total) kurze Sätze\(session.whisper ? "," : " vor,") in denen „\(session.word)“ vorkommt – so, wie du sonst diktierst. Flow weiß, was du sagen wolltest, lernt daraus, wie du den Namen im Satz aussprichst, und prüft danach jeden Satz.")
                        .font(VF.sans(13)).foregroundStyle(VF.muted).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460)
                    if let first = session.sentences.first {
                        Text("Zum Beispiel: „\(first)“").font(VF.sans(12.5, .medium)).foregroundStyle(VF.ink.opacity(0.75))
                    }
                } else {
                    Text("Sag das Wort \(session.total)× – jedes Mal einzeln und so, wie du es beim Diktieren sagst. Im Satz trainieren wirkt stärker, weil Flow dann auch deine Aussprache mitten im Satz lernt.")
                        .font(VF.sans(13)).foregroundStyle(VF.muted).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460)
                }
                if let r = session.record {
                    Text("Zuletzt: vorher \(r.accuracyBefore)/\(r.total) · jetzt \(r.accuracyAfter)/\(r.total)")
                        .font(VF.sans(12)).foregroundStyle(VF.muted)
                }
                HStack(spacing: 10) {
                    if session.record != nil {
                        TrainingButton("Testen", icon: "waveform", style: .soft) { testing = WordTestSession(word: session.word, trainer: session.trainer) }
                    }
                    TrainingButton("Starten", icon: "mic.fill", style: .primary) { session.start() }
                }
                .padding(.top, 2)
            }
            .padding(.top, 4)
        case .listening, .heardNothing, .gotIt:
            VStack(spacing: 18) {
                Text(prompt).font(VF.sans(14, .semibold)).foregroundStyle(promptColor)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(promptColor.opacity(0.1), in: Capsule())
                if let sentence = session.currentSentence {
                    SentenceWithWord(sentence: sentence, word: session.word, size: 30)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500, minHeight: 90)
                } else {
                    Text(session.word).font(VF.serif(66)).foregroundStyle(VF.ink).lineLimit(1).minimumScaleFactor(0.5)
                }
                TakeDots(done: session.takeCount, total: session.total, listening: session.phase == .listening)
                TrainingMeter(levels: session.levels, active: session.phase == .listening)
                Text(session.mode == .sentences
                     ? "Satz \(min(session.takeCount + 1, session.total)) von \(session.total) · stoppt nach einer kurzen Pause"
                     : "Aufnahme \(min(session.takeCount + 1, session.total)) von \(session.total) · stoppt von selbst")
                    .font(VF.sans(12)).foregroundStyle(VF.muted)
                TrainingButton("Abbrechen", style: .soft) { session.cancel() }
            }
            .padding(.top, 18)
        case .processing(let step):
            VStack(spacing: 16) {
                Text(session.word).font(VF.serif(50)).foregroundStyle(VF.ink)
                TakeDots(done: session.total, total: session.total, listening: false)
                ProgressView().padding(.top, 8)
                Text(step).font(VF.sans(13.5, .medium)).foregroundStyle(VF.ink)
                Text("Whisper und Parakeet hören sich jede Aufnahme an. Danach wird jede mit dem geprüft, was aus den anderen gelernt wurde.")
                    .font(VF.sans(12)).foregroundStyle(VF.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .padding(.top, 34)
        case .result:
            if let r = session.record {
                WordResultView(record: r, retry: { session.start() }, test: { testing = WordTestSession(word: session.word, trainer: session.trainer) }, close: close)
            }
        case .failed(let msg):
            SheetProblem(icon: "exclamationmark.triangle.fill", title: "Hat nicht geklappt", message: msg,
                         primary: ("Nochmal", { session.start() }), secondary: ("Schließen", close))
                .padding(.top, 60)
        case .micDenied:
            SheetProblem(icon: "mic.slash.fill", title: "Kein Zugriff aufs Mikrofon",
                         message: "Erlaube Flow in den Systemeinstellungen unter Datenschutz › Mikrofon den Zugriff.",
                         primary: ("Systemeinstellungen öffnen", { TrainingMic.openPrivacySettings() }), secondary: ("Schließen", close))
                .padding(.top, 60)
        }
    }

    private var prompt: String {
        switch session.phase {
        case .heardNothing: return "Nichts gehört – nochmal"
        case .gotIt: return session.mode == .sentences ? "Gut! Nächster Satz …" : "Gut! Und nochmal …"
        default:
            if session.whisper { return session.mode == .sentences ? "Flüstere:" : "Flüstere: \(session.word)" }
            return session.mode == .sentences ? "Lies vor:" : "Sag: \(session.word)"
        }
    }

    private var promptColor: Color {
        switch session.phase {
        case .heardNothing: return Color(red: 0.72, green: 0.42, blue: 0.08)
        case .gotIt: return VF.teal1
        default: return VF.ink
        }
    }

    @ViewBuilder private var illustration: some View {
        if let img = VFAsset.image("illu_wort_gelernt") {
            Image(nsImage: img).resizable().scaledToFill().frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: VF.cardRadius))
        } else {
            Image(systemName: "character.bubble.fill").font(.system(size: 38)).foregroundStyle(VF.purple)
                .frame(width: 84, height: 84).background(VF.purple.opacity(0.12), in: Circle())
        }
    }
}

/// Schalter „Geflüstert“ fürs Wort-Training
struct WhisperToggle: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "mouth").font(.system(size: 11, weight: .semibold))
                Text("Geflüstert").font(VF.sans(12.5, .semibold))
            }
            .foregroundStyle(on ? Color.white : VF.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? VF.purple : VF.buttonSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Dasselbe Training geflüstert – eigenes Ergebnis")
    }
}

/// „Im Satz trainieren“ | „Nur das Wort“
private struct ModePicker: View {
    @Binding var mode: WordTrainer.Mode
    var body: some View {
        HStack(spacing: 2) {
            item("Im Satz trainieren", .sentences)
            item("Nur das Wort", .word)
        }
        .padding(3)
        .background(VF.buttonSoft, in: Capsule())
    }
    private func item(_ title: String, _ m: WordTrainer.Mode) -> some View {
        Button { mode = m } label: {
            Text(title).font(VF.sans(12.5, .semibold))
                .foregroundStyle(mode == m ? VF.ink : VF.muted)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(mode == m ? VF.card : Color.clear, in: Capsule())
                .shadow(color: mode == m ? Color.black.opacity(0.06) : .clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// Satz mit hervorgehobenem Wort (kursiv, lila unterstrichen)
struct SentenceWithWord: View {
    let sentence: String
    let word: String
    var size: CGFloat = 28
    var body: some View {
        var t = Text("")
        var rest = Substring(sentence)
        while let r = rest.range(of: word, options: [.caseInsensitive]) {
            t = t + Text(String(rest[..<r.lowerBound])).font(VF.serif(size)).foregroundColor(VF.ink)
            t = t + Text(String(rest[r])).font(VF.serif(size, italic: true)).foregroundColor(VF.purple).underline(true, color: VF.purple.opacity(0.5))
            rest = rest[r.upperBound...]
        }
        t = t + Text(String(rest)).font(VF.serif(size)).foregroundColor(VF.ink)
        return t.fixedSize(horizontal: false, vertical: true)
    }
}

struct WordResultView: View {
    let record: WordTrainer.Record
    let retry: () -> Void
    var test: (() -> Void)? = nil
    let close: () -> Void

    private var sentences: Bool { record.mode == .sentences }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.word).font(VF.serif(44)).foregroundStyle(VF.ink)
                Text([record.kind?.label, record.language == "en" ? "Englisch" : "Deutsch"].compactMap { $0 }.joined(separator: " · "))
                    .font(VF.sans(12, .medium)).foregroundStyle(VF.muted)
            }
            HStack(spacing: 12) {
                ScoreBox(title: "Vorher", value: record.accuracyBefore, total: record.total, highlight: false,
                         caption: sentences ? "Sätze richtig" : "richtig erkannt")
                Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(VF.muted)
                ScoreBox(title: "Jetzt", value: record.accuracyAfter, total: record.total, highlight: true,
                         caption: sentences ? "Sätze richtig" : "richtig erkannt")
            }
            Text("Ehrlich gemessen: jede Aufnahme wurde nur mit dem geprüft, was Flow aus den anderen gelernt hat.")
                .font(VF.sans(11.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                TrainingSectionLabel("So schreibt Flow jetzt")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(record.takes.enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: t.okAfter ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(t.okAfter ? VF.teal1 : Color(red: 0.8, green: 0.25, blue: 0.2))
                            Text(t.after.isEmpty ? "(nichts erkannt)" : t.after).font(VF.sans(12.5)).foregroundStyle(VF.ink).lineLimit(1)
                            if !t.okBefore && t.okAfter, !t.before.isEmpty {
                                Text("vorher: \(t.before)").font(VF.sans(11)).foregroundStyle(VF.muted).strikethrough(color: VF.muted.opacity(0.5)).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VF.card, in: RoundedRectangle(cornerRadius: VF.cardRadius))
            }
            VStack(alignment: .leading, spacing: 8) {
                TrainingSectionLabel("So hört sich „\(record.word)“ bei dir an")
                if record.variants.isEmpty {
                    Text("Nichts Neues – Flow hat „\(record.word)“ schon jedes Mal richtig gehört.")
                        .font(VF.sans(13)).foregroundStyle(VF.muted)
                } else {
                    TrainingFlow(spacing: 6) {
                        ForEach(record.variants.prefix(10), id: \.self) { v in
                            HStack(spacing: 5) {
                                Text(v).foregroundStyle(VF.muted).strikethrough(color: VF.muted.opacity(0.6))
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(VF.muted)
                                Text(record.word).foregroundStyle(VF.ink)
                                if record.learned.contains(v) {
                                    Text("Regel").font(VF.sans(10, .semibold)).foregroundStyle(VF.teal1)
                                        .padding(.horizontal, 5).padding(.vertical, 1).background(VF.teal4, in: Capsule())
                                }
                            }
                            .font(VF.sans(12.5, .medium))
                            .fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(VF.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(VF.hairline))
                        }
                    }
                }
                Text("Echte Wörter wie „Shark“ werden nie blind ersetzt: nur wenn die Stelle unsicher klingt UND Whisper mit dem Namen als Hinweis bestätigt\(record.acousticReady == true ? " oder dein Klang passt" : ""). „Regel“ = Kunstwort, wird direkt ersetzt.")
                    .font(VF.sans(11.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                TrainingButton("Nochmal üben", icon: "arrow.counterclockwise", style: .soft, action: retry)
                if let test { TrainingButton("Testen", icon: "waveform", style: .soft, action: test) }
                Spacer()
                TrainingButton("Fertig", style: .primary, action: close)
            }
        }
        .padding(.top, 8)
    }
}

/// Testen: einen freien Satz mit dem Wort sagen → Ergebnis mit ✓/✗
struct WordTestPanel: View {
    @ObservedObject var session: WordTestSession
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch session.phase {
            case .ready:
                Text(session.word).font(VF.serif(50)).foregroundStyle(VF.ink)
                Text("Sag einen beliebigen Satz mit „\(session.word)“ – so, wie du ihn diktieren würdest. Flow zeigt dir, was es schreibt.")
                    .font(VF.sans(13)).foregroundStyle(VF.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
                HStack(spacing: 10) {
                    TrainingButton("Zurück", style: .soft, action: done)
                    TrainingButton("Aufnehmen", icon: "mic.fill", style: .primary) { session.start() }
                }
            case .listening:
                Text("Ich höre zu …").font(VF.sans(14, .semibold)).foregroundStyle(VF.ink)
                    .padding(.horizontal, 12).padding(.vertical, 5).background(VF.ink.opacity(0.08), in: Capsule())
                Text(session.word).font(VF.serif(50)).foregroundStyle(VF.ink)
                TrainingMeter(levels: session.levels)
                Text("stoppt nach einer kurzen Pause").font(VF.sans(12)).foregroundStyle(VF.muted)
                HStack(spacing: 10) {
                    TrainingButton("Abbrechen", style: .soft) { session.cancel() }
                    TrainingButton("Fertig", icon: "checkmark", style: .primary) { session.finish() }
                }
            case .processing:
                ProgressView().padding(.top, 30)
                Text("Flow schreibt …").font(VF.sans(13.5, .medium)).foregroundStyle(VF.ink)
            case .result(let r):
                WordTestResultCard(result: r, word: session.word)
                HStack(spacing: 10) {
                    TrainingButton("Nochmal testen", icon: "arrow.counterclockwise", style: .soft) { session.start() }
                    TrainingButton("Fertig", style: .primary, action: done)
                }
            case .failed(let m):
                SheetProblem(icon: "exclamationmark.triangle.fill", title: "Hat nicht geklappt", message: m,
                             primary: ("Nochmal", { session.start() }), secondary: ("Zurück", done))
            case .micDenied:
                SheetProblem(icon: "mic.slash.fill", title: "Kein Zugriff aufs Mikrofon",
                             message: "Erlaube Flow in den Systemeinstellungen unter Datenschutz › Mikrofon den Zugriff.",
                             primary: ("Systemeinstellungen öffnen", { TrainingMic.openPrivacySettings() }), secondary: ("Zurück", done))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

struct WordTestResultCard: View {
    let result: WordTrainer.TestResult
    let word: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 40)).foregroundStyle(result.ok ? VF.teal1 : Color(red: 0.8, green: 0.25, blue: 0.2))
            Text(result.ok ? "Richtig geschrieben" : "„\(word)“ nicht erkannt").font(VF.sans(15, .semibold)).foregroundStyle(VF.ink)
            Text("„\(result.text.isEmpty ? "…" : result.text)“")
                .font(VF.serif(24)).foregroundStyle(VF.ink).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460)
            Text(result.ok
                 ? (result.engine.contains("namen") ? "Der Namen-Prüfer hat die Stelle erkannt und bestätigen lassen." : "Direkt richtig erkannt.")
                 : "Trainiere „\(word)“ nochmal im Satz – je mehr echte Sätze, desto sicherer.")
                .font(VF.sans(12)).foregroundStyle(VF.muted).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(result.ok ? VF.teal4.opacity(0.6) : VF.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: VF.cardRadius))
    }
}

private struct ScoreBox: View {
    let title: String
    let value: Int
    let total: Int
    let highlight: Bool
    var caption = "richtig erkannt"
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(VF.sans(10.5, .semibold)).tracking(1.1).foregroundStyle(VF.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)").font(VF.serif(44)).foregroundStyle(highlight ? VF.teal1 : VF.ink)
                Text("/\(total)").font(VF.serif(24)).foregroundStyle(VF.muted)
            }
            Text(caption).font(VF.sans(11.5)).foregroundStyle(VF.muted)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? VF.teal4 : VF.cardSoft, in: RoundedRectangle(cornerRadius: VF.cardRadius))
    }
}

struct TakeDots: View {
    let done: Int
    let total: Int
    let listening: Bool
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<total, id: \.self) { i in
                ZStack {
                    Circle().stroke(i < done ? VF.ink : VF.hairline, lineWidth: 1.5)
                    if i < done { Circle().fill(VF.ink).padding(3) }
                    if i == done && listening {
                        Circle().fill(Color.red.opacity(pulse ? 0.85 : 0.35)).padding(4)
                    }
                }
                .frame(width: 18, height: 18)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { pulse = true } }
    }
}

struct SheetCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(VF.muted)
                .frame(width: 28, height: 28).background(VF.buttonSoft, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }
}

struct SheetProblem: View {
    let icon: String
    let title: String
    let message: String
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(VF.orange)
            Text(title).font(VF.sans(15, .semibold)).foregroundStyle(VF.ink)
            Text(message).font(VF.sans(13)).foregroundStyle(VF.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
            HStack(spacing: 10) {
                TrainingButton(secondary.0, style: .soft, action: secondary.1)
                TrainingButton(primary.0, style: .primary, action: primary.1)
            }
            .padding(.top, 4)
        }
    }
}

/// Einfaches Umbruch-Layout für Chips
struct TrainingFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            w = max(w, x - spacing)
        }
        return CGSize(width: min(maxW, w), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}


// MARK: - Andere Stimme einlernen

struct OtherVoiceSheet: View {
    @ObservedObject var session: OtherVoiceSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ANDERE STIMME").font(VF.sans(11, .semibold)).tracking(1.2).foregroundStyle(VF.muted)
                    Text("\(session.name.isEmpty ? "Jemand anderes" : session.name) liest vor").font(VF.serif(34)).foregroundStyle(VF.ink)
                }
                Spacer()
                SheetCloseButton { close() }
            }
            Text("Gib das MacBook kurz \(Identity.partner(.dative)) – oder wer sonst oft neben dir redet. Die Person liest 30 Sekunden vor. Gespeichert werden nur Stimm-Fingerabdrücke, keine Aufnahme. Danach schreibt Flow diese Stimme nicht mehr mit, auch wenn sie ähnlich klingt wie deine.")
                .font(VF.sans(13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if session.phase == .ready {
                HStack(spacing: 10) {
                    Text("Name").font(VF.sans(12.5, .semibold)).foregroundStyle(VF.muted)
                    TextField("z. B. \(Identity.partner(.nominative, capitalized: true))", text: $session.name)
                        .textFieldStyle(.plain).font(VF.sans(13.5))
                        .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 220)
                        .background(VF.card, in: RoundedRectangle(cornerRadius: VF.buttonRadius))
                        .overlay(RoundedRectangle(cornerRadius: VF.buttonRadius).stroke(VF.hairline))
                }
                .padding(.top, 14)
            }
            Text(OtherVoiceSession.text)
                .font(VF.sans(16)).lineSpacing(5)
                .foregroundStyle(session.phase == .recording || session.phase == .ready ? VF.ink : VF.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(VF.card, in: RoundedRectangle(cornerRadius: VF.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(session.phase == .recording ? VF.ink.opacity(0.25) : VF.hairline))
                .padding(.top, 16)
            bottom.frame(maxWidth: .infinity).frame(minHeight: 120).padding(.top, 18)
        }
        .padding(28)
        .frame(width: 620)
        .background(VF.panel)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var bottom: some View {
        switch session.phase {
        case .ready:
            VStack(spacing: 10) {
                TrainingButton("Aufnahme starten", icon: "mic.fill", style: .primary, full: true) { session.start() }
                Text("Etwa 30 Sekunden. Du selbst sagst dabei nichts.").font(VF.sans(12)).foregroundStyle(VF.muted)
            }
        case .countdown(let n):
            VStack(spacing: 4) {
                Text("\(n)").font(VF.serif(64)).foregroundStyle(VF.ink)
                Text("Gleich geht's los …").font(VF.sans(12.5)).foregroundStyle(VF.muted)
            }
        case .recording:
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    TrainingMeter(levels: session.levels)
                    Spacer(minLength: 0)
                    Text("\(session.remaining) s").font(VF.serif(30)).monospacedDigit().foregroundStyle(VF.ink)
                }
                ProgressView(value: session.progress).tint(VF.ink)
                HStack {
                    TrainingButton("Abbrechen", style: .soft) { session.cancel() }
                    Spacer()
                    TrainingButton("Fertig", icon: "checkmark", style: .primary) { session.finish() }
                        .opacity(session.canFinishEarly ? 1 : 0.35).disabled(!session.canFinishEarly)
                }
            }
        case .processing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Fingerabdrücke berechnen …").font(VF.sans(13.5, .medium)).foregroundStyle(VF.ink)
            }
        case .done(let name):
            VStack(spacing: 12) {
                Label("\(name) eingelernt", systemImage: "checkmark.circle.fill").font(VF.sans(15, .semibold)).foregroundStyle(VF.teal1)
                Text("Diese Stimme gilt ab jetzt nicht mehr als deine – auch wenn sie ähnlich klingt.").font(VF.sans(12.5)).foregroundStyle(VF.muted)
                TrainingButton("Fertig", style: .primary) { close() }
            }
        case .failed(let msg):
            SheetProblem(icon: "exclamationmark.triangle.fill", title: "Hat nicht geklappt", message: msg,
                         primary: ("Nochmal", { session.start() }), secondary: ("Schließen", { close() }))
        case .micDenied:
            SheetProblem(icon: "mic.slash.fill", title: "Kein Zugriff aufs Mikrofon",
                         message: "Erlaube Flow in den Systemeinstellungen unter Datenschutz › Mikrofon den Zugriff.",
                         primary: ("Systemeinstellungen öffnen", { TrainingMic.openPrivacySettings() }), secondary: ("Schließen", { close() }))
        }
    }
}
