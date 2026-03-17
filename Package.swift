// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "BareRPC",
  platforms: [.macOS(.v11), .iOS(.v14)],
  products: [
    .library(name: "BareRPC", targets: ["BareRPC"])
  ],
  dependencies: [
    .package(url: "https://github.com/holepunchto/compact-encoding-swift", branch: "main")
  ],
  targets: [
    .target(
      name: "BareRPC",
      dependencies: [.product(name: "CompactEncoding", package: "compact-encoding-swift")],
      path: "Sources/BareRPC"
    ),
    .testTarget(
      name: "BareRPCTests",
      dependencies: ["BareRPC"],
      path: "Tests/BareRPCTests"
    )
  ]
)
