import Foundation

@MainActor
public final class HardcoverAutoMatcher {
    static let shared = HardcoverAutoMatcher()
    var onPendingConfirmation: ((Book) -> Void)?

    func attemptAutoMatch(for book: Book) async {
        guard SettingsManager.shared.hardcoverAutoSyncEnabled, HardcoverSyncService.hasProfileAccess,
              let token = SettingsManager.shared.hardcoverApiKey else { return }
        do {
            let match = try await HardcoverService.$syncToken.withValue(token) {
                try await HardcoverSyncService.shared.resolveMatch(for: book)
            }
            guard SettingsManager.shared.hardcoverApiKey == token, HardcoverSyncService.hasProfileAccess else { return }
            SettingsManager.shared.addHardcoverMatch(match)
        } catch is CancellationError {
        } catch {
            onPendingConfirmation?(book)
        }
    }
}
