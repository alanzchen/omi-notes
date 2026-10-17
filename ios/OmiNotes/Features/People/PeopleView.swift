import OmiBLE
import OmiProtocol
import SwiftUI

/// You, the people the server recognizes, suggestions for recurring voices, and recognition settings.
struct PeopleView: View {
    /// "3 conversations · 2 days"; only what the server said (nothing rather than "0" when it didn't).
    static func evidence(_ s: SpeakerSuggestion) -> String? {
        let parts = [s.conversations.map { "\($0) conversation\($0 == 1 ? "" : "s")" }, s.days.map { "\($0) day\($0 == 1 ? "" : "s")" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @Bindable var model: AppModel
    @State private var showEnrollment = false
    @State private var showConsent = false
    @State private var forgetting: Person?
    @State private var naming: SpeakerSuggestion?
    @State private var run: ConversationSpeakersView.NamingRun?
    @State private var player = ClipPlayer()

    private var speakers: SpeakersModel { model.speakers }
    private var settings: SpeakerSettings? { speakers.settings }

    var body: some View {
        List {
            youSection
            if !speakers.others.isEmpty { peopleSection }
            if settings?.unknownVoicesEnabled == true { suggestionsSection }
            recognitionSection
            if let error = speakers.error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if let message = player.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("People")
        .task { await speakers.refresh() }
        .refreshable { await speakers.refresh() }
        .sheet(isPresented: $showEnrollment) { EnrollmentView(model: model) }
        #if DEBUG
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugEnrollment") {
                speakers.debugShowEnrollment(name)
                showEnrollment = true
            }
        }
        #endif
        .sheet(isPresented: $showConsent) { RecognitionConsentView(model: model) }
        .sheet(item: $naming) { suggestion in
            SuggestionPickerView(model: model, suggestion: suggestion)
        }
        .fullScreenCover(item: $run, onDismiss: { Task { await speakers.refresh() } }) { r in
            NameVoiceView(model: model, items: r.items)
        }
        .confirmationDialog(
            forgetting?.isMe == true ? "Forget your voice?" : "Forget \(forgetting?.name ?? "")'s voice?", isPresented: .init(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible
        ) {
            if let p = forgetting {
                Button("Forget voice", role: .destructive) { Task { await speakers.forgetVoice(p) } }
                Button("Forget voice and delete their note", role: .destructive) { Task { await speakers.forgetVoice(p, deleteNote: true) } }
            }
        } message: {
            Text(forgetting?.isMe == true
                 ? "Your voice sample, confirmations and voiceprints are deleted from your server, and past notes go back to “Speaker N”. You stay in People. This can't be undone. “Delete their note” also deletes your People note in the vault."
                 : "Their voiceprints are deleted from your server and past notes go back to “Speaker N”. They stay in People. This can't be undone. “Delete their note” also deletes their People note in the vault.")
        }
        .onDisappear { player.stop() }
    }

    private var youSection: some View {
        Section("You") {
            if let me = speakers.me {
                HStack {
                    Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(me.name).font(.headline)
                        Text(voiceSummary(me)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("Forget voice", role: .destructive) { forgetting = me } }
                Button(me.voiceReady == true ? "Add another voice sample" : "Teach my voice") { showEnrollment = true }
            } else {
                Text("Teach the server your voice so notes can label you, and action items you own show your name.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Teach my voice") { showEnrollment = true }
            }
        }
    }

    private var peopleSection: some View {
        Section {
            ForEach(speakers.others) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                    Text(voiceSummary(p)).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Forget voice", role: .destructive) { forgetting = p } }
            }
        } header: {
            Text("People")
        } footer: {
            Text("Name someone from a conversation (Home › Recent conversations) to teach their voice.")
        }
    }

    private var suggestionsSection: some View {
        Section {
            if speakers.suggestions.isEmpty {
                Text("No recurring unknown voices yet.").font(.subheadline).foregroundStyle(.secondary)
            }
            if speakers.serverSupportsNameVoice, !speakers.suggestions.isEmpty {
                Button { run = .init(items: speakers.suggestions.map(VoiceItem.init(suggestion:))) } label: {
                    Label("Name \(speakers.suggestions.count) voice\(speakers.suggestions.count == 1 ? "" : "s")", systemImage: "person.wave.2")
                        .font(.body.weight(.medium))
                }
            }
            ForEach(speakers.suggestions) { s in
                if speakers.serverSupportsNameVoice {
                    Button {
                        // this one first, then the rest
                        run = .init(items: ([s] + speakers.suggestions.filter { $0.id != s.id }).map(VoiceItem.init(suggestion:)))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(s)).font(.body.weight(.medium)).foregroundStyle(.primary)
                            if let text = s.clips?.first?.text ?? s.excerpt {
                                Text("“\(text)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if let e = Self.evidence(s) { Text(e).font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                } else {
                HStack(alignment: .top, spacing: 12) {
                    PlayButton(clipId: s.clipId, player: player, speakers: speakers)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(s)).font(.body.weight(.medium))
                        if let excerpt = s.excerpt { Text("“\(excerpt)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        if let e = Self.evidence(s) { Text(e).font(.caption2).foregroundStyle(.tertiary) }
                        HStack {
                            Button("Name…") { naming = s }.buttonStyle(.bordered)
                            Button("Dismiss") { Task { await speakers.dismiss(s) } }.buttonStyle(.borderless)
                        }
                        .font(.subheadline)
                    }
                }
                }
            }
        } header: {
            Text("Who is this?")
        } footer: {
            Text("Voices that keep appearing in your conversations. Their temporary voice data is deleted with the audio.")
        }
    }

    private var recognitionSection: some View {
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
        } header: {
            Text("Recognition")
        } footer: {
            Text("Automatic naming applies to a person only after they've been confirmed in conversations on at least two different days (for you: your voice sample plus confirmations in three recordings is enough). Voiceprints never leave your server.")
        }
        .disabled(model.settings.endpoint == nil)
    }

    private func title(_ s: SpeakerSuggestion) -> String {
        switch s.kind {
        case "is_this_you": return "Is this you?"
        case "is_this_person": return "Is this \(speakers.people.first { $0.id == s.personId }?.name ?? "someone you know")?"
        default: return "Who is this?"
        }
    }

    private func voiceSummary(_ p: Person) -> String {
        guard p.voiceReady == true else { return "No voice samples yet" }
        let samples = "\(p.samples ?? 0) sample\(p.samples == 1 ? "" : "s")"
        let sessions = p.sessions.map { " · \($0) session\($0 == 1 ? "" : "s")" } ?? ""
        return samples + sessions + (p.autoActive == true ? " · auto-naming on" : " · suggestions only")
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
