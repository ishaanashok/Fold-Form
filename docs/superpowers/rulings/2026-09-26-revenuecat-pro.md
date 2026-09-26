# RevenueCat Pro rulings — 2026-09-26

- **3 Free / 50 Pro Imagine cloud attempts per local day.** Cost if wrong: Free may be restrictive or Pro may be too generous; the constants are centralized.
- **Charge at cloud dispatch, including failed or cancelled calls.** Cost if wrong: a transient network failure uses a slot. Counting successes only could permit unbounded costly retries.
- **Development code is a persisted local override, not a RevenueCat promotional grant.** RevenueCat grants require a server-side secret or dashboard action; Apple offer codes require App Store Connect. Cost if wrong: a shared or tampered code gives unearned access, so it cannot ship as a secure promotion.
- **The placeholder key skips RevenueCat configuration.** Cost if wrong: that build cannot show a RevenueCat anonymous ID, offering price, or purchase/restore behavior; it avoids a fake SDK session and states the limitation clearly.
- **Test Store is the local payment path after the user supplies a real test key.** Cost if wrong: purchase flow cannot be tested yet. Bitrig does not launch via Xcode schemes, so a StoreKit configuration file would not exercise this app here.
- **Only extended Imagine usage is advertised as a Pro benefit.** Cost if wrong: the upgrade screen may seem sparse; no other app feature is presently gated, so claiming more would mislead users.
- **Manage Subscription appears for SDK-backed Pro, not for the local promo override alone.** Cost if wrong: promo users cannot open an empty management screen from the app, but they have no subscription to manage.
