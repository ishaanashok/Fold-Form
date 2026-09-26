# RevenueCat Pro implementation plan — 2026-09-26

## Scope and evidence

RevenueCat's iOS installation guide specifies `https://github.com/RevenueCat/purchases-ios-spm.git`, product `RevenueCat`, and a 5.0.0 minimum. Its Test Store requires SDK 5.43.0+, so this project uses a 5.43.0 floor. The quickstart documents `Purchases.configure(withAPIKey:)`, anonymous IDs when no app user ID is passed, `customerInfo()`, entitlement checks, and customer-info updates. Its product guide documents `getOfferings()`, `current.monthly`, and `Package.storeProduct`; its purchase and restore guides document `purchase(package:)` and `restorePurchases()`. SDK source/API will settle exact Swift 6 signatures after resolution.

Sources: https://www.revenuecat.com/docs/getting-started/installation/ios ; https://www.revenuecat.com/docs/getting-started/quickstart ; https://www.revenuecat.com/docs/getting-started/displaying-products ; https://www.revenuecat.com/docs/getting-started/making-purchases ; https://www.revenuecat.com/docs/getting-started/restoring-purchases ; https://www.revenuecat.com/docs/test-and-launch/sandbox/test-store ; https://www.revenuecat.com/docs/subscription-guidance/subscription-offers/ios-subscription-offers ; https://www.revenuecat.com/docs/dashboard-and-metrics/customer-profile ; https://www.revenuecat.com/docs/api-v2

## Architecture

- All new production types live in `FoldForm/Subscription/`: `SubscriptionConfiguration` (single fake SDK key, entitlement/product identifiers, limits, promo code), `SubscriptionService`/RevenueCat adapter, `EntitlementStore` (`@MainActor ObservableObject`), `ImagineUsageLimiting`/persistent daily limiter, account and upgrade views and an upgrade view model.
- The service returns plain Sendable snapshots of customer status and the monthly package. It owns the SDK `Package` so no SDK object crosses the strict-concurrency UI boundary. The real adapter uses RevenueCat for configuration, offerings, purchase, customer info, entitlement and restore. With the placeholder key it remains unconfigured and reports price unavailable; the views explain setup is pending. Tests inject a fake service and isolated UserDefaults.
- `AppRoot` owns one entitlement store and limiter, passes them to the dashboard and editor. `ImagineSession.generate` checks the limiter immediately before cloud generation and records the attempt once; a quota failure exposes an upsell in `ImagineView`. No sign-in.
- Daily limits: Free 3, Pro 50, reset at local calendar-day rollover. Count a cloud attempt once when it is started, including failed/cancelled requests; local validation/capture failures do not count. Persist date/count in UserDefaults. This limits cost, but a local counter can be cleared or altered and needs server-side enforcement for abuse resistance.
- Upgrade benefits: **50 Imagine requests per day instead of 3** (enforced). Other CAD, voice, export and document features are already free and will not be claimed as Pro benefits. Show the current Offering's localized monthly price only; never hardcode $2.99 in UI.
- RevenueCat promotional grants require a privileged server/dashboard action. Apple offer codes must be configured in App Store Connect and redeemed through its flow; neither accepts a secure app-hardcoded code. Implement the requested code as an explicit persisted local development/promo override. It is **not secure** and must move to a server-backed promotional entitlement or Apple offer code before a real release. The override is labeled in account details and does not impersonate an SDK entitlement.
- Use RevenueCat Test Store for local purchase testing after the user supplies a real Test Store key and product setup. No StoreKit file: Bitrig's run path does not use Xcode schemes. No real payment or account actions in this task.

## Tasks

1. Commit this plan. Add the SDK package to `project.yml`, generate XcodeGen project, inspect the resolved SDK signatures.
2. RED→GREEN tests for `EntitlementStore` with fake service: active/inactive status, expiry, restore, cancelled/failed purchase, promo right/wrong/persistence, upgrade loading/unavailable/failure. Run the full unit suite, commit.
3. RED→GREEN limiter tests: free/Pro boundaries, local-day rollover, persistence, no double counting of the same Imagine request. Wire `ImagineSession` and upsell with a minimal change. Run the full unit suite, commit.
4. Add account toolbar button/page and upgrade page with accessible controls and honest states. Build and run the full unit suite without UI tests or live simulator control. Review diff and commit.

## Rulings and cost if wrong

- Count attempted cloud requests, including failed/cancelled ones. Cost if wrong: users may use quota on a network failure; this can change to successful-only accounting but would allow unlimited costly retries.
- Use 3/50 daily requests. Cost if wrong: free tier may be too restrictive or Pro too generous; both constants are centralized.
- With the fake key, avoid configuring RevenueCat. Cost if wrong: the placeholder build cannot show a RevenueCat anonymous ID or prices, but avoids an invalid SDK session and offers a truthful unavailable state.
- Treat the hardcoded code as a local override, separate from RevenueCat entitlement. Cost if wrong: it can be shared or tampered with; it cannot ship as a secure promotion.
