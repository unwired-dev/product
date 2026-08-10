import Foundation
import SwiftMail

// swiftlint:disable file_length type_body_length

enum SwiftMailExperimentalBuildPolicy {
  static let dependencyVersion = "1.10.0"
  static let dependencyRevision = "c907f871bb23812895274f4c7ae17bf343171c1e"
  static let providerCertificationIssue = 280

  // This must be changed only after #280 records passing iCloud Mail and Fastmail evidence.
  static let providerCertificationComplete = false

  static var isEnabled: Bool {
    #if DEBUG || TESTING || UNWIRED_INTERNAL_SWIFTMAIL
      true
    #else
      providerCertificationComplete
    #endif
  }
}

struct ExperimentalSwiftMailEngine: MailEngine {
  func connect(
    configuration: MailEngineConfiguration,
    logger: any MailEngineLogging
  ) async throws -> (snapshot: MailEngineConnectionSnapshot, session: any MailEngineSession) {
    guard SwiftMailExperimentalBuildPolicy.isEnabled else {
      throw MailEngineError.operationUnsupported
    }

    let imap = IMAPServer(
      host: configuration.imapEndpoint.hostname,
      port: configuration.imapEndpoint.port,
      transportSecurity: Self.transportSecurity(configuration.imapEndpoint.transportMode),
      certificateVerificationPolicy: .fullVerification,
      minimumTLSVersion: Self.minimumTLSVersion(configuration.minimumTLSVersion)
    )
    let smtp = Self.makeSMTPServer(configuration: configuration)

    do {
      async let imapSetup: Void = Self.connect(
        imap: imap,
        authorization: configuration.authorization
      )
      async let smtpSetup: Void = Self.connect(
        smtp: smtp,
        authorization: configuration.authorization
      )
      _ = try await (imapSetup, smtpSetup)

      let capabilityNames = try await imap.fetchCapabilities().map {
        String(describing: $0).uppercased()
      }
      let mailboxes = try await imap.listMailboxes()
      let snapshot = MailEngineConnectionSnapshot(
        capabilities: Self.capabilities(capabilityNames, mailboxes: mailboxes),
        mailboxes: mailboxes.map(Self.mailbox),
        transportSecurity: [
          .imap: configuration.minimumTLSVersion,
          .smtp: configuration.minimumTLSVersion,
        ]
      )
      logger.record(.connected)
      return (
        snapshot,
        SwiftMailEngineSession(
          capabilities: snapshot.capabilities,
          configuration: configuration,
          imap: imap,
          logger: logger,
          smtp: smtp
        )
      )
    } catch {
      try? await imap.disconnect()
      try? await smtp.disconnect()
      logger.record(.operationFailed)
      throw Self.connectionError(error)
    }
  }

  fileprivate static func makeSMTPServer(configuration: MailEngineConfiguration) -> SMTPServer {
    SMTPServer(
      host: configuration.smtpEndpoint.hostname,
      port: configuration.smtpEndpoint.port,
      transportSecurity: transportSecurity(configuration.smtpEndpoint.transportMode),
      certificateVerificationPolicy: .fullVerification,
      minimumTLSVersion: minimumTLSVersion(configuration.minimumTLSVersion)
    )
  }

  fileprivate static func connect(
    imap: IMAPServer,
    authorization: MailEngineAuthorization
  ) async throws {
    try await imap.connect()
    switch authorization {
    case .password(let username, let password):
      try await imap.login(username: username, password: password)
    case .xoauth2(let username, let accessToken):
      try await imap.authenticateXOAUTH2(email: username, accessToken: accessToken)
    }
  }

  fileprivate static func connect(
    smtp: SMTPServer,
    authorization: MailEngineAuthorization
  ) async throws {
    try await smtp.connect()
    switch authorization {
    case .password(let username, let password):
      try await smtp.login(username: username, password: password)
    case .xoauth2(let username, let accessToken):
      try await smtp.authenticateXOAUTH2(email: username, accessToken: accessToken)
    }
  }

  private static func capabilities(
    _ names: [String],
    mailboxes: [Mailbox.Info]
  ) -> Set<MailEngineCapability> {
    var result: Set<MailEngineCapability> = []
    if names.contains(where: { $0.contains("IDLE") }) { result.insert(.idle) }
    if names.contains(where: { $0.contains("MOVE") }) { result.insert(.move) }
    if names.contains(where: { $0.contains("SPECIAL") })
      || mailboxes.contains(where: { !specialUses($0.attributes).isEmpty })
    {
      result.insert(.specialUse)
    }
    if names.contains(where: { $0.contains("UIDPLUS") }) { result.insert(.uidPlus) }
    return result
  }

  private static func mailbox(_ mailbox: Mailbox.Info) -> MailEngineMailbox {
    MailEngineMailbox(
      identity: MailEngineMailboxIdentity(mailbox.name),
      specialUses: specialUses(mailbox.attributes)
    )
  }

  private static func specialUses(
    _ attributes: Mailbox.Info.Attributes
  ) -> Set<MailEngineSpecialUse> {
    var result: Set<MailEngineSpecialUse> = []
    if attributes.contains(.archive) { result.insert(.archive) }
    if attributes.contains(.drafts) { result.insert(.drafts) }
    if attributes.contains(.sent) { result.insert(.sent) }
    if attributes.contains(.junk) { result.insert(.spam) }
    if attributes.contains(.trash) { result.insert(.trash) }
    return result
  }

  fileprivate static func transportSecurity(
    _ mode: MailEngineTransportMode
  ) -> SwiftMail.MailTransportSecurity {
    switch mode {
    case .implicitTLS: .implicitTLS
    case .startTLS: .startTLS
    }
  }

  fileprivate static func minimumTLSVersion(
    _ version: MailEngineTLSVersion
  ) -> MailTLSMinimumVersion {
    switch version {
    case .tls10, .tls11, .tls12: .tlsv12
    case .tls13: .tlsv13
    }
  }

  fileprivate static func connectionError(_ error: Error) -> MailEngineError {
    if error is CancellationError { return .cancelled }
    if let error = error as? IMAPError {
      switch error {
      case .authFailed, .loginFailed, .unsupportedAuthMechanism:
        return .authenticationRejected
      case .commandNotSupported:
        return .operationUnsupported
      default:
        return .connectionClosed
      }
    }
    if let error = error as? SMTPError {
      switch error {
      case .authenticationFailed:
        return .authenticationRejected
      case .tlsFailed:
        return .tlsVersionUnsupported
      default:
        return .connectionClosed
      }
    }
    return .connectionClosed
  }
}

actor SwiftMailEngineSession: MailEngineSession {
  private struct SelectedMessages {
    let mailbox: MailEngineMailboxIdentity
    let uidValidity: Int64
    let uids: UIDSet
  }

  private let capabilities: Set<MailEngineCapability>
  private let configuration: MailEngineConfiguration
  private let imap: IMAPServer
  private let logger: any MailEngineLogging
  private var smtp: SMTPServer
  private var smtpNeedsReconnect = false
  private var uidValidityByMailbox: [MailEngineMailboxIdentity: Int64] = [:]
  private var isClosed = false

  init(
    capabilities: Set<MailEngineCapability>,
    configuration: MailEngineConfiguration,
    imap: IMAPServer,
    logger: any MailEngineLogging,
    smtp: SMTPServer
  ) {
    self.capabilities = capabilities
    self.configuration = configuration
    self.imap = imap
    self.logger = logger
    self.smtp = smtp
  }

  func appendToSent(
    _ rawMessage: Data,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineMessageIdentity {
    try ensureOpen()
    try Task.checkCancellation()
    guard let message = String(data: rawMessage, encoding: .utf8) else {
      throw MailEngineError.protocolRejected(code: "INVALID-MIME", retryable: false)
    }
    do {
      let result = try await imap.append(
        rawMessage: message,
        to: mailbox.rawValue,
        flags: [],
        internalDate: nil
      )
      guard result.uids.count == 1, let uid = result.firstUID, let uidValidity = result.uidValidity,
        uid.value > 0, uidValidity.value > 0
      else {
        throw MailEngineUIDMappingError.invalidUID
      }
      return MailEngineMessageIdentity(
        connectionID: configuration.connectionID,
        mailbox: mailbox,
        uid: Int64(uid.value),
        uidValidity: Int64(uidValidity.value)
      )
    } catch let error as MailEngineUIDMappingError {
      throw error
    } catch {
      throw Self.mutationError(error)
    }
  }

  func close() async {
    guard !isClosed else { return }
    isClosed = true
    try? await imap.disconnect()
    try? await smtp.disconnect()
    logger.record(.disconnected)
  }

  func copy(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    let source = try await select(messages)
    do {
      let reported = try await imap.copy(
        messages: source.uids,
        to: destinationMailbox.rawValue
      )
      return try Self.mapping(
        reported,
        sourceMailbox: source.mailbox,
        sourceUIDValidity: source.uidValidity,
        requestedSourceUIDs: messages.map(\.uid),
        destinationMailbox: destinationMailbox
      )
    } catch let error as MailEngineUIDMappingError {
      throw error
    } catch {
      throw Self.mutationError(error)
    }
  }

  func fetchBodyParts(
    _ selectors: Set<MailEngineBodyPartSelector>,
    for message: MailEngineMessageIdentity
  ) async throws -> [MailEngineBodyPart] {
    _ = try await select([message])
    do {
      var parts: [MailEngineBodyPart] = []
      for selector in selectors.sorted(by: { $0.rawValue < $1.rawValue }) {
        try Task.checkCancellation()
        let data = try await imap.fetchPart(
          section: Section(selector.rawValue),
          of: SwiftMail.UID(UInt32(message.uid))
        )
        parts.append(MailEngineBodyPart(data: data, selector: selector))
      }
      return parts
    } catch is CancellationError {
      throw MailEngineError.cancelled
    } catch {
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  func idle(
    mailbox: MailEngineMailboxIdentity,
    onEvent: @escaping @Sendable (MailEngineIdleEvent) async -> Void
  ) async throws {
    try ensureOpen()
    let selection = try await imap.selectMailbox(mailbox.rawValue)
    let initialUIDValidity = Int64(selection.uidValidity.value)
    guard initialUIDValidity > 0 else {
      throw MailEngineUIDMappingError.invalidSourceUIDValidity
    }
    uidValidityByMailbox[mailbox] = initialUIDValidity
    let session = try await imap.idle(on: mailbox.rawValue)

    do {
      try await withTaskCancellationHandler {
        for await event in session.events {
          try Task.checkCancellation()
          if let changedUIDs = Self.changedUIDs(event) {
            guard changedUIDs.allSatisfy({ $0 > 0 }) else {
              throw MailEngineUIDMappingError.invalidUID
            }
            await onEvent(.changedUIDs(changedUIDs))
          } else if Self.requiresMailboxRefresh(event) {
            let refreshed = try await imap.selectMailbox(mailbox.rawValue)
            let refreshedUIDValidity = Int64(refreshed.uidValidity.value)
            guard refreshedUIDValidity > 0 else {
              throw MailEngineUIDMappingError.invalidSourceUIDValidity
            }
            if uidValidityByMailbox[mailbox] != refreshedUIDValidity {
              uidValidityByMailbox[mailbox] = refreshedUIDValidity
              await onEvent(.mailboxReset(uidValidity: refreshedUIDValidity))
            } else {
              await onEvent(.changedUIDs([]))
            }
          }
        }
        try Task.checkCancellation()
      } onCancel: {
        Task { try? await session.done() }
      }
      try await session.done()
    } catch is CancellationError {
      try? await session.done()
      throw MailEngineError.cancelled
    } catch {
      try? await session.done()
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage {
    try ensureOpen()
    try Self.validatePage(beforeUID: beforeUID, limit: limit)

    do {
      let uidValidity = Int64(try await imap.selectMailbox(mailbox.rawValue).uidValidity.value)
      guard uidValidity > 0 else { throw MailEngineUIDMappingError.invalidSourceUIDValidity }
      uidValidityByMailbox[mailbox] = uidValidity

      let result: ExtendedSearchResult<SwiftMail.UID> = try await imap.extendedSearch(
        criteria: [.all]
      )
      let searchedUIDs =
        result.all?.toArray() ?? result.partial?.results.toArray()
        ?? result.ordered ?? []
      let eligibleUIDs =
        searchedUIDs
        .map { Int64($0.value) }
        .filter { uid in beforeUID.map { uid < $0 } ?? true }
        .sorted(by: >)
      let pageUIDs = Array(eligibleUIDs.prefix(limit))
      guard !pageUIDs.isEmpty else {
        return MailEngineMetadataPage(messages: [], nextOlderUID: nil, uidValidity: uidValidity)
      }

      let infos = try await imap.fetchMessageInfosBulk(
        using: UIDSet(pageUIDs.map { SwiftMail.UID(UInt32($0)) }),
        options: .slim
      )
      let messages = try infos.map {
        try Self.metadata(
          $0,
          connectionID: configuration.connectionID,
          mailbox: mailbox,
          uidValidity: uidValidity
        )
      }.sorted { $0.identity.uid > $1.identity.uid }
      guard messages.map({ $0.identity.uid }) == pageUIDs else {
        throw MailEngineError.protocolRejected(code: "UID-SET-MISMATCH", retryable: false)
      }
      return MailEngineMetadataPage(
        messages: messages,
        nextOlderUID: eligibleUIDs.count > pageUIDs.count ? pageUIDs.last : nil,
        uidValidity: uidValidity
      )
    } catch let error as MailEngineUIDMappingError {
      throw error
    } catch let error as MailEngineError {
      throw error
    } catch is CancellationError {
      throw MailEngineError.cancelled
    } catch {
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  func move(
    messages: [MailEngineMessageIdentity],
    to destinationMailbox: MailEngineMailboxIdentity
  ) async throws -> MailEngineUIDMapping {
    let source = try await select(messages)
    guard capabilities.contains(.uidPlus) else {
      throw MailEngineError.operationUnsupported
    }

    do {
      if capabilities.contains(.move) {
        let reported = try await imap.move(
          messages: source.uids,
          to: destinationMailbox.rawValue
        )
        return try Self.mapping(
          reported,
          sourceMailbox: source.mailbox,
          sourceUIDValidity: source.uidValidity,
          requestedSourceUIDs: messages.map(\.uid),
          destinationMailbox: destinationMailbox
        )
      }

      let reported = try await imap.copy(
        messages: source.uids,
        to: destinationMailbox.rawValue
      )
      let mapping = try Self.mapping(
        reported,
        sourceMailbox: source.mailbox,
        sourceUIDValidity: source.uidValidity,
        requestedSourceUIDs: messages.map(\.uid),
        destinationMailbox: destinationMailbox
      )
      try await imap.store(flags: [.deleted], on: source.uids, operation: .add)
      try await imap.expunge(messages: source.uids)
      return mapping
    } catch let error as MailEngineUIDMappingError {
      throw error
    } catch {
      throw Self.mutationError(error)
    }
  }

  func submit(
    envelope: MailEngineEnvelope,
    rawMessage: Data
  ) async throws -> MailEngineSMTPOutcome {
    try ensureOpen()
    try Task.checkCancellation()
    if smtpNeedsReconnect { try await reconnectSMTP() }

    do {
      _ = try await smtp.sendRawMessage(
        rawMessage,
        from: EmailAddress(address: envelope.sender),
        to: envelope.recipients.map { EmailAddress(address: $0) }
      )
      return .accepted(serverMessageID: nil)
    } catch let error as SMTPSendError {
      if error.acceptance == .ambiguous || Self.invalidatesSMTP(error.reason) {
        smtpNeedsReconnect = true
      }
      return Self.smtpOutcome(error)
    } catch is CancellationError {
      smtpNeedsReconnect = true
      return .notSubmitted(.transportUnavailable)
    } catch let error as SMTPError {
      switch error {
      case .authenticationFailed:
        smtpNeedsReconnect = true
        return .notSubmitted(.authentication)
      case .unexpectedResponse(let response):
        return Self.responseOutcome(response.code)
      default:
        smtpNeedsReconnect = true
        return .notSubmitted(.transportUnavailable)
      }
    } catch {
      smtpNeedsReconnect = true
      return .notSubmitted(.transportUnavailable)
    }
  }

  private func ensureOpen() throws {
    guard !isClosed else { throw MailEngineError.connectionClosed }
  }

  private static func validatePage(beforeUID: Int64?, limit: Int) throws {
    guard (1...500).contains(limit),
      beforeUID.map({ (1...Int64(UInt32.max)).contains($0) }) ?? true
    else {
      throw MailEngineError.protocolRejected(code: "INVALID-PAGE", retryable: false)
    }
  }

  private func reconnectSMTP() async throws {
    try? await smtp.disconnect()
    let replacement = ExperimentalSwiftMailEngine.makeSMTPServer(configuration: configuration)
    do {
      try await ExperimentalSwiftMailEngine.connect(
        smtp: replacement,
        authorization: configuration.authorization
      )
      smtp = replacement
      smtpNeedsReconnect = false
    } catch {
      try? await replacement.disconnect()
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  private func select(
    _ messages: [MailEngineMessageIdentity]
  ) async throws -> SelectedMessages {
    try ensureOpen()
    try Task.checkCancellation()
    guard let first = messages.first,
      first.connectionID == configuration.connectionID,
      (1...Int64(UInt32.max)).contains(first.uid),
      (1...Int64(UInt32.max)).contains(first.uidValidity),
      messages.allSatisfy({
        $0.connectionID == first.connectionID && $0.mailbox == first.mailbox
          && $0.uidValidity == first.uidValidity && (1...Int64(UInt32.max)).contains($0.uid)
      })
    else {
      throw MailEngineError.staleMessageIdentity
    }

    let selection = try await imap.selectMailbox(first.mailbox.rawValue)
    let currentUIDValidity = Int64(selection.uidValidity.value)
    uidValidityByMailbox[first.mailbox] = currentUIDValidity
    guard currentUIDValidity == first.uidValidity else {
      throw MailEngineError.staleMessageIdentity
    }
    return SelectedMessages(
      mailbox: first.mailbox,
      uidValidity: first.uidValidity,
      uids: UIDSet(messages.map { SwiftMail.UID(UInt32($0.uid)) })
    )
  }

  private static func mapping(
    _ mapping: CopyUID?,
    sourceMailbox: MailEngineMailboxIdentity,
    sourceUIDValidity: Int64,
    requestedSourceUIDs: [Int64],
    destinationMailbox: MailEngineMailboxIdentity
  ) throws -> MailEngineUIDMapping {
    guard let mapping else { throw MailEngineUIDMappingError.invalidUID }
    return try MailEngineUIDMapping.validated(
      sourceMailbox: sourceMailbox,
      sourceUIDValidity: sourceUIDValidity,
      destinationMailbox: destinationMailbox,
      requestedSourceUIDs: requestedSourceUIDs,
      reported: MailEngineReportedUIDMapping(
        destinationUIDValidity: Int64(mapping.destinationUIDValidity.value),
        destinationUIDs: mapping.mapping.map { Int64($0.destination.value) },
        sourceUIDs: mapping.mapping.map { Int64($0.source.value) }
      )
    )
  }

  private static func metadata(
    _ info: MessageInfo,
    connectionID: String,
    mailbox: MailEngineMailboxIdentity,
    uidValidity: Int64
  ) throws -> MailEngineMessageMetadata {
    guard let uid = info.uid, uid.value > 0 else {
      throw MailEngineUIDMappingError.invalidUID
    }
    return MailEngineMessageMetadata(
      flags: Set(info.flags.map(flag)),
      identity: MailEngineMessageIdentity(
        connectionID: connectionID,
        mailbox: mailbox,
        uid: Int64(uid.value),
        uidValidity: uidValidity
      ),
      internalDate: info.internalDate ?? info.date ?? .distantPast,
      rfcMessageID: info.messageId?.description
    )
  }

  private static func flag(_ flag: Flag) -> String {
    switch flag {
    case .seen: "\\Seen"
    case .answered: "\\Answered"
    case .flagged: "\\Flagged"
    case .deleted: "\\Deleted"
    case .draft: "\\Draft"
    case .custom(let value): value
    }
  }

  private static func changedUIDs(_ event: IMAPServerEvent) -> [Int64]? {
    switch event {
    case .fetchUID(let uid, _):
      [Int64(uid.value)]
    case .vanished(let uids):
      uids.toArray().map { Int64($0.value) }
    default:
      nil
    }
  }

  private static func requiresMailboxRefresh(_ event: IMAPServerEvent) -> Bool {
    switch event {
    case .exists, .expunge, .fetch, .flags, .recent:
      true
    case .alert, .bye, .capability, .fetchUID, .vanished:
      false
    }
  }

  private static func mutationError(_ error: Error) -> MailEngineError {
    if error is CancellationError { return .operationOutcomeUnknown }
    if let error = error as? IMAPError {
      switch error {
      case .commandNotSupported:
        return .operationUnsupported
      case .copyFailed, .moveFailed, .storeFailed, .expungeFailed, .commandFailed:
        return .protocolRejected(code: "IMAP-NO", retryable: false)
      case .connectionFailed, .timeout:
        return .operationOutcomeUnknown
      default:
        return ExperimentalSwiftMailEngine.connectionError(error)
      }
    }
    return .operationOutcomeUnknown
  }

  nonisolated static func smtpOutcome(_ error: SMTPSendError) -> MailEngineSMTPOutcome {
    switch error.acceptance {
    case .ambiguous:
      return .ambiguous
    case .rejectedTransiently:
      return .transientlyRejected(code: error.response?.code ?? 400)
    case .rejectedPermanently:
      return .permanentlyRejected(code: error.response?.code ?? 500)
    case .notAccepted:
      let code = error.response?.code ?? 0
      switch error.phase {
      case .mailFrom:
        return .notSubmitted(.senderRejected(code: code))
      case .rcptTo:
        return .notSubmitted(.recipientRejected(code: code))
      case .data:
        return .notSubmitted(.dataRejected(code: code))
      case .content:
        return .notSubmitted(.transportUnavailable)
      }
    }
  }

  private static func responseOutcome(_ code: Int) -> MailEngineSMTPOutcome {
    if (400...499).contains(code) { return .transientlyRejected(code: code) }
    if (500...599).contains(code) { return .permanentlyRejected(code: code) }
    return .notSubmitted(.transportUnavailable)
  }

  private static func invalidatesSMTP(_ reason: SMTPSendError.Reason) -> Bool {
    switch reason {
    case .cancelled, .connectionLost, .timedOut, .transport:
      true
    case .reply:
      false
    }
  }
}
