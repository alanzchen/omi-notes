import OmiBLE
import OmiCapture
import OmiProtocol
import SwiftUI

@main
struct OmiNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
                .onOpenURL { url in appDelegate.model.handleOpenURL(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: appDelegate.model.engine.appDidBecomeActive()
            case .background: appDelegate.model.engine.appDidEnterBackground()
            default: break
            }
        }
    }
}

struct RootView: View {
    enum Tab: String { case home, people, server }
    /// What the Settings sheet opens on.
    enum SettingsPage: String, Identifiable { case main, pairing; var id: String { rawValue } }

    @Bindable var model: AppModel
    @State private var showOnboarding = false
    @State private var tab: Tab = RootView.initialTab
    @State private var settings: SettingsPage? = RootView.initialSettings
    @State private var serverPath = RootView.initialServerPath

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView(model: model, onFix: fix, openPeople: { tab = .people })
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { settings = .main } label: { Label("Settings", systemImage: "gearshape") }
                        }
                    }
            }
            .tabItem { Label("Home", systemImage: "waveform") }
            .tag(Tab.home)
            NavigationStack { PeopleView(model: model) }
                .tabItem { Label("People", systemImage: "person.2") }
                .tag(Tab.people)
            NavigationStack(path: $serverPath) { ServerView(model: model, onFix: fix) }
                .tabItem { Label("Server", systemImage: "server.rack") }
                .tag(Tab.server)
        }
        .onAppear { showOnboarding = model.needsOnboarding }
        // One refresh loop for every tab: status, issues and the first page of conversations.
        .task {
            while !Task.isCancelled {
                await model.refreshServer()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .sheet(item: $settings) { page in
            NavigationStack {
                Group {
                    switch page {
                    case .main: SettingsView(model: model)
                    case .pairing: PairingView(model: model, onPaired: { settings = nil })
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = nil } } }
            }
        }
        .sheet(item: $model.pendingConfigure) { link in
            ConfigureConfirmSheet(model: model, link: link)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(model: model) {
                model.finishOnboarding()
                showOnboarding = false
            }
        }
    }

    private func fix(_ fix: SystemHealth.Fix) {
        switch fix {
        case .pairDevice: settings = .pairing
        case .reconnectDevice: model.engine.reconnect()
        case .openBluetoothSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .retryUploads: model.engine.retryUploads()
        case .openServer:
            serverPath = NavigationPath()
            tab = .server
        case .openDiagnostics:
            serverPath = NavigationPath([ServerView.Page.diagnostics])
            tab = .server
        }
    }
}

extension RootView {
    /// Simulator automation only (debug builds): `-OmiNotesDebugTab home|people|server|settings|pairing|diagnostics|debug`
    /// opens that screen at launch (there is no way to tap in a headless simulator).
    static var initialTab: Tab {
        #if DEBUG
        let raw = UserDefaults.standard.string(forKey: "OmiNotesDebugTab")
        if raw == "diagnostics" || raw == "debug" { return .server }
        if let raw, let tab = Tab(rawValue: raw) { return tab }
        #endif
        return .home
    }

    static var initialServerPath: NavigationPath {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "OmiNotesDebugTab") {
        case "diagnostics": return NavigationPath([ServerView.Page.diagnostics])
        case "debug": return NavigationPath([ServerView.Page.developer])
        default: return NavigationPath()
        }
        #else
        return NavigationPath()
        #endif
    }

    static var initialSettings: SettingsPage? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "OmiNotesDebugTab") {
        case "settings": return .main
        case "pairing": return .pairing
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// Shown for `omi-notes://configure?url=…&token=…`: displays the destination before anything is saved.
struct ConfigureConfirmSheet: View {
    let model: AppModel
    let link: ConfigureLink
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var testResult: String?

    var body: some View {
        let (url, verdict) = ServerURLPolicy.evaluate(link.url)
        NavigationStack {
            Form {
                Section {
                    Text("A pairing link wants to send your recordings to this server:")
                    LabeledContent("Server", value: url?.host() ?? link.url)
                    LabeledContent("URL", value: link.url).font(.footnote)
                    LabeledContent("Token", value: link.maskedToken).monospaced()
                } footer: {
                    Text("Only continue if you generated this code with `omi-notes pair` on your own computer.")
                }
                switch verdict {
                case .ok: EmptyView()
                case .insecureLocal(let warning):
                    Section { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                case .rejected(let why):
                    Section { Label(why, systemImage: "xmark.octagon").foregroundStyle(.red) }
                }
                if let url, verdict.isAcceptable {
                    Section {
                        Button("Test connection") {
                            Task { testResult = await model.testConnection(url: url, token: link.token) }
                        }
                        if let testResult { Text(testResult).font(.footnote) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Connect to server?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.pendingConfigure = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try model.confirmPendingConfigure()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(!verdict.isAcceptable)
                }
            }
        }
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return SystemHealth.relative(date, Date())
    }

    static func iso(_ s: String?) -> String {
        guard let s, let d = ISO8601UTC.parse(s) else { return s ?? "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func shortId(_ s: String?) -> String { s.map { String($0.prefix(8)) } ?? "—" }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 10, height: 10) }
}
