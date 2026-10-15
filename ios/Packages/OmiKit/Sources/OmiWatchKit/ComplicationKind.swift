import Foundation

/// Shared between the Watch app and its complication extension.
public enum ComplicationKind {
    public static let status = "OmiNotesStatus"
    /// Opens the Watch app's (only) screen; it shows the status and never starts or stops anything.
    public static let statusURL = URL(string: "omi-notes-watch://status")!

    /// `<team>.dev.omi-notes.shared`, from the bundle's Info.plist (`OmiSharedKeychainGroup`).
    public static var accessGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "OmiSharedKeychainGroup") as? String, !g.isEmpty, !g.hasPrefix("$(") else { return nil }
        return g
    }
}
