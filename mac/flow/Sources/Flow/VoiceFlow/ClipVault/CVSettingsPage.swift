import AppKit
import SwiftUI

// MARK: - ClipVault-Einstellungen

struct CVSettingsPage: View {
    @ObservedObject var cv = ClipVaultClient.shared
    @ObservedObject var shared = CVShared.shared
    @State private var status = ClipVaultClient.shared.status()
    @State private var aiApps: [String] = []
    @State private var newApp = ""
    @State private var openButton: Int?
    @State private var learning = false
    @State private var monitor: Any?
    @State private var syncURL = ""
    @State private var syncURLSaved = ""
    @State private var initSecret = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Einstellungen").font(HubFont.title).foregroundStyle(VF.ink).padding(.bottom, 26)

                CVSettingsCard(caption: "Verlauf") {
                    CVSettingRow(title: "Aufbewahrung",
                                 detail: "Zwei Tage, höchstens 200 Einträge. Angeheftetes und alles in Bereichen bleibt, bis du es löschst.") {
                        Text("\(cv.items.count) / 200").font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(VF.ink)
                    }
                    CVSettingRow(title: "Dauerhaft gespeichert",
                                 detail: "\(cv.items.filter(\.pinned).count) angeheftet · \(cv.items.filter { $0.collection != nil }.count) in \(cv.collections.count) Bereichen") {
                        Button("Bereiche") { CVHubState.shared.go(.bereiche) }.buttonStyle(HubSoftButton())
                    }
                }

                CVSettingsCard(caption: "Öffnen") {
                    CVSettingRow(title: "Tastenkürzel", detail: "Öffnet ClipVault über jeder App, dort wo die Maus ist.") {
                        HStack(spacing: 5) { HubKeycap("⌘"); HubKeycap("⇧"); HubKeycap("V") }
                    }
                    CVSettingRow(title: "Maustaste",
                                 detail: learning ? "Drück jetzt die Maustaste, die ClipVault öffnen soll …"
                                                  : (openButton.map { "Taste Nr. \($0) öffnet ClipVault (\(Self.buttonName($0)))." } ?? "Keine Maustaste festgelegt.")) {
                        if learning {
                            Button("Abbrechen") { stopLearning() }.buttonStyle(HubSoftButton())
                        } else {
                            Button("Neu festlegen") { startLearning() }.buttonStyle(HubSoftButton())
                        }
                    }
                }

                CVSettingsCard(caption: "KI-Erkennung") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Apps, deren Kopien als „von KI“ gelten").font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                            Text("Kennung oder App-Name, Teiltreffer genügt. Wirkt sofort, ohne Neustart.")
                                .font(.system(size: 13)).foregroundStyle(VF.muted)
                        }
                        PGFlow(spacing: 7, lineSpacing: 7) {
                            ForEach(aiApps, id: \.self) { a in
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles").font(.system(size: 10.5)).foregroundStyle(CVPalette.ai)
                                    Text(a).font(.system(size: 13, weight: .medium)).foregroundStyle(VF.ink)
                                    Button { remove(a) } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(VF.muted)
                                    }
                                    .buttonStyle(.plain).help("Entfernen")
                                }
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(VF.card, in: Capsule())
                                .overlay(Capsule().stroke(VF.hairline))
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("App hinzufügen, z. B. perplexity", text: $newApp)
                                .textFieldStyle(.plain).font(.system(size: 14))
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(VF.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VF.hairline))
                                .onSubmit(add)
                                .frame(maxWidth: 320)
                            Button("Hinzufügen", action: add).buttonStyle(HubBlackButton(height: 32)).disabled(newApp.pgTrimmed.isEmpty)
                        }
                    }
                    .padding(.vertical, 18)
                }

                CVSettingsCard(caption: "Teilen") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sync-Server (dein eigener Cloudflare Worker)").font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                            Text(syncURLSaved.isEmpty
                                 ? "Aus – Teilen ist optional. Einrichten in 5 Minuten: mac/clipvault/sync-worker/README.md (npx wrangler deploy), dann die URL hier einfügen."
                                 : "Eingetragen: \(syncURLSaved) – Inhalte sind Ende-zu-Ende verschlüsselt, der Server sieht nur Chiffrat.")
                                .font(.system(size: 13)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            TextField("https://flow-clipvault-sync.<dein-konto>.workers.dev", text: $syncURL)
                                .textFieldStyle(.plain).font(.system(size: 14))
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(VF.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VF.hairline))
                                .onSubmit(saveSyncURL)
                                .frame(maxWidth: 420)
                            Button("Speichern", action: saveSyncURL).buttonStyle(HubBlackButton(height: 32))
                                .disabled(!syncURL.pgTrimmed.lowercased().hasPrefix("https://"))
                        }
                        SecureField("Init-Geheimnis (INIT_SECRET deines Workers – nur zum Anlegen des Tresors)", text: $initSecret)
                            .textFieldStyle(.plain).font(.system(size: 14))
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(VF.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(VF.hairline))
                            .onSubmit(saveSyncURL)
                            .frame(maxWidth: 420)
                    }
                    .padding(.vertical, 18)
                    CVSettingRow(title: "Geteilt mit \(Identity.partner(.dative))", detail: shared.status.label) {
                        if shared.status.isConnected {
                            Button("Trennen") { shared.unpair() }.buttonStyle(HubSoftButton())
                        } else {
                            Button("Verbinden") { CVHubState.shared.go(.geteilt) }.buttonStyle(HubBlackButton())
                        }
                    }
                }

                CVSettingsCard(caption: "ClipVault") {
                    CVSettingRow(title: status.running ? "Läuft" : "Läuft nicht",
                                 detail: status.since.map { "Seit \(HubFormat.date($0, "d. MMMM, HH:mm")) · Tastenkürzel \(status.hotkeyOK ? "aktiv" : "fehlt")" }
                                    ?? "ClipVault startet automatisch mit dem Mac.") {
                        Circle().fill(status.running ? CVPalette.green : VF.orange).frame(width: 10, height: 10).padding(.trailing, 8)
                    }
                    CVSettingRow(title: "Verbindung zum Hub",
                                 detail: cv.canSendCommands ? "Befehlskanal bereit – Anheften, Löschen und Bereiche wirken sofort."
                                                            : "Noch kein Befehlskanal – der Hub kann nur lesen und kopieren.") {
                        Label(cv.canSendCommands ? "Bereit" : "Nur lesen", systemImage: cv.canSendCommands ? "checkmark.circle.fill" : "eye")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(cv.canSendCommands ? Color(red: 0.18, green: 0.55, blue: 0.34) : VF.muted)
                    }
                    CVSettingRow(title: "Speicherort", detail: "~/.config/flow-clipvault – nur auf diesem Mac.") {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([ClipVaultClient.base]) }
                            .buttonStyle(HubSoftButton())
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .onAppear { loadAIApps(); loadButton(); status = cv.status(); loadSyncURL() }
        .onDisappear(perform: stopLearning)
    }

    // MARK: Sync-Server (sync.json › url, gesetzt über ClipVaults Befehl „syncSetup“ – Standard: aus)

    private func loadSyncURL() {
        let url = ClipVaultClient.base.appendingPathComponent("sync.json")
        let o = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        syncURLSaved = (o?["url"] as? String) ?? ""
        if syncURL.isEmpty { syncURL = syncURLSaved }
    }

    private func saveSyncURL() {
        let u = syncURL.pgTrimmed
        guard u.lowercased().hasPrefix("https://") else { return }
        var extra: [String: Any] = ["url": u]
        if !initSecret.pgTrimmed.isEmpty { extra["initSecret"] = initSecret.pgTrimmed }
        initSecret = ""
        ClipVaultClient.shared.send("syncSetup", extra: extra, onError: { err in
            ClipVaultClient.shared.show(CVToast(text: "Sync-Server: \(err)", symbol: "exclamationmark.triangle", isError: true))
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { loadSyncURL() }
    }

    // MARK: KI-Apps (ai-apps.txt, Kommentare bleiben erhalten)

    private func loadAIApps() {
        let s = (try? String(contentsOf: cv.aiAppsURL, encoding: .utf8)) ?? ""
        aiApps = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func saveAIApps() {
        let old = (try? String(contentsOf: cv.aiAppsURL, encoding: .utf8)) ?? ""
        let header = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).prefix { $0.hasPrefix("#") }
        let out = (header + aiApps).joined(separator: "\n") + "\n"
        do { try out.write(to: cv.aiAppsURL, atomically: true, encoding: .utf8) }
        catch { cv.show(CVToast(text: "Konnte ai-apps.txt nicht speichern", symbol: "exclamationmark.triangle", isError: true)) }
    }

    private func add() {
        let a = newApp.pgTrimmed.lowercased()
        guard !a.isEmpty, !aiApps.contains(a) else { newApp = ""; return }
        withAnimation(.easeOut(duration: 0.15)) { aiApps.append(a) }
        newApp = ""
        saveAIApps()
    }

    private func remove(_ a: String) {
        withAnimation(.easeOut(duration: 0.15)) { aiApps.removeAll { $0 == a } }
        saveAIApps()
    }

    // MARK: Maustaste (openbutton.txt – ClipVault liest sie bei jedem Klick neu)

    private var buttonURL: URL { ClipVaultClient.base.appendingPathComponent("openbutton.txt") }

    static func buttonName(_ n: Int) -> String {
        switch n {
        case 2: return "Mausrad-Klick"
        case 3: return "Seitentaste hinten"
        case 4: return "Seitentaste vorne"
        default: return "Zusatztaste"
        }
    }

    private func loadButton() {
        openButton = (try? String(contentsOf: buttonURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func startLearning() {
        learning = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { e in
            let n = e.buttonNumber
            try? "\(n)".write(to: buttonURL, atomically: true, encoding: .utf8)
            openButton = n
            cv.show(CVToast(text: "Taste Nr. \(n) öffnet jetzt ClipVault", symbol: "computermouse"))
            stopLearning()
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if learning { stopLearning() } }
    }

    private func stopLearning() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        learning = false
    }
}

struct CVSettingsCard<Content: View>: View {
    var caption: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubLabel(caption).padding(.leading, 4)
            _VariadicView.Tree(CVDividedLayout()) { content() }
                .padding(.horizontal, 22)
                .background(RoundedRectangle(cornerRadius: VF.cardRadius, style: .continuous).fill(VF.cardSoft))
        }
        .padding(.bottom, 26)
    }
}

struct CVDividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != children.last?.id { Rectangle().fill(VF.hairline).frame(height: 1) }
            }
        }
    }
}

struct CVSettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 13)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 17)
    }
}
