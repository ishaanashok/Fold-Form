import Foundation

enum SubscriptionConfiguration {
    /// Replace only this public SDK key for a configured RevenueCat app. Never commit a real key.
    static let sdkKey = "appl_PLACEHOLDER_REPLACE_ME"
    static let entitlementID = "pro"
    static let monthlyProductID = "foldform_pro_monthly"
    static let freeDailyImagineLimit = 3
    static let proDailyImagineLimit = 50

    /// Development-only local override. Not secure: move redemption to a server-backed
    /// RevenueCat promotional entitlement or Apple offer codes before a real release.
    static let developmentPromoCode = "FOLDFORM-PRO-DEV"
    static let promoOverrideKey = "subscription.developmentPromoOverride"
    static let usageDayKey = "subscription.imagineUsageDay"
    static let usageIDsKey = "subscription.imagineUsageIDs"

    static var hasRealSDKKey: Bool { sdkKey != "appl_PLACEHOLDER_REPLACE_ME" }
}
