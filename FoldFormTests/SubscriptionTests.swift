import XCTest
@testable import FoldForm

@MainActor
private final class FakeSubscriptionService: SubscriptionService {
    var status = SubscriptionStatus(isPro: false, expiryDate: nil, appUserID: "$RCAnonymousID:test")
    var monthlyPrice: String? = "$2.99"
    var purchaseResult: SubscriptionPurchaseResult = .purchased
    var failure: Error?

    func customerStatus() async throws -> SubscriptionStatus {
        if let failure { throw failure }
        return status
    }

    func monthlyPriceString() async throws -> String? {
        if let failure { throw failure }
        return monthlyPrice
    }

    func purchaseMonthly() async throws -> SubscriptionPurchaseResult {
        if let failure { throw failure }
        return purchaseResult
    }

    func restorePurchases() async throws -> SubscriptionStatus {
        if let failure { throw failure }
        return status
    }
}

private enum TestServiceError: Error { case unavailable }

@MainActor
final class SubscriptionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "FoldForm.SubscriptionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testEntitlementTracksServiceStatusAndExpiry() async {
        let service = FakeSubscriptionService()
        let store = EntitlementStore(service: service, defaults: defaults)
        await store.refresh()
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.appUserID, "$RCAnonymousID:test")
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        service.status = .init(isPro: true, expiryDate: expiry, appUserID: "$RCAnonymousID:test")
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.expiryDate, expiry)
    }

    func testPromoAcceptsOnlyCorrectCodeAndPersists() {
        let service = FakeSubscriptionService()
        let store = EntitlementStore(service: service, defaults: defaults)
        XCTAssertFalse(store.redeemPromoCode("WRONG"))
        XCTAssertFalse(store.isPro)
        XCTAssertTrue(store.redeemPromoCode(SubscriptionConfiguration.developmentPromoCode))
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(store.isPromoOverride)
        let relaunched = EntitlementStore(service: service, defaults: defaults)
        XCTAssertTrue(relaunched.isPro)
        XCTAssertTrue(relaunched.isPromoOverride)
    }

    func testRestoreRefreshesEntitlement() async {
        let service = FakeSubscriptionService()
        let store = EntitlementStore(service: service, defaults: defaults)
        service.status = .init(isPro: true, expiryDate: nil, appUserID: "$RCAnonymousID:test")
        await store.restore()
        XCTAssertTrue(store.isPro)
    }

    func testUpgradeStatesForPriceUnavailableCancellationAndFailure() async {
        let service = FakeSubscriptionService()
        let store = EntitlementStore(service: service, defaults: defaults)
        let model = UpgradeViewModel(service: service, entitlementStore: store)
        XCTAssertEqual(model.phase, .idle)
        service.monthlyPrice = nil
        await model.load()
        XCTAssertEqual(model.phase, .priceUnavailable)
        service.monthlyPrice = "€2.99"
        await model.load()
        XCTAssertEqual(model.phase, .ready(price: "€2.99"))
        service.purchaseResult = .cancelled
        await model.purchase()
        XCTAssertEqual(model.phase, .cancelled(price: "€2.99"))
        service.failure = TestServiceError.unavailable
        await model.purchase()
        guard case .failed(price: "€2.99", message: _) = model.phase else { return XCTFail("Expected failure with the known price") }
    }

    func testFreeAndProLimitsAndDuplicateRequest() {
        let service = FakeSubscriptionService()
        let store = EntitlementStore(service: service, defaults: defaults)
        var today = Date(timeIntervalSince1970: 1_800_000_000)
        let limiter = ImagineUsageLimiter(entitlements: store, defaults: defaults, now: { today })
        XCTAssertEqual(limiter.remaining, 3)
        let first = UUID()
        XCTAssertTrue(limiter.recordGeneration(id: first))
        XCTAssertFalse(limiter.recordGeneration(id: first))
        XCTAssertEqual(limiter.remaining, 2)
        XCTAssertTrue(limiter.recordGeneration(id: UUID()))
        XCTAssertTrue(limiter.recordGeneration(id: UUID()))
        XCTAssertFalse(limiter.canGenerate())
        XCTAssertFalse(limiter.recordGeneration(id: UUID()))
        XCTAssertTrue(store.redeemPromoCode(SubscriptionConfiguration.developmentPromoCode))
        XCTAssertEqual(limiter.remaining, 47)
        today = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        XCTAssertEqual(limiter.remaining, 50)
    }

    func testUsageSurvivesRelaunchAndRollsOverAtLocalMidnight() {
        let service = FakeSubscriptionService()
        let store = EntitlementStore(service: service, defaults: defaults)
        let calendar = Calendar(identifier: .gregorian)
        var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 23, minute: 59))!
        let limiter = ImagineUsageLimiter(entitlements: store, defaults: defaults, now: { now })
        XCTAssertTrue(limiter.recordGeneration(id: UUID()))
        let relaunched = ImagineUsageLimiter(entitlements: store, defaults: defaults, now: { now })
        XCTAssertEqual(relaunched.remaining, 2)
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 0, minute: 1))!
        XCTAssertEqual(relaunched.remaining, 3)
    }
}
