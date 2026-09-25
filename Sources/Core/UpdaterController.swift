import Foundation
import Sparkle

/// Sparkle auto-updates from the GitHub Releases appcast. The feed URL and
/// EdDSA public key live in Info.plist (SUFeedURL / SUPublicEDKey); releases
/// are signed with the matching private key in CI.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
