import OmiBLE
import OmiCapture
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    var body: some View {
        Form {
            ServerSettingsSection(model: model)
            DeviceSettingsSection(model: model)
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                Text("Audio is journaled on this phone and uploaded to your server, which transcribes it and writes Markdown notes. Nothing is sent anywhere else by this app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
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
            Text("Easiest: run `omi-notes pair` on your Mac and scan the QR code with the Camera app. The token is stored in the Keychain.")
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
        Section("Device") {
            if let id = s.rememberedDeviceId {
                LabeledContent("Paired", value: s.rememberedDeviceName ?? "Omi")
                LabeledContent("Identifier", value: String(id.prefix(8))).font(.footnote)
                switch s.connection {
                case .paused, .refused:
                    Button("Reconnect") { model.engine.reconnect() }
                default:
                    Button("Disconnect") { model.engine.disconnect() }
                }
                NavigationLink("Pair a different device") { PairingView(model: model) }
                Button("Forget device", role: .destructive) { confirmForget = true }
            } else {
                NavigationLink("Pair a device") { PairingView(model: model) }
            }
        }
        .confirmationDialog("Forget this device?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.engine.forgetDevice() }
        } message: {
            Text("The current capture is sealed and uploaded; the app stops reconnecting. Audio already on the phone is kept until the server has it.")
        }
    }
}
