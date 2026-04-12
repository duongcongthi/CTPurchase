# CTPurchase

A lightweight Swift Package for managing In-App Purchases using StoreKit 2, supporting optional App Group for shared UserDefaults across your app and extensions. Built with modern concurrency (`async/await`).

## Features

- Simple interface to manage purchases and check premium status using `async/await`.
- Automatic loading of products and listening for transactions.
- Optional App Group ID integration for shared purchase status.
- Provides helper `ProductInfo` struct for easier UI display.
- Built-in loading state and error message handling via `@Published` properties.

## Requirements

- iOS 15.0+
- macOS 12.0+ if building or using the package on macOS
- Xcode 13.0+

## Installation

1.  In Xcode, go to `File > Add Packages...`.
2.  Enter the repository URL for this package.
3.  Select the `CTPurchase` package product.

## Usage

### 1. Import the Package

```swift
import CTPurchase
```

### 2. Configure the Manager

Call `configure` **once** early in your app's lifecycle (e.g., in your `AppDelegate`'s `didFinishLaunchingWithOptions` or your SwiftUI App's `init`).

```swift
@main
struct YourApp: App {
    init() {
        // --- Configuration ---
        
        // Option 1: App only has 2 ids:
        // BundleID.lifetime and BundleID.week
        PurchaseManager.shared.configure() 
        
        // Option 2: Same 2 keys, but custom App Store Connect ids
        // PurchaseManager.shared.configure(customIDs: [
        //     .lifetime: "com.yourcompany.yourapp.lifetime",
        //     .week: "com.yourcompany.yourapp.week"
        // ])
        
        // Option 3: App has many custom premium ids
        // PurchaseManager.shared.configure(productIDs: [
        //     "com.yourcompany.yourapp.weekly",
        //     "com.yourcompany.yourapp.monthly",
        //     "com.yourcompany.yourapp.yearly",
        //     "com.yourcompany.yourapp.lifetime"
        // ])

        // Option 4: With App Group (uses shared UserDefaults)
        // Replace "group.com.yourcompany.yourapp" with your actual App Group ID
        // PurchaseManager.shared.configure(appGroupID: "group.com.yourcompany.yourapp") 

        // ---------------------
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Make the manager available in the environment if needed
                .environmentObject(PurchaseManager.shared) 
        }
    }
}
```

### 3. Observe Purchase Status and State in SwiftUI

Inject `PurchaseManager` into your SwiftUI environment and observe its `@Published` properties.

```swift
import SwiftUI
import CTPurchase

struct ContentView: View {
    @EnvironmentObject var purchaseManager: PurchaseManager

    var body: some View {
        VStack {
            if purchaseManager.isLoading {
                ProgressView("Loading...")
            } else {
                Text("Is Premium: \\(purchaseManager.isPurchased ? "Yes" : "No")")

                // Display Products
                ForEach(purchaseManager.products, id: \\.id) { product in
                    Button {
                        Task {
                           let success = await purchaseManager.buyProduct(product)
                           if success {
                               print("Purchase successful!")
                           } else {
                               print("Purchase failed or cancelled.")
                           }
                        }
                    } label: {
                        Text("Buy \\(product.displayName) - \\(product.displayPrice)")
                    }
                    .disabled(purchaseManager.isLoading || purchaseManager.isPurchased) // Disable if loading or already premium
                }
                
                // Restore Button
                Button("Restore Purchases") {
                    Task {
                        await purchaseManager.restorePurchases()
                    }
                }
                .disabled(purchaseManager.isLoading)
            }
            
            // Display Error Message if any
            if let errorMessage = purchaseManager.errorMessage {
                Text("Error: \\(errorMessage)")
                    .foregroundColor(.red)
            }
        }
        // Present alert based on the manager's state
        .alert("Error", isPresented: $purchaseManager.isShowingErrorAlert) {
             Button("OK", role: .cancel) { }
        } message: {
             Text(purchaseManager.errorMessage ?? "An unknown error occurred.")
        }
    }
}

```

### 4. Accessing Product Information for UI

Use the `getInfo(for:)` helper method to get a display-friendly `ProductInfo` object.

```swift
if let lifetimeInfo = purchaseManager.getInfo(for: .lifetime) {
    print("Title: \\(lifetimeInfo.title)")
    print("Price: \\(lifetimeInfo.localizePrice)")
}
```

For apps configured with many custom ids, use the product id directly:

```swift
if let weeklyInfo = purchaseManager.getInfo(forProductID: "com.yourcompany.yourapp.weekly") {
    print("Title: \\(weeklyInfo.title)")
    print("Price: \\(weeklyInfo.localizePrice)")
}
```

### 5. Checking for Free Trials (Example)

```swift
if purchaseManager.hasFreeTrialForWeekSubscription() {
    print("Weekly subscription has a free trial.")
}
```

### 6. Checking Offers by In-App Product ID

Use the new in-app id helpers when you need to check a specific product id directly, for example free 3 days or free 7 days.

```swift
let productID = "com.yourcompany.yourapp.weekly"

Task {
    // Auto-loads this product id if it has not been loaded yet.
    let hasAnyTrial = await purchaseManager.fetchHasFreeTrial(forProductID: productID)
    let has3DaysTrial = await purchaseManager.fetchHasFreeTrial3Days(forProductID: productID)
    let has7DaysTrial = await purchaseManager.fetchHasFreeTrial7Days(forProductID: productID)

    if let offerInfo = await purchaseManager.fetchIntroductoryOfferInfo(forProductID: productID) {
        print("Payment mode: \\(offerInfo.paymentMode.rawValue)")
        print("Duration: \\(offerInfo.durationDescription)")
        print("Exact days: \\(offerInfo.exactDurationInDays ?? 0)")
    }
}
```

If the product has already been loaded, you can use the non-async checks:

```swift
let isFree7Days = purchaseManager.hasFreeTrial(forProductID: productID, days: 7)
let isFree1Week = purchaseManager.hasFreeTrial(forProductID: productID, value: 1, unit: .week)
```

## Important Notes

-   **Product Identifiers:** `configure()` loads `BundleID.lifetime` and `BundleID.week`. Use `configure(customIDs:)` for those same 2 keys with custom ids, or `configure(productIDs:)` when an app has many premium ids.
-   **App Group Setup:** If using `appGroupID`, make sure the App Group is correctly configured in your Xcode project's capabilities for all targets that need access (main app, extensions, etc.).
-   **Testing:** Test thoroughly using Sandbox accounts and TestFlight. Remember to configure products in App Store Connect.
-   **Error Handling:** Implement robust error handling based on the `errorMessage` property and the return values of `buyProduct` and `restorePurchases`.
