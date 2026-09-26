import Foundation
import RevenueCat

/// The sole boundary to RevenueCat. SDK Package and CustomerInfo objects stay on the main actor.
@MainActor
final class RevenueCatSubscriptionService: SubscriptionService {
    private var monthlyPackage: Package?

    init() {
        if SubscriptionConfiguration.hasRealSDKKey {
            Purchases.configure(withAPIKey: SubscriptionConfiguration.sdkKey)
        }
    }

    func customerStatus() async throws -> SubscriptionStatus {
        guard SubscriptionConfiguration.hasRealSDKKey else { return .init(isPro: false, expiryDate: nil, appUserID: nil) }
        let info = try await Purchases.shared.customerInfo()
        return status(from: info)
    }

    func monthlyPriceString() async throws -> String? {
        guard SubscriptionConfiguration.hasRealSDKKey else { return nil }
        let offerings = try await Purchases.shared.offerings()
        monthlyPackage = offerings.current?.monthly
        return monthlyPackage?.storeProduct.localizedPriceString
    }

    func purchaseMonthly() async throws -> SubscriptionPurchaseResult {
        guard SubscriptionConfiguration.hasRealSDKKey else { throw SubscriptionServiceError.notConfigured }
        if monthlyPackage == nil { _ = try await monthlyPriceString() }
        guard let monthlyPackage else { throw SubscriptionServiceError.priceUnavailable }
        let result = try await Purchases.shared.purchase(package: monthlyPackage)
        return result.userCancelled ? .cancelled : .purchased
    }

    func restorePurchases() async throws -> SubscriptionStatus {
        guard SubscriptionConfiguration.hasRealSDKKey else { throw SubscriptionServiceError.notConfigured }
        let info = try await Purchases.shared.restorePurchases()
        return status(from: info)
    }

    private func status(from info: CustomerInfo) -> SubscriptionStatus {
        let entitlement = info.entitlements.all[SubscriptionConfiguration.entitlementID]
        return .init(
            isPro: entitlement?.isActive == true,
            expiryDate: entitlement?.isActive == true ? entitlement?.expirationDate : nil,
            appUserID: Purchases.shared.appUserID,
            managementURL: info.managementURL
        )
    }
}

enum SubscriptionServiceError: LocalizedError {
    case notConfigured
    case priceUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Purchases aren't configured yet. Add a RevenueCat public SDK key to enable them."
        case .priceUnavailable: "The monthly plan isn't available right now. Try again later."
        }
    }
}
