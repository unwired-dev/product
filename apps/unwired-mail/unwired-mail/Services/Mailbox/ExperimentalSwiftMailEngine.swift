import Foundation
import OSLog
import SwiftMail
import SwiftSoup

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

    let imap = Self.makeIMAPServer(configuration: configuration)
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
        minimumTLSVersions: [
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

  fileprivate static func makeIMAPServer(configuration: MailEngineConfiguration) -> IMAPServer {
    IMAPServer(
      host: configuration.imapEndpoint.hostname,
      port: configuration.imapEndpoint.port,
      transportSecurity: transportSecurity(configuration.imapEndpoint.transportMode),
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

  static func capabilities(
    _ names: [String],
    mailboxes: [Mailbox.Info]
  ) -> Set<MailEngineCapability> {
    var result: Set<MailEngineCapability> = []
    if names.contains("IDLE") { result.insert(.idle) }
    if names.contains("MOVE") { result.insert(.move) }
    if names.contains("SPECIAL-USE")
      || mailboxes.contains(where: { !specialUses($0.attributes).isEmpty })
    {
      result.insert(.specialUse)
    }
    if names.contains("UIDPLUS") { result.insert(.uidPlus) }
    return result
  }

  fileprivate static func mailbox(_ mailbox: Mailbox.Info) -> MailEngineMailbox {
    MailEngineMailbox(
      identity: MailEngineMailboxIdentity(mailbox.name),
      specialUses: specialUses(mailbox.attributes)
    )
  }

  fileprivate static func specialUses(
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

  static func connectionError(_ error: Error) -> MailEngineError {
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
    try await ensureIMAPConnection()
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

  func deletePermanently(
    _ messages: [MailEngineMessageIdentity]
  ) async throws {
    guard capabilities.contains(.uidPlus) else {
      throw MailEngineError.operationUnsupported
    }
    let source = try await select(messages)
    do {
      try await imap.store(flags: [.deleted], on: source.uids, operation: .add)
      try await imap.expunge(messages: source.uids)
    } catch {
      throw Self.mutationError(error)
    }
  }

  func containsMessage(
    rfcMessageID: String,
    mailbox: MailEngineMailboxIdentity
  ) async throws -> Bool {
    try await ensureIMAPConnection()
    guard Self.isSafeHeaderValue(rfcMessageID) else {
      throw MailEngineError.protocolRejected(code: "INVALID-MESSAGE-ID", retryable: false)
    }
    do {
      _ = try await imap.selectMailbox(mailbox.rawValue)
      let result: ExtendedSearchResult<SwiftMail.UID> = try await imap.extendedSearch(
        criteria: [.header("Message-ID", rfcMessageID)]
      )
      let matchCount =
        result.count
        ?? result.all?.toArray().count
        ?? result.partial?.results.toArray().count
        ?? result.ordered?.count
        ?? 0
      return matchCount > 0
    } catch is CancellationError {
      throw MailEngineError.cancelled
    } catch {
      throw ExperimentalSwiftMailEngine.connectionError(error)
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
    try await ensureIMAPConnection()
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

  func loadAttachment(
    _ selector: MailEngineBodyPartSelector,
    for message: MailEngineMessageIdentity,
    maximumByteCount: Int
  ) async throws -> Data {
    do {
      let bodyStructure = try await messageInfo(for: message)
      let swiftMailMessage = Message(
        header: bodyStructure.info,
        parts: bodyStructure.info.parts
      )
      guard
        let selected = SwiftMailMessageContentLoader.attachment(
          with: selector,
          in: swiftMailMessage,
          maximumDecodedByteCount: maximumByteCount
        )
      else {
        throw MailEngineError.protocolRejected(
          code: "INVALID-ATTACHMENT",
          retryable: false
        )
      }
      return try await SwiftMailMessageContentLoader.attachmentData(
        for: selected.part,
        maximumDecodedByteCount: maximumByteCount
      ) { part in
        try await self.imap.fetchPart(
          section: part.section,
          of: bodyStructure.uid
        )
      }
    } catch let error as MailEngineError {
      throw error
    } catch is CancellationError {
      throw MailEngineError.cancelled
    } catch {
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  func loadTextBody(
    for message: MailEngineMessageIdentity
  ) async throws -> String {
    do {
      let bodyStructure = try await messageInfo(for: message)
      guard var bodyPart = Self.preferredBodyPart(bodyStructure.info.parts) else {
        throw MailEngineError.protocolRejected(code: "UNSUPPORTED-BODY", retryable: false)
      }
      bodyPart.data = try await imap.fetchPart(
        section: bodyPart.section,
        of: bodyStructure.uid
      )
      guard let body = bodyPart.textContent else {
        throw MailEngineError.protocolRejected(code: "UNSUPPORTED-BODY", retryable: false)
      }
      return bodyPart.contentType.lowercased().hasPrefix("text/html")
        ? Self.plainText(fromHTML: body) : body
    } catch let error as MailEngineError {
      throw error
    } catch is CancellationError {
      throw MailEngineError.cancelled
    } catch {
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  func loadMessageContent(
    for message: MailEngineMessageIdentity,
    maximumAttachmentByteCount: Int
  ) async throws -> MailEngineMessageContent {
    do {
      let bodyStructure = try await messageInfo(for: message)
      let swiftMailMessage = Message(
        header: bodyStructure.info,
        parts: bodyStructure.info.parts
      )
      return try await SwiftMailMessageContentLoader.messageContent(
        in: swiftMailMessage,
        maximumAttachmentByteCount: maximumAttachmentByteCount
      ) { bodyPart in
        try await self.imap.fetchPart(
          section: bodyPart.section,
          of: bodyStructure.uid
        )
      }
    } catch let error as MailEngineError {
      throw error
    } catch is CancellationError {
      throw MailEngineError.cancelled
    } catch {
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  // swiftlint:disable:next function_body_length
  func loadMetadataPage(
    mailbox: MailEngineMailboxIdentity,
    beforeUID: Int64?,
    limit: Int
  ) async throws -> MailEngineMetadataPage {
    try await ensureIMAPConnection()
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
        options: [.envelope, .flags, .internalDate, .bodyStructure],
        headerFields: ["References", "Reply-To"]
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
    guard capabilities.contains(.move) || capabilities.contains(.uidPlus) else {
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

  func renderMessage(
    _ message: MailEngineOutgoingMessage
  ) async throws -> Data {
    try ensureOpen()
    guard
      Self.isSafeHeaderValue(message.sender),
      !message.recipients.isEmpty,
      message.recipients.allSatisfy(Self.isSafeHeaderValue),
      Self.isSafeHeaderValue(message.subject),
      Self.isSafeHeaderValue(message.messageID),
      message.inReplyTo.map(Self.isSafeHeaderValue) ?? true,
      let messageID = MessageID(message.messageID)
    else {
      throw MailEngineError.protocolRejected(code: "INVALID-MESSAGE", retryable: false)
    }

    var email = Email(
      sender: EmailAddress(address: message.sender),
      recipients: message.recipients.map { EmailAddress(address: $0) },
      subject: message.subject,
      textBody: message.body
    )
    email.messageID = messageID
    var headers: [String: String] = [:]
    if let inReplyTo = message.inReplyTo {
      headers["In-Reply-To"] = inReplyTo
      headers["References"] = inReplyTo
    }
    if message.requestsReadReceipt {
      headers["Disposition-Notification-To"] = message.sender
    }
    email.additionalHeaders = headers
    return Data(email.constructContent().utf8)
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

  func updateFlags(
    _ flags: Set<String>,
    on messages: [MailEngineMessageIdentity],
    mutation: MailEngineFlagMutation
  ) async throws {
    let selected = try await select(messages)
    guard !flags.isEmpty else { return }
    do {
      try await imap.store(
        flags: flags.sorted().map(Self.swiftMailFlag),
        on: selected.uids,
        operation: mutation == .add ? .add : .remove
      )
    } catch {
      throw Self.mutationError(error)
    }
  }

  private func ensureOpen() throws {
    guard !isClosed else { throw MailEngineError.connectionClosed }
  }

  private func ensureIMAPConnection() async throws {
    try ensureOpen()
    let isIMAPConnected = await imap.isConnected
    guard !isIMAPConnected else { return }
    do {
      try await ExperimentalSwiftMailEngine.connect(
        imap: imap,
        authorization: configuration.authorization
      )
    } catch is CancellationError {
      throw MailEngineError.cancelled
    } catch {
      throw ExperimentalSwiftMailEngine.connectionError(error)
    }
  }

  static func validatePage(beforeUID: Int64?, limit: Int) throws {
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

  private func messageInfo(
    for message: MailEngineMessageIdentity
  ) async throws -> (info: MessageInfo, uid: SwiftMail.UID) {
    _ = try await select([message])
    let uid = SwiftMail.UID(UInt32(message.uid))
    guard
      let info = try await imap.fetchMessageInfo(
        for: uid,
        options: [.envelope, .flags, .internalDate, .bodyStructure]
      ),
      info.uid?.value == uid.value
    else {
      throw MailEngineError.protocolRejected(code: "MISSING-MESSAGE", retryable: false)
    }
    return (info, uid)
  }

  private func select(
    _ messages: [MailEngineMessageIdentity]
  ) async throws -> SelectedMessages {
    try await ensureIMAPConnection()
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

  static func mapping(
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

  static func metadata(
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
      rfcMessageID: info.messageId?.description,
      ccRecipients: info.cc,
      from: info.from,
      hasAttachments: info.parts.contains(where: isAttachment),
      inReplyTo: info.inReplyTo?.description,
      references: info.references?.map(\.description) ?? [],
      replyTo: additionalHeader("Reply-To", in: info.additionalFields),
      subject: info.subject ?? "",
      toRecipients: info.to
    )
  }

  private static func additionalHeader(
    _ name: String,
    in fields: [String: String]?
  ) -> String? {
    fields?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func isAttachment(_ part: MessagePart) -> Bool {
    let disposition = part.disposition?.lowercased()
    let contentType = part.contentType.lowercased()
    let hasFilename = !(part.filename?.isEmpty ?? true)
    let isExplicitAttachment = disposition == "attachment"
    let isCidOnly = part.contentId != nil && !isExplicitAttachment
    if isExplicitAttachment || contentType.hasPrefix("text/calendar") { return true }
    return hasFilename && !isCidOnly
      && (disposition != "inline" || !contentType.hasPrefix("image/"))
  }

  static func preferredBodyPart(_ parts: [MessagePart]) -> MessagePart? {
    let displayable = parts.filter { part in
      let contentType = part.contentType.lowercased()
      let isBody = contentType.hasPrefix("text/plain") || contentType.hasPrefix("text/html")
      return isBody && part.disposition?.lowercased() != "attachment"
        && (part.filename?.isEmpty ?? true)
    }
    return displayable.first { $0.contentType.lowercased().hasPrefix("text/plain") }
      ?? displayable.first { $0.contentType.lowercased().hasPrefix("text/html") }
  }

  static func plainText(fromHTML value: String) -> String {
    guard let document = try? SwiftSoup.parseBodyFragment(value) else { return value }
    _ = try? document.select("script, style").remove()
    _ = try? document.select("br").before("\n")
    _ = try? document.select("p, div, li, h1, h2, h3, h4, h5, h6, tr").append("\n")
    return ((try? document.text()) ?? value).replacingOccurrences(of: "\u{00a0}", with: " ")
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

  private static func swiftMailFlag(_ flag: String) -> Flag {
    switch flag.uppercased() {
    case "\\SEEN": .seen
    case "\\ANSWERED": .answered
    case "\\FLAGGED": .flagged
    case "\\DELETED": .deleted
    case "\\DRAFT": .draft
    default: .custom(flag)
    }
  }

  private static func isSafeHeaderValue(_ value: String) -> Bool {
    !value.contains("\r") && !value.contains("\n")
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

  static func mutationError(_ error: Error) -> MailEngineError {
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

struct SwiftMailMessageContentLoader {
  static func attachments(
    in message: Message,
    maximumDecodedByteCount: Int
  ) -> [(attachment: MailEngineMessageAttachment, part: MessagePart)] {
    message.attachments.map { part in
      (
        MailEngineMessageAttachment(
          byteCount: decodedByteCountHint(
            for: part,
            maximumDecodedByteCount: maximumDecodedByteCount
          ),
          filename: part.filename ?? part.suggestedFilename,
          mimeType: part.contentType.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "application/octet-stream",
          selector: MailEngineBodyPartSelector(part.section.description)
        ),
        part
      )
    }
  }

  static func attachment(
    with selector: MailEngineBodyPartSelector,
    in message: Message,
    maximumDecodedByteCount: Int
  ) -> (attachment: MailEngineMessageAttachment, part: MessagePart)? {
    attachments(
      in: message,
      maximumDecodedByteCount: maximumDecodedByteCount
    ).first { $0.attachment.selector == selector }
  }

  static func messageContent(
    in message: Message,
    maximumAttachmentByteCount: Int,
    loadPart: (MessagePart) async throws -> Data
  ) async throws -> MailEngineMessageContent {
    guard maximumAttachmentByteCount >= 0 else {
      throw MailEngineError.protocolRejected(code: "INVALID-ATTACHMENT-LIMIT", retryable: false)
    }
    let attachments = attachments(
      in: message,
      maximumDecodedByteCount: maximumAttachmentByteCount
    ).map(\.attachment)
    guard
      let bodyPart = message.bodies.first(where: {
        $0.contentType.lowercased().hasPrefix("text/plain")
      })
        ?? message.bodies.first(where: {
          $0.contentType.lowercased().hasPrefix("text/html")
        })
    else {
      guard !attachments.isEmpty else {
        throw MailEngineError.protocolRejected(code: "UNSUPPORTED-BODY", retryable: false)
      }
      return MailEngineMessageContent(attachments: attachments, text: "")
    }
    var loadedPart = bodyPart
    loadedPart.data = try await loadPart(bodyPart)
    guard let decodedBody = loadedPart.textContent else {
      throw MailEngineError.protocolRejected(code: "UNSUPPORTED-BODY", retryable: false)
    }
    let text =
      bodyPart.contentType.lowercased().hasPrefix("text/html")
      ? SwiftMailEngineSession.plainText(fromHTML: decodedBody) : decodedBody
    return MailEngineMessageContent(attachments: attachments, text: text)
  }

  static func attachmentData(
    for part: MessagePart,
    maximumDecodedByteCount: Int,
    loadPart: (MessagePart) async throws -> Data
  ) async throws -> Data {
    guard
      let encodedByteCount = part.size,
      encodedByteCount >= 0,
      let encodedLimit = maximumTransferEncodedByteCount(
        for: part,
        maximumDecodedByteCount: maximumDecodedByteCount
      ),
      encodedByteCount <= encodedLimit
    else {
      throw MailEngineError.protocolRejected(code: "INVALID-ATTACHMENT", retryable: false)
    }
    let encodedData = try await loadPart(part)
    guard encodedData.count <= encodedLimit else {
      throw MailEngineError.protocolRejected(code: "INVALID-ATTACHMENT", retryable: false)
    }
    let data = encodedData.decoded(for: part)
    guard data.count <= maximumDecodedByteCount else {
      throw MailEngineError.protocolRejected(code: "INVALID-ATTACHMENT", retryable: false)
    }
    return data
  }

  static func maximumTransferEncodedByteCount(
    for part: MessagePart,
    maximumDecodedByteCount: Int
  ) -> Int? {
    guard maximumDecodedByteCount >= 0, maximumDecodedByteCount <= Int.max / 3 else {
      return nil
    }
    switch part.encoding?.lowercased() {
    case "base64":
      return maximumDecodedByteCount * 2
    case "quoted-printable":
      return maximumDecodedByteCount * 3
    default:
      return maximumDecodedByteCount
    }
  }

  private static func decodedByteCountHint(
    for part: MessagePart,
    maximumDecodedByteCount: Int
  ) -> Int {
    guard let encodedByteCount = part.size, encodedByteCount >= 0 else { return 0 }
    switch part.encoding?.lowercased() {
    case "base64":
      guard encodedByteCount <= Int.max - 3 else { return 0 }
      let upperBound = ((encodedByteCount + 3) / 4) * 3
      return upperBound <= maximumDecodedByteCount ? upperBound : 0
    case "quoted-printable":
      return encodedByteCount <= maximumDecodedByteCount ? encodedByteCount : 0
    default:
      return encodedByteCount <= maximumDecodedByteCount ? encodedByteCount : 0
    }
  }
}

private struct SwiftMailRuntimeLogSink: MailEngineProductionLogSinking {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "unwired-mail",
    category: "SwiftMailRuntime"
  )

  func record(_ event: MailEngineDiagnosticEvent) {
    let name =
      switch event {
      case .connected: "connected"
      case .disconnected: "disconnected"
      case .operationFailed: "operation-failed"
      }
    Self.logger.notice("Mail engine event: \(name, privacy: .public)")
  }
}

private actor SwiftMailRuntimeSessionPool {
  typealias Connection = (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  )

  private struct Entry {
    let authorization: DeviceLocalGenericMailAuthorization
    let session: any MailEngineSession
    let snapshot: MailEngineConnectionSnapshot
  }

  private struct InFlightEntry {
    let authorization: DeviceLocalGenericMailAuthorization
    let task: Task<Connection, Error>
    let token: UUID
  }

  private let engine: any MailEngine
  private var entries: [MailboxConnectionId: Entry] = [:]
  private var inFlight: [MailboxConnectionId: InFlightEntry] = [:]

  init(engine: any MailEngine) {
    self.engine = engine
  }

  // swiftlint:disable:next function_body_length
  func connect(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> Connection {
    let connectionId = authorization.definition.connectionId
    if let entry = entries[connectionId], entry.authorization == authorization {
      return (entry.snapshot, entry.session)
    }
    if let pending = inFlight[connectionId], pending.authorization == authorization {
      return try await pending.task.value
    }
    if let pending = inFlight.removeValue(forKey: connectionId) {
      pending.task.cancel()
      if let connection = try? await pending.task.value {
        await connection.session.close()
      }
    }
    if let previous = entries.removeValue(forKey: connectionId) {
      await previous.session.close()
    }
    let configuration = try authorization.mailEngineConfiguration()
    let engine = engine
    let token = UUID()
    let task = Task<Connection, Error> {
      try await engine.connect(
        configuration: configuration,
        logger: PrivacyPreservingMailEngineLogger(sink: SwiftMailRuntimeLogSink())
      )
    }
    inFlight[connectionId] = InFlightEntry(
      authorization: authorization,
      task: task,
      token: token
    )
    let connection: Connection
    do {
      connection = try await task.value
    } catch {
      if inFlight[connectionId]?.token == token {
        inFlight[connectionId] = nil
      }
      throw error
    }
    guard inFlight[connectionId]?.token == token else {
      if let entry = entries[connectionId], entry.authorization == authorization {
        return (entry.snapshot, entry.session)
      }
      await connection.session.close()
      throw CancellationError()
    }
    inFlight[connectionId] = nil
    entries[connectionId] = Entry(
      authorization: authorization,
      session: connection.session,
      snapshot: connection.snapshot
    )
    return connection
  }

  func invalidate(connectionId: MailboxConnectionId) async {
    inFlight.removeValue(forKey: connectionId)?.task.cancel()
    guard let entry = entries.removeValue(forKey: connectionId) else { return }
    await entry.session.close()
  }
}

struct SwiftMailMailboxClient: IMAPMailboxClient {
  private static let attachmentIdentifierPrefix = "swiftmail-body-part:"

  private let engine: any MailEngine
  private let pool: SwiftMailRuntimeSessionPool

  init(engine: any MailEngine = ExperimentalSwiftMailEngine()) {
    self.engine = engine
    pool = SwiftMailRuntimeSessionPool(engine: engine)
  }

  func connect(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    try await pool.connect(authorization: authorization)
  }

  func connectFresh(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> (
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession
  ) {
    try await engine.connect(
      configuration: try authorization.mailEngineConfiguration(),
      logger: PrivacyPreservingMailEngineLogger(sink: SwiftMailRuntimeLogSink())
    )
  }

  func invalidate(connectionId: MailboxConnectionId) async {
    await pool.invalidate(connectionId: connectionId)
  }

  func listMailboxes(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> [IMAPMailboxDescriptor] {
    try await connect(authorization: authorization).snapshot.mailboxes.map {
      IMAPMailboxDescriptor(displayName: $0.identity.rawValue, name: $0.identity.rawValue)
    }
  }

  func loadMetadataPage(
    mailbox: IMAPMailboxDescriptor,
    beforeUID: Int64?,
    limit: Int,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> IMAPMetadataPage {
    let page = try await connect(authorization: authorization).session.loadMetadataPage(
      mailbox: MailEngineMailboxIdentity(mailbox.name),
      beforeUID: beforeUID,
      limit: limit
    )
    return IMAPMetadataPage(
      messages: page.messages.map { message in
        IMAPProviderMessage(
          categoryId: nil,
          cc: message.ccRecipients.isEmpty ? nil : message.ccRecipients.joined(separator: ", "),
          flags: message.flags.sorted(),
          from: message.from,
          hasAttachments: message.hasAttachments,
          inReplyTo: message.inReplyTo,
          internalDateMilliseconds: Int64(message.internalDate.timeIntervalSince1970 * 1_000),
          mailbox: message.identity.mailbox.rawValue,
          providerEmailId: nil,
          providerThreadId: nil,
          references: message.references,
          replyTo: message.replyTo,
          rfcMessageId: message.rfcMessageID,
          snippet: "",
          subject: message.subject,
          to: message.toRecipients.isEmpty ? nil : message.toRecipients.joined(separator: ", "),
          uid: message.identity.uid,
          uidValidity: message.identity.uidValidity
        )
      },
      nextOlderUID: page.nextOlderUID,
      uidValidity: page.uidValidity
    )
  }

  func loadTextBody(
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> String {
    try await connect(authorization: authorization).session.loadTextBody(
      for: Self.identity(for: message, authorization: authorization)
    )
  }

  func loadMessageBody(
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> MailboxMessageBody {
    let content = try await connect(authorization: authorization).session.loadMessageContent(
      for: Self.identity(for: message, authorization: authorization),
      maximumAttachmentByteCount: MailboxMessageAttachmentPolicy.maximumByteCount
    )
    return MailboxMessageBody(
      text: content.text,
      attachments: content.attachments.map { attachment in
        MailboxMessageAttachment(
          byteCount: attachment.byteCount,
          filename: attachment.filename,
          id: Self.attachmentIdentifierPrefix + attachment.selector.rawValue,
          mimeType: attachment.mimeType
        )
      }
    )
  }

  func loadMessageAttachment(
    _ attachment: MailboxMessageAttachment,
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    guard attachment.id.hasPrefix(Self.attachmentIdentifierPrefix) else {
      throw MailboxMessageAttachmentError.invalidResponse
    }
    let rawSelector = String(attachment.id.dropFirst(Self.attachmentIdentifierPrefix.count))
    guard !rawSelector.isEmpty else {
      throw MailboxMessageAttachmentError.invalidResponse
    }
    do {
      return try await connect(authorization: authorization).session.loadAttachment(
        MailEngineBodyPartSelector(rawSelector),
        for: Self.identity(for: message, authorization: authorization),
        maximumByteCount: MailboxMessageAttachmentPolicy.maximumByteCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch MailEngineError.cancelled {
      throw CancellationError()
    } catch {
      throw MailboxMessageAttachmentError.invalidResponse
    }
  }

  private static func identity(
    for message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) -> MailEngineMessageIdentity {
    MailEngineMessageIdentity(
      connectionID: authorization.definition.connectionId.rawValue,
      mailbox: MailEngineMailboxIdentity(message.mailbox),
      uid: message.uid,
      uidValidity: message.uidValidity
    )
  }
}

extension DeviceLocalGenericMailAuthorization {
  fileprivate func mailEngineConfiguration() throws -> MailEngineConfiguration {
    let definition = definition
    guard definition.incomingEndpoint.mailProtocol == .imap,
      definition.outgoingEndpoint.mailProtocol == .smtp
    else {
      throw MailEngineError.operationUnsupported
    }
    let authorization: MailEngineAuthorization =
      definition.authorizationMethod == .oauth
      ? .xoauth2(username: definition.username, accessToken: credential)
      : .password(username: definition.username, password: credential)
    return MailEngineConfiguration(
      authorization: authorization,
      connectionID: definition.connectionId.rawValue,
      imapEndpoint: definition.incomingEndpoint.mailEngineEndpoint,
      smtpEndpoint: definition.outgoingEndpoint.mailEngineEndpoint
    )
  }
}

extension GenericMailEndpoint {
  fileprivate var mailEngineEndpoint: MailEngineEndpoint {
    MailEngineEndpoint(
      hostname: hostname,
      port: port,
      transportMode: security == .implicitTLS ? .implicitTLS : .startTLS
    )
  }
}

protocol SwiftMailEndpointVerifying {
  func verify(
    endpoint: GenericMailEndpoint,
    username: String,
    credential: String,
    authorizationMethod: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification
}

struct SwiftMailEndpointVerifier: SwiftMailEndpointVerifying {
  // swiftlint:disable:next cyclomatic_complexity
  func verify(
    endpoint: GenericMailEndpoint,
    username: String,
    credential: String,
    authorizationMethod: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification {
    guard SwiftMailExperimentalBuildPolicy.isEnabled else {
      throw GenericMailSetupError.standardsMailUnavailable
    }
    guard endpoint.mailProtocol == .imap || endpoint.mailProtocol == .smtp else {
      throw MailEngineError.operationUnsupported
    }
    guard !username.contains("\r"), !username.contains("\n"), !credential.contains("\r"),
      !credential.contains("\n")
    else {
      throw GenericMailSetupError.authenticationFailed(endpoint.mailProtocol)
    }
    let authorization: MailEngineAuthorization =
      authorizationMethod == .oauth
      ? .xoauth2(username: username, accessToken: credential)
      : .password(username: username, password: credential)
    let configuration = MailEngineConfiguration(
      authorization: authorization,
      connectionID: "setup-verification",
      imapEndpoint: endpoint.mailEngineEndpoint,
      smtpEndpoint: endpoint.mailEngineEndpoint
    )

    do {
      switch endpoint.mailProtocol {
      case .imap:
        return try await verifyIMAP(configuration: configuration, authorization: authorization)
      case .smtp:
        return try await verifySMTP(configuration: configuration, authorization: authorization)
      case .pop3:
        throw MailEngineError.operationUnsupported
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      switch ExperimentalSwiftMailEngine.connectionError(error) {
      case .authenticationRejected:
        throw GenericMailSetupError.authenticationFailed(endpoint.mailProtocol)
      case .certificateRejected, .serverIdentityMismatch, .startTLSRejected,
        .tlsVersionUnsupported:
        throw GenericMailSetupError.secureTransportRequired(endpoint.mailProtocol)
      default:
        throw error
      }
    }
  }

  private func verifyIMAP(
    configuration: MailEngineConfiguration,
    authorization: MailEngineAuthorization
  ) async throws -> GenericMailEndpointVerification {
    let server = ExperimentalSwiftMailEngine.makeIMAPServer(configuration: configuration)
    do {
      try await ExperimentalSwiftMailEngine.connect(imap: server, authorization: authorization)
      let capabilityNames = try await server.fetchCapabilities().map {
        String(describing: $0).uppercased()
      }
      let mailboxes = try await server.listMailboxes()
      let verification = GenericMailEndpointVerification(
        authenticated: true,
        discoveredRoleMappings: Self.roleMappings(mailboxes),
        engineCapabilities: ExperimentalSwiftMailEngine.capabilities(
          capabilityNames,
          mailboxes: mailboxes
        ),
        transportVersion: .tls12OrNewer
      )
      try? await server.disconnect()
      return verification
    } catch {
      try? await server.disconnect()
      throw error
    }
  }

  private func verifySMTP(
    configuration: MailEngineConfiguration,
    authorization: MailEngineAuthorization
  ) async throws -> GenericMailEndpointVerification {
    let server = ExperimentalSwiftMailEngine.makeSMTPServer(configuration: configuration)
    do {
      try await ExperimentalSwiftMailEngine.connect(smtp: server, authorization: authorization)
      try? await server.disconnect()
      return GenericMailEndpointVerification(
        authenticated: true,
        transportVersion: .tls12OrNewer
      )
    } catch {
      try? await server.disconnect()
      throw error
    }
  }

  private static func roleMappings(
    _ mailboxes: [Mailbox.Info]
  ) -> [CanonicalMailboxRole: String] {
    var candidates: [CanonicalMailboxRole: Set<String>] = [:]
    for mailbox in mailboxes {
      for specialUse in ExperimentalSwiftMailEngine.specialUses(mailbox.attributes) {
        candidates[canonicalRole(specialUse), default: []].insert(mailbox.name)
      }
    }
    return candidates.reduce(into: [:]) { result, candidate in
      if candidate.value.count == 1 { result[candidate.key] = candidate.value.first }
    }
  }

  private static func canonicalRole(
    _ specialUse: MailEngineSpecialUse
  ) -> CanonicalMailboxRole {
    switch specialUse {
    case .archive: .archive
    case .drafts: .drafts
    case .sent: .sent
    case .spam: .spam
    case .trash: .trash
    }
  }
}
