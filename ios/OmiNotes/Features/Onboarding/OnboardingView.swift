import OmiBLE
import SwiftUI

/// First run: what the app does → server → device → background notes.
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
                default: background
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
                Image(systemName: "waveform.badge.mic").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Omi Notes").font(.largeTitle.bold())
                Text("This app carries audio from your Omi pendant to **your own server**, which transcribes it and writes Markdown notes.")
                Text("The phone doesn't transcribe anything: it saves what the pendant sends, then uploads it. If the phone or network is away, the pendant and the phone both keep audio until it can be delivered.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Welcome")
    }

    private var server: some View {
        Form {
            Section {
                Text("On your Mac, run `omi-notes pair` and scan the QR code with the iPhone **Camera** app. The link opens this app and asks you to confirm the server.")
                if let host = model.serverURL?.host() {
                    Label("Configured: \(host)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            ServerSettingsSection(model: model)
        }
        .navigationTitle("Server")
    }

    private var device: some View {
        VStack(spacing: 0) {
            if let name = model.snapshot.rememberedDeviceName {
                Label("Paired with \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding()
            }
            PairingView(model: model, onPaired: { step = 3 })
        }
        .navigationTitle("Device")
    }

    private var background: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Keep it running").font(.title.bold())
                Label("Leave the app in the background. iOS wakes it for the pendant and finishes uploads on its own.", systemImage: "moon.zzz")
                Label("Don't force-quit it from the app switcher: that stops Bluetooth reconnection until you open it again (the pendant buffers meanwhile).", systemImage: "xmark.app")
                Label("Only one phone can connect to the pendant. Disconnect the official Omi app.", systemImage: "iphone.slash")
                Label("Single tap on the pendant = bookmark. Double tap = end the current conversation now.", systemImage: "hand.tap")
            }
            .padding()
        }
        .navigationTitle("Background")
    }
}
