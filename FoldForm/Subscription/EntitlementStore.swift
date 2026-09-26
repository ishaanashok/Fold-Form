import Foundation
import Combine

@MainActor
final class EntitlementStore: ObservableObject {
    @Published private(set) var isPro: Bool
    @Published private(set) var isPromoOverride: Bool
    @Published private(set) var hasStorePro = false
    @Published private(set) var willRenew: Bool?
    @Published private(set) var expiryDate: Date?
    @Published private(set) var appUserID: String?
    @Published private(set) var managementURL: URL?
    @Published private(set) var message: String?

    private let service: any SubscriptionService
    private let defaults: UserDefaults
    private var sdkIsPro = false

    init(service: any SubscriptionService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        let overrideEnabled = defaults.bool(forKey: SubscriptionConfiguration.promoOverrideKey)
        isPromoOverride = overrideEnabled
        isPro = overrideEnabled
    }

    func refresh() async {
        do {
            apply(try await service.customerStatus())
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        do {
            apply(try await service.restorePurchases())
            message = hasStorePro ? "Pro access restored." : "No active Pro purchase was found."
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func redeemPromoCode(_ code: String) -> Bool {
        guard code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == SubscriptionConfiguration.developmentPromoCode else {
            message = "That promo code isn't valid."
            return false
        }
        defaults.set(true, forKey: SubscriptionConfiguration.promoOverrideKey)
        isPromoOverride = true
        isPro = true
        message = "Development Pro access enabled on this device."
        return true
    }

    private func apply(_ status: SubscriptionStatus) {
        sdkIsPro = status.isPro
        hasStorePro = status.isPro
        willRenew = status.willRenew
        isPro = sdkIsPro || isPromoOverride
        expiryDate = status.expiryDate
        appUserID = status.appUserID
        managementURL = status.managementURL
    }
}
