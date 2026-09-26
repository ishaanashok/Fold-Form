import Foundation

struct SubscriptionStatus: Equatable, Sendable {
    var isPro: Bool
    var expiryDate: Date?
    var appUserID: String?
    var managementURL: URL? = nil
}

enum SubscriptionPurchaseResult: Equatable, Sendable {
    case purchased
    case cancelled
}

@MainActor
protocol SubscriptionService {
    func customerStatus() async throws -> SubscriptionStatus
    func monthlyPriceString() async throws -> String?
    func purchaseMonthly() async throws -> SubscriptionPurchaseResult
    func restorePurchases() async throws -> SubscriptionStatus
}
