import Foundation
import Logging
import StoreKit

@MainActor
@Observable
final class IAPManager {
    static let shared = IAPManager()

    static let tipProductIDs = [
        "com.enve.tip.coffee",
        "com.enve.tip.generousCoffee",
        "com.enve.tip.veryGenerous",
        "com.enve.tip.extremelyGenerous",
    ]

    private static let legacyTipProductIDs = [
        "com.narratarr.tip.coffee",
        "com.narratarr.tip.generousCoffee",
        "com.narratarr.tip.veryGenerous",
        "com.narratarr.tip.extremelyGenerous",
    ]

    private static func legacyTipProductID(for currentProductID: String) -> String? {
        guard let index = tipProductIDs.firstIndex(of: currentProductID), index < legacyTipProductIDs.count else {
            return nil
        }
        return legacyTipProductIDs[index]
    }

    var isLoading: Bool = false
    var products: [Product] = []
    var purchasedProductIDs = Set<String>()
    var lastLoadErrorMessage: String?

    @ObservationIgnored private var updateListenerTask: Task<Void, Error>?

    private init() {
        updateListenerTask = listenForTransactions()

        Task {
            await loadProducts()
            await updatePurchaseStatus()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    func loadProducts() async {
        do {
            let allProductIDs = Self.tipProductIDs + Self.legacyTipProductIDs
            let allIDs = Array(Set(allProductIDs))
            products = try await Product.products(for: allIDs)
            lastLoadErrorMessage = nil

            let returnedIDs = Set(products.map(\.id))
            let missingCurrentIDs = Self.tipProductIDs.filter { !returnedIDs.contains($0) }
            if !missingCurrentIDs.isEmpty {
                AppLogger.network.warning("Missing current products: \(missingCurrentIDs.joined(separator: ", "))")
            }
        } catch {
            AppLogger.network.error("Failed to load products: \(error)")
            lastLoadErrorMessage = error.localizedDescription
        }
    }

    func product(for productID: String) -> Product? {
        return products.first { $0.id == productID }
    }

    func resolvedTipProduct(for preferredProductID: String) -> Product? {
        if let current = product(for: preferredProductID) {
            return current
        }

        if let legacyID = Self.legacyTipProductID(for: preferredProductID) {
            return product(for: legacyID)
        }

        return nil
    }

    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try Self.checkVerified(result)
                    await self.updatePurchasedProducts()
                    await transaction.finish()
                } catch {
                    AppLogger.network.error("Transaction verification failed: \(error)")
                }
            }
        }
    }

    private nonisolated static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    func updatePurchasedProducts() async {
        var newPurchasedIDs = Set<String>()

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try Self.checkVerified(result)

                if transaction.revocationDate == nil {
                    newPurchasedIDs.insert(transaction.productID)
                }
            } catch {
                AppLogger.network.error("Failed to verify transaction: \(error)")
            }
        }

        purchasedProductIDs = newPurchasedIDs

    }

    func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }

        try? await AppStore.sync()
        await updatePurchasedProducts()
    }

    private func updatePurchaseStatus() async {
        await updatePurchasedProducts()
    }

    func purchase(_ product: Product) async throws {
        isLoading = true
        defer { isLoading = false }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try Self.checkVerified(verification)
            await updatePurchasedProducts()
            await transaction.finish()

        case .userCancelled:
            throw StoreError.userCancelled

        case .pending:
            throw StoreError.pending

        @unknown default:
            throw StoreError.unknown
        }
    }

    func purchaseTip(productID: String) async throws {
        if resolvedTipProduct(for: productID) == nil {
            await loadProducts()
        }

        guard let product = resolvedTipProduct(for: productID) else {
            throw StoreError.productNotFound
        }

        try await purchase(product)
    }
}

enum StoreError: Error {
    case failedVerification
    case userCancelled
    case pending
    case productNotFound
    case unknown
}

extension StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "Transaction verification failed"
        case .userCancelled:
            return "Purchase was cancelled"
        case .pending:
            return "Purchase is pending"
        case .productNotFound:
            return
                "Purchase product could not be loaded. Check App Store Connect product IDs or run with the StoreKit configuration attached to the scheme."
        case .unknown:
            return "An unknown error occurred"
        }
    }
}
