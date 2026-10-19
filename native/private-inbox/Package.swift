// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PrivateInbox",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [.library(name: "PrivateInbox", targets: ["PrivateInbox"])],
  dependencies: [
    // Sentry 9.30.2 is a permanently disconnected native crash collector.
    .package(
      url: "https://github.com/getsentry/sentry-cocoa.git",
      revision: "4bb2282661ee6ca2212aa01d19a1214394cd3c45"),
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
        .product(name: "Sentry", package: "sentry-cocoa"),
        .product(name: "SwiftMail", package: "SwiftMail"),
        .product(name: "Logging", package: "swift-log"),
      ]),
    .testTarget(name: "PrivateInboxTests", dependencies: ["PrivateInbox"]),
  ]
)
