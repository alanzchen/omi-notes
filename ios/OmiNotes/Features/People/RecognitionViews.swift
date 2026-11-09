import OmiBLE
import OmiProtocol
import SwiftUI

/// Recognition settings (from the 声纹 hub's toolbar): the one-time acknowledgment, recurring
/// unknown voices and automatic naming.
struct RecognitionSettingsView: View {
    @Bindable var model: AppModel
    @State private var showConsent = false
    @Environment(\.dismiss) private var dismiss

    private var speakers: SpeakersModel { model.speakers }
    private var settings: SpeakerSettings? { speakers.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if settings?.acknowledged == true {
                        Label("Recognizing other people is on", systemImage: "checkmark.shield")
                        Toggle("Suggest recurring unknown voices", isOn: .init(
                            get: { settings?.unknownVoicesEnabled == true },
                            set: { on in Task { await speakers.setUnknownVoices(on) } }))
                    } else {
                        Button("Recognize other people…") { showConsent = true }
                    }
                    Toggle("Name speakers automatically", isOn: .init(
                        get: { settings?.autoAssign ?? true },
                        set: { on in Task { await speakers.setAutoAssign(on) } }))
                } footer: {
                    Text("Automatic naming applies to a person only after they've been confirmed in conversations on at least two different days (for you: your voice sample plus confirmations in three recordings is enough). Voiceprints never leave your server.")
                }
                .disabled(model.settings.endpoint == nil)
                if let error = speakers.error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("识别设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showConsent) { RecognitionConsentView(model: model) }
        }
    }
}

/// Names a suggested voice cluster.
struct SuggestionPickerView: View {
    @Bindable var model: AppModel
    let suggestion: SpeakerSuggestion
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var attest = false

    private var speakers: SpeakersModel { model.speakers }

    var body: some View {
        NavigationStack {
            Form {
                if let me = speakers.me {
                    Section { assignButton(me, "This is me (\(me.name))") }
                }
                if !speakers.others.isEmpty {
                    Section("People") { ForEach(speakers.others) { p in assignButton(p, p.name) } }
                }
                Section("New person") {
                    TextField("Name", text: $newName)
                    Toggle("They know Omi Notes recognizes their voice", isOn: $attest)
                    Button("Add and assign") {
                        Task {
                            if let p = await speakers.createPerson(name: newName.trimmingCharacters(in: .whitespaces), attestKnows: attest) {
                                await speakers.assign(suggestion, to: p)
                                dismiss()
                            }
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !attest)
                }
            }
            .navigationTitle("Name this voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func assignButton(_ p: Person, _ title: String) -> some View {
        Button(title) {
            Task {
                await speakers.assign(suggestion, to: p)
                dismiss()
            }
        }
    }
}

/// One-time acknowledgment before recognizing anyone other than the wearer.
struct RecognitionConsentView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recognizing other people").font(.title2.bold())
                    Text("When you name someone in a conversation, your server stores a voiceprint of them so later notes can label them automatically.")
                    Text("Voiceprints are biometric data. Laws such as Illinois' BIPA and Texas' CUBI restrict collecting them without the person's consent. Turning this on does **not** establish anyone else's consent or your legal compliance — only name people who know and agree.")
                    Text("Voiceprints stay on your server, are never sent to transcription or AI providers, and are deleted when you forget a person.")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    // stays open if the server didn't take it, and says why
                    if let failed { Label(failed, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                    Button {
                        saving = true
                        Task {
                            await model.speakers.acknowledgeRecognition()
                            saving = false
                            if model.speakers.settings?.acknowledgedAt != nil { dismiss() } else {
                                failed = model.speakers.error ?? "Couldn't turn it on; try again."
                            }
                        }
                    } label: {
                        Text(saving ? "Turning on…" : "I understand — turn on").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                }
                .padding()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
        }
    }
}
