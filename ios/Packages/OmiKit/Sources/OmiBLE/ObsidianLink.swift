import Foundation

/// `obsidian://open?vault=…&file=…` for a note (https://obsidian.md/help/uri).
///
/// The vault name is the user's (it names the vault in the Obsidian app on this phone, which may
/// differ from the folder name on the server), remembered per server vault. The link only says
/// where the note should be: the phone may not have synced it yet, or may not have this vault.
public enum ObsidianLink {
    /// Strict percent-encoding: `&`, `=`, `+`, `#` and `/` inside a value can't be misread.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    /// nil without a vault name or a Markdown note path.
    public static func url(vault: String, notePath: String) -> URL? {
        let name = vault.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, notePath.hasSuffix(".md"), !notePath.hasPrefix("/"),
              !notePath.split(separator: "/").contains("..") else { return nil }
        let file = String(notePath.dropLast(3))
        return URL(string: "obsidian://open?vault=\(encode(name))&file=\(encode(file))")
    }

    /// The server's notes folder name: a suggestion for the vault name, not a fact about this phone.
    public static func suggestedVault(notesDir: String?) -> String? {
        guard let dir = notesDir, !dir.isEmpty else { return nil }
        let last = URL(fileURLWithPath: dir).lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }

    static func key(vaultId: String) -> String { "omi.obsidianVault.\(vaultId)" }

    public static func vaultName(for vaultId: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(vaultId: vaultId))
    }

    public static func setVaultName(_ name: String?, for vaultId: String, defaults: UserDefaults = .standard) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed?.isEmpty == false ? trimmed : nil, forKey: key(vaultId: vaultId))
    }
}
