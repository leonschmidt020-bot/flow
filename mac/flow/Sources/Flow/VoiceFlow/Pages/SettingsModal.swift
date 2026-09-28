import AppKit
import AVFoundation
import SwiftUI

/// Einstellungen als Modal : links Navigation, rechts Serif-Titel + Karten mit Zeilen „Titel / Beschreibung / [Ändern]“.
/// Enthält alle Einstellungen aus dem alten SettingsWindow (gleiche Settings.shared-Bindungen).
struct VFSettingsModal: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, system, dictation, notetaker, voice, pill, privacy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "Allgemein"
            case .system: return "System"
            case .dictation: return "Diktat"
            case .notetaker: return "Notetaker"
            case .voice: return "Stimme"
            case .pill: return "Pille"
            case .privacy: return "Daten & Datenschutz"
            }
        }
        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .system: return "laptopcomputer"
            case .dictation: return "mic"
            case .notetaker: return "record.circle"
            case .voice: return "person.wave.2"
            case .pill: return "capsule"
            case .privacy: return "checkmark.shield"
            }
        }
    }

    /// Nur Sichtprüfung: höher rendern, damit alles ohne Scrollen sichtbar ist
    static var maxHeight: CGFloat = 847
    let onClose: () -> Void
    @State private var section: Section
    @ObservedObject private var s = Settings.shared

    init(onClose: @escaping () -> Void) { self.onClose = onClose; _section = State(initialValue: .general) }
    /// Direkt auf einem Bereich öffnen (z. B. „Stimme“ aus der Einrichtungs-Karte)
    init(section: Section, onClose: @escaping () -> Void) { self.onClose = onClose; _section = State(initialValue: section) }

    var body: some View {
        // Passt sich dem Platz an (kleine Bildschirme wie ein MacBook Air: schmalere Seitenleiste + Ränder, nichts ragt heraus)
        GeometryReader { g in
            let compact = g.size.width < 900
            HStack(spacing: 0) {
                sidebar.frame(width: compact ? 214 : 290)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title).font(VF.serif(compact ? 32 : 40)).foregroundStyle(VF.ink).padding(.bottom, compact ? 24 : 34)
                        content
                    }
                    .padding(.horizontal, compact ? 26 : 64).padding(.top, compact ? 52 : 66).padding(.bottom, 50)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(VF.card)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(minWidth: 560, idealWidth: 1271, maxWidth: 1271, minHeight: 420, idealHeight: 847, maxHeight: VFSettingsModal.maxHeight)
        .background(VF.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            PGIconButton(symbol: "xmark", help: "Schließen (Esc)", size: 16, action: onClose)
                .keyboardShortcut(.cancelAction)
                .padding(18)
        }
        .shadow(color: .black.opacity(0.18), radius: 40, y: 12)
        .environment(\.colorScheme, .light)
    }

    // MARK: Navigation

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            navLabel("Einstellungen").padding(.top, 26)
            VStack(spacing: 2) {
                ForEach([Section.general, .system, .dictation, .notetaker, .voice, .pill]) { navItem($0) }
            }
            .padding(.top, 14)
            Rectangle().fill(VF.hairline).frame(height: 1).padding(.vertical, 14).padding(.horizontal, 12)
            navLabel("Konto")
            navItem(.privacy).padding(.top, 14)
            Spacer()
            HStack {
                Text(AppVersion.short == "dev" ? "Flow (Entwickler)" : "Flow v\(AppVersion.short)").font(.system(size: 14.5)).foregroundStyle(VF.muted).help(AppVersion.line)
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(VF.muted).help("Alles lokal auf diesem Mac")
            }
            .padding(.horizontal, 22).padding(.bottom, 24)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.957, green: 0.953, blue: 0.937))
    }

    private func navLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 14.5, weight: .medium)).tracking(1.3).foregroundStyle(VF.ink.opacity(0.7))
            .padding(.horizontal, 10)
    }

    private func navItem(_ sec: Section) -> some View {
        SettingsNavItem(title: sec.title, icon: sec.icon, selected: section == sec) { section = sec }
    }

    // MARK: Inhalte

    @ViewBuilder private var content: some View {
        switch section {
        case .general: GeneralSection(s: s)
        case .system: SystemSection(s: s)
        case .dictation: DictationSection(s: s)
        case .notetaker: NotetakerSection(s: s)
        case .voice: VoiceSection(s: s)
        case .pill: PillSection(s: s)
        case .privacy: PrivacySection(s: s)
        }
    }
}

private struct SettingsNavItem: View {
    let title: String, icon: String, selected: Bool, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 24)
                Text(title).font(.system(size: 18.5)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
            }
            .foregroundStyle(VF.ink)
            .padding(.horizontal, 12).frame(height: 47)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? VF.selected : (hover ? VF.buttonSoft.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Bausteine

/// Karte (#F5F4F0) mit Zeilen und Haarlinien dazwischen.
private struct SCard<Content: View>: View {
    var caption: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let caption {
                Text(caption.uppercased()).font(.system(size: 13, weight: .semibold)).tracking(1.2).foregroundStyle(VF.muted).padding(.leading, 4)
            }
            _VariadicView.Tree(SDividedLayout()) { content() }
                .padding(.horizontal, 26)
                .background(RoundedRectangle(cornerRadius: VF.cardRadius).fill(VF.cardSoft))
        }
        .padding(.bottom, 26)
    }
}

/// Setzt Haarlinien zwischen die Zeilen einer Karte.
private struct SDividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != children.last?.id { Rectangle().fill(VF.hairline).frame(height: 1) }
            }
        }
    }
}

private struct SToggle: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(VF.black) }
}

private struct SButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(PGSoftButtonStyle(minWidth: 172, fill: Color(red: 0.925, green: 0.918, blue: 0.898)))
    }
}

private struct SField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(.system(size: 17))
            .padding(.horizontal, 14).frame(width: 196, height: 47)
            .background(RoundedRectangle(cornerRadius: VF.buttonRadius).fill(VF.card))
            .overlay(RoundedRectangle(cornerRadius: VF.buttonRadius).stroke(VF.hairline))
    }
}

private struct SStatus: View {
    let ok: Bool
    var okText = "Erteilt"
    var body: some View {
        Label(ok ? okText : "Fehlt", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(ok ? Color(red: 0.18, green: 0.55, blue: 0.34) : Color(red: 0.80, green: 0.25, blue: 0.22))
            .frame(width: 216)
    }
}

private func safeAppDelegate() -> AppDelegate? { NSApp.delegate as? AppDelegate }

// MARK: - Allgemein

private struct GeneralSection: View {
    @ObservedObject var s: Settings
    @State private var devices: [AudioInputDevice] = []
    @State private var updateInfo = "Updates kommen automatisch – oder hier prüfen."
    @State private var autoUpdate = Updater.enabled

    private var micName: String {
        guard let uid = s.micUID else { return "Systemstandard (empfohlen)" }
        return devices.first { $0.uid == uid }?.name ?? "Nicht angeschlossen – nimmt Systemstandard"
    }

    var body: some View {
        SCard {
            PGSettingRow(title: "Tastenkürzel", detail: "\(s.hotkey.label) halten und sprechen, loslassen → Text erscheint. Esc bricht ab.") {
                PGChoiceMenu(selection: $s.hotkey, options: HotkeyChoice.allCases, label: { $0.label }) { _ in safeAppDelegate()?.startHotkey() }
            }
            PGSettingRow(title: "Freihand-Modus", detail: "Doppelt tippen startet, nochmal tippen beendet.") { SToggle(isOn: $s.doubleTapHandsFree) }
            PGSettingRow(title: "Mikrofon", detail: micName) {
                PGChoiceMenu(selection: Binding(get: { s.micUID ?? "" }, set: { s.micUID = $0.isEmpty ? nil : $0 }),
                             options: [""] + devices.map(\.uid),
                             label: { uid in uid.isEmpty ? "Systemstandard" : (devices.first { $0.uid == uid }?.name ?? uid) })
            }
            PGSettingRow(title: "Diktat-Sprachen", detail: s.languageMode.label) {
                PGChoiceMenu(selection: $s.languageMode, options: LanguageMode.allCases, label: { $0.label }) { m in
                    safeAppDelegate()?.pill?.view.languageShort = m.short
                }
            }
            PGSettingRow(title: "Töne", detail: "Leise Töne bei Start und Stopp.") { SToggle(isOn: $s.sounds) }
        }
        SCard(caption: "Speicher") { MemorySaverSettingRow() }
        SCard(caption: "Tempo") { TempoGuardSettingRow() }
        SCard(caption: "Du") {
            PGSettingRow(title: "Dein Name", detail: "Begrüßung, Stimm-Training und dein eigenes Mikrofon im Meeting-Transkript.") {
                SField(placeholder: Identity.systemFirstName, text: $s.myName)
            }
            PGSettingRow(title: "Partner im geteilten Tresor",
                         detail: Identity.clipVaultPartner.map { "Leer = aus der ClipVault-Kopplung: \($0)." }
                            ?? "Nur die Beschriftung „Geteilt mit …“ in ClipVault. Leer = „deinem Partner“.") {
                SField(placeholder: Identity.clipVaultPartner ?? "optional", text: $s.partnerName)
            }
        }
        SCard(caption: "Über") {
            PGSettingRow(title: "Über Flow",
                         detail: "\(AppVersion.line)\n\(updateInfo)") {
                VStack(alignment: .trailing, spacing: 8) {   // untereinander – nebeneinander wären sie zu breit für kleine Bildschirme
                    SButton(title: "Fehlerbericht senden") {
                        updateInfo = "Erstelle Fehlerbericht …"
                        Diagnose.send { updateInfo = $0 }
                    }
                    SButton(title: "Jetzt prüfen") {
                        updateInfo = "Prüfe …"
                        Updater.shared.check(manual: true) { updateInfo = $0 }
                    }
                    SButton(title: "Willkommen erneut zeigen") {
                        OnboardingState.shared.step = 0
                        s.onboardingDone = false
                        VFHub.shared.closeSettings()
                    }
                }
            }
            PGSettingRow(title: "Automatische Updates",
                         detail: "Schaut jede Minute auf GitHub nach einer neuen Version. Ist eine da, bekommt die Pille einen roten Punkt – drüberfahren, „Jetzt installieren“. Deine Daten bleiben erhalten.") {
                Toggle("", isOn: Binding(get: { autoUpdate }, set: { autoUpdate = $0; Updater.enabled = $0 }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
        .onAppear { devices = AudioDevices.inputs() }
    }
}

// MARK: - System

private struct SystemSection: View {
    @ObservedObject var s: Settings
    @State private var status = SystemSection.currentStatus()
    @State private var fnOK = FnKeySetting.isNothing
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    static func currentStatus() -> AppDelegate.PermissionStatus {
        safeAppDelegate()?.permissionStatus ?? AppDelegate.PermissionStatus(
            mic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess(), hotkeyActive: false)
    }

    var body: some View {
        SCard(caption: "Berechtigungen") {
            perm("Mikrofon", "Damit Flow dich hört.", status.mic, "Privacy_Microphone")
            perm("Bedienungshilfen", "Damit der Text an der Cursor-Stelle eingefügt wird.", status.accessibility, "Privacy_Accessibility")
            perm("Eingabeüberwachung", "Damit die Fn-Taste erkannt wird.", status.inputMonitoring && status.hotkeyActive, "Privacy_ListenEvent")
        }
        Text("Systemton im Meeting fragt macOS beim ersten Meeting selbst ab („Bildschirm- & Systemaudioaufnahme“).")
            .font(.system(size: 14.5)).foregroundStyle(VF.muted).padding(.top, -14).padding(.bottom, 26).padding(.leading, 4)
        SCard(caption: "Fn-Taste") {
            PGSettingRow(title: "🌐-Taste drücken für", detail: fnOK ? "Steht auf „Nichts tun“ – perfekt." : "Öffnet noch Emojis oder Apple-Diktat – das stört Flow.") {
                if fnOK { SStatus(ok: true, okText: "Passt") } else {
                    SButton(title: "Auf „Nichts tun“") { FnKeySetting.setNothing(); fnOK = FnKeySetting.isNothing }
                }
            }
        }
        .onReceive(timer) { _ in status = SystemSection.currentStatus(); fnOK = FnKeySetting.isNothing }
    }

    private func perm(_ title: String, _ detail: String, _ ok: Bool, _ anchor: String) -> some View {
        PGSettingRow(title: title, detail: detail) {
            if ok { SStatus(ok: true) } else { SButton(title: "Öffnen") { AppDelegate.openPrivacyPane(anchor) } }
        }
    }
}

// MARK: - Diktat

private struct DictationSection: View {
    @ObservedObject var s: Settings
    @ObservedObject private var pv = PartnerVocab.shared
    var body: some View {
        SCard {
            PGSettingRow(title: "Erkennung", detail: s.engine.label) {
                PGChoiceMenu(selection: $s.engine, options: ASREngine.allCases, label: { $0.label })
            }
            PGSettingRow(title: "Aus meinen Korrekturen lernen", detail: "Wort im Textfeld ändern → Flow merkt es sich im Wörterbuch (✨).") { SToggle(isOn: $s.learnFromEdits) }
            PGSettingRow(title: "Namen vom Partner automatisch übernehmen", detail: "Lernt \(Identity.partner(.nominative)) einen Namen, kommt nur das Wort an. Aus: Flow fragt kurz an der Pille.") { SToggle(isOn: $pv.autoAccept) }
            PGSettingRow(title: "Diktat bleibt in der Zwischenablage", detail: "Praktisch mit ClipVault – nichts geht verloren.") { SToggle(isOn: $s.keepInClipboard) }
            PGSettingRow(title: "Text dorthin, wo die Maus ist",
                         detail: "Fn halten, sprechen, Maus auf ein Fenster – beim Loslassen landet der Text dort im Eingabefeld, ohne vorher hineinzuklicken.") {
                SToggle(isOn: $s.mouseTarget)
            }
            PGSettingRow(title: "Danach automatisch abschicken (Enter)",
                         detail: "Nur in Terminals, Claude Code und Chat-Feldern (Claude, ChatGPT, Nachrichten, WhatsApp, Slack) – nie in Dokumenten oder im Code-Editor.") {
                SToggle(isOn: $s.mouseTargetAutoSend).disabled(!s.mouseTarget).opacity(s.mouseTarget ? 1 : 0.4)
            }
            PGSettingRow(title: "Rahmen „Text kommt hierher“ zeigen",
                         detail: "Blauer Rahmen um das Fenster, in das der Text kommt, solange du sprichst.") {
                SToggle(isOn: $s.mouseTargetHighlight).disabled(!s.mouseTarget).opacity(s.mouseTarget ? 1 : 0.4)
            }
        }
        SCard(caption: "Text") {
            PGSettingRow(title: "Command Mode (fn + ⌃)",
                         detail: ClaudeCLI.isAvailable ? "Text markieren, fn + ⌃ halten, Befehl sprechen („mach das kürzer“) – Claude schreibt um. Optional."
                                                       : "Braucht die optionale Claude-CLI (nicht gefunden). fn + ⌃ bleibt ein normales Diktat.") {
                SToggle(isOn: $s.commandMode).disabled(!ClaudeCLI.isAvailable).opacity(ClaudeCLI.isAvailable ? 1 : 0.45)
            }
            PGSettingRow(title: "Füllwörter entfernen", detail: "ähm, äh, uh … und direkte Wortwiederholungen.") { SToggle(isOn: $s.removeFillers) }
            PGSettingRow(title: "Zeilen-Befehle", detail: "„neue Zeile“, „neuer Absatz“") { SToggle(isOn: $s.voiceCommands) }
            PGSettingRow(title: "KI-Feinschliff",
                         detail: s.aiPolish.label + "\n" + Polisher.statusLine(s.aiPolish)) {
                PGChoiceMenu(selection: $s.aiPolish, options: AIPolish.allCases, label: { $0.label })
            }
        }
        SCard(caption: "Sprachbefehle") { VoiceCommandSettingsRows() }
        SCard(caption: "Agent-Prompts") { APSettingsRows() }
    }
}

// MARK: - Notetaker

private struct NotetakerSection: View {
    @ObservedObject var s: Settings
    var body: some View {
        SCard {
            PGSettingRow(title: "Meeting-Apps erkennen",
                         detail: s.meetingDetection.label + "\nZoom, Teams, FaceTime, Meet, Slack, Discord, WhatsApp … sobald sie das Mikrofon nutzen.") {
                PGChoiceMenu(selection: $s.meetingDetection, options: MeetingDetection.allCases, label: { $0.label })
            }
            PGSettingRow(title: "Mein Name", detail: "So heißt dein eigenes Mikrofon im Transkript.") {
                SField(placeholder: Identity.systemFirstName, text: $s.myName)
            }
            PGSettingRow(title: "Automatisch zusammenfassen",
                         detail: ClaudeCLI.isAvailable ? "Nach dem Meeting schreibt Claude die Notizen (optional, über deine Claude-CLI)."
                                                       : "Braucht die optionale Claude-CLI (nicht gefunden). Transkripte gehen auch ohne.") {
                SToggle(isOn: $s.autoSummary).disabled(!ClaudeCLI.isAvailable).opacity(ClaudeCLI.isAvailable ? 1 : 0.45)
            }
            PGSettingRow(title: "Audio behalten", detail: "Nötig für „Neu auswerten“.") { SToggle(isOn: $s.keepAudio) }
            PGSettingRow(title: "Kurzbefehl", detail: "⌃⌥M startet oder beendet eine Aufnahme. ⌃⌥S merkt einen Moment (Bildschirmfoto + die letzten 30 s).") { EmptyView() }
        }
        SCard(caption: "Audiodateien") { AudioImportSettingsRows() }
        SCard(caption: "Meeting-Kontext") {
            MCSettingsCaptureRow()
            MCSettingsVideoRow()
            MCSettingsSummaryRow()
            MCSettingsPermissionRow()
        }
    }
}

// MARK: - Stimme

private struct VoiceSection: View {
    @ObservedObject var s: Settings
    @State private var enrolled = VoiceID.isEnrolled
    @State private var voices: [VoiceStore.Voice] = []
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        SCard(caption: "Nur meine Stimme") {
            PGSettingRow(title: "Stimmprofil", detail: enrolled ? "Ist eingelernt." : "Noch keins – einmal 22 Sekunden vorlesen.") {
                SButton(title: enrolled ? "Neu einlernen" : "Stimme einlernen") { VFHub.shared.closeSettings(); VoiceFlowWindow.shared.show(.training) }
            }
            PGSettingRow(title: "Nur meine Stimme behalten", detail: enrolled ? "An: andere Stimmen im Raum werden verworfen. Aus: alle Stimmen werden mitgeschrieben – z. B. wenn ihr zu zweit diktiert. Schnell umschalten: Maus auf die Pille → Weltkugel → „Wer darf diktieren?“." : "Braucht ein eingelerntes Stimmprofil.") {
                SToggle(isOn: $s.onlyMyVoice).disabled(!enrolled).opacity(enrolled ? 1 : 0.45)
            }
            PGSettingRow(title: "Ton vom Mac herausfiltern", detail: "Musik, YouTube, Meeting-Teilnehmer landen nicht im Diktat.") { SToggle(isOn: $s.filterMacAudio) }
        }
        SCard(caption: "Gemerkte Stimmen") {
            if voices.isEmpty {
                PGSettingRow(title: "Noch keine", detail: "Im Meeting-Transkript auf einen Sprecher klicken und benennen – dann erkennt Flow die Stimme beim nächsten Mal.") { EmptyView() }
            }
            ForEach(voices, id: \.name) { v in
                PGSettingRow(title: v.name, detail: "\(v.samples)× gehört") {
                    SButton(title: "Vergessen") { VoiceStore.forget(name: v.name); voices = VoiceStore.all() }
                }
            }
        }
        .onAppear { voices = VoiceStore.all() }
        .onReceive(refresh) { _ in enrolled = VoiceID.isEnrolled }
    }
}

// MARK: - Pille

private struct PillSection: View {
    @ObservedObject var s: Settings
    var body: some View {
        SCard {
            PGSettingRow(title: "Anzeige", detail: s.pillVisibility.label) {
                PGChoiceMenu(selection: $s.pillVisibility, options: PillVisibility.allCases, label: { $0.label }) { _ in
                    safeAppDelegate()?.pill?.applyVisibility()
                }
            }
            PGSettingRow(title: "Pille folgt", detail: s.pillFollow.label) {
                PGChoiceMenu(selection: $s.pillFollow, options: PillFollow.allCases, label: { $0.label })
            }
        }
        SCard(caption: "Position pro Bildschirm") {
            ForEach(NSScreen.screens, id: \.self) { screen in
                let current = s.placement(for: screen).preset
                PGSettingRow(title: screen.localizedName, detail: current?.label ?? "Frei (gezogen)") {
                    PGChoiceMenu(selection: Binding(get: { current?.rawValue ?? "custom" }, set: { _ in }),
                                 options: PillPreset.allCases.map(\.rawValue) + (current == nil ? ["custom"] : []),
                                 label: { PillPreset(rawValue: $0)?.label ?? "Frei (gezogen)" }) { v in
                        if let p = PillPreset(rawValue: v) { safeAppDelegate()?.pill?.setPlacement(p, for: screen) }
                    }
                }
            }
        }
        Text("Tipp: Die Pille lässt sich auch mit der Maus an jede Stelle ziehen. In der Nähe eines Andock-Punkts rastet sie ein.")
            .font(.system(size: 14.5)).foregroundStyle(VF.muted).padding(.top, -14).padding(.leading, 4)
    }
}

// MARK: - Daten & Datenschutz

private struct PrivacySection: View {
    @ObservedObject var s: Settings
    var body: some View {
        SCard {
            PGSettingRow(title: "Transkripte automatisch löschen",
                         detail: (s.retentionDays == 0 ? "Nie" : "Nach \(s.retentionDays) \(s.retentionDays == 1 ? "Tag" : "Tagen")")
                            + " – Transkript, Zusammenfassung und Tonspuren, endgültig. Meetings mit 📌 bleiben.") {
                PGChoiceMenu(selection: $s.retentionDays, options: [1, 3, 7, 30, 0],
                             label: { $0 == 0 ? "Nie" : ($0 == 1 ? "Nach 1 Tag" : "Nach \($0) Tagen") }) { _ in MeetingStore.shared.cleanup() }
            }
            SmartSettingsRows()
            PGSettingRow(title: "Diktierte Texte im Protokoll",
                         detail: "Nur zur Fehlersuche. Aus: Im Protokoll stehen nur Dauer und Wortzahl.") { SToggle(isOn: $s.logTexts) }
            PGSettingRow(title: "Daten-Ordner", detail: "Meetings, Wörterbuch, Stimmen, Snippets: \(Paths.baseDisplay) – bleibt auf diesem Mac, wird nie geteilt.") {
                SButton(title: "Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Paths.base]) }
            }
        }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 20)).foregroundStyle(VF.teal1)
            Text("Alles läuft lokal auf dem Mac (Whisper/Parakeet + pyannote auf der Neural Engine). Nur Zusammenfassungen, Fragen und Transforms gehen an Claude.")
                .font(.system(size: 15.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: VF.cardRadius).stroke(VF.hairline))
    }
}
