import Darwin
import Foundation
import OmiCapture
import Security

// MARK: - Token storage

public protocol TokenStore: AnyObject, Sendable {
    /// nil = no token stored. Throws for transient failures (e.g. protected data unavailable),
    /// which must not be mistaken for "no token".
    func load() throws -> String?
    func save(_ token: String?) throws
}

public enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    public var description: String {
        if case .status(let s) = self { return "Keychain error \(s)" }
        return "Keychain error"
    }
}

/// Bearer token in the Keychain, readable after first unlock (background uploads need it).
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "omi-notes", account: String = "server-token") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func save(_ token: String?) throws {
        SecItemDelete(query as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(_ token: String? = nil) { self.token = token }
    public func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ token: String?) throws { lock.lock(); self.token = token; lock.unlock() }
}

// MARK: - Settings

/// Persistent app settings. Server URL in UserDefaults, token in the Keychain.
///
/// URL, token and a configuration `generation` form one snapshot guarded by a single lock:
/// `serverConfig()` can never pair one server's URL with another server's token. The generation is
/// persisted and bumped on every change, and becomes part of each upload task's identity.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let tokens: TokenStore
    private let lock = NSLock()
    private var cachedURL: URL?
    private var cachedToken: String?
    private var tokenLoaded = false
    private var generation: Int
    private var lastTokenError: String?

    enum Key {
        static let serverURL = "omi.serverURL"
        static let serverGeneration = "omi.serverGeneration"
        static let rememberedDevice = "omi.rememberedPeripheral"
        static let rememberedName = "omi.rememberedPeripheralName"
        static let userDisconnected = "omi.userDisconnected"
        static let simulated = "omi.simulatedDevice"
        static let onboarded = "omi.onboarded"
        static let buttonActionsOff = "omi.buttonActionsOff"
        static let doubleTapAction = "omi.doubleTapAction"
    }

    public init(defaults: UserDefaults = .standard, tokens: TokenStore = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokens = tokens
        cachedURL = defaults.string(forKey: Key.serverURL).flatMap(URL.init(string:))
        generation = defaults.integer(forKey: Key.serverGeneration)
    }

    /// One consistent snapshot of the server configuration.
    public func serverConfig() -> UploadConfig {
        lock.lock(); defer { lock.unlock() }
        loadTokenLocked()
        guard let url = cachedURL, let token = cachedToken, !token.isEmpty else {
            return UploadConfig(endpoint: nil, generation: generation)
        }
        return UploadConfig(endpoint: ServerEndpoint(baseURL: url, token: token), generation: generation)
    }

    public var endpoint: ServerEndpoint? { serverConfig().endpoint }

    public var serverURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return cachedURL
    }

    public var token: String? {
        lock.lock(); defer { lock.unlock() }
        loadTokenLocked()
        return cachedToken
    }

    /// Last Keychain read failure (transient; retried on next access).
    public var tokenError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastTokenError
    }

    /// Keychain first (may throw), then URL + token + generation published together.
    public func setServer(url: URL, token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try tokens.save(token)
        generation += 1
        defaults.set(generation, forKey: Key.serverGeneration)
        defaults.set(url.absoluteString, forKey: Key.serverURL)
        cachedURL = url
        cachedToken = token
        tokenLoaded = true
        lastTokenError = nil
        OmiLog.shared.registerSecret(token)
    }

    /// Protected data became available (or the app suspects a stale cache): read the Keychain again.
    public func invalidateTokenCache() {
        lock.lock(); defer { lock.unlock() }
        if cachedToken == nil { tokenLoaded = false }
    }

    private func loadTokenLocked() {
        guard !tokenLoaded else { return }
        do {
            cachedToken = try tokens.load()
            tokenLoaded = true  // cache only a definitive answer (token or "none stored")
            lastTokenError = nil
            OmiLog.shared.registerSecret(cachedToken)
        } catch {
            cachedToken = nil
            if lastTokenError == nil { OmiLog.shared.log(.warning, "settings", "token unavailable for now: \(error)") }
            lastTokenError = "\(error)"
        }
    }

    public var rememberedDeviceId: UUID? {
        get { defaults.string(forKey: Key.rememberedDevice).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.rememberedDevice) }
    }

    public var rememberedDeviceName: String? {
        get { defaults.string(forKey: Key.rememberedName) }
        set { defaults.set(newValue, forKey: Key.rememberedName) }
    }

    public var userDisconnected: Bool {
        get { defaults.bool(forKey: Key.userDisconnected) }
        set { defaults.set(newValue, forKey: Key.userDisconnected) }
    }

    public var simulatedMode: Bool {
        get { defaults.bool(forKey: Key.simulated) }
        set { defaults.set(newValue, forKey: Key.simulated) }
    }

    public var onboarded: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    /// Whether this phone acts on the pendant's button (on by default). Kept on the phone: the
    /// pendant always sends its button events.
    public var buttonActionsEnabled: Bool {
        get { !defaults.bool(forKey: Key.buttonActionsOff) }
        set { defaults.set(!newValue, forKey: Key.buttonActionsOff) }
    }

    public var doubleTapAction: DoubleTapAction {
        get { defaults.string(forKey: Key.doubleTapAction).flatMap(DoubleTapAction.init(rawValue:)) ?? .endConversation }
        set { defaults.set(newValue.rawValue, forKey: Key.doubleTapAction) }
    }
}

/// What a double tap on the pendant does (this phone's choice).
public enum DoubleTapAction: String, CaseIterable, Sendable {
    /// End the current conversation now (the default).
    case endConversation
    /// Bookmark this moment, like a single tap; the conversation continues.
    case bookmark

    public var title: String {
        switch self {
        case .endConversation: return "End conversation"
        case .bookmark: return "Bookmark"
        }
    }
}

// MARK: - Server URL policy

public enum ServerURLVerdict: Equatable, Sendable {
    case ok
    /// http to a local-network / development host: allowed, with a warning.
    case insecureLocal(String)
    case rejected(String)

    public var isAcceptable: Bool {
        if case .rejected = self { return false }
        return true
    }
}

/// HTTPS is required. In Debug builds only, plain http is accepted (with a warning) for hosts that
/// cannot be on the public internet: loopback (`localhost`, 127/8, ::1), RFC 1918 (10/8, 172.16/12,
/// 192.168/16), link-local (169.254/16, fe80::/10), CGNAT 100.64/10 (Tailscale's WireGuard-encrypted
/// IPs), IPv6 unique-local fc00::/7 (Tailscale IPv6), and mDNS `*.local` names. IP literals are
/// parsed, not pattern-matched. Release builds are HTTPS-only (the Info.plist ATS exception is also
/// Debug-only).
public enum ServerURLPolicy {
    #if DEBUG
    public static let allowsInsecureLocalByDefault = true
    #else
    public static let allowsInsecureLocalByDefault = false
    #endif

    public static func evaluate(_ raw: String, allowInsecureLocal: Bool = allowsInsecureLocalByDefault) -> (url: URL?, verdict: ServerURLVerdict) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased(),
              let rawHost = comps.host, !rawHost.isEmpty else {
            return (nil, .rejected("Not a valid URL"))
        }
        guard comps.query == nil, comps.fragment == nil, comps.user == nil, comps.password == nil else {
            return (nil, .rejected("The server URL must not contain credentials, a query or a fragment"))
        }
        guard let url = comps.url else { return (nil, .rejected("Not a valid URL")) }
        switch scheme {
        case "https":
            return (url, .ok)
        case "http":
            if allowInsecureLocal, isLocal(rawHost) {
                return (url, .insecureLocal("Plain http: the token and audio travel unencrypted on this network. Use only for local development."))
            }
            return (nil, .rejected(allowInsecureLocal
                ? "Use https (e.g. `tailscale serve`); plain http is only allowed for local-network hosts"
                : "Use https (e.g. `tailscale serve`); plain http is only allowed in development builds"))
        default:
            return (nil, .rejected("Unsupported scheme \(scheme)"))
        }
    }

    public static func isLocal(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if let v4 = ipv4(host) { return isLocalV4(v4) }
        if let v6 = ipv6(host) { return isLocalV6(v6) }
        if host.contains(":") { return false }  // malformed IPv6 literal
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local"), host.count > ".local".count { return true }
        return false
    }

    static func ipv4(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }  // network byte order
    }

    static func ipv6(_ s: String) -> [UInt8]? {
        let core = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s  // strip zone id
        var addr = in6_addr()
        guard inet_pton(AF_INET6, core, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    static func isLocalV4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    static func isLocalV6(_ b: [UInt8]) -> Bool {
        if b == [UInt8](repeating: 0, count: 15) + [1] { return true }                 // ::1
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return true }                            // fe80::/10
        if b[0] & 0xFE == 0xFC { return true }                                          // fc00::/7
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {             // ::ffff:a.b.c.d
            return isLocalV4(Array(b[12..<16]))
        }
        return false
    }
}

/// `omi-notes://configure?url=…&token=…` from the `omi-notes pair` QR code.
public struct ConfigureLink: Equatable, Sendable, Identifiable {
    public var url: String
    public var token: String
    public var id: String { url }

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }

    public static func parse(_ link: URL) -> ConfigureLink? {
        guard link.scheme?.lowercased() == "omi-notes", link.host?.lowercased() == "configure",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        guard let url = items.first(where: { $0.name == "url" })?.value, !url.isEmpty,
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else { return nil }
        return ConfigureLink(url: url, token: token)
    }

    /// For display: `abcd…wxyz`.
    public var maskedToken: String {
        guard token.count > 8 else { return String(repeating: "•", count: token.count) }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }
}
