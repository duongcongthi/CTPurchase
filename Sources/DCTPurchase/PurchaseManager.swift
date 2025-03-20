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
        self.userDefaults = UserDefaults.init(suiteName: appGroupID)!
        self.hasPro = userDefaults.bool(forKey: "hasPro")
        super.init()
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
        
        // Sử dụng localizedPrice từ extension
        return product.localizedPrice ?? (product.isFree ? "Free" : "N/A")
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await _ in StoreKit.Transaction.updates {
                await self?.updatePurchasedProducts()
            }
        }
    }

    public func loadProducts() async {
        do {
            self.products = try await Product.products(for: productIDs)
                .sorted(by: { $0.price > $1.price })
        } catch {
            print("Failed to fetch products: \(error.localizedDescription)")
        }
    }

    public func buyProduct(_ product: Product) async {
        do {
            let result = try await product.purchase()

            switch result {
            case let .success(.verified(transaction)):
                if await verifyReceipt(transaction: transaction) {
                    await transaction.finish()
                    await self.updatePurchasedProducts()
                } else {
                    print("Receipt verification failed!")
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
            "exclude-old-transactions": false  // Đặt thành false để lấy tất cả giao dịch
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
        let url = URL(string: urlString)!

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
            print("Verifying transaction ID: \(transactionIdString)")

            switch status {
            case 0:
                // Kiểm tra cả latest_receipt_info và receipt.in_app
                if let latestReceiptInfo = jsonResponse["latest_receipt_info"] as? [[String: Any]] {
                    for receipt in latestReceiptInfo {
                        if let receiptTransactionID = receipt["transaction_id"] as? String,
                           receiptTransactionID == transactionIdString {
                            print("Receipt verified successfully for transaction: \(transactionIdString)")
                            return true
                        }
                    }
                }
                
                // Kiểm tra trong receipt.in_app (phần thay thế)
                if let receipt = jsonResponse["receipt"] as? [String: Any],
                   let inAppReceipts = receipt["in_app"] as? [[String: Any]] {
                    for inApp in inAppReceipts {
                        if let receiptTransactionID = inApp["transaction_id"] as? String,
                           receiptTransactionID == transactionIdString {
                            print("Receipt verified successfully for transaction: \(transactionIdString)")
                            return true
                        }
                    }
                }
                
                print("Transaction ID \(transactionIdString) not found in receipt.")
                return false

            case 21000:
                print("App Store could not read the JSON object.")
            case 21002:
                print("Receipt data malformed.")
            case 21003:
                print("Receipt not authenticated.")
            case 21007:
                print("Receipt is from sandbox but sent to production.")
                // Tự động chuyển sang sandbox nếu gặp lỗi này
                if urlString == "https://buy.itunes.apple.com/verifyReceipt" {
                    print("Switching to sandbox environment...")
                    // Tạo một request mới tới sandbox
                    let sandboxUrl = URL(string: "https://sandbox.itunes.apple.com/verifyReceipt")!
                    var sandboxRequest = URLRequest(url: sandboxUrl)
                    sandboxRequest.httpMethod = "POST"
                    sandboxRequest.httpBody = requestBody
                    sandboxRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    do {
                        let (sandboxData, sandboxResponse) = try await URLSession.shared.data(for: sandboxRequest)
                        // Xử lý phản hồi từ sandbox tương tự như trên
                        // (Đoạn code này có thể được tách thành một hàm riêng để tránh lặp lại)
                    } catch {
                        print("Sandbox verification failed: \(error.localizedDescription)")
                    }
                }
            case 21008:
                print("Receipt is from production but sent to sandbox.")
            default:
                print("Receipt verification failed with status: \(status)")
            }
            return false
        } catch {
            print("Receipt verification failed: \(error.localizedDescription)")
            return false
        }
    }

    private func updatePurchasedProducts() async {
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.revocationDate == nil {
                purchasedProductIDs.insert(transaction.productID)
            } else {
                purchasedProductIDs.remove(transaction.productID)
            }
        }
        hasPro = !purchasedProductIDs.isEmpty
    }
}

// MARK: - SKPaymentTransactionObserver (Non-MainActor)
extension SubscriptionsManager: SKPaymentTransactionObserver {
    nonisolated public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        DispatchQueue.main.async {
            print("Transactions updated: \(transactions.count)")
        }
    }

    nonisolated public func paymentQueue(_ queue: SKPaymentQueue, shouldAddStorePayment payment: SKPayment, for product: SKProduct) -> Bool {
        return true
    }
}
extension Product {
    var isFree: Bool {
        price == 0.00
    }

    var localizedPrice: String? {
        guard !isFree else {
            return nil
        }
        return displayPrice
    }
}
