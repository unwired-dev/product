import Foundation

/// One pinned open-source package acknowledged by Unwired Mail.
struct OpenSourcePackage: Equatable, Identifiable {
  let name: String
  let license: String
  let licenseURL: URL
  let repositoryURL: URL

  var id: String { name }

  /// Every package pinned by the Apple app's resolved Swift package graph.
  static let all: [Self] = [
    package(
      "AppAuth",
      license: "Apache 2.0",
      repository: "https://github.com/openid/AppAuth-iOS",
      licensePath: "blob/2.1.0/LICENSE"
    ),
    package(
      "Swift Argument Parser",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-argument-parser",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "Swift Atomics",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-atomics",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "Swift Collections",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-collections",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "Swift Dotenv",
      license: "MIT",
      repository: "https://github.com/thebarndog/swift-dotenv",
      licensePath: "blob/develop/LICENSE"
    ),
    package(
      "Swift Log",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-log",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "SwiftNIO",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-nio",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "SwiftNIO IMAP",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-nio-imap",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "SwiftNIO SSL",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-nio-ssl",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "Swift RangeSet",
      license: "Apache 2.0",
      repository: "https://github.com/swiftlang/swift-se0270-range-set",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "Swift System",
      license: "Apache 2.0",
      repository: "https://github.com/apple/swift-system",
      licensePath: "blob/main/LICENSE.txt"
    ),
    package(
      "SwiftCross",
      license: "MIT",
      repository: "https://github.com/Cocoanetics/SwiftCross",
      licensePath: "blob/main/LICENSE"
    ),
    package(
      "SwiftMail",
      license: "BSD 2-Clause",
      repository: "https://github.com/Cocoanetics/SwiftMail",
      licensePath: "blob/main/LICENSE"
    ),
    package(
      "SwiftSoup",
      license: "MIT",
      repository: "https://github.com/scinfu/SwiftSoup",
      licensePath: "blob/master/LICENSE"
    ),
  ]

  private static func package(
    _ name: String,
    license: String,
    repository: String,
    licensePath: String
  ) -> Self {
    let repositoryURL = makeURL(repository)
    return Self(
      name: name,
      license: license,
      licenseURL: repositoryURL.appending(path: licensePath),
      repositoryURL: repositoryURL
    )
  }

  private static func makeURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
      preconditionFailure("Invalid open-source package URL: \(value)")
    }
    return url
  }
}
