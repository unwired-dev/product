import CryptoKit
import Foundation

// swiftlint:disable file_length type_body_length

protocol PinSyncing {
  func loadPinnedThreadIds(
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity>

  func reconcilePins(
    with messages: [MailboxMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity>

  func setPinned(
    _ isPinned: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws
}

extension PinSyncing {
  func reconcilePins(
    with _: [MailboxMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    try await loadPinnedThreadIds(session: session)
  }
}

enum PinSyncError: LocalizedError, Equatable {
  case concurrentModification
  case invalidPayload
  case missingProductSyncKeyMaterial

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Pins changed on another device. Refresh and try again."
    case .invalidPayload:
      return "A synchronized Pin could not be verified."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Pins."
    }
  }
}

private protocol PinTimestampedPayload {
  var changedAtMilliseconds: Int64 { get }
  var changedByTrustedDeviceId: String { get }
  var isPinned: Bool { get }
}

extension PinTimestampedPayload {
  func isNewer(than other: some PinTimestampedPayload) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }
}

private struct ThreadPinSyncPayload: Codable, Equatable, PinTimestampedPayload, Sendable {
  let anchorProviderMessageId: String
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let isPinned: Bool
  let provider: String
  let providerAccountIdentifier: String
  let providerThreadId: String
  let schemaVersion: Int

  init(
    anchorMessageId: StableProviderMessageIdentity,
    changedAtMilliseconds: Int64,
    changedByTrustedDeviceId: String,
    isPinned: Bool,
    threadId: StableThreadIdentity
  ) {
    anchorProviderMessageId = anchorMessageId.providerMessageId
    self.changedAtMilliseconds = changedAtMilliseconds
    self.changedByTrustedDeviceId = changedByTrustedDeviceId
    self.isPinned = isPinned
    provider = threadId.connectionId.providerId.rawValue
    providerAccountIdentifier = threadId.connectionId.providerMailboxIdentity.value
    providerThreadId = threadId.providerThreadId
    schemaVersion = 2
  }

  var threadId: StableThreadIdentity {
    StableThreadIdentity(
      connectionId: connectionId,
      providerThreadId: providerThreadId
    )
  }

  var anchorMessageId: StableProviderMessageIdentity {
    StableProviderMessageIdentity(
      connectionId: connectionId,
      providerMessageId: anchorProviderMessageId
    )
  }

  private var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }
}

private struct LegacyMessagePinSyncPayload: Codable, Equatable, PinTimestampedPayload, Sendable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let isPinned: Bool
  let provider: String
  let providerAccountIdentifier: String
  let providerMessageId: String
  let schemaVersion: Int

  init(
    changedAtMilliseconds: Int64,
    changedByTrustedDeviceId: String,
    isPinned: Bool,
    messageId: StableProviderMessageIdentity
  ) {
    self.changedAtMilliseconds = changedAtMilliseconds
    self.changedByTrustedDeviceId = changedByTrustedDeviceId
    self.isPinned = isPinned
    provider = messageId.connectionId.providerId.rawValue
    providerAccountIdentifier = messageId.connectionId.providerMailboxIdentity.value
    providerMessageId = messageId.providerMessageId
    schemaVersion = 1
  }

  var messageId: StableProviderMessageIdentity {
    StableProviderMessageIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: MailProviderId(rawValue: provider),
          value: providerAccountIdentifier
        )
      ),
      providerMessageId: providerMessageId
    )
  }
}

private struct ThreadPinRedirectPayload: Codable, Equatable, Sendable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let formerProviderThreadId: String
  let provider: String
  let providerAccountIdentifier: String
  let schemaVersion: Int
  let targetProviderThreadId: String

  init(
    changedAtMilliseconds: Int64,
    changedByTrustedDeviceId: String,
    formerThreadId: StableThreadIdentity,
    targetThreadId: StableThreadIdentity
  ) {
    self.changedAtMilliseconds = changedAtMilliseconds
    self.changedByTrustedDeviceId = changedByTrustedDeviceId
    formerProviderThreadId = formerThreadId.providerThreadId
    provider = formerThreadId.connectionId.providerId.rawValue
    providerAccountIdentifier = formerThreadId.connectionId.providerMailboxIdentity.value
    schemaVersion = 1
    targetProviderThreadId = targetThreadId.providerThreadId
  }

  var formerThreadId: StableThreadIdentity {
    StableThreadIdentity(connectionId: connectionId, providerThreadId: formerProviderThreadId)
  }

  var targetThreadId: StableThreadIdentity {
    StableThreadIdentity(connectionId: connectionId, providerThreadId: targetProviderThreadId)
  }

  func isNewer(than other: ThreadPinRedirectPayload) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }

  private var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }
}

final class PinSyncService: PinSyncing {
  static let legacyPayloadIdentifierPrefix = "pin-v1-"
  static let payloadIdentifierPrefix = "thread-pin-v2-"
  static let redirectPayloadIdentifierPrefix = "thread-pin-redirect-v1-"

  private let lastChangeLock = NSLock()
  private let legacyRecords: ProductSyncRecordFamilyHandle<String, LegacyMessagePinSyncPayload>
  private let nowMilliseconds: @Sendable () -> Int64
  private let records: ProductSyncRecordFamilyHandle<String, ThreadPinSyncPayload>
  private let redirectRecords: ProductSyncRecordFamilyHandle<String, ThreadPinRedirectPayload>
  private var lastChangeAtMilliseconds: Int64 = 0

  init(
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    },
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    self.nowMilliseconds = nowMilliseconds
    records = recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, ThreadPinSyncPayload>(
        identifier: { $0 },
        identifierPrefix: Self.payloadIdentifierPrefix,
        recordId: { identifier in
          identifier.hasPrefix(Self.payloadIdentifierPrefix) ? identifier : nil
        },
        cachePolicy: .authoritative
      )
    )
    legacyRecords = recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, LegacyMessagePinSyncPayload>(
        identifier: { $0 },
        identifierPrefix: Self.legacyPayloadIdentifierPrefix,
        recordId: { identifier in
          identifier.hasPrefix(Self.legacyPayloadIdentifierPrefix) ? identifier : nil
        },
        cachePolicy: .authoritative
      )
    )
    redirectRecords = recordBoundary.family(
      ProductSyncRecordFamilyDefinition<String, ThreadPinRedirectPayload>(
        identifier: { $0 },
        identifierPrefix: Self.redirectPayloadIdentifierPrefix,
        recordId: { identifier in
          identifier.hasPrefix(Self.redirectPayloadIdentifierPrefix) ? identifier : nil
        },
        cachePolicy: .authoritative
      )
    )
  }

  func loadPinnedThreadIds(
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    do {
      return try await loadThreadRecords(session: session).values.reduce(into: []) {
        if $1.isPinned { $0.insert($1.threadId) }
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  // swiftlint:disable:next function_body_length
  func reconcilePins(
    with messages: [MailboxMessageMetadata],
    session: ProductAccountSessionSnapshot
  ) async throws -> Set<StableThreadIdentity> {
    let currentThreadByMessageId = Dictionary(
      messages.map { ($0.id, $0.threadIdentity) },
      uniquingKeysWith: { first, _ in first }
    )
    do {
      var threadRecords = try await loadThreadRecords(session: session)
      let legacy = try await loadLegacyRecords(session: session)
      var redirects = try await loadRedirectRecords(session: session)

      for (_, payload) in legacy {
        guard let currentTarget = currentThreadByMessageId[payload.messageId] else { continue }
        let target = try resolveRedirect(for: currentTarget, redirects: redirects)
        let targetIdentifier = Self.payloadIdentifier(for: target)
        if threadRecords[targetIdentifier].map({ payload.isNewer(than: $0) }) ?? true {
          let migrated = try await writeThreadPin(
            ThreadPinSyncPayload(
              anchorMessageId: payload.messageId,
              changedAtMilliseconds: payload.changedAtMilliseconds,
              changedByTrustedDeviceId: payload.changedByTrustedDeviceId,
              isPinned: payload.isPinned,
              threadId: target
            ),
            session: session
          )
          threadRecords[targetIdentifier] = migrated
        }
      }

      for (identifier, payload) in Array(threadRecords) where payload.isPinned {
        guard
          let target = currentThreadByMessageId[payload.anchorMessageId],
          target != payload.threadId
        else { continue }
        let redirectedTarget = try resolveRedirect(for: target, redirects: redirects)
        guard redirectedTarget != payload.threadId else { continue }
        let redirect = try await writeRedirect(
          formerThreadId: payload.threadId,
          targetThreadId: redirectedTarget,
          session: session
        )
        redirects[Self.redirectPayloadIdentifier(for: payload.threadId)] = redirect
        let resolvedTarget = try resolveRedirect(
          for: redirect.targetThreadId, redirects: redirects)
        let targetIdentifier = Self.payloadIdentifier(for: resolvedTarget)
        if threadRecords[targetIdentifier] == nil {
          let repaired = try await writeThreadPinIfAbsent(
            threadId: resolvedTarget,
            anchorMessageId: payload.anchorMessageId,
            session: session
          )
          threadRecords[targetIdentifier] = repaired
        }
        try await tombstoneThreadPin(identifier: identifier, session: session)
        threadRecords[identifier] = nil
      }

      return threadRecords.values.reduce(into: []) {
        if $1.isPinned { $0.insert($1.threadId) }
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func setPinned(
    _ isPinned: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard anchorMessageId.connectionId == threadId.connectionId else {
      throw PinSyncError.invalidPayload
    }
    do {
      let redirects = try await loadRedirectRecords(session: session)
      let resolvedThreadId = try resolveRedirect(for: threadId, redirects: redirects)
      let changedAtMilliseconds = nextChangeAtMilliseconds()
      let proposed = ThreadPinSyncPayload(
        anchorMessageId: anchorMessageId,
        changedAtMilliseconds: changedAtMilliseconds,
        changedByTrustedDeviceId: session.trustedDeviceId,
        isPinned: isPinned,
        threadId: resolvedThreadId
      )
      _ = try await writeThreadPin(proposed, requiringMatchingState: true, session: session)
      let legacyProposed = LegacyMessagePinSyncPayload(
        changedAtMilliseconds: changedAtMilliseconds,
        changedByTrustedDeviceId: session.trustedDeviceId,
        isPinned: isPinned,
        messageId: anchorMessageId
      )
      try await writeLegacyPin(legacyProposed, session: session)
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func loadThreadRecords(
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: ThreadPinSyncPayload] {
    try await records.list(session: session).reduce(into: [:]) { result, element in
      let (identifier, record) = element
      try validate(record.value, identifier: identifier)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      result[identifier] = record.value
    }
  }

  private func loadLegacyRecords(
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: LegacyMessagePinSyncPayload] {
    try await legacyRecords.list(session: session).reduce(into: [:]) { result, element in
      let (identifier, record) = element
      try validate(record.value, identifier: identifier)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      result[identifier] = record.value
    }
  }

  private func loadRedirectRecords(
    session: ProductAccountSessionSnapshot
  ) async throws -> [String: ThreadPinRedirectPayload] {
    try await redirectRecords.list(session: session).reduce(into: [:]) { result, element in
      let (identifier, record) = element
      try validate(record.value, identifier: identifier)
      advanceChangeClock(to: record.value.changedAtMilliseconds)
      result[identifier] = record.value
    }
  }

  private func writeThreadPin(
    _ proposed: ThreadPinSyncPayload,
    requiringMatchingState: Bool = false,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadPinSyncPayload {
    let identifier = Self.payloadIdentifier(for: proposed.threadId)
    let record = try await records.update(identifier, session: session) { currentRecord in
      guard let currentRecord else { return .write(proposed) }
      try self.validate(currentRecord.value, identifier: identifier)
      self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
      if !proposed.isNewer(than: currentRecord.value) {
        guard !requiringMatchingState || currentRecord.value.isPinned == proposed.isPinned else {
          throw PinSyncError.concurrentModification
        }
        return .acceptAuthoritative
      }
      return .write(proposed)
    }
    guard let record else { throw PinSyncError.invalidPayload }
    return record.value
  }

  private func writeLegacyPin(
    _ proposed: LegacyMessagePinSyncPayload,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let identifier = Self.legacyPayloadIdentifier(for: proposed.messageId)
    _ = try await legacyRecords.update(identifier, session: session) { currentRecord in
      if let currentRecord {
        let current = currentRecord.value
        try self.validate(current, identifier: identifier)
        self.advanceChangeClock(to: current.changedAtMilliseconds)
        if !proposed.isNewer(than: current) {
          guard current.isPinned == proposed.isPinned else {
            throw PinSyncError.concurrentModification
          }
          return .acceptAuthoritative
        }
      }
      return .write(proposed)
    }
  }

  private func writeThreadPinIfAbsent(
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadPinSyncPayload {
    let identifier = Self.payloadIdentifier(for: threadId)
    let proposed = makeThreadPayload(
      isPinned: true,
      threadId: threadId,
      anchorMessageId: anchorMessageId,
      trustedDeviceId: session.trustedDeviceId
    )
    let record = try await records.update(identifier, session: session) { currentRecord in
      guard let currentRecord else { return .write(proposed) }
      try self.validate(currentRecord.value, identifier: identifier)
      self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
      return .acceptAuthoritative
    }
    guard let record else { throw PinSyncError.invalidPayload }
    return record.value
  }

  private func tombstoneThreadPin(
    identifier: String,
    session: ProductAccountSessionSnapshot
  ) async throws {
    _ = try await records.update(identifier, session: session) { currentRecord in
      guard let currentRecord else { return .acceptAuthoritative }
      let current = currentRecord.value
      try self.validate(current, identifier: identifier)
      self.advanceChangeClock(to: current.changedAtMilliseconds)
      guard current.isPinned else { return .acceptAuthoritative }
      return .write(
        self.makeThreadPayload(
          isPinned: false,
          threadId: current.threadId,
          anchorMessageId: current.anchorMessageId,
          trustedDeviceId: session.trustedDeviceId
        )
      )
    }
  }

  private func writeRedirect(
    formerThreadId: StableThreadIdentity,
    targetThreadId: StableThreadIdentity,
    session: ProductAccountSessionSnapshot
  ) async throws -> ThreadPinRedirectPayload {
    let identifier = Self.redirectPayloadIdentifier(for: formerThreadId)
    let proposed = ThreadPinRedirectPayload(
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: session.trustedDeviceId,
      formerThreadId: formerThreadId,
      targetThreadId: targetThreadId
    )
    let record = try await redirectRecords.update(identifier, session: session) { currentRecord in
      guard let currentRecord else { return .write(proposed) }
      try self.validate(currentRecord.value, identifier: identifier)
      self.advanceChangeClock(to: currentRecord.value.changedAtMilliseconds)
      return proposed.isNewer(than: currentRecord.value)
        ? .write(proposed)
        : .acceptAuthoritative
    }
    guard let record else { throw PinSyncError.invalidPayload }
    return record.value
  }

  private func resolveRedirect(
    for threadId: StableThreadIdentity,
    redirects: [String: ThreadPinRedirectPayload]
  ) throws -> StableThreadIdentity {
    var current = threadId
    var path: [StableThreadIdentity] = []
    var pathIndexByThreadId: [StableThreadIdentity: Int] = [:]
    while let redirect = redirects[Self.redirectPayloadIdentifier(for: current)] {
      if let cycleStart = pathIndexByThreadId[current] {
        return path[cycleStart...].min { $0.rawValue < $1.rawValue } ?? current
      }
      pathIndexByThreadId[current] = path.count
      path.append(current)
      current = redirect.targetThreadId
    }
    return current
  }

  private func makeThreadPayload(
    isPinned: Bool,
    threadId: StableThreadIdentity,
    anchorMessageId: StableProviderMessageIdentity,
    trustedDeviceId: String
  ) -> ThreadPinSyncPayload {
    ThreadPinSyncPayload(
      anchorMessageId: anchorMessageId,
      changedAtMilliseconds: nextChangeAtMilliseconds(),
      changedByTrustedDeviceId: trustedDeviceId,
      isPinned: isPinned,
      threadId: threadId
    )
  }

  private func nextChangeAtMilliseconds() -> Int64 {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(nowMilliseconds(), lastChangeAtMilliseconds + 1)
    return lastChangeAtMilliseconds
  }

  private func advanceChangeClock(to changedAtMilliseconds: Int64) {
    lastChangeLock.lock()
    defer { lastChangeLock.unlock() }
    lastChangeAtMilliseconds = max(lastChangeAtMilliseconds, changedAtMilliseconds)
  }

  private func validate(_ payload: ThreadPinSyncPayload, identifier: String) throws {
    guard
      payload.schemaVersion == 2,
      payload.anchorMessageId.connectionId == payload.threadId.connectionId,
      identifier == Self.payloadIdentifier(for: payload.threadId)
    else {
      throw PinSyncError.invalidPayload
    }
  }

  private func validate(_ payload: LegacyMessagePinSyncPayload, identifier: String) throws {
    guard
      payload.schemaVersion == 1,
      identifier == Self.legacyPayloadIdentifier(for: payload.messageId)
    else {
      throw PinSyncError.invalidPayload
    }
  }

  private func validate(_ payload: ThreadPinRedirectPayload, identifier: String) throws {
    guard
      payload.schemaVersion == 1,
      payload.formerThreadId.connectionId == payload.targetThreadId.connectionId,
      payload.formerThreadId != payload.targetThreadId,
      identifier == Self.redirectPayloadIdentifier(for: payload.formerThreadId)
    else {
      throw PinSyncError.invalidPayload
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    guard let boundaryError = error as? ProductSyncRecordBoundaryError else { return error }
    switch boundaryError {
    case .missingProductSyncKeyMaterial:
      return PinSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return PinSyncError.concurrentModification
    case .incompletePagination, .invalidPayloadIdentifier:
      return PinSyncError.invalidPayload
    }
  }

  private static func payloadIdentifier(for threadId: StableThreadIdentity) -> String {
    hashedIdentifier(
      prefix: payloadIdentifierPrefix,
      components: [
        threadId.connectionId.providerId.rawValue,
        threadId.connectionId.providerMailboxIdentity.value,
        threadId.providerThreadId,
      ]
    )
  }

  private static func legacyPayloadIdentifier(
    for messageId: StableProviderMessageIdentity
  ) -> String {
    hashedIdentifier(
      prefix: legacyPayloadIdentifierPrefix,
      components: [
        messageId.connectionId.providerId.rawValue,
        messageId.connectionId.providerMailboxIdentity.value,
        messageId.providerMessageId,
      ]
    )
  }

  private static func hashedIdentifier(prefix: String, components: [String]) -> String {
    let canonicalIdentity = components.map {
      "\($0.utf8.count):\($0)"
    }.joined()
    let digest = SHA256.hash(data: Data(canonicalIdentity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return prefix + digest
  }

  private static func redirectPayloadIdentifier(for threadId: StableThreadIdentity) -> String {
    hashedIdentifier(
      prefix: redirectPayloadIdentifierPrefix,
      components: [
        threadId.connectionId.providerId.rawValue,
        threadId.connectionId.providerMailboxIdentity.value,
        threadId.providerThreadId,
      ]
    )
  }
}
