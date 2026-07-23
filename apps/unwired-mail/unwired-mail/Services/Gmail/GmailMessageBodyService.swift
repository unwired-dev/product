import CoreFoundation
import Foundation

// swiftlint:disable file_length type_body_length

struct GmailMessageBody: Equatable {
  let text: String
}

struct GmailMessageBodyPrefetchPlan {
  static let maximumRecentMessageCount = 500
  static let recentInterval: TimeInterval = 30 * 24 * 60 * 60

  let pinnedMessages: [GmailMessageMetadata]
  let recentMessages: [GmailMessageMetadata]

  var messages: [GmailMessageMetadata] {
    recentMessages + pinnedMessages
  }

  init(
    messages: [GmailMessageMetadata],
    pinnedMessageIds: Set<String>,
    referenceDate: Date
  ) {
    var messagesByStableId: [String: GmailMessageMetadata] = [:]
    for message in messages {
      guard !message.isExcludedFromBodyPrefetch else { continue }
      let existing = messagesByStableId[message.stableProviderMessageId]
      if existing == nil
        || message.providerInternalDateMilliseconds > existing!.providerInternalDateMilliseconds
      {
        messagesByStableId[message.stableProviderMessageId] = message
      }
    }
    let lowerBoundMilliseconds = Int64(
      referenceDate.addingTimeInterval(-Self.recentInterval).timeIntervalSince1970 * 1_000
    )
    let upperBoundMilliseconds = Int64(referenceDate.timeIntervalSince1970 * 1_000)
    recentMessages = messagesByStableId.values.filter { message in
      message.isInRecentBodyPrefetchMailbox
        && (lowerBoundMilliseconds...upperBoundMilliseconds).contains(
          message.providerInternalDateMilliseconds
        )
    }.sorted(by: Self.prefetchOrder).prefix(Self.maximumRecentMessageCount).map(\.self)
    let recentMessageIds = Set(recentMessages.map(\.stableProviderMessageId))
    pinnedMessages = messagesByStableId.values.filter { message in
      pinnedMessageIds.contains(message.stableProviderMessageId)
        && !recentMessageIds.contains(message.stableProviderMessageId)
    }.sorted(by: Self.prefetchOrder)
  }

  private static func prefetchOrder(
    _ first: GmailMessageMetadata,
    _ second: GmailMessageMetadata
  ) -> Bool {
    if first.providerInternalDateMilliseconds == second.providerInternalDateMilliseconds {
      return first.stableProviderMessageId < second.stableProviderMessageId
    }
    return first.providerInternalDateMilliseconds > second.providerInternalDateMilliseconds
  }
}

extension GmailMessageMetadata {
  fileprivate var isExcludedFromBodyPrefetch: Bool {
    let labels = Set(providerLabelIds ?? [])
    return labels.contains("DRAFT") || labels.contains("SPAM") || labels.contains("TRASH")
  }

  fileprivate var isInRecentBodyPrefetchMailbox: Bool {
    let labels = Set(providerLabelIds ?? [])
    return labels.contains("INBOX") || labels.contains("SENT")
  }
}

enum GmailMessageBodyCacheRetention: String, Codable {
  case opened
  case prefetched
}

struct GmailMessageBodyCacheWrite {
  let cachedAt: Date
  let isPinned: Bool
  let isProtected: Bool
  let payload: ProductSyncEncryptedPayload
  let retention: GmailMessageBodyCacheRetention
}

protocol GmailMessageBodyCaching {
  func clearMessageBodies(productAccountId: String) throws

  func clearMessageBodies(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws

  func loadMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws -> ProductSyncEncryptedPayload?

  func removeMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId: String,
    stableProviderMessageId: String
  ) throws

  func saveMessageBody(
    _ write: GmailMessageBodyCacheWrite,
    productAccountId: String,
    stableProviderMessageId: String
  ) throws -> Bool

  func reconcileSelection(
    productAccountId: String,
    providerAccountIdentifier: String,
    protectedMessageIds: Set<String>,
    pinnedMessageIds: Set<String>
  ) throws

  func recordMessageBodyAccess(
    productAccountId: String,
    stableProviderMessageId: String,
    accessedAt: Date
  ) throws
}

extension GmailMessageBodyCaching {
  func clearMessageBodies(
    productAccountId: String,
    providerAccountIdentifier _: String
  ) throws {
    try clearMessageBodies(productAccountId: productAccountId)
  }

  func saveMessageBody(
    _ write: GmailMessageBodyCacheWrite,
    productAccountId: String,
    stableProviderMessageId: String
  ) throws -> Bool {
    try saveMessageBody(
      write.payload,
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
    return true
  }

  func reconcileSelection(
    productAccountId _: String,
    providerAccountIdentifier _: String,
    protectedMessageIds _: Set<String>,
    pinnedMessageIds _: Set<String>
  ) throws {}

  func recordMessageBodyAccess(
    productAccountId _: String,
    stableProviderMessageId _: String,
    accessedAt _: Date
  ) throws {}
}

protocol GmailMessageReading {
  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws

  func clearCachedMessageBodies(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) throws

  func loadMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody

  func prefetchMessageBodies(
    connection: GmailProviderConnectionStatus,
    pinnedMessageIds: Set<String>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws

  func removeCachedMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws
}

extension GmailMessageReading {
  func clearCachedMessageBodies(
    connection _: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) throws {
    try clearCachedMessageBodies(session: session)
  }

  func prefetchMessageBodies(
    connection _: GmailProviderConnectionStatus,
    pinnedMessageIds _: Set<String>,
    referenceDate _: Date,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

/// Reads only message bodies already present in the bounded encrypted body cache.
///
/// This boundary never fetches mail from Gmail. System Categorization uses it to keep
/// provider retrieval outside the categorization path.
///
/// Example:
/// ```swift
/// func cachedBody(
///   for message: GmailMessageMetadata,
///   session: ProductAccountSessionSnapshot
/// ) throws -> GmailMessageBody? {
///   try GmailMessageBodyService().loadCachedMessageBody(message: message, session: session)
/// }
/// ```
protocol GmailCachedMessageBodyReading {
  func loadCachedMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws -> GmailMessageBody?
}

struct FileGmailMessageBodyCache: GmailMessageBodyCaching {
  static let defaultMaximumByteCount = 500 * 1_024 * 1_024
  private static let fileLock = NSRecursiveLock()

  private let fileManager: FileManager
  private let maximumByteCount: Int
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    maximumByteCount: Int = Self.defaultMaximumByteCount,
    rootDirectory: URL? = nil
  ) {
    self.fileManager = fileManager
    self.maximumByteCount = max(0, maximumByteCount)
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/GmailBodyCache", isDirectory: true)
  }

  func clearMessageBodies(productAccountId: String) throws {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    guard fileManager.fileExists(atPath: rootDirectory.path) else {
      return
    }
    let prefixes = [
      "\(gmailSafeFileComponent(productAccountId))-",
      "\(legacyGmailSafeFileComponent(productAccountId))-",
    ]
    for fileURL in try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil
    ) where prefixes.contains(where: { fileURL.lastPathComponent.hasPrefix($0) }) {
      try fileManager.removeItem(at: fileURL)
    }
  }

  func clearMessageBodies(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    guard fileManager.fileExists(atPath: rootDirectory.path) else {
      return
    }
    let prefixes = [
      [
        gmailSafeFileComponent(productAccountId),
        gmailSafeFileComponent("gmail:\(providerAccountIdentifier):"),
      ].joined(separator: "-")
    ]
    for fileURL in try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil
    ) where prefixes.contains(where: { fileURL.lastPathComponent.hasPrefix($0) }) {
      try fileManager.removeItem(at: fileURL)
    }
  }

  func loadMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws -> ProductSyncEncryptedPayload? {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    let fileURL = fileURL(
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL)
    if let entry = try? JSONDecoder().decode(FileGmailMessageBodyCacheEntry.self, from: data) {
      return entry.payload
    }
    return try JSONDecoder().decode(ProductSyncEncryptedPayload.self, from: data)
  }

  func removeMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    let fileURL = fileURL(
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.removeItem(at: fileURL)
    }
  }

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId: String,
    stableProviderMessageId: String
  ) throws {
    _ = try saveMessageBody(
      GmailMessageBodyCacheWrite(
        cachedAt: Date(),
        isPinned: false,
        isProtected: false,
        payload: payload,
        retention: .opened
      ),
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
  }

  func saveMessageBody(
    _ write: GmailMessageBodyCacheWrite,
    productAccountId: String,
    stableProviderMessageId: String
  ) throws -> Bool {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    let destination = fileURL(
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
    let entry = FileGmailMessageBodyCacheEntry(
      cachedAt: write.cachedAt,
      isPinned: write.isPinned,
      isProtected: write.isProtected,
      lastReadAt: write.retention == .opened ? write.cachedAt : nil,
      payload: write.payload,
      retention: write.retention
    )
    return try writeEntryIfFits(entry, to: destination)
  }

  private func writeEntryIfFits(
    _ entry: FileGmailMessageBodyCacheEntry,
    to destination: URL
  ) throws -> Bool {
    let encodedEntry = try JSONEncoder().encode(entry)
    guard encodedEntry.count <= maximumByteCount else { return false }

    var cachedFiles = try cachedFiles(excluding: destination)
    var cachedByteCount = cachedFiles.reduce(0) { $0 + $1.byteCount }
    cachedFiles.sort(by: FileGmailMessageBodyCacheFile.evictionOrder)
    let canEvictProtectedEntries = entry.retention == .opened
    while cachedByteCount > maximumByteCount - encodedEntry.count,
      let eviction = cachedFiles.first(where: {
        canEvictProtectedEntries || !$0.entry.isProtected
      })
    {
      try fileManager.removeItem(at: eviction.url)
      cachedByteCount -= eviction.byteCount
      cachedFiles.removeAll { $0.url == eviction.url }
    }
    guard cachedByteCount <= maximumByteCount - encodedEntry.count else { return false }
    try encodedEntry.write(to: destination, options: [.atomic])
    return true
  }

  func reconcileSelection(
    productAccountId: String,
    providerAccountIdentifier: String,
    protectedMessageIds: Set<String>,
    pinnedMessageIds: Set<String>
  ) throws {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
    try clearProtectedSelections(productAccountId: productAccountId)
    try enforceMaximumByteCount()
    let prefix = [
      gmailSafeFileComponent(productAccountId),
      gmailSafeFileComponent("gmail:\(providerAccountIdentifier):"),
    ].joined(separator: "-")
    let protectedFileNames = Set(
      protectedMessageIds.map {
        fileURL(productAccountId: productAccountId, stableProviderMessageId: $0).lastPathComponent
      })
    let pinnedFileNames = Set(
      pinnedMessageIds.map {
        fileURL(productAccountId: productAccountId, stableProviderMessageId: $0).lastPathComponent
      })
    for fileURL in try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) where fileURL.lastPathComponent.hasPrefix(prefix) {
      guard let data = try dataIfPresent(at: fileURL) else { continue }
      var entry: FileGmailMessageBodyCacheEntry
      if let storedEntry = try? JSONDecoder().decode(
        FileGmailMessageBodyCacheEntry.self,
        from: data
      ) {
        entry = storedEntry
      } else {
        let payload = try JSONDecoder().decode(ProductSyncEncryptedPayload.self, from: data)
        let cachedAt =
          try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate ?? .distantPast
        entry = FileGmailMessageBodyCacheEntry(
          cachedAt: cachedAt,
          isPinned: false,
          isProtected: false,
          lastReadAt: cachedAt,
          payload: payload,
          retention: .opened
        )
      }
      entry.isPinned = pinnedFileNames.contains(fileURL.lastPathComponent)
      entry.isProtected = protectedFileNames.contains(fileURL.lastPathComponent)
      _ = try writeEntryIfFits(entry, to: fileURL)
    }
  }

  private func clearProtectedSelections(productAccountId: String) throws {
    let productPrefix = "\(gmailSafeFileComponent(productAccountId))-"
    for fileURL in try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil
    ) where fileURL.lastPathComponent.hasPrefix(productPrefix) {
      guard
        var entry = try? JSONDecoder().decode(
          FileGmailMessageBodyCacheEntry.self,
          from: Data(contentsOf: fileURL)
        )
      else { continue }
      entry.isProtected = false
      try JSONEncoder().encode(entry).write(to: fileURL, options: [.atomic])
    }
  }

  private func dataIfPresent(at fileURL: URL) throws -> Data? {
    do {
      return try Data(contentsOf: fileURL)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    {
      return nil
    }
  }

  func recordMessageBodyAccess(
    productAccountId: String,
    stableProviderMessageId: String,
    accessedAt: Date
  ) throws {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    let fileURL = fileURL(
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    let data = try Data(contentsOf: fileURL)
    var entry: FileGmailMessageBodyCacheEntry
    if let storedEntry = try? JSONDecoder().decode(
      FileGmailMessageBodyCacheEntry.self,
      from: data
    ) {
      entry = storedEntry
    } else {
      let payload = try JSONDecoder().decode(ProductSyncEncryptedPayload.self, from: data)
      entry = FileGmailMessageBodyCacheEntry(
        cachedAt: accessedAt,
        isPinned: false,
        isProtected: false,
        lastReadAt: nil,
        payload: payload,
        retention: .opened
      )
    }
    entry.lastReadAt = accessedAt
    entry.retention = .opened
    _ = try writeEntryIfFits(entry, to: fileURL)
  }

  private func fileURL(productAccountId: String, stableProviderMessageId: String) -> URL {
    rootDirectory.appendingPathComponent(
      "\(gmailSafeFileComponent(productAccountId))-\(gmailSafeFileComponent(stableProviderMessageId)).json"
    )
  }

  private func enforceMaximumByteCount() throws {
    var cachedFiles = try cachedFiles(excluding: nil)
    var cachedByteCount = cachedFiles.reduce(0) { $0 + $1.byteCount }
    cachedFiles.sort(by: FileGmailMessageBodyCacheFile.evictionOrder)
    while cachedByteCount > maximumByteCount,
      let eviction = cachedFiles.first(where: { !$0.entry.isProtected })
    {
      try fileManager.removeItem(at: eviction.url)
      cachedByteCount -= eviction.byteCount
      cachedFiles.removeAll { $0.url == eviction.url }
    }
  }

  private func cachedFiles(excluding excludedURL: URL?) throws
    -> [FileGmailMessageBodyCacheFile]
  {
    guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
    var cachedFiles: [FileGmailMessageBodyCacheFile] = []
    for fileURL in try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
    ) where excludedURL == nil || fileURL != excludedURL {
      let values = try fileURL.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey,
      ])
      let data = try Data(contentsOf: fileURL)
      let entry: FileGmailMessageBodyCacheEntry
      if let storedEntry = try? JSONDecoder().decode(
        FileGmailMessageBodyCacheEntry.self,
        from: data
      ) {
        entry = storedEntry
      } else if let legacyPayload = try? JSONDecoder().decode(
        ProductSyncEncryptedPayload.self,
        from: data
      ) {
        let cachedAt = values.contentModificationDate ?? .distantPast
        entry = FileGmailMessageBodyCacheEntry(
          cachedAt: cachedAt,
          isPinned: false,
          isProtected: false,
          lastReadAt: cachedAt,
          payload: legacyPayload,
          retention: .opened
        )
      } else {
        try fileManager.removeItem(at: fileURL)
        continue
      }
      cachedFiles.append(
        FileGmailMessageBodyCacheFile(
          byteCount: values.fileSize ?? data.count,
          entry: entry,
          url: fileURL
        )
      )
    }
    return cachedFiles
  }

}

private struct FileGmailMessageBodyCacheEntry: Codable {
  let cachedAt: Date
  var isPinned: Bool
  var isProtected: Bool
  var lastReadAt: Date?
  let payload: ProductSyncEncryptedPayload
  var retention: GmailMessageBodyCacheRetention
}

private struct FileGmailMessageBodyCacheFile {
  let byteCount: Int
  let entry: FileGmailMessageBodyCacheEntry
  let url: URL

  static func evictionOrder(
    _ first: FileGmailMessageBodyCacheFile,
    _ second: FileGmailMessageBodyCacheFile
  ) -> Bool {
    let firstPriority = first.evictionPriority
    let secondPriority = second.evictionPriority
    if firstPriority != secondPriority {
      return firstPriority < secondPriority
    }
    let firstDate = first.entry.lastReadAt ?? first.entry.cachedAt
    let secondDate = second.entry.lastReadAt ?? second.entry.cachedAt
    if firstDate != secondDate {
      return firstDate < secondDate
    }
    return first.url.lastPathComponent < second.url.lastPathComponent
  }

  private var evictionPriority: Int {
    if entry.isPinned { return 2 }
    return entry.retention == .opened ? 0 : 1
  }
}

private struct GmailMessageBodyPrefetchContext {
  let accessToken: String
  let keyMaterial: ProductSyncKeyMaterial
  let pinnedMessageIds: Set<String>
  let referenceDate: Date
  let session: ProductAccountSessionSnapshot
}

enum GmailMessageBodyError: LocalizedError, Equatable {
  case gmailRequestFailed
  case missingLocalGmailTokens
  case missingMessageBody
  case missingOAuthClientId
  case refreshTokenRejected

  var errorDescription: String? {
    switch self {
    case .gmailRequestFailed:
      return "Gmail message body could not be loaded."
    case .missingLocalGmailTokens:
      return "Gmail is connected on the backend, but this device has no local Gmail tokens."
    case .missingMessageBody:
      return "Gmail did not return a readable message body."
    case .missingOAuthClientId:
      return "Gmail OAuth client id is not configured."
    case .refreshTokenRejected:
      return "Gmail did not refresh local mail access for this account."
    }
  }
}

struct GmailMessageBodyService: GmailCachedMessageBodyReading, GmailMessageReading {
  private let cache: GmailMessageBodyCaching
  private let gmailBaseURL: URL
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let metadataStore: GmailMessageMetadataPersisting
  private let oauthClientId: String?
  private let session: URLSession
  private let tokenStore: GmailProviderTokenPersisting
  private let tokenRefreshURL: URL
  private let tokenInfoURL: URL

  init(
    gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1")!,
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    metadataStore: GmailMessageMetadataPersisting = SwiftDataGmailMessageMetadataStore(),
    oauthClientId: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    session: URLSession = .shared,
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    tokenRefreshURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
    tokenInfoURL: URL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!
  ) {
    self.cache = cache
    self.gmailBaseURL = gmailBaseURL
    self.keyMaterialStore = keyMaterialStore
    self.metadataStore = metadataStore
    self.oauthClientId = oauthClientId
    self.session = session
    self.tokenStore = tokenStore
    self.tokenRefreshURL = tokenRefreshURL
    self.tokenInfoURL = tokenInfoURL
  }

  func loadMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    if let cachedBody = try loadCachedMessageBody(message: message, session: session) {
      try? cache.recordMessageBodyAccess(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId,
        accessedAt: Date()
      )
      return cachedBody
    }
    let material = try requiredKeyMaterial(productAccountId: session.productAccountId)

    guard
      let tokens = try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: message.providerAccountIdentifier
      )
    else {
      throw GmailMessageBodyError.missingLocalGmailTokens
    }
    let refreshedTokens = try await refreshedTokens(
      tokens,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: message.providerAccountIdentifier
    )
    try await validateRefreshedToken(
      refreshedTokens.accessToken,
      providerAccountIdentifier: message.providerAccountIdentifier
    )
    let body = try await fetchMessageBody(
      message: message, accessToken: refreshedTokens.accessToken)
    try? cache.saveMessageBody(
      material.encryptPayload(Data(body.text.utf8), associatedData: associatedData(for: message)),
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
    return body
  }

  func prefetchMessageBodies(
    connection: GmailProviderConnectionStatus,
    pinnedMessageIds: Set<String>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try Task.checkCancellation()
    let messages = try metadataStore.loadMessages(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let plan = GmailMessageBodyPrefetchPlan(
      messages: messages,
      pinnedMessageIds: pinnedMessageIds,
      referenceDate: referenceDate
    )
    let protectedMessageIds = Set(plan.messages.map(\.stableProviderMessageId))
    try Task.checkCancellation()
    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier,
      protectedMessageIds: protectedMessageIds,
      pinnedMessageIds: pinnedMessageIds
    )
    guard !plan.messages.isEmpty else { return }

    let material = try requiredKeyMaterial(productAccountId: session.productAccountId)
    guard
      let tokens = try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerAccountIdentifier
      )
    else {
      throw GmailMessageBodyError.missingLocalGmailTokens
    }
    let refreshedTokens = try await refreshedTokens(
      tokens,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    try await validateRefreshedToken(
      refreshedTokens.accessToken,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
    let context = GmailMessageBodyPrefetchContext(
      accessToken: refreshedTokens.accessToken,
      keyMaterial: material,
      pinnedMessageIds: pinnedMessageIds,
      referenceDate: referenceDate,
      session: session
    )
    for message in plan.messages {
      try Task.checkCancellation()
      try await prefetchMessageBody(message, context: context)
    }
  }

  private func prefetchMessageBody(
    _ message: GmailMessageMetadata,
    context: GmailMessageBodyPrefetchContext
  ) async throws {
    if try loadCachedMessageBody(message: message, session: context.session) != nil {
      return
    }
    let body: GmailMessageBody
    do {
      body = try await fetchMessageBody(
        message: message,
        accessToken: context.accessToken
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return
    }
    try Task.checkCancellation()
    let encryptedPayload = try context.keyMaterial.encryptPayload(
      Data(body.text.utf8),
      associatedData: associatedData(for: message)
    )
    _ = try cache.saveMessageBody(
      GmailMessageBodyCacheWrite(
        cachedAt: context.referenceDate,
        isPinned: context.pinnedMessageIds.contains(message.stableProviderMessageId),
        isProtected: true,
        payload: encryptedPayload,
        retention: .prefetched
      ),
      productAccountId: context.session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
  }

  func loadCachedMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws -> GmailMessageBody? {
    let cached: ProductSyncEncryptedPayload?
    do {
      cached = try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      cached = nil
    }
    guard let cached else {
      return nil
    }
    let material = try requiredKeyMaterial(productAccountId: session.productAccountId)
    do {
      let decrypted = try material.decryptPayload(
        cached, associatedData: associatedData(for: message))
      guard let text = String(bytes: decrypted, encoding: .utf8) else {
        throw GmailMessageBodyError.missingMessageBody
      }
      return GmailMessageBody(text: text)
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      return nil
    }
  }

  func removeCachedMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try cache.clearMessageBodies(productAccountId: session.productAccountId)
  }

  func clearCachedMessageBodies(
    connection: GmailProviderConnectionStatus,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerAccountIdentifier
    )
  }

  private func fetchMessageBody(
    message: GmailMessageMetadata,
    accessToken: String
  ) async throws -> GmailMessageBody {
    var components = URLComponents(
      url: gmailBaseURL.appendingPathComponent("users/me/messages/\(message.providerMessageId)"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "format", value: "full")]
    guard let url = components?.url else {
      throw GmailMessageBodyError.gmailRequestFailed
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageBodyError.gmailRequestFailed
    }

    let responseBody = try JSONDecoder().decode(GmailMessageBodyResponse.self, from: data)
    guard let bodyPart = responseBody.payload.preferredBodyPart else {
      throw GmailMessageBodyError.missingMessageBody
    }
    let encodedBody = try await encodedBodyData(
      bodyPart: bodyPart,
      message: message,
      accessToken: accessToken
    )
    guard let data = Data(gmailBase64URLEncoded: encodedBody),
      let decodedText = String(data: data, encoding: bodyPart.textEncoding)
    else {
      throw GmailMessageBodyError.missingMessageBody
    }
    let text: String
    if bodyPart.mimeType == "text/html" {
      text = htmlText(decodedText)
    } else {
      text = decodedText
    }
    return GmailMessageBody(text: text)
  }

  private func refreshedTokens(
    _ tokens: GmailProviderTokens,
    productAccountId: String,
    providerAccountIdentifier: String
  ) async throws -> GmailProviderTokens {
    guard let oauthClientId, !oauthClientId.isEmpty else {
      throw GmailMessageBodyError.missingOAuthClientId
    }
    var request = URLRequest(url: tokenRefreshURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncodedBody([
      "client_id": oauthClientId,
      "grant_type": "refresh_token",
      "refresh_token": tokens.refreshToken,
    ])
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let responseBody = try? JSONDecoder().decode(GmailMessageBodyTokenResponse.self, from: data),
      !responseBody.accessToken.isEmpty
    else {
      throw GmailMessageBodyError.refreshTokenRejected
    }
    let refreshedTokens = GmailProviderTokens(
      accessToken: responseBody.accessToken,
      refreshToken: tokens.refreshToken,
      idToken: responseBody.idToken ?? tokens.idToken
    )
    try tokenStore.save(
      refreshedTokens,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    return refreshedTokens
  }

  private func formURLEncodedBody(_ fields: [String: String]) -> Data {
    fields.map { "\(formURLEncode($0.key))=\(formURLEncode($0.value))" }
      .joined(separator: "&").data(using: .utf8) ?? Data()
  }

  private func formURLEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private func validateRefreshedToken(
    _ accessToken: String,
    providerAccountIdentifier: String
  ) async throws {
    var components = URLComponents(url: tokenInfoURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
    guard let url = components?.url else { throw GmailMessageBodyError.gmailRequestFailed }
    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let tokenInfo = try? JSONDecoder().decode(GmailMessageBodyTokenInfo.self, from: data),
      tokenInfo.sub == providerAccountIdentifier,
      tokenInfo.allowsReadingMessageBodies
    else { throw GmailMessageBodyError.gmailRequestFailed }
  }

  private func encodedBodyData(
    bodyPart: GmailMessageBodyPart,
    message: GmailMessageMetadata,
    accessToken: String
  ) async throws -> String {
    if let data = bodyPart.body?.data, !data.isEmpty {
      return data
    }
    guard let attachmentId = bodyPart.body?.attachmentId else {
      throw GmailMessageBodyError.missingMessageBody
    }
    var request = URLRequest(
      url: gmailBaseURL.appendingPathComponent(
        "users/me/messages/\(message.providerMessageId)/attachments/\(attachmentId)"
      )
    )
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let attachment = try? JSONDecoder().decode(GmailMessageBodyAttachment.self, from: data),
      let encodedBody = attachment.data
    else {
      throw GmailMessageBodyError.gmailRequestFailed
    }
    return encodedBody
  }

  private func requiredKeyMaterial(productAccountId: String) throws -> ProductSyncKeyMaterial {
    guard let material = try keyMaterialStore.load(productAccountId: productAccountId) else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }
    return material
  }

  private func associatedData(for message: GmailMessageMetadata) -> Data {
    Data("gmail-body-cache:\(message.stableProviderMessageId)".utf8)
  }

  private func htmlText(_ value: String) -> String {
    let withoutNonVisibleBlocks = value.replacingOccurrences(
      of: "<(?:script|style)\\b[^>]*>[\\s\\S]*?</(?:script|style)\\s*>",
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    let withLineBreaks = withoutNonVisibleBlocks.replacingOccurrences(
      of: "<(?:br\\b[^>]*|/p|/div|/li|/h[1-6]|/tr|/?t[dh])\\s*>",
      with: "\n",
      options: [.regularExpression, .caseInsensitive]
    )
    let withoutTags = withLineBreaks.replacingOccurrences(
      of: "<[^>]+>", with: "", options: .regularExpression)
    return decodedHTMLEntities(in: withoutTags)
  }

}

private func decodedHTMLEntities(in value: String) -> String {
  guard
    let expression = try? NSRegularExpression(
      pattern: "&(?:#(?:x[0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"
    )
  else {
    return value
  }
  let range = NSRange(value.startIndex..., in: value)
  return expression.matches(in: value, range: range).reversed().reduce(value) { result, match in
    guard let entityRange = Range(match.range, in: result),
      let decoded = try? NSAttributedString(
        data: Data(result[entityRange].utf8),
        options: [.documentType: NSAttributedString.DocumentType.html],
        documentAttributes: nil
      ).string
    else {
      return result
    }
    return result.replacingCharacters(in: entityRange, with: decoded)
  }
}

private struct GmailMessageBodyResponse: Decodable {
  let payload: GmailMessageBodyPart
}

private struct GmailMessageBodyPart: Decodable {
  let body: GmailMessageBodyData?
  let filename: String?
  let headers: [GmailMessageBodyHeader]?
  let mimeType: String?
  let parts: [GmailMessageBodyPart]?

  var preferredBodyPart: GmailMessageBodyPart? {
    guard !isAttachment else {
      return nil
    }
    if mimeType == "text/plain", hasNonWhitespacePlainTextBodyData {
      return self
    }
    if let plainTextPart = parts?.lazy.compactMap(\.preferredNonEmptyPlainTextPart).first {
      return plainTextPart
    }
    if mimeType == "text/html", hasNonEmptyBodyData {
      return self
    }
    if let htmlPart = parts?.lazy.compactMap(\.preferredNonEmptyHTMLPart).first {
      return htmlPart
    }
    if mimeType == "text/plain", hasBodyData {
      return self
    }
    if let plainTextPart = parts?.lazy.compactMap(\.preferredPlainTextPart).first {
      return plainTextPart
    }
    if mimeType == "text/html", hasBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredHTMLPart).first
  }

  private var preferredNonEmptyPlainTextPart: GmailMessageBodyPart? {
    guard !isAttachment else {
      return nil
    }
    if mimeType == "text/plain", hasNonWhitespacePlainTextBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredNonEmptyPlainTextPart).first
  }

  private var preferredPlainTextPart: GmailMessageBodyPart? {
    guard !isAttachment else {
      return nil
    }
    if mimeType == "text/plain", hasBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredPlainTextPart).first
  }

  private var preferredHTMLPart: GmailMessageBodyPart? {
    guard !isAttachment else {
      return nil
    }
    if mimeType == "text/html", hasBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredHTMLPart).first
  }

  private var preferredNonEmptyHTMLPart: GmailMessageBodyPart? {
    guard !isAttachment else {
      return nil
    }
    if mimeType == "text/html", hasNonEmptyBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredNonEmptyHTMLPart).first
  }

  var textEncoding: String.Encoding {
    guard
      let contentType = headers?.first(where: {
        $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
      })?.value,
      let charset = contentType.split(separator: ";").first(where: {
        $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("charset=")
      })?.split(separator: "=", maxSplits: 1).last,
      CFStringConvertIANACharSetNameToEncoding(
        charset.trimmingCharacters(
          in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) as CFString
      ) != kCFStringEncodingInvalidId
    else {
      return .utf8
    }
    let encoding = CFStringConvertIANACharSetNameToEncoding(
      charset.trimmingCharacters(
        in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) as CFString
    )
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
  }

  private var isAttachment: Bool {
    guard filename?.isEmpty != false else { return true }
    return headers?.contains {
      $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame
        && $0.value.lowercased().contains("attachment")
    } == true
  }

  private var hasBodyData: Bool {
    body?.attachmentId != nil || body?.data != nil
  }

  private var hasNonEmptyBodyData: Bool {
    body?.attachmentId != nil || body?.data?.isEmpty == false
  }

  private var hasNonWhitespacePlainTextBodyData: Bool {
    guard let encodedBody = body?.data,
      let data = Data(gmailBase64URLEncoded: encodedBody),
      let text = String(data: data, encoding: textEncoding)
    else {
      return body?.attachmentId != nil
    }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

private struct GmailMessageBodyData: Decodable {
  let attachmentId: String?
  let data: String?
}

private struct GmailMessageBodyHeader: Decodable {
  let name: String
  let value: String
}

private struct GmailMessageBodyAttachment: Decodable {
  let data: String?
}

private struct GmailMessageBodyTokenResponse: Decodable {
  let accessToken: String
  let idToken: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case idToken = "id_token"
  }
}

private struct GmailMessageBodyTokenInfo: Decodable {
  private static let bodyReadableScopes: Set = [
    "https://mail.google.com/",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.readonly",
  ]

  let scope: String?
  let sub: String?

  var allowsReadingMessageBodies: Bool {
    guard let scope else { return false }
    return !Self.bodyReadableScopes.isDisjoint(with: scope.split(separator: " ").map(String.init))
  }
}

extension Data {
  fileprivate init?(gmailBase64URLEncoded value: String) {
    var base64 =
      value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    self.init(base64Encoded: base64)
  }
}
