// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PrivateInbox",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [.library(name: "PrivateInbox", targets: ["PrivateInbox"])],
  dependencies: [
    // SwiftMail 1.16.0. It pins swift-nio-imap to a revision, so SwiftPM accepts it only by
    // revision; the hosts and the storage probe pin the same commit.
    .package(
      url: "https://github.com/Cocoanetics/SwiftMail.git",
      revision: "88c45cbd31b347b373f7c87e197be63eb95efbc2"),
    // swift-log 1.16.1, the version SwiftMail resolves, so its logs can be silenced.
    .package(
      url: "https://github.com/apple/swift-log.git",
      revision: "4038b6a4f74a1426f47eb1dd5b4bb5628a15d597"),
  ],
  targets: [
    .target(
      name: "PrivateInbox",
      dependencies: [
        .product(name: "SwiftMail", package: "SwiftMail"),
        .product(name: "Logging", package: "swift-log"),
      ]),
    .testTarget(name: "PrivateInboxTests", dependencies: ["PrivateInbox"]),
  ]
)
