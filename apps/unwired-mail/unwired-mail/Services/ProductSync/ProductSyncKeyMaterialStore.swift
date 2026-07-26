import Foundation

protocol ProductSyncKeyMaterialPersisting {
  func clear(productAccountId: String) throws
  func ensureMaterial(
    productAccountId: String,
    allowCreation: Bool
  ) throws -> ProductSyncKeyMaterial
  func load(productAccountId: String) throws -> ProductSyncKeyMaterial?
  func restore(
    productAccountId: String,
    recoveryKey: ProductSyncRecoveryKey,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload
  ) throws -> ProductSyncKeyMaterial
  func save(_ material: ProductSyncKeyMaterial, productAccountId: String) throws
}

enum ProductSyncKeyMaterialStoreError: LocalizedError, Equatable {
  case recoveryRequired

  var errorDescription: String? {
    switch self {
    case .recoveryRequired:
      return "Recovery Key or trusted-device recovery is required for this Product Account."
    }
  }
}

enum ProductSyncKeyMaterialStore {
  static let serviceName = "dev.unwired.mail.product-sync"
}

struct KeychainProductSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting {
  private let service = ProductSyncKeyMaterialStore.serviceName

  func load(productAccountId: String) throws -> ProductSyncKeyMaterial? {
    guard
      let rawValue = try KeychainStore.readString(
        service: service,
        account: accountName(productAccountId: productAccountId)
      )
    else {
      return nil
    }

    let decoder = JSONDecoder()
    guard let data = rawValue.data(using: .utf8) else {
      return nil
    }

    return try ProductSyncKeyMaterial(
      snapshot: decoder.decode(ProductSyncKeyMaterialSnapshot.self, from: data)
    )
  }

  func save(_ material: ProductSyncKeyMaterial, productAccountId: String) throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(material.snapshot)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }

    try KeychainStore.writeString(
      rawValue,
      service: service,
      account: accountName(productAccountId: productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  func ensureMaterial(
    productAccountId: String,
    allowCreation: Bool
  ) throws -> ProductSyncKeyMaterial {
    if let material = try load(productAccountId: productAccountId) {
      try save(material, productAccountId: productAccountId)
      return material
    }
    guard allowCreation else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }

    let material = try ProductSyncKeyMaterial.create()
    try save(material, productAccountId: productAccountId)
    return material
  }

  func restore(
    productAccountId: String,
    recoveryKey: ProductSyncRecoveryKey,
    recoveryWrappedAccountKey: ProductSyncEncryptedPayload
  ) throws -> ProductSyncKeyMaterial {
    let material = try ProductSyncKeyMaterial.restore(
      recoveryKey: recoveryKey,
      recoveryWrappedAccountKey: recoveryWrappedAccountKey
    )
    try save(material, productAccountId: productAccountId)
    return material
  }

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(
      service: service,
      account: accountName(productAccountId: productAccountId)
    )
  }

  private func accountName(productAccountId: String) -> String {
    "material-\(productAccountId)"
  }
}

#if DEBUG || TESTING
  final class InMemoryProductSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting {
    private var materials: [String: ProductSyncKeyMaterial] = [:]
    private(set) var saveCount = 0

    func load(productAccountId: String) throws -> ProductSyncKeyMaterial? {
      materials[productAccountId]
    }

    func save(_ material: ProductSyncKeyMaterial, productAccountId: String) throws {
      saveCount += 1
      materials[productAccountId] = material
    }

    func ensureMaterial(
      productAccountId: String,
      allowCreation: Bool
    ) throws -> ProductSyncKeyMaterial {
      if let material = materials[productAccountId] {
        try save(material, productAccountId: productAccountId)
        return material
      }
      guard allowCreation else {
        throw ProductSyncKeyMaterialStoreError.recoveryRequired
      }

      let material = try ProductSyncKeyMaterial.create()
      try save(material, productAccountId: productAccountId)
      return material
    }

    func restore(
      productAccountId: String,
      recoveryKey: ProductSyncRecoveryKey,
      recoveryWrappedAccountKey: ProductSyncEncryptedPayload
    ) throws -> ProductSyncKeyMaterial {
      let material = try ProductSyncKeyMaterial.restore(
        recoveryKey: recoveryKey,
        recoveryWrappedAccountKey: recoveryWrappedAccountKey
      )
      materials[productAccountId] = material
      return material
    }

    func clear(productAccountId: String) throws {
      materials[productAccountId] = nil
    }
  }
#endif
