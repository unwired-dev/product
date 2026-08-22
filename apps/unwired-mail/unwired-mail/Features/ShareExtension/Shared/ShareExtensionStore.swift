import CryptoKit
import Foundation
import Security

/// Errors that keep shared content intact while explaining the next safe action.
enum ShareExtensionStoreError: LocalizedError, Equatable {
  case configurationUnavailable
  case encryptionKeyUnavailable(OSStatus)
  case invalidStoredData
  case storageLimitExceeded

  var errorDescription: String? {
    switch self {
    case .configurationUnavailable:
      "Open Unwired Mail once before sharing."
    case .encryptionKeyUnavailable:
      "Shared Draft encryption is unavailable. Open Unwired Mail and try again."
    case .invalidStoredData:
      "Shared Draft data could not be read. Open Unwired Mail and try again."
    case .storageLimitExceeded:
      "Draft storage is full. Remove a Draft in Unwired Mail and try again."
    }
  }
}

/// Supplies the device-only key used for Share Extension metadata and pending Drafts.
protocol ShareExtensionEncryptionKeyProviding: Sendable {
  func loadOrCreateKey() throws -> SymmetricKey
}

/// Stores one random Share Extension key in the dedicated shared keychain group.
struct KeychainShareExtensionEncryptionKeyStore: ShareExtensionEncryptionKeyProviding {
  private static let account = "share-extension-encryption-key-v1"
  private static let service = "dev.unwired.mail.share-extension"

  private let accessGroup: String

  /// Creates a key store for the build-expanded shared access group.
  init(accessGroup: String) {
    self.accessGroup = accessGroup
  }

  func loadOrCreateKey() throws -> SymmetricKey {
    var item: CFTypeRef?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccessGroup as String: accessGroup,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      return SymmetricKey(data: data)
    }
    guard status == errSecItemNotFound else {
      throw ShareExtensionStoreError.encryptionKeyUnavailable(status)
    }

    let key = SymmetricKey(size: .bits256)
    let data = key.withUnsafeBytes { Data($0) }
    var addQuery = query
    addQuery[kSecReturnData as String] = nil
    addQuery[kSecMatchLimit as String] = nil
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      return try loadOrCreateKey()
    }
    guard addStatus == errSecSuccess else {
      throw ShareExtensionStoreError.encryptionKeyUnavailable(addStatus)
    }
    return key
  }
}

/// Persistence boundary shared by the extension and its containing app.
protocol ShareExtensionStoring: Sendable {
  func loadCatalog() async throws -> ShareExtensionCatalog?
  func loadPendingDrafts() async throws -> [ShareExtensionDraftPayload]
  func removePendingDraft(_ draftId: UUID) async throws
  func saveCatalog(_ catalog: ShareExtensionCatalog) async throws
  func savePendingDraft(_ draft: ShareExtensionDraftPayload) async throws
}

/// Encrypts Share Extension state in the app-group container without using product credentials.
actor ShareExtensionStore: ShareExtensionStoring {
  static let deviceStorageLimit = 100 * 1_024 * 1_024

  private let fileManager: FileManager
  private let keyProvider: any ShareExtensionEncryptionKeyProviding
  private let rootDirectory: URL
  private let storageLimit: Int

  /// Creates the live app-group store when the required shared capabilities are available.
  static func live(
    fileManager: FileManager = .default
  ) throws -> ShareExtensionStore {
    guard
      let rootDirectory = ShareExtensionConfiguration.sharedRootDirectory(
        fileManager: fileManager
      ),
      let accessGroup = ShareExtensionConfiguration.keychainAccessGroup()
    else { throw ShareExtensionStoreError.configurationUnavailable }
    return ShareExtensionStore(
      fileManager: fileManager,
      keyProvider: KeychainShareExtensionEncryptionKeyStore(accessGroup: accessGroup),
      rootDirectory: rootDirectory
    )
  }

  /// Creates a store with explicit dependencies for deterministic tests.
  init(
    fileManager: FileManager = .default,
    keyProvider: any ShareExtensionEncryptionKeyProviding,
    rootDirectory: URL,
    storageLimit: Int = ShareExtensionStore.deviceStorageLimit
  ) {
    self.fileManager = fileManager
    self.keyProvider = keyProvider
    self.rootDirectory = rootDirectory
    self.storageLimit = storageLimit
  }

  func loadCatalog() throws -> ShareExtensionCatalog? {
    let file = shareDirectory.appending(path: "catalog.bin")
    guard fileManager.fileExists(atPath: file.path) else { return nil }
    return try decrypt(ShareExtensionCatalog.self, from: file, context: "catalog-v1")
  }

  func saveCatalog(_ catalog: ShareExtensionCatalog) throws {
    let file = shareDirectory.appending(path: "catalog.bin")
    try writeEncrypted(catalog, to: file, context: "catalog-v1", enforcesStorageLimit: false)
  }

  func loadPendingDrafts() throws -> [ShareExtensionDraftPayload] {
    guard fileManager.fileExists(atPath: pendingDirectory.path) else { return [] }
    let files = try fileManager.contentsOfDirectory(
      at: pendingDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "bin" }
    return try files.map { file in
      let draftId = file.deletingPathExtension().lastPathComponent
      return try decrypt(
        ShareExtensionDraftPayload.self,
        from: file,
        context: "draft-v1.\(draftId)"
      )
    }.sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
  }

  func savePendingDraft(_ draft: ShareExtensionDraftPayload) throws {
    guard draft.inputByteCount <= ShareExtensionDraftPayload.maximumInputByteCount else {
      throw ShareExtensionStoreError.storageLimitExceeded
    }
    let file = pendingDirectory.appending(path: "\(draft.id.uuidString.lowercased()).bin")
    try writeEncrypted(
      draft,
      to: file,
      context: "draft-v1.\(draft.id.uuidString.lowercased())",
      enforcesStorageLimit: true
    )
  }

  func removePendingDraft(_ draftId: UUID) throws {
    let file = pendingDirectory.appending(path: "\(draftId.uuidString.lowercased()).bin")
    guard fileManager.fileExists(atPath: file.path) else { return }
    try fileManager.removeItem(at: file)
  }

  private var pendingDirectory: URL {
    shareDirectory.appending(path: "PendingDrafts", directoryHint: .isDirectory)
  }

  private var shareDirectory: URL {
    rootDirectory.appending(path: "ShareExtension", directoryHint: .isDirectory)
  }

  private func decrypt<Value: Decodable>(
    _ type: Value.Type,
    from file: URL,
    context: String
  ) throws -> Value {
    do {
      let key = try keyProvider.loadOrCreateKey()
      let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
      let plaintext = try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
      return try JSONDecoder().decode(type, from: plaintext)
    } catch let error as ShareExtensionStoreError {
      throw error
    } catch {
      throw ShareExtensionStoreError.invalidStoredData
    }
  }

  private func writeEncrypted<Value: Encodable>(
    _ value: Value,
    to file: URL,
    context: String,
    enforcesStorageLimit: Bool
  ) throws {
    let plaintext = try JSONEncoder().encode(value)
    let key = try keyProvider.loadOrCreateKey()
    guard
      let encrypted = try AES.GCM.seal(
        plaintext,
        using: key,
        authenticating: Data(context.utf8)
      ).combined
    else { throw ShareExtensionStoreError.invalidStoredData }
    if enforcesStorageLimit {
      let currentSize = fileSize(file)
      let projectedSize = directorySize(rootDirectory) - currentSize + encrypted.count
      guard projectedSize <= storageLimit else {
        throw ShareExtensionStoreError.storageLimitExceeded
      }
    }
    try fileManager.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encrypted.write(to: file, options: .atomic)
    #if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: file.path
      )
    #endif
  }

  private func directorySize(_ directory: URL) -> Int {
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else { return 0 }
    return enumerator.compactMap { element in
      guard let url = element as? URL else { return nil }
      return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }.reduce(0, +)
  }

  private func fileSize(_ file: URL) -> Int {
    (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }
}
