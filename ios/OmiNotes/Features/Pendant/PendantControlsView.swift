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
            } else if let d = s.device, d.controlsUnreadable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't read which settings this pendant supports, so none can be changed yet.", systemImage: "questionmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Try again") { model.engine.retryPendantControls() }
                }
                .padding(.vertical, 2)
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

/// Pausing recording and collecting the pendant's stored audio: this phone's choices, with what
/// they mean for recording said before they are made.
struct PendantRecordingSection: View {
    let model: AppModel
    @State private var confirmPause = false
    @State private var confirmManual = false

    var body: some View {
        let s = model.snapshot
        Section {
            if s.recordingPaused {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recording is paused from this phone.", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                    Text(s.connection == .streaming
                         ? "While connected, the pendant records nothing. If it disconnects, it records to its own storage as usual."
                         : "When it reconnects it won't record until you resume. While away it records to its own storage as usual.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Resume recording") { model.engine.setRecordingPaused(false) }
                        .buttonStyle(.borderedProminent).padding(.top, 2)
                }
                .padding(.vertical, 2)
            } else {
                Button("Pause recording…") { confirmPause = true }
            }
            Toggle("Collect pendant audio automatically", isOn: Binding(get: { s.autoCollect }, set: { on in
                if on { model.engine.setAutoCollect(true) } else { confirmManual = true }
            }))
            if !s.autoCollect, s.connection == .streaming, let d = s.device, d.offlineHeld {
                LabeledContent("Waiting on the pendant") {
                    Text(d.offlineUnread.map { "\($0) records" } ?? "Unknown").foregroundStyle(.secondary)
                }
                Button("Collect now") { model.engine.collectPendantAudioNow() }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text(s.autoCollect
                 ? "Audio the pendant recorded while away from this phone is collected each time it connects."
                 : "The pendant keeps what it recorded away from this phone until you collect it. When its storage is full the oldest audio is overwritten.")
        }
        .confirmationDialog("Pause recording?", isPresented: $confirmPause, titleVisibility: .visible) {
            Button("Pause", role: .destructive) { model.engine.setRecordingPaused(true) }
        } message: {
            Text("While the pendant is connected to this phone it records nothing, live or to its own storage, until you resume here (or with a double tap set to pause). If it disconnects, it records to its own storage as usual.")
        }
        .confirmationDialog("Collect pendant audio only when asked?", isPresented: $confirmManual, titleVisibility: .visible) {
            Button("Only when I ask", role: .destructive) { model.engine.setAutoCollect(false) }
        } message: {
            Text("What the pendant records away from this phone stays on it until you tap Collect now. Its storage is a ring: when it fills, the oldest audio is overwritten and lost. Notes for that time appear only after collecting, and conversations around a reconnect may be finished without it.")
        }
    }
}

/// What this phone does with the pendant's button (kept on the phone, like the Omi app's).
struct PendantButtonSection: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        let starSupported = model.serverStatus?.supportsPendantStar == true
        let options = DoubleTapAction.allCases.filter { $0 != .starConversation || starSupported || s.doubleTapAction == .starConversation }
        Section {
            Toggle("Button actions", isOn: Binding(get: { s.buttonActionsEnabled }, set: { model.engine.setButtonActions($0) }))
            Picker("Double tap", selection: Binding(get: { s.doubleTapAction }, set: { model.engine.setDoubleTapAction($0) })) {
                ForEach(options, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!s.buttonActionsEnabled)
        } header: {
            Text("Pendant button")
        } footer: {
            Text(footer(s, starSupported: starSupported))
        }
    }

    private func footer(_ s: EngineSnapshot, starSupported: Bool) -> String {
        guard s.buttonActionsEnabled else { return "Taps on the pendant are ignored. Kept on this phone." }
        var text = "A single tap bookmarks the moment. "
        switch s.doubleTapAction {
        case .endConversation: text += "A double tap ends the conversation."
        case .bookmark: text += "A double tap bookmarks too."
        case .pauseRecording: text += "A double tap pauses recording (one long buzz) or resumes it (one short buzz)."
        case .starConversation:
            text += starSupported
                ? "A double tap stars the conversation it's in, once it's finished; a second one in the same conversation un-stars it."
                : "Your server doesn't support stars yet: taps are kept and applied if it is updated within 7 days."
        }
        if !starSupported, s.doubleTapAction != .starConversation { text += " Starring needs a server update." }
        return text + " Kept on this phone."
    }
}

/// The pendant's firmware: what it runs, whether Omi has published a newer release, installing it
/// (or reinstalling the latest stable one), and how the update is going. Finished means the pendant
/// restarted and reports the new version.
struct PendantFirmwareSection: View {
    let model: AppModel
    let firmware: FirmwareModel
    @State private var confirm: FirmwareRelease?

    var body: some View {
        let s = model.snapshot
        let current = s.connection == .streaming ? s.device?.firmwareRevision : nil
        Section {
            LabeledContent("Firmware", value: current ?? "—")
            if s.firmware != .idle {
                progress(s.firmware)
            } else if firmware.prepare != .idle {
                preparing(firmware.prepare)
            } else {
                offer(s, current: current)
            }
        } header: {
            Text("Firmware")
        } footer: {
            Text("Releases come from Omi. Only the official package for that version is installed, after it's checked on this iPhone.")
        }
        .confirmationDialog(confirm.map { "Install firmware \($0.version)?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { release in
            Button("Install \(release.version)", role: .destructive) {
                Task { await firmware.install(release, current: current) }
            }
        } message: { release in
            Text("The pendant stops recording during the update (a few minutes), then restarts to install it. It can't go back to \(current ?? "the current version") by itself. Keep this app open and the pendant near your iPhone, with at least 15% battery or charging.\(release.changelog.isEmpty ? "" : "\n\nWhat's new: \(release.changelog.joined(separator: "; ")).")")
        }
    }

    @ViewBuilder private func offer(_ s: EngineSnapshot, current: String?) -> some View {
        let blocker = OmiEngine.firmwareBlocker(s)
        switch firmware.check {
        case .idle:
            Button("Check for update") { Task { await firmware.checkForUpdate(s.device) } }
                .disabled(current == nil)
        case .checking:
            HStack(spacing: 10) { ProgressView(); Text("Checking with Omi…").foregroundStyle(.secondary) }
        case .upToDate(let v):
            Label("Up to date: \(v) is the latest published firmware.", systemImage: "checkmark.seal").foregroundStyle(.secondary)
            Button("Check again") { Task { await firmware.checkForUpdate(s.device) } }
        case .available(let r):
            VStack(alignment: .leading, spacing: 4) {
                Text("Version \(r.version) is available").font(.body.weight(.semibold))
                if !r.changelog.isEmpty { Text(r.changelog.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
            }
            Button("Install \(r.version)…") { confirm = r }.disabled(blocker != nil)
            if let blocker { Text(blocker).font(.footnote).foregroundStyle(.secondary) }
        case .failed(let why):
            Text(why).font(.footnote).foregroundStyle(.red)
            Button("Try again") { Task { await firmware.checkForUpdate(s.device) } }.disabled(current == nil)
        }
        if let stable = firmware.stable, let current, stable.version != current {
            Button("Reinstall the latest stable firmware (\(stable.version))…", role: .destructive) { confirm = stable }
                .disabled(blocker != nil)
        }
    }

    @ViewBuilder private func preparing(_ p: FirmwareModel.Prepare) -> some View {
        switch p {
        case .idle: EmptyView()
        case .downloading: HStack(spacing: 10) { ProgressView(); Text("Downloading the update…").foregroundStyle(.secondary) }
        case .checkingPackage: HStack(spacing: 10) { ProgressView(); Text("Checking the package…").foregroundStyle(.secondary) }
        case .failed(let why):
            Text(why).font(.footnote).foregroundStyle(.red)
            Button("OK") { firmware.dismissResult() }
        }
    }

    @ViewBuilder private func progress(_ st: FirmwareUpdateState) -> some View {
        switch st {
        case .idle: EmptyView()
        case .preparing: HStack(spacing: 10) { ProgressView(); Text("Starting the update…").foregroundStyle(.secondary) }
        case .uploading(let sent, let total):
            VStack(alignment: .leading, spacing: 6) {
                Text("Sending the update to the pendant · \(total > 0 ? Int(100 * Double(sent) / Double(total)) : 0)%")
                ProgressView(value: Double(sent), total: Double(max(total, 1)))
                Text("Keep this app open and the pendant near your iPhone. It isn't recording during the update.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .confirming: HStack(spacing: 10) { ProgressView(); Text("Checking what the pendant received…").foregroundStyle(.secondary) }
        case .restarting(let v): HStack(spacing: 10) { ProgressView(); Text("The pendant is restarting to install \(v)…").foregroundStyle(.secondary) }
        case .done(let v):
            Label("Updated: the pendant now reports firmware \(v).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("OK") { firmware.dismissResult() }
        case .failed(let why):
            Text("The update didn't complete: \(why).").font(.footnote).foregroundStyle(.red)
            Button("OK") { firmware.dismissResult() }
        }
    }
}
