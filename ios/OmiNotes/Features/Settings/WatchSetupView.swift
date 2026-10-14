import OmiBLE
import SwiftUI
import WatchConnectivity

/// Settings ▸ Apple Watch: how to record on the Watch all day, and where its audio is now
/// (on this iPhone, uploaded to your server, then a note).
struct WatchSetupView: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        Form {
            Section {
                LabeledContent("Watch", value: watchState)
                if let at = s.watchLastReceivedAt {
                    LabeledContent("Received on this iPhone", value: at.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Parts received", value: "\(s.watchReceived)")
                }
                if s.watchPending + s.watchWaitingUpload > 0 {
                    LabeledContent("Waiting to upload", value: "\(s.watchPending + s.watchWaitingUpload)")
                }
                if let at = s.watchLastUploadedAt {
                    LabeledContent("Last uploaded to server", value: at.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("Status")
            } footer: {
                Text(statusFooter(s))
            }

            Section {
                step(1, "Install", "In the iPhone's Watch app, find Omi Notes under Available Apps and tap Install. It may already be there.")
                step(2, "Start", "Open Omi Notes on the Watch and tap the red microphone. Allow microphone access the first time.")
                step(3, "Wear it", "It keeps recording with your wrist down or the screen dark, in one-minute parts, until you tap Stop.")
                step(4, "Sync", "Parts come to this iPhone when it's nearby and upload like the pendant's. A note appears about two minutes after a conversation ends.")
            } header: {
                Text("Record all day")
            }

            Section {
                Label("A call or Siri pauses recording. If it doesn't continue by itself, the Watch says Paused: tap Resume.", systemImage: "pause.circle")
                Label("It doesn't restart by itself after the Watch restarts, its battery runs out, or the app is closed. Open it and tap the microphone again.", systemImage: "arrow.clockwise")
                Label("Recording all day uses battery; charge the Watch overnight.", systemImage: "battery.75percent")
                Label("Away from this iPhone, the Watch keeps up to about 40 hours of audio, then pauses until it can send.", systemImage: "externaldrive")
                Label("If the pendant recorded the same conversation, you get one note; the Watch audio is kept as an alternate recording.", systemImage: "rectangle.on.rectangle")
            } header: {
                Text("Good to know")
            }
            .font(.subheadline)
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var watchState: String {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return "Checking…" }
        if !WCSession.default.isPaired { return "No Apple Watch paired" }
        return WCSession.default.isWatchAppInstalled ? "Omi Notes installed" : "Omi Notes not installed yet"
    }

    private func statusFooter(_ s: EngineSnapshot) -> String {
        if s.watchLastReceivedAt == nil { return "Nothing has come from the Watch yet." }
        let others = s.outbox.pendingChunks - s.watchWaitingUpload
        if s.watchWaitingUpload > 0, others > 50 {
            return "Watch audio uploads in turn with \(others) other parts already waiting on this iPhone."
        }
        return "The Watch deletes a part only after this iPhone has saved it; this iPhone keeps it until your server has it."
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.accentColor, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
