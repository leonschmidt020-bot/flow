import AppKit
import AVFoundation
import FluidAudio
import SwiftUI

// MARK: - Willkommen (erster Start ohne settings.json): Name → Sprachen → Berechtigungen live → Training
// Liegt als Schicht über dem Hub, bis `Settings.onboardingDone` gesetzt ist. Bestehende Installationen sehen ihn nie.

/// Was auf diesem Mac schon eingerichtet ist (Berechtigungen, Sprachmodelle, Claude-CLI).
/// Auch für `Flow --setup-status` (setup.sh --check).
enum SetupCheck {
    struct Permissions: Equatable {
        var mic: Bool, micAsked: Bool, accessibility: Bool, inputMonitoring: Bool, hotkeyActive: Bool, fnNothing: Bool
        var allRequired: Bool { mic && accessibility && inputMonitoring }
    }

    static func permissions() -> Permissions {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let running = (NSApp?.delegate as? AppDelegate)?.permissionStatus
        return Permissions(mic: mic == .authorized, micAsked: mic != .notDetermined,
                           accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess(),
                           hotkeyActive: running?.hotkeyActive ?? false, fnNothing: FnKeySetting.isNothing)
    }

    /// FluidAudio legt seine Modelle hier ab (lädt sie beim ersten Start von Hugging Face)
    static var fluidModels: URL { MLModelConfigurationUtils.defaultModelsDirectory() }
    private static func present(_ folder: String) -> Bool {
        let d = fluidModels.appendingPathComponent(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).contains { $0.hasSuffix(".mlmodelc") }
    }
    static var parakeet: Bool { present("parakeet-ultra") }
    static var campplus: Bool { present("campplus") }
    static var diarizer: Bool { present("speaker-diarization") }
    static var whisperServer: Bool { WhisperEngine.serverBinary != nil }
    static var whisperModel: Bool { WhisperFallback.model != nil }
    static var claude: Bool { ClaudeCLI.isAvailable }

    /// Zeilen für die Konsole: „ok|fehlt|optional  Name  Hinweis“
    static func report() -> [(ok: Bool, optional: Bool, name: String, hint: String)] {
        let p = permissions()
        return [
            (whisperServer, false, "whisper-server", whisperServer ? WhisperEngine.serverBinary! : "brew install whisper-cpp"),
            (whisperModel, false, "Whisper-Modell", WhisperFallback.model ?? "~/.cache/whisper-cpp/models/ggml-large-v3-turbo-q5_0.bin fehlt"),
            (parakeet, false, "Parakeet (FluidAudio)", parakeet ? "vorhanden" : "lädt beim ersten Start (~0,5 GB) – oder: Flow --prewarm-models"),
            (campplus, false, "Stimmprofil-Modell (CAM++)", campplus ? "vorhanden" : "lädt beim ersten Start"),
            (diarizer, true, "Sprechertrennung (Meetings)", diarizer ? "vorhanden" : "lädt beim ersten Meeting"),
            (claude, true, "Claude-CLI", claude ? ClaudeCLI.binary! : "fehlt – Zusammenfassungen/Transforms aus, Diktat geht trotzdem"),
            (p.fnNothing, false, "Fn-Taste = „Nichts tun“", p.fnNothing ? "passt" : "Systemeinstellungen → Tastatur"),
        ]
    }
}

final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()
    @Published var step = 0
    /// Nur Sichtprüfung: Ablauf zeigen, ohne Settings zu ändern
    var forceVisible = false
    static let steps = 4
}

struct OnboardingOverlay: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var state = OnboardingState.shared
    @State private var perms = SetupCheck.permissions()
    private let timer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            VF.chrome.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    dots
                    Spacer()
                    if state.step < OnboardingState.steps - 1 {
                        Button("Überspringen") { finish(openTraining: false) }
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(VF.muted)
                    }
                }
                .padding(.bottom, 22)
                Group {
                    switch state.step {
                    case 0: welcome
                    case 1: languages
                    case 2: permissions
                    default: done
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer.padding(.top, 20)
            }
            .padding(.horizontal, 44).padding(.top, 30).padding(.bottom, 28)
            .frame(width: 780, height: 610)
            .background(VF.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(VF.hairline))
            .shadow(color: .black.opacity(0.14), radius: 36, y: 14)
        }
        .environment(\.colorScheme, .light)
        .onReceive(timer) { _ in
            let p = SetupCheck.permissions()
            if p != perms { perms = p }
        }
    }

    // MARK: Schritte

    private var welcome: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 0) {
                PG.headline("Willkommen bei *Flow*.", size: 42)
                Text("Halte fn, sprich, lass los – der Text steht da, wo dein Cursor ist. Alles bleibt auf diesem Mac: deine Stimme, dein Wörterbuch, deine Meetings.")
                    .font(.system(size: 15)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                field("Wie heißt du?", text: $s.myName, placeholder: Identity.systemFirstName,
                      hint: "So begrüßt dich Flow, so heißt dein Mikrofon im Meeting-Transkript.")
                    .padding(.top, 28)
                field("Mit wem teilst du den ClipVault-Tresor? (optional)", text: $s.partnerName,
                      placeholder: Identity.clipVaultPartner ?? "z. B. Bruder, Kollegin …",
                      hint: Identity.clipVaultPartner.map { "Aus der ClipVault-Kopplung erkannt: \($0). Leer lassen = so übernehmen." }
                        ?? "Nur für die Beschriftung „Geteilt mit …“. Geteilt wird nur, was du selbst teilst.")
                    .padding(.top, 18)
            }
            HubIllustration(name: "illu_willkommen", fallback: "hand.wave", size: 190)
        }
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 0) {
            PG.headline("In welcher Sprache *sprichst* du?", size: 38)
            Text("Flow erkennt Deutsch und Englisch. Ändern kannst du das jederzeit an der Pille (🌐) oder in den Einstellungen.")
                .font(.system(size: 15)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            VStack(spacing: 10) {
                ForEach(LanguageMode.allCases) { m in
                    Button { s.languageMode = m } label: {
                        HStack(spacing: 14) {
                            Text(m.short).font(.system(size: 13, weight: .semibold, design: .rounded))
                                .frame(width: 58, height: 30).background(VF.buttonSoft, in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.label).font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                                Text(languageHint(m)).font(.system(size: 12.5)).foregroundStyle(VF.muted)
                            }
                            Spacer()
                            Image(systemName: s.languageMode == m ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20)).foregroundStyle(s.languageMode == m ? VF.purple : VF.muted.opacity(0.6))
                        }
                        .padding(.horizontal, 18).frame(height: 66)
                        .background(VF.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(s.languageMode == m ? VF.purple : VF.hairline, lineWidth: s.languageMode == m ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 26)
        }
    }

    private func languageHint(_ m: LanguageMode) -> String {
        switch m {
        case .both: return "Flow erkennt pro Diktat selbst, ob du Deutsch oder Englisch sprichst."
        case .de: return "Am genauesten, wenn du fast nur Deutsch diktierst."
        case .en: return "Most accurate if you only dictate in English."
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            PG.headline("Drei *Freigaben*, dann geht's los.", size: 36)
            Text("macOS fragt einmal. Klick auf „Erlauben“ bzw. „Öffnen“ und schalte Flow in der Liste ein – die Häkchen hier aktualisieren sich von selbst.")
                .font(.system(size: 14)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            VStack(spacing: 0) {
                permRow("Mikrofon", "Damit Flow dich hört.", perms.mic, perms.micAsked ? "Öffnen" : "Erlauben") {
                    if !perms.micAsked { AVCaptureDevice.requestAccess(for: .audio) { _ in } } else { AppDelegate.openPrivacyPane("Privacy_Microphone") }
                }
                divider
                permRow("Bedienungshilfen", "Damit der Text an der Cursor-Stelle landet.", perms.accessibility, "Öffnen") {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    if !AXIsProcessTrustedWithOptions(opts) { AppDelegate.openPrivacyPane("Privacy_Accessibility") }
                }
                divider
                permRow("Eingabeüberwachung", "Damit Flow die fn-Taste bemerkt.", perms.inputMonitoring, "Öffnen") {
                    if !CGRequestListenEventAccess() { AppDelegate.openPrivacyPane("Privacy_ListenEvent") }
                }
                divider
                permRow("fn-Taste auf „Nichts tun“", "Sonst öffnet fn Emojis oder Apple-Diktat.", perms.fnNothing, "Umstellen", okText: "Passt") {
                    FnKeySetting.setNothing(); perms = SetupCheck.permissions()
                }
                divider
                permRow("Systemton (nur Meetings)", "macOS fragt beim ersten Meeting selbst – dann „Erlauben“.", nil, "Öffnen") {
                    AppDelegate.openPrivacyPane("Privacy_ScreenCapture")
                }
            }
            .padding(.horizontal, 18)
            .hubCard(VF.cardSoft, radius: 12)
            .padding(.top, 18)
            models.padding(.top, 14)
        }
    }

    private var models: some View {
        let whisper = SetupCheck.whisperServer && SetupCheck.whisperModel
        return HStack(spacing: 16) {
            chip("Parakeet", SetupCheck.parakeet, SetupCheck.parakeet ? "bereit" : "lädt beim Start")
            chip("Whisper", whisper, whisper ? "bereit" : "setup.sh ausführen")
            chip("Claude", SetupCheck.claude, SetupCheck.claude ? "Zusammenfassungen an" : "optional – fehlt")
        }
    }

    private func chip(_ t: String, _ ok: Bool, _ d: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? VF.teal1 : VF.muted)
            Text(t).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(VF.ink)
            Text(d).font(.system(size: 12.5)).foregroundStyle(VF.muted)
        }
    }

    private var done: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 0) {
                PG.headline("Jetzt lernt Flow *deine* Stimme.", size: 40)
                Text("Im Training liest du fünf kurze Texte vor (je ~20 Sekunden). Danach schreibt Flow nur noch, was nach \(s.myName.isEmpty ? Identity.systemFirstName : s.myName) klingt – Stimmen aus Videos oder von Leuten neben dir fliegen raus.")
                    .font(.system(size: 15)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                VStack(alignment: .leading, spacing: 9) {
                    tip("fn", "halten, sprechen, loslassen")
                    tip("fn fn", "doppelt tippen = freihändig")
                    tip("⌃⌥M", "Meeting mitschreiben")
                }
                .padding(.top, 24)
                if !perms.allRequired {
                    Label("Noch nicht alle Freigaben erteilt – die Einrichtungs-Karte links erinnert dich.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(Color(red: 0.72, green: 0.42, blue: 0.10)).padding(.top, 20)
                }
            }
            HubIllustration(name: "illu_stimme", fallback: "waveform", size: 190)
        }
    }

    private func tip(_ k: String, _ t: String) -> some View {
        HStack(spacing: 10) { HubKeycap(k); Text(t).font(.system(size: 14)).foregroundStyle(VF.ink) }
    }

    // MARK: Bausteine

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<OnboardingState.steps, id: \.self) { i in
                Capsule().fill(i <= state.step ? VF.ink : VF.hairline).frame(width: i == state.step ? 22 : 8, height: 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            if state.step > 0 {
                Button("Zurück") { withAnimation(.easeOut(duration: 0.15)) { state.step -= 1 } }.buttonStyle(HubSoftButton(height: 38))
            }
            Spacer()
            if state.step < OnboardingState.steps - 1 {
                Button(state.step == 2 && !perms.allRequired ? "Später erledigen" : "Weiter") {
                    if state.step == 0 { s.myName = s.myName.trimmingCharacters(in: .whitespaces) }
                    withAnimation(.easeOut(duration: 0.15)) { state.step += 1 }
                }
                .buttonStyle(HubBlackButton(height: 38))
            } else {
                Button("Später") { finish(openTraining: false) }.buttonStyle(HubSoftButton(height: 38))
                Button("Zum Training") { finish(openTraining: true) }.buttonStyle(HubBlackButton(height: 38))
            }
        }
    }

    private var divider: some View { Rectangle().fill(VF.hairline).frame(height: 1) }

    private func field(_ label: String, text: Binding<String>, placeholder: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(VF.ink)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.system(size: 16))
                .padding(.horizontal, 12).frame(height: 40)
                .background(VF.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(VF.hairline))
            Text(hint).font(.system(size: 12)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ok == nil → nur Hinweis (kein prüfbarer Zustand)
    private func permRow(_ title: String, _ detail: String, _ ok: Bool?, _ button: String, okText: String = "Erteilt",
                         action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : (ok == nil ? "info.circle" : "circle"))
                .font(.system(size: 18)).foregroundStyle(ok == true ? VF.teal1 : VF.muted.opacity(0.8)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(VF.ink)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(VF.muted)
            }
            Spacer()
            if ok == true {
                Text(okText).font(.system(size: 13, weight: .medium)).foregroundStyle(VF.teal1)
            } else {
                Button(button, action: action).buttonStyle(HubOutlineButton(height: 30))
            }
        }
        .frame(height: 54)
    }

    private func finish(openTraining: Bool) {
        let st = OnboardingState.shared
        guard !st.forceVisible else { return }
        if s.myName.trimmingCharacters(in: .whitespaces).isEmpty { s.myName = Identity.systemFirstName }
        s.onboardingDone = true
        s.save()
        (NSApp.delegate as? AppDelegate)?.onboardingFinished()
        if openTraining { VFHub.shared.go(.training) }
        HubSetupState.shared.refresh()
    }
}

// MARK: - CLI: Einrichtung prüfen / Modelle vorladen / Willkommen rendern

enum OnboardingCLI {
    static func run(_ args: [String]) -> Int32? {
        switch args[1] {
        case "--version":
            print(AppVersion.line); return 0
        case "--setup-status":
            // Nur lesen – für setup.sh --check
            for r in SetupCheck.report() {
                print("\(r.ok ? "ok     " : (r.optional ? "optional" : "fehlt  "))  \(r.name) – \(r.hint)")
            }
            print("Daten-Ordner: \(Paths.baseDisplay) (\(Settings.shared.isFreshInstall ? "neu" : "vorhanden"))")
            let st = Settings.shared
            print("Name: \(Identity.myName) · Partner: \(Identity.partnerName ?? "–") · Wörterbuch: \(st.dictionary.count) Einträge · Sprache: \(st.languageMode.rawValue) · Willkommen: \(st.onboardingDone ? "erledigt" : "offen")")
            return 0
        case "--prewarm-models":
            return prewarm(includeDiarizer: !args.contains("--ohne-meeting"))
        case "--render-onboarding":
            return render(dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "vf_onboarding")
        default: return nil
        }
    }

    /// Lädt Parakeet, CAM++ und (optional) die Sprechertrennung herunter und kompiliert sie einmal (Core ML).
    private static func prewarm(includeDiarizer: Bool) -> Int32 {
        var code: Int32 = 0
        var done = false
        Task {
            do {
                let t0 = Date()
                print("Parakeet Ultra (Diktat) …"); fflush(stdout)
                try await Transcriber.shared.load()
                print("CAM++ (Stimmprofil) …"); fflush(stdout)
                _ = try await CampPlusEmbedder.load()
                if includeDiarizer {
                    print("Sprechertrennung (Meetings) …"); fflush(stdout)
                    try await Diarizer.shared.prepare()
                }
                print(String(format: "Modelle bereit in %.0f s → %@", Date().timeIntervalSince(t0), SetupCheck.fluidModels.path))
            } catch {
                print("Fehler beim Modell-Laden: \(error.localizedDescription)"); code = 1
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }

    /// Sichtprüfung: alle Schritte als PNG (Settings werden NICHT geändert)
    private static func render(dir: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        VF.registerFonts()
        AppDelegate.registerHubPages()
        // Sichtprüfung schreibt nie in die echte Statistik (wie --render-hub)
        VFStats.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("vf-statistik-onboarding.json")
        try? FileManager.default.removeItem(at: VFStats.fileURL)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let st = OnboardingState.shared
        st.forceVisible = true
        let size = NSSize(width: 1320, height: 860)
        var shots: [(String, () -> Void)] = (0..<OnboardingState.steps).map { i in ("onboarding_\(i + 1)", { CVHubState.shared.mode = .flow; st.step = i }) }
        // Danach: Hub ohne Schicht (Einrichtungs-Karte, Begrüßung, Geteilt-Seite) – so sieht ein neuer Benutzer ihn
        shots.append(("hub_diktat_neu", { st.forceVisible = false; OnboardingState.hidden = true; VFHub.shared.section = .diktat }))
        shots.append(("hub_einstellungen_allgemein", { VFHub.shared.openSettings("general"); VFHub.shared.showSettings = true }))
        shots.append(("hub_training_neu", { VFHub.shared.showSettings = false; VFHub.shared.section = .training }))
        shots.append(("hub_clipvault_geteilt", { CVHubState.shared.mode = .clipvault; CVHubState.shared.section = .geteilt }))
        // Einstellungen „Allgemein“ komplett (ohne Scrollen): Name, Partner, Über Flow
        shots.append(("settings_allgemein_voll", { VFHub.shared.showSettings = false; CVHubState.shared.mode = .flow; VFSettingsModal.maxHeight = 1750 }))
        for (name, setup) in shots {
            setup()
            let full = name == "settings_allgemein_voll"
            let sz = full ? NSSize(width: 1271, height: 1750) : size
            let v: NSView = full
                ? NSHostingView(rootView: VFSettingsModal(section: .general, onClose: {}).frame(width: 1271, height: 1750))
                : NSHostingView(rootView: VFHubView())
            v.frame = NSRect(origin: .zero, size: sz)
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: sz), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = v
            for _ in 0..<8 { v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
            win.close()
        }
        return 0
    }
}

extension OnboardingState {
    /// Nur Sichtprüfung: Schicht ausblenden, obwohl onboardingDone noch false ist
    static var hidden = false
    static func shouldShow(_ s: Settings) -> Bool { shared.forceVisible || (!s.onboardingDone && !hidden) }
}
