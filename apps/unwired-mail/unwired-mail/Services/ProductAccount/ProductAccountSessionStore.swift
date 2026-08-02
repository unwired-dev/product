import Foundation

enum ProductAccountIdentityTokenState: Equatable {
  case active
  case expired
  case unverifiable
}

struct ProductAccountSessionSnapshot: Codable, Equatable {
  let appleUserIdentifier: String
  let identityToken: String
  let identityTokenExpiresAt: Date?
  let productAccountId: String
  let trustedDeviceId: String

  init(
    appleUserIdentifier: String,
    identityToken: String,
    identityTokenExpiresAt: Date? = nil,
    productAccountId: String,
    trustedDeviceId: String
  ) {
    self.appleUserIdentifier = appleUserIdentifier
    self.identityToken = identityToken
    self.identityTokenExpiresAt = identityTokenExpiresAt
    self.productAccountId = productAccountId
    self.trustedDeviceId = trustedDeviceId
  }

  func identityTokenState(at date: Date = Date()) -> ProductAccountIdentityTokenState {
    guard let identityTokenExpiresAt else { return .unverifiable }

    return date < identityTokenExpiresAt ? .active : .expired
  }
}

struct UnacknowledgedRecoveryKey: Codable, Equatable {
  let recoveryKey: String
  let recoveryWrappedAccountKey: ProductSyncEncryptedPayload?
}

struct PendingTrustedDeviceUnregistration: Codable, Equatable {
  let appleUserIdentifier: String
  let productAccountId: String
  let trustedDeviceId: String
}

protocol ProductAccountSessionPersisting {
  func load() throws -> ProductAccountSessionSnapshot?
  func save(_ snapshot: ProductAccountSessionSnapshot) throws
  func clear() throws
  func loadUnacknowledgedRecoveryKey(productAccountId: String) throws
    -> UnacknowledgedRecoveryKey?
  func saveUnacknowledgedRecoveryKey(
    _ recoveryKey: UnacknowledgedRecoveryKey,
    productAccountId: String
  ) throws
  func clearUnacknowledgedRecoveryKey(productAccountId: String) throws
  func loadPendingTrustedDeviceUnregistrations() throws -> [PendingTrustedDeviceUnregistration]
  func savePendingTrustedDeviceUnregistration(
    _ unregistration: PendingTrustedDeviceUnregistration
  ) throws
  func clearPendingTrustedDeviceUnregistration(trustedDeviceId: String) throws
  func loadPendingSignOutProductAccountId() throws -> String?
  func savePendingSignOutProductAccountId(_ productAccountId: String) throws
  func clearPendingSignOutProductAccountId() throws
  func loadPendingOutboxCleanupProductAccountId() throws -> String?
  func savePendingOutboxCleanupProductAccountId(_ productAccountId: String) throws
  func clearPendingOutboxCleanupProductAccountId() throws
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

  private func unacknowledgedRecoveryKeyAccount(productAccountId: String) -> String {
    "unacknowledged-recovery-key-\(productAccountId)"
  }

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

  func loadUnacknowledgedRecoveryKey(productAccountId: String) throws
    -> UnacknowledgedRecoveryKey?
  {
    guard
      let rawValue = try KeychainStore.readString(
        service: service,
        account: unacknowledgedRecoveryKeyAccount(productAccountId: productAccountId)
      )
    else {
      return nil
    }
    if let data = rawValue.data(using: .utf8),
      let recoveryKey = try? JSONDecoder().decode(UnacknowledgedRecoveryKey.self, from: data)
    {
      return recoveryKey
    }
    return UnacknowledgedRecoveryKey(
      recoveryKey: rawValue,
      recoveryWrappedAccountKey: nil
    )
  }

  func saveUnacknowledgedRecoveryKey(
    _ recoveryKey: UnacknowledgedRecoveryKey,
    productAccountId: String
  ) throws {
    let data = try JSONEncoder().encode(recoveryKey)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      rawValue,
      service: service,
      account: unacknowledgedRecoveryKeyAccount(productAccountId: productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  func clearUnacknowledgedRecoveryKey(productAccountId: String) throws {
    try KeychainStore.delete(
      service: service,
      account: unacknowledgedRecoveryKeyAccount(productAccountId: productAccountId)
    )
  }

  func loadPendingTrustedDeviceUnregistrations() throws
    -> [PendingTrustedDeviceUnregistration]
  {
    guard
      let rawValue = try KeychainStore.readString(
        service: service,
        account: "pending-trusted-device-unregistration"
      ),
      let data = rawValue.data(using: .utf8)
    else {
      return []
    }
    if let unregistrations = try? JSONDecoder().decode(
      [PendingTrustedDeviceUnregistration].self,
      from: data
    ) {
      return unregistrations
    }
    guard
      let legacyUnregistration = try? JSONDecoder().decode(
        PendingTrustedDeviceUnregistration.self,
        from: data
      )
    else {
      return []
    }
    return [legacyUnregistration]
  }

  func savePendingTrustedDeviceUnregistration(
    _ unregistration: PendingTrustedDeviceUnregistration
  ) throws {
    var unregistrations = try loadPendingTrustedDeviceUnregistrations()
    unregistrations.removeAll { $0.trustedDeviceId == unregistration.trustedDeviceId }
    unregistrations.append(unregistration)
    try savePendingTrustedDeviceUnregistrations(unregistrations)
  }

  func clearPendingTrustedDeviceUnregistration(trustedDeviceId: String) throws {
    var unregistrations = try loadPendingTrustedDeviceUnregistrations()
    unregistrations.removeAll { $0.trustedDeviceId == trustedDeviceId }
    if unregistrations.isEmpty {
      try KeychainStore.delete(
        service: service,
        account: "pending-trusted-device-unregistration"
      )
    } else {
      try savePendingTrustedDeviceUnregistrations(unregistrations)
    }
  }

  private func savePendingTrustedDeviceUnregistrations(
    _ unregistrations: [PendingTrustedDeviceUnregistration]
  ) throws {
    let data = try JSONEncoder().encode(unregistrations)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      rawValue,
      service: service,
      account: "pending-trusted-device-unregistration",
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  func loadPendingSignOutProductAccountId() throws -> String? {
    try KeychainStore.readString(
      service: service,
      account: "pending-sign-out-product-account"
    )
  }

  func savePendingSignOutProductAccountId(_ productAccountId: String) throws {
    try KeychainStore.writeString(
      productAccountId,
      service: service,
      account: "pending-sign-out-product-account",
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  func clearPendingSignOutProductAccountId() throws {
    try KeychainStore.delete(
      service: service,
      account: "pending-sign-out-product-account"
    )
  }

  func loadPendingOutboxCleanupProductAccountId() throws -> String? {
    try KeychainStore.readString(
      service: service,
      account: "pending-outbox-cleanup-product-account"
    )
  }

  func savePendingOutboxCleanupProductAccountId(_ productAccountId: String) throws {
    try KeychainStore.writeString(
      productAccountId,
      service: service,
      account: "pending-outbox-cleanup-product-account",
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  func clearPendingOutboxCleanupProductAccountId() throws {
    try KeychainStore.delete(
      service: service,
      account: "pending-outbox-cleanup-product-account"
    )
  }
}

#if DEBUG || TESTING
  final class InMemoryProductAccountSessionStore: ProductAccountSessionPersisting {
    private var pendingSignOutProductAccountId: String?
    private var pendingOutboxCleanupProductAccountId: String?
    private var pendingTrustedDeviceUnregistrations: [PendingTrustedDeviceUnregistration] = []
    private var snapshot: ProductAccountSessionSnapshot?
    private var unacknowledgedRecoveryKeys: [String: UnacknowledgedRecoveryKey] = [:]

    func load() throws -> ProductAccountSessionSnapshot? {
      snapshot
    }

    func save(_ snapshot: ProductAccountSessionSnapshot) throws {
      self.snapshot = snapshot
    }

    func clear() throws {
      snapshot = nil
    }

    func loadUnacknowledgedRecoveryKey(productAccountId: String) throws
      -> UnacknowledgedRecoveryKey?
    {
      unacknowledgedRecoveryKeys[productAccountId]
    }

    func saveUnacknowledgedRecoveryKey(
      _ recoveryKey: UnacknowledgedRecoveryKey,
      productAccountId: String
    ) throws {
      unacknowledgedRecoveryKeys[productAccountId] = recoveryKey
    }

    func clearUnacknowledgedRecoveryKey(productAccountId: String) throws {
      unacknowledgedRecoveryKeys[productAccountId] = nil
    }

    func loadPendingTrustedDeviceUnregistrations() throws
      -> [PendingTrustedDeviceUnregistration]
    {
      pendingTrustedDeviceUnregistrations
    }

    func savePendingTrustedDeviceUnregistration(
      _ unregistration: PendingTrustedDeviceUnregistration
    ) throws {
      pendingTrustedDeviceUnregistrations.removeAll {
        $0.trustedDeviceId == unregistration.trustedDeviceId
      }
      pendingTrustedDeviceUnregistrations.append(unregistration)
    }

    func clearPendingTrustedDeviceUnregistration(trustedDeviceId: String) throws {
      pendingTrustedDeviceUnregistrations.removeAll { $0.trustedDeviceId == trustedDeviceId }
    }

    func loadPendingSignOutProductAccountId() throws -> String? {
      pendingSignOutProductAccountId
    }

    func savePendingSignOutProductAccountId(_ productAccountId: String) throws {
      pendingSignOutProductAccountId = productAccountId
    }

    func clearPendingSignOutProductAccountId() throws {
      pendingSignOutProductAccountId = nil
    }

    func loadPendingOutboxCleanupProductAccountId() throws -> String? {
      pendingOutboxCleanupProductAccountId
    }

    func savePendingOutboxCleanupProductAccountId(_ productAccountId: String) throws {
      pendingOutboxCleanupProductAccountId = productAccountId
    }

    func clearPendingOutboxCleanupProductAccountId() throws {
      pendingOutboxCleanupProductAccountId = nil
    }
  }
#endif
