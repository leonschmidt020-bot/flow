import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SettingsTabModel()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Flow – Einstellungen"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(tabs: model).environmentObject(Settings.shared))
            w.delegate = self
            window = w
        }
        if let w = window, !w.isVisible { w.centerOnMouseScreen() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func select(tab: String) { model.tab = tab }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

final class SettingsTabModel: ObservableObject { @Published var tab = "diktat" }

struct SettingsView: View {
    @ObservedObject var tabs: SettingsTabModel
    var embedded = false
    @EnvironmentObject var s: Settings

    var body: some View {
        TabView(selection: $tabs.tab) {
            DictationTab().tabItem { Label("Diktat", systemImage: "mic") }.tag("diktat")
            PillTab().tabItem { Label("Pille", systemImage: "capsule") }.tag("pille")
            DictionaryTab().tabItem { Label("Wörterbuch", systemImage: "character.book.closed") }.tag("woerter")
            MeetingTab().tabItem { Label("Meetings", systemImage: "person.2.wave.2") }.tag("meetings")
            GeneralTab().tabItem { Label("Allgemein", systemImage: "gearshape") }.tag("allgemein")
        }
        .padding(embedded ? 0 : 20)
        .frame(minWidth: embedded ? 560 : 620, idealWidth: 620, minHeight: embedded ? 480 : 560)
    }
}

struct DictationTab: View {
    @EnvironmentObject var s: Settings
    @State private var devices: [AudioInputDevice] = []
    @State private var enrolled = VoiceID.isEnrolled
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("Diktier-Taste", selection: $s.hotkey) {
                    ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: s.hotkey) { AppDelegate.shared.startHotkey() }
                Toggle("Doppelt tippen = Freihand-Modus (nochmal tippen zum Beenden)", isOn: $s.doubleTapHandsFree)
                Picker("Sprache", selection: $s.languageMode) {
                    ForEach(LanguageMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: s.languageMode) { AppDelegate.shared.pill.view.languageShort = s.languageMode.short }
                Picker("Erkennung", selection: $s.engine) {
                    ForEach(ASREngine.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Aus meinen Korrekturen lernen (Wort im Textfeld ändern → Flow merkt es sich)", isOn: $s.learnFromEdits)
                Text("Halten und sprechen, loslassen → Text erscheint an der Cursor-Stelle. Esc bricht ab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text") {
                Toggle("Füllwörter entfernen (ähm, äh, uh …)", isOn: $s.removeFillers)
                Toggle("Sprachbefehle: „neue Zeile“, „neuer Absatz“", isOn: $s.voiceCommands)
                Picker("KI-Feinschliff", selection: $s.aiPolish) {
                    ForEach(AIPolish.allCases) { Text($0.label).tag($0) }
                }
                Text(Polisher.statusLine(s.aiPolish))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Diktat bleibt in der Zwischenablage (→ ClipVault)", isOn: $s.keepInClipboard)
            }
            Section("Nur meine Stimme") {
                Toggle("Ton vom Mac herausfiltern (Musik, YouTube, Meeting-Teilnehmer)", isOn: $s.filterMacAudio)
                Toggle("Nur meine Stimme behalten (andere Stimmen im Raum/Video verwerfen)", isOn: $s.onlyMyVoice)
                    .disabled(!enrolled)
                HStack {
                    Image(systemName: enrolled ? "checkmark.circle.fill" : "person.wave.2")
                        .foregroundStyle(enrolled ? .green : .secondary)
                    Text(enrolled ? "Stimmprofil ist eingelernt." : "Noch kein Stimmprofil – einmal 22 s vorlesen.")
                    Spacer()
                    Button(enrolled ? "Neu einlernen" : "Stimme einlernen") { VoiceEnrollController.shared.show() }
                }
            }
            Section("Audio") {
                Picker("Mikrofon", selection: Binding(get: { s.micUID ?? "" }, set: { s.micUID = $0.isEmpty ? nil : $0 })) {
                    Text("Systemstandard").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                Toggle("Leise Töne bei Start/Stopp", isOn: $s.sounds)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputs() }
        .onReceive(refresh) { _ in enrolled = VoiceID.isEnrolled }
    }
}

struct PillTab: View {
    @EnvironmentObject var s: Settings

    var body: some View {
        Form {
            Section {
                Picker("Anzeige", selection: $s.pillVisibility) {
                    ForEach(PillVisibility.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: s.pillVisibility) { AppDelegate.shared.pill.applyVisibility() }
                Picker("Pille folgt", selection: $s.pillFollow) {
                    ForEach(PillFollow.allCases) { Text($0.label).tag($0) }
                }
                Text("Standard: die Pille springt auf den Bildschirm, auf dem du gerade schreibst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Position pro Bildschirm") {
                ForEach(NSScreen.screens, id: \.self) { screen in
                    Picker(screen.localizedName, selection: Binding(
                        get: { s.placement(for: screen).preset?.rawValue ?? "custom" },
                        set: { v in
                            if let p = PillPreset(rawValue: v) { AppDelegate.shared.pill.setPlacement(p, for: screen) }
                        })) {
                        ForEach(PillPreset.allCases) { Text($0.label).tag($0.rawValue) }
                        Text("Frei (gezogen)").tag("custom")
                    }
                }
                Text("Tipp: Die Pille lässt sich auch einfach mit der Maus an jede Stelle ziehen. In der Nähe eines Andock-Punkts rastet sie ein.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DictionaryTab: View {
    @EnvironmentObject var s: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wenn Flow ein Wort falsch schreibt: links, wie es ankommt – rechts, wie es richtig ist. Korrigierst du ein Diktat direkt im Textfeld, trägt Flow das hier selbst ein (✨ gelernt). Echte Wörter wie „ID“ werden dabei nicht blind ersetzt, sondern Whisper bekommt „Lidl“ als Hinweis.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach($s.dictionary) { $e in
                    HStack {
                        TextField("gehört", text: $e.heard).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("richtig", text: $e.write).textFieldStyle(.roundedBorder)
                        if e.learned == true {
                            Image(systemName: "sparkles").foregroundStyle(.purple).help(e.vocabOnly == true ? "Gelernt – nur als Hinweis für Whisper" : "Gelernt aus deiner Korrektur")
                        }
                        Button { s.dictionary.removeAll { $0.id == e.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button { s.dictionary.append(DictEntry(heard: "", write: "")) } label: { Label("Eintrag hinzufügen", systemImage: "plus") }
                Spacer()
            }
        }
    }
}

struct MeetingTab: View {
    @EnvironmentObject var s: Settings
    @State private var voices: [VoiceStore.Voice] = []

    var body: some View {
        Form {
            Section {
                Picker("Meeting-Apps erkennen", selection: $s.meetingDetection) {
                    ForEach(MeetingDetection.allCases) { Text($0.label).tag($0) }
                }
                Text("Erkennt Zoom, Teams, FaceTime, Meet im Browser, Slack, Discord, WhatsApp … sobald sie das Mikrofon benutzen. Bei „Automatisch“ stoppt die Aufnahme 30 s nach Meeting-Ende.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Kurzbefehl: ⌃⌥M startet/beendet eine Aufnahme.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Transkript") {
                TextField("Mein Name (für das eigene Mikrofon)", text: $s.myName)
                Toggle("Nach dem Meeting automatisch zusammenfassen (Claude)", isOn: $s.autoSummary)
                Toggle("Audio behalten (für „Neu auswerten“)", isOn: $s.keepAudio)
                Picker("Transkripte automatisch löschen nach", selection: $s.retentionDays) {
                    Text("1 Tag").tag(1); Text("3 Tagen").tag(3); Text("7 Tagen").tag(7); Text("30 Tagen").tag(30); Text("Nie").tag(0)
                }
                .onChange(of: s.retentionDays) { MeetingStore.shared.cleanup() }
                Text("Gelöscht werden Transkript, Zusammenfassung und Tonspuren – endgültig. Meetings mit 📌 „Behalten“ (Rechtsklick in der Liste) bleiben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Gemerkte Stimmen") {
                if voices.isEmpty {
                    Text("Noch keine. Im Transkript auf einen Sprecher klicken und benennen – dann erkennt Flow die Stimme beim nächsten Mal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(voices, id: \.name) { v in
                    HStack {
                        Text(v.name)
                        Text("\(v.samples)× gehört").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Vergessen") { VoiceStore.forget(name: v.name); voices = VoiceStore.all() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { voices = VoiceStore.all() }
    }
}

struct GeneralTab: View {
    @EnvironmentObject var s: Settings
    @State private var status = AppDelegate.shared.permissionStatus
    @State private var fnOK = FnKeySetting.isNothing
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Berechtigungen") {
                row("Mikrofon", status.mic, "Privacy_Microphone")
                row("Bedienungshilfen (Text einfügen)", status.accessibility, "Privacy_Accessibility")
                row("Eingabeüberwachung (Fn-Taste)", status.inputMonitoring && status.hotkeyActive, "Privacy_ListenEvent")
                Text("Systemton im Meeting fragt macOS beim ersten Meeting selbst ab („Systemaudio aufnehmen“).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Fn-Taste") {
                HStack {
                    Image(systemName: fnOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(fnOK ? .green : .orange)
                    Text(fnOK ? "🌐-Taste ist auf „Nichts tun“ – perfekt." : "🌐-Taste öffnet noch Emojis/Diktat.")
                    Spacer()
                    if !fnOK { Button("Auf „Nichts tun“ stellen") { FnKeySetting.setNothing(); fnOK = FnKeySetting.isNothing } }
                }
            }
            Section("Fehlersuche") {
                Toggle("Diktierte Texte im Protokoll mitschreiben (nur zur Fehlersuche)", isOn: $s.logTexts)
                Text("Aus: Im Protokoll stehen nur Dauer und Wortzahl. Die letzten 5 Aufnahmen liegen in ~/.config/flow/diktate und löschen sich mit der normalen Frist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Daten") {
                HStack {
                    Text("Meetings, Wörterbuch, Stimmen: ~/.config/flow").font(.callout)
                    Spacer()
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Paths.base]) }
                }
                Text("Alles läuft lokal auf dem Mac (Parakeet + pyannote auf der Neural Engine). Nur Zusammenfassungen und Fragen gehen an Claude.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in status = AppDelegate.shared.permissionStatus; fnOK = FnKeySetting.isNothing }
    }

    private func row(_ title: String, _ ok: Bool, _ anchor: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
            Text(title)
            Spacer()
            if !ok { Button("Öffnen") { AppDelegate.openPrivacyPane(anchor) } }
        }
    }
}

/// „🌐-Taste drücken für“ – muss auf „Nichts tun“ (0) stehen, sonst öffnet Fn Emojis oder Apple-Diktat.
enum FnKeySetting {
    static var isNothing: Bool {
        let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        return v == 0
    }

    static func setNothing() {
        CFPreferencesSetAppValue("AppleFnUsageType" as CFString, 0 as CFNumber, "com.apple.HIToolbox" as CFString)
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        // Die Umschalt-Anzeige (DE/US) liest die Einstellung erst nach einem Neustart neu ein.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["TextInputSwitcher"]
        try? p.run()
    }
}
