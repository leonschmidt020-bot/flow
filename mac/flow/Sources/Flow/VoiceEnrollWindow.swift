import AppKit
import SwiftUI

/// Kleines Fenster: du liest ~20 s vor, daraus entsteht dein Stimmprofil.
final class VoiceEnrollController: NSObject, NSWindowDelegate {
    static let shared = VoiceEnrollController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Flow – Stimme einlernen"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: VoiceEnrollView(model: EnrollModel()))
            w.delegate = self
            window = w
        }
        window?.centerOnMouseScreen()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        (window?.contentView as? NSHostingView<VoiceEnrollView>)?.rootView.model.cancel()
        window = nil
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

final class EnrollModel: ObservableObject {
    enum Phase: Equatable { case ready, recording, saving, done, failed(String) }
    @Published var phase: Phase = .ready
    @Published var progress: Double = 0
    @Published var level: Float = 0
    private let mic = MicCapture()
    private let buf = SampleBuffer()
    private var timer: Timer?
    let seconds: Double = 22

    func start() {
        buf.reset()
        mic.onSamples = { [weak self] s in self?.buf.append(s) }
        mic.onLevel = { [weak self] lv in DispatchQueue.main.async { self?.level = lv } }
        do { try mic.start(deviceUID: Settings.shared.micUID) } catch { phase = .failed("Mikrofon startet nicht"); return }
        phase = .recording
        progress = 0
        let t0 = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.progress = min(1, Date().timeIntervalSince(t0) / self.seconds)
            if self.progress >= 1 { t.invalidate(); self.finish() }
        }
    }

    func cancel() { timer?.invalidate(); mic.stop(); if phase == .recording { phase = .ready } }

    private func finish() {
        mic.stop()
        phase = .saving
        let samples = buf.take()
        Task {
            do {
                try await VoiceID.shared.enroll(samples)
                await MainActor.run { self.phase = .done; Settings.shared.onlyMyVoice = true }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}

struct VoiceEnrollView: View {
    @ObservedObject var model: EnrollModel

    private var script: String { """
    Hallo, ich bin \(Identity.myName). Ich spreche jetzt ein paar Sätze, damit Flow meine Stimme kennenlernt. \
    Heute arbeite ich an meinen Projekten, danach schreibe ich noch ein paar Nachrichten. \
    And now a few sentences in English: I'm recording my voice so that only I get transcribed, \
    even when music or a video is playing in the background.
    """ }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nur deine Stimme").font(.system(size: 22, weight: .semibold))
            Text("Lies den Text in normaler Lautstärke vor, so wie du sonst diktierst – am besten an deinem gewohnten Platz. Danach behält Flow beim Diktieren nur noch, was nach dir klingt: Stimmen aus Videos, Liedtexte oder jemand neben dir fliegen raus.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(script)
                .font(.system(size: 15))
                .lineSpacing(4)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            switch model.phase {
            case .ready:
                Button { model.start() } label: { Label("Aufnahme starten (22 s)", systemImage: "mic.fill").frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent)
            case .recording:
                ProgressView(value: model.progress)
                HStack {
                    Image(systemName: "waveform").foregroundStyle(.red)
                    GeometryReader { g in
                        Capsule().fill(Color.red.opacity(0.7)).frame(width: max(4, g.size.width * CGFloat(model.level)), height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }.frame(height: 10)
                    Text("\(Int((1 - model.progress) * model.seconds)) s").monospacedDigit().foregroundStyle(.secondary)
                }
            case .saving:
                HStack { ProgressView().controlSize(.small); Text("Stimmprofil wird berechnet …") }
            case .done:
                Label("Fertig – ab jetzt zählt beim Diktieren nur deine Stimme.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Nochmal aufnehmen") { model.phase = .ready }
            case .failed(let e):
                Label("Hat nicht geklappt: \(e)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Nochmal versuchen") { model.phase = .ready }
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
