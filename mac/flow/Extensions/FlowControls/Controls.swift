// Kontrollzentrum-Knopf „Bildschirm aufnehmen (Flow)“
//
// Apples Aufnahme-Knopf im Kontrollzentrum startet Apples Aufnahme, nicht die von Flow. Seit macOS 26 dürfen Apps
// eigene Steuerelemente ins Kontrollzentrum (und in die Menüleiste) legen. Dieser Knopf öffnet
// flowdictation://aufnahme → Flow zeigt an der Pille „Bildschirm aufnehmen“ (wie ⌃⌥R; läuft eine Aufnahme: Stopp).
// Gebaut von build.sh mit swiftc (kein Xcode-Projekt), liegt als FlowControls.appex in Contents/PlugIns.
// Zwei Fallen ohne Xcode-Projekt:
//  • Einstieg muss _NSExtensionMain sein (-Xlinker -e) – mit dem normalen main beendet sich die Erweiterung sofort
//    und der Knopf fehlt in „Steuerelemente bearbeiten“.
//  • Die Aktion braucht AppIntents-Metadaten (Resources/Metadata.appintents, von appintentsmetadataprocessor) –
//    ohne sie: „Encountered action intent without linkAction“, ein Druck auf den Knopf tut nichts. Darum eine EIGENE
//    Absicht statt Apples OpenURLIntent direkt; sie öffnet flowdictation:// selbst (NSWorkspace).
import AppIntents
import AppKit
import SwiftUI
import WidgetKit

struct FlowRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Bildschirm aufnehmen (Flow)"
    static let description = IntentDescription("Öffnet die Bildschirmaufnahme von Flow an der Pille.")
    // Selbst öffnen: als Rückgabe „opensIntent: OpenURLIntent(…)“ meldet macOS zwar „Action success“, öffnet die
    // Adresse aber nicht – NSWorkspace darf auch eine Sandbox-Erweiterung benutzen.
    func perform() async throws -> some IntentResult {
        let url = URL(string: "flowdictation://aufnahme")!
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        return .result()
    }
}

@main
struct FlowControls: WidgetBundle {
    var body: some Widget { FlowRecordControl() }
}

struct FlowRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.flowdictation.flow.controls.aufnahme") {
            ControlWidgetButton(action: FlowRecordingIntent()) {
                Label("Flow-Aufnahme", systemImage: "record.circle")
            }
        }
        .displayName("Bildschirm aufnehmen (Flow)")
        .description("Flow nimmt den Bildschirm unter der Maus auf – Ton wählbar, Flow selbst nicht im Video.")
    }
}
