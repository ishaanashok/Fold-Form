import Foundation

@MainActor
protocol ImagineUsageLimiting: AnyObject {
    var remaining: Int { get }
    var dailyLimit: Int { get }
    func canGenerate() -> Bool
    @discardableResult func recordGeneration(id: UUID) -> Bool
}

/// Counts cloud attempts by request ID. A failed or cancelled cloud call still uses one slot.
/// Local UserDefaults can be reset/tampered with; production abuse protection belongs server-side.
@MainActor
final class ImagineUsageLimiter: ImagineUsageLimiting {
    private let entitlements: EntitlementStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar

    init(entitlements: EntitlementStore, defaults: UserDefaults = .standard, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.entitlements = entitlements
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    var dailyLimit: Int {
        entitlements.isPro ? SubscriptionConfiguration.proDailyImagineLimit : SubscriptionConfiguration.freeDailyImagineLimit
    }

    var remaining: Int { max(0, dailyLimit - usedIDs().count) }

    func canGenerate() -> Bool { remaining > 0 }

    @discardableResult
    func recordGeneration(id: UUID) -> Bool {
        var ids = usedIDs()
        guard !ids.contains(id.uuidString), ids.count < dailyLimit else { return false }
        ids.append(id.uuidString)
        defaults.set(ids, forKey: SubscriptionConfiguration.usageIDsKey)
        return true
    }

    private func usedIDs() -> [String] {
        let today = calendar.startOfDay(for: now())
        if let savedDay = defaults.object(forKey: SubscriptionConfiguration.usageDayKey) as? Date,
           calendar.isDate(savedDay, inSameDayAs: today) {
            return defaults.stringArray(forKey: SubscriptionConfiguration.usageIDsKey) ?? []
        }
        defaults.set(today, forKey: SubscriptionConfiguration.usageDayKey)
        defaults.set([String](), forKey: SubscriptionConfiguration.usageIDsKey)
        return []
    }
}
