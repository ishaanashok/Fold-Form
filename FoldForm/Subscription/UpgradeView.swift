import SwiftUI

struct UpgradeView: View {
    @ObservedObject var entitlements: EntitlementStore
    @StateObject private var model: UpgradeViewModel
    @State private var isRestoring = false

    init(service: any SubscriptionService, entitlements: EntitlementStore) {
        self.entitlements = entitlements
        _model = StateObject(wrappedValue: UpgradeViewModel(service: service, entitlementStore: entitlements))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("More room to Imagine")
                        .font(.title2.bold())
                    Text("Pro raises your daily cloud generation limit for design changes from 3 to 50.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            Section("Included with Pro") {
                Label("50 Imagine generations per day", systemImage: "checkmark.seal")
                Text("Free includes 3 Imagine generations per day. Other design tools remain available on both plans.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Monthly subscription") {
                switch model.phase {
                case .idle, .loading:
                    ProgressView("Loading local price…")
                case .priceUnavailable:
                    Text("Price unavailable. Purchases aren't configured or the monthly plan couldn't be loaded.")
                        .foregroundStyle(.secondary)
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await model.load() } }
                case .ready(let price), .purchasing(let price), .cancelled(let price):
                    priceRow(price)
                case .purchased:
                    Label("Pro is active", systemImage: "checkmark.seal")
                case .failed(let price, let message):
                    if let price { priceRow(price) }
                    Text(message).foregroundStyle(.red)
                    if price == nil {
                        Button("Try Again", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    }
                }

                if let message = statusMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if let price = purchasablePrice {
                    Button("Subscribe for \(price) / month") { Task { await model.purchase() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPurchasing)
                        .accessibilityIdentifier("purchaseProButton")
                }
                Button("Restore Purchases", systemImage: "arrow.clockwise") {
                    isRestoring = true
                    Task {
                        await model.restore()
                        isRestoring = false
                    }
                }
                .disabled(isRestoring)
                if isRestoring { ProgressView("Restoring…") }
                if let message = entitlements.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Text("The subscription renews monthly until cancelled in Apple subscription settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("FoldForm Pro")
        .task { await model.load() }
    }

    private func priceRow(_ price: String) -> some View {
        LabeledContent("Price", value: "\(price) per month")
    }

    private var isPurchasing: Bool {
        if case .purchasing = model.phase { return true }
        return false
    }

    private var purchasablePrice: String? {
        switch model.phase {
        case .ready(let price), .cancelled(let price), .failed(.some(let price), _): price
        default: nil
        }
    }

    private var statusMessage: String? {
        switch model.phase {
        case .cancelled: "Purchase cancelled. No charge was made."
        case .purchasing: "Confirm the subscription in the system purchase sheet."
        default: nil
        }
    }
}
