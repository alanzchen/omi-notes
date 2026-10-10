import OmiBLE
import OmiProtocol
import SwiftUI

/// The pendant's own settings (light, microphone level) and Find, as in the Omi app. Values shown
/// are the ones read back from the pendant on this connection; a change in progress says so, and
/// nothing can be changed while it is disconnected.
struct PendantControlsSection: View {
    let model: AppModel
    let controls: PendantControlsModel

    var body: some View {
        let s = model.snapshot
        Section {
            if s.connection != .streaming || s.device == nil {
                Label("Connect the pendant to change its light or microphone level, or to find it.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let d = s.device, !d.controlsKnown {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the pendant's settings…").foregroundStyle(.secondary)
                }
            } else if let d = s.device {
                if d.settingsSupported.contains(.ledBrightness) {
                    LightRow(reported: d.settings[.ledBrightness], status: controls.status(of: .ledBrightness)) {
                        controls.change(.ledBrightness, to: $0)
                    }
                } else {
                    unsupported("Light brightness", d)
                }
                if d.settingsSupported.contains(.micGain) {
                    MicrophoneRow(reported: d.settings[.micGain], status: controls.status(of: .micGain)) {
                        controls.change(.micGain, to: $0)
                    }
                } else {
                    unsupported("Microphone level", d)
                }
                if d.canVibrate {
                    FindRow(status: controls.find) { controls.findPendant() }
                } else {
                    unsupported("Find pendant", d)
                }
            }
        } header: {
            Text("On the pendant")
        } footer: {
            Text("Saved on the pendant itself and read back from it, so it keeps them after reconnecting.")
        }
    }

    private func unsupported(_ title: String, _ d: DeviceSession.Info) -> some View {
        LabeledContent(title) {
            Text("Not on this pendant\(d.firmwareRevision.map { " (firmware \($0))" } ?? "")").foregroundStyle(.secondary)
        }
    }
}

/// "Light 50%" and a slider; the change is sent when the slider is let go.
private struct LightRow: View {
    let reported: Int?
    let status: PendantControlsModel.Status
    var onChange: (Int) -> Void
    /// Only while the slider is being dragged; afterwards the row shows the pendant's value again.
    @State private var draft: Double?
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Light brightness") {
                Text(valueText).monospacedDigit().foregroundStyle(reported == nil ? .secondary : .primary)
            }
            if reported != nil {
                HStack(spacing: 10) {
                    Image(systemName: "light.min").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: sliderValue, in: 0...100, step: 5, onEditingChanged: editingChanged)
                        .disabled(isSaving)
                        .accessibilityLabel("Light brightness")
                        .accessibilityValue(valueText)
                    Image(systemName: "light.max").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            StatusLine(status: status, reportedText: reported.map(Self.text), unknownHint: "Reconnect the pendant to read it again.")
        }
        .padding(.vertical, 2)
        // Whatever the drag left behind, once the pendant has answered the row shows its value.
        .onChange(of: status) { _, new in
            if case .saving = new { return }
            draft = nil
            dragging = false
        }
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { dragging ? draft ?? Double(reported ?? 0) : Double(reported ?? 0) }, set: { value in
            if dragging {
                draft = value
            } else if !isSaving, Int(value) != reported {
                onChange(Int(value))  // adjusted without a drag (VoiceOver); a late update after a drag is ignored
            }
        })
    }

    /// Sent once, when the slider is let go.
    private func editingChanged(_ editing: Bool) {
        dragging = editing
        guard !editing, let value = draft else { return }
        draft = nil
        if Int(value) != reported { onChange(Int(value)) }
    }

    private var isSaving: Bool { if case .saving = status { return true } else { return false } }
    private var valueText: String {
        if dragging, let draft { return Self.text(Int(draft)) }
        return reported.map(Self.text) ?? "Unknown"
    }
    static func text(_ v: Int) -> String { v == 0 ? "Off" : "\(v)%" }
}

/// The microphone gain level (0–8). Muting asks first: the pendant would record silence.
private struct MicrophoneRow: View {
    let reported: Int?
    let status: PendantControlsModel.Status
    var onChange: (Int) -> Void
    @State private var confirmMute = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reported {
                Picker("Microphone level", selection: Binding(get: { reported }, set: { level in
                    if level == 0 { confirmMute = true } else if level != reported { onChange(level) }
                })) {
                    ForEach((0...8).reversed(), id: \.self) { level in
                        Text(Self.text(level)).tag(level)
                    }
                }
                .disabled(isSaving)
            } else {
                LabeledContent("Microphone level") { Text("Unknown").foregroundStyle(.secondary) }
            }
            StatusLine(status: status, reportedText: reported.map(Self.text), unknownHint: "Reconnect the pendant to read it again.")
            if reported == 0 {
                Label("The microphone is muted: the pendant records silence.", systemImage: "mic.slash")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Mute the pendant's microphone?", isPresented: $confirmMute, titleVisibility: .visible) {
            Button("Mute", role: .destructive) { onChange(0) }
        } message: {
            Text("Until you raise it again, the pendant records silence, both live and to its own storage.")
        }
    }

    private var isSaving: Bool { if case .saving = status { return true } else { return false } }
    static func text(_ level: Int) -> String {
        level == PendantSetting.micGain.firmwareDefault ? "\(MicGainLevel.label(level)) (default)" : MicGainLevel.label(level)
    }
}

/// Find pendant: it vibrates three times.
private struct FindRow: View {
    let status: PendantControlsModel.FindStatus
    var onFind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onFind) {
                HStack {
                    Label("Find pendant", systemImage: "dot.radiowaves.left.and.right")
                    Spacer()
                    if status == .vibrating { ProgressView() }
                }
            }
            .disabled(status == .vibrating)
            switch status {
            case .idle: Text("Vibrates the pendant three times.").font(.footnote).foregroundStyle(.secondary)
            case .vibrating: Text("Vibrating…").font(.footnote).foregroundStyle(.secondary)
            case .done: Text("The pendant vibrated three times.").font(.footnote).foregroundStyle(.secondary)
            case .failed(let why): Text("Couldn't vibrate it: \(why).").font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Saving 30%…", "Saved on the pendant", or why not (and what the pendant still has).
private struct StatusLine: View {
    let status: PendantControlsModel.Status
    let reportedText: String?
    let unknownHint: String

    var body: some View {
        Group {
            switch status {
            case .idle:
                if reportedText == nil { Text("Couldn't read it from the pendant. \(unknownHint)").foregroundStyle(.secondary) }
            case .saving:
                Text("Saving on the pendant…").foregroundStyle(.secondary)
            case .saved:
                Label("Saved on the pendant", systemImage: "checkmark").foregroundStyle(.secondary)
            case .failed(let why):
                Text("Couldn't change it: \(why). \(reportedText.map { "The pendant has \($0)." } ?? "Its current value is unknown. \(unknownHint)")")
                    .foregroundStyle(.red)
            }
        }
        .font(.footnote)
    }
}

/// What this phone does with the pendant's button (kept on the phone, like the Omi app's).
struct PendantButtonSection: View {
    let model: AppModel
    @State private var enabled = true
    @State private var doubleTap = DoubleTapAction.endConversation

    var body: some View {
        Section {
            Toggle("Button actions", isOn: Binding(get: { enabled }, set: { enabled = $0; model.engine.settings.buttonActionsEnabled = $0 }))
            Picker("Double tap", selection: Binding(get: { doubleTap }, set: { doubleTap = $0; model.engine.settings.doubleTapAction = $0 })) {
                ForEach(DoubleTapAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!enabled)
        } header: {
            Text("Pendant button")
        } footer: {
            Text(enabled ? "A single tap bookmarks the moment. Kept on this phone." : "Taps on the pendant are ignored. Kept on this phone.")
        }
        .onAppear {
            enabled = model.engine.settings.buttonActionsEnabled
            doubleTap = model.engine.settings.doubleTapAction
        }
    }
}
