// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "CTPurchase",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "CTPurchase",
            targets: ["CTPurchase"]
        ),
    ],
    targets: [
        .target(
            name: "CTPurchase",
            path: "Sources/CTPurchase"
        ),
    ]
)
