import Foundation

@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private var session: CreatorStudioSession { .shared }

    var isLoading: Bool { session.isRestoringConnection }
    var isMisconfigured: Bool { !session.isConfigured }
    var isConnected: Bool { session.isSignedIn }
    var isSigningIn: Bool { session.isSigningIn }
    var lastError: String? { session.lastError }

    private init() {}

    func configure() { session.configure() }
    func connectCreatorStudio() { SettingsCoordinator.shared.show(tab: .account) }
    func disconnectCreatorStudio() async { await session.signOut() }

    var displayPrimaryText: String {
        isConnected ? L10n.string("Connected") : L10n.string("Connect")
    }

    var displaySecondaryText: String? {
        isConnected ? L10n.string("Fal.ai account sync") : nil
    }

    var displayInitial: String { isConnected ? "C" : "" }
}
