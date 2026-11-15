import StoreKit
import SwiftUI

/// Explains RoomScan Pro and sells the App Store subscription.
struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProAccess.shared
    @ObservedObject private var sync = CloudSync.shared
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text("RoomScan Pro").font(.largeTitle.bold())
                        Text("Let AI document every room, and turn a walkthrough into a quote.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        feature("viewfinder", "AI item scan", "Point at each wall, the ceiling and the floor. The AI lists what it sees, with photos.")
                        feature("doc.text.magnifyingglass", "Send to QuoteMaster", "Build a draft quote from a walkthrough in a few steps.")
                        feature("bubble.left.and.text.bubble.right", "AI helper on the web", "Ask about a walkthrough and add items from the conversation.")
                    }

                    if pro.isActive {
                        Label(activeText, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                    } else if !sync.isSignedIn {
                        Button {
                            signingIn = true
                        } label: {
                            Text("Sign In to Subscribe").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Pro belongs to your QuoteMaster account, so it works on every device you sign in on.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if pro.products.isEmpty {
                        ProgressView("Loading plans…").frame(maxWidth: .infinity)
                    } else {
                        ForEach(pro.products, id: \.id) { product in
                            planButton(product)
                        }
                    }

                    if let error = pro.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }

                    Button("Restore Purchases") { Task { await pro.restore() } }
                        .font(.subheadline)
                        .disabled(!sync.isSignedIn)

                    Text("Does your company use QuoteMaster? Pro is included when your company adds RoomScan to its QuoteMaster plan. Sign in with your QuoteMaster account and it unlocks on its own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Subscriptions renew automatically until cancelled. Payment is charged to your Apple ID. Cancel at least 24 hours before the end of the period in Settings → Apple ID → Subscriptions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Link("Privacy Policy", destination: CloudConfig.webApp.appendingPathComponent("privacy"))
                    }
                    .font(.caption)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $signingIn) { SignInView() }
            .task { await pro.loadProducts() }
            .onChange(of: pro.isActive) {
                if pro.isActive { dismiss() }
            }
        }
    }

    private var activeText: String {
        pro.source == "quotemaster" ? "Included with your company's QuoteMaster plan" : "You have RoomScan Pro"
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func planButton(_ product: Product) -> some View {
        Button {
            Task { await pro.purchase(product) }
        } label: {
            VStack(spacing: 2) {
                Text("\(product.displayName) · \(product.displayPrice)\(period(product))")
                    .font(.headline)
                if let trial = trialText(product) {
                    Text(trial).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(pro.isPurchasing)
    }

    private func period(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .month: return period.value == 1 ? " a month" : " every \(period.value) months"
        case .year: return period.value == 1 ? " a year" : " every \(period.value) years"
        case .week: return " a week"
        case .day: return " a day"
        @unknown default: return ""
        }
    }

    private func trialText(_ product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let unit: String
        switch offer.period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        let count = offer.period.value
        return "Free for \(count) \(unit)\(count == 1 ? "" : "s"), then renews"
    }
}
