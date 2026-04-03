//
//  PurchaseManager.swift
//  thingstv
//
//  Created by DUONG THI on 26/4/25.
//  Updated & Optimized for StoreKit 2
//

import StoreKit
import SwiftUI

// MARK: - Purchase Case Enum
public enum PurchaseCase: String {
    case lifetime
    case week
    
    /// Hàm lấy ID sản phẩm, ưu tiên customID nếu có, nếu không fallback về bundleID + rawValue
    func productID(customID: String? = nil) -> String {
        if let customID = customID, !customID.isEmpty {
            return customID
        }
        
        guard let bundleID = Bundle.main.bundleIdentifier else {
            print("ERROR: Bundle Identifier not found!")
            return "unknown.bundle.\(self.rawValue)"
        }
        return "\(bundleID).\(self.rawValue)"
    }
    
    /// Giữ lại thuộc tính description để tương thích 100% với code cũ gọi `.description`
    public var description: String {
        return productID()
    }
}

// MARK: - Product Info Struct
/// Cấu trúc dữ liệu đơn giản để hiển thị trên UI
public struct ProductInfo {
    public var title = ""
    public var subtitle = ""
    public var localizePrice = ""
    public var symbol = ""
    public var price: Decimal = 0.0
    
    init(title: String, subtitle: String, localizePrice: String, price: Decimal, symbol: String = "$") {
        self.title = title
        self.subtitle = subtitle
        self.localizePrice = localizePrice
        self.price = price
        self.symbol = symbol
    }
}

// MARK: - Purchase Manager
@MainActor
public class PurchaseManager: ObservableObject {
    // MARK: - Properties
    static public let shared = PurchaseManager()
    private let kIsPremium = "kIsPremium"
    private let kDebugOverrideActive = "kDebugOverrideActive"

    @Published public private(set) var isPurchased: Bool = false
    @Published public private(set) var isDebugOverrideActive: Bool = false

    @Published public var products: [Product] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? {
        didSet { if errorMessage != nil { isShowingErrorAlert = true } }
    }
    @Published public var isShowingErrorAlert: Bool = false
    @Published public var purchasePending: Bool = false

    private var appGroupID: String?
    
    // Lưu trữ Custom IDs do người dùng truyền vào
    public var customProductIDs: [PurchaseCase: String] = [:]
    
    // Sử dụng computed property để đảm bảo luôn lấy đúng ID tại thời điểm gọi
    public var productIDs: [String] {
        [
            PurchaseCase.lifetime.productID(customID: customProductIDs[.lifetime]),
            PurchaseCase.week.productID(customID: customProductIDs[.week])
        ]
    }

    // Computed property cho UserDefaults hỗ trợ AppGroup
    private var userDefaults: UserDefaults {
        if let appGroupId = self.appGroupID,
           let defaults = UserDefaults(suiteName: appGroupId) {
            return defaults
        } else {
            if self.appGroupID != nil {
                 print("⚠️ Failed to create UserDefaults with suiteName: \(self.appGroupID!). Falling back to standard UserDefaults.")
            }
            return .standard
        }
    }

    @Published var purchasedProductIDs: Set<String> = []
    private var transactionListener: Task<Void, Error>?

    // MARK: - Initialization
    private init() {}
    
    deinit {
        transactionListener?.cancel()
    }
    
    // MARK: - Configuration
    /// Hàm cấu hình ban đầu, hỗ trợ truyền AppGroup và Custom In-App IDs
    public func configure(appGroupID: String? = nil, customIDs: [PurchaseCase: String]? = nil) {
        self.appGroupID = appGroupID
        
        // Cập nhật customIDs nếu có
        if let customIDs = customIDs {
            self.customProductIDs = customIDs
        }
        
        loadInitialPurchaseState()
        
        // Bắt đầu listener *sau khi* cấu hình xong
        if transactionListener == nil {
             self.transactionListener = listenForTransactions()
        }

        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Ép load lại products vì có thể custom IDs vừa được set
            await self.loadProducts(forceReload: true)
            await self.updatePurchasedProducts()
        }
    }
    
    private func loadInitialPurchaseState() {
        self.isDebugOverrideActive = userDefaults.bool(forKey: kDebugOverrideActive)
        self.isPurchased = userDefaults.bool(forKey: kIsPremium)
        print("Initial state loaded - isPurchased: \(self.isPurchased), isDebugOverrideActive: \(self.isDebugOverrideActive)")
    }

    // MARK: - Transaction Handling
    private func listenForTransactions() -> Task<Void, Error> {
        // Thay Task.detached bằng Task để giữ an toàn cho actor context
        Task { [weak self] in
            guard let self = self else { return }

            for await result in StoreKit.Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    let productID = transaction.productID
                    let isTransactionActive = (transaction.revocationDate == nil && transaction.revocationReason == nil)

                    // Xử lý cập nhật state trên MainActor
                    await MainActor.run {
                         var currentIDs = self.purchasedProductIDs
                         var stateChanged = false

                         if isTransactionActive {
                             if !currentIDs.contains(productID) {
                                 currentIDs.insert(productID)
                                 stateChanged = true
                                 print("Transaction listener: Added \(productID)")
                             }
                         } else {
                             if currentIDs.contains(productID) {
                                 currentIDs.remove(productID)
                                 stateChanged = true
                                 print("Transaction listener: Removed \(productID) (revoked/expired)")
                             }
                         }

                         if !self.isDebugOverrideActive {
                             if stateChanged {
                                 self.purchasedProductIDs = currentIDs
                                 let newPurchaseState = !currentIDs.isEmpty
                                 if self.isPurchased != newPurchaseState {
                                     self.isPurchased = newPurchaseState
                                     self.userDefaults.set(newPurchaseState, forKey: self.kIsPremium)
                                     print("Transaction listener: isPurchased updated to \(self.isPurchased) and saved.")
                                 }
                             }
                         } else {
                             if stateChanged {
                                 self.purchasedProductIDs = currentIDs
                                 print("Transaction listener: Override ACTIVE. isPurchased remains \(self.isPurchased).")
                             }
                         }
                    }
                    
                    // GỌI FINISH DUY NHẤT Ở ĐÂY
                    await transaction.finish()
                    print("Transaction listener: Finished transaction \(transaction.id)")

                } catch {
                    print("Transaction update error: \(error)")
                    await MainActor.run { self.errorMessage = "Transaction Error: \(error.localizedDescription)" }
                }
            }
        }
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Product Loading
    public func loadProducts(forceReload: Bool = false) async {
        // Tránh load lại nếu đã có data (trừ khi forceReload) và tránh dồn request
        guard (products.isEmpty || forceReload) && !isLoading else { return }
        
        print("🚀 Loading products for IDs: \(productIDs)...")
        await MainActor.run { isLoading = true; errorMessage = nil }

        do {
            let storeProducts = try await Product.products(for: productIDs)
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
    public func buyProduct(_ product: Product) async -> Bool {
        guard !isLoading else {
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
                    let _ = try checkVerified(verificationResult)
                    // Thành công: Cập nhật entitlements
                    await updatePurchasedProducts()
                    
                    // KHÔNG gọi transaction.finish() ở đây nữa, Listener sẽ lo việc đó!
                    
                    purchaseSuccess = true
                    await MainActor.run { purchasePending = false } // Reset trạng thái pending
                } catch {
                    print("Verification failed after purchase: \(error)")
                    await MainActor.run { errorMessage = "Purchase verification failed." }
                }
                
            case .pending:
                print("Purchase result: Pending")
                await MainActor.run {
                    errorMessage = "Purchase requires approval (e.g., Ask to Buy)."
                    purchasePending = true
                }
                
            case .userCancelled:
                print("Purchase result: User Cancelled")
                await MainActor.run { purchasePending = false }
                
            @unknown default:
                print("Purchase result: Unknown")
                await MainActor.run { errorMessage = "An unknown error occurred."; purchasePending = false }
            }
            
            await MainActor.run { isLoading = false }
            return purchaseSuccess
            
        } catch StoreKitError.notEntitled {
            print("⚠️ Purchase error: Not entitled.")
            await MainActor.run { errorMessage = "You are not entitled to this purchase."; isLoading = false; purchasePending = false }
            return false
        } catch {
            print("⚠️ Purchase error: \(error)")
            await MainActor.run { errorMessage = "Purchase failed: \(error.localizedDescription)"; isLoading = false; purchasePending = false }
            return false
        }
    }

    // MARK: - Update Purchased Status
    public func updatePurchasedProducts() async {
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
            if !self.isDebugOverrideActive {
                self.purchasedProductIDs = currentEntitlements
                let newPurchaseState = !currentEntitlements.isEmpty
                
                let previousState = self.isPurchased
                self.isPurchased = newPurchaseState
                self.userDefaults.set(newPurchaseState, forKey: self.kIsPremium)
                
                if previousState != newPurchaseState {
                    print("✅ Purchase status CHANGED: \(previousState) → \(newPurchaseState) and saved.")
                } else {
                    print("✅ Purchase status synced (unchanged): \(self.isPurchased)")
                }
                print("Active entitlements: \(currentEntitlements)")
            } else {
                self.purchasedProductIDs = currentEntitlements
                print("⚠️ Purchase status update skipped due to ACTIVE debug override.")
            }
        }
    }

    // MARK: - Restore Purchases
    public func restorePurchases() async -> Bool {
        await MainActor.run { isLoading = true; errorMessage = nil }
        print("Attempting to restore purchases...")

        var restoreSuccess = false
        do {
            try await AppStore.sync()
            print("AppStore.sync() completed.")
            
            await updatePurchasedProducts()
            restoreSuccess = await MainActor.run { isPurchased }
            
            if restoreSuccess {
                print("✅ Purchases restored successfully.")
            } else {
                await MainActor.run { errorMessage = "No previous purchases found to restore." }
            }
        } catch {
            print("⚠️ Restore error: \(error)")
            await MainActor.run { errorMessage = "Failed to restore purchases: \(error.localizedDescription)" }
        }
        
        await MainActor.run { isLoading = false }
        return restoreSuccess
    }

    // MARK: - Helper Methods
    public func getInfo(for productType: PurchaseCase) -> ProductInfo? {
        // Lấy đúng Product ID đang active
        let targetID = productType.productID(customID: customProductIDs[productType])
        
        guard let product = products.first(where: { $0.id == targetID }) else {
            return nil
        }
        
        let priceFormatter = NumberFormatter()
        priceFormatter.numberStyle = .currency
        priceFormatter.locale = product.priceFormatStyle.locale
        let localizedPrice = priceFormatter.string(from: product.price as NSNumber) ?? "\(product.price)"
        
        return ProductInfo(
            title: product.displayName,
            subtitle: product.description,
            localizePrice: localizedPrice,
            price: product.price,
            symbol: product.priceFormatStyle.locale.currencySymbol ?? "$"
        )
    }

    public func productForType(_ type: PurchaseCase) -> Product? {
        let targetID = type.productID(customID: customProductIDs[type])
        return products.first(where: { $0.id == targetID })
    }
    
    public func hasFreeTrialForWeekSubscription() -> Bool {
        guard let weeklyProduct = productForType(.week),
              let subscription = weeklyProduct.subscription else {
            return false
        }
        return subscription.introductoryOffer?.paymentMode == .freeTrial
    }

    // MARK: - Debug Methods
    public func debugSetPurchaseOverride(forcePremium: Bool) {
        print("⚠️ DEBUG: Forcing purchase state to \(forcePremium)")
        self.isDebugOverrideActive = true
        self.userDefaults.set(true, forKey: kDebugOverrideActive)
        
        self.isPurchased = forcePremium
        self.userDefaults.set(forcePremium, forKey: kIsPremium)
        print("⚠️ DEBUG: Saved forced state (\(forcePremium))")
    }

    public func debugClearPurchaseOverride() {
        print("⚠️ DEBUG: Deactivating and clearing purchase state override. Reloading actual state...")
        self.isDebugOverrideActive = false
        self.userDefaults.removeObject(forKey: kDebugOverrideActive)
        
        Task {
            await self.updatePurchasedProducts()
            print("⚠️ DEBUG: Override cleared. Actual purchase state reloaded. isPurchased is now \(self.isPurchased)")
        }
    }
}