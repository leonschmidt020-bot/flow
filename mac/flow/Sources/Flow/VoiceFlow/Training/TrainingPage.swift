import AppKit
import SwiftUI

// MARK: - Flow · Seite „Training“ (Stimm-Level + Wort-Training)

struct VFTrainingPage: View {
    @ObservedObject var voice: VoiceTrainer
    @ObservedObject var words: WordTrainer
    @State private var levelSession: LevelSession?
    @State private var wordSession: WordSession?
    @State private var testSession: WordTestSession?
    @State private var candidates: [WordTrainer.Candidate] = []
    @State private var stats: [String: WordTrainer.DictationStats] = [:]
    @State private var upgrading: String?
    @State private var newWord = ""
    @State private var adding = false
    @State private var otherSession: OtherVoiceSession?
    @State private var printMessage: String?

    init(voice: VoiceTrainer = .shared, words: WordTrainer = .shared) {
        self.voice = voice
        self.words = words
        let c = words.candidates()
        _candidates = State(initialValue: c)
        _stats = State(initialValue: words.dictationStats(for: c.map(\.word)))
    }

    private func reload() {
        candidates = words.candidates()
        stats = words.dictationStats(for: candidates.map(\.word))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 26)
                TrainingKnowledgeCard(k: voice.detail, preparing: voice.preparingImpostors, rollback: { voice.rollback() })
                    .padding(.bottom, 40)
                levelSection
                    .padding(.bottom, 40)
                otherVoicesSection
                    .padding(.bottom, 40)
                wordSection
            }
            .frame(maxWidth: VF.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .background(VF.panel)
        .onAppear {
            voice.refresh()
            reload()
            if voice.store.impostors.isEmpty, voice.levelsDone > 0 { Task { try? await voice.prepareImpostors() } }
            // Alte Wort-Trainings (vor dem Namen-Prüfer) einmal mit den gespeicherten Aufnahmen neu messen
            if upgrading == nil, words.store.words.values.contains(where: { $0.mode == nil && $0.remeasured != true }) {
                upgrading = ""
                Task {
                    await words.upgradeOldRecords { w in DispatchQueue.main.async { upgrading = w } }
                    await MainActor.run { upgrading = nil; reload() }
                }
            }
        }
        .onReceive(words.$store) { _ in DispatchQueue.main.async { reload() } }
        .sheet(item: $levelSession, onDismiss: { voice.refresh() }) { s in
            LevelRecordingSheet(session: s, trainer: voice) { next in
                s.cancel()
                levelSession = nil
                if let next, let lv = VoiceLevel.level(next) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { levelSession = LevelSession(level: lv, trainer: voice) }
                }
            }
        }
        .sheet(item: $otherSession, onDismiss: { voice.refresh() }) { s in
            OtherVoiceSheet(session: s) { s.cancel(); otherSession = nil }
        }
        .sheet(item: $wordSession, onDismiss: { reload() }) { s in
            WordTrainingSheet(session: s) { s.cancel(); wordSession = nil }
        }
        .sheet(item: $testSession, onDismiss: { reload() }) { t in
            VStack(spacing: 0) {
                HStack {
                    Text("TESTEN").font(VF.sans(11, .semibold)).tracking(1.2).foregroundStyle(VF.muted)
                    Spacer()
                    SheetCloseButton { t.cancel(); testSession = nil }
                }
                WordTestPanel(session: t) { t.cancel(); testSession = nil }.frame(minHeight: 320)
            }
            .padding(28).frame(width: 560).background(VF.panel).environment(\.colorScheme, .light)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Training").font(VF.pageTitle).foregroundStyle(VF.ink)
            Text("Bring Flow deine Stimme und deine Wörter bei – alles bleibt auf deinem Mac.")
                .font(VF.sans(14)).foregroundStyle(VF.muted)
        }
    }

    // MARK: Stimm-Level

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                TrainingSectionLabel("Stimm-Level")
                Spacer()
                Text("\(voice.levelsDone) von 5 geschafft" + (voice.whisperDone ? " · Flüstern ✓" : ""))
                    .font(VF.sans(12.5, .medium)).foregroundStyle(VF.muted)
            }
            Text("Jedes Level zeigt Flow eine andere Seite deiner Stimme. Je mehr Level, desto sicherer erkennt es dich – auch leise, schnell, mit Musik im Hintergrund oder geflüstert.")
                .font(VF.sans(13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), alignment: .leading, spacing: 12) {
                ForEach(VoiceLevel.all) { lv in
                    LevelCard(level: lv, done: voice.isDone(lv.id), unlocked: voice.isUnlocked(lv.id),
                              consistency: voice.data(lv.id)?.consistency) {
                        levelSession = LevelSession(level: lv, trainer: voice)
                    }
                }
            }
        }
    }

    // MARK: Wort-Training

    private var wordSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                TrainingSectionLabel("Wort-Training")
                Spacer()
                if adding {
                    HStack(spacing: 8) {
                        TextField("Wort oder Name", text: $newWord)
                            .textFieldStyle(.plain)
                            .font(VF.sans(13.5))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(width: 200)
                            .background(VF.card, in: RoundedRectangle(cornerRadius: VF.buttonRadius))
                            .overlay(RoundedRectangle(cornerRadius: VF.buttonRadius).stroke(VF.hairline))
                            .onSubmit(addWord)
                        TrainingButton("Hinzufügen", style: .primary, action: addWord)
                        TrainingButton("Abbrechen", style: .soft) { adding = false; newWord = "" }
                    }
                } else {
                    TrainingButton("Wort hinzufügen", icon: "plus", style: .soft) { adding = true }
                }
            }
            Text("Namen und Wörter, die du oft korrigierst: Lies 6 kurze Sätze damit vor – Flow lernt, wie du sie im Satz aussprichst, und zeigt dir ehrlich gemessen, wie oft es sie jetzt richtig schreibt. Mit „Geflüstert“ übst du dieselben Sätze leise.")
                .font(VF.sans(13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            if candidates.isEmpty {
                TrainingEmptyWords()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Rectangle().fill(VF.hairline).frame(height: 1) }
                        WordRow(c: c, stats: stats[c.word], whisperRecord: words.whisperRecord(c.word), remeasuring: upgrading == c.word,
                                onTrain: { wordSession = WordSession(word: c.word, trainer: words) },
                                onTest: c.record == nil ? nil : { testSession = WordTestSession(word: c.word, trainer: words) },
                                onRemove: c.manual && c.record == nil ? { words.removeManual(c.word) } : nil)
                    }
                }
                .background(VF.card, in: RoundedRectangle(cornerRadius: VF.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
            }
        }
    }

    // MARK: Andere Stimmen

    private var otherVoicesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                TrainingSectionLabel("Andere Stimmen")
                Spacer()
                TrainingButton("Stimmabdruck importieren", icon: "square.and.arrow.down", style: .soft, action: importPrint)
                TrainingButton("Meinen exportieren", icon: "square.and.arrow.up", style: .soft, action: exportPrint)
                    .opacity(voice.levelsDone > 0 ? 1 : 0.4).disabled(voice.levelsDone == 0)
            }
            Text("Klingt jemand ähnlich wie du – zum Beispiel \(Identity.partner(.nominative))? Lass die Person 30 Sekunden vorlesen oder importiere ihren Stimmabdruck. Flow nimmt dann nur noch Stellen, die klar näher an dir sind als an ihr. Gespeichert werden nur Fingerabdrücke, kein Ton.")
                .font(VF.sans(13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(voice.store.negatives.enumerated()), id: \.element.id) { i, n in
                    if i > 0 { Rectangle().fill(VF.hairline).frame(height: 1) }
                    OtherVoiceRow(voice: n) { voice.removeNegative(n.id) }
                }
                if !voice.store.negatives.isEmpty { Rectangle().fill(VF.hairline).frame(height: 1) }
                HStack(spacing: 14) {
                    Image(systemName: "person.2.wave.2").font(.system(size: 20)).foregroundStyle(VF.ink).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Andere Stimme einlernen (z. B. \(Identity.partner(.accusative)))").font(VF.sans(14.5, .semibold)).foregroundStyle(VF.ink)
                        Text("30 Sekunden vorlesen lassen · nur Fingerabdrücke").font(VF.sans(12)).foregroundStyle(VF.muted)
                    }
                    Spacer()
                    TrainingButton("Einlernen", icon: "mic.fill", style: voice.store.negatives.isEmpty ? .primary : .soft) {
                        otherSession = OtherVoiceSession(name: Identity.partnerName ?? "")
                    }
                    .opacity(voice.levelsDone > 0 ? 1 : 0.4).disabled(voice.levelsDone == 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
            .background(VF.card, in: RoundedRectangle(cornerRadius: VF.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
            if let m = printMessage { Text(m).font(VF.sans(12.5, .medium)).foregroundStyle(VF.muted) }
        }
    }

    private func exportPrint() {
        guard let d = voice.exportVoiceprint(name: Identity.myName) else { printMessage = "Erst Level 1 schaffen – dann gibt es einen Stimmabdruck."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Stimmabdruck \(Identity.myName).\(VoiceTrainer.voiceprintExtension)"
        panel.message = "Nur Fingerabdrücke (Zahlen), kein Ton. \(Identity.partner(.nominative, capitalized: true)) importiert die Datei unter „Andere Stimmen“."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            printMessage = "Stimmabdruck gespeichert: \(url.lastPathComponent)"
        } catch { printMessage = "Nicht gespeichert: \(error.localizedDescription)" }
    }

    private func importPrint() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Stimmabdruck (.\(VoiceTrainer.voiceprintExtension)) einer anderen Person wählen"
        guard panel.runModal() == .OK, let url = panel.url, let d = try? Data(contentsOf: url) else { return }
        Task {
            do {
                let n = try await voice.importVoiceprint(d)
                await MainActor.run { printMessage = "„\(n.name)“ importiert – diese Stimme gilt nicht mehr als deine." }
            } catch { await MainActor.run { printMessage = error.localizedDescription } }
        }
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        words.addManual(w)
        newWord = ""
        adding = false
        reload()
    }
}

// MARK: - Kenntnis-Karte

struct TrainingKnowledgeCard: View {
    let k: VoiceKnowledge
    var preparing = false
    var rollback: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 34) {
            TrainingRing(value: Double(k.percent) / 100, lineWidth: 12) {
                VStack(spacing: 0) {
                    Text("\(k.percent)").font(VF.serif(54)).foregroundStyle(VF.ink)
                    Text("Prozent").font(VF.sans(11, .semibold)).tracking(1.1).foregroundStyle(VF.muted).textCase(.uppercase)
                }
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 14) {
                Text("Flow kennt deine Stimme zu \(Text("\(k.percent) %").font(VF.serif(34, italic: true)))")
                    .font(VF.serif(34))
                    .foregroundStyle(VF.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(VF.sans(13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    BreakdownRow(title: "Stimm-Level", detail: "\(k.levelsDone) von 5 Level", value: k.levelPoints, max: 40, color: VF.teal1)
                    BreakdownRow(title: "Trennschärfe", detail: separationDetail, value: k.separationPoints, max: 30, color: VF.teal2)
                    BreakdownRow(title: "Flüstern", detail: whisperDetail, value: k.whisperPoints, max: 15, color: VF.purple)
                    BreakdownRow(title: "Aus Diktaten gelernt", detail: adaptiveDetail, value: k.adaptivePoints, max: 10, color: VF.teal3)
                    BreakdownRow(title: "Andere Stimmen", detail: k.negativeNames.isEmpty ? "noch keine eingelernt" : k.negativeNames.joined(separator: ", "),
                                 value: k.negativePoints, max: 5, color: VF.beige)
                    if k.canRollback, let rollback {
                        Button(action: rollback) {
                            Label("Letzte Anpassung aus Diktaten zurücknehmen", systemImage: "arrow.uturn.backward")
                                .font(VF.sans(11.5, .medium)).foregroundStyle(VF.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let img = VFAsset.image("illu_stimme") {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: VF.cardRadius))
            }
        }
        .padding(28)
        .background(VF.card, in: RoundedRectangle(cornerRadius: VF.bannerRadius))
        .overlay(RoundedRectangle(cornerRadius: VF.bannerRadius).stroke(VF.hairline))
    }

    private var subtitle: String {
        if k.levelsDone == 0 {
            return k.legacyProfile
                ? "Dein bisheriges Stimmprofil bleibt aktiv. Starte Level 1, damit Flow messen kann, wie gut es dich kennt."
                : "Noch kein Stimmprofil. Starte mit Level 1 – dauert keine 20 Sekunden."
        }
        if k.percent >= 90 { return "Flow erkennt dich sicher – auch leise, schnell, geflüstert und mit Geräuschen im Hintergrund." }
        return "Gemessen, nicht geschätzt: geschaffte Level, wie klar sich deine Stimme von fremden Stimmen abhebt, und was Flow aus deinen Diktaten gelernt hat."
    }

    private var separationDetail: String {
        if preparing { return "wird gemessen …" }
        guard let j = k.ownMean, let i = k.impostorMax else { return k.levelsDone == 0 ? "nach Level 1" : "wird gemessen …" }
        return String(format: "Abstand zu fremden Stimmen %.2f", j - i).replacingOccurrences(of: ".", with: ",")
    }

    private var whisperDetail: String {
        guard k.whisperDone else { return "Level Flüstern noch offen" }
        guard let j = k.whisperOwnMean, let i = k.whisperImpostorMax else { return preparing ? "wird gemessen …" : "gelernt" }
        return String(format: "gelernt · Abstand %.2f", j - i).replacingOccurrences(of: ".", with: ",")
    }

    private var adaptiveDetail: String {
        k.adaptivePool > 0 ? "\(k.adaptiveSamples) sichere Diktate · \(k.adaptivePool) Stellen im Modell" : "\(k.adaptiveSamples) sichere Diktate"
    }
}

private struct BreakdownRow: View {
    let title: String
    let detail: String
    let value: Int
    let max: Int
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(VF.sans(13, .semibold)).foregroundStyle(VF.ink)
                Text(detail).font(VF.sans(11.5)).foregroundStyle(VF.muted).lineLimit(1)
            }
            .frame(width: 230, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(VF.cardSoft)
                    Capsule().fill(color).frame(width: g.size.width * CGFloat(value) / CGFloat(Swift.max(max, 1)))
                }
            }
            .frame(height: 8)
            Text("\(value) / \(max)").font(VF.sans(12.5, .medium)).monospacedDigit().foregroundStyle(VF.muted)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

// MARK: - Level-Karte

private struct LevelCard: View {
    let level: VoiceLevel
    let done: Bool
    let unlocked: Bool
    let consistency: Float?
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(level.whisper ? "BONUS · FLÜSTERN" : "LEVEL \(level.id)").font(VF.sans(11, .semibold)).tracking(1.1)
                    .foregroundStyle(level.whisper ? VF.purple : VF.muted)
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(VF.teal2)
                } else if !unlocked {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(VF.beige)
                }
            }
            Image(systemName: level.symbol).font(.system(size: 20, weight: .regular))
                .foregroundStyle(unlocked ? VF.ink : VF.beige)
                .frame(height: 26)
            Text(level.title).font(VF.sans(15, .semibold)).foregroundStyle(unlocked ? VF.ink : VF.muted)
            DifficultyDots(n: level.difficulty)
            Text(level.short).font(VF.sans(12.5)).foregroundStyle(VF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Spacer(minLength: 0)
            if done {
                TrainingButton("Nochmal", style: .soft, full: true, action: start)
            } else if unlocked {
                TrainingButton("Starten", style: .primary, full: true, action: start)
            } else {
                Text(level.whisper ? "Erst Level 1" : "Erst Level \(level.id - 1)").font(VF.sans(12.5, .medium)).foregroundStyle(VF.beige)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(VF.cardSoft, in: RoundedRectangle(cornerRadius: VF.buttonRadius))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 214, alignment: .topLeading)
        .background(done ? VF.teal4.opacity(0.55) : (unlocked ? VF.card : VF.cardSoft.opacity(0.6)),
                    in: RoundedRectangle(cornerRadius: VF.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(done ? VF.teal3.opacity(0.6) : VF.hairline))
    }
}

struct DifficultyDots: View {
    let n: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= n ? VF.ink.opacity(0.75) : VF.hairline).frame(width: 6, height: 6)
            }
            Text(["", "leicht", "leicht", "mittel", "schwer", "schwer"][n]).font(VF.sans(11)).foregroundStyle(VF.muted).padding(.leading, 4)
        }
    }
}

// MARK: - Wort-Zeile

private struct WordRow: View {
    let c: WordTrainer.Candidate
    var stats: WordTrainer.DictationStats?
    var whisperRecord: WordTrainer.Record? = nil
    var remeasuring = false
    let onTrain: () -> Void
    var onTest: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(c.word).font(VF.sans(15, .medium)).foregroundStyle(VF.ink)
                    if c.learnedFromEdits { Text("✨").font(.system(size: 12)) }
                }
                if let line = statsLine {
                    Text(line).font(VF.sans(11.5)).foregroundStyle(VF.muted).lineLimit(1)
                }
            }
            .frame(minWidth: 170, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(c.reasons.prefix(2), id: \.self) { r in ReasonChip(text: r, corrections: r.contains("korrigiert") ? c.corrections : 0) }
            }
            Spacer(minLength: 8)
            if remeasuring {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("wird neu gemessen …").font(VF.sans(12)).foregroundStyle(VF.muted) }
            } else {
                if let w = whisperRecord {
                    HStack(spacing: 3) {
                        Image(systemName: "mouth").font(.system(size: 10, weight: .semibold))
                        Text("\(w.accuracyAfter)/\(w.total)")
                    }
                    .font(VF.sans(12, .semibold)).monospacedDigit().foregroundStyle(VF.purple)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(VF.purple.opacity(0.1), in: Capsule())
                    .help("Geflüstert: Sätze richtig nach dem Flüster-Training")
                }
                AccuracyBadge(record: c.record)
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.muted) }
                    .buttonStyle(.plain).help("Entfernen")
            }
            if let onTest {
                TrainingButton("Testen", icon: "waveform", style: .soft, action: onTest).frame(width: 96)
            }
            TrainingButton(c.record == nil ? "Trainieren" : "Nochmal", style: c.record == nil ? .primary : .soft, action: onTrain)
                .frame(width: 104)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// „in deinen Diktaten: 7× richtig, 1× korrigiert“ (+ letzter Test)
    private var statsLine: String? {
        var parts: [String] = []
        if let s = stats, s.correct + s.corrected > 0 {
            parts.append("in deinen Diktaten: \(s.correct)× richtig, \(s.corrected)× korrigiert")
        }
        if let t = c.record?.lastTest { parts.append("Test: \(t.ok ? "✓" : "✗")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ReasonChip: View {
    let text: String
    var corrections = 0
    var body: some View {
        let label = corrections > 1 ? "\(text) · \(corrections)×" : text
        Text(label)
            .font(VF.sans(11.5, .medium))
            .foregroundStyle(text == "unsicher erkannt" ? Color(red: 0.62, green: 0.38, blue: 0.1) : VF.muted)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(text == "unsicher erkannt" ? VF.orange.opacity(0.18) : VF.buttonSoft, in: Capsule())
    }
}

struct AccuracyBadge: View {
    let record: WordTrainer.Record?
    var body: some View {
        if let r = record {
            let good = r.accuracyAfter * 6 >= r.total * 5
            HStack(spacing: 4) {
                Text("vorher \(r.accuracyBefore)/\(r.total)").foregroundStyle(VF.muted)
                Text("·").foregroundStyle(VF.muted)
                Text("jetzt \(r.accuracyAfter)/\(r.total)").foregroundStyle(good ? VF.teal1 : Color(red: 0.62, green: 0.38, blue: 0.1))
            }
            .font(VF.sans(12.5, .semibold)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(good ? VF.teal4 : VF.orange.opacity(0.16), in: Capsule())
            .help(r.mode == .sentences ? "Sätze richtig geschrieben – vor dem Training und jetzt" : "Richtig erkannt – vor dem Training und jetzt")
        } else {
            Text("noch nicht trainiert").font(VF.sans(12)).foregroundStyle(VF.beige)
        }
    }
}

private struct TrainingEmptyWords: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "character.bubble").font(.system(size: 26)).foregroundStyle(VF.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text("Noch keine Wörter zum Üben").font(VF.sans(14, .semibold)).foregroundStyle(VF.ink)
                Text("Sobald du Namen korrigierst oder etwas ins Wörterbuch schreibst, taucht es hier auf. Oder füge oben selbst ein Wort hinzu.")
                    .font(VF.sans(12.5)).foregroundStyle(VF.muted)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VF.card, in: RoundedRectangle(cornerRadius: VF.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
    }
}

// MARK: - Bausteine

struct TrainingSectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(VF.sectionLabel).tracking(1.2).foregroundStyle(VF.muted)
    }
}

struct TrainingRing<Content: View>: View {
    let value: Double
    var lineWidth: CGFloat = 10
    var track: Color = VF.cardSoft
    var tint: Color = VF.teal1
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if value > 0.005 {
                Circle().trim(from: 0, to: min(1, value))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            content()
        }
        .padding(lineWidth / 2)
    }
}

struct TrainingButton: View {
    enum Style { case primary, soft }
    let title: String
    var icon: String?
    var style: Style = .primary
    var full = false
    let action: () -> Void

    init(_ title: String, icon: String? = nil, style: Style = .primary, full: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.style = style; self.full = full; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(VF.sans(13, .semibold))
            }
            .foregroundStyle(style == .primary ? Color.white : VF.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: full ? .infinity : nil)
            .frame(height: 32)
            .background(style == .primary ? VF.black : VF.buttonSoft, in: RoundedRectangle(cornerRadius: VF.buttonRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pegel als Balken-Verlauf (neueste rechts)
struct TrainingMeter: View {
    let levels: [Float]
    var active = true
    var tint: Color = VF.ink
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, lv in
                Capsule()
                    .fill(active ? tint.opacity(0.35 + 0.65 * Double(lv)) : VF.hairline)
                    .frame(width: 4, height: max(4, CGFloat(lv) * 40))
            }
        }
        .frame(height: 44)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private struct OtherVoiceRow: View {
    let voice: NegativeVoice
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Text(String(voice.name.prefix(1)).uppercased()).font(VF.sans(15, .semibold)).foregroundStyle(VF.ink)
                .frame(width: 36, height: 36).background(VF.cardSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name).font(VF.sans(14.5, .semibold)).foregroundStyle(VF.ink)
                Text((voice.source == "import" ? "Stimmabdruck importiert" : "30 s vorgelesen") + " · "
                     + (voice.whisper.isEmpty ? "normal" : "normal + geflüstert") + " · "
                     + voice.date.formatted(date: .abbreviated, time: .omitted))
                    .font(VF.sans(12)).foregroundStyle(VF.muted)
            }
            Spacer()
            Text("wird nicht mitgeschrieben").font(VF.sans(12, .medium)).foregroundStyle(VF.teal1)
                .padding(.horizontal, 9).padding(.vertical, 4).background(VF.teal4, in: Capsule())
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.muted) }
                .buttonStyle(.plain).help("Entfernen")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
