import Foundation

struct ProductAccountSessionSnapshot: Codable, Equatable {
  let appleUserIdentifier: String
  let identityToken: String
  let productAccountId: String
  let trustedDeviceId: String
}

protocol ProductAccountSessionPersisting {
  func load() throws -> ProductAccountSessionSnapshot?
  func save(_ snapshot: ProductAccountSessionSnapshot) throws
  func clear() throws
}

enum ProductAccountSessionStore {
  static let serviceName = "dev.unwired.mail.product-account"

  static func load(
    using persistence: ProductAccountSessionPersisting = KeychainProductAccountSessionStore()
  ) throws -> ProductAccountSessionSnapshot? {
    try persistence.load()
  }

  static func save(
    _ snapshot: ProductAccountSessionSnapshot,
    using persistence: ProductAccountSessionPersisting = KeychainProductAccountSessionStore()
  ) throws {
    try persistence.save(snapshot)
  }

  static func clear(
    using persistence: ProductAccountSessionPersisting = KeychainProductAccountSessionStore()
  ) throws {
    try persistence.clear()
  }
}

struct KeychainProductAccountSessionStore: ProductAccountSessionPersisting {
  private let service = ProductAccountSessionStore.serviceName

  func load() throws -> ProductAccountSessionSnapshot? {
    guard
      let rawValue = try KeychainStore.readString(
        service: service,
        account: "session"
      )
    else {
      return nil
    }

    let decoder = JSONDecoder()
    guard let data = rawValue.data(using: .utf8) else {
      return nil
    }

    return try decoder.decode(ProductAccountSessionSnapshot.self, from: data)
  }

  func save(_ snapshot: ProductAccountSessionSnapshot) throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(snapshot)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }

    try KeychainStore.writeString(rawValue, service: service, account: "session")
  }

  func clear() throws {
    try KeychainStore.delete(service: service, account: "session")
  }
}

#if DEBUG || TESTING
  final class InMemoryProductAccountSessionStore: ProductAccountSessionPersisting {
    private var snapshot: ProductAccountSessionSnapshot?

    func load() throws -> ProductAccountSessionSnapshot? {
      snapshot
    }

    func save(_ snapshot: ProductAccountSessionSnapshot) throws {
      self.snapshot = snapshot
    }

    func clear() throws {
      snapshot = nil
    }
  }
#endif
