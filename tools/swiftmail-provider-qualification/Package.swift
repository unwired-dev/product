// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SwiftMailProviderQualification",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "swiftmail-provider-qualification",
      targets: ["swiftmail-provider-qualification"]
    )
  ],
  dependencies: [
    .package(
      url: "https://github.com/Cocoanetics/SwiftMail.git",
      exact: "1.10.0"
    )
  ],
  targets: [
    .target(
      name: "SwiftMailProviderQualification",
      dependencies: ["SwiftMail"]
    ),
    .executableTarget(
      name: "swiftmail-provider-qualification",
      dependencies: ["SwiftMailProviderQualification"]
    ),
    .testTarget(
      name: "SwiftMailProviderQualificationTests",
      dependencies: ["SwiftMailProviderQualification"]
    ),
  ]
)
