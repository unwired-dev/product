// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PrivateInbox",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [.library(name: "PrivateInbox", targets: ["PrivateInbox"])],
  targets: [
    .target(name: "PrivateInbox"),
    .testTarget(name: "PrivateInboxTests", dependencies: ["PrivateInbox"]),
  ]
)
