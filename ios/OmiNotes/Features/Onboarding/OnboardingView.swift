import OmiBLE
import OmiProtocol
import SwiftUI

/// First run: what the app does → connect the server → pair the pendant → what to expect.
struct OnboardingView: View {
    let model: AppModel
    let onFinish: () -> Void
    @State private var step = 0

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0: welcome
                case 1: server
                case 2: device
                default: expect
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step > 0 { Button("Back") { step -= 1 } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step < 3 ? "Next" : "Done") { step < 3 ? (step += 1) : onFinish() }
                }
            }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "waveform.badge.mic").font(.system(size: 56)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Omi Notes").font(.largeTitle.bold())
                Text("Wear your Omi pendant and talk as usual. A few minutes after each conversation, a note with a summary, action items and a transcript appears here and in your notes folder.")
                Label("Audio goes from the pendant to this phone, then to **your own server**. This app sends it nowhere else.", systemImage: "lock.shield")
                Label("If the phone or the network is away, audio waits safely on the pendant or the phone until it can be delivered.", systemImage: "tray.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Welcome")
    }

    private var server: some View {
        Form {
            Section {
                Text("On the computer that runs your server, run `omi-notes pair`, then scan the QR code with the iPhone **Camera** app. The link opens this app and asks you to confirm.")
                if let host = model.serverURL?.host() {
                    Label("Connected to \(host)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            ServerSettingsSection(model: model)
        }
        .navigationTitle("Your server")
    }

    private var device: some View {
        VStack(spacing: 0) {
            if let name = model.snapshot.rememberedDeviceName {
                Label("Paired with \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding()
            }
            PairingView(model: model, onPaired: { step = 3 })
        }
        .navigationTitle("Your pendant")
    }

    private var expect: some View {
        List {
            Section {
                check
            } header: {
                Text("Connection")
            } footer: {
                Text("This checks that the phone can reach your server and that the server is set up. It doesn't prove transcription works; that is confirmed when your first note appears.")
            }
            Section("What to expect") {
                Label("Your first note appears a few minutes after a conversation ends.", systemImage: "clock")
                Label("Leave the app in the background. Don't force-quit it: that stops the pendant from reconnecting until you open it again.", systemImage: "moon.zzz")
                Label("Only one phone can connect to the pendant. Disconnect the official Omi app.", systemImage: "iphone.slash")
                Label(PendantTip.text(model.snapshot), systemImage: "hand.tap")
                Label("If your server is a Mac, it must be awake and logged in to transcribe. If you use Tailscale, keep it connected on this phone.",
                      systemImage: "desktopcomputer")
            }
            .font(.subheadline)
            Section {
                Text("Your server decides which services receive your audio and transcripts. You can see its setup in the Server tab.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("You're set")
        .task { await model.refreshServer() }
    }

    @ViewBuilder private var check: some View {
        switch model.server {
        case .reachable:
            let st = model.serverStatus
            Label("Your server answered", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if st?.stt?.ready == false {
                Label("Transcription isn't set up on the server yet", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if model.snapshot.rememberedDeviceId == nil {
                Label("No pendant paired yet", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case .checking, .unknown:
            HStack { ProgressView(); Text("Checking your server…").padding(.leading, 6) }
        case .notConfigured:
            Label("No server connected yet. Recordings wait on this phone until you connect one.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .unauthorized:
            Label("The server rejected this phone. Pair again with a new code.", systemImage: "xmark.octagon").foregroundStyle(.red)
        case .unreachable(let why):
            Label("Couldn't reach your server (\(why)). Recordings wait on this phone until it's reachable.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}
