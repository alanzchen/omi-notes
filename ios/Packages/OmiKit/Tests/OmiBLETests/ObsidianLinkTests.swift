import Foundation
import Testing
@testable import OmiBLE

@Suite struct ObsidianLinkTests {
    @Test func encodesSpacesUnicodeAndNestedPaths() throws {
        let url = try #require(ObsidianLink.url(vault: "My Notes", notePath: "Conversations/2026/2026-09/2026-09-26 1403 Café & Budget #2.md"))
        #expect(url.absoluteString == "obsidian://open?vault=My%20Notes&file=Conversations%2F2026%2F2026-09%2F2026-09-26%201403%20Caf%C3%A9%20%26%20Budget%20%232")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.first { $0.name == "file" }?.value == "Conversations/2026/2026-09/2026-09-26 1403 Café & Budget #2")
    }

    @Test func refusesWhatIsNotAVaultNote() {
        #expect(ObsidianLink.url(vault: " ", notePath: "a.md") == nil)
        #expect(ObsidianLink.url(vault: "V", notePath: "a.txt") == nil)
        #expect(ObsidianLink.url(vault: "V", notePath: "../outside.md") == nil)
        #expect(ObsidianLink.url(vault: "V", notePath: "/abs.md") == nil)
    }

    @Test func theNameIsRememberedPerVaultAndTheFolderIsOnlyASuggestion() {
        let d = UserDefaults(suiteName: "obsidian-\(UUID().uuidString)")!
        #expect(ObsidianLink.suggestedVault(notesDir: "/Users/alan/OmiNotes") == "OmiNotes")
        ObsidianLink.setVaultName("Work vault", for: "v1", defaults: d)
        #expect(ObsidianLink.vaultName(for: "v1", defaults: d) == "Work vault" && ObsidianLink.vaultName(for: "v2", defaults: d) == nil)
        ObsidianLink.setVaultName("  ", for: "v1", defaults: d)
        #expect(ObsidianLink.vaultName(for: "v1", defaults: d) == nil)
    }
}
