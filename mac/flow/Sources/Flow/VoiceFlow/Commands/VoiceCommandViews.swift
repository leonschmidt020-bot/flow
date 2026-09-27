import SwiftUI

// MARK: - Einstellungen → Diktat → Karte „Sprachbefehle“
//
// Einbinden in SettingsModal.swift (DictationSection):   SCard(caption: "Sprachbefehle") { VoiceCommandSettingsRows() }

struct VoiceCommandSettingsRows: View {
    @ObservedObject var vc = VoiceCommands.shared

    var body: some View {
        VStack(spacing: 0) {
            PGSettingRow(title: "Sprachbefehle",
                         detail: "Am Anfang eines Diktats: „Schick \(Identity.partnerName ?? "…"): …“, „Erinner mich …“, „Termin …“, „Notiz: …“. Mitten im Satz passiert nichts.") {
                toggle(\.enabled)
            }
            line
            PGSettingRow(title: "Vorher bestätigen",
                         detail: "Karte an der Pille vor Termin, Erinnerung und Schicken. Führt nach \(Int(vc.prefs.confirmSeconds)) s selbst aus – Maus drauf hält an, ✕ bricht ab.") {
                toggle(\.confirm).disabled(!vc.prefs.enabled).opacity(vc.prefs.enabled ? 1 : 0.45)
            }
            line
            PGSettingRow(title: "Wartezeit der Karte", detail: "\(Int(vc.prefs.confirmSeconds)) Sekunden") {
                PGChoiceMenu(selection: Binding(get: { Int(vc.prefs.confirmSeconds) }, set: { vc.prefs.confirmSeconds = Double($0) }),
                             options: [3, 4, 6, 10], label: { "\($0) Sekunden" })
                    .disabled(!vc.prefs.enabled || !vc.prefs.confirm)
            }
            line
            PGSettingRow(title: "Websuche", detail: "„Such nach …“ / „Search for …“ öffnet die Suche im Standard-Browser.") {
                toggle(\.search).disabled(!vc.prefs.enabled).opacity(vc.prefs.enabled ? 1 : 0.45)
            }
        }
    }

    private var line: some View { Rectangle().fill(VF.hairline).frame(height: 1) }

    private func toggle(_ kp: WritableKeyPath<VCPrefs, Bool>) -> some View {
        Toggle("", isOn: Binding(get: { vc.prefs[keyPath: kp] }, set: { vc.prefs[keyPath: kp] = $0 }))
            .toggleStyle(.switch).labelsHidden().tint(VF.black)
    }
}

// MARK: - Hilfe-Seite: Abschnitt „Sprachbefehle“
//
// Einbinden in HubHilfePage.swift (nach der Karte „Tastenkürzel“):   VoiceCommandsHelpSection().padding(.bottom, 40)

struct VoiceCommandsHelpSection: View {
    @ObservedObject var vc = VoiceCommands.shared

    private var partner: String { Identity.partnerName ?? "Partner" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HubLabel("Sprachbefehle")
                Spacer()
                Text(vc.prefs.enabled ? (vc.prefs.confirm ? "an · mit Bestätigung" : "an · ohne Bestätigung") : "aus – in den Einstellungen einschalten")
                    .font(.system(size: 12.5)).foregroundStyle(VF.muted)
            }
            .padding(.bottom, 12)
            VStack(spacing: 0) {
                row("paperplane", "„Schick \(partner): …“", "„Sende an \(partner) …“ · „Send \(partner) …“",
                    "Schickt den Rest in euren geteilten Tresor. Ohne Verbindung landet er in der Zwischenablage.")
                divider
                row("bell", "„Erinner mich morgen um 9 an …“", "„… in 2 Stunden …“ · „… am Freitag …“ · „Remind me …“",
                    "Legt eine Erinnerung mit Fälligkeit an.")
                divider
                row("calendar", "„Termin Freitag 14 Uhr mit Pierre“", "„Kalender: …“ · „… für eine Stunde“ · „New event …“",
                    "Trägt einen Termin ein – 30 Minuten, wenn nichts anderes gesagt wird.")
                divider
                row("doc.text", "„Notiz: …“", "„Note: …“ · „Note to self …“", "Legt eine neue Notiz im Scratchpad an.")
                if vc.prefs.search {
                    divider
                    row("magnifyingglass", "„Such nach …“", "„Google mal …“ · „Search for …“", "Öffnet die Websuche im Browser.")
                }
            }
            .hubCard(VF.card, radius: 12)
            Text("Nur ganz am Anfang des Diktats. Vor Termin, Erinnerung und Schicken zeigt die Pille eine Karte: „Eintragen“ oder „Abbrechen“ – nach \(Int(vc.prefs.confirmSeconds)) s geht es von selbst, Maus drauf hält an. Versteht Flow den Befehl nicht ganz, wird der Text ganz normal eingefügt.")
                .font(.system(size: 13)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.leading, 4)
        }
    }

    private var divider: some View { Rectangle().fill(VF.hairline).frame(height: 1) }

    private func row(_ symbol: String, _ title: String, _ variants: String, _ detail: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(VF.ink)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(VF.cardSoft))
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(HubFont.bodyMedium).foregroundStyle(VF.ink)
                Text(variants).font(.system(size: 13)).foregroundStyle(VF.ink.opacity(0.62))
                Text(detail).font(.system(size: 13.5)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
