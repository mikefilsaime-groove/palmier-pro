import AppKit
import Foundation

enum AccountTier: String, Decodable, Sendable {
    case none, pro, max

    var isPaid: Bool { self != .none }
    var planLabel: String { self == .none ? L10n.key("GodMode inactive") : L10n.key("GodMode active") }
    var upgradeLabel: String { self == .none ? "" : "GodMode" }
}

struct AccountUser: Decodable, Sendable {
    let email: String?
    let name: String?
    let image: String?
    let tier: AccountTier
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool?
    let spentCreditsThisPeriod: Int?
    let purchasedCredits: Int?

    var displayName: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var firstName: String? { displayName?.split(separator: " ").first.map(String.init) }
}

struct AccountPlan: Decodable, Sendable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let monthlyBudgetCredits: Int?
}

struct AvailablePlan: Decodable, Sendable, Identifiable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let discountedMonthlyPriceUsd: Int?
    let monthlyBudgetCredits: Int?
    var id: String { tier.rawValue }
    var effectiveMonthlyPriceUsd: Int { discountedMonthlyPriceUsd ?? monthlyPriceUsd }
    var hasDiscount: Bool { (discountedMonthlyPriceUsd ?? monthlyPriceUsd) < monthlyPriceUsd }
}

struct AccountResponse: Decodable, Sendable {
    let user: AccountUser
    let plan: AccountPlan?
}

enum TopOffLimits {
    static let minDollars = 5
    static let maxDollars = 1000
}

@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private var session: CreatorStudioSession { .shared }

    var isLoading: Bool { session.access == .checking }
    var isMisconfigured: Bool { !session.isConfigured }
    var isSignedIn: Bool { session.isSignedIn }
    var aiAllowed: Bool { session.canUseProtectedFeatures }
    var tier: AccountTier { session.canUseProtectedFeatures ? .max : .none }
    var isPaid: Bool { session.canUseProtectedFeatures }
    var spentCredits: Int { 0 }
    var budgetCredits: Int? { nil }
    var remainingCredits: Int { isPaid ? .max : 0 }
    var hasCredits: Bool { isPaid }
    var isSigningIn: Bool { session.isSigningIn }
    var isBuyingCredits: Bool { false }
    var lastError: String? { session.lastError }
    var availablePlans: [AvailablePlan] { [] }
    var account: AccountResponse? {
        guard isSignedIn else { return nil }
        return AccountResponse(
            user: AccountUser(
                email: session.email,
                name: session.displayName,
                image: nil,
                tier: tier,
                currentPeriodEnd: nil,
                cancelAtPeriodEnd: nil,
                spentCreditsThisPeriod: nil,
                purchasedCredits: nil
            ),
            plan: nil
        )
    }

    private init() {}

    func configure() { session.configure() }
    func connectGodModeMCP() { SettingsWindowController.shared.show(tab: .account) }
    func signOut() async { await session.signOut() }

    func subscribe(tier: AccountTier) async { openGodModeDashboard() }
    func buyCredits(dollars: Int) { openGodModeDashboard() }
    func manageSubscription() async { openGodModeDashboard() }

    private func openGodModeDashboard() {
        guard let url = URL(string: "https://app.scaleplus.gg/dashboard") else { return }
        NSWorkspace.shared.open(url)
    }

    var displayPrimaryText: String {
        if !isSignedIn { return L10n.string("Signed out") }
        return account?.user.displayName ?? account?.user.email ?? L10n.string("Signed in")
    }

    var displaySecondaryText: String? {
        guard isSignedIn else { return nil }
        return account?.user.displayName != nil ? account?.user.email : nil
    }

    var displayInitial: String {
        guard isSignedIn else { return "" }
        let source = account?.user.displayName ?? account?.user.email ?? ""
        return source.first.map { String($0).uppercased() } ?? ""
    }

    func availablePlan(for tier: AccountTier) -> AvailablePlan? { nil }
}
