import AppKit
import SwiftUI

// MARK: - Hilfe: Tastenkürzel + Tipps + Sprünge in die Einstellungen

struct HubHilfePage: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var hub = VFHub.shared

    private var key: String {
        switch settings.hotkey {
        case .fn: return "fn"
        case .rightOption: return "⌥ rechts"
        case .rightCommand: return "⌘ rechts"
        case .rightControl: return "⌃ rechts"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Hilfe").font(HubFont.title).foregroundStyle(VF.ink).padding(.bottom, 25)

                HubBanner(image: "banner_diktat",
                          headline: Text("So \(Text("sprichst").font(VF.serif(33, italic: true))) du mit Flow."),
                          sub: "Alles läuft lokal auf deinem Mac – ohne Wortlimit, ohne Cloud.") {
                    Button("Einstellungen öffnen") { hub.openSettings() }.buttonStyle(HubBannerButton())
                }
                .padding(.bottom, 44)

                HubLabel("Tastenkürzel").padding(.bottom, 12)
                VStack(spacing: 0) {
                    row([key], "halten, sprechen, loslassen", "Der Text erscheint da, wo dein Cursor steht.")
                    divider
                    row([key, key], "doppelt tippen", "Freihändig sprechen – nochmal tippen beendet das Diktat.")
                    divider
                    row(["esc"], "Diktat abbrechen", "Nichts wird eingefügt.")
                    divider
                    row(["⌃", "⌥", "M"], "Meeting aufnehmen oder beenden", "Die Mitschrift landet im Notetaker.")
                    divider
                    row(["🌐"], "Sprache wählen", "Maus über die Pille → Weltkugel: Deutsch, Englisch oder beides (jetzt: \(settings.languageMode.short)).")
                    divider
                    row(["✎"], "Wort korrigieren → merken", "Korrigierst du ein diktiertes Wort, fragt die Pille „merken?“ – ab dann schreibt Flow es richtig.")
                }
                .hubCard(VF.card, radius: 12)
                .padding(.bottom, 40)

                VoiceCommandsHelpSection().padding(.bottom, 40)

                HubLabel("Weiter").padding(.bottom, 12)
                HStack(spacing: 16) {
                    tile("gearshape", "Einstellungen", "Kürzel, Mikrofon, Sprache") { hub.openSettings() }
                    tile("person.wave.2", "Stimme einlernen", "Nur deine Stimme zählt") { VoiceFlowWindow.shared.show(.training) }
                    tile("text.book.closed", "Wörterbuch", "Namen & Fachbegriffe") { hub.go(.woerterbuch) }
                    tile("record.circle", "Notetaker", "Meetings mitschreiben") { hub.go(.notetaker) }
                }
            }
            .hubPage()
        }
    }

    private var divider: some View { Rectangle().fill(VF.hairline).frame(height: 1) }

    private func row(_ keys: [String], _ title: String, _ detail: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 5) { ForEach(keys.indices, id: \.self) { HubKeycap(keys[$0]) } }
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                Text(detail).font(.system(size: 13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
    }

    private func tile(_ symbol: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(VF.ink)
                Text(title).font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                Text(sub).font(.system(size: 12.5)).foregroundStyle(VF.muted).lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hubCard(VF.cardSoft, radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
