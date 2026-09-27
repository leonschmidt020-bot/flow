import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Oberfläche: Ablage-Karte (Notetaker), Fortschritt in der Listenzeile, Ablage auf dem ganzen Hub, Einstellungen

/// Große Ablagefläche „Audiodatei hierher ziehen“ im Notetaker (über „Heute“).
/// Nimmt Datei-URLs UND Datei-Versprechen (Sprachmemos, Mail-Anhänge, WhatsApp) an; Text bricht um, wird nie abgeschnitten.
struct AudioImportCard: View {
    @ObservedObject var imports = AudioImport.shared
    @ObservedObject var settings = AudioImportSettings.shared
    @State private var targeted = false
    /// Nur für Render/Tests
    var forceTargeted = false

    private var hot: Bool { targeted || forceTargeted }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dropZone
            inboxLine.padding(.horizontal, 6)
            ForEach(imports.errors) { e in AudioImportErrorCard(card: e) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(hot ? VF.purple.opacity(0.14) : VF.cardSoft)
                Circle().stroke(hot ? VF.purple.opacity(0.35) : VF.hairline)
                Image(systemName: hot ? "arrow.down" : "waveform.badge.plus")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(hot ? VF.purple : VF.ink)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 54, height: 54)
            .padding(.bottom, 16)
            Group {
                if hot {
                    (Text("Loslassen – Flow ") + Text("transkribiert").italic() + Text(" die Datei."))
                } else {
                    (Text("Audiodatei ") + Text("hierher").italic() + Text(" ziehen"))
                }
            }
            .font(VF.serif(30)).foregroundStyle(hot ? VF.purple : VF.ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
            Text("Sprachmemo, MP3, M4A, WAV, WhatsApp-Sprachnachricht oder Video – Flow schreibt mit, wer was wann gesagt hat, und fasst zusammen. Alles bleibt auf dem Mac.")
                .font(.system(size: 14.5)).foregroundStyle(VF.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
                .padding(.bottom, 18)
            HStack(spacing: 12) {
                Button("Datei wählen …") { imports.pickFiles() }
                    .buttonStyle(HubBlackButton(height: 34))
                    .help("Audio- oder Videodatei auswählen (mehrere möglich)")
                    .fixedSize()
                Text("oder auf die Pille ziehen")
                    .font(.system(size: 13)).foregroundStyle(VF.muted)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 28)
        .frame(maxWidth: .infinity, minHeight: 250)
        .background(hot ? VF.purple.opacity(0.05) : VF.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(hot ? VF.purple.opacity(0.8) : VF.beige.opacity(0.9),
                              style: StrokeStyle(lineWidth: hot ? 1.8 : 1.3, dash: [7, 5]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.14), value: hot)
        .onDrop(of: AudioImportDropDelegate.types, delegate: AudioImportDropDelegate(targeted: $targeted, openNotetaker: false))
    }

    private var inboxLine: some View {
        // Breit: eine Zeile; schmal (kleines Fenster): Knöpfe unter den Text – nie abgeschnitten
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                inboxIcon
                inboxText.fixedSize()
                Spacer(minLength: 8)
                inboxActions
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                inboxIcon
                VStack(alignment: .leading, spacing: 6) {
                    inboxText.fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) { inboxActions; Spacer(minLength: 0) }
                }
            }
        }
    }

    private var inboxIcon: some View {
        Image(systemName: settings.inboxEnabled ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
            .font(.system(size: 12)).foregroundStyle(settings.inboxEnabled ? VF.teal1 : VF.muted)
    }

    private var inboxText: some View {
        Group {
            if settings.inboxEnabled {
                Text("Eingangsordner an: ") + Text(settings.inboxDisplay).foregroundColor(VF.ink.opacity(0.8))
                    + Text(" – fertige Dateien wandern nach „Erledigt“.")
            } else {
                Text("Eingangsordner: ") + Text(settings.inboxDisplay).foregroundColor(VF.ink.opacity(0.8))
                    + Text(" – was dort landet, wird automatisch transkribiert.")
            }
        }
        .font(.system(size: 13)).foregroundStyle(VF.muted)
    }

    @ViewBuilder private var inboxActions: some View {
        if imports.waiting.count > 0 {
            Text(imports.waiting.count == 1 ? "1 Datei wartet" : "\(imports.waiting.count) Dateien warten")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(VF.muted)
                .padding(.horizontal, 8).frame(height: 22)
                .background(VF.cardSoft, in: Capsule())
                .fixedSize()
        }
        Group {
            if settings.inboxEnabled {
                Button("Im Finder zeigen") {
                    AudioImport.shared.inbox?.ensureFolders()
                    NSWorkspace.shared.open(settings.inboxURL)
                }
            } else {
                Button("Einschalten") { settings.inboxEnabled = true }
            }
        }
        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(VF.ink)
        .fixedSize()
    }
}

/// Freundliche Fehlerkarte (z. B. beschädigte Datei)
struct AudioImportErrorCard: View {
    let card: AudioImport.ErrorCard
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14)).foregroundStyle(Color(red: 0.80, green: 0.45, blue: 0.10))
                .frame(width: 30, height: 30)
                .background(Color(red: 0.99, green: 0.93, blue: 0.84), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(card.fileName).font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.ink).lineLimit(1).truncationMode(.middle)
                Text(card.message).font(.system(size: 13)).foregroundStyle(VF.muted).fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button("Andere Datei …") { AudioImport.shared.pickFiles() }
                .buttonStyle(HubOutlineButton(height: 28)).font(.system(size: 12.5, weight: .medium))
                .fixedSize()
            HubIconButton(symbol: "xmark", size: 11, color: VF.muted, help: "Ausblenden") {
                withAnimation(.easeOut(duration: 0.15)) { AudioImport.shared.dismissError(card) }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 11)
        .background(Color(red: 1.0, green: 0.975, blue: 0.945), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(red: 0.95, green: 0.84, blue: 0.70)))
    }
}

// MARK: - Listenzeile: Wasser-Fortschritt + Abbrechen

// Wasser-Zeichnung + geglätteter Pegel: siehe AudioWater.swift (`AudioWaterFill`, `AudioWaterLive`, `AudioProgressSmoother`).

/// Symbol-Kachel links in der Zeile: füllt sich von unten nach oben mit Wasser, solange die Datei läuft.
struct AudioImportTileWater: View {
    let meetingID: String
    @ObservedObject var imports = AudioImport.shared
    /// Nur Render: fester Pegel + feste Zeit
    var renderFraction: Double?
    var body: some View {
        if let f = renderFraction {
            AudioWaterFill(fraction: f, axis: .up, cornerRadius: 8, inset: 1, time: 0.7)
                .opacity(0.55).allowsHitTesting(false)
        } else if let l = imports.live[meetingID], imports.runningID == meetingID {
            AudioWaterLive(meetingID: meetingID, live: l, axis: .up, cornerRadius: 8, inset: 1)
                .opacity(0.55)   // Symbol bleibt lesbar
                .allowsHitTesting(false)
        }
    }
}

/// Unter dem Untertitel: schmaler Wasser-Balken + Restzeit (Prozent steht schon im Untertitel).
struct AudioImportRowProgress: View {
    let meetingID: String
    @ObservedObject var imports = AudioImport.shared
    /// Nur Render
    var time: Double?

    var body: some View {
        if let l = imports.live[meetingID], imports.runningID == meetingID {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    Capsule().fill(AudioWater.surfaceColor.opacity(0.14))
                    if let time {
                        AudioWaterFill(fraction: l.fraction, axis: .right, time: time)
                    } else {
                        AudioWaterLive(meetingID: meetingID, live: l, axis: .right)
                    }
                }
                .frame(width: 220, height: 6)
                let d = AudioImportRowProgress.detail(l, waiting: false)
                if !d.isEmpty {
                    Text(d).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(VF.muted).lineLimit(1).fixedSize()
                }
            }
            .padding(.top, 1)
        }
    }

    /// Nur die Restzeit
    static func detail(_ l: AudioImport.Live, waiting: Bool) -> String {
        guard !waiting, let eta = l.eta, eta >= 1 else { return "" }
        return eta < 60 ? "noch \(Int(eta.rounded())) s" : "noch ~\(Int((eta / 60).rounded(.up))) Min."
    }
}

/// Rechts in der Zeile: „Abbrechen“ solange eine Datei läuft/wartet (ersetzt die Hover-Knöpfe).
struct AudioImportRowCancel: View {
    let meetingID: String
    @ObservedObject var imports = AudioImport.shared
    var body: some View {
        if imports.live[meetingID] != nil {
            Button("Abbrechen") { imports.cancel(meetingID) }
                .buttonStyle(HubOutlineButton(height: 28)).font(.system(size: 12.5, weight: .medium))
                .help("Auswertung abbrechen – der Zwischenstand bleibt, „Neu auswerten“ setzt fort")
        }
    }
}

// MARK: - Ablage auf dem ganzen Hub-Fenster (URLs + Versprechen)

struct AudioImportHubDrop: ViewModifier {
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted { AudioImportDropOverlay().transition(.opacity).allowsHitTesting(false) }
            }
            .animation(.easeOut(duration: 0.14), value: targeted)
            .onDrop(of: AudioImportDropDelegate.types, delegate: AudioImportDropDelegate(targeted: $targeted, openNotetaker: true))
    }
}

extension View {
    /// Audio-/Videodateien auf diese Fläche ziehen → transkribieren
    func audioImportDropTarget() -> some View { modifier(AudioImportHubDrop()) }
}

/// Großer, ruhiger Hinweis über dem Hub, solange eine Datei darüber schwebt
struct AudioImportDropOverlay: View {
    var body: some View {
        ZStack {
            VF.panel.opacity(0.86)
            VStack(spacing: 14) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(VF.purple)
                    .symbolRenderingMode(.hierarchical)
                (Text("Loslassen – Flow ") + Text("transkribiert").italic() + Text(" die Datei."))
                    .font(VF.serif(34)).foregroundStyle(VF.ink)
                Text("MP3, M4A, WAV, FLAC, WhatsApp-Sprachnachricht (Opus) oder Video · bleibt auf dem Mac")
                    .font(HubFont.body).foregroundStyle(VF.muted)
            }
            .padding(.horizontal, 60).padding(.vertical, 44)
            .background(VF.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(VF.purple.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
            .shadow(color: .black.opacity(0.08), radius: 24, y: 8)
        }
    }
}

// MARK: - Einstellungen → Notetaker → „Audiodateien“

struct AudioImportSettingsRows: View {
    @ObservedObject var s = AudioImportSettings.shared

    var body: some View {
        PGSettingRow(title: "Eingangsordner beobachten",
                     detail: "Alles, was du in \(s.inboxDisplay) legst, wird automatisch transkribiert und danach nach „Erledigt“ verschoben – nie gelöscht.") {
            HStack(spacing: 10) {
                if s.inboxEnabled {
                    Button("Im Finder zeigen") {
                        AudioImport.shared.inbox?.ensureFolders()
                        NSWorkspace.shared.open(s.inboxURL)
                    }
                    .buttonStyle(HubSoftButton(height: 30)).font(.system(size: 13, weight: .medium))
                }
                AudioImportSwitch(isOn: $s.inboxEnabled)
            }
        }
        PGSettingRow(title: "Namen und Sprachwechsel mit Whisper nachhören",
                     detail: "Parakeet schreibt die ganze Datei, Whisper hört Stellen mit Wörterbuch-Namen und fremdsprachig wirkende Stellen noch einmal (nur Deutsch/Englisch, höchstens ein Drittel der Länge).") {
            AudioImportSwitch(isOn: $s.whisperAssist)
        }
        PGSettingRow(title: "Meldung, wenn eine Datei fertig ist", detail: "Karte an der Pille mit „Öffnen“.") {
            AudioImportSwitch(isOn: $s.notifyWhenDone)
        }
        PGSettingRow(title: "Öffnen mit …", detail: "Im Finder: Rechtsklick auf eine Audio- oder Videodatei → Öffnen mit → Flow. Oder die Datei auf die Pille ziehen.") { EmptyView() }
    }
}

struct AudioImportSwitch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(VF.black) }
}
