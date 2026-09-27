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

    private var speakers: SpeakersModel { model.speakers }

    var body: some View {
        List {
            if let data {
                Section {
                    ForEach(data.labels) { label in
                        Button { editing = label } label: { row(label) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text(data.audioAvailable == false
                         ? "The audio for this conversation has expired; names can still be corrected."
                         : "Naming someone teaches the server their voice. Automatic names show an “auto” badge.")
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
                    Text("Names update in the note right away. Re-summarizing also rewrites the summary with them (one LLM call).")
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
    }

    private func row(_ label: SpeakerLabel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PlayButton(clipId: label.clipId, player: player, speakers: speakers)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label.name ?? "Speaker \(label.label.dropFirst())").font(.body.weight(.medium))
                    if label.isAuto {
                        Text("auto").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: .capsule)
                    }
                    Spacer()
                    Text(label.label).font(.caption).foregroundStyle(.tertiary)
                }
                if let excerpt = label.excerpt {
                    Text("“\(excerpt)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if label.isAuto, let d = label.distance {
                    Text(evidence(label, distance: d)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func evidence(_ label: SpeakerLabel, distance: Double) -> String {
        var parts = [String(format: "distance %.2f", distance)]
        if let m = label.margin { parts.append(String(format: "margin %.2f", m)) }
        if let s = label.evidenceS { parts.append(String(format: "%.0f s of speech", s)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
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
            .navigationTitle(label.name ?? "Speaker \(label.label.dropFirst())")
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
