import Foundation
import Combine

/// One service and quota shared by the dashboard and every editor in this app session.
@MainActor
final class SubscriptionContext: ObservableObject {
    var service: any SubscriptionService
    var entitlements: EntitlementStore
    var usageLimiter: ImagineUsageLimiter

    init() {
        let service = RevenueCatSubscriptionService()
        let entitlements = EntitlementStore(service: service)
        self.service = service
        self.entitlements = entitlements
        usageLimiter = ImagineUsageLimiter(entitlements: entitlements)
    }
}
