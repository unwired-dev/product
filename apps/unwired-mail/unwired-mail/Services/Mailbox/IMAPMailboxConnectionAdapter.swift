import Foundation
import SwiftData

// swiftlint:disable file_length function_parameter_count identifier_name type_body_length

enum IMAPMailboxError: LocalizedError, Equatable {
  case invalidProviderResponse
  case missingLocalAuthorization
  case missingMessage
  case unsupportedBody

  var errorDescription: String? {
    switch self {
    case .invalidProviderResponse:
      return "The IMAP server returned an invalid response."
    case .missingLocalAuthorization:
      return "Authorize this IMAP mailbox on this device before accessing mail."
    case .missingMessage:
      return "The selected IMAP message is no longer available."
    case .unsupportedBody:
      return "The IMAP server did not return a readable message body."
    }
  }
}

enum StandardsMailDeliveryError: LocalizedError, Equatable {
  case ambiguous
  case authenticationRequired
  case invalidRecipients
  case permanentlyRejected(code: Int)
  case sentCopyPending
  case transientlyRejected(code: Int?)

  var errorDescription: String? {
    switch self {
    case .ambiguous:
      "The SMTP server did not confirm whether it accepted this message."
    case .authenticationRequired:
      "The SMTP server rejected this mailbox authorization."
    case .invalidRecipients:
      "Enter a valid recipient list before sending."
    case .permanentlyRejected(let code):
      "The SMTP server rejected this message (\(code))."
    case .sentCopyPending:
      "Message delivered. Saving its copy to the Sent mailbox."
    case .transientlyRejected(let code):
      code.map { "The SMTP server temporarily rejected this message (\($0))." }
        ?? "The SMTP server is temporarily unavailable."
    }
  }
}

enum StandardsMailMoveError: LocalizedError, Equatable {
  case localRecoveryRequired

  var errorDescription: String? {
    "The server changed this message, but its local move record needs recovery before retrying."
  }
}

private actor StandardsMailIdleCoordinator {
  static let shared = StandardsMailIdleCoordinator()

  private struct Entry {
    let productAccountId: String
    let task: Task<Void, Never>
    let token: UUID
  }

  private var entries: [MailboxConnectionId: Entry] = [:]

  // swiftlint:disable:next function_body_length
  func start(
    connectionId: MailboxConnectionId,
    productAccountId: String,
    initialSession: any MailEngineSession,
    makeSession: @escaping () async throws -> any MailEngineSession
  ) {
    entries.removeValue(forKey: connectionId)?.task.cancel()
    let token = UUID()
    let task = Task {
      var reconnectAttempt = 0
      var nextSession: (any MailEngineSession)? = initialSession
      while !Task.isCancelled {
        var activeSession: (any MailEngineSession)?
        do {
          let session: any MailEngineSession
          if let nextSession {
            session = nextSession
          } else {
            session = try await makeSession()
          }
          nextSession = nil
          activeSession = session
          try await session.idle(mailbox: MailEngineMailboxIdentity("INBOX")) { _ in
            await MainActor.run {
              NotificationCenter.default.post(
                name: .standardsMailIdleDidChange,
                object: nil,
                userInfo: [
                  MailboxSyncNotificationUserInfoKey.connectionId: connectionId.rawValue,
                  MailboxSyncNotificationUserInfoKey.productAccountId: productAccountId,
                ]
              )
            }
          }
          try await Task.sleep(for: .seconds(5))
          nextSession = session
          activeSession = nil
          reconnectAttempt = 0
        } catch is CancellationError {
          await activeSession?.close()
          break
        } catch {
          await activeSession?.close()
          reconnectAttempt += 1
          let delaySeconds = min(60, 1 << min(reconnectAttempt - 1, 6))
          do {
            try await Task.sleep(for: .seconds(delaySeconds))
          } catch {
            break
          }
        }
      }
      finished(connectionId: connectionId, token: token)
    }
    entries[connectionId] = Entry(
      productAccountId: productAccountId,
      task: task,
      token: token
    )
  }

  func isRunning(connectionId: MailboxConnectionId) -> Bool {
    guard let entry = entries[connectionId] else { return false }
    return !entry.task.isCancelled
  }

  func cancel(connectionId: MailboxConnectionId) {
    entries.removeValue(forKey: connectionId)?.task.cancel()
  }

  func cancel(productAccountId: String) {
    let connectionIds = entries.compactMap { connectionId, entry in
      entry.productAccountId == productAccountId ? connectionId : nil
    }
    for connectionId in connectionIds {
      entries.removeValue(forKey: connectionId)?.task.cancel()
    }
  }

  private func finished(connectionId: MailboxConnectionId, token: UUID) {
    guard entries[connectionId]?.token == token else { return }
    entries[connectionId] = nil
  }
}

struct IMAPMailboxDescriptor: Codable, Equatable, Hashable, Sendable {
  let displayName: String
  let name: String
}

struct IMAPProviderMessage: Codable, Equatable, Sendable {
  var calendarInvitation: CalendarInvitationDescriptor? = .none
  var categoryId: String?
  var categoryIds: [String]? = .none
  let cc: String?
  let flags: [String]
  let from: String?
  var hasAttachments: Bool? = .none
  let inReplyTo: String?
  let internalDateMilliseconds: Int64
  let mailbox: String
  var providerEmailId: String?
  let providerThreadId: String?
  let references: [String]
  let replyTo: String?
  let rfcMessageId: String?
  let snippet: String
  var stableProviderIdOverride: String? = .none
  let subject: String
  let to: String?
  let uid: Int64
  let uidValidity: Int64

  var providerMessageId: String {
    if let stableProviderIdOverride,
      !stableProviderIdOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return stableProviderIdOverride
    }
    if let providerEmailId = providerEmailId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !providerEmailId.isEmpty
    {
      return "imap-email:\(providerEmailId)"
    }
    let encodedMailbox = Data(mailbox.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "imap:\(encodedMailbox):\(uidValidity):\(uid)"
  }

  func moved(
    to mailbox: MailEngineMailboxIdentity,
    uid: Int64,
    uidValidity: Int64
  ) -> IMAPProviderMessage {
    IMAPProviderMessage(
      calendarInvitation: calendarInvitation,
      categoryId: categoryId,
      categoryIds: categoryIds,
      cc: cc,
      flags: flags,
      from: from,
      hasAttachments: hasAttachments,
      inReplyTo: inReplyTo,
      internalDateMilliseconds: internalDateMilliseconds,
      mailbox: mailbox.rawValue,
      providerEmailId: providerEmailId,
      providerThreadId: providerThreadId,
      references: references,
      replyTo: replyTo,
      rfcMessageId: rfcMessageId,
      snippet: snippet,
      stableProviderIdOverride: providerMessageId,
      subject: subject,
      to: to,
      uid: uid,
      uidValidity: uidValidity
    )
  }

  func mailboxMetadata(
    connectionId: MailboxConnectionId,
    connectedAt: Int64,
    roleMappings: [CanonicalMailboxRole: String],
    resolvedThreadId: String? = nil
  ) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: categoryId,
      connectionId: connectionId,
      from: from,
      isHistorical: internalDateMilliseconds < connectedAt,
      providerInternalDateMilliseconds: internalDateMilliseconds,
      providerMessageId: providerMessageId,
      providerStateIds: providerStateIds(roleMappings: roleMappings),
      providerThreadId: resolvedThreadId ?? threadId(connectionId: connectionId),
      recipientHeaders: [to, cc].compactMap { $0 },
      replyTo: replyTo,
      rfcMessageId: rfcMessageId,
      snippet: snippet,
      subject: subject,
      categoryIds: categoryIds,
      calendarInvitation: calendarInvitation,
      hasAttachments: hasAttachments ?? false
    )
  }

  private func providerStateIds(
    roleMappings: [CanonicalMailboxRole: String]
  ) -> [String] {
    var states: Set<String> = []
    let normalizedFlags = Set(flags.map { $0.uppercased() })
    if !normalizedFlags.contains("\\SEEN") { states.insert("UNREAD") }
    if normalizedFlags.contains("\\FLAGGED") { states.insert("STARRED") }
    if normalizedFlags.contains("\\DRAFT") { states.insert("DRAFT") }

    if mailbox.caseInsensitiveCompare("INBOX") == .orderedSame {
      states.insert("INBOX")
    }
    let mappedRole = roleMappings.first { Self.mailboxNamesEqual($0.value, mailbox) }?.key
    if let mappedRole {
      states.insert(mappedRole.providerStateId)
    } else if mailbox.caseInsensitiveCompare("INBOX") != .orderedSame {
      states.insert(Self.customMailboxStateId(mailbox))
    }
    return states.sorted()
  }

  private func threadId(connectionId: MailboxConnectionId) -> String {
    if let providerThreadId = providerThreadId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !providerThreadId.isEmpty
    {
      return "provider:\(providerThreadId)"
    }
    let referenceRoot = references.lazy.compactMap(Self.normalizedMessageId).first
    if let referenceRoot { return "rfc:\(referenceRoot)" }
    if let inReplyTo = Self.normalizedMessageId(inReplyTo) {
      return "rfc:\(inReplyTo)"
    }
    if let rfcMessageId = Self.normalizedMessageId(rfcMessageId) {
      return "rfc:\(rfcMessageId)"
    }
    return "message:\(connectionId.rawValue):\(providerMessageId)"
  }

  fileprivate static func normalizedMessageId(_ value: String?) -> String? {
    guard let value else { return nil }
    let expression = try? NSRegularExpression(pattern: #"<[^<>[:space:]]+>"#)
    let range = NSRange(value.startIndex..., in: value)
    guard
      let match = expression?.firstMatch(in: value, range: range),
      let matchRange = Range(match.range, in: value)
    else { return nil }
    return value[matchRange].lowercased()
  }

  static func customMailboxStateId(_ mailbox: String) -> String {
    let encodedMailbox = Data(mailbox.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "imap-mailbox:\(encodedMailbox)"
  }

  static func mailboxNamesEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs
      || (lhs.caseInsensitiveCompare("INBOX") == .orderedSame
        && rhs.caseInsensitiveCompare("INBOX") == .orderedSame)
  }
}

extension CanonicalMailboxRole {
  fileprivate var providerStateId: String {
    switch self {
    case .archive:
      return "ARCHIVE"
    case .drafts:
      return "DRAFT"
    case .sent:
      return "SENT"
    case .spam:
      return "SPAM"
    case .trash:
      return "TRASH"
    }
  }
}

struct IMAPMetadataPage: Equatable, Sendable {
  let messages: [IMAPProviderMessage]
  let nextOlderUID: Int64?
  let uidValidity: Int64
}

protocol IMAPMailboxClient {
  func connect(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  )

  /// Returns a non-pooled session that the caller exclusively owns and must close.
  func connectFresh(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  )

  func invalidate(
    connectionId: MailboxConnectionId
  ) async

  func listMailboxes(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> [IMAPMailboxDescriptor]

  func loadMetadataPage(
    mailbox: IMAPMailboxDescriptor,
    beforeUID: Int64?,
    limit: Int,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> IMAPMetadataPage

  func loadTextBody(
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> String

  func loadRawMessage(
    message: IMAPProviderMessage,
    maximumByteCount: Int,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> Data

  func loadCalendarInvitation(
    _ invitation: CalendarInvitationDescriptor,
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> Data
}

extension IMAPMailboxClient {
  func loadRawMessage(
    message _: IMAPProviderMessage,
    maximumByteCount _: Int,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    throw MailEngineError.operationUnsupported
  }

  func connect(
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    throw MailEngineError.operationUnsupported
  }

  func connectFresh(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    try await connect(authorization: authorization)
  }

  func invalidate(connectionId _: MailboxConnectionId) async {}

  func loadCalendarInvitation(
    _: CalendarInvitationDescriptor,
    message _: IMAPProviderMessage,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    throw MailEngineError.operationUnsupported
  }
}

struct IMAPMailboxBackfillState: Codable, Equatable, Sendable {
  var descriptor: IMAPMailboxDescriptor
  var nextOlderUID: Int64?
  var uidValidity: Int64

  var isComplete: Bool { nextOlderUID == nil }
}

struct IMAPMetadataSyncState: Codable, Equatable, Sendable {
  var hasInitialMailboxAvailability: Bool
  var mailboxes: [IMAPMailboxBackfillState]
  let scanId: String

  var historicalMetadataBackfillIsComplete: Bool {
    hasInitialMailboxAvailability && mailboxes.allSatisfy(\.isComplete)
  }
}

struct IMAPPendingMoveContinuation: Equatable, Sendable {
  let mapping: MailEngineUIDMapping
  let sourceDeletionRequired: Bool
}

protocol IMAPMessageMetadataPersisting {
  func beginScan(
    activeMailboxes: Set<String>,
    state: IMAPMetadataSyncState,
    markExistingRecords: Bool,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws

  func clear(productAccountId: String) throws

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws

  func finishScan(
    state: IMAPMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws

  func loadMessages(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [IMAPProviderMessage]

  func loadProviderMessage(
    stableProviderMessageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPProviderMessage?

  func loadPendingMove(
    sourceMessages: [IMAPProviderMessage],
    destinationMailbox: MailEngineMailboxIdentity,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPPendingMoveContinuation?

  func loadState(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPMetadataSyncState?

  func savePage(
    _ messages: [IMAPProviderMessage],
    mailbox: String,
    reconciliation: IMAPPageReconciliation,
    state: IMAPMetadataSyncState,
    uidValidity: Int64,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws

  func savePendingMove(
    _ mapping: MailEngineUIDMapping,
    sourceDeletionRequired: Bool,
    sourceMessages: [IMAPProviderMessage],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws

  func saveState(
    _ state: IMAPMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws

  func updateCategory(
    _ categoryId: String,
    stableProviderMessageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPProviderMessage

  func finishMove(
    _ mapping: MailEngineUIDMapping,
    sourceMessages: [IMAPProviderMessage],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
}

enum IMAPPageReconciliation {
  case backfill
  case newest(coversEntireMailbox: Bool)
}

@Model
final class DurableIMAPMessageMetadataRecord {
  var connectionIdRawValue: String
  var encodedMessage: Data
  var mailbox: String
  var pendingRemovalScanId: String?
  var productAccountId: String
  @Attribute(.unique) var storageKey: String
  var stableProviderMessageId: String
  var uidValidity: Int64

  init(
    connectionIdRawValue: String,
    encodedMessage: Data,
    mailbox: String,
    productAccountId: String,
    stableProviderMessageId: String,
    storageKey: String,
    uidValidity: Int64
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedMessage = encodedMessage
    self.mailbox = mailbox
    self.productAccountId = productAccountId
    self.stableProviderMessageId = stableProviderMessageId
    self.storageKey = storageKey
    self.uidValidity = uidValidity
    pendingRemovalScanId = nil
  }

  func message() throws -> IMAPProviderMessage {
    try JSONDecoder().decode(IMAPProviderMessage.self, from: encodedMessage)
  }
}

@Model
final class IMAPMetadataSyncCheckpointRecord {
  var connectionIdRawValue: String
  var encodedState: Data
  var productAccountId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    encodedState: Data,
    productAccountId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedState = encodedState
    self.productAccountId = productAccountId
    self.storageKey = storageKey
  }

  func state() throws -> IMAPMetadataSyncState {
    try JSONDecoder().decode(IMAPMetadataSyncState.self, from: encodedState)
  }
}

private struct IMAPPendingMoveState: Codable {
  let mapping: MailEngineUIDMapping
  let sourceDeletionRequired: Bool
  let sourceProviderMessageIdsByUID: [Int64: String]

  init(
    mapping: MailEngineUIDMapping,
    sourceDeletionRequired: Bool,
    sourceProviderMessageIdsByUID: [Int64: String]
  ) {
    self.mapping = mapping
    self.sourceDeletionRequired = sourceDeletionRequired
    self.sourceProviderMessageIdsByUID = sourceProviderMessageIdsByUID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mapping = try container.decode(MailEngineUIDMapping.self, forKey: .mapping)
    sourceDeletionRequired =
      try container.decodeIfPresent(Bool.self, forKey: .sourceDeletionRequired) ?? true
    sourceProviderMessageIdsByUID = try container.decode(
      [Int64: String].self,
      forKey: .sourceProviderMessageIdsByUID
    )
  }
}

@Model
final class IMAPPendingMoveRecord {
  var connectionIdRawValue: String
  var encodedState: Data
  var productAccountId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    encodedState: Data,
    productAccountId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedState = encodedState
    self.productAccountId = productAccountId
    self.storageKey = storageKey
  }

  fileprivate func state() throws -> IMAPPendingMoveState {
    try JSONDecoder().decode(IMAPPendingMoveState.self, from: encodedState)
  }
}

struct SwiftDataIMAPMessageMetadataStore: IMAPMessageMetadataPersisting {
  private let containerResult: Result<ModelContainer, Error>

  init(container: ModelContainer? = nil) {
    containerResult = Result {
      if let container { return container }
      let schema = Self.schema
      let configuration = ModelConfiguration("IMAPMetadata", schema: schema)
      return try ModelContainer(for: schema, configurations: [configuration])
    }
  }

  static func inMemory() throws -> SwiftDataIMAPMessageMetadataStore {
    let schema = Self.schema
    let configuration = ModelConfiguration(
      "IMAPMetadataTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    return SwiftDataIMAPMessageMetadataStore(
      container: try ModelContainer(for: schema, configurations: [configuration])
    )
  }

  func beginScan(
    activeMailboxes: Set<String>,
    state: IMAPMetadataSyncState,
    markExistingRecords: Bool = true,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    for record in try fetchRecords(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      if !activeMailboxes.contains(where: {
        IMAPProviderMessage.mailboxNamesEqual($0, record.mailbox)
      }) {
        context.delete(record)
      } else if markExistingRecords, !state.historicalMetadataBackfillIsComplete {
        record.pendingRemovalScanId = state.scanId
      }
    }
    try save(
      state: state, productAccountId: productAccountId, connectionId: connectionId, context: context
    )
    try context.save()
  }

  func clear(productAccountId: String) throws {
    let context = try makeContext()
    let records = try context.fetch(
      FetchDescriptor<DurableIMAPMessageMetadataRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    for record in records { context.delete(record) }
    let checkpoints = try context.fetch(
      FetchDescriptor<IMAPMetadataSyncCheckpointRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    for checkpoint in checkpoints { context.delete(checkpoint) }
    let pendingMoves = try context.fetch(
      FetchDescriptor<IMAPPendingMoveRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    for pendingMove in pendingMoves { context.delete(pendingMove) }
    try context.save()
  }

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    for record in try fetchRecords(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      context.delete(record)
    }
    if let checkpoint = try fetchCheckpoint(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      context.delete(checkpoint)
    }
    for pendingMove in try fetchPendingMoves(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      context.delete(pendingMove)
    }
    try context.save()
  }

  func finishScan(
    state: IMAPMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    for record in try fetchRecords(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) where record.pendingRemovalScanId == state.scanId {
      context.delete(record)
    }
    try save(
      state: state, productAccountId: productAccountId, connectionId: connectionId, context: context
    )
    try context.save()
  }

  func loadMessages(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [IMAPProviderMessage] {
    try fetchRecords(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: makeContext()
    )
    .map { try $0.message() }
    .sorted(by: Self.messagesAreOrdered)
  }

  func loadProviderMessage(
    stableProviderMessageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPProviderMessage? {
    let context = try makeContext()
    let connectionIdRawValue = connectionId.rawValue
    var descriptor = FetchDescriptor<DurableIMAPMessageMetadataRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
          && $0.stableProviderMessageId == stableProviderMessageId
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first.map { try $0.message() }
  }

  func loadPendingMove(
    sourceMessages: [IMAPProviderMessage],
    destinationMailbox: MailEngineMailboxIdentity,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPPendingMoveContinuation? {
    guard let source = Self.moveSource(sourceMessages) else { return nil }
    let storageKey = Self.pendingMoveStorageKey(
      productAccountId: productAccountId,
      connectionId: connectionId,
      sourceMailbox: source.mailbox,
      sourceUIDValidity: source.uidValidity,
      sourceUIDs: sourceMessages.map(\.uid),
      destinationMailbox: destinationMailbox
    )
    let context = try makeContext()
    var descriptor = FetchDescriptor<IMAPPendingMoveRecord>(
      predicate: #Predicate { $0.storageKey == storageKey }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first.map {
      let state = try $0.state()
      return IMAPPendingMoveContinuation(
        mapping: state.mapping,
        sourceDeletionRequired: state.sourceDeletionRequired
      )
    }
  }

  func loadState(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPMetadataSyncState? {
    let context = try makeContext()
    return try fetchCheckpoint(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    )?.state()
  }

  // swiftlint:disable:next function_body_length
  func savePage(
    _ messages: [IMAPProviderMessage],
    mailbox: String,
    reconciliation: IMAPPageReconciliation,
    state: IMAPMetadataSyncState,
    uidValidity: Int64,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    let connectionRecords = try fetchRecords(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    )
    let existingRecords = connectionRecords.filter {
      IMAPProviderMessage.mailboxNamesEqual($0.mailbox, mailbox)
    }
    for record in existingRecords where record.uidValidity != uidValidity {
      context.delete(record)
    }
    let matchingRecords = existingRecords.filter { $0.uidValidity == uidValidity }
    let existingById = Dictionary(
      matchingRecords.map { ($0.stableProviderMessageId, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let priorCategoriesById = Dictionary(
      try connectionRecords.map { try ($0.stableProviderMessageId, $0.message().categoryId) },
      uniquingKeysWith: { first, _ in first }
    )
    let existingOverridesByUID = Dictionary(
      try matchingRecords.compactMap {
        let message = try $0.message()
        return message.stableProviderIdOverride.map { (message.uid, $0) }
      },
      uniquingKeysWith: { first, _ in first }
    )
    let pendingMoveStates = try fetchPendingMoves(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ).map { try $0.state() }
    let normalizedMessages = messages.map { incoming in
      var message = incoming
      if let existingOverride = existingOverridesByUID[message.uid] {
        message.stableProviderIdOverride = existingOverride
        return message
      }
      for pending in pendingMoveStates
      where
        IMAPProviderMessage.mailboxNamesEqual(
          pending.mapping.destinationMailbox.rawValue,
          mailbox
        ) && pending.mapping.destinationUIDValidity == uidValidity
      {
        guard
          let pair = pending.mapping.pairs.first(where: { $0.destinationUID == message.uid }),
          let sourceProviderMessageId = pending.sourceProviderMessageIdsByUID[pair.sourceUID]
        else { continue }
        message.stableProviderIdOverride = sourceProviderMessageId
        break
      }
      return message
    }
    if case .newest(let coversEntireMailbox) = reconciliation {
      let incomingIds = Set(normalizedMessages.map(\.providerMessageId))
      let oldestFetchedUID = normalizedMessages.map(\.uid).min()
      for record in matchingRecords {
        let existingMessage = try record.message()
        if !incomingIds.contains(existingMessage.providerMessageId),
          coversEntireMailbox || oldestFetchedUID.map({ existingMessage.uid >= $0 }) == true
        {
          context.delete(record)
        }
      }
    }
    for var message in normalizedMessages {
      let stableId = StableProviderMessageIdentity(
        connectionId: connectionId,
        providerMessageId: message.providerMessageId
      ).rawValue
      if let existing = existingById[stableId] {
        let existingMessage = try existing.message()
        message.categoryId = existingMessage.categoryId
        message.calendarInvitation = message.calendarInvitation?.preservingDismissalIdentifier(
          from: existingMessage.calendarInvitation
        )
        existing.encodedMessage = try JSONEncoder().encode(message)
        existing.pendingRemovalScanId = nil
      } else {
        message.categoryId = priorCategoriesById[stableId] ?? nil
        context.insert(
          DurableIMAPMessageMetadataRecord(
            connectionIdRawValue: connectionId.rawValue,
            encodedMessage: try JSONEncoder().encode(message),
            mailbox: mailbox,
            productAccountId: productAccountId,
            stableProviderMessageId: stableId,
            storageKey: Self.messageStorageKey(
              productAccountId: productAccountId,
              connectionId: connectionId,
              mailbox: mailbox,
              uidValidity: uidValidity,
              uid: message.uid
            ),
            uidValidity: uidValidity
          )
        )
      }
    }
    try save(
      state: state, productAccountId: productAccountId, connectionId: connectionId, context: context
    )
    try context.save()
  }

  func savePendingMove(
    _ mapping: MailEngineUIDMapping,
    sourceDeletionRequired: Bool,
    sourceMessages: [IMAPProviderMessage],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    guard let source = Self.moveSource(sourceMessages) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    let context = try makeContext()
    let storageKey = Self.pendingMoveStorageKey(
      productAccountId: productAccountId,
      connectionId: connectionId,
      sourceMailbox: source.mailbox,
      sourceUIDValidity: source.uidValidity,
      sourceUIDs: sourceMessages.map(\.uid),
      destinationMailbox: mapping.destinationMailbox
    )
    let state = IMAPPendingMoveState(
      mapping: mapping,
      sourceDeletionRequired: sourceDeletionRequired,
      sourceProviderMessageIdsByUID: Dictionary(
        sourceMessages.map { ($0.uid, $0.providerMessageId) },
        uniquingKeysWith: { first, _ in first }
      )
    )
    let encodedState = try JSONEncoder().encode(state)
    var descriptor = FetchDescriptor<IMAPPendingMoveRecord>(
      predicate: #Predicate { $0.storageKey == storageKey }
    )
    descriptor.fetchLimit = 1
    if let existing = try context.fetch(descriptor).first {
      existing.encodedState = encodedState
    } else {
      context.insert(
        IMAPPendingMoveRecord(
          connectionIdRawValue: connectionId.rawValue,
          encodedState: encodedState,
          productAccountId: productAccountId,
          storageKey: storageKey
        )
      )
    }
    try context.save()
  }

  func saveState(
    _ state: IMAPMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    try save(
      state: state,
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    )
    try context.save()
  }

  func updateCategory(
    _ categoryId: String,
    stableProviderMessageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> IMAPProviderMessage {
    let context = try makeContext()
    let connectionIdRawValue = connectionId.rawValue
    let descriptor = FetchDescriptor<DurableIMAPMessageMetadataRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
          && $0.stableProviderMessageId == stableProviderMessageId
      }
    )
    let records = try context.fetch(descriptor)
    guard let firstRecord = records.first else {
      throw IMAPMailboxError.missingMessage
    }
    var firstMessage = try firstRecord.message()
    firstMessage.categoryId = categoryId
    for record in records {
      var message = try record.message()
      message.categoryId = categoryId
      record.encodedMessage = try JSONEncoder().encode(message)
    }
    try context.save()
    return firstMessage
  }

  // swiftlint:disable:next function_body_length
  func finishMove(
    _ mapping: MailEngineUIDMapping,
    sourceMessages: [IMAPProviderMessage],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    guard let source = Self.moveSource(sourceMessages) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    let context = try makeContext()
    let records = try fetchRecords(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    )
    var destinationUIDBySourceUID: [Int64: Int64] = [:]
    for pair in mapping.pairs {
      guard
        destinationUIDBySourceUID.updateValue(pair.destinationUID, forKey: pair.sourceUID) == nil
      else { throw IMAPMailboxError.invalidProviderResponse }
    }
    for sourceMessage in sourceMessages {
      guard let destinationUID = destinationUIDBySourceUID[sourceMessage.uid] else {
        throw IMAPMailboxError.invalidProviderResponse
      }
      let moved = sourceMessage.moved(
        to: mapping.destinationMailbox,
        uid: destinationUID,
        uidValidity: mapping.destinationUIDValidity
      )
      let destinationStorageKey = Self.messageStorageKey(
        productAccountId: productAccountId,
        connectionId: connectionId,
        mailbox: mapping.destinationMailbox.rawValue,
        uidValidity: mapping.destinationUIDValidity,
        uid: destinationUID
      )
      let stableId = StableProviderMessageIdentity(
        connectionId: connectionId,
        providerMessageId: moved.providerMessageId
      ).rawValue
      if let destination = records.first(where: { $0.storageKey == destinationStorageKey }) {
        destination.encodedMessage = try JSONEncoder().encode(moved)
        destination.mailbox = mapping.destinationMailbox.rawValue
        destination.pendingRemovalScanId = nil
        destination.stableProviderMessageId = stableId
        destination.uidValidity = mapping.destinationUIDValidity
      } else {
        context.insert(
          DurableIMAPMessageMetadataRecord(
            connectionIdRawValue: connectionId.rawValue,
            encodedMessage: try JSONEncoder().encode(moved),
            mailbox: mapping.destinationMailbox.rawValue,
            productAccountId: productAccountId,
            stableProviderMessageId: stableId,
            storageKey: destinationStorageKey,
            uidValidity: mapping.destinationUIDValidity
          )
        )
      }
      if let sourceRecord = records.first(where: {
        IMAPProviderMessage.mailboxNamesEqual($0.mailbox, source.mailbox)
          && $0.uidValidity == source.uidValidity
          && (try? $0.message().uid) == sourceMessage.uid
      }) {
        context.delete(sourceRecord)
      }
    }
    let pendingStorageKey = Self.pendingMoveStorageKey(
      productAccountId: productAccountId,
      connectionId: connectionId,
      sourceMailbox: source.mailbox,
      sourceUIDValidity: source.uidValidity,
      sourceUIDs: sourceMessages.map(\.uid),
      destinationMailbox: mapping.destinationMailbox
    )
    var descriptor = FetchDescriptor<IMAPPendingMoveRecord>(
      predicate: #Predicate { $0.storageKey == pendingStorageKey }
    )
    descriptor.fetchLimit = 1
    if let pending = try context.fetch(descriptor).first { context.delete(pending) }
    try context.save()
  }

  static let schema = Schema([
    DurableIMAPMessageMetadataRecord.self,
    IMAPMetadataSyncCheckpointRecord.self,
    IMAPPendingMoveRecord.self,
  ])

  private func makeContext() throws -> ModelContext {
    try ModelContext(containerResult.get())
  }

  private func fetchCheckpoint(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> IMAPMetadataSyncCheckpointRecord? {
    let connectionIdRawValue = connectionId.rawValue
    var descriptor = FetchDescriptor<IMAPMetadataSyncCheckpointRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func fetchRecords(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    mailbox: String? = nil,
    context: ModelContext
  ) throws -> [DurableIMAPMessageMetadataRecord] {
    let connectionIdRawValue = connectionId.rawValue
    var descriptor = FetchDescriptor<DurableIMAPMessageMetadataRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
      }
    )
    if let mailbox {
      descriptor.predicate = #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
          && $0.mailbox == mailbox
      }
    }
    return try context.fetch(descriptor)
  }

  private func fetchPendingMoves(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> [IMAPPendingMoveRecord] {
    let connectionIdRawValue = connectionId.rawValue
    return try context.fetch(
      FetchDescriptor<IMAPPendingMoveRecord>(
        predicate: #Predicate {
          $0.productAccountId == productAccountId
            && $0.connectionIdRawValue == connectionIdRawValue
        }
      )
    )
  }

  private func save(
    state: IMAPMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws {
    let encodedState = try JSONEncoder().encode(state)
    if let checkpoint = try fetchCheckpoint(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      checkpoint.encodedState = encodedState
    } else {
      context.insert(
        IMAPMetadataSyncCheckpointRecord(
          connectionIdRawValue: connectionId.rawValue,
          encodedState: encodedState,
          productAccountId: productAccountId,
          storageKey: Self.checkpointStorageKey(
            productAccountId: productAccountId,
            connectionId: connectionId
          )
        )
      )
    }
  }

  private static func messageStorageKey(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    mailbox: String,
    uidValidity: Int64,
    uid: Int64
  ) -> String {
    return gmailSafeFileComponent(
      "\(productAccountId)\0\(connectionId.rawValue)\0\(mailbox)\0\(uidValidity)\0\(uid)"
    )
  }

  private static func moveSource(
    _ messages: [IMAPProviderMessage]
  ) -> (mailbox: String, uidValidity: Int64)? {
    guard let first = messages.first,
      messages.allSatisfy({
        IMAPProviderMessage.mailboxNamesEqual($0.mailbox, first.mailbox)
          && $0.uidValidity == first.uidValidity
      })
    else { return nil }
    return (first.mailbox, first.uidValidity)
  }

  private static func pendingMoveStorageKey(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    sourceMailbox: String,
    sourceUIDValidity: Int64,
    sourceUIDs: [Int64],
    destinationMailbox: MailEngineMailboxIdentity
  ) -> String {
    let normalizedSourceMailbox =
      sourceMailbox.caseInsensitiveCompare("INBOX") == .orderedSame ? "INBOX" : sourceMailbox
    return gmailSafeFileComponent(
      [
        productAccountId,
        connectionId.rawValue,
        normalizedSourceMailbox,
        String(sourceUIDValidity),
        sourceUIDs.sorted().map(String.init).joined(separator: ","),
        destinationMailbox.rawValue,
      ].joined(separator: "\0")
    )
  }

  private static func checkpointStorageKey(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> String {
    gmailSafeFileComponent("\(productAccountId)\0\(connectionId.rawValue)")
  }

  private static func messagesAreOrdered(
    _ first: IMAPProviderMessage,
    _ second: IMAPProviderMessage
  ) -> Bool {
    if first.internalDateMilliseconds == second.internalDateMilliseconds {
      return first.providerMessageId < second.providerMessageId
    }
    return first.internalDateMilliseconds > second.internalDateMilliseconds
  }
}

struct IMAPMessageMetadataService {
  static let initialPageSize = 50

  private let client: IMAPMailboxClient
  private let store: IMAPMessageMetadataPersisting

  init(
    client: IMAPMailboxClient = SwiftMailMailboxClient(),
    store: IMAPMessageMetadataPersisting = SwiftDataIMAPMessageMetadataStore()
  ) {
    self.client = client
    self.store = store
  }

  func load(
    definition: GenericMailConnectionDefinition,
    connectedAt: Int64,
    productAccountId: String
  ) throws -> MailboxMetadataSyncResult {
    let connectionId = definition.connectionId
    let state = try store.loadState(
      productAccountId: productAccountId,
      connectionId: connectionId
    )
    let storedMessages = try store.loadMessages(
      productAccountId: productAccountId,
      connectionId: connectionId
    )
    let allMessages = mergedMetadata(
      storedMessages,
      connectionId: connectionId,
      connectedAt: connectedAt,
      roleMappings: definition.roleMappings
    )
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: allMessages,
      newMessageIds: nil,
      providerCursorIsExpired: false,
      threads: MailboxThread.group(allMessages),
      hasInitialMailboxAvailability: state?.hasInitialMailboxAvailability ?? false,
      historicalMetadataBackfillIsComplete:
        state?.historicalMetadataBackfillIsComplete ?? false
    )
  }

  func loadProviderMailboxes(
    definition: GenericMailConnectionDefinition,
    productAccountId: String
  ) throws -> [ProviderMailbox] {
    return try store.loadState(
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )?.mailboxes.compactMap { mailbox in
      guard
        !definition.roleMappings.values.contains(where: {
          IMAPProviderMessage.mailboxNamesEqual($0, mailbox.descriptor.name)
        }), !IMAPProviderMessage.mailboxNamesEqual("INBOX", mailbox.descriptor.name)
      else { return nil }
      return ProviderMailbox(
        id: IMAPProviderMessage.customMailboxStateId(mailbox.descriptor.name),
        title: mailbox.descriptor.displayName
      )
    }.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    } ?? []
  }

  // swiftlint:disable:next function_body_length
  func sync(
    authorization: DeviceLocalGenericMailAuthorization,
    connectedAt: Int64,
    productAccountId: String
  ) async throws -> MailboxMetadataSyncResult {
    let definition = authorization.definition
    if let state = try store.loadState(
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    ), state.hasInitialMailboxAvailability {
      return try await refreshNewestPages(
        state: state,
        authorization: authorization,
        connectedAt: connectedAt,
        productAccountId: productAccountId
      )
    }
    let descriptors = try await client.listMailboxes(authorization: authorization)
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    var state = IMAPMetadataSyncState(
      hasInitialMailboxAvailability: false,
      mailboxes: [],
      scanId: UUID().uuidString
    )
    try store.beginScan(
      activeMailboxes: Set(descriptors.map(\.name)),
      state: state,
      markExistingRecords: true,
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )

    for descriptor in descriptors {
      try Task.checkCancellation()
      let page = try await client.loadMetadataPage(
        mailbox: descriptor,
        beforeUID: nil,
        limit: Self.initialPageSize,
        authorization: authorization
      )
      state.mailboxes.append(
        IMAPMailboxBackfillState(
          descriptor: descriptor,
          nextOlderUID: page.nextOlderUID,
          uidValidity: page.uidValidity
        )
      )
      try store.savePage(
        page.messages,
        mailbox: descriptor.name,
        reconciliation: .newest(coversEntireMailbox: page.nextOlderUID == nil),
        state: state,
        uidValidity: page.uidValidity,
        productAccountId: productAccountId,
        connectionId: definition.connectionId
      )
    }
    state.hasInitialMailboxAvailability = true
    if state.historicalMetadataBackfillIsComplete {
      try store.finishScan(
        state: state,
        productAccountId: productAccountId,
        connectionId: definition.connectionId
      )
    } else {
      try store.saveState(
        state,
        productAccountId: productAccountId,
        connectionId: definition.connectionId
      )
    }
    return try load(
      definition: definition,
      connectedAt: connectedAt,
      productAccountId: productAccountId
    )
  }

  // swiftlint:disable:next function_body_length
  func continueBackfill(
    authorization: DeviceLocalGenericMailAuthorization,
    connectedAt: Int64,
    productAccountId: String
  ) async throws -> MailboxMetadataSyncResult {
    let definition = authorization.definition
    guard
      var state = try store.loadState(
        productAccountId: productAccountId,
        connectionId: definition.connectionId
      ),
      state.hasInitialMailboxAvailability
    else {
      return try await sync(
        authorization: authorization,
        connectedAt: connectedAt,
        productAccountId: productAccountId
      )
    }

    for index in state.mailboxes.indices where !state.mailboxes[index].isComplete {
      while let beforeUID = state.mailboxes[index].nextOlderUID {
        try Task.checkCancellation()
        let descriptor = state.mailboxes[index].descriptor
        var page = try await client.loadMetadataPage(
          mailbox: descriptor,
          beforeUID: beforeUID,
          limit: Self.initialPageSize,
          authorization: authorization
        )
        var restartedFromNewest = false
        if page.uidValidity != state.mailboxes[index].uidValidity {
          page = try await client.loadMetadataPage(
            mailbox: descriptor,
            beforeUID: nil,
            limit: Self.initialPageSize,
            authorization: authorization
          )
          restartedFromNewest = true
        }
        state.mailboxes[index].uidValidity = page.uidValidity
        state.mailboxes[index].nextOlderUID = page.nextOlderUID
        try store.savePage(
          page.messages,
          mailbox: descriptor.name,
          reconciliation: restartedFromNewest
            ? .newest(coversEntireMailbox: page.nextOlderUID == nil) : .backfill,
          state: state,
          uidValidity: page.uidValidity,
          productAccountId: productAccountId,
          connectionId: definition.connectionId
        )
      }
    }
    try store.finishScan(
      state: state,
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )
    return try load(
      definition: definition,
      connectedAt: connectedAt,
      productAccountId: productAccountId
    )
  }

  // swiftlint:disable:next function_body_length
  private func refreshNewestPages(
    state existingState: IMAPMetadataSyncState,
    authorization: DeviceLocalGenericMailAuthorization,
    connectedAt: Int64,
    productAccountId: String
  ) async throws -> MailboxMetadataSyncResult {
    let definition = authorization.definition
    let descriptors = try await client.listMailboxes(authorization: authorization)
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    let activeNames = Set(descriptors.map(\.name))
    var state = existingState
    try store.beginScan(
      activeMailboxes: activeNames,
      state: state,
      markExistingRecords: false,
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )
    state.mailboxes.removeAll { mailbox in
      !activeNames.contains(where: {
        IMAPProviderMessage.mailboxNamesEqual($0, mailbox.descriptor.name)
      })
    }

    for descriptor in descriptors {
      try Task.checkCancellation()
      let page = try await client.loadMetadataPage(
        mailbox: descriptor,
        beforeUID: nil,
        limit: Self.initialPageSize,
        authorization: authorization
      )
      let existingIndex = state.mailboxes.firstIndex(where: {
        IMAPProviderMessage.mailboxNamesEqual($0.descriptor.name, descriptor.name)
      })
      let hadCompletedBackfill: Bool
      if let existingIndex {
        hadCompletedBackfill = state.mailboxes[existingIndex].nextOlderUID == nil
      } else {
        hadCompletedBackfill = false
      }
      if let index = existingIndex {
        state.mailboxes[index].descriptor = descriptor
        let uidValidityChanged = state.mailboxes[index].uidValidity != page.uidValidity
        state.mailboxes[index].uidValidity = page.uidValidity
        if !hadCompletedBackfill || uidValidityChanged {
          state.mailboxes[index].nextOlderUID = page.nextOlderUID
        }
      } else {
        state.mailboxes.append(
          IMAPMailboxBackfillState(
            descriptor: descriptor,
            nextOlderUID: page.nextOlderUID,
            uidValidity: page.uidValidity
          )
        )
      }
      try store.savePage(
        page.messages,
        mailbox: descriptor.name,
        reconciliation: .newest(
          coversEntireMailbox: page.nextOlderUID == nil
        ),
        state: state,
        uidValidity: page.uidValidity,
        productAccountId: productAccountId,
        connectionId: definition.connectionId
      )
    }

    if state.historicalMetadataBackfillIsComplete {
      try store.finishScan(
        state: state,
        productAccountId: productAccountId,
        connectionId: definition.connectionId
      )
    } else {
      try store.saveState(
        state,
        productAccountId: productAccountId,
        connectionId: definition.connectionId
      )
    }
    return try load(
      definition: definition,
      connectedAt: connectedAt,
      productAccountId: productAccountId
    )
  }

  // swiftlint:disable:next function_body_length
  private func mergedMetadata(
    _ storedMessages: [IMAPProviderMessage],
    connectionId: MailboxConnectionId,
    connectedAt: Int64,
    roleMappings: [CanonicalMailboxRole: String]
  ) -> [MailboxMessageMetadata] {
    let threadResolver = IMAPThreadResolver(messages: storedMessages, connectionId: connectionId)
    return Dictionary(grouping: storedMessages, by: \.providerMessageId)
      .values.compactMap { appearances in
        guard
          let representative = appearances.first(where: {
            $0.mailbox.caseInsensitiveCompare("INBOX") == .orderedSame
          }) ?? appearances.first
        else { return nil }
        var metadata = representative.mailboxMetadata(
          connectionId: connectionId,
          connectedAt: connectedAt,
          roleMappings: roleMappings,
          resolvedThreadId: threadResolver.threadId(for: representative)
        )
        metadata = MailboxMessageMetadata(
          categoryId: appearances.compactMap(\.categoryId).first ?? metadata.categoryId,
          connectionId: metadata.connectionId,
          from: metadata.from,
          isHistorical: metadata.isHistorical,
          providerInternalDateMilliseconds: metadata.providerInternalDateMilliseconds,
          providerMessageId: metadata.providerMessageId,
          providerStateIds: Set(
            appearances.flatMap { appearance in
              appearance.mailboxMetadata(
                connectionId: connectionId,
                connectedAt: connectedAt,
                roleMappings: roleMappings
              ).providerStateIds ?? []
            }
          ).sorted(),
          providerThreadId: metadata.providerThreadId,
          recipientHeaders: metadata.recipientHeaders,
          replyTo: metadata.replyTo,
          rfcMessageId: metadata.rfcMessageId,
          snippet: metadata.snippet,
          subject: metadata.subject,
          categoryIds: Array(
            Set(
              appearances.flatMap { appearance in
                [appearance.categoryId].compactMap { $0 } + (appearance.categoryIds ?? [])
              })
          ).sorted(),
          calendarInvitation: appearances.compactMap(\.calendarInvitation).first,
          hasAttachments: appearances.contains { $0.hasAttachments == true }
        )
        return metadata
      }
      .sorted {
        if $0.providerInternalDateMilliseconds == $1.providerInternalDateMilliseconds {
          return $0.providerMessageId < $1.providerMessageId
        }
        return $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
      }
  }

  func overrideCategory(
    _ categoryId: String,
    message: MailboxMessageMetadata,
    definition: GenericMailConnectionDefinition,
    connectedAt: Int64,
    productAccountId: String
  ) throws -> MailboxMessageMetadata {
    _ = try store.updateCategory(
      categoryId,
      stableProviderMessageId: message.stableProviderMessageId,
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )
    let messages = try store.loadMessages(
      productAccountId: productAccountId,
      connectionId: definition.connectionId
    )
    guard
      let updatedMessage = mergedMetadata(
        messages,
        connectionId: definition.connectionId,
        connectedAt: connectedAt,
        roleMappings: definition.roleMappings
      ).first(where: { $0.stableProviderMessageId == message.stableProviderMessageId })
    else {
      throw IMAPMailboxError.missingMessage
    }
    return updatedMessage
  }
}

private struct IMAPThreadResolver {
  private let connectionId: MailboxConnectionId
  private let parents: [String: String]

  init(messages: [IMAPProviderMessage], connectionId: MailboxConnectionId) {
    self.connectionId = connectionId
    parents = Dictionary(
      messages.compactMap { message -> (String, String)? in
        guard
          let ownId = IMAPProviderMessage.normalizedMessageId(message.rfcMessageId),
          let parentId =
            message.references.lazy.compactMap(IMAPProviderMessage.normalizedMessageId).first
            ?? IMAPProviderMessage.normalizedMessageId(message.inReplyTo),
          ownId != parentId
        else { return nil }
        return (ownId, parentId)
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  func threadId(for message: IMAPProviderMessage) -> String {
    if let providerThreadId = message.providerThreadId?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !providerThreadId.isEmpty
    {
      return "provider:\(providerThreadId)"
    }
    if let ownId = IMAPProviderMessage.normalizedMessageId(message.rfcMessageId) {
      return "rfc:\(root(of: ownId))"
    }
    if let linkedId =
      message.references.lazy.compactMap(IMAPProviderMessage.normalizedMessageId).first
      ?? IMAPProviderMessage.normalizedMessageId(message.inReplyTo)
    {
      return "rfc:\(root(of: linkedId))"
    }
    return "message:\(connectionId.rawValue):\(message.providerMessageId)"
  }

  private func root(of messageId: String) -> String {
    var current = messageId
    var visited: Set<String> = []
    while let parent = parents[current], !visited.contains(parent) {
      visited.insert(current)
      current = parent
    }
    return current
  }
}

struct IMAPMessageBodyService {
  private let cache: GmailMessageBodyCaching
  private let client: IMAPMailboxClient
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let metadataStore: IMAPMessageMetadataPersisting

  init(
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: IMAPMailboxClient = SwiftMailMailboxClient(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    metadataStore: IMAPMessageMetadataPersisting = SwiftDataIMAPMessageMetadataStore()
  ) {
    self.cache = cache
    self.client = client
    self.keyMaterialStore = keyMaterialStore
    self.metadataStore = metadataStore
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try cache.clearMessageBodies(productAccountId: session.productAccountId)
  }

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> MailboxMessageBody {
    if let cached = try loadCachedMessageBody(message: message, session: session) {
      try? cache.recordMessageBodyAccess(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId,
        accessedAt: Date()
      )
      return cached
    }
    guard
      let providerMessage = try metadataStore.loadProviderMessage(
        stableProviderMessageId: message.stableProviderMessageId,
        productAccountId: session.productAccountId,
        connectionId: message.connectionId
      )
    else { throw IMAPMailboxError.missingMessage }
    let body = try await client.loadTextBody(
      message: providerMessage,
      authorization: authorization
    )
    let material = try requiredKeyMaterial(productAccountId: session.productAccountId)
    try? cache.saveMessageBody(
      material.encryptPayload(
        Data(body.utf8),
        associatedData: associatedData(for: message.stableProviderMessageId)
      ),
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
    return MailboxMessageBody(text: body)
  }

  func loadMessageSource(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> MailboxMessageSource {
    let sourceCache = MailboxMessageSourceCache(cache: cache, keyMaterialStore: keyMaterialStore)
    if let cached = try sourceCache.load(
      stableProviderMessageId: message.stableProviderMessageId,
      session: session
    ) {
      return try .exact(cached)
    }
    guard
      let providerMessage = try metadataStore.loadProviderMessage(
        stableProviderMessageId: message.stableProviderMessageId,
        productAccountId: session.productAccountId,
        connectionId: message.connectionId
      )
    else { throw IMAPMailboxError.missingMessage }
    let data = try await client.loadRawMessage(
      message: providerMessage,
      maximumByteCount: MailboxMessageSourcePolicy.maximumByteCount,
      authorization: authorization
    )
    guard data.count <= MailboxMessageSourcePolicy.maximumByteCount else {
      throw MailboxMessageSourceError.exceedsSizeLimit
    }
    try sourceCache.save(
      data,
      stableProviderMessageId: message.stableProviderMessageId,
      session: session
    )
    return try .exact(data)
  }

  func loadCalendarInvitation(
    _ invitation: CalendarInvitationDescriptor,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    try Task.checkCancellation()
    guard invitation.byteCount <= CalendarInvitationDescriptor.maximumByteCount else {
      throw CalendarInvitationParsingError.invitationTooLarge
    }
    guard
      let providerMessage = try metadataStore.loadProviderMessage(
        stableProviderMessageId: message.stableProviderMessageId,
        productAccountId: session.productAccountId,
        connectionId: message.connectionId
      ),
      providerMessage.calendarInvitation?.stablePartSignature == invitation.stablePartSignature
    else { throw MailboxMessageAttachmentError.invalidResponse }
    let data = try await client.loadCalendarInvitation(
      invitation,
      message: providerMessage,
      authorization: authorization
    )
    guard data.count <= CalendarInvitationDescriptor.maximumByteCount else {
      throw CalendarInvitationParsingError.invitationTooLarge
    }
    try Task.checkCancellation()
    return data
  }

  // swiftlint:disable:next function_body_length
  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws {
    try Task.checkCancellation()
    let providerMessages = try metadataStore.loadMessages(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    let messagesById = Dictionary(
      providerMessages.map {
        (
          StableProviderMessageIdentity(
            connectionId: connection.id,
            providerMessageId: $0.providerMessageId
          ),
          $0
        )
      },
      uniquingKeysWith: { first, _ in first }
    )
    let plan = IMAPBodyPrefetchPlan(
      messages: providerMessages.map {
        $0.mailboxMetadata(
          connectionId: connection.id,
          connectedAt: connection.connectedAt,
          roleMappings: authorization.definition.roleMappings
        )
      },
      pinnedThreadIds: pinnedThreadIds,
      referenceDate: referenceDate
    )
    let protectedIds = Set(plan.map(\.stableProviderMessageId))
    let pinnedIds = Set(
      plan.filter { pinnedThreadIds.contains($0.threadIdentity) }.map(\.stableProviderMessageId)
    )
    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      connectionId: connection.id,
      protectedMessageIds: protectedIds,
      pinnedMessageIds: pinnedIds
    )
    let material = try requiredKeyMaterial(productAccountId: session.productAccountId)
    for message in plan {
      try Task.checkCancellation()
      guard try loadCachedMessageBody(message: message, session: session) == nil else { continue }
      guard let providerMessage = messagesById[message.id] else { continue }
      let body: String
      do {
        body = try await client.loadTextBody(
          message: providerMessage,
          authorization: authorization
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        continue
      }
      let encrypted = try material.encryptPayload(
        Data(body.utf8),
        associatedData: associatedData(for: message.stableProviderMessageId)
      )
      _ = try cache.saveMessageBody(
        GmailMessageBodyCacheWrite(
          cachedAt: Date(
            timeIntervalSince1970: TimeInterval(message.providerInternalDateMilliseconds) / 1_000
          ),
          isPinned: pinnedIds.contains(message.stableProviderMessageId),
          isProtected: true,
          payload: encrypted,
          retention: .prefetched
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    }
  }

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
    try MailboxMessageSourceCache(cache: cache, keyMaterialStore: keyMaterialStore).remove(
      stableProviderMessageId: message.stableProviderMessageId,
      session: session
    )
  }

  func loadCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws -> MailboxMessageBody? {
    guard
      let payload = try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    else { return nil }
    let material = try requiredKeyMaterial(productAccountId: session.productAccountId)
    do {
      let decrypted = try material.decryptPayload(
        payload,
        associatedData: associatedData(for: message.stableProviderMessageId)
      )
      guard let text = String(data: decrypted, encoding: .utf8) else {
        throw IMAPMailboxError.unsupportedBody
      }
      return MailboxMessageBody(text: text)
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      return nil
    }
  }

  private func requiredKeyMaterial(productAccountId: String) throws -> ProductSyncKeyMaterial {
    guard let material = try keyMaterialStore.load(productAccountId: productAccountId) else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }
    return material
  }

  private func associatedData(for stableProviderMessageId: String) -> Data {
    Data("imap-body-cache:\(stableProviderMessageId)".utf8)
  }
}

private struct IMAPBodyPrefetchPlan {
  static let maximumRecentMessageCount = 500
  static let recentInterval: TimeInterval = 30 * 24 * 60 * 60

  let messages: [MailboxMessageMetadata]

  init(
    messages: [MailboxMessageMetadata],
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date
  ) {
    let lowerBound = Int64(
      referenceDate.addingTimeInterval(-Self.recentInterval).timeIntervalSince1970 * 1_000
    )
    let upperBound = Int64(referenceDate.timeIntervalSince1970 * 1_000)
    let eligible = Dictionary(
      messages.filter { message in
        let states = Set(message.providerStateIds ?? [])
        return states.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"])
      }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let recent = eligible.values.filter { message in
      let states = Set(message.providerStateIds ?? [])
      return !states.isDisjoint(with: ["INBOX", "SENT"])
        && (lowerBound...upperBound).contains(message.providerInternalDateMilliseconds)
    }.sorted(by: Self.messagesAreOrdered).prefix(Self.maximumRecentMessageCount)
    let recentIds = Set(recent.map(\.id))
    let pinned = eligible.values.filter {
      pinnedThreadIds.contains($0.threadIdentity) && !recentIds.contains($0.id)
    }.sorted(by: Self.messagesAreOrdered)
    self.messages = Array(pinned) + Array(recent)
  }

  func map<T>(_ transform: (MailboxMessageMetadata) throws -> T) rethrows -> [T] {
    try messages.map(transform)
  }

  func filter(_ isIncluded: (MailboxMessageMetadata) throws -> Bool) rethrows
    -> [MailboxMessageMetadata]
  {
    try messages.filter(isIncluded)
  }

  func makeIterator() -> Array<MailboxMessageMetadata>.Iterator {
    messages.makeIterator()
  }

  private static func messagesAreOrdered(
    _ first: MailboxMessageMetadata,
    _ second: MailboxMessageMetadata
  ) -> Bool {
    if first.providerInternalDateMilliseconds == second.providerInternalDateMilliseconds {
      return first.stableProviderMessageId < second.stableProviderMessageId
    }
    return first.providerInternalDateMilliseconds > second.providerInternalDateMilliseconds
  }
}

extension IMAPBodyPrefetchPlan: Sequence {}

struct IMAPMailboxConnectionAdapter: MailboxConnectionAdapter, MailboxConnectionCacheLoading {
  private let attachmentStore: DownloadedAttachmentStore
  private let authorizationStore: GenericMailAuthorizationPersisting
  private let bodyReader: IMAPMessageBodyService
  private let cache: GmailMessageBodyCaching
  private let client: IMAPMailboxClient
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let messageCategorizer: GmailMessageCategorizing?
  private let metadataService: IMAPMessageMetadataService
  private let metadataStore: IMAPMessageMetadataPersisting
  private let outboxService: OutboxDeliveryService
  private let pendingActionService: PendingProviderActionService
  private let sentCopyStore: StandardsMailSentCopyPersisting
  private let syncGate: MailboxConnectionSyncGate

  init(
    attachmentStore: DownloadedAttachmentStore = DownloadedAttachmentStore(),
    authorizationStore: GenericMailAuthorizationPersisting =
      KeychainGenericMailAuthorizationStore(),
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: IMAPMailboxClient = SwiftMailMailboxClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    messageCategorizer: GmailMessageCategorizing? = nil,
    metadataStore: IMAPMessageMetadataPersisting = SwiftDataIMAPMessageMetadataStore(),
    outboxService: OutboxDeliveryService = .shared,
    pendingActionService: PendingProviderActionService = .shared,
    sentCopyStore: StandardsMailSentCopyPersisting? = nil,
    syncGate: MailboxConnectionSyncGate = .shared
  ) {
    self.attachmentStore = attachmentStore
    self.authorizationStore = authorizationStore
    self.cache = cache
    self.client = client
    self.definitionSyncService = definitionSyncService
    self.messageCategorizer = messageCategorizer
    self.metadataStore = metadataStore
    self.outboxService = outboxService
    self.pendingActionService = pendingActionService
    self.sentCopyStore =
      sentCopyStore ?? FileStandardsMailSentCopyStore(keyMaterialStore: keyMaterialStore)
    self.syncGate = syncGate
    bodyReader = IMAPMessageBodyService(
      cache: cache,
      client: client,
      keyMaterialStore: keyMaterialStore,
      metadataStore: metadataStore
    )
    metadataService = IMAPMessageMetadataService(client: client, store: metadataStore)
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    await StandardsMailIdleCoordinator.shared.cancel(productAccountId: session.productAccountId)
    var firstError: Error?
    let connectionIds: [MailboxConnectionId]
    do {
      connectionIds = try authorizationStore.connectionIds(
        productAccountId: ProductAccountId(session.productAccountId)
      )
    } catch {
      connectionIds = []
      firstError = error
    }
    for connectionId in connectionIds where connectionId.providerId == .imapSMTP {
      await client.invalidate(connectionId: connectionId)
    }
    do {
      try authorizationStore.clearAll(productAccountId: ProductAccountId(session.productAccountId))
    } catch {
      firstError = firstError ?? error
    }
    do {
      try metadataStore.clear(productAccountId: session.productAccountId)
    } catch {
      firstError = firstError ?? error
    }
    do {
      try cache.clearMessageBodies(productAccountId: session.productAccountId)
    } catch {
      firstError = firstError ?? error
    }
    do {
      try sentCopyStore.clear(productAccountId: session.productAccountId)
    } catch {
      firstError = firstError ?? error
    }
    if let firstError { throw firstError }
  }

  func rebuildLocalIndexes(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      try metadataStore.clear(productAccountId: session.productAccountId)
    }
  }

  func clearLocalMailboxData(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      var firstError: Error?
      do {
        try metadataStore.clear(productAccountId: session.productAccountId)
      } catch {
        firstError = error
      }
      do {
        try cache.clearMessageBodies(productAccountId: session.productAccountId)
      } catch {
        firstError = firstError ?? error
      }
      if let firstError { throw firstError }
    }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    try await syncGate.withLock(connection.id) {
      try await performLocalCleanupWithoutLock(connection, session: session)
    }
  }

  private func performLocalCleanupWithoutLock(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    await StandardsMailIdleCoordinator.shared.cancel(connectionId: connection.id)
    await client.invalidate(connectionId: connection.id)
    var firstError: Error?
    do {
      try clearLocalConnectionWithoutLock(connection, session: session)
    } catch {
      firstError = error
    }
    do {
      try await pendingActionService.clear(connection: connection, session: session)
    } catch {
      firstError = firstError ?? error
    }
    do {
      try await outboxService.clear(connection: connection, session: session)
    } catch {
      firstError = firstError ?? error
    }
    do {
      try sentCopyStore.clear(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    } catch {
      firstError = firstError ?? error
    }
    do {
      try attachmentStore.clear(connectionId: connection.id)
    } catch {
      firstError = firstError ?? error
    }
    if let firstError { throw firstError }
  }

  private func clearLocalConnectionWithoutLock(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try clearLocalConnectionWithoutLock(connection.id, session: session)
  }

  private func clearLocalConnectionWithoutLock(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) throws {
    try metadataStore.clear(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      connectionId: connectionId
    )
    try authorizationStore.remove(
      productAccountId: ProductAccountId(session.productAccountId),
      connectionId: connectionId
    )
  }

  @MainActor
  func connect(
    expectedConnectionId _: MailboxConnectionId?,
    removalObservation _: MailboxConnectionRemovalObservation?,
    session _: ProductAccountSessionSnapshot,
    isSessionCurrent _: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    var snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    for connectionId in snapshot.connectionIdsRequiringLocalCleanup
    where connectionId.providerId == .imapSMTP {
      snapshot = try await refreshAndClearLocalStateIfNeeded(
        connectionId,
        session: session
      )
    }
    return try snapshot.connections.compactMap { definition in
      guard
        definition.provider == MailProviderId.imapSMTP.rawValue,
        let genericDefinition = definition.genericMailDefinition,
        genericDefinition.incomingEndpoint.mailProtocol == .imap
      else { return nil }
      let authorization = try authorizationStore.load(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: definition.id
      )
      let isAuthorized =
        authorization.map {
          $0.authorizationGeneration == definition.authorizationGeneration
            && hasMatchingCredentials($0.definition, genericDefinition)
            && (!SwiftMailExperimentalBuildPolicy.isEnabled
              || $0.hasPersistedEngineCapabilities)
        } ?? false
      return MailboxConnection(
        authorizationGeneration: definition.authorizationGeneration,
        authorizationState: isAuthorized ? .authorized : .required,
        capabilities:
          isAuthorized && SwiftMailExperimentalBuildPolicy.isEnabled
          ? .standardsMail(
            engineCapabilities: authorization?.engineCapabilities ?? [],
            roleMappings: genericDefinition.roleMappings
          ) : .none,
        connectedAt: definition.connectedAt,
        displayName: definition.displayName,
        id: definition.id,
        lastVerifiedAt: isAuthorized ? definition.connectedAt : 0,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: snapshot.updatedAt ?? definition.connectedAt
      )
    }
  }

  func loadCachedConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    guard let snapshot = try await definitionSyncService.loadCachedSnapshot(session: session)
    else { return [] }
    return try snapshot.connections.compactMap { definition in
      guard
        definition.provider == MailProviderId.imapSMTP.rawValue,
        let genericDefinition = definition.genericMailDefinition,
        genericDefinition.incomingEndpoint.mailProtocol == .imap
      else { return nil }
      let authorization = try authorizationStore.load(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: definition.id
      )
      let isAuthorized =
        authorization.map {
          $0.authorizationGeneration == definition.authorizationGeneration
            && hasMatchingCredentials($0.definition, genericDefinition)
            && (!SwiftMailExperimentalBuildPolicy.isEnabled
              || $0.hasPersistedEngineCapabilities)
        } ?? false
      return MailboxConnection(
        authorizationGeneration: definition.authorizationGeneration,
        authorizationState: isAuthorized ? .authorized : .required,
        capabilities:
          isAuthorized && SwiftMailExperimentalBuildPolicy.isEnabled
          ? .standardsMail(
            engineCapabilities: authorization?.engineCapabilities ?? [],
            roleMappings: genericDefinition.roleMappings
          ) : .none,
        connectedAt: definition.connectedAt,
        displayName: definition.displayName,
        id: definition.id,
        lastVerifiedAt: isAuthorized ? definition.connectedAt : 0,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: snapshot.updatedAt ?? definition.connectedAt
      )
    }
  }

  private func refreshAndClearLocalStateIfNeeded(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot {
    try await syncGate.withLock(connectionId) {
      let currentSnapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
        session: session
      )
      let authorizationGeneration = try authorizationStore.load(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: connectionId
      )?.authorizationGeneration
      guard
        try definitionSyncService.requiresLocalCleanup(
          in: currentSnapshot,
          connectionId: connectionId,
          localAuthorizationGeneration: authorizationGeneration,
          session: session
        )
      else {
        return currentSnapshot
      }
      let removed = MailboxConnection(
        authorizationState: .required,
        capabilities: .none,
        connectedAt: 0,
        displayName: "",
        id: connectionId,
        lastVerifiedAt: 0,
        productAccountId: ProductAccountId(session.productAccountId),
        trustedDeviceId: session.trustedDeviceId,
        updatedAt: currentSnapshot.updatedAt ?? 0
      )
      try await performLocalCleanupWithoutLock(removed, session: session)
      try definitionSyncService.recordLocalCleanup(
        in: currentSnapshot,
        connectionId: connectionId,
        session: session
      )
      return currentSnapshot
    }
  }

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
      .defaultSendingConnectionId
  }

  func removeMailboxConnectionEverywhere(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await clearLocalConnection(connection, session: session)
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
  }

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    if let connection {
      try validate(connection: connection, session: session, requiresAuthorization: true)
      guard connection.capabilities.canSend else {
        throw MailboxConnectionAdapterError.unsupportedCapability
      }
    }
    _ = try await definitionSyncService.setDefaultSendingConnection(
      connection?.id,
      session: session
    )
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let definition = try await localDefinition(connection: connection, session: session)
    let result = try await categorizing(
      metadataService.load(
        definition: definition,
        connectedAt: connection.connectedAt,
        productAccountId: session.productAccountId
      ),
      connectionId: connection.id,
      session: session
    )
    return try await pendingActionService.project(
      result,
      connection: connection,
      session: session
    )
    .limitedInitialPage(to: IMAPMessageMetadataService.initialPageSize)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let definition = try await localDefinition(connection: connection, session: session)
    let categorized = try await categorizing(
      metadataService.load(
        definition: definition,
        connectedAt: connection.connectedAt,
        productAccountId: session.productAccountId
      ),
      connectionId: connection.id,
      session: session
    )
    let result = try await pendingActionService.project(
      categorized,
      collection: collection,
      connection: connection,
      session: session
    )
    return collection == .allObserved
      ? result : result.limitedInitialPage(to: IMAPMessageMetadataService.initialPageSize)
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    try metadataService.loadProviderMailboxes(
      definition: try await localDefinition(connection: connection, session: session),
      productAccountId: session.productAccountId
    )
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      let categorized = try await categorizing(
        metadataService.continueBackfill(
          authorization: authorization,
          connectedAt: connection.connectedAt,
          productAccountId: session.productAccountId
        ),
        connectionId: connection.id,
        session: session
      )
      try await reconcilePendingActions(
        categorized,
        connection: connection,
        session: session
      )
      return try await pendingActionService.project(
        categorized,
        connection: connection,
        session: session
      )
      .limitedInitialPage(to: IMAPMessageMetadataService.initialPageSize)
    }
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      let categorized = try await categorizing(
        metadataService.sync(
          authorization: authorization,
          connectedAt: connection.connectedAt,
          productAccountId: session.productAccountId
        ),
        connectionId: connection.id,
        session: session
      )
      try await reconcilePendingActions(
        categorized,
        connection: connection,
        session: session
      )
      _ = await retryPendingSentCopies(
        authorization: authorization,
        productAccountId: session.productAccountId
      )
      return try await pendingActionService.project(
        categorized,
        connection: connection,
        session: session
      )
      .limitedInitialPage(to: IMAPMessageMetadataService.initialPageSize)
    }
  }

  private func reconcilePendingActions(
    _ result: MailboxMetadataSyncResult,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let observedMessages = Dictionary(
      (result.threads.flatMap(\.messages) + result.messages).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    ).values
    try await pendingActionService.reconcileProviderSync(
      messages: Array(observedMessages),
      removesContradictedActions: result.historicalMetadataBackfillIsComplete,
      connection: connection,
      session: session
    )
  }

  private func categorizing(
    _ result: MailboxMetadataSyncResult,
    connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    guard let messageCategorizer else { return result }
    let observedMessages = Dictionary(
      (result.threads.flatMap(\.messages) + result.messages).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    ).values
    let categorizedMessages = try await messageCategorizer.categorize(
      messages: observedMessages.map(\.gmailMetadata),
      session: session
    )
    let categorizedById = Dictionary(
      categorizedMessages.map {
        let message = $0.mailboxMetadata(connectionId: connectionId)
        return (message.id, message)
      },
      uniquingKeysWith: { first, _ in first }
    )
    let messages = result.messages.map { categorizedById[$0.id] ?? $0 }
    let threads = result.threads.map { thread in
      MailboxThread(
        latestMessage: categorizedById[thread.latestMessage.id] ?? thread.latestMessage,
        messages: thread.messages.map { categorizedById[$0.id] ?? $0 },
        providerThreadId: thread.providerThreadId
      )
    }
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: result.hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: result.newMessageIds,
      providerCursorIsExpired: result.providerCursorIsExpired,
      threads: threads,
      hasInitialMailboxAvailability: result.hasInitialMailboxAvailability,
      historicalMetadataBackfillCanResume: result.historicalMetadataBackfillCanResume,
      historicalMetadataBackfillIsComplete: result.historicalMetadataBackfillIsComplete
    )
  }

  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    guard shouldPersist() else { throw CancellationError() }
    return try await syncInbox(connection: connection, session: session)
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    let connection = try await connection(
      id: message.connectionId,
      session: session
    )
    return try metadataService.overrideCategory(
      categoryId,
      message: message,
      definition: try await localDefinition(connection: connection, session: session),
      connectedAt: connection.connectedAt,
      productAccountId: session.productAccountId
    )
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    let categoryId = try singleCategoryIdentifier(categoryIds)
    return try await overrideCategory(categoryId, for: message, session: session)
  }

  func searchProvider(
    query _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try bodyReader.clearCachedMessageBodies(session: session)
  }

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    try bodyReader.clearCachedMessageBodies(connection: connection, session: session)
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    guard message.connectionId.providerId == .imapSMTP else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    let connection = try await connection(id: message.connectionId, session: session)
    return try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      if let cached = try bodyReader.loadCachedMessageBody(message: message, session: session) {
        return cached
      }
      return try await bodyReader.loadMessageBody(
        message: message,
        session: session,
        authorization: authorization
      )
    }
  }

  func loadMessageSource(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageSource {
    guard message.connectionId.providerId == .imapSMTP else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    let connection = try await connection(id: message.connectionId, session: session)
    return try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      do {
        return try await bodyReader.loadMessageSource(
          message: message,
          session: session,
          authorization: authorization
        )
      } catch MailEngineError.operationUnsupported {
        return .unavailable(for: message)
      }
    }
  }

  func loadCalendarInvitation(
    _ invitation: CalendarInvitationDescriptor,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> Data {
    guard message.connectionId.providerId == .imapSMTP else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    let connection = try await connection(id: message.connectionId, session: session)
    return try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      return try await bodyReader.loadCalendarInvitation(
        invitation,
        message: message,
        session: session,
        authorization: authorization
      )
    }
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      try await bodyReader.prefetchMessageBodies(
        connection: connection,
        pinnedThreadIds: pinnedThreadIds,
        referenceDate: referenceDate,
        session: session,
        authorization: authorization
      )
    }
  }

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    guard message.connectionId.providerId == .imapSMTP else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    try bodyReader.removeCachedMessageBody(message: message, session: session)
  }

  func registerOrRenewPush(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard await !StandardsMailIdleCoordinator.shared.isRunning(connectionId: connection.id) else {
      return
    }
    let authorization = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    let engine = try await client.connectFresh(authorization: authorization)
    guard engine.snapshot.capabilities.contains(.idle) else {
      await engine.session.close()
      throw MailboxConnectionAdapterError.unsupportedCapability
    }
    await StandardsMailIdleCoordinator.shared.start(
      connectionId: connection.id,
      productAccountId: session.productAccountId,
      initialSession: engine.session,
      makeSession: {
        try await client.connectFresh(authorization: authorization).session
      }
    )
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: nil,
      targetProviderStateIds: [],
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: [],
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let selection = try await performTracked(
      action,
      sourceProviderMailboxId: nil,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds,
      messages: messages,
      connection: connection,
      session: session
    )
    if let selection { await pendingActionService.releaseSelection(selection) }
  }

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    try await syncGate.withLock(connection.id) {
      _ = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      guard connection.capabilities.supports(action) else {
        throw MailboxConnectionAdapterError.unsupportedCapability
      }
      if action == .move, targetProviderMailboxId == nil {
        throw MailboxConnectionAdapterError.providerMailboxTargetRequired
      }
      return try await pendingActionService.enqueue(
        action,
        sourceProviderMailboxId: sourceProviderMailboxId,
        targetProviderMailboxId: targetProviderMailboxId,
        targetProviderStateIds: targetProviderStateIds,
        messages: messages,
        connection: connection,
        session: session,
        coalescesMessages: true
      )
    }
  }

  func releasePendingActionSelection(
    _ selection: MailboxProviderActionSelection,
    connection _: MailboxConnection
  ) async {
    await pendingActionService.releaseSelection(selection)
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connections: connections,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    var errors: [String] = []
    for connection in connections {
      if let error = await resumePendingActions(
        connection: connection,
        session: session,
        revalidateProviderAccess: revalidateProviderAccess
      ) {
        errors.append(error)
      }
    }
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await retryBlockedPendingAction(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    await resolveBlockedAction(
      connection: connection,
      session: session,
      discards: false,
      revalidateProviderAccess: revalidateProviderAccess
    )
  }

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedAction(
      connection: connection,
      session: session,
      discards: true,
      revalidateProviderAccess: { true }
    )
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var ids: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasBlockedAction(
        connection: connection,
        session: session
      )) == true
    {
      ids.append(connection.id)
    }
    return ids
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var ids: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasFailedAction(
        connection: connection,
        session: session
      )) == true
    {
      ids.append(connection.id)
    }
    return ids
  }

  func pendingActionFailureDetails(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    try? await pendingActionService.failureDetails(
      action,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func pendingActionFailureLookup(
    _ action: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    try? await pendingActionService.failureLookup(
      action,
      selectedActionIds: selection?.pendingActionIds,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func waitForPendingActionRetries(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    for connection in connections {
      await pendingActionService.waitForScheduledRetries(
        connection: connection,
        session: session
      )
    }
    return await resumePendingActions(connections: connections, session: session)
  }

  func waitForPendingActionRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionService.waitForScheduledRetries(
      connection: connection,
      session: session
    )
    return await resumePendingActions(connection: connection, session: session)
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    try? await pendingActionService.acknowledgeFailures(
      connection: connection,
      session: session
    )
  }

  private func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session,
        revalidateProviderAccess: revalidateProviderAccess,
        provider: pendingActionPerformer(connection: connection, session: session)
      )
      return try await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func resolveBlockedAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    discards: Bool,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    do {
      let performer = pendingActionPerformer(connection: connection, session: session)
      if discards {
        try await pendingActionService.discardBlockedAction(
          connection: connection,
          session: session,
          provider: performer
        )
      } else {
        try await pendingActionService.retryBlockedAction(
          connection: connection,
          session: session,
          revalidateProviderAccess: revalidateProviderAccess,
          provider: performer
        )
      }
      return try await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func pendingActionPerformer(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> PendingProviderActionPerformer {
    { action, _, targetProviderMailboxId, messageIds in
      try await syncGate.withLock(connection.id) {
        let authorization = try await authorizationForProviderAccess(
          connection: connection,
          session: session,
          isWithinSyncGate: true
        )
        try await performProviderAction(
          action,
          targetProviderMailboxId: targetProviderMailboxId,
          messageIds: messageIds,
          authorization: authorization,
          productAccountId: session.productAccountId
        )
      }
    }
  }

  private func performProviderAction(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messageIds: [String],
    authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: String
  ) async throws {
    let connectionId = authorization.definition.connectionId
    let storedMessages = try metadataStore.loadMessages(
      productAccountId: productAccountId,
      connectionId: connectionId
    )
    let messages = messageIds.compactMap { messageId in
      storedMessages.first { $0.providerMessageId == messageId }
    }
    guard messages.count == messageIds.count else { throw IMAPMailboxError.missingMessage }
    let engine = try await client.connect(authorization: authorization)
    let grouped = Dictionary(grouping: messages) { message in
      "\(message.mailbox)\u{0}\(message.uidValidity)"
    }

    for group in grouped.values {
      let identities = group.map {
        MailEngineMessageIdentity(
          connectionID: connectionId.rawValue,
          mailbox: MailEngineMailboxIdentity($0.mailbox),
          uid: $0.uid,
          uidValidity: $0.uidValidity
        )
      }
      switch action {
      case .markRead:
        try await engine.session.updateFlags(["\\Seen"], on: identities, mutation: .add)
      case .markUnread:
        try await engine.session.updateFlags(["\\Seen"], on: identities, mutation: .remove)
      case .star:
        try await engine.session.updateFlags(["\\Flagged"], on: identities, mutation: .add)
      case .unstar:
        try await engine.session.updateFlags(["\\Flagged"], on: identities, mutation: .remove)
      case .archive, .delete, .move, .notSpam, .restore, .spam:
        let destination = try destinationMailbox(
          for: action,
          targetProviderMailboxId: targetProviderMailboxId,
          definition: authorization.definition
        )
        if identities.first?.mailbox != destination {
          try await moveProviderMessages(
            group,
            identities: identities,
            destination: destination,
            engine: engine,
            productAccountId: productAccountId,
            connectionId: connectionId
          )
        }
      }
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  private func moveProviderMessages(
    _ messages: [IMAPProviderMessage],
    identities: [MailEngineMessageIdentity],
    destination: MailEngineMailboxIdentity,
    engine: (
      snapshot: MailEngineConnectionSnapshot,
      session: any MailEngineSession
    ),
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) async throws {
    let mapping: MailEngineUIDMapping
    if let pending = try metadataStore.loadPendingMove(
      sourceMessages: messages,
      destinationMailbox: destination,
      productAccountId: productAccountId,
      connectionId: connectionId
    ) {
      mapping = pending.mapping
      if pending.sourceDeletionRequired {
        try await engine.session.deletePermanently(identities)
      }
    } else if engine.snapshot.capabilities.contains(.move) {
      mapping = try await engine.session.move(messages: identities, to: destination)
      do {
        try metadataStore.savePendingMove(
          mapping,
          sourceDeletionRequired: false,
          sourceMessages: messages,
          productAccountId: productAccountId,
          connectionId: connectionId
        )
      } catch {
        throw StandardsMailMoveError.localRecoveryRequired
      }
    } else if engine.snapshot.capabilities.contains(.uidPlus) {
      mapping = try await engine.session.copy(messages: identities, to: destination)
      do {
        try metadataStore.savePendingMove(
          mapping,
          sourceDeletionRequired: true,
          sourceMessages: messages,
          productAccountId: productAccountId,
          connectionId: connectionId
        )
      } catch {
        throw StandardsMailMoveError.localRecoveryRequired
      }
      try await engine.session.deletePermanently(identities)
    } else {
      throw MailEngineError.operationUnsupported
    }
    do {
      try metadataStore.finishMove(
        mapping,
        sourceMessages: messages,
        productAccountId: productAccountId,
        connectionId: connectionId
      )
    } catch {
      throw StandardsMailMoveError.localRecoveryRequired
    }
  }

  private func destinationMailbox(
    for action: ProviderMailAction,
    targetProviderMailboxId: String?,
    definition: GenericMailConnectionDefinition
  ) throws -> MailEngineMailboxIdentity {
    let mailbox: String? =
      switch action {
      case .archive: definition.roleMappings[.archive]
      case .delete: definition.roleMappings[.trash]
      case .move: targetProviderMailboxId.flatMap(Self.mailboxName)
      case .notSpam, .restore: "INBOX"
      case .spam: definition.roleMappings[.spam]
      case .markRead, .markUnread, .star, .unstar: nil
      }
    guard let mailbox, !mailbox.isEmpty else {
      throw MailboxConnectionAdapterError.providerMailboxTargetRequired
    }
    return MailEngineMailboxIdentity(mailbox)
  }

  private static func mailboxName(from providerMailboxId: String) -> String? {
    if providerMailboxId.caseInsensitiveCompare("INBOX") == .orderedSame { return "INBOX" }
    let roleMappings: [String: CanonicalMailboxRole] = [
      "ARCHIVE": .archive,
      "DRAFT": .drafts,
      "SENT": .sent,
      "SPAM": .spam,
      "TRASH": .trash,
    ]
    if roleMappings[providerMailboxId.uppercased()] != nil { return nil }
    let prefix = "imap-mailbox:"
    guard providerMailboxId.hasPrefix(prefix) else { return nil }
    var encoded = String(providerMailboxId.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      guard let sentMailbox = authorization.definition.roleMappings[.sent] else {
        throw MailboxConnectionAdapterError.providerMailboxTargetRequired
      }
      let engine: (snapshot: MailEngineConnectionSnapshot, session: any MailEngineSession)
      do {
        engine = try await client.connect(authorization: authorization)
      } catch MailEngineError.authenticationRejected {
        throw StandardsMailDeliveryError.authenticationRequired
      } catch MailEngineError.connectionClosed {
        throw StandardsMailDeliveryError.transientlyRejected(code: nil)
      }
      guard let recipients = RFCMailboxHeaderParser.recipientAddresses(in: message.recipient) else {
        throw StandardsMailDeliveryError.invalidRecipients
      }
      let rfcMessageId =
        message.rfcMessageId
        ?? OutgoingMessage.rfcMessageId(
          for: "unwired-\(UUID().uuidString.lowercased())"
        )
      let rawMessage = try await engine.session.renderMessage(
        MailEngineOutgoingMessage(
          body: message.body,
          inReplyTo: message.inReplyTo,
          messageID: rfcMessageId,
          recipients: recipients,
          requestsReadReceipt: message.requestsReadReceipt == true,
          sender: authorization.definition.emailAddress,
          subject: message.subject
        )
      )
      switch try await engine.session.submit(
        envelope: MailEngineEnvelope(
          recipients: recipients,
          sender: authorization.definition.emailAddress
        ),
        rawMessage: rawMessage
      ) {
      case .accepted:
        let pendingCopy = StandardsMailPendingSentCopy(
          connectionId: connection.id,
          idempotencyKey: message.idempotencyKey ?? rfcMessageId,
          mailbox: sentMailbox,
          rawMessage: rawMessage,
          rfcMessageId: rfcMessageId
        )
        do {
          try recordPendingSentCopy(
            pendingCopy,
            productAccountId: session.productAccountId
          )
        } catch {
          throw StandardsMailDeliveryError.ambiguous
        }
        let sentCopyCompleted = await retryPendingSentCopies(
          authorization: authorization,
          productAccountId: session.productAccountId,
          engineSession: engine.session,
          targetIdempotencyKey: pendingCopy.idempotencyKey
        )
        if !sentCopyCompleted { throw StandardsMailDeliveryError.sentCopyPending }
      case .ambiguous:
        throw StandardsMailDeliveryError.ambiguous
      case .permanentlyRejected(let code):
        throw StandardsMailDeliveryError.permanentlyRejected(code: code)
      case .transientlyRejected(let code):
        throw StandardsMailDeliveryError.transientlyRejected(code: code)
      case .notSubmitted(let failure):
        throw Self.deliveryError(failure)
      }
    }
  }

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    try await syncGate.withLock(connection.id) {
      let authorization = try await authorizationForProviderAccess(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      guard let sentMailbox = authorization.definition.roleMappings[.sent] else {
        return .unknown
      }
      let engine = try await client.connect(authorization: authorization)
      let pendingCopies = try sentCopyStore.load(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      if pendingCopies.contains(where: { $0.idempotencyKey == idempotencyKey }) {
        _ = await retryPendingSentCopies(
          authorization: authorization,
          productAccountId: session.productAccountId,
          engineSession: engine.session
        )
        let remainingCopies = try sentCopyStore.load(
          productAccountId: session.productAccountId,
          connectionId: connection.id
        )
        return remainingCopies.contains(where: { $0.idempotencyKey == idempotencyKey })
          ? .sentCopyPending : .sent
      }
      return try await engine.session.containsMessage(
        rfcMessageID: OutgoingMessage.rfcMessageId(for: idempotencyKey),
        mailbox: MailEngineMailboxIdentity(sentMailbox)
      ) ? .sent : .unknown
    }
  }

  private static func deliveryError(
    _ failure: MailEnginePreSubmissionFailure
  ) -> StandardsMailDeliveryError {
    switch failure {
    case .authentication:
      .authenticationRequired
    case .transportUnavailable:
      .transientlyRejected(code: nil)
    case .dataRejected(let code), .recipientRejected(let code), .senderRejected(let code):
      if (400...499).contains(code) {
        .transientlyRejected(code: code)
      } else {
        .permanentlyRejected(code: code)
      }
    }
  }

  private func recordPendingSentCopy(
    _ copy: StandardsMailPendingSentCopy,
    productAccountId: String
  ) throws {
    var copies = try sentCopyStore.load(
      productAccountId: productAccountId,
      connectionId: copy.connectionId
    )
    if let index = copies.firstIndex(where: { $0.idempotencyKey == copy.idempotencyKey }) {
      copies[index] = copy
    } else {
      copies.append(copy)
    }
    try sentCopyStore.save(
      copies,
      productAccountId: productAccountId,
      connectionId: copy.connectionId
    )
  }

  private func retryPendingSentCopies(
    authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: String,
    engineSession: (any MailEngineSession)? = nil,
    targetIdempotencyKey: String? = nil
  ) async -> Bool {
    let connectionId = authorization.definition.connectionId
    guard
      var pendingCopies = try? sentCopyStore.load(
        productAccountId: productAccountId,
        connectionId: connectionId
      )
    else { return false }
    guard !pendingCopies.isEmpty else { return true }
    let session: any MailEngineSession
    if let engineSession {
      session = engineSession
    } else {
      guard let connected = try? await client.connect(authorization: authorization) else {
        return false
      }
      session = connected.session
    }

    for copy in pendingCopies {
      if Task.isCancelled { break }
      do {
        let mailbox = MailEngineMailboxIdentity(copy.mailbox)
        if !(try await session.containsMessage(
          rfcMessageID: copy.rfcMessageId,
          mailbox: mailbox
        )) {
          _ = try await session.appendToSent(copy.rawMessage, mailbox: mailbox)
        }
        pendingCopies.removeAll { $0.idempotencyKey == copy.idempotencyKey }
        try sentCopyStore.save(
          pendingCopies,
          productAccountId: productAccountId,
          connectionId: connectionId
        )
      } catch is CancellationError {
        break
      } catch MailEngineError.cancelled {
        break
      } catch {
        // The encrypted journal retains the exact MIME bytes for the next reconciliation.
      }
    }
    return targetIdempotencyKey.map { target in
      !pendingCopies.contains { $0.idempotencyKey == target }
    } ?? pendingCopies.isEmpty
  }

  // swiftlint:disable:next function_body_length
  private func authorizationForProviderAccess(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    isWithinSyncGate: Bool = false
  ) async throws -> DeviceLocalGenericMailAuthorization {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    if snapshot.removedConnectionIds.contains(connection.id) {
      if isWithinSyncGate {
        try await performLocalCleanupWithoutLock(connection, session: session)
      } else {
        try await clearLocalConnection(connection, session: session)
      }
      try definitionSyncService.recordLocalCleanup(
        in: snapshot,
        connectionId: connection.id,
        session: session
      )
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard
      let authorization = try authorizationStore.load(
        productAccountId: ProductAccountId(session.productAccountId),
        connectionId: connection.id
      ),
      authorization.definition.incomingEndpoint.mailProtocol == .imap
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    guard
      let synchronizedDefinition = snapshot.connections.first(where: { $0.id == connection.id }),
      let definition = synchronizedDefinition.genericMailDefinition
    else {
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard
      connection.authorizationGeneration == synchronizedDefinition.authorizationGeneration
    else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    if try definitionSyncService.requiresLocalCleanup(
      in: snapshot,
      connectionId: connection.id,
      localAuthorizationGeneration: authorization.authorizationGeneration,
      session: session
    )
      || authorization.authorizationGeneration != synchronizedDefinition.authorizationGeneration
    {
      if isWithinSyncGate {
        try await performLocalCleanupWithoutLock(connection, session: session)
      } else {
        try await clearLocalConnection(connection, session: session)
      }
      try definitionSyncService.recordLocalCleanup(
        in: snapshot,
        connectionId: connection.id,
        session: session
      )
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    guard hasMatchingCredentials(authorization.definition, definition) else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    return DeviceLocalGenericMailAuthorization(
      authorizationGeneration: authorization.authorizationGeneration,
      credential: authorization.credential,
      definition: definition,
      engineCapabilities: authorization.engineCapabilities
    )
  }

  private func connection(
    id: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection {
    guard let connection = try await loadConnections(session: session).first(where: { $0.id == id })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return connection
  }

  private func localDefinition(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> GenericMailConnectionDefinition {
    try await authorizationForProviderAccess(
      connection: connection,
      session: session
    ).definition
  }

  private func hasMatchingCredentials(
    _ authorizationDefinition: GenericMailConnectionDefinition,
    _ syncedDefinition: GenericMailConnectionDefinition
  ) -> Bool {
    authorizationDefinition.authorizationMethod == syncedDefinition.authorizationMethod
      && authorizationDefinition.connectionId == syncedDefinition.connectionId
      && authorizationDefinition.incomingEndpoint == syncedDefinition.incomingEndpoint
      && authorizationDefinition.outgoingEndpoint == syncedDefinition.outgoingEndpoint
      && authorizationDefinition.username == syncedDefinition.username
  }

  private func validate(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool
  ) throws {
    guard connection.productAccountId == ProductAccountId(session.productAccountId) else {
      throw MailboxConnectionAdapterError.productAccountMismatch
    }
    guard connection.providerId == .imapSMTP else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    if requiresAuthorization, connection.authorizationState != .authorized {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }
}

struct MailboxConnectionRouter: MailboxConnectionAdapter, MailboxConnectionCacheLoading,
  MailboxConnectionSnapshotLoading
{
  private let attachmentStore: DownloadedAttachmentStore
  private let exchangeWebServices: MailboxConnectionAdapter
  private let gmail: MailboxConnectionAdapter
  private let imap: MailboxConnectionAdapter
  private let microsoftGraph: MailboxConnectionAdapter

  init(
    attachmentStore: DownloadedAttachmentStore = DownloadedAttachmentStore(),
    exchangeWebServices: MailboxConnectionAdapter = EWSMailboxConnectionAdapter(),
    gmail: MailboxConnectionAdapter = GmailMailboxConnectionAdapter(),
    imap: MailboxConnectionAdapter = IMAPMailboxConnectionAdapter(
      messageCategorizer: GmailMessageCategorizationService()
    ),
    microsoftGraph: MailboxConnectionAdapter = MicrosoftGraphMailboxConnectionAdapter()
  ) {
    self.attachmentStore = attachmentStore
    self.exchangeWebServices = exchangeWebServices
    self.gmail = gmail
    self.imap = imap
    self.microsoftGraph = microsoftGraph
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    var firstError: Error?
    do {
      try await exchangeWebServices.clearLocalConnection(session: session)
    } catch {
      firstError = error
    }
    do {
      try await gmail.clearLocalConnection(session: session)
    } catch {
      if firstError == nil { firstError = error }
    }
    do {
      try await imap.clearLocalConnection(session: session)
    } catch {
      if firstError == nil { firstError = error }
    }
    do {
      try await microsoftGraph.clearLocalConnection(session: session)
    } catch {
      if firstError == nil { firstError = error }
    }
    do {
      try attachmentStore.clearAll()
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }

  func rebuildLocalIndexes(session: ProductAccountSessionSnapshot) async throws {
    var firstError: Error?
    for adapter in [exchangeWebServices, gmail, imap, microsoftGraph] {
      do {
        try await adapter.rebuildLocalIndexes(session: session)
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError { throw firstError }
  }

  func clearLocalMailboxData(session: ProductAccountSessionSnapshot) async throws {
    var firstError: Error?
    for adapter in [exchangeWebServices, gmail, imap, microsoftGraph] {
      do {
        try await adapter.clearLocalMailboxData(session: session)
      } catch {
        firstError = firstError ?? error
      }
    }
    do {
      try attachmentStore.clearAll()
    } catch {
      firstError = firstError ?? error
    }
    if let firstError { throw firstError }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    do {
      try await adapter(for: connection.id).clearLocalConnection(connection, session: session)
    } catch {
      firstError = error
    }
    do {
      try attachmentStore.clear(connectionId: connection.id)
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }

  @MainActor
  func connect(
    expectedConnectionId: MailboxConnectionId?,
    removalObservation: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    let target = try expectedConnectionId.map(adapter(for:)) ?? gmail
    return try await target.connect(
      expectedConnectionId: expectedConnectionId,
      removalObservation: removalObservation,
      session: session,
      isSessionCurrent: isSessionCurrent
    )
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    try await loadConnectionSnapshot(session: session).connections
  }

  func loadConnectionSnapshot(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionLoadSnapshot {
    async let gmailLoad = loadConnections(from: gmail, session: session)
    async let imapLoad = loadConnections(from: imap, session: session)
    async let graphLoad = loadConnections(from: microsoftGraph, session: session)
    async let ewsLoad = loadConnections(from: exchangeWebServices, session: session)
    let (gmailResult, imapResult, graphResult, ewsResult) =
      try await (gmailLoad, imapLoad, graphLoad, ewsLoad)
    var connections: [MailboxConnection] = []
    var isAuthoritative = true
    var loadErrorDescription: String?
    for providerLoad in [gmailResult, imapResult, graphResult, ewsResult] {
      switch providerLoad {
      case .success(let loadedConnections):
        connections += loadedConnections
      case .failure(let errorDescription):
        isAuthoritative = false
        loadErrorDescription = loadErrorDescription ?? errorDescription
      }
    }
    return MailboxConnectionLoadSnapshot(
      connections: connections.sorted {
        if $0.displayName == $1.displayName { return $0.id.rawValue < $1.id.rawValue }
        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      },
      isAuthoritative: isAuthoritative,
      loadErrorDescription: loadErrorDescription
    )
  }

  func loadCachedConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    var connections: [MailboxConnection] = []
    var firstError: Error?
    for adapter in [exchangeWebServices, gmail, imap, microsoftGraph] {
      guard let cacheLoader = adapter as? any MailboxConnectionCacheLoading else { continue }
      do {
        connections += try await cacheLoader.loadCachedConnections(session: session)
      } catch {
        firstError = firstError ?? error
      }
    }
    if connections.isEmpty, let firstError { throw firstError }
    return connections.sorted {
      if $0.displayName == $1.displayName { return $0.id.rawValue < $1.id.rawValue }
      return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  func loadCachedDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    guard let cacheLoader = gmail as? any MailboxConnectionCacheLoading else { return nil }
    return try await cacheLoader.loadCachedDefaultSendingConnectionId(session: session)
  }

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    try await gmail.loadDefaultSendingConnectionId(session: session)
  }

  func removeMailboxConnectionEverywhere(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    do {
      try await adapter(for: connection.id)
        .removeMailboxConnectionEverywhere(connection, session: session)
    } catch {
      firstError = error
    }
    do {
      try attachmentStore.clear(connectionId: connection.id)
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await (try connection.map { try adapter(for: $0.id) } ?? gmail)
      .setDefaultSendingConnection(connection, session: session)
  }

  func categorizeHistorical(
    scope: HistoricalCategorizationScope,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await adapter(for: connection.id)
      .categorizeHistorical(scope: scope, connection: connection, session: session)
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await adapter(for: connection.id).loadInbox(connection: connection, session: session)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await adapter(for: connection.id)
      .loadMailbox(collection, connection: connection, session: session)
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    try await adapter(for: connection.id)
      .loadProviderMailboxes(connection: connection, session: session)
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await adapter(for: connection.id)
      .continueHistoricalBackfill(connection: connection, session: session)
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await adapter(for: connection.id).syncInbox(connection: connection, session: session)
  }

  // swiftlint:disable:next function_parameter_count
  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId: String?,
    throughHistoryId: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    try await adapter(for: connection.id).syncRecentInbox(
      connection: connection,
      includingHistoryCandidates: includingHistoryCandidates,
      session: session,
      sinceHistoryId: sinceHistoryId,
      throughHistoryId: throughHistoryId,
      shouldPersist: shouldPersist
    )
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    try await adapter(for: message.connectionId)
      .overrideCategory(categoryId, for: message, session: session)
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    try await adapter(for: message.connectionId)
      .setCategories(categoryIds, for: message, session: session)
  }

  func searchProvider(
    query: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    try await adapter(for: connection.id)
      .searchProvider(query: query, connection: connection, session: session)
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    var firstError: Error?
    do {
      try exchangeWebServices.clearCachedMessageBodies(session: session)
    } catch {
      firstError = error
    }
    do {
      try gmail.clearCachedMessageBodies(session: session)
    } catch {
      if firstError == nil { firstError = error }
    }
    do {
      try imap.clearCachedMessageBodies(session: session)
    } catch {
      if firstError == nil { firstError = error }
    }
    do {
      try microsoftGraph.clearCachedMessageBodies(session: session)
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try adapter(for: connection.id)
      .clearCachedMessageBodies(connection: connection, session: session)
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    try await adapter(for: message.connectionId).loadMessageBody(message: message, session: session)
  }

  func loadMessageSource(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageSource {
    try await adapter(for: message.connectionId).loadMessageSource(
      message: message,
      session: session
    )
  }

  func loadMessageBodyText(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> String {
    try await adapter(for: message.connectionId).loadMessageBodyText(
      message: message,
      session: session
    )
  }

  func loadMessageAttachment(
    _ attachment: MailboxMessageAttachment,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> Data {
    try await adapter(for: message.connectionId).loadMessageAttachment(
      attachment,
      message: message,
      session: session
    )
  }

  func loadCalendarInvitationCandidate(
    _ invitation: CalendarInvitationDescriptor,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> CalendarInvitationCandidate {
    try await adapter(for: message.connectionId).loadCalendarInvitationCandidate(
      invitation,
      message: message,
      session: session
    )
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).prefetchMessageBodies(
      connection: connection,
      pinnedThreadIds: pinnedThreadIds,
      referenceDate: referenceDate,
      session: session
    )
  }

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try adapter(for: message.connectionId).removeCachedMessageBody(
      message: message,
      session: session
    )
  }

  func registerOrRenewPush(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id)
      .registerOrRenewPush(connection: connection, session: session)
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id)
      .perform(action, messages: messages, connection: connection, session: session)
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).perform(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  // swiftlint:disable:next function_parameter_count
  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).perform(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  // swiftlint:disable:next function_parameter_count
  func perform(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).perform(
      action,
      sourceProviderMailboxId: sourceProviderMailboxId,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    try await adapter(for: connection.id).performTracked(
      action,
      sourceProviderMailboxId: sourceProviderMailboxId,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: targetProviderStateIds,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func releasePendingActionSelection(
    _ selection: MailboxProviderActionSelection,
    connection: MailboxConnection
  ) async {
    guard let adapter = try? adapter(for: connection.id) else { return }
    await adapter.releasePendingActionSelection(selection, connection: connection)
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionErrors(
      connections: connections,
      session: session,
      operation: { adapter, connections in
        await adapter.resumePendingActions(connections: connections, session: session)
      }
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    await pendingActionErrors(
      connections: connections,
      session: session,
      operation: { adapter, connections in
        await adapter.resumePendingActions(
          connections: connections,
          session: session,
          revalidateProviderAccess: revalidateProviderAccess
        )
      }
    )
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    guard let adapter = try? adapter(for: connection.id) else { return nil }

    return await adapter.retryBlockedPendingAction(
      connection: connection,
      session: session
    )
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    guard let adapter = try? adapter(for: connection.id) else { return nil }

    return await adapter.retryBlockedPendingAction(
      connection: connection,
      session: session,
      revalidateProviderAccess: revalidateProviderAccess
    )
  }

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    guard let adapter = try? adapter(for: connection.id) else { return nil }

    return await adapter.discardBlockedPendingAction(
      connection: connection,
      session: session
    )
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    await pendingActionConnectionIds(
      connections: connections,
      session: session,
      operation: { adapter, connections in
        await adapter.blockedPendingActionConnectionIds(connections: connections, session: session)
      }
    )
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    await pendingActionConnectionIds(
      connections: connections,
      session: session,
      operation: { adapter, connections in
        await adapter.failedPendingActionConnectionIds(connections: connections, session: session)
      }
    )
  }

  func waitForPendingActionRetries(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionErrors(
      connections: connections,
      session: session,
      operation: { adapter, connections in
        await adapter.waitForPendingActionRetries(connections: connections, session: session)
      }
    )
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    guard let adapter = try? adapter(for: connection.id) else { return }
    await adapter.acknowledgePendingActionFailures(
      connection: connection,
      session: session
    )
  }

  func pendingActionFailureDetails(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    await (try? adapter(for: connection.id))?.pendingActionFailureDetails(
      action,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func pendingActionFailureLookup(
    _ action: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    await (try? adapter(for: connection.id))?.pendingActionFailureLookup(
      action,
      selection: selection,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).send(message, connection: connection, session: session)
  }

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    try await adapter(for: connection.id).deliveryStatus(
      idempotencyKey: idempotencyKey,
      connection: connection,
      session: session
    )
  }

  private func adapter(
    for connectionId: MailboxConnectionId
  ) throws -> MailboxConnectionAdapter {
    switch connectionId.providerId {
    case .exchangeWebServices:
      return exchangeWebServices
    case .gmail:
      return gmail
    case .imapSMTP:
      return imap
    case .microsoftGraph:
      return microsoftGraph
    default:
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
  }

  private func pendingActionErrors(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    operation: (MailboxConnectionAdapter, [MailboxConnection]) async -> String?
  ) async -> String? {
    let gmailConnections = connections.filter { $0.id.providerId == .gmail }
    let ewsConnections = connections.filter { $0.id.providerId == .exchangeWebServices }
    let imapConnections = connections.filter { $0.id.providerId == .imapSMTP }
    let graphConnections = connections.filter { $0.id.providerId == .microsoftGraph }
    async let gmailError = operation(gmail, gmailConnections)
    async let ewsError = operation(exchangeWebServices, ewsConnections)
    async let imapError = operation(imap, imapConnections)
    async let graphError = operation(microsoftGraph, graphConnections)
    let (resolvedGmailError, resolvedImapError, resolvedGraphError, resolvedEWSError) =
      await (gmailError, imapError, graphError, ewsError)
    let errors = [resolvedGmailError, resolvedImapError, resolvedGraphError, resolvedEWSError]
      .compactMap { $0 }
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  private func pendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    operation: (MailboxConnectionAdapter, [MailboxConnection]) async -> [MailboxConnectionId]
  ) async -> [MailboxConnectionId] {
    let ewsConnections = connections.filter { $0.id.providerId == .exchangeWebServices }
    let gmailConnections = connections.filter { $0.id.providerId == .gmail }
    let imapConnections = connections.filter { $0.id.providerId == .imapSMTP }
    let graphConnections = connections.filter { $0.id.providerId == .microsoftGraph }
    async let ewsIds = operation(exchangeWebServices, ewsConnections)
    async let gmailIds = operation(gmail, gmailConnections)
    async let imapIds = operation(imap, imapConnections)
    async let graphIds = operation(microsoftGraph, graphConnections)
    let (resolvedEWSIds, resolvedGmailIds, resolvedImapIds, resolvedGraphIds) =
      await (ewsIds, gmailIds, imapIds, graphIds)
    return resolvedEWSIds + resolvedGmailIds + resolvedImapIds + resolvedGraphIds
  }

  private func loadConnections(
    from adapter: MailboxConnectionAdapter,
    session: ProductAccountSessionSnapshot
  ) async throws -> ProviderConnectionLoad {
    do {
      return .success(try await adapter.loadConnections(session: session))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  private enum ProviderConnectionLoad {
    case failure(String)
    case success([MailboxConnection])
  }
}
