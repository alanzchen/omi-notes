import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

/// Who spoke in one conversation; tap a speaker to name or correct them.
struct ConversationSpeakersView: View {
    @Bindable var model: AppModel
    let conversationId: String
    let title: String

    @State private var data: ConversationSpeakers?
    @State private var error: String?
    @State private var editing: SpeakerLabel?
    @State private var info: String?
    @State private var player = ClipPlayer()
    @State private var naming: NamingRun?
    var startedAt: String?

    /// The voices a "Name this voice" run covers.
    struct NamingRun: Identifiable {
        let id = UUID()
        let items: [VoiceItem]
    }

    private var speakers: SpeakersModel { model.speakers }
    private var context: ConversationContext { ConversationContext(id: conversationId, startedAt: startedAt, title: title) }

    var body: some View {
        List {
            if let data {
                if speakers.serverSupportsNameVoice, !VoiceItem.unnamed(data, in: context).isEmpty {
                    Section {
                        let n = VoiceItem.unnamed(data, in: context).count
                        Button { naming = NamingRun(items: VoiceItem.unnamed(data, in: context)) } label: {
                            Label("Name \(n) voice\(n == 1 ? "" : "s")", systemImage: "person.wave.2")
                        }
                    }
                }
                Section {
                    ForEach(data.labels) { label in
                        Button {
                            if speakers.serverSupportsNameVoice {
                                naming = NamingRun(items: [VoiceItem(label: label, in: context)])
                            } else {
                                editing = label
                            }
                        } label: { row(label) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text(data.audioAvailable == false
                         ? "The audio for this conversation has expired; names can still be corrected."
                         : "Naming someone teaches the server their voice. Names the server recognized show “Recognized”.")
                }
                Section {
                    Button("Re-summarize with names") {
                        Task {
                            do {
                                try await speakers.resummarize(conversationId: conversationId)
                                info = "Queued. The note is rewritten in a minute or two."
                            } catch {
                                self.error = "\(error)"
                            }
                        }
                    }
                } footer: {
                    Text("Names update in the note right away. Re-summarizing also rewrites the summary using them; it takes a minute or two.")
                }
            } else if error == nil {
                ProgressView()
            }
            if let info { Section { Text(info).font(.footnote) } }
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            if let message = player.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { label in
            SpeakerPickerView(model: model, label: label) { choice in
                Task { await apply(choice, to: label) }
            }
        }
        .onDisappear { player.stop() }
        .fullScreenCover(item: $naming, onDismiss: { Task { await load() } }) { run in
            NameVoiceView(model: model, items: run.items)
        }
    }

    private func row(_ label: SpeakerLabel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PlayButton(clipId: label.clipId, player: player, speakers: speakers)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label.name ?? (label.keptUnknown == true ? "Unknown" : ConversationDetail.anonymous(label.label)))
                        .font(.body.weight(.medium))
                    if label.isAuto {
                        Text("Recognized").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: .capsule)
                    }
                    Spacer()
                }
                if let text = label.clips?.first?.text ?? label.excerpt {
                    Text("“\(text)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        // Opened straight from a conversation: the picker needs people and recognition settings
        // even if the People tab was never visited.
        if speakers.settings == nil || speakers.people.isEmpty { await speakers.refresh() }
        do {
            data = try await speakers.speakers(conversationId: conversationId)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func apply(_ choice: SpeakerPickerView.Choice, to label: SpeakerLabel) async {
        guard let revision = data?.revision else { return }
        do {
            switch choice {
            case .person(let p):
                data = try await speakers.assign(conversationId: conversationId, label: label.label, personId: p.id, revision: revision)
            case .unknown:
                data = try await speakers.assign(conversationId: conversationId, label: label.label, personId: nil, revision: revision)
            case .notThisPerson(let pid):
                data = try await speakers.assign(conversationId: conversationId, label: label.label, personId: nil, notPersonId: pid, revision: revision)
            }
            info = nil
        } catch APIError.http(409, _) {
            info = "The speakers changed on the server; reloaded. Please try again."
            await load()
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Pick who a speaker is: you, a known person, a new person, or unknown.
struct SpeakerPickerView: View {
    enum Choice { case person(Person), unknown, notThisPerson(String) }

    @Bindable var model: AppModel
    let label: SpeakerLabel
    let onChoose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var attest = false
    @State private var showConsent = false

    private var speakers: SpeakersModel { model.speakers }
    private var acknowledged: Bool { speakers.settings?.acknowledged == true }

    var body: some View {
        NavigationStack {
            Form {
                if let me = speakers.me {
                    Section { choose(.person(me), "This is me (\(me.name))", system: "person.crop.circle.badge.checkmark") }
                }
                if !speakers.others.isEmpty {
                    Section("People") {
                        ForEach(speakers.others) { p in choose(.person(p), p.name, system: "person.circle") }
                    }
                }
                Section("New person") {
                    if acknowledged {
                        TextField("Name", text: $newName)
                        Toggle("They know Omi Notes recognizes their voice", isOn: $attest)
                        Button("Add and assign") {
                            Task {
                                if let p = await speakers.createPerson(name: newName.trimmingCharacters(in: .whitespaces), attestKnows: attest) {
                                    onChoose(.person(p))
                                    dismiss()
                                }
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !attest)
                    } else {
                        Button("Recognize other people…") { showConsent = true }
                        Text("Before naming anyone other than you, confirm how recognition works.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let pid = label.personId, label.isAuto {
                        choose(.notThisPerson(pid), "Not \(label.name ?? "this person")", system: "person.crop.circle.badge.xmark")
                    }
                    choose(.unknown, "Unknown speaker", system: "questionmark.circle")
                }
            }
            .navigationTitle(label.name ?? (label.label == "unknown" ? "Unknown speaker"
                                            : label.label.hasPrefix("S") && Int(label.label.dropFirst()) != nil ? "Speaker \(label.label.dropFirst())" : label.label))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showConsent) { RecognitionConsentView(model: model) }
        }
    }

    private func choose(_ choice: Choice, _ title: String, system: String) -> some View {
        Button {
            onChoose(choice)
            dismiss()
        } label: {
            Label(title, systemImage: system)
        }
    }
}
