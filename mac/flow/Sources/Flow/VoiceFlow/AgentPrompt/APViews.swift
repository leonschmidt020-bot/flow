import AppKit
import SwiftUI

// MARK: - Agent-Prompts im Hub: Einstellungen (Diktat › Agent-Prompts) + Verlauf (Scratchpad › Reiter „Agent-Prompts“)

struct APSettingsRows: View {
    @ObservedObject var flow = APFlow.shared

    /// Claude-CLI ist optional: mit ihr formuliert Claude den Prompt (Text geht über dein Claude-Konto an Anthropic),
    /// ohne sie sortiert Flow lokal nach Regeln – und schlägt bei langen Aufträgen nichts von selbst vor.
    private var howTo: String {
        let start = "Sag am Anfang „Prompt: …“, „Agent-Prompt …“ oder „Ich mache jetzt einen Prompt …“ und erzähl einfach. "
        let end = "Er landet in der Zwischenablage und unter Scratchpad › Agent-Prompts. Dein Original bleibt immer als „Diktat (Original)“ in ClipVault."
        if flow.actions.claudeAvailable() {
            return start + "Claude (\(flow.prefs.model.capitalized), Aufwand \(flow.prefs.effort)) macht daraus einen sauberen Auftrag – "
                + "dafür geht das Diktat (und bei Entwickler-Apps Fenstertitel/markierter Text) über dein Claude-Konto an Anthropic. " + end
        }
        return start + "Ohne Claude-CLI baut Flow den Prompt lokal nach Regeln (Ziel, Aufgabe, Regeln, offene Punkte – nichts geht verloren, "
            + "umformuliert wird nichts). Vorschläge bei langen Aufträgen gibt es erst mit der Claude-CLI. " + end
    }

    var body: some View {
        VStack(spacing: 0) {
            PGSettingRow(title: "Agent-Prompts", detail: flow.prefs.mode.detail) {
                PGChoiceMenu(selection: Binding(get: { flow.prefs.mode }, set: { flow.prefs.mode = $0 }),
                             options: APMode.allCases, label: { $0.label })
            }
            Rectangle().fill(VF.hairline).frame(height: 1)
            PGSettingRow(title: "So geht’s", detail: howTo) { EmptyView() }
        }
    }
}

/// Liste + Ansicht der letzten 50 Prompts (mit Original)
struct APPromptsPane: View {
    @ObservedObject var store: APStore
    @State private var showOriginal = false
    @State private var copied = false

    init(store: APStore = APStore.shared) { self.store = store }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Rectangle().fill(VF.hairline).frame(width: 1)
            detail
        }
        .onAppear { store.reload() }
        .onChange(of: store.selectedID) { showOriginal = false; copied = false }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 4) {
                if store.records.isEmpty {
                    Text("Noch keine Agent-Prompts").font(.system(size: 15)).foregroundStyle(VF.muted).padding(.top, 24)
                }
                ForEach(store.records) { r in
                    APRow(record: r, selected: r.id == store.selectedID) { store.selectedID = r.id }
                }
            }
            .padding(10)
        }
        .background(VF.panel.opacity(0.6))
    }

    @ViewBuilder private var detail: some View {
        if let r = store.record(store.selectedID) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(r.created.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13.5)).foregroundStyle(VF.muted)
                    if !r.appName.isEmpty { tag(r.appName, "app.badge") }
                    tag(r.byRules ? "nach Regeln" : APCardStyle.sourceLabel(r.source), r.byRules ? "list.bullet.indent" : "sparkles")
                    Spacer()
                    Picker("", selection: $showOriginal) {
                        Text("Prompt").tag(false)
                        Text("Original").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    PGIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: showOriginal ? "Original kopieren" : "Prompt kopieren") {
                        APFlow.shared.actions.copy(showOriginal ? r.original : r.prompt, showOriginal ? APFlow.sourceOriginal : APFlow.sourcePrompt)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    PGIconButton(symbol: "trash", help: "Prompt löschen (Original bleibt in ClipVault)", tint: Color(red: 0.75, green: 0.25, blue: 0.22)) { store.delete(r.id) }
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
                ScrollView {
                    Text(showOriginal ? r.original : r.prompt)
                        .font(showOriginal ? .system(size: 16) : .system(size: 14, design: .monospaced))
                        .lineSpacing(showOriginal ? 5 : 3)
                        .foregroundStyle(VF.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                }
            }
        } else {
            VStack(spacing: 14) {
                if let img = APCardStyle.image("illu_prompt_fertig") {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 20))
                }
                Text("Noch kein Agent-Prompt").font(.system(size: 19, weight: .semibold)).foregroundStyle(VF.ink)
                Text("Sag „Prompt: …“ und erzähl einfach los – Flow macht daraus einen sauberen Auftrag für deinen Agenten.")
                    .font(.system(size: 15)).foregroundStyle(VF.muted).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tag(_ s: String, _ symbol: String) -> some View {
        Label(s, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(VF.muted)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(VF.buttonSoft)).lineLimit(1)
    }
}

private struct APRow: View {
    let record: APRecord
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.system(size: 15, weight: .medium)).foregroundStyle(VF.ink).lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.created.formatted(.relative(presentation: .named))).foregroundStyle(VF.muted)
                    let g = record.gist
                    if g.tasks > 0 { Text("·").foregroundStyle(VF.muted); Text(g.tasks == 1 ? "1 Anforderung" : "\(g.tasks) Anforderungen").foregroundStyle(VF.muted).fixedSize() }
                    if record.byRules { Text("·").foregroundStyle(VF.muted); Text("Regeln").foregroundStyle(VF.orange) }
                }
                .font(.system(size: 12.5))
                .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? VF.selected : (hover ? VF.buttonSoft.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
