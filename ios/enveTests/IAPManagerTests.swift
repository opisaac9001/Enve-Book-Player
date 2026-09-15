import Foundation
import Testing

@testable import enve

@MainActor
struct IAPManagerTests {
    @Test func requestFailurePreservesUnderlyingError() async {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let failure = NSError(domain: "StoreKitTest", code: 7, userInfo: [NSUnderlyingErrorKey: underlying])
        let manager = IAPManager(productLoader: { _ in throw failure }, startsAutomatically: false)

        do {
            try await manager.purchaseTip(productID: IAPManager.tipProductIDs[0])
            Issue.record("Expected the product request to fail")
        } catch let error as ProductLoadFailure {
            #expect(error.diagnosticCode == "StoreKitTest (7) → NSURLErrorDomain (-1009)")
            #expect(manager.lastLoadErrorMessage == error.localizedDescription)
            #expect(error.localizedDescription == "Unable to load tips from the App Store. Please try again later.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func emptyCatalogReportsMissingProduct() async {
        let manager = IAPManager(productLoader: { _ in [] }, startsAutomatically: false)

        do {
            try await manager.purchaseTip(productID: IAPManager.tipProductIDs[0])
            Issue.record("Expected an unavailable product")
        } catch StoreError.productNotFound {
            #expect(manager.lastLoadErrorMessage == nil)
            #expect(StoreError.productNotFound.localizedDescription == "This tip is temporarily unavailable. Please try again later.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func successfulReloadClearsPreviousRequestFailure() async {
        var attempts = 0
        let manager = IAPManager(productLoader: { _ in
            attempts += 1
            if attempts == 1 {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            return []
        }, startsAutomatically: false)

        await manager.loadProducts()
        #expect(manager.lastLoadErrorMessage != nil)

        do {
            try await manager.purchaseTip(productID: IAPManager.tipProductIDs[0])
            Issue.record("Expected an unavailable product")
        } catch StoreError.productNotFound {
            #expect(attempts == 2)
            #expect(manager.lastLoadErrorMessage == nil)
        } catch {
            Issue.record("Stale request failure was not cleared: \(error)")
        }
    }
}
