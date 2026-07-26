import Foundation
import SwiftData

// swiftlint:disable file_length function_parameter_count identifier_name type_body_length

enum IMAPMailboxError: LocalizedError, Equatable {
  case appendOutcomeUnknown
  case idleUnsupported
  case invalidProviderResponse
  case missingLocalAuthorization
  case missingMessage
  case unsafeExpunge
  case unsupportedAction
  case unsupportedBody

  var errorDescription: String? {
    switch self {
    case .appendOutcomeUnknown:
      return "The IMAP server did not confirm whether it saved the message."
    case .idleUnsupported:
      return "This IMAP server does not support IDLE; mail will refresh periodically."
    case .invalidProviderResponse:
      return "The IMAP server returned an invalid response."
    case .missingLocalAuthorization:
      return "Authorize this IMAP mailbox on this device before accessing mail."
    case .missingMessage:
      return "The selected IMAP message is no longer available."
    case .unsafeExpunge:
      return "The IMAP server cannot safely remove only the selected message."
    case .unsupportedAction:
      return "The IMAP server does not support this mail action."
    case .unsupportedBody:
      return "The IMAP server did not return a readable message body."
    }
  }
}

enum SMTPMailError: LocalizedError, Equatable {
  case deliveryUncertainAfterSubmission
  case invalidMessage
  case responseCode(Int)
  case sentCopyFailedAfterAcceptance
  case sentCopyOutcomeUnknownAfterAcceptance

  var errorDescription: String? {
    switch self {
    case .deliveryUncertainAfterSubmission:
      return "The SMTP connection closed before the server confirmed the submitted message."
    case .invalidMessage:
      return "The outgoing message contains an invalid address or header."
    case .responseCode(let code):
      return "The SMTP server rejected the outgoing message with status \(code)."
    case .sentCopyFailedAfterAcceptance:
      return
        "SMTP accepted the message, but the server did not confirm its Sent mailbox copy."
    case .sentCopyOutcomeUnknownAfterAcceptance:
      return
        "SMTP accepted the message, but the Sent mailbox copy outcome is unknown."
    }
  }
}

struct IMAPMailboxDescriptor: Codable, Equatable, Hashable, Sendable {
  let displayName: String
  let name: String
}

struct IMAPProviderMessage: Codable, Equatable, Sendable {
  var categoryId: String?
  let cc: String?
  let flags: [String]
  let from: String?
  let inReplyTo: String?
  let internalDateMilliseconds: Int64
  let mailbox: String
  var providerEmailId: String?
  let providerThreadId: String?
  let references: [String]
  let replyTo: String?
  let rfcMessageId: String?
  let snippet: String
  let subject: String
  let to: String?
  let uid: Int64
  let uidValidity: Int64

  var providerMessageId: String {
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
      subject: subject
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

  static func mailboxName(fromProviderStateId providerStateId: String) -> String? {
    let prefix = "imap-mailbox:"
    guard providerStateId.hasPrefix(prefix) else { return nil }
    var encoded = String(providerStateId.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard
      let data = Data(base64Encoded: encoded),
      let mailbox = String(data: data, encoding: .utf8),
      !mailbox.isEmpty
    else { return nil }
    return mailbox
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

  func appendMessage(
    _ message: Data,
    to mailbox: String,
    flags: [String],
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws

  func perform(
    _ action: ProviderMailAction,
    message: IMAPProviderMessage,
    targetMailbox: String?,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws

  func waitForChange(
    in mailbox: String,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws

  func supportsIdle(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> Bool
}

extension IMAPMailboxClient {
  func appendMessage(
    _: Data,
    to _: String,
    flags _: [String],
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws {
    throw IMAPMailboxError.unsupportedAction
  }

  func perform(
    _: ProviderMailAction,
    message _: IMAPProviderMessage,
    targetMailbox _: String?,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws {
    throw IMAPMailboxError.unsupportedAction
  }

  func waitForChange(
    in _: String,
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws {
    throw IMAPMailboxError.idleUnsupported
  }

  func supportsIdle(
    authorization _: DeviceLocalGenericMailAuthorization
  ) async throws -> Bool {
    false
  }
}

protocol SMTPMailClient {
  func send(
    _ message: Data,
    envelopeFrom: String,
    envelopeRecipients: [String],
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws
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

  func loadProviderMessages(
    stableProviderMessageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [IMAPProviderMessage]

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

  func loadProviderMessages(
    stableProviderMessageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [IMAPProviderMessage] {
    let context = try makeContext()
    let connectionIdRawValue = connectionId.rawValue
    let descriptor = FetchDescriptor<DurableIMAPMessageMetadataRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
          && $0.stableProviderMessageId == stableProviderMessageId
      }
    )
    return try context.fetch(descriptor).map { try $0.message() }
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
    if case .newest(let coversEntireMailbox) = reconciliation {
      let incomingIds = Set(messages.map(\.providerMessageId))
      let oldestFetchedUID = messages.map(\.uid).min()
      for record in matchingRecords {
        let existingMessage = try record.message()
        if !incomingIds.contains(existingMessage.providerMessageId),
          coversEntireMailbox || oldestFetchedUID.map({ existingMessage.uid >= $0 }) == true
        {
          context.delete(record)
        }
      }
    }
    for var message in messages {
      let stableId = StableProviderMessageIdentity(
        connectionId: connectionId,
        providerMessageId: message.providerMessageId
      ).rawValue
      if let existing = existingById[stableId] {
        message.categoryId = try existing.message().categoryId
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

  private static let schema = Schema([
    DurableIMAPMessageMetadataRecord.self,
    IMAPMetadataSyncCheckpointRecord.self,
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
    gmailSafeFileComponent(
      "\(productAccountId)\0\(connectionId.rawValue)\0\(mailbox)\0\(uidValidity)\0\(uid)"
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
    client: IMAPMailboxClient = SystemIMAPMailboxClient(),
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
          subject: metadata.subject
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
  private let authorizationStore: GenericMailAuthorizationPersisting
  private let cache: GmailMessageBodyCaching
  private let client: IMAPMailboxClient
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let metadataStore: IMAPMessageMetadataPersisting

  init(
    authorizationStore: GenericMailAuthorizationPersisting =
      KeychainGenericMailAuthorizationStore(),
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: IMAPMailboxClient = SystemIMAPMailboxClient(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    metadataStore: IMAPMessageMetadataPersisting = SwiftDataIMAPMessageMetadataStore()
  ) {
    self.authorizationStore = authorizationStore
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
    session: ProductAccountSessionSnapshot
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
    let authorization = try requiredAuthorization(
      connectionId: message.connectionId,
      productAccountId: ProductAccountId(session.productAccountId)
    )
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

  // swiftlint:disable:next function_body_length
  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
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
      pinnedMessageIds: pinnedMessageIds,
      referenceDate: referenceDate
    )
    let protectedIds = Set(plan.map(\.stableProviderMessageId))
    let pinnedIds = Set(
      pinnedMessageIds.filter { $0.connectionId == connection.id }.map(\.rawValue)
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

  private func requiredAuthorization(
    connectionId: MailboxConnectionId,
    productAccountId: ProductAccountId
  ) throws -> DeviceLocalGenericMailAuthorization {
    guard
      let authorization = try authorizationStore.load(
        productAccountId: productAccountId,
        connectionId: connectionId
      ),
      authorization.definition.incomingEndpoint.mailProtocol == .imap
    else { throw IMAPMailboxError.missingLocalAuthorization }
    return authorization
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
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
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
      pinnedMessageIds.contains($0.id) && !recentIds.contains($0.id)
    }.sorted(by: Self.messagesAreOrdered)
    self.messages = Array(pinned) + Array(recent)
  }

  func map<T>(_ transform: (MailboxMessageMetadata) throws -> T) rethrows -> [T] {
    try messages.map(transform)
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

struct IMAPMailboxConnectionAdapter: MailboxConnectionAdapter, MailboxChangeObserving {
  private let authorizationStore: GenericMailAuthorizationPersisting
  private let bodyReader: IMAPMessageBodyService
  private let cache: GmailMessageBodyCaching
  private let client: IMAPMailboxClient
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let metadataService: IMAPMessageMetadataService
  private let metadataStore: IMAPMessageMetadataPersisting
  private let outboxService: OutboxDeliveryService
  private let pendingActionService: PendingProviderActionService
  private let smtpClient: SMTPMailClient
  private let syncGate: MailboxConnectionSyncGate

  init(
    authorizationStore: GenericMailAuthorizationPersisting =
      KeychainGenericMailAuthorizationStore(),
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: IMAPMailboxClient = SystemIMAPMailboxClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing =
      MailboxConnectionSyncService(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    metadataStore: IMAPMessageMetadataPersisting = SwiftDataIMAPMessageMetadataStore(),
    outboxService: OutboxDeliveryService = .shared,
    pendingActionService: PendingProviderActionService = .shared,
    smtpClient: SMTPMailClient = SystemSMTPMailClient(),
    syncGate: MailboxConnectionSyncGate = .shared
  ) {
    self.authorizationStore = authorizationStore
    self.cache = cache
    self.client = client
    self.definitionSyncService = definitionSyncService
    self.metadataStore = metadataStore
    self.outboxService = outboxService
    self.pendingActionService = pendingActionService
    self.smtpClient = smtpClient
    self.syncGate = syncGate
    bodyReader = IMAPMessageBodyService(
      authorizationStore: authorizationStore,
      cache: cache,
      client: client,
      keyMaterialStore: keyMaterialStore,
      metadataStore: metadataStore
    )
    metadataService = IMAPMessageMetadataService(client: client, store: metadataStore)
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    try await pendingActionService.clear(session: session)
    try await outboxService.clear(session: session)
    try authorizationStore.clearAll(productAccountId: ProductAccountId(session.productAccountId))
    try metadataStore.clear(productAccountId: session.productAccountId)
    try cache.clearMessageBodies(productAccountId: session.productAccountId)
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    try await pendingActionService.clear(connection: connection, session: session)
    try await outboxService.clear(connection: connection, session: session)
    try await syncGate.withLock(connection.id) {
      try clearLocalConnectionWithoutLock(connection, session: session)
    }
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
    session _: ProductAccountSessionSnapshot,
    isSessionCurrent _: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection? {
    try await loadConnections(session: session).first
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    for removedId in snapshot.removedConnectionIds where removedId.providerId == .imapSMTP {
      try await syncGate.withLock(removedId) {
        try clearLocalConnectionWithoutLock(removedId, session: session)
      }
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
          hasMatchingCredentials($0.definition, genericDefinition)
        } ?? false
      let capabilities =
        if let serverCapabilities = genericDefinition.imapCapabilities {
          MailboxConnectionCapabilities.imapFull(serverCapabilities: serverCapabilities)
        } else {
          MailboxConnectionCapabilities.imapFull(serverCapabilities: [])
        }
      return MailboxConnection(
        authorizationState: isAuthorized ? .authorized : .required,
        capabilities: isAuthorized ? capabilities : .none,
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
    let result = try metadataService.load(
      definition: definition,
      connectedAt: connection.connectedAt,
      productAccountId: session.productAccountId
    )
    return try await pendingActionService.project(
      result,
      collection: .role(.inbox),
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
    let result = try metadataService.load(
      definition: definition,
      connectedAt: connection.connectedAt,
      productAccountId: session.productAccountId
    )
    let projected = try await pendingActionService.project(
      result,
      collection: collection,
      connection: connection,
      session: session
    )
    guard collection != .allObserved else { return projected }
    return projected.limitedInitialPage(to: IMAPMessageMetadataService.initialPageSize)
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
      let result = try await metadataService.continueBackfill(
        authorization: authorization,
        connectedAt: connection.connectedAt,
        productAccountId: session.productAccountId
      )
      try await reconcileAndResumePendingActions(
        messages: result.messages,
        connection: connection,
        session: session
      )
      return try await pendingActionService.project(
        result,
        collection: .role(.inbox),
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
      let result = try await metadataService.sync(
        authorization: authorization,
        connectedAt: connection.connectedAt,
        productAccountId: session.productAccountId
      )
      try await reconcileAndResumePendingActions(
        messages: result.messages,
        connection: connection,
        session: session
      )
      return try await pendingActionService.project(
        result,
        collection: .role(.inbox),
        connection: connection,
        session: session
      )
      .limitedInitialPage(to: IMAPMessageMetadataService.initialPageSize)
    }
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
    if let cached = try bodyReader.loadCachedMessageBody(message: message, session: session) {
      return cached
    }
    _ = try await authorizationForProviderAccess(
      connection: connection(id: message.connectionId, session: session),
      session: session
    )
    return try await bodyReader.loadMessageBody(message: message, session: session)
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
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
        pinnedMessageIds: pinnedMessageIds,
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
    let authorization = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    guard try await client.supportsIdle(authorization: authorization) else {
      throw IMAPMailboxError.idleUnsupported
    }
  }

  func waitForMailboxChange(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let authorization = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    try await client.waitForChange(
      in: "INBOX",
      authorization: authorization
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
    _ = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    try await pendingActionService.enqueue(
      action,
      targetProviderMailboxId: targetProviderMailboxId,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    var errors: [String] = []
    for connection in connections {
      if let error = await resumePendingActions(connection: connection, session: session) {
        errors.append("\(connection.displayName): \(error)")
      }
    }
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session,
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

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedPendingAction(
      connection: connection,
      session: session,
      discards: false
    )
  }

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedPendingAction(
      connection: connection,
      session: session,
      discards: true
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

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    try? await pendingActionService.acknowledgeFailures(
      connection: connection,
      session: session
    )
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let authorization = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    let rfc822Message = try Self.rfc822Message(
      message,
      sender: authorization.definition.emailAddress
    )
    guard let sentMailbox = authorization.definition.roleMappings[.sent] else {
      throw IMAPMailboxError.unsupportedAction
    }
    if message.sentCopyOnly != true {
      try await smtpClient.send(
        rfc822Message,
        envelopeFrom: authorization.definition.emailAddress,
        envelopeRecipients: try Self.envelopeRecipients(in: message.recipient),
        authorization: authorization
      )
    }
    do {
      try await client.appendMessage(
        rfc822Message,
        to: sentMailbox,
        flags: ["\\Seen"],
        authorization: authorization
      )
    } catch IMAPMailboxError.appendOutcomeUnknown {
      throw SMTPMailError.sentCopyOutcomeUnknownAfterAcceptance
    } catch {
      throw SMTPMailError.sentCopyFailedAfterAcceptance
    }
  }

  func saveDraft(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let authorization = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    guard let draftsMailbox = authorization.definition.roleMappings[.drafts] else {
      throw IMAPMailboxError.unsupportedAction
    }
    try await client.appendMessage(
      try Self.rfc822Message(
        message,
        sender: authorization.definition.emailAddress,
        requiresRecipient: false
      ),
      to: draftsMailbox,
      flags: ["\\Draft"],
      authorization: authorization
    )
  }

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    let authorization = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    guard let sentMailbox = authorization.definition.roleMappings[.sent] else {
      return .unknown
    }
    let messageId = OutgoingMessage.rfcMessageId(for: idempotencyKey).lowercased()
    let storedMessages = try metadataStore.loadMessages(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    if storedMessages.contains(where: {
      $0.rfcMessageId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == messageId
        && IMAPProviderMessage.mailboxNamesEqual(
          $0.mailbox,
          sentMailbox
        )
    }) {
      return .sent
    }
    let page = try await client.loadMetadataPage(
      mailbox: IMAPMailboxDescriptor(displayName: sentMailbox, name: sentMailbox),
      beforeUID: nil,
      limit: 50,
      authorization: authorization
    )
    return page.messages.contains {
      $0.rfcMessageId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == messageId
    } ? .sent : .unknown
  }

  private func pendingActionPerformer(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> PendingProviderActionPerformer {
    { action, targetProviderMailboxId, messageIds in
      try await performProviderAction(
        action,
        targetProviderMailboxId: targetProviderMailboxId,
        messageIds: messageIds,
        connection: connection,
        session: session
      )
    }
  }

  private func reconcileAndResumePendingActions(
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await pendingActionService.reconcileProviderSync(
      messages: messages,
      connection: connection,
      session: session
    )
    _ = await resumePendingActions(connection: connection, session: session)
  }

  private func performProviderAction(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messageIds: [String],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let authorization = try await authorizationForProviderAccess(
      connection: connection,
      session: session
    )
    for messageId in messageIds {
      let appearances = try metadataStore.loadProviderMessages(
        stableProviderMessageId: StableProviderMessageIdentity(
          connectionId: connection.id,
          providerMessageId: messageId
        ).rawValue,
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
      guard
        let message = providerActionAppearance(
          for: action,
          appearances: appearances,
          definition: authorization.definition
        )
      else {
        throw IMAPMailboxError.missingMessage
      }
      try await client.perform(
        action,
        message: message,
        targetMailbox: try targetMailbox(
          for: action,
          requestedProviderMailboxId: targetProviderMailboxId,
          message: message,
          definition: authorization.definition
        ),
        authorization: authorization
      )
    }
  }

  private func providerActionAppearance(
    for action: ProviderMailAction,
    appearances: [IMAPProviderMessage],
    definition: GenericMailConnectionDefinition
  ) -> IMAPProviderMessage? {
    let preferredMailbox =
      switch action {
      case .notSpam:
        definition.roleMappings[.spam]
      case .restore:
        definition.roleMappings[.trash] ?? definition.roleMappings[.spam]
      default:
        "INBOX"
      }
    return appearances.first {
      IMAPProviderMessage.mailboxNamesEqual($0.mailbox, preferredMailbox ?? "")
    }
      ?? appearances.sorted {
        if $0.mailbox == $1.mailbox { return $0.uid < $1.uid }
        return $0.mailbox.localizedCaseInsensitiveCompare($1.mailbox) == .orderedAscending
      }.first
  }

  private func targetMailbox(
    for action: ProviderMailAction,
    requestedProviderMailboxId: String?,
    message: IMAPProviderMessage,
    definition: GenericMailConnectionDefinition
  ) throws -> String? {
    switch action {
    case .archive:
      return definition.roleMappings[.archive]
    case .delete:
      guard let trash = definition.roleMappings[.trash] else {
        throw IMAPMailboxError.unsupportedAction
      }
      return IMAPProviderMessage.mailboxNamesEqual(message.mailbox, trash) ? nil : trash
    case .move:
      guard
        let requestedProviderMailboxId,
        let mailbox = IMAPProviderMessage.mailboxName(
          fromProviderStateId: requestedProviderMailboxId
        )
      else {
        throw MailboxConnectionAdapterError.providerMailboxTargetRequired
      }
      return mailbox
    case .notSpam, .restore:
      return "INBOX"
    case .spam:
      return definition.roleMappings[.spam]
    case .markRead, .markUnread, .star, .unstar:
      return nil
    }
  }

  private func resolveBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    discards: Bool
  ) async -> String? {
    do {
      let provider = pendingActionPerformer(connection: connection, session: session)
      if discards {
        try await pendingActionService.discardBlockedAction(
          connection: connection,
          session: session,
          provider: provider
        )
      } else {
        try await pendingActionService.retryBlockedAction(
          connection: connection,
          session: session,
          provider: provider
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

  private static func rfc822Message(
    _ message: OutgoingMessage,
    sender: String,
    requiresRecipient: Bool = true
  ) throws -> Data {
    let sender = try safeHeaderValue(sender)
    let recipient = try safeHeaderValue(message.recipient)
    guard !sender.isEmpty, !requiresRecipient || !recipient.isEmpty else {
      throw SMTPMailError.invalidMessage
    }
    var headers = [
      "From: \(sender)",
      "Subject: \(try encodedHeaderValue(message.subject))",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: base64",
    ]
    if !recipient.isEmpty {
      headers.insert("To: \(recipient)", at: 0)
    }
    if let inReplyTo = message.inReplyTo {
      let replyHeader = try safeHeaderValue(inReplyTo)
      headers.append("In-Reply-To: \(replyHeader)")
      headers.append("References: \(replyHeader)")
    }
    if let rfcMessageId = message.rfcMessageId {
      headers.append("Message-ID: \(try safeHeaderValue(rfcMessageId))")
    }
    let encodedBody = Data(message.body.utf8).base64EncodedString(
      options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
    )
    return Data((headers + ["", encodedBody]).joined(separator: "\r\n").utf8)
  }

  private static func encodedHeaderValue(_ value: String) throws -> String {
    let value = try safeHeaderValue(value)
    guard !value.unicodeScalars.allSatisfy(\.isASCII) else { return value }
    return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
  }

  private static func envelopeRecipients(in value: String) throws -> [String] {
    let value = try safeHeaderValue(value)
    let recipients = splitMailboxValues(value).map(mailboxAddress)
    guard
      !recipients.isEmpty,
      recipients.allSatisfy({
        !$0.isEmpty
          && $0.contains("@")
          && !$0.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," })
      })
    else {
      throw SMTPMailError.invalidMessage
    }
    return recipients
  }

  private static func splitMailboxValues(_ value: String) -> [String] {
    var values: [String] = []
    var valueBuffer = ""
    var isEscaped = false
    var isQuoted = false
    var angleBracketDepth = 0

    for character in value {
      if isEscaped {
        valueBuffer.append(character)
        isEscaped = false
        continue
      }
      if character == "\\" && isQuoted {
        valueBuffer.append(character)
        isEscaped = true
        continue
      }
      switch character {
      case "\"":
        isQuoted.toggle()
      case "<":
        angleBracketDepth += 1
      case ">":
        angleBracketDepth = max(0, angleBracketDepth - 1)
      case "," where !isQuoted && angleBracketDepth == 0:
        values.append(valueBuffer)
        valueBuffer = ""
        continue
      default:
        break
      }
      valueBuffer.append(character)
    }
    values.append(valueBuffer)
    return values
  }

  private static func mailboxAddress(_ value: String) -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let opening = value.lastIndex(of: "<"),
      let closing = value.lastIndex(of: ">"),
      opening < closing
    else { return value }
    return String(value[value.index(after: opening)..<closing])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func safeHeaderValue(_ value: String) throws -> String {
    guard !value.contains("\r"), !value.contains("\n") else {
      throw SMTPMailError.invalidMessage
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func authorizationForProviderAccess(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    isWithinSyncGate: Bool = false
  ) async throws -> DeviceLocalGenericMailAuthorization {
    try validate(connection: connection, session: session, requiresAuthorization: true)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    if snapshot.removedConnectionIds.contains(connection.id) {
      if isWithinSyncGate {
        try clearLocalConnectionWithoutLock(connection, session: session)
      } else {
        try await clearLocalConnection(connection, session: session)
      }
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
      let definition = snapshot.connections.first(where: { $0.id == connection.id })?
        .genericMailDefinition
    else {
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard hasMatchingCredentials(authorization.definition, definition) else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    return DeviceLocalGenericMailAuthorization(
      credential: authorization.credential,
      definition: definition
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
    try validate(connection: connection, session: session, requiresAuthorization: false)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    if snapshot.removedConnectionIds.contains(connection.id) {
      try await clearLocalConnection(connection, session: session)
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
      let definition = snapshot.connections.first(where: { $0.id == connection.id })?
        .genericMailDefinition
    else {
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard hasMatchingCredentials(authorization.definition, definition) else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    return definition
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

struct MailboxConnectionRouter: MailboxConnectionAdapter, MailboxChangeObserving {
  private let gmail: MailboxConnectionAdapter
  private let imap: MailboxConnectionAdapter
  private let microsoftGraph: MailboxConnectionAdapter

  init(
    gmail: MailboxConnectionAdapter = GmailMailboxConnectionAdapter(),
    imap: MailboxConnectionAdapter = IMAPMailboxConnectionAdapter(),
    microsoftGraph: MailboxConnectionAdapter = MicrosoftGraphMailboxConnectionAdapter()
  ) {
    self.gmail = gmail
    self.imap = imap
    self.microsoftGraph = microsoftGraph
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    var firstError: Error?
    do {
      try await gmail.clearLocalConnection(session: session)
    } catch {
      firstError = error
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
    if let firstError { throw firstError }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).clearLocalConnection(connection, session: session)
  }

  @MainActor
  func connect(
    expectedConnectionId: MailboxConnectionId?,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    let target = try expectedConnectionId.map(adapter(for:)) ?? gmail
    return try await target.connect(
      expectedConnectionId: expectedConnectionId,
      session: session,
      isSessionCurrent: isSessionCurrent
    )
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection? {
    try await loadConnections(session: session).first
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    let gmailConnections = try await gmail.loadConnections(session: session)
    let imapConnections = (try? await imap.loadConnections(session: session)) ?? []
    let graphConnections = (try? await microsoftGraph.loadConnections(session: session)) ?? []
    let connections = gmailConnections + imapConnections + graphConnections
    return connections.sorted {
      if $0.displayName == $1.displayName { return $0.id.rawValue < $1.id.rawValue }
      return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
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
    try await adapter(for: connection.id)
      .removeMailboxConnectionEverywhere(connection, session: session)
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
      try gmail.clearCachedMessageBodies(session: session)
    } catch {
      firstError = error
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

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).prefetchMessageBodies(
      connection: connection,
      pinnedMessageIds: pinnedMessageIds,
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

  func waitForMailboxChange(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    guard let observer = try adapter(for: connection.id) as? MailboxChangeObserving else {
      throw MailboxConnectionAdapterError.unsupportedCapability
    }
    try await observer.waitForMailboxChange(connection: connection, session: session)
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

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id).send(message, connection: connection, session: session)
  }

  func saveDraft(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await adapter(for: connection.id)
      .saveDraft(message, connection: connection, session: session)
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
    let imapConnections = connections.filter { $0.id.providerId == .imapSMTP }
    let graphConnections = connections.filter { $0.id.providerId == .microsoftGraph }
    let gmailError = await operation(gmail, gmailConnections)
    let imapError = await operation(imap, imapConnections)
    let graphError = await operation(microsoftGraph, graphConnections)
    let errors = [gmailError, imapError, graphError].compactMap { $0 }
    return errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  private func pendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    operation: (MailboxConnectionAdapter, [MailboxConnection]) async -> [MailboxConnectionId]
  ) async -> [MailboxConnectionId] {
    let gmailConnections = connections.filter { $0.id.providerId == .gmail }
    let imapConnections = connections.filter { $0.id.providerId == .imapSMTP }
    let graphConnections = connections.filter { $0.id.providerId == .microsoftGraph }
    let gmailIds = await operation(gmail, gmailConnections)
    let imapIds = await operation(imap, imapConnections)
    let graphIds = await operation(microsoftGraph, graphConnections)
    return gmailIds + imapIds + graphIds
  }
}
