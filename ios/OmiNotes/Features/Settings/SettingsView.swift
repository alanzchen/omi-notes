import OmiBLE
import OmiCapture
import SwiftUI

/// App and pendant settings (the server connection lives in the Server tab).
struct SettingsView: View {
    let model: AppModel
    var body: some View {
        Form {
            DeviceSettingsSection(model: model)
            Section {
                Label("Leave Omi Notes running in the background. Force-quitting it stops the pendant from reconnecting until you open the app again.",
                      systemImage: "moon.zzz")
                Label("Only one phone can connect to the pendant. Disconnect the official Omi app.", systemImage: "iphone.slash")
                Label("Tap the pendant once to bookmark a moment; double-tap to end the conversation now.", systemImage: "hand.tap")
            } header: {
                Text("Tips")
            }
            .font(.subheadline)
            Section("Privacy") {
                Text("Audio goes from the pendant to this phone, then to your own server. This app sends it nowhere else. Your server decides which services receive your audio and transcripts; see Server → Configuration.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Server URL + token (Keychain) with validation and "Test connection".
struct ServerSettingsSection: View {
    let model: AppModel
    @State private var urlText = ""
    @State private var token = ""
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        let (url, verdict) = ServerURLPolicy.evaluate(urlText)
        Section {
            TextField("https://your-mac.tailnet.ts.net", text: $urlText)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(model.settings.token == nil ? "Token" : "Token (saved — enter to replace)", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !urlText.isEmpty {
                switch verdict {
                case .ok: EmptyView()
                case .insecureLocal(let w): Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                case .rejected(let r): Label(r, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red)
                }
            }
            HStack {
                Button(testing ? "Testing…" : "Test connection") {
                    guard let url, let t = effectiveToken else { message = "Enter a URL and token first"; return }
                    testing = true
                    Task {
                        message = await model.testConnection(url: url, token: t)
                        testing = false
                    }
                }
                .disabled(url == nil || !verdict.isAcceptable || testing)
                Spacer()
                Button("Save") {
                    guard let url, let t = effectiveToken else { return }
                    do {
                        try model.saveServer(url: url, token: t)
                        token = ""
                        message = "Saved"
                    } catch {
                        message = "Could not save: \(error.localizedDescription)"
                    }
                }
                .disabled(url == nil || !verdict.isAcceptable || effectiveToken == nil)
            }
            .buttonStyle(.borderless)
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Server")
        } footer: {
            Text("Easiest: run `omi-notes pair` on your server and scan the QR code with the Camera app. The token is stored in the Keychain.")
        }
        .onAppear { urlText = model.serverURL?.absoluteString ?? "" }
    }

    private var effectiveToken: String? {
        if !token.isEmpty { return token }
        return model.settings.token
    }
}

struct DeviceSettingsSection: View {
    let model: AppModel
    @State private var confirmForget = false

    var body: some View {
        let s = model.snapshot
        Section("Pendant") {
            if let id = s.rememberedDeviceId {
                LabeledContent("Paired", value: s.rememberedDeviceName ?? "Omi")
                LabeledContent("ID", value: String(id.prefix(8))).font(.footnote)
                switch s.connection {
                case .paused, .refused:
                    Button("Reconnect") { model.engine.reconnect() }
                default:
                    Button("Disconnect") { model.engine.disconnect() }
                    Text("Disconnecting stops this phone from receiving audio. The pendant may keep recording to its own storage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink("Pair a different pendant") { PairingView(model: model) }
                Button("Forget pendant", role: .destructive) { confirmForget = true }
            } else {
                NavigationLink("Pair a pendant") { PairingView(model: model) }
            }
        }
        .confirmationDialog("Forget this pendant?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.engine.forgetDevice() }
        } message: {
            Text("The current recording is finished and uploaded, and the app stops reconnecting. Audio already on this phone is kept until your server has it.")
        }
    }
}
