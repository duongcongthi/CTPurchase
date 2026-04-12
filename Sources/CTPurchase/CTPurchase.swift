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
public enum PurchaseCase: String, CaseIterable {
    case lifetime
    case week
    
    /// Hàm lấy ID sản phẩm, ưu tiên customID nếu có, nếu không fallback về bundleID + rawValue
    public func productID(customID: String? = nil, bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        if let customID = customID?.trimmingCharacters(in: .whitespacesAndNewlines), !customID.isEmpty {
            return customID
        }
        
        guard let bundleID = bundleID, !bundleID.isEmpty else {
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

// MARK: - Product Offer Info
public enum ProductOfferPaymentMode: String {
    case freeTrial
    case payAsYouGo
    case payUpFront
    case unknown
}

public enum ProductOfferPeriodUnit: String {
    case day
    case week
    case month
    case year
    case unknown
}

/// Thông tin offer của một subscription product, dùng để kiểm tra free trial theo in-app id.
public struct ProductOfferInfo {
    public let productID: String
    public let paymentMode: ProductOfferPaymentMode
    public let periodUnit: ProductOfferPeriodUnit
    public let periodValue: Int
    public let periodCount: Int
    public let exactDurationInDays: Int?
    public let price: Decimal
    public let displayPrice: String
    public let durationDescription: String

    public var isFreeTrial: Bool {
        paymentMode == .freeTrial
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
    @Published public private(set) var isFetchingProducts: Bool = false
    @Published public private(set) var isPurchasing: Bool = false
    @Published public private(set) var isRestoring: Bool = false
    @Published public var errorMessage: String? {
        didSet { if errorMessage != nil { isShowingErrorAlert = true } }
    }
    @Published public var isShowingErrorAlert: Bool = false
    @Published public var purchasePending: Bool = false

    private var appGroupID: String?
    private var activeProductFetchCount = 0
    private var configuredProductIDs: [String]?
    
    // Lưu trữ Custom IDs do người dùng truyền vào
    public var customProductIDs: [PurchaseCase: String] = [:]
    
    // Sử dụng computed property để đảm bảo luôn lấy đúng ID tại thời điểm gọi
    public var productIDs: [String] {
        if let configuredProductIDs = configuredProductIDs {
            return configuredProductIDs
        }

        return PurchaseCase.allCases.map { productType in
            productType.productID(customID: customProductIDs[productType])
        }
    }

    public var defaultProductIDs: [String] {
        PurchaseCase.allCases.map { $0.productID() }
    }

    private var premiumProductIDSet: Set<String> {
        Set(productIDs)
    }

    private var handledTransactionProductIDSet: Set<String> {
        premiumProductIDSet
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
        self.configuredProductIDs = nil
        
        // Cập nhật customIDs nếu có
        if let customIDs = customIDs {
            self.customProductIDs = customIDs
        } else {
            self.customProductIDs = [:]
        }
        
        startConfiguredPurchaseFlow()
    }

    /// Dùng cho app có nhiều in-app ids custom. Toàn bộ ids truyền vào được xem là premium ids của package.
    public func configure(appGroupID: String? = nil, productIDs: [String]) {
        self.appGroupID = appGroupID
        self.customProductIDs = [:]
        self.configuredProductIDs = sanitizeProductIDs(productIDs)

        startConfiguredPurchaseFlow()
    }

    public func configure(appGroupID: String? = nil, productIDs: String...) {
        configure(appGroupID: appGroupID, productIDs: productIDs)
    }

    private func startConfiguredPurchaseFlow() {
        loadInitialPurchaseState()

        // Bắt đầu listener *sau khi* cấu hình xong
        if transactionListener == nil {
             self.transactionListener = listenForTransactions()
        }

        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Ép load lại products vì cấu hình ids có thể vừa đổi
            await self.loadProducts(forceReload: true)
            await self.updatePurchasedProducts()
        }
    }
    
    private func loadInitialPurchaseState() {
        self.isDebugOverrideActive = userDefaults.bool(forKey: kDebugOverrideActive)
        self.isPurchased = userDefaults.bool(forKey: kIsPremium)
        print("Initial state loaded - isPurchased: \(self.isPurchased), isDebugOverrideActive: \(self.isDebugOverrideActive)")
    }

    private func sanitizeProductIDs(_ ids: [String]) -> [String] {
        var seenIDs = Set<String>()
        return ids.compactMap { id in
            let sanitizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitizedID.isEmpty, !seenIDs.contains(sanitizedID) else {
                return nil
            }

            seenIDs.insert(sanitizedID)
            return sanitizedID
        }
    }

    private func refreshLoadingState() {
        isLoading = isFetchingProducts || isPurchasing || isRestoring
    }

    private func beginProductFetch() {
        activeProductFetchCount += 1
        isFetchingProducts = true
        refreshLoadingState()
    }

    private func endProductFetch() {
        activeProductFetchCount = max(0, activeProductFetchCount - 1)
        isFetchingProducts = activeProductFetchCount > 0
        refreshLoadingState()
    }

    private func setPurchasing(_ value: Bool) {
        isPurchasing = value
        refreshLoadingState()
    }

    private func setRestoring(_ value: Bool) {
        isRestoring = value
        refreshLoadingState()
    }

    private func shouldHandleTransaction(for productID: String) -> Bool {
        handledTransactionProductIDSet.contains(productID)
    }

    // MARK: - Transaction Handling
    private func listenForTransactions() -> Task<Void, Error> {
        // Thay Task.detached bằng Task để giữ an toàn cho actor context
        Task { [weak self] in
            guard let self = self else { return }

            for await result in StoreKit.Transaction.updates {
                switch result {
                case .verified(let transaction):
                    let productID = transaction.productID
                    guard self.shouldHandleTransaction(for: productID) else {
                        print("Transaction listener: Ignored unmanaged product \(productID)")
                        continue
                    }

                    let isTransactionActive = (transaction.revocationDate == nil && transaction.revocationReason == nil)

                    var currentIDs = self.purchasedProductIDs
                    var stateChanged = false

                    if isTransactionActive && self.premiumProductIDSet.contains(productID) {
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
                    
                    await transaction.finish()
                    print("Transaction listener: Finished transaction \(transaction.id)")

                case .unverified(let transaction, let error):
                    let productID = transaction.productID
                    guard self.shouldHandleTransaction(for: productID) else {
                        print("Transaction listener: Ignored unverified unmanaged product \(productID)")
                        continue
                    }

                    print("Transaction update error: \(error)")
                    self.errorMessage = "Transaction Error: \(error.localizedDescription)"
                    await transaction.finish()
                    print("Transaction listener: Finished unverified transaction \(transaction.id)")
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
        guard products.isEmpty || forceReload else { return }
        
        print("🚀 Loading products for IDs: \(productIDs)...")
        beginProductFetch()
        errorMessage = nil

        do {
            let storeProducts = try await Product.products(for: productIDs)
            let sortedProducts = storeProducts.sorted { $0.price < $1.price }

            self.products = sortedProducts
            endProductFetch()
            if sortedProducts.isEmpty {
                print("⚠️ No products found for IDs: \(productIDs). Check App Store Connect.")
                self.errorMessage = "Products not available currently."
            } else {
                print("🛒 Products loaded: \(sortedProducts.map { $0.id })")
            }
        } catch {
            print("⚠️ Failed to fetch products: \(error)")
            self.errorMessage = "Error loading products: \(error.localizedDescription)"
            endProductFetch()
        }
    }

    /// Load thêm product theo in-app ids bất kỳ để có thể kiểm tra offer trực tiếp theo id.
    public func loadProducts(forProductIDs ids: [String], forceReload: Bool = false) async {
        let requestedIDs = Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !requestedIDs.isEmpty else { return }

        let idsToLoad: [String]
        if forceReload {
            idsToLoad = requestedIDs
        } else {
            idsToLoad = requestedIDs.filter { productID in
                !products.contains(where: { $0.id == productID })
            }
        }

        guard !idsToLoad.isEmpty else { return }

        print("🚀 Loading products for custom IDs: \(idsToLoad)...")
        beginProductFetch()
        errorMessage = nil

        do {
            let storeProducts = try await Product.products(for: idsToLoad)

            var productsByID = Dictionary(uniqueKeysWithValues: self.products.map { ($0.id, $0) })
            storeProducts.forEach { productsByID[$0.id] = $0 }
            self.products = productsByID.values.sorted { $0.price < $1.price }
            endProductFetch()

            if storeProducts.isEmpty {
                print("⚠️ No products found for custom IDs: \(idsToLoad). Check App Store Connect.")
                self.errorMessage = "Products not available currently."
            } else {
                print("🛒 Custom products loaded: \(storeProducts.map { $0.id })")
            }
        } catch {
            print("⚠️ Failed to fetch custom products: \(error)")
            self.errorMessage = "Error loading products: \(error.localizedDescription)"
            endProductFetch()
        }
    }

    public func loadProduct(forProductID productID: String, forceReload: Bool = false) async {
        await loadProducts(forProductIDs: [productID], forceReload: forceReload)
    }
    
    // MARK: - Purchase Flow
    public func buyProduct(_ product: Product) async -> Bool {
        guard !isPurchasing && !isRestoring else {
            print("Purchase already in progress.")
            return false
        }
        
        setPurchasing(true)
        purchasePending = false
        errorMessage = nil
        print("Initiating purchase for \(product.id)...")

        do {
            let result = try await product.purchase()
            var purchaseSuccess = false
            
            switch result {
            case .success(let verificationResult):
                print("Purchase result: Success")
                do {
                    let transaction = try checkVerified(verificationResult)
                    // Thành công: Cập nhật entitlements
                    await updatePurchasedProducts()
                    await transaction.finish()
                    print("Purchase flow: Finished transaction \(transaction.id)")
                    
                    purchaseSuccess = true
                    purchasePending = false
                } catch {
                    print("Verification failed after purchase: \(error)")
                    errorMessage = "Purchase verification failed."
                }
                
            case .pending:
                print("Purchase result: Pending")
                errorMessage = "Purchase requires approval (e.g., Ask to Buy)."
                purchasePending = true
                
            case .userCancelled:
                print("Purchase result: User Cancelled")
                purchasePending = false
                
            @unknown default:
                print("Purchase result: Unknown")
                errorMessage = "An unknown error occurred."
                purchasePending = false
            }
            
            setPurchasing(false)
            return purchaseSuccess
            
        } catch StoreKitError.notEntitled {
            print("⚠️ Purchase error: Not entitled.")
            errorMessage = "You are not entitled to this purchase."
            setPurchasing(false)
            purchasePending = false
            return false
        } catch {
            print("⚠️ Purchase error: \(error)")
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            setPurchasing(false)
            purchasePending = false
            return false
        }
    }

    // MARK: - Update Purchased Status
    public func updatePurchasedProducts() async {
        print("Updating purchased products status...")
        var currentEntitlements = Set<String>()
        let premiumIDs = premiumProductIDSet
        
        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if transaction.revocationDate == nil && premiumIDs.contains(transaction.productID) {
                    currentEntitlements.insert(transaction.productID)
                }
            } catch {
                print("Skipping unverified transaction during entitlement check: \(error)")
            }
        }
        
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

    // MARK: - Restore Purchases
    public func restorePurchases() async -> Bool {
        guard !isPurchasing && !isRestoring else {
            print("Purchase or restore already in progress.")
            return false
        }

        setRestoring(true)
        errorMessage = nil
        print("Attempting to restore purchases...")

        var restoreSuccess = false
        do {
            try await AppStore.sync()
            print("AppStore.sync() completed.")
            
            await updatePurchasedProducts()
            restoreSuccess = isPurchased
            
            if restoreSuccess {
                print("✅ Purchases restored successfully.")
            } else {
                errorMessage = "No previous purchases found to restore."
            }
        } catch {
            print("⚠️ Restore error: \(error)")
            errorMessage = "Failed to restore purchases: \(error.localizedDescription)"
        }
        
        setRestoring(false)
        return restoreSuccess
    }

    // MARK: - Helper Methods
    public func getInfo(for productType: PurchaseCase) -> ProductInfo? {
        // Lấy đúng Product ID đang active
        let targetID = productType.productID(customID: customProductIDs[productType])
        return getInfo(forProductID: targetID)
    }

    public func getInfo(forProductID productID: String) -> ProductInfo? {
        let targetID = productID.trimmingCharacters(in: .whitespacesAndNewlines)
        
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

    public func productForID(_ productID: String) -> Product? {
        products.first(where: { $0.id == productID })
    }

    public func fetchProductForID(_ productID: String) async -> Product? {
        if let product = productForID(productID) {
            return product
        }

        await loadProduct(forProductID: productID)
        return productForID(productID)
    }

    public func introductoryOfferInfo(forProductID productID: String) -> ProductOfferInfo? {
        guard let product = productForID(productID),
              let offer = product.subscription?.introductoryOffer else {
            return nil
        }

        return makeOfferInfo(productID: productID, offer: offer)
    }

    public func fetchIntroductoryOfferInfo(forProductID productID: String) async -> ProductOfferInfo? {
        if let offerInfo = introductoryOfferInfo(forProductID: productID) {
            return offerInfo
        }

        await loadProduct(forProductID: productID)
        return introductoryOfferInfo(forProductID: productID)
    }

    public func hasIntroductoryOffer(forProductID productID: String) -> Bool {
        introductoryOfferInfo(forProductID: productID) != nil
    }

    public func hasOffer(forProductID productID: String, paymentMode: ProductOfferPaymentMode) -> Bool {
        introductoryOfferInfo(forProductID: productID)?.paymentMode == paymentMode
    }

    public func hasFreeTrial(forProductID productID: String) -> Bool {
        introductoryOfferInfo(forProductID: productID)?.isFreeTrial == true
    }

    public func hasFreeTrial(forProductID productID: String, days: Int) -> Bool {
        guard days > 0,
              let offerInfo = introductoryOfferInfo(forProductID: productID),
              offerInfo.isFreeTrial else {
            return false
        }

        return offerInfo.exactDurationInDays == days
    }

    public func hasFreeTrial(forProductID productID: String, value: Int, unit: ProductOfferPeriodUnit, periodCount: Int = 1) -> Bool {
        guard value > 0,
              periodCount > 0,
              let offerInfo = introductoryOfferInfo(forProductID: productID),
              offerInfo.isFreeTrial else {
            return false
        }

        return offerInfo.periodValue == value &&
               offerInfo.periodUnit == unit &&
               offerInfo.periodCount == periodCount
    }

    public func hasFreeTrial3Days(forProductID productID: String) -> Bool {
        hasFreeTrial(forProductID: productID, days: 3)
    }

    public func hasFreeTrial7Days(forProductID productID: String) -> Bool {
        hasFreeTrial(forProductID: productID, days: 7)
    }

    public func fetchHasIntroductoryOffer(forProductID productID: String) async -> Bool {
        await fetchIntroductoryOfferInfo(forProductID: productID) != nil
    }

    public func fetchHasOffer(forProductID productID: String, paymentMode: ProductOfferPaymentMode) async -> Bool {
        await fetchIntroductoryOfferInfo(forProductID: productID)?.paymentMode == paymentMode
    }

    public func fetchHasFreeTrial(forProductID productID: String) async -> Bool {
        await fetchIntroductoryOfferInfo(forProductID: productID)?.isFreeTrial == true
    }

    public func fetchHasFreeTrial(forProductID productID: String, days: Int) async -> Bool {
        guard days > 0,
              let offerInfo = await fetchIntroductoryOfferInfo(forProductID: productID),
              offerInfo.isFreeTrial else {
            return false
        }

        return offerInfo.exactDurationInDays == days
    }

    public func fetchHasFreeTrial(forProductID productID: String, value: Int, unit: ProductOfferPeriodUnit, periodCount: Int = 1) async -> Bool {
        guard value > 0,
              periodCount > 0,
              let offerInfo = await fetchIntroductoryOfferInfo(forProductID: productID),
              offerInfo.isFreeTrial else {
            return false
        }

        return offerInfo.periodValue == value &&
               offerInfo.periodUnit == unit &&
               offerInfo.periodCount == periodCount
    }

    public func fetchHasFreeTrial3Days(forProductID productID: String) async -> Bool {
        await fetchHasFreeTrial(forProductID: productID, days: 3)
    }

    public func fetchHasFreeTrial7Days(forProductID productID: String) async -> Bool {
        await fetchHasFreeTrial(forProductID: productID, days: 7)
    }
    
    public func hasFreeTrialForWeekSubscription() -> Bool {
        guard let weeklyProduct = productForType(.week),
              let subscription = weeklyProduct.subscription else {
            return false
        }
        return subscription.introductoryOffer?.paymentMode == .freeTrial
    }

    private func makeOfferInfo(productID: String, offer: Product.SubscriptionOffer) -> ProductOfferInfo {
        let paymentMode = mapPaymentMode(offer.paymentMode)
        let periodUnit = mapPeriodUnit(offer.period.unit)
        let exactDurationInDays = exactDays(value: offer.period.value, unit: periodUnit, periodCount: offer.periodCount)

        return ProductOfferInfo(
            productID: productID,
            paymentMode: paymentMode,
            periodUnit: periodUnit,
            periodValue: offer.period.value,
            periodCount: offer.periodCount,
            exactDurationInDays: exactDurationInDays,
            price: offer.price,
            displayPrice: offer.displayPrice,
            durationDescription: durationDescription(value: offer.period.value, unit: periodUnit, periodCount: offer.periodCount)
        )
    }

    private func mapPaymentMode(_ paymentMode: Product.SubscriptionOffer.PaymentMode) -> ProductOfferPaymentMode {
        switch paymentMode {
        case .freeTrial:
            return .freeTrial
        case .payAsYouGo:
            return .payAsYouGo
        case .payUpFront:
            return .payUpFront
        default:
            return .unknown
        }
    }

    private func mapPeriodUnit(_ unit: Product.SubscriptionPeriod.Unit) -> ProductOfferPeriodUnit {
        switch unit {
        case .day:
            return .day
        case .week:
            return .week
        case .month:
            return .month
        case .year:
            return .year
        @unknown default:
            return .unknown
        }
    }

    private func exactDays(value: Int, unit: ProductOfferPeriodUnit, periodCount: Int) -> Int? {
        let totalValue = value * periodCount

        switch unit {
        case .day:
            return totalValue
        case .week:
            return totalValue * 7
        case .month, .year, .unknown:
            return nil
        }
    }

    private func durationDescription(value: Int, unit: ProductOfferPeriodUnit, periodCount: Int) -> String {
        let totalValue = value * periodCount

        switch unit {
        case .day:
            return "\(totalValue) day\(totalValue == 1 ? "" : "s")"
        case .week:
            return "\(totalValue) week\(totalValue == 1 ? "" : "s")"
        case .month:
            return "\(totalValue) month\(totalValue == 1 ? "" : "s")"
        case .year:
            return "\(totalValue) year\(totalValue == 1 ? "" : "s")"
        case .unknown:
            return "\(totalValue)"
        }
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
