// swift-tools-version: 6.0
import PackageDescription

// Spike #831: run the frozen DeBERTa candidates through Core ML. Only the
// `categorization-spike` Mock Mail Session build compiles it into the Mac host.
let package = Package(
  name: "CategorizationSpike",
  platforms: [.macOS("27.0")],
  products: [.library(name: "CategorizationSpike", targets: ["CategorizationSpike"])],
  targets: [
    .target(name: "CategorizationSpike"),
    .testTarget(name: "CategorizationSpikeTests", dependencies: ["CategorizationSpike"]),
  ]
)
