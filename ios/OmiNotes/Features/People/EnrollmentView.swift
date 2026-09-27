import OmiBLE
import OmiProtocol
import SwiftUI

/// Teaches the server the wearer's voice through the pendant (docs/speaker-learning.md,
/// "Enrollment"): the phone only marks the window; the server extracts it from normal pendant audio.
struct EnrollmentView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var creating = false

    private var speakers: SpeakersModel { model.speakers }
    private var streaming: Bool { model.snapshot.connection == .streaming }

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle("Teach my voice")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isDone ? "Done" : "Cancel") {
                            speakers.cancelEnrollment()
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled(isReading || isChecking)
        .onDisappear { speakers.enrollmentScreenClosed() }
    }

    private var isReading: Bool { if case .reading = speakers.enrollment { return true } else { return false } }
    private var isChecking: Bool { speakers.enrollment == .checking }
    private var isDone: Bool { if case .finished = speakers.enrollment { return true } else { return false } }

    @ViewBuilder private var content: some View {
        switch speakers.enrollment {
        case .idle:
            if speakers.me == nil { nameStep } else { introStep }
        case .checking:
            VStack(spacing: 16) {
                ProgressView()
                Text("Checking that your server supports voice enrollment…").multilineTextAlignment(.center)
            }
            .padding(.top, 40)
        case .reading(_, let prompt):
            readingStep(prompt)
        case .waiting(_, let status):
            VStack(spacing: 16) {
                ProgressView()
                Text(waitingText(status)).multilineTextAlignment(.center)
                Text("Keep the app open or come back later; the result is saved on your server.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 40)
        case .finished(let status):
            finishedStep(status)
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Back") { speakers.enrollment = .idle }
            }
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What should notes call you?").font(.headline)
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .textContentType(.name)
            Text("This creates your People note. Action items you own will use this name.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                creating = true
                Task {
                    _ = await speakers.createPerson(name: name.trimmingCharacters(in: .whitespaces), me: true)
                    creating = false
                }
            } label: {
                if creating { ProgressView() } else { Text("Continue").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
        }
    }

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wear your pendant and read six short sentences aloud, in a quiet place, in your normal voice. It takes about a minute.")
            Text("Your voice is turned into a voiceprint stored only on your own server, so notes can label you. You can forget it any time from People.")
                .font(.footnote).foregroundStyle(.secondary)
            if speakers.serverSupportsEnrollment == false {
                Label(SpeakersModel.serverTooOld, systemImage: "server.rack")
                    .font(.footnote).foregroundStyle(.orange)
            } else if !streaming {
                Label("Waiting for the pendant to stream audio (Home should say Recording).", systemImage: "waveform.slash")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button {
                Task { await speakers.startEnrollment() }
            } label: {
                Text("Start reading").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!streaming || speakers.serverSupportsEnrollment != true)
        }
    }

    private func readingStep(_ prompt: Int) -> some View {
        VStack(spacing: 24) {
            ProgressView(value: Double(prompt), total: Double(SpeakersModel.prompts.count))
            Text("Sentence \(prompt + 1) of \(SpeakersModel.prompts.count)").font(.caption).foregroundStyle(.secondary)
            Text(SpeakersModel.prompts[prompt])
                .font(.title2.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 160)
            Button {
                speakers.nextPrompt()
            } label: {
                Text(prompt + 1 < SpeakersModel.prompts.count ? "Next" : "Finish").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if !streaming {
                Label("The pendant stopped streaming; this attempt will be interrupted.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func finishedStep(_ status: EnrollmentStatus) -> some View {
        VStack(spacing: 16) {
            if status.state == "accepted" {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(.green)
                Text("Your voice is enrolled.").font(.headline)
                Text("Notes start labeling you once you've confirmed yourself in a few conversations on different days; until then the app suggests.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Image(systemName: "arrow.clockwise.circle").font(.system(size: 48)).foregroundStyle(.orange)
                Text("Needs another sample").font(.headline)
                Text(status.reason ?? "The recording wasn't clear enough.")
                    .multilineTextAlignment(.center)
                Button("Try again") { speakers.enrollment = .idle }.buttonStyle(.bordered)
            }
        }
        .padding(.top, 40)
    }

    private func waitingText(_ status: EnrollmentStatus?) -> String {
        switch status?.state {
        case "processing": return "Checking your recording…"
        case let s? where s == "waiting_audio": return "Waiting for the audio to reach your server…"
        default: return "Sending the recording to your server…"
        }
    }
}
