import StoreKit
import SwiftUI

@MainActor
public class SubscriptionsManager: NSObject, ObservableObject {
    private let productIDs: [String]
    private let keySecret: String
    private let userDefaults: UserDefaults
    private var purchasedProductIDs: Set<String> = []
    
    @Published public var products: [Product] = []
    @Published public var hasPro: Bool {
        didSet {
            userDefaults.set(hasPro, forKey: "hasPro")
        }
    }
    
    private var updates: Task<Void, Never>? = nil

    public init(productIDs: [String], keySecret: String, appGroupID: String) {
        self.productIDs = productIDs
        self.keySecret = keySecret
        self.userDefaults = UserDefaults(suiteName: appGroupID)!
        self.hasPro = userDefaults.bool(forKey: "hasPro")
        super.init()
        // Bắt đầu lắng nghe các cập nhật giao dịch
        self.updates = observeTransactionUpdates()
        SKPaymentQueue.default().add(self)
        Task { await loadProducts() }
    }

    deinit {
        updates?.cancel()
    }

    // MARK: - Get Price
    public func getPrice(for productID: String) -> String {
        guard let product = products.first(where: { $0.id == productID }) else {
            return "N/A"
        }
        return product.localizedPrice ?? (product.isFree ? "Free" : "N/A")
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await verificationResult in StoreKit.Transaction.updates {
                guard let self = self else { break }
                switch verificationResult {
                case .verified(let transaction):
                    print("Received verified transaction update for: \(transaction.productID)")
                    if await self.verifyReceipt(transaction: transaction) {
                        print("Receipt verification succeeded for \(transaction.productID)")
                        await transaction.finish()
                    } else {
                        print("Receipt verification failed for \(transaction.productID)")
                    }
                case .unverified(let transaction, let error):
                    print("Unverified transaction: \(transaction.productID), error: \(error.localizedDescription)")
                @unknown default:
                    print("Unknown transaction verification result.")
                }
                await self.updatePurchasedProducts()
            }
        }
    }

    public func loadProducts() async {
        do {
            let fetchedProducts = try await Product.products(for: productIDs)
            self.products = fetchedProducts.sorted { $0.price > $1.price }
            print("Loaded products: \(self.products.map { $0.id })")
        } catch {
            print("Failed to fetch products: \(error.localizedDescription)")
        }
    }

    public func buyProduct(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case let .success(.verified(transaction)):
                print("Purchase successful for: \(transaction.productID)")
                if await verifyReceipt(transaction: transaction) {
                    await transaction.finish()
                    print("Transaction finished for: \(transaction.productID)")
                    await self.updatePurchasedProducts()
                } else {
                    print("Receipt verification failed in buyProduct for \(transaction.productID)")
                }
            case let .success(.unverified(_, error)):
                print("Unverified purchase: \(error.localizedDescription)")
            case .pending:
                print("Transaction pending...")
            case .userCancelled:
                print("User cancelled purchase.")
            @unknown default:
                print("Unknown purchase result.")
            }
        } catch {
            print("Purchase failed: \(error.localizedDescription)")
        }
    }

    public func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updatePurchasedProducts()
            print("Purchases restored successfully.")
        } catch {
            print("Failed to restore purchases: \(error.localizedDescription)")
        }
    }

    // MARK: - Receipt Verification
    private func verifyReceipt(transaction: StoreKit.Transaction) async -> Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL,
              let receiptData = try? Data(contentsOf: receiptURL).base64EncodedString() else {
            print("No receipt found.")
            return false
        }
        
        let requestData: [String: Any] = [
            "receipt-data": receiptData,
            "password": keySecret,
            "exclude-old-transactions": false
        ]
        
        guard let requestBody = try? JSONSerialization.data(withJSONObject: requestData) else {
            print("Failed to serialize receipt data.")
            return false
        }
        
        #if DEBUG
        let urlString = "https://sandbox.itunes.apple.com/verifyReceipt"
        #else
        let urlString = "https://buy.itunes.apple.com/verifyReceipt"
        #endif
        
        print("Verifying receipt at URL: \(urlString)")
        return await verifyReceiptWithURL(urlString: urlString, requestBody: requestBody, transaction: transaction)
    }
    
    private func verifyReceiptWithURL(urlString: String, requestBody: Data, transaction: StoreKit.Transaction) async -> Bool {
        guard let url = URL(string: urlString) else {
            print("Invalid URL: \(urlString)")
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("Invalid server response.")
                return false
            }
            
            guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = jsonResponse["status"] as? Int else {
                print("Invalid JSON response.")
                return false
            }
            
            let transactionIdString = String(transaction.id)
            print("Verifying transaction ID: \(transactionIdString) with status: \(status)")
            
            switch status {
            case 0:
                return checkReceiptForTransaction(jsonResponse: jsonResponse, transactionIdString: transactionIdString)
                
            case 21007:
                print("Receipt is from sandbox but sent to production. Switching to sandbox environment...")
                if urlString == "https://buy.itunes.apple.com/verifyReceipt" {
                    return await verifyReceiptWithURL(
                        urlString: "https://sandbox.itunes.apple.com/verifyReceipt",
                        requestBody: requestBody,
                        transaction: transaction
                    )
                }
                return false
                
            case 21008:
                print("Receipt is from production but sent to sandbox. Switching to production environment...")
                if urlString == "https://sandbox.itunes.apple.com/verifyReceipt" {
                    return await verifyReceiptWithURL(
                        urlString: "https://buy.itunes.apple.com/verifyReceipt",
                        requestBody: requestBody,
                        transaction: transaction
                    )
                }
                return false
                
            case 21000:
                print("App Store could not read the JSON object.")
            case 21002:
                print("Receipt data malformed.")
            case 21003:
                print("Receipt not authenticated.")
            default:
                print("Receipt verification failed with status: \(status)")
            }
            return false
        } catch {
            print("Receipt verification failed: \(error.localizedDescription)")
            return false
        }
    }
    
    private func checkReceiptForTransaction(jsonResponse: [String: Any], transactionIdString: String) -> Bool {
        // Kiểm tra trong latest_receipt_info (cho subscription)
        if let latestReceiptInfo = jsonResponse["latest_receipt_info"] as? [[String: Any]] {
            for receipt in latestReceiptInfo {
                if let receiptTransactionID = receipt["transaction_id"] as? String,
                   receiptTransactionID == transactionIdString {
                    print("Receipt verified successfully for transaction: \(transactionIdString) in latest_receipt_info")
                    return true
                }
            }
        }
        
        // Kiểm tra trong receipt.in_app (cho one-time purchase)
        if let receipt = jsonResponse["receipt"] as? [String: Any],
           let inAppReceipts = receipt["in_app"] as? [[String: Any]] {
            for inApp in inAppReceipts {
                if let receiptTransactionID = inApp["transaction_id"] as? String,
                   receiptTransactionID == transactionIdString {
                    print("Receipt verified successfully for transaction: \(transactionIdString) in in_app")
                    return true
                }
            }
        }
        
        print("Transaction ID \(transactionIdString) not found in receipt.")
        return false
    }
    
    private func updatePurchasedProducts() async {
        var updatedProducts = Set<String>()
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                updatedProducts.insert(transaction.productID)
                print("Found purchased product: \(transaction.productID)")
            }
        }
        purchasedProductIDs = updatedProducts
        hasPro = !purchasedProductIDs.isEmpty
        print("Updated purchased products: \(purchasedProductIDs), hasPro: \(hasPro)")
    }
}

// MARK: - SKPaymentTransactionObserver (Non-MainActor)
extension SubscriptionsManager: SKPaymentTransactionObserver {
    nonisolated public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        DispatchQueue.main.async {
            print("Transactions updated: \(transactions.count)")
            for transaction in transactions {
                print("Transaction state: \(transaction.transactionState.rawValue) for product: \(transaction.payment.productIdentifier)")
            }
        }
    }

    nonisolated public func paymentQueue(_ queue: SKPaymentQueue, shouldAddStorePayment payment: SKPayment, for product: SKProduct) -> Bool {
        return true
    }
}

// MARK: - Product Extensions
extension Product {
    var isFree: Bool {
        price == 0.00
    }

    var localizedPrice: String? {
        guard !isFree else { return nil }
        return displayPrice
    }
}
