// swift-tools-version: 6.0
import PackageDescription

// Spikes #831 and #830: run the frozen DeBERTa candidates through Core ML. Only the
// `categorization-spike` Mock Mail Session build compiles it into the Mac and mobile hosts.
let package = Package(
  name: "CategorizationSpike",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [.library(name: "CategorizationSpike", targets: ["CategorizationSpike"])],
  targets: [
    .target(name: "CategorizationSpike"),
    .testTarget(name: "CategorizationSpikeTests", dependencies: ["CategorizationSpike"]),
  ]
)
