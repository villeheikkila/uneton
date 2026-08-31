// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "UnetonPackage",
  platforms: [
    .iOS(.v26),
    .macOS(.v13),
    .watchOS(.v26),
  ],
  products: [
    .library(name: "UnetonCore", targets: ["UnetonCore"]),
    .library(name: "UnetonActivity", targets: ["UnetonActivity"]),
    .library(name: "UnetonAPI", targets: ["UnetonAPI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/connectrpc/connect-swift", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-protobuf", from: "1.30.0"),
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "UnetonAPI",
      dependencies: [
        .product(name: "Connect", package: "connect-swift"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]
    ),
    .target(
      name: "UnetonCore",
      dependencies: [
        "UnetonAPI",
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .target(name: "UnetonActivity"),
    .testTarget(
      name: "UnetonCoreTests",
      dependencies: [
        "UnetonCore",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]
    ),
  ]
)
