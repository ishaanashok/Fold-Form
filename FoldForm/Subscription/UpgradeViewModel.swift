import Foundation
import Combine

enum UpgradePhase: Equatable {
    case idle
    case loading
    case priceUnavailable
    case ready(price: String)
    case purchasing(price: String)
    case cancelled(price: String)
    case purchased
    case failed(price: String?, message: String)
}

@MainActor
final class UpgradeViewModel: ObservableObject {
    @Published private(set) var phase: UpgradePhase = .idle
    private let service: any SubscriptionService
    private let entitlementStore: EntitlementStore
    private var price: String?

    init(service: any SubscriptionService, entitlementStore: EntitlementStore) {
        self.service = service
        self.entitlementStore = entitlementStore
    }

    func load() async {
        phase = .loading
        do {
            price = try await service.monthlyPriceString()
            phase = price.map { .ready(price: $0) } ?? .priceUnavailable
        } catch {
            price = nil
            phase = .failed(price: nil, message: error.localizedDescription)
        }
    }

    func purchase() async {
        guard let price else { phase = .priceUnavailable; return }
        phase = .purchasing(price: price)
        do {
            switch try await service.purchaseMonthly() {
            case .cancelled:
                phase = .cancelled(price: price)
            case .purchased:
                await entitlementStore.refresh()
                phase = entitlementStore.isPro ? .purchased : .failed(price: price, message: "Purchase completed, but Pro access hasn't appeared yet. Try Restore Purchases.")
            }
        } catch {
            phase = .failed(price: price, message: error.localizedDescription)
        }
    }

    func restore() async { await entitlementStore.restore() }
}
