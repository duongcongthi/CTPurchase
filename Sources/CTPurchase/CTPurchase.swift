//
//  PurchaseManager.swift
//  thingstv
//
//  Created by DUONG THI on 26/4/25.
//

import StoreKit
import SwiftUI

enum PurchaseCase: String {
    case lifetime
    case week
    var description: String {
        // Ensure bundleID is fetched safely
        guard let bundleID = Bundle.main.bundleIdentifier else {
            // In a real app, handle this more gracefully than fatalError
            // Maybe return a default or log an error.
            print("ERROR: Bundle Identifier not found!")
            return "unknown.bundle.\(self.rawValue)"
        }
        return "\(bundleID).\(self.rawValue)"
    }
}

// Simple data structure for display purposes in the UI
struct ProductInfo {
    var title = ""
    var subtitle = ""
    var localizePrice = ""
    var symbol = ""
    var price: Decimal = 0.0 // Use Decimal for currency
    
    init(title: String, subtitle: String, localizePrice: String, price: Decimal, symbol: String = "$") {
        self.title = title
        self.subtitle = subtitle
        self.localizePrice = localizePrice
        self.price = price
        self.symbol = symbol
    }
}

let kIsPremium = "kIsPremium"

@MainActor
public class PurchaseManager: /*NSObject,*/ ObservableObject {
    // MARK: - Properties
    static public let shared = PurchaseManager()

    // Use a standard @Published property, managed manually
    @Published public private(set) var isPurchased: Bool = false
    
    @Published public var products: [Product] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? {
        didSet { if errorMessage != nil { isShowingErrorAlert = true } }
    }
    @Published public var isShowingErrorAlert: Bool = false // For presenting alerts in SwiftUI
    @Published public var purchasePending: Bool = false

    // Add instance variable for appGroupID
    private var appGroupID: String?
    
    // Computed property for UserDefaults
    private var userDefaults: UserDefaults {
        if let appGroupId = self.appGroupID,
           let defaults = UserDefaults(suiteName: appGroupId) {
            return defaults
        } else {
            // If appGroupID is nil or invalid, use standard UserDefaults
            if self.appGroupID != nil {
                 print("⚠️ Failed to create UserDefaults with suiteName: \(self.appGroupID!). Falling back to standard UserDefaults.")
            }
            return .standard
        }
    }

    // Use lazy var for productIDs to ensure bundleID is available
    lazy public var productIDs: [String] = [PurchaseCase.lifetime.description, PurchaseCase.week.description]
    @Published var purchasedProductIDs: Set<String> = []

    private var transactionListener: Task<Void, Error>? // Can throw errors

    // MARK: - Initialization
    // Make init private again if shared is the only entry point
    // override init() {
    private init() {
        // Defer setup until configure is called
        // super.init() // No longer needed if not inheriting NSObject
        // self.transactionListener = listenForTransactions() // Start listener after config
        // Task { ... } // Load products after config
       
    }
    
    // Public configure method
    public func configure(appGroupID: String? = nil) {
        self.appGroupID = appGroupID
        
        // Load initial purchase state after UserDefaults is determined
        loadInitialPurchaseState()
        
        // Start listener *after* configuration
        if transactionListener == nil { // Ensure listener is started only once
             self.transactionListener = listenForTransactions()
        }

        // Load products and entitlements *after* configuration
        Task(priority: .background) { [weak self] in
            guard let self = self else { return }
            await self.loadProducts()
            await self.updatePurchasedProducts() // This will also update isPurchased based on entitlements
        }
    }
    
    // Helper to load initial state
    private func loadInitialPurchaseState() {
        self.isPurchased = userDefaults.bool(forKey: kIsPremium)
        print("Initial isPurchased state loaded: \(self.isPurchased)")
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Transaction Handling
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            guard let self = self else {
                 print("PurchaseManager instance deallocated before transaction listener could run.")
                 return
             }

            for await result in StoreKit.Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    let productID = transaction.productID
                    let isTransactionActive = (transaction.revocationDate == nil && transaction.revocationReason == nil)

                    await MainActor.run {
                         var currentIDs = self.purchasedProductIDs
                         var stateChanged = false

                         if isTransactionActive {
                             if !currentIDs.contains(productID) {
                                 currentIDs.insert(productID)
                                 stateChanged = true
                                 print("Transaction listener (MainActor): Added \(productID)")
                             }
                         } else {
                             if currentIDs.contains(productID) {
                                 currentIDs.remove(productID)
                                 stateChanged = true
                                 print("Transaction listener (MainActor): Removed \(productID) (revoked/expired)")
                             }
                         }

                         if stateChanged {
                             self.purchasedProductIDs = currentIDs
                             let newPurchaseState = !currentIDs.isEmpty
                             if self.isPurchased != newPurchaseState {
                                 self.isPurchased = newPurchaseState
                                 // *** Save the updated state to UserDefaults ***
                                 self.userDefaults.set(newPurchaseState, forKey: kIsPremium)
                                 print("Transaction listener (MainActor): isPurchased updated to \(self.isPurchased) and saved.")
                             }
                              print("Transaction listener (MainActor): State updated. purchasedProductIDs: \(currentIDs)")
                         }
                    }
                    await transaction.finish()
                    print("Transaction listener: Finished transaction \(transaction.id)")

                } catch {
                    // StoreKit error handling
                    print("Transaction update error: \(error)")
                    // Update errorMessage on main thread using the captured self
                    await MainActor.run { self.errorMessage = "Transaction Error: \(error.localizedDescription)" }
                }
            }
        }
    }
    
    // Check verification status
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error // Verification error
        case .verified(let safe):
            return safe // Transaction is verified
        }
    }

    // MARK: - Product Loading
    func loadProducts() async {
        guard !isLoading else { return } // Prevent concurrent loading
        print("🚀 Loading products...")
        await MainActor.run { isLoading = true; errorMessage = nil }

        do {
            let storeProducts = try await Product.products(for: productIDs)
            // Sort products, e.g., by price or type
            let sortedProducts = storeProducts.sorted { $0.price < $1.price }
            
            await MainActor.run {
                self.products = sortedProducts
                self.isLoading = false
                if sortedProducts.isEmpty {
                    print("⚠️ No products found for IDs: \(productIDs). Check App Store Connect.")
                    self.errorMessage = "Products not available currently."
                } else {
                    print("🛒 Products loaded: \(sortedProducts.map { $0.id })")
                }
            }
        } catch {
            print("⚠️ Failed to fetch products: \(error)")
            await MainActor.run {
                self.errorMessage = "Error loading products: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Purchase Flow
    func buyProduct(_ product: Product) async -> Bool {
        guard !isPurchased else {
            print("User is already premium.")
            return true // Indicate success (already purchased)
        }
        
        guard !isLoading else { // Prevent double tapping
            print("Purchase already in progress.")
            return false
        }
        
        await MainActor.run { isLoading = true; purchasePending = false; errorMessage = nil }
        print("Initiating purchase for \(product.id)...")

        do {
            let result = try await product.purchase()
            
            var purchaseSuccess = false
            switch result {
            case .success(let verificationResult):
                print("Purchase result: Success")
                do {
                    let transaction = try checkVerified(verificationResult)
                    // Purchase verified, update state and finish
                    await updatePurchasedProducts() // Update based on the new transaction
                    await transaction.finish()
                    purchaseSuccess = true // Mark as successful
                } catch {
                    print("Verification failed after purchase: \(error)")
                    await MainActor.run { errorMessage = "Purchase verification failed." }
                }
                
            case .pending:
                print("Purchase result: Pending")
                await MainActor.run {
                    errorMessage = "Purchase requires approval (e.g., Ask to Buy)."
                    purchasePending = true // Indicate pending state
                }
                
            case .userCancelled:
                print("Purchase result: User Cancelled")
                // No error message needed
                
            @unknown default:
                print("Purchase result: Unknown")
                await MainActor.run { errorMessage = "An unknown error occurred." }
            }
            
            await MainActor.run { isLoading = false }
            return purchaseSuccess // Return the final success state
            
        } catch StoreKitError.notEntitled {
            print("⚠️ Purchase error: Not entitled.")
            await MainActor.run { errorMessage = "You are not entitled to this purchase."; isLoading = false }
            return false
        } catch {
            print("⚠️ Purchase error: \(error)")
            await MainActor.run { errorMessage = "Purchase failed: \(error.localizedDescription)"; isLoading = false }
            return false
        }
    }

    // MARK: - Get Product Info (For UI Display)
    func getInfo(for productType: PurchaseCase) -> ProductInfo? {
        guard let product = products.first(where: { $0.id == productType.description }) else {
            return nil // Product not found/loaded
        }
        
        let priceFormatter = NumberFormatter()
        priceFormatter.numberStyle = .currency
        priceFormatter.locale = product.priceFormatStyle.locale
        let localizedPrice = priceFormatter.string(from: product.price as NSNumber) ?? "\(product.price)"
        
        return ProductInfo(
            title: product.displayName,
            subtitle: product.description,
            localizePrice: localizedPrice,
            price: product.price, // Keep as Decimal
            symbol: product.priceFormatStyle.locale.currencySymbol ?? "$"
        )
    }

    // MARK: - Update Purchased Status
    func updatePurchasedProducts() async {
        print("Updating purchased products status...")
        var currentEntitlements = Set<String>()
        
        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if transaction.revocationDate == nil {
                    currentEntitlements.insert(transaction.productID)
                }
            } catch {
                print("Skipping unverified transaction during entitlement check: \(error)")
            }
        }
        
        await MainActor.run {
            self.purchasedProductIDs = currentEntitlements
            let newPurchaseState = !currentEntitlements.isEmpty
            if self.isPurchased != newPurchaseState {
                self.isPurchased = newPurchaseState
                // *** Save the updated state to UserDefaults ***
                self.userDefaults.set(newPurchaseState, forKey: kIsPremium)
                print("Purchase status changed to: \(self.isPurchased) and saved.")
            }
             print("Active entitlements: \(currentEntitlements)")
        }
    }

    // MARK: - Restore Purchases
    func restorePurchases() async -> Bool {
        await MainActor.run { isLoading = true; errorMessage = nil }
        print("Attempting to restore purchases...")

        var restoreSuccess = false
        do {
            try await AppStore.sync()
            print("AppStore.sync() completed.")
            // Update status based on potentially synced transactions
            await updatePurchasedProducts()
            restoreSuccess = await MainActor.run { isPurchased } // Check final state
            
            if restoreSuccess {
                print("✅ Purchases restored successfully.")
            } else {
                await MainActor.run { errorMessage = "No previous purchases found to restore." }
                print("ℹ️ No active purchases found after sync.")
            }
        } catch {
            print("⚠️ Restore error: \(error)")
            await MainActor.run { errorMessage = "Failed to restore purchases: \(error.localizedDescription)" }
        }
        
        await MainActor.run { isLoading = false }
        return restoreSuccess
    }

    // MARK: - Helper Methods
    func hasFreeTrialForWeekSubscription() -> Bool {
        guard let weeklyProduct = productForType(.week),
              let subscription = weeklyProduct.subscription else {
            return false
        }
        // Check introductory offer details
        return subscription.introductoryOffer?.paymentMode == .freeTrial
    }

    func productForType(_ type: PurchaseCase) -> Product? {
        return products.first(where: { $0.id == type.description })
    }
}
