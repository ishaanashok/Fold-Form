import SwiftUI

struct AccountView: View {
    @ObservedObject var entitlements: EntitlementStore
    var service: any SubscriptionService
    var usageLimiter: any ImagineUsageLimiting
    @State private var promoCode = ""
    @State private var isRestoring = false

    var body: some View {
        Form {
            Section("Plan") {
                LabeledContent("Current plan", value: entitlements.isPro ? "Pro" : "Free")
                if entitlements.isPromoOverride {
                    Text("Development promo access on this device")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let expiryDate = entitlements.expiryDate {
                    LabeledContent(entitlements.willRenew == true ? "Renews" : "Expires") {
                        Text(expiryDate, format: .dateTime.month().day().year())
                    }
                }
                LabeledContent("Imagine today", value: "\(usageLimiter.dailyLimit - usageLimiter.remaining) of \(usageLimiter.dailyLimit) used")
                if !entitlements.isPro {
                    NavigationLink("Upgrade to Pro") {
                        UpgradeView(service: service, entitlements: entitlements)
                    }
                }
            }

            Section("RevenueCat account") {
                LabeledContent("Anonymous app user ID") {
                    Text(entitlements.appUserID ?? "Unavailable until purchases are configured")
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                Text("FoldForm does not require sign-in. Purchases belong to the App Store account used on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Purchases") {
                Button("Restore Purchases", systemImage: "arrow.clockwise") {
                    isRestoring = true
                    Task {
                        await entitlements.restore()
                        isRestoring = false
                    }
                }
                .disabled(isRestoring)
                if isRestoring { ProgressView("Restoring…") }
                if entitlements.hasStorePro {
                    Link("Manage Subscription", destination: entitlements.managementURL ?? URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                if let message = entitlements.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Promo code") {
                TextField("Enter promo code", text: $promoCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("promoCodeField")
                Button("Redeem Code") {
                    if entitlements.redeemPromoCode(promoCode) { promoCode = "" }
                }
                .disabled(promoCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("This development code unlocks Pro only on this installation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Account")
        .task { await entitlements.refresh() }
    }
}
