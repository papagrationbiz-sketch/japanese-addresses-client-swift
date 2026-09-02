// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "JapaneseAddressesClient",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "JapaneseAddresses", targets: ["JapaneseAddressNormalizer"])
  ],
  targets: [
    .target(
      name: "JapaneseAddressNormalizer",
      resources: [.copy("Resources")]
    ),
    .testTarget(
      name: "JapaneseAddressNormalizerTests",
      dependencies: ["JapaneseAddressNormalizer"]
    ),
  ]
)
