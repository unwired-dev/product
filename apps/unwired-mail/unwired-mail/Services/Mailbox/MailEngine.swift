import Foundation

// swiftlint:disable file_length

// This boundary intentionally contains no persistence, retry, mailbox-role policy, or
// provider-action reconciliation. Those remain product-owned above the protocol engine.

struct MailEngineMailboxIdentity: Codable, Equatable, Hashable, Sendable {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

struct MailEngineMessageIdentity: Equatable, Hashable, Sendable {
  let connectionID: String
  let mailbox: MailEngineMailboxIdentity
  let uid: Int64
  let uidValidity: Int64
}

struct MailEngineHeaderField: Equatable, Sendable {
  let name: String
  let value: String
}

enum MailEngineTransportMode: Equatable, Sendable {
  case implicitTLS
  case startTLS
}

enum MailEngineService: Equatable, Hashable, Sendable {
  case imap
  case smtp
}

enum MailEngineTLSVersion: Int, Comparable, Sendable {
  case tls10 = 10
  case tls11 = 11
  case tls12 = 12
  case tls13 = 13

  static func < (lhs: MailEngineTLSVersion, rhs: MailEngineTLSVersion) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct MailEngineEndpoint: Equatable, Sendable {
  let hostname: String
  let port: Int
  let transportMode: MailEngineTransportMode
}

enum MailEngineAuthorization: Equatable, Sendable {
  case password(username: String, password: String)
  case xoauth2(username: String, accessToken: String)
}

struct MailEngineConfiguration: Equatable, Sendable {
  let authorization: MailEngineAuthorization
  let connectionID: String
  let imapEndpoint: MailEngineEndpoint
  let minimumTLSVersion: MailEngineTLSVersion
  let smtpEndpoint: MailEngineEndpoint

  init(
    authorization: MailEngineAuthorization,
    connectionID: String,
    imapEndpoint: MailEngineEndpoint,
    minimumTLSVersion: MailEngineTLSVersion = .tls12,
    smtpEndpoint: MailEngineEndpoint
  ) {
    self.authorization = authorization
    self.connectionID = connectionID
    self.imapEndpoint = imapEndpoint
    self.minimumTLSVersion = max(minimumTLSVersion, .tls12)
    self.smtpEndpoint = smtpEndpoint
  }
}

enum MailEngineCapability: Codable, Equatable, Hashable, Sendable {
  case idle
  case move
  case specialUse
  case uidPlus
}

enum MailEngineSpecialUse: Equatable, Hashable, Sendable {
  case archive
  case drafts
  case sent
  case spam
  case trash
}

struct MailEngineMailbox: Equatable, Hashable, Sendable {
  let identity: MailEngineMailboxIdentity
  let specialUses: Set<MailEngineSpecialUse>
}

struct MailEngineConnectionSnapshot: Equatable, Sendable {
  let capabilities: Set<MailEngineCapability>
  let mailboxes: [MailEngineMailbox]
  let minimumTLSVersions: [MailEngineService: MailEngineTLSVersion]

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.capabilities == rhs.capabilities
      && Dictionary(grouping: lhs.mailboxes, by: \.self).mapValues(\.count)
        == Dictionary(grouping: rhs.mailboxes, by: \.self).mapValues(\.count)
      && lhs.minimumTLSVersions == rhs.minimumTLSVersions
  }
}

enum MailEngineError: Error, Equatable, Sendable {
  case authenticationRejected
  case cancelled
  case certificateRejected
  case connectionClosed
  case operationUnsupported
  case operationOutcomeUnknown
  case protocolRejected(code: String, retryable: Bool)
  case serverIdentityMismatch
  case staleMessageIdentity
  case startTLSRejected
  case tlsVersionUnsupported
}

struct MailEngineMessageMetadata: Equatable, Sendable {
  let calendarInvitationPart: MailEngineBodyPartDescriptor?
  let ccRecipients: [String]
  let flags: Set<String>
  let from: String?
  let hasAttachments: Bool
  let headerFields: [MailEngineHeaderField]
  let identity: MailEngineMessageIdentity
  let inReplyTo: String?
  let internalDate: Date
  let references: [String]
  let replyTo: String?
  let rfcMessageID: String?
  let subject: String
  let toRecipients: [String]

  init(
    flags: Set<String>,
    identity: MailEngineMessageIdentity,
    internalDate: Date,
    rfcMessageID: String?,
    calendarInvitationPart: MailEngineBodyPartDescriptor? = nil,
    ccRecipients: [String] = [],
    from: String? = nil,
    hasAttachments: Bool = false,
    headerFields: [MailEngineHeaderField] = [],
    inReplyTo: String? = nil,
    references: [String] = [],
    replyTo: String? = nil,
    subject: String = "",
    toRecipients: [String] = []
  ) {
    self.calendarInvitationPart = calendarInvitationPart
    self.ccRecipients = ccRecipients
    self.flags = flags
    self.from = from
    self.hasAttachments = hasAttachments
    self.headerFields = headerFields
    self.identity = identity
    self.inReplyTo = inReplyTo
    self.internalDate = internalDate
    self.references = references
    self.replyTo = replyTo
    self.rfcMessageID = rfcMessageID
    self.subject = subject
    self.toRecipients = toRecipients
  }
}

struct MailEngineMetadataPage: Equatable, Sendable {
  let messages: [MailEngineMessageMetadata]
  let nextOlderUID: Int64?
  let uidValidity: Int64
}

struct MailEngineBodyPartSelector: Equatable, Hashable, Sendable {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

struct MailEngineBodyPartDescriptor: Equatable, Sendable {
  let byteCount: Int
  let contentTransferEncoding: String?
  let mimeType: String
  let selector: MailEngineBodyPartSelector
}

struct MailEngineBodyPart: Equatable, Sendable {
  let data: Data
  let selector: MailEngineBodyPartSelector
}

enum MailEngineIdleEvent: Equatable, Sendable {
  case changedUIDs([Int64])
  case mailboxReset(uidValidity: Int64)
}

enum MailEngineFlagMutation: Equatable, Sendable {
  case add
  case remove
}

struct MailEngineUIDPair: Codable, Equatable, Sendable {
  let destinationUID: Int64
  let sourceUID: Int64
}

struct MailEngineReportedUIDMapping: Equatable, Sendable {
  let destinationUIDValidity: Int64
  let destinationUIDs: [Int64]
  let sourceUIDs: [Int64]
}

enum MailEngineUIDMappingError: Error, Equatable {
  case invalidDestinationUIDValidity
  case invalidSourceUIDValidity
  case invalidUID
  case mismatchedCardinality
  case mismatchedSourceUIDs
  case repeatedUID
}

struct MailEngineUIDMapping: Codable, Equatable, Sendable {
  let destinationMailbox: MailEngineMailboxIdentity
  let destinationUIDValidity: Int64
  let pairs: [MailEngineUIDPair]
  let sourceMailbox: MailEngineMailboxIdentity
  let sourceUIDValidity: Int64

  static func validated(
    sourceMailbox: MailEngineMailboxIdentity,
    sourceUIDValidity: Int64,
    destinationMailbox: MailEngineMailboxIdentity,
    requestedSourceUIDs: [Int64],
    reported: MailEngineReportedUIDMapping
  ) throws -> MailEngineUIDMapping {
    guard sourceUIDValidity > 0 && sourceUIDValidity <= 4_294_967_295 else {
      throw MailEngineUIDMappingError.invalidSourceUIDValidity
    }
    guard
      reported.destinationUIDValidity > 0
        && reported.destinationUIDValidity <= 4_294_967_295
    else {
      throw MailEngineUIDMappingError.invalidDestinationUIDValidity
    }
    guard reported.sourceUIDs.count == reported.destinationUIDs.count else {
      throw MailEngineUIDMappingError.mismatchedCardinality
    }
    guard
      !requestedSourceUIDs.isEmpty,
      !reported.sourceUIDs.isEmpty,
      !reported.destinationUIDs.isEmpty
    else {
      throw MailEngineUIDMappingError.invalidUID
    }
    guard
      reported.sourceUIDs.allSatisfy({ $0 > 0 && $0 <= 4_294_967_295 }),
      reported.destinationUIDs.allSatisfy({ $0 > 0 && $0 <= 4_294_967_295 })
    else {
      throw MailEngineUIDMappingError.invalidUID
    }
    guard Set(reported.sourceUIDs).count == reported.sourceUIDs.count,
      Set(reported.destinationUIDs).count == reported.destinationUIDs.count
    else {
      throw MailEngineUIDMappingError.repeatedUID
    }
    guard Set(reported.sourceUIDs) == Set(requestedSourceUIDs),
      requestedSourceUIDs.count == reported.sourceUIDs.count
    else {
      throw MailEngineUIDMappingError.mismatchedSourceUIDs
    }
    return MailEngineUIDMapping(
      destinationMailbox: destinationMailbox,
      destinationUIDValidity: reported.destinationUIDValidity,
      pairs: zip(reported.sourceUIDs, reported.destinationUIDs).map {
        MailEngineUIDPair(destinationUID: $0.1, sourceUID: $0.0)
      },
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity
    )
  }
}

struct MailEngineEnvelope: Equatable, Sendable {
  let recipients: [String]
  let sender: String
}

struct MailEngineOutgoingMessage: Equatable, Sendable {
  let body: String
  let inReplyTo: String?
  let messageID: String
  let recipients: [String]
  let requestsReadReceipt: Bool
  let sender: String
  let subject: String
}

enum MailEnginePreSubmissionFailure: Equatable, Sendable {
  case authentication
  case dataRejected(code: Int)
  case recipientRejected(code: Int)
  case senderRejected(code: Int)
  case transportUnavailable
}

enum MailEngineSMTPOutcome: Equatable, Sendable {
  case accepted(serverMessageID: String?)
  case ambiguous
  case notSubmitted(MailEnginePreSubmissionFailure)
  case permanentlyRejected(code: Int)
  case transientlyRejected(code: Int)
}

enum MailEngineDiagnosticEvent: Equatable, Sendable {
  case connected
  case disconnected
  case operationFailed
}

protocol MailEngineProductionLogSinking: Sendable {
  func record(_ event: MailEngineDiagnosticEvent)
}

protocol MailEngineLogging: Sendable {
  func record(_ event: MailEngineDiagnosticEvent)
  func recordProtocolTrace(_ trace: Data)
}

struct PrivacyPreservingMailEngineLogger: MailEngineLogging {
  private let sink: any MailEngineProductionLogSinking

  init(sink: any MailEngineProductionLogSinking) {
    self.sink = sink
  }

  func record(_ event: MailEngineDiagnosticEvent) {
    sink.record(event)
  }

  func recordProtocolTrace(_: Data) {
    // Protocol traces may contain credentials, mailbox identifiers, or message content.
  }
}

protocol MailEngine: Sendable {
  func connect(
    configuration: MailEngineConfiguration,
    logger: any MailEngineLogging
  ) async throws -> (snapshot: MailEngineConnectionSnapshot, session: any MailEngineSession)
}

protocol MailEngineSession: Sendable {
  func appendToSent(
    _ rawMessage: Data,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineMessageIdentity

  func close() async

  func copy(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping

  func deletePermanently(
    _ messages: [MailEngineMessageIdentity]
  ) async throws

  func fetchBodyParts(
    _ selectors: Set<MailEngineBodyPartSelector>,
    for message: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart]

  func fetchDecodedBodyPart(
    _ part: MailEngineBodyPartDescriptor,
    for message: MailEngineMessageIdentity,
    maximumByteCount: Int
  ) async throws -> Data

  func idle(
    mailbox: MailEngineMailboxIdentity,
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws

  func containsMessage(
    rfcMessageID: String,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> Bool

  func loadTextBody(
    for message: MailEngineMessageIdentity
  ) async throws -> String

  func loadRawMessage(
    for message: MailEngineMessageIdentity,
    maximumByteCount: Int
  ) async throws -> Data

  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage

  func move(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping

  func renderMessage(
    _ message: MailEngineOutgoingMessage
  ) async throws -> Data

  func submit(
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome

  func updateFlags(
    _ flags: Set<String>,
    on messages: [MailEngineMessageIdentity],
    mutation: MailEngineFlagMutation
  ) async throws
}

extension MailEngineSession {
  func loadRawMessage(
    for _: MailEngineMessageIdentity,
    maximumByteCount _: Int
  ) async throws -> Data {
    throw MailEngineError.operationUnsupported
  }

  func fetchDecodedBodyPart(
    _: MailEngineBodyPartDescriptor,
    for _: MailEngineMessageIdentity,
    maximumByteCount _: Int
  ) async throws -> Data {
    throw MailEngineError.operationUnsupported
  }

  func deletePermanently(
    _: [MailEngineMessageIdentity]
  ) async throws {
    throw MailEngineError.operationUnsupported
  }

  func containsMessage(
    rfcMessageID _: String,
    mailbox _: MailEngineMailboxIdentity
  ) async throws -> Bool {
    throw MailEngineError.operationUnsupported
  }

  func loadTextBody(
    for _: MailEngineMessageIdentity
  ) async throws -> String {
    throw MailEngineError.operationUnsupported
  }

  func renderMessage(
    _: MailEngineOutgoingMessage
  ) async throws -> Data {
    throw MailEngineError.operationUnsupported
  }

  func updateFlags(
    _: Set<String>,
    on _: [MailEngineMessageIdentity],
    mutation _: MailEngineFlagMutation
  ) async throws {
    throw MailEngineError.operationUnsupported
  }
}
