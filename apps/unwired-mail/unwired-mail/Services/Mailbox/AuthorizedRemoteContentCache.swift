import CryptoKit
import Foundation

// swiftlint:disable file_length type_body_length

protocol AuthorizedRemoteContentCacheClearing {
  func clear(productAccountId: String) throws
  func clear(productAccountId: String, profileId: MailProfileId) throws
  func clear(productAccountId: String, connectionId: MailboxConnectionId) throws
}

/// Identifies one authorized remote resource without exposing message or resource data on disk.
struct AuthorizedRemoteContentCacheKey: Hashable, Sendable {
  let messageId: StableProviderMessageIdentity
  let presentationRevision: String
  let productAccountId: String
  let profileId: MailProfileId
  let resourceURL: URL

  fileprivate var associatedData: Data {
    Data(
      [
        "authorized-remote-content-v1",
        productAccountId,
        profileId.rawValue,
        messageId.connectionId.rawValue,
        messageId.rawValue,
        presentationRevision,
        resourceURL.absoluteString,
      ].joined(separator: "\u{0}").utf8
    )
  }

  fileprivate func fileURL(rootDirectory: URL) -> URL {
    rootDirectory
      .appending(path: Self.digest(productAccountId), directoryHint: .isDirectory)
      .appending(path: Self.digest(profileId.rawValue), directoryHint: .isDirectory)
      .appending(path: Self.digest(messageId.connectionId.rawValue), directoryHint: .isDirectory)
      .appending(path: Self.digest(messageId.rawValue), directoryHint: .isDirectory)
      .appending(
        path: "\(Self.digest(presentationRevision + "\u{0}" + resourceURL.absoluteString)).cache"
      )
  }

  fileprivate static func digest(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    let characters = Array("0123456789abcdef".utf8)
    var encoded = [UInt8]()
    encoded.reserveCapacity(64)
    for byte in digest {
      encoded.append(characters[Int(byte >> 4)])
      encoded.append(characters[Int(byte & 0x0f)])
    }
    guard let result = String(bytes: encoded, encoding: .utf8) else {
      preconditionFailure("A hexadecimal digest must be valid UTF-8")
    }
    return result
  }
}

/// Binds remote resources to one exact authorized message presentation.
struct AuthorizedRemoteContentCacheContext: Sendable {
  let messageId: StableProviderMessageIdentity
  let presentationRevision: String
  let productAccountId: String
  let profileId: MailProfileId

  init(
    productAccountId: String,
    profileId: MailProfileId,
    messageId: StableProviderMessageIdentity,
    html: SanitizedMessageHTML
  ) {
    self.productAccountId = productAccountId
    self.profileId = profileId
    self.messageId = messageId
    presentationRevision = Self.presentationRevision(for: html)
  }

  func key(for reference: RemoteMessageImageReference) -> AuthorizedRemoteContentCacheKey {
    AuthorizedRemoteContentCacheKey(
      messageId: messageId,
      presentationRevision: presentationRevision,
      productAccountId: productAccountId,
      profileId: profileId,
      resourceURL: reference.url
    )
  }

  private static func presentationRevision(for html: SanitizedMessageHTML) -> String {
    let references = html.remoteImageReferences.map {
      "\($0.identifier)\u{0}\($0.url.absoluteString)"
    }
    return AuthorizedRemoteContentCacheKey.digest(
      ([html.documentHTML] + references).joined(separator: "\u{0}")
    )
  }
}

/// Stores authorized remote content encrypted under the Product Account key.
struct AuthorizedRemoteContentCache: @unchecked Sendable, AuthorizedRemoteContentCacheClearing {
  struct WritePermit: Sendable {
    fileprivate let accountGeneration: Int
    fileprivate let accountKey: String
    fileprivate let connectionGeneration: Int
    fileprivate let connectionKey: String
    fileprivate let profileGeneration: Int
    fileprivate let profileKey: String
    fileprivate let rootGeneration: Int
    fileprivate let rootKey: String
  }

  private struct Payload: Codable {
    let data: Data
    let mimeType: String
  }

  private struct StoredFile {
    let accessedAt: Date
    let byteCount: Int
    let url: URL
  }

  static let maximumStoredByteCount = 250 * 1_024 * 1_024

  private static let mutationLock = NSRecursiveLock()
  private static var accountGenerations: [String: Int] = [:]
  private static var connectionGenerations: [String: Int] = [:]
  private static var profileGenerations: [String: Int] = [:]
  private static var protectedFileCounts: [String: Int] = [:]
  private static var rootGenerations: [String: Int] = [:]

  private let fileManager: FileManager
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let maximumStoredByteCount: Int
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    maximumStoredByteCount: Int = Self.maximumStoredByteCount,
    rootDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    self.keyMaterialStore = keyMaterialStore
    self.maximumStoredByteCount = max(0, maximumStoredByteCount)
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(
        path: "UnwiredMail/AuthorizedRemoteContent",
        directoryHint: .isDirectory
      )
  }

  /// Returns and records access to a cached image, or `nil` when no valid entry is available.
  func image(
    for key: AuthorizedRemoteContentCacheKey,
    identifier: String,
    accessedAt: Date = .now
  ) -> RemoteMessageImage? {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let location = key.fileURL(rootDirectory: rootDirectory)
    guard fileManager.fileExists(atPath: location.path) else { return nil }
    guard
      let material = try? keyMaterialStore.load(productAccountId: key.productAccountId),
      let storedData = try? Data(contentsOf: location)
    else { return nil }
    do {
      let encrypted = try JSONDecoder().decode(ProductSyncEncryptedPayload.self, from: storedData)
      let decrypted = try material.decryptPayload(encrypted, associatedData: key.associatedData)
      let payload = try JSONDecoder().decode(Payload.self, from: decrypted)
      try? fileManager.setAttributes(
        [.modificationDate: accessedAt],
        ofItemAtPath: location.path
      )
      return RemoteMessageImage(
        data: payload.data,
        identifier: identifier,
        mimeType: payload.mimeType
      )
    } catch {
      try? fileManager.removeItem(at: location)
      return nil
    }
  }

  /// Captures the deletion generations that must still match when a network load finishes.
  func makeWritePermit(for key: AuthorizedRemoteContentCacheKey) -> WritePermit {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let accountKey = generationAccountKey(key.productAccountId)
    let connectionKey = generationConnectionKey(
      productAccountId: key.productAccountId,
      connectionId: key.messageId.connectionId
    )
    let profileKey = generationProfileKey(
      productAccountId: key.productAccountId,
      profileId: key.profileId
    )
    return WritePermit(
      accountGeneration: Self.accountGenerations[accountKey, default: 0],
      accountKey: accountKey,
      connectionGeneration: Self.connectionGenerations[connectionKey, default: 0],
      connectionKey: connectionKey,
      profileGeneration: Self.profileGenerations[profileKey, default: 0],
      profileKey: profileKey,
      rootGeneration: Self.rootGenerations[rootKey, default: 0],
      rootKey: rootKey
    )
  }

  /// Encrypts and stores an admitted image when the cache has eligible space.
  @discardableResult
  func save(
    _ image: RemoteMessageImage,
    for key: AuthorizedRemoteContentCacheKey,
    writePermit: WritePermit
  ) throws -> Bool {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    guard writePermit.rootKey == rootKey,
      writePermit.rootGeneration == Self.rootGenerations[rootKey, default: 0],
      writePermit.accountGeneration
        == Self.accountGenerations[writePermit.accountKey, default: 0],
      writePermit.profileGeneration
        == Self.profileGenerations[writePermit.profileKey, default: 0],
      writePermit.connectionGeneration
        == Self.connectionGenerations[writePermit.connectionKey, default: 0]
    else { throw CancellationError() }
    guard let material = try keyMaterialStore.load(productAccountId: key.productAccountId) else {
      return false
    }
    let location = key.fileURL(rootDirectory: rootDirectory)
    if fileManager.fileExists(atPath: location.path) {
      try fileManager.setAttributes([.modificationDate: Date.now], ofItemAtPath: location.path)
      return true
    }
    let plaintext = try JSONEncoder().encode(
      Payload(data: image.data, mimeType: image.mimeType)
    )
    let encrypted = try material.encryptPayload(plaintext, associatedData: key.associatedData)
    let encoded = try JSONEncoder().encode(encrypted)
    guard try makeRoom(for: encoded.count, excluding: location) else { return false }
    try fileManager.createDirectory(
      at: location.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoded.write(to: location, options: [.atomic, .completeFileProtection])
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var protectedLocation = location
    try protectedLocation.setResourceValues(resourceValues)
    return true
  }

  /// Prevents LRU eviction while matching content is displayed.
  func protect(_ keys: Set<AuthorizedRemoteContentCacheKey>) {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    for key in keys {
      let path = protectedPath(for: key)
      Self.protectedFileCounts[path, default: 0] += 1
    }
  }

  /// Releases a prior display-protection claim.
  func release(_ keys: Set<AuthorizedRemoteContentCacheKey>) {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    for key in keys {
      let path = protectedPath(for: key)
      let remaining = Self.protectedFileCounts[path, default: 1] - 1
      Self.protectedFileCounts[path] = remaining > 0 ? remaining : nil
    }
  }

  /// Removes one invalid or stale entry without affecting sibling resources.
  func remove(_ key: AuthorizedRemoteContentCacheKey) {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let location = key.fileURL(rootDirectory: rootDirectory)
    guard fileManager.fileExists(atPath: location.path) else { return }
    try? fileManager.removeItem(at: location)
  }

  /// Returns the device-wide encrypted remote-content usage.
  func storedByteCount() -> Int64 {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    return storedFiles(excluding: nil).reduce(into: Int64.zero) {
      $0 += Int64($1.byteCount)
    }
  }

  /// Returns the encrypted remote-content usage owned by one Product Account.
  func storedByteCount(productAccountId: String) -> Int64 {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    return storedFiles(in: accountDirectory(productAccountId)).reduce(into: Int64.zero) {
      $0 += Int64($1.byteCount)
    }
  }

  /// Removes every device-local authorized remote-content entry.
  func clearAll() throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    Self.rootGenerations[rootKey, default: 0] += 1
    removeProtectionClaims(in: rootDirectory)
    guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
    try fileManager.removeItem(at: rootDirectory)
  }

  /// Removes every entry owned by one Product Account.
  func clear(productAccountId: String) throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let key = generationAccountKey(productAccountId)
    Self.accountGenerations[key, default: 0] += 1
    let directory = accountDirectory(productAccountId)
    removeProtectionClaims(in: directory)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }

  /// Removes every entry owned by one Mail Profile.
  func clear(productAccountId: String, profileId: MailProfileId) throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let key = generationProfileKey(productAccountId: productAccountId, profileId: profileId)
    Self.profileGenerations[key, default: 0] += 1
    let directory = profileDirectory(productAccountId: productAccountId, profileId: profileId)
    removeProtectionClaims(in: directory)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }

  /// Removes entries for one Mailbox Connection across the Product Account's Profiles.
  func clear(productAccountId: String, connectionId: MailboxConnectionId) throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let key = generationConnectionKey(
      productAccountId: productAccountId,
      connectionId: connectionId
    )
    Self.connectionGenerations[key, default: 0] += 1
    let accountDirectory = accountDirectory(productAccountId)
    removeProtectionClaims(
      productAccountId: productAccountId,
      connectionId: connectionId
    )
    guard
      let profileDirectories = try? fileManager.contentsOfDirectory(
        at: accountDirectory,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else { return }
    let connectionName = AuthorizedRemoteContentCacheKey.digest(connectionId.rawValue)
    for profileDirectory in profileDirectories {
      let directory = profileDirectory.appending(
        path: connectionName,
        directoryHint: .isDirectory
      )
      if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
      }
    }
  }

  private var rootKey: String {
    rootDirectory.standardizedFileURL.path
  }

  private func protectedPath(for key: AuthorizedRemoteContentCacheKey) -> String {
    key.fileURL(rootDirectory: rootDirectory).standardizedFileURL.path
  }

  private func removeProtectionClaims(in directory: URL) {
    let directoryPath = directory.standardizedFileURL.path
    let descendantPrefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"
    Self.protectedFileCounts = Self.protectedFileCounts.filter { path, _ in
      path != directoryPath && !path.hasPrefix(descendantPrefix)
    }
  }

  private func removeProtectionClaims(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) {
    let accountPath = accountDirectory(productAccountId).standardizedFileURL.path
    let accountPrefix = accountPath.hasSuffix("/") ? accountPath : "\(accountPath)/"
    let connectionName = AuthorizedRemoteContentCacheKey.digest(connectionId.rawValue)
    Self.protectedFileCounts = Self.protectedFileCounts.filter { path, _ in
      guard path.hasPrefix(accountPrefix) else { return true }
      let relativePath = path.dropFirst(accountPrefix.count)
      let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
      return components.count < 2 || components[1] != Substring(connectionName)
    }
  }

  private func accountDirectory(_ productAccountId: String) -> URL {
    rootDirectory.appending(
      path: AuthorizedRemoteContentCacheKey.digest(productAccountId),
      directoryHint: .isDirectory
    )
  }

  private func profileDirectory(
    productAccountId: String,
    profileId: MailProfileId
  ) -> URL {
    accountDirectory(productAccountId).appending(
      path: AuthorizedRemoteContentCacheKey.digest(profileId.rawValue),
      directoryHint: .isDirectory
    )
  }

  private func generationAccountKey(_ productAccountId: String) -> String {
    "\(rootKey):\(AuthorizedRemoteContentCacheKey.digest(productAccountId))"
  }

  private func generationProfileKey(
    productAccountId: String,
    profileId: MailProfileId
  ) -> String {
    "\(generationAccountKey(productAccountId)):\(AuthorizedRemoteContentCacheKey.digest(profileId.rawValue))"
  }

  private func generationConnectionKey(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> String {
    "\(generationAccountKey(productAccountId)):\(AuthorizedRemoteContentCacheKey.digest(connectionId.rawValue))"
  }

  private func makeRoom(for incomingByteCount: Int, excluding excludedURL: URL) throws -> Bool {
    guard incomingByteCount <= maximumStoredByteCount else { return false }
    var files = storedFiles(excluding: excludedURL)
    var storedByteCount = files.reduce(0) { $0 + $1.byteCount }
    files.sort {
      if $0.accessedAt != $1.accessedAt { return $0.accessedAt < $1.accessedAt }
      return $0.url.lastPathComponent < $1.url.lastPathComponent
    }
    while storedByteCount > maximumStoredByteCount - incomingByteCount,
      let eviction = files.first(where: {
        Self.protectedFileCounts[$0.url.standardizedFileURL.path, default: 0] == 0
      })
    {
      try fileManager.removeItem(at: eviction.url)
      storedByteCount -= eviction.byteCount
      files.removeAll { $0.url == eviction.url }
    }
    return storedByteCount <= maximumStoredByteCount - incomingByteCount
  }

  private func storedFiles(excluding excludedURL: URL?) -> [StoredFile] {
    storedFiles(in: rootDirectory, excluding: excludedURL)
  }

  private func storedFiles(in directory: URL) -> [StoredFile] {
    storedFiles(in: directory, excluding: nil)
  }

  private func storedFiles(in directory: URL, excluding excludedURL: URL?) -> [StoredFile] {
    guard fileManager.fileExists(atPath: directory.path),
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [
          .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
      )
    else { return [] }
    return enumerator.compactMap { item -> StoredFile? in
      guard let url = item as? URL, url != excludedURL,
        let values = try? url.resourceValues(forKeys: [
          .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]),
        values.isRegularFile == true
      else { return nil }
      return StoredFile(
        accessedAt: values.contentModificationDate ?? .distantPast,
        byteCount: values.fileSize ?? 0,
        url: url
      )
    }
  }
}
