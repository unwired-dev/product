import Foundation

#if canImport(SwiftMail)
  import SwiftMail
#endif

// A Standards-Based Mailbox Connection's SMTP endpoint. Secure Mail Transport: implicit TLS from the
// first byte, or STARTTLS the server must offer before any authentication; certificates are
// verified against the system's trusted roots, with no override.
struct SmtpAccount: Codable, Equatable, Sendable {
  let host: String
  let port: Int
  let startTLS: Bool
  let username: String

  // The same reviewable host, port and user name rules as an IMAP endpoint.
  init(host: String, port: Int, startTLS: Bool, username: String) throws {
    let checked = try ImapAccount(host: host, port: port, username: username)
    self.host = checked.host
    self.port = port
    self.startTLS = startTLS
    self.username = username
  }
}

// Why an SMTP login or submission ended before the server could have accepted the message.
enum SmtpFailure: Error, Equatable {
  // The server refused the user name and password.
  case authentication
  // TLS could not be established with a verified certificate, or STARTTLS was not offered.
  case insecure
  // The server could not be reached, or refused the message for now; a later attempt may succeed.
  case offline
  // The server refused the message for good, such as a recipient it does not accept.
  case rejected

  var code: String {
    switch self {
    case .authentication: "smtp-refused"
    case .insecure: "smtp-insecure"
    case .offline: "offline"
    case .rejected: "smtp-rejected"
    }
  }
}

protocol SmtpProvider: Sendable {
  func verify(_ account: SmtpAccount, password: String) async throws
  // Submits the message once. Throws SmtpFailure or tooLarge when the server cannot have accepted
  // it, and deliveryUnknown when it may have.
  func send(
    _ account: SmtpAccount, password: String, from: String, to: [String], message: Data
  ) async throws
}

#if canImport(SwiftMail)
  // SwiftMail's SMTP client. Each operation opens one authenticated session and closes it.
  struct SwiftMailSmtp: SmtpProvider {
    private func session(
      _ account: SmtpAccount, _ password: String,
      _ work: @Sendable (SMTPServer) async throws -> Void
    ) async throws {
      _ = SwiftMailImap.quiet
      let server = SMTPServer(
        host: account.host, port: account.port,
        transportSecurity: account.startTLS ? .startTLS : .implicitTLS,
        certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12)
      do {
        try await server.connect()
        do {
          try await server.login(username: account.username, password: password)
        } catch SMTPError.authenticationFailed {
          throw SmtpFailure.authentication
        }
        try await work(server)
        try? await server.disconnect()
      } catch {
        try? await server.disconnect()
        throw Self.failure(error)
      }
    }

    // Before the dialogue nothing reached the server; SwiftMail classifies the dialogue itself.
    static func failure(_ error: any Error) -> any Error {
      switch error {
      case is SmtpFailure, is PrivateInboxError, is CancellationError: return error
      case let error as SMTPSendError:
        switch error.retryDisposition {
        case .unsafeToRetry: return PrivateInboxError.deliveryUnknown
        case .permanent: return SmtpFailure.rejected
        case .retryable: return SmtpFailure.offline
        }
      case SMTPError.tlsFailed: return SmtpFailure.insecure
      case SMTPError.messageTooLarge: return PrivateInboxError.tooLarge
      default:
        let type = String(reflecting: Swift.type(of: error))
        return type.contains("NIOSSL") || type.contains("BoringSSL")
          ? SmtpFailure.insecure : SmtpFailure.offline
      }
    }

    func verify(_ account: SmtpAccount, password: String) async throws {
      try await session(account, password) { _ in }
    }

    func send(
      _ account: SmtpAccount, password: String, from: String, to: [String], message: Data
    ) async throws {
      try await session(account, password) { server in
        if let limit = await server.maximumMessageSizeOctets, limit > 0, message.count > limit {
          throw PrivateInboxError.tooLarge
        }
        try await server.sendRawMessage(
          message, from: EmailAddress(address: from), to: to.map { EmailAddress(address: $0) })
      }
    }
  }
#else
  struct SwiftMailSmtp: SmtpProvider {
    func verify(_ account: SmtpAccount, password: String) async throws {
      throw SmtpFailure.offline
    }
    func send(
      _ account: SmtpAccount, password: String, from: String, to: [String], message: Data
    ) async throws {
      throw SmtpFailure.offline
    }
  }
#endif

extension RegistrationStore {
  // The connection's SMTP endpoint and password: its own SMTP password when one was given.
  private func smtpConnection(_ id: String) throws -> (SmtpAccount, String) {
    let (_, password, connection) = try imapConnection(id)
    guard let smtp = connection.smtp else { throw RegistrationError.unavailable }
    return (smtp, connection.smtpCredential.map { String(decoding: $0, as: UTF8.self) } ?? password)
  }

  // An envelope address SMTP can carry: ASCII, one `@`, no spaces, brackets or controls.
  private nonisolated static func envelopeAddress(_ address: String) -> Bool {
    address.count <= 320
      && address.range(of: "^[!-~]+@[!-~]+$", options: .regularExpression) != nil
      && !address.contains(where: { "<>()[],;:\\\"".contains($0) })
  }

  // Submits a message TypeScript composed, without its Bcc field, from the connection's address to
  // `recipients`, with each Draft Asset's verified bytes inserted here. Any failure once its end may
  // have reached the server is deliveryUnknown; nothing here retries a submission.
  func imapSend(
    segments: [Any], recipients: [String], connection id: String, address: String,
    generation: String
  ) async throws -> [String: Any] {
    let product = try mailboxAccount(id)
    guard (1...1_000).contains(recipients.count), recipients.allSatisfy(Self.envelopeAddress)
    else { throw RegistrationError.unavailable }
    let message = try await outgoingMessage(segments: segments, owner: product.productAccountId)
    guard mailboxGeneration(id).uuidString == generation else {
      throw PrivateInboxError.mailboxInvalidated
    }
    guard verifiedMailboxes.contains(id) else { throw RegistrationError.unavailable }
    guard try imapConnection(id).2.receipt.address == address else {
      throw PrivateInboxError.mailboxInvalidated
    }
    // A submission requires a current Trusted Device proof, as every provider write does.
    guard let deviceRevoked else { throw RegistrationError.unavailable }
    if try await deviceRevoked(product) {
      try await purge()
      throw RegistrationError.revoked
    }
    guard mailboxGeneration(id).uuidString == generation, verifiedMailboxes.contains(id) else {
      throw PrivateInboxError.mailboxInvalidated
    }
    let (account, password) = try smtpConnection(id)
    try await smtp.send(account, password: password, from: address, to: recipients, message: message)
    return ["accepted": true]
  }

  // Files an accepted message's copy in the connection's Sent folder, unless a copy with its MIME
  // boundary is already there, so filing again never adds a second copy.
  func imapFileSent(
    segments: [Any], folder: String, boundary: String, connection id: String, address: String,
    generation: String
  ) async throws -> [String: Any] {
    guard Self.sentBoundary(boundary), !folder.isEmpty, folder.count <= 1_000 else {
      throw RegistrationError.unavailable
    }
    let product = try mailboxAccount(id)
    let message = try await outgoingMessage(
      segments: segments, owner: product.productAccountId)
    guard let deviceRevoked else { throw RegistrationError.unavailable }
    if try await deviceRevoked(product) {
      try await purge()
      throw RegistrationError.revoked
    }
    try await imapWork(connection: id, address: address, generation: generation) {
      try await imap.fileSent($0, password: $1, folder: folder, boundary: boundary, message: message)
    }
    return [:]
  }

  // How many messages in the Sent folder carry the MIME boundary.
  func imapFindSent(
    folder: String, boundary: String, connection id: String, address: String, generation: String
  ) async throws -> [String: Any] {
    guard Self.sentBoundary(boundary), !folder.isEmpty, folder.count <= 1_000 else {
      throw RegistrationError.unavailable
    }
    let count = try await imapWork(connection: id, address: address, generation: generation) {
      try await imap.findSent($0, password: $1, folder: folder, boundary: boundary)
    }
    return ["count": Double(count)]
  }

  // The boundaries TypeScript chooses, which a quoted IMAP search carries unchanged.
  private nonisolated static func sentBoundary(_ boundary: String) -> Bool {
    boundary.range(of: "^[0-9A-Za-z=_.-]{8,70}$", options: .regularExpression) != nil
  }
}
