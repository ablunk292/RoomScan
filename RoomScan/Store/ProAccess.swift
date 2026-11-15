import StoreKit
import SwiftUI

/// RoomScan Pro unlocks AI item scans and Send to QuoteMaster. A person has it when their
/// company has the RoomScan add-on in QuoteMaster, or when they subscribe in this app.
///
/// The server decides: App Store purchases are sent to it, it checks them with Apple, and it
/// answers whether this account has Pro and whether Pro is required yet. Until the server
/// requires it, everyone signed in keeps full access.
@MainActor
final class ProAccess: ObservableObject {
    static let shared = ProAccess()

    /// Auto-renewing subscriptions in one group in App Store Connect (and RoomScan.storekit).
    static let productIDs = ["com.ablunk292.roomscan.pro.monthly", "com.ablunk292.roomscan.pro.yearly"]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isActive = false
    @Published private(set) var isRequired = false
    /// "quotemaster" or "app_store" while active.
    @Published private(set) var source: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var isPurchasing = false
    @Published var lastError: String?

    private var updates: Task<Void, Never>?

    /// Whether AI scans and Send to QuoteMaster may be used right now.
    var hasAccess: Bool { isActive || !isRequired }

    private init() {}

    func start() {
        guard updates == nil else { return }
        // Renewals, refunds, and purchases approved later (Ask to Buy) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await self?.report(transaction)
                await transaction.finish()
                await self?.fetchEntitlement()
            }
        }
        Task {
            await loadProducts()
            await refresh()
        }
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
        } catch {
            products = []
        }
    }

    /// Sends the current App Store subscription to the server, then asks it what this account has.
    func refresh() async {
        guard SessionStore.isSignedIn else {
            isActive = false
            isRequired = false
            source = nil
            expiresAt = nil
            return
        }
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID) {
                await report(transaction)
            }
        }
        await fetchEntitlement()
    }

    func purchase(_ product: Product) async {
        guard let session = SessionStore.load(), let account = UUID(uuidString: session.userID) else {
            lastError = "Sign in with your QuoteMaster account first."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        lastError = nil
        do {
            // The account id goes with the purchase, so the server only unlocks this account with it.
            switch try await product.purchase(options: [.appAccountToken(account)]) {
            case .success(.verified(let transaction)):
                await report(transaction)
                await transaction.finish()
            case .success(.unverified):
                lastError = "The App Store couldn't confirm this purchase. Try Restore Purchases."
            case .pending:
                lastError = "The purchase is waiting for approval. Pro unlocks as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
        await fetchEntitlement()
    }

    func restore() async {
        lastError = nil
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
        if !isActive, lastError == nil {
            lastError = "No RoomScan Pro subscription was found for this Apple ID."
        }
    }

    private struct Entitlement: Decodable {
        var active: Bool
        var source: String?
        var expires_at: String?
        var required: Bool
    }

    private func fetchEntitlement() async {
        #if DEBUG
        // Purchases made with RoomScan.storekit in Xcode are unknown to Apple's servers.
        if await hasLocalTestPurchase() {
            isActive = true
            source = "app_store"
            return
        }
        #endif
        guard let data = try? await CloudAPI.ai("entitlement", [:], timeout: 20),
              let answer = try? JSONDecoder().decode(Entitlement.self, from: data) else { return }
        isActive = answer.active
        isRequired = answer.required
        source = answer.source
        expiresAt = answer.expires_at.flatMap { ISO8601DateFormatter.withFractions.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
    }

    private func report(_ transaction: Transaction) async {
        guard SessionStore.isSignedIn, Self.productIDs.contains(transaction.productID) else { return }
        #if DEBUG
        if transaction.environment == .xcode { return }
        #endif
        do {
            _ = try await CloudAPI.ai("verify_purchase", ["transaction_id": String(transaction.originalID)], timeout: 30)
        } catch {
            lastError = error.localizedDescription
        }
    }

    #if DEBUG
    private func hasLocalTestPurchase() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.environment == .xcode,
               Self.productIDs.contains(transaction.productID) {
                return true
            }
        }
        return false
    }
    #endif
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
