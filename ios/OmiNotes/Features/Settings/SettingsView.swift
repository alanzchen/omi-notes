import OmiBLE
import OmiCapture
import SwiftUI

/// App and pendant settings (the server connection lives in the Server tab).
struct SettingsView: View {
    let model: AppModel
    var onFix: (SystemHealth.Fix) -> Void = { _ in }
    var body: some View {
        Form {
            // the same pages as the Devices tab (each device's settings live there, once)
            Section("Devices") {
                NavigationLink { DevicePageView(page: .pendant, model: model, onFix: onFix) } label: {
                    Label("Pendant", systemImage: "circle.circle")
                }
                NavigationLink { DevicePageView(page: .watch, model: model, onFix: onFix) } label: {
                    Label("Apple Watch", systemImage: "applewatch")
                }
            }
            Section {
                Label("Leave Omi Notes running in the background. Force-quitting it stops the pendant from reconnecting until you open the app again.",
                      systemImage: "moon.zzz")
                Label("Only one phone can connect to the pendant. Disconnect the official Omi app.", systemImage: "iphone.slash")
                Label(PendantTip.text(model.snapshot), systemImage: "hand.tap")
            } header: {
                Text("Tips")
            }
            .font(.subheadline)
            Section("Privacy") {
                Text("Audio goes from the pendant (and your Apple Watch, when you record on it) to this phone, then to your own server. This app sends it nowhere else. Your server decides which services receive your audio and transcripts; see Server → Configuration.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            AlertsSection(model: model)
            ObsidianSection(model: model)
            SavedNotesSection(model: model)
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

/// Opt-in alerts for problems this phone notices while you're not looking at it.
struct AlertsSection: View {
    let model: AppModel
    @State private var on = false
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Alert me when recording or uploads stop", isOn: Binding(get: { on }, set: { value in
                Task {
                    if value, !(await LocalAlerts.requestPermission()) {
                        message = "Notifications are turned off for Omi Notes in the iPhone Settings app."
                        on = false
                        return
                    }
                    model.problemAlerts.enabled = value
                    on = value
                    message = nil
                }
            }))
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
        } header: {
            Text("Alerts")
        } footer: {
            Text("For problems this phone can see: recording stopped because storage is full, audio that couldn't be uploaded, uploads paused, or an Apple Watch recording stopped without you stopping it. Alerts never include what was said, and go away once fixed. They may arrive late: iOS decides when the app runs in the background.")
        }
        .onAppear { on = model.problemAlerts.enabled }
    }
}

/// The name of this server's vault in the Obsidian app on this phone (for "Open in Obsidian").
struct ObsidianSection: View {
    let model: AppModel
    @State private var name = ""

    var body: some View {
        if let vaultId = model.serverStatus?.vaultId {
            let suggestion = ObsidianLink.suggestedVault(notesDir: model.serverStatus?.notesDir)
            Section {
                TextField(suggestion ?? "Vault name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { ObsidianLink.setVaultName(name, for: vaultId) }
                    .onChange(of: name) { _, value in ObsidianLink.setVaultName(value, for: vaultId) }
                if name.isEmpty, let suggestion {
                    Button("Use “\(suggestion)”") { name = suggestion }
                }
            } header: {
                Text("Obsidian vault")
            } footer: {
                Text("The vault's name as it appears in Obsidian on this phone. The server's folder is only a guess; the names can differ.")
            }
            .onAppear { name = ObsidianLink.vaultName(for: vaultId) ?? "" }
        }
    }
}

/// Notes kept on this phone for reading offline.
struct SavedNotesSection: View {
    let model: AppModel
    @State private var cleared = false

    var body: some View {
        Section {
            Button("Clear saved notes", role: .destructive) {
                model.clearSavedNotes()
                cleared = true
            }
            if cleared { Text("Cleared. Notes are saved again as you read them.").font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Saved on this phone")
        } footer: {
            Text("Notes you open are kept on this phone (up to \(NoteCache.maxDetails)) so you can read them without a connection. iOS may remove them to free space; your server always has the originals.")
        }
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


