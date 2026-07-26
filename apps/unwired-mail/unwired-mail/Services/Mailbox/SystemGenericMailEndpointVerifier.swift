import Foundation

// swiftlint:disable file_length

protocol GenericMailStreamTasking: AnyObject {
  func close()
  func read() async throws -> String
  func readData() async throws -> Data
  func readData(timeout: TimeInterval) async throws -> Data
  func resume()
  func startSecureConnection()
  func write(_ value: String) async throws
}

extension GenericMailStreamTasking {
  func readData() async throws -> Data {
    Data(try await read().utf8)
  }

  func readData(timeout _: TimeInterval) async throws -> Data {
    try await readData()
  }
}

protocol GenericMailStreamTaskCreating {
  func makeStreamTask(
    hostname: String,
    port: Int,
    minimumTransportVersion: MailTransportVersion
  ) -> GenericMailStreamTasking
}

final class SystemGenericMailEndpointVerifier: NSObject, GenericMailEndpointVerifying {
  private let streamTaskFactory: GenericMailStreamTaskCreating

  init(
    streamTaskFactory: GenericMailStreamTaskCreating = URLSessionGenericMailStreamTaskFactory()
  ) {
    self.streamTaskFactory = streamTaskFactory
  }

  func verify(
    endpoint: GenericMailEndpoint,
    username: String,
    credential: String,
    authorizationMethod: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification {
    guard !username.contains("\r"), !username.contains("\n"), !credential.contains("\r"),
      !credential.contains("\n")
    else {
      throw GenericMailSetupError.authenticationFailed(endpoint.mailProtocol)
    }
    let task = streamTaskFactory.makeStreamTask(
      hostname: endpoint.hostname,
      port: endpoint.port,
      minimumTransportVersion: .tls12OrNewer
    )
    task.resume()
    defer { task.close() }

    let result = try await withTaskCancellationHandler {
      let conversation = MailEndpointConversation(
        authorizationMethod: authorizationMethod,
        credential: credential,
        endpoint: endpoint,
        task: task,
        username: username
      )
      return try await conversation.verify()
    } onCancel: {
      task.close()
    }
    return GenericMailEndpointVerification(
      authenticated: true,
      discoveredIMAPCapabilities: result.imapCapabilities,
      discoveredRoleMappings: result.roleMappings,
      transportVersion: .tls12OrNewer
    )
  }
}

private struct MailEndpointVerificationResult {
  let imapCapabilities: Set<String>
  let roleMappings: [CanonicalMailboxRole: String]
}

private final class MailEndpointConversation {
  let authorizationMethod: MailAuthorizationMethod
  let credential: String
  let endpoint: GenericMailEndpoint
  let task: GenericMailStreamTasking
  let username: String
  private var unreadResponse = ""

  init(
    authorizationMethod: MailAuthorizationMethod,
    credential: String,
    endpoint: GenericMailEndpoint,
    task: GenericMailStreamTasking,
    username: String
  ) {
    self.authorizationMethod = authorizationMethod
    self.credential = credential
    self.endpoint = endpoint
    self.task = task
    self.username = username
  }

  func verify() async throws -> MailEndpointVerificationResult {
    if endpoint.security == .implicitTLS {
      task.startSecureConnection()
    }

    let greeting = try await readGreeting()
    guard isPositiveGreeting(greeting) else {
      throw GenericMailSetupError.authenticationFailed(endpoint.mailProtocol)
    }

    if endpoint.security == .startTLS {
      try await negotiateStartTLS()
      unreadResponse = ""
      task.startSecureConnection()
    }

    try await authenticate()
    if endpoint.mailProtocol == .imap {
      let capabilities = try await discoverIMAPCapabilities()
      return MailEndpointVerificationResult(
        imapCapabilities: capabilities,
        roleMappings: try await discoverIMAPRoleMappings()
      )
    }
    return MailEndpointVerificationResult(imapCapabilities: [], roleMappings: [:])
  }

  private func discoverIMAPCapabilities() async throws -> Set<String> {
    try await write("a3 CAPABILITY\r\n")
    let response = try await readIMAPResponse(tag: "A3")
    return Set(
      response.components(separatedBy: "\r\n")
        .filter { $0.uppercased().hasPrefix("* CAPABILITY ") }
        .flatMap { $0.split(separator: " ").dropFirst(2).map { $0.uppercased() } }
    )
  }

  private func negotiateStartTLS() async throws {
    switch endpoint.mailProtocol {
    case .imap:
      try await write("a1 STARTTLS\r\n")
      guard try await readIMAPResponse(tag: "A1").uppercased().contains("A1 OK") else {
        throw GenericMailSetupError.secureTransportRequired(.imap)
      }
    case .pop3:
      try await write("STLS\r\n")
      guard try await readResponse().uppercased().hasPrefix("+OK") else {
        throw GenericMailSetupError.secureTransportRequired(.pop3)
      }
    case .smtp:
      try await write("EHLO unwired.local\r\n")
      guard try await readSMTPResponse(code: "250").hasPrefix("250") else {
        throw GenericMailSetupError.secureTransportRequired(.smtp)
      }
      try await write("STARTTLS\r\n")
      guard try await readSMTPResponse(code: "220").hasPrefix("220") else {
        throw GenericMailSetupError.secureTransportRequired(.smtp)
      }
    }
  }

  private func authenticate() async throws {
    switch endpoint.mailProtocol {
    case .imap:
      try await authenticateIMAP()
    case .pop3:
      try await authenticatePOP3()
    case .smtp:
      try await authenticateSMTP()
    }
  }

  private func authenticateIMAP() async throws {
    if authorizationMethod == .oauth {
      try await write("a2 AUTHENTICATE XOAUTH2 \(oauthPayload())\r\n")
    } else {
      try await write("a2 LOGIN \(quoted(username)) \(quoted(credential))\r\n")
    }
    let response = try await readIMAPResponse(
      tag: "A2",
      respondsToContinuation: authorizationMethod == .oauth
    )
    let taggedResponse = response.components(separatedBy: "\r\n").last { line in
      line.uppercased().hasPrefix("A2 ")
    }
    guard taggedResponse?.uppercased().hasPrefix("A2 OK") == true else {
      throw GenericMailSetupError.authenticationFailed(.imap)
    }
  }

  private func discoverIMAPRoleMappings() async throws -> [CanonicalMailboxRole: String] {
    try await write("a4 LIST \"\" \"*\" RETURN (SPECIAL-USE)\r\n")
    let response = try await readIMAPResponse(tag: "A4")
    var candidates: [CanonicalMailboxRole: Set<String>] = [:]
    for line in response.components(separatedBy: "\r\n") where line.hasPrefix("* LIST (") {
      guard let mailbox = listedMailbox(in: line) else { continue }
      let flags = imapListFlags(in: line)
      for (flag, role) in specialUseRoles where flags.contains(flag) {
        candidates[role, default: []].insert(mailbox)
      }
    }
    return candidates.reduce(into: [:]) { mappings, candidate in
      if candidate.value.count == 1 { mappings[candidate.key] = candidate.value.first }
    }
  }

  private var specialUseRoles: [(String, CanonicalMailboxRole)] {
    [
      ("\\ARCHIVE", .archive),
      ("\\DRAFTS", .drafts),
      ("\\JUNK", .spam),
      ("\\SENT", .sent),
      ("\\TRASH", .trash),
    ]
  }

  private func listedMailbox(in line: String) -> String? {
    guard let flagsEnd = line.range(of: ") ") else { return nil }
    guard let (_, afterDelimiter) = imapListToken(in: line[flagsEnd.upperBound...]) else {
      return nil
    }
    return imapListToken(in: afterDelimiter)?.value
  }

  private func imapListFlags(in line: String) -> Set<String> {
    guard let range = line.range(of: "* LIST (") else { return [] }
    guard let end = line[range.upperBound...].firstIndex(of: ")") else { return [] }
    return Set(line[range.upperBound..<end].split(separator: " ").map { $0.uppercased() })
  }

  private func authenticatePOP3() async throws {
    if authorizationMethod == .oauth {
      try await write("AUTH XOAUTH2 \(oauthPayload())\r\n")
    } else {
      try await write("USER \(username)\r\n")
      guard try await readResponse().uppercased().hasPrefix("+OK") else {
        throw GenericMailSetupError.authenticationFailed(.pop3)
      }
      try await write("PASS \(credential)\r\n")
    }
    guard try await readResponse().uppercased().hasPrefix("+OK") else {
      throw GenericMailSetupError.authenticationFailed(.pop3)
    }
  }

  private func authenticateSMTP() async throws {
    try await write("EHLO unwired.local\r\n")
    guard try await readSMTPResponse(code: "250").hasPrefix("250") else {
      throw GenericMailSetupError.authenticationFailed(.smtp)
    }
    if authorizationMethod == .oauth {
      try await write("AUTH XOAUTH2 \(oauthPayload())\r\n")
    } else {
      let payload = Data("\u{0}\(username)\u{0}\(credential)".utf8).base64EncodedString()
      try await write("AUTH PLAIN \(payload)\r\n")
    }
    guard try await readSMTPResponse(code: "235").hasPrefix("235") else {
      throw GenericMailSetupError.authenticationFailed(.smtp)
    }
  }

  private func isPositiveGreeting(_ response: String) -> Bool {
    switch endpoint.mailProtocol {
    case .imap:
      return response.uppercased().contains("* OK")
    case .pop3:
      return response.uppercased().hasPrefix("+OK")
    case .smtp:
      return response.hasPrefix("220")
    }
  }

  private func readGreeting() async throws -> String {
    if endpoint.mailProtocol == .smtp {
      return try await readSMTPResponse(code: "220")
    }
    return try await readResponse()
  }

  private func readIMAPResponse(
    tag: String,
    respondsToContinuation: Bool = false
  ) async throws -> String {
    var response = ""
    while true {
      let line = try await readResponse()
      response += line
      if line.uppercased().hasPrefix("\(tag.uppercased()) ") {
        return response
      }
      if respondsToContinuation, line.hasPrefix("+") {
        try await write("\r\n")
      }
    }
  }

  private func readSMTPResponse(code: String) async throws -> String {
    var response = ""
    repeat {
      response += try await readResponse()
    } while !response.components(separatedBy: "\r\n").contains(where: {
      $0.hasPrefix("\(code) ") || $0.range(of: #"^\d{3} "#, options: .regularExpression) != nil
    })
    return response
  }

  private func oauthPayload() -> String {
    Data("user=\(username)\u{1}auth=Bearer \(credential)\u{1}\u{1}".utf8)
      .base64EncodedString()
  }

  private func quoted(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }

  private func imapListToken(in value: Substring) -> (value: String, remainder: Substring)? {
    let trimmed = value.drop(while: \Character.isWhitespace)
    guard let first = trimmed.first else { return nil }
    if first != "\"" {
      let end = trimmed.firstIndex(where: \Character.isWhitespace) ?? trimmed.endIndex
      return (String(trimmed[..<end]), trimmed[end...])
    }
    let contentStart = trimmed.index(after: trimmed.startIndex)
    guard let closingQuote = trimmed[contentStart...].firstIndex(of: "\"") else { return nil }
    return (
      String(trimmed[contentStart..<closingQuote]),
      trimmed[trimmed.index(after: closingQuote)...]
    )
  }

  private func readResponse() async throws -> String {
    while !unreadResponse.contains("\r\n") {
      unreadResponse += try await task.read()
    }
    let range = unreadResponse.range(of: "\r\n")!
    let response = String(unreadResponse[..<range.upperBound])
    unreadResponse.removeSubrange(..<range.upperBound)
    return response
  }

  private func write(_ value: String) async throws {
    try await task.write(value)
  }
}

struct SystemSMTPMailClient: SMTPMailClient {
  private let streamTaskFactory: GenericMailStreamTaskCreating

  init(
    streamTaskFactory: GenericMailStreamTaskCreating = URLSessionGenericMailStreamTaskFactory()
  ) {
    self.streamTaskFactory = streamTaskFactory
  }

  func send(
    _ message: Data,
    envelopeFrom: String,
    envelopeRecipients: [String],
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws {
    let definition = authorization.definition
    let endpoint = definition.outgoingEndpoint
    guard
      endpoint.mailProtocol == .smtp,
      !envelopeFrom.isEmpty,
      !envelopeRecipients.isEmpty,
      ([envelopeFrom] + envelopeRecipients).allSatisfy({
        !$0.contains("\r") && !$0.contains("\n")
      })
    else {
      throw SMTPMailError.invalidMessage
    }
    let task = streamTaskFactory.makeStreamTask(
      hostname: endpoint.hostname,
      port: endpoint.port,
      minimumTransportVersion: .tls12OrNewer
    )
    task.resume()
    let conversation = SMTPDeliveryConversation(
      authorizationMethod: definition.authorizationMethod,
      credential: authorization.credential,
      endpoint: endpoint,
      task: task,
      username: definition.username
    )
    try await withTaskCancellationHandler {
      defer { task.close() }
      try await conversation.send(
        message,
        envelopeFrom: envelopeFrom,
        envelopeRecipients: envelopeRecipients
      )
    } onCancel: {
      task.close()
    }
  }
}

private final class SMTPDeliveryConversation {
  private let authorizationMethod: MailAuthorizationMethod
  private let credential: String
  private let endpoint: GenericMailEndpoint
  private let task: GenericMailStreamTasking
  private let username: String
  private var unreadResponse = ""

  init(
    authorizationMethod: MailAuthorizationMethod,
    credential: String,
    endpoint: GenericMailEndpoint,
    task: GenericMailStreamTasking,
    username: String
  ) {
    self.authorizationMethod = authorizationMethod
    self.credential = credential
    self.endpoint = endpoint
    self.task = task
    self.username = username
  }

  func send(
    _ message: Data,
    envelopeFrom: String,
    envelopeRecipients: [String]
  ) async throws {
    guard
      let message = String(data: message, encoding: .utf8),
      !username.contains("\r"),
      !username.contains("\n"),
      !credential.contains("\r"),
      !credential.contains("\n")
    else {
      throw SMTPMailError.invalidMessage
    }
    do {
      if endpoint.security == .implicitTLS {
        task.startSecureConnection()
      }
      try await expect(220)
      if endpoint.security == .startTLS {
        try await write("EHLO unwired.local\r\n")
        try await expect(250)
        try await write("STARTTLS\r\n")
        try await expect(220)
        unreadResponse = ""
        task.startSecureConnection()
      }
      try await write("EHLO unwired.local\r\n")
      try await expect(250)
      try await authenticate()
      try await write("MAIL FROM:<\(envelopeFrom)>\r\n")
      try await expect(250)
      for recipient in envelopeRecipients {
        try await write("RCPT TO:<\(recipient)>\r\n")
        try await expectOne(of: [250, 251])
      }
      try await write("DATA\r\n")
      try await expect(354)
    } catch let error as SMTPMailError {
      throw error
    } catch {
      throw SMTPMailError.connectionFailedBeforeSubmission
    }
    do {
      try await write("\(Self.dotStuffed(message))\r\n.\r\n")
      try await expect(250)
    } catch let error as SMTPMailError {
      if case .responseCode = error { throw error }
      throw SMTPMailError.deliveryUncertainAfterSubmission
    } catch {
      throw SMTPMailError.deliveryUncertainAfterSubmission
    }
    try? await write("QUIT\r\n")
  }

  private func authenticate() async throws {
    if authorizationMethod == .oauth {
      let payload = Data(
        "user=\(username)\u{1}auth=Bearer \(credential)\u{1}\u{1}".utf8
      ).base64EncodedString()
      try await write("AUTH XOAUTH2 \(payload)\r\n")
      let code = try await readResponseCode()
      if code == 334 {
        try await write("\r\n")
        try await expect(235)
      } else if code != 235 {
        throw SMTPMailError.responseCode(code)
      }
    } else {
      let payload = Data("\u{0}\(username)\u{0}\(credential)".utf8).base64EncodedString()
      try await write("AUTH PLAIN \(payload)\r\n")
      try await expect(235)
    }
  }

  private func expect(_ code: Int) async throws {
    try await expectOne(of: [code])
  }

  private func expectOne(of expectedCodes: Set<Int>) async throws {
    let code = try await readResponseCode()
    guard expectedCodes.contains(code) else {
      throw SMTPMailError.responseCode(code)
    }
  }

  private func readResponseCode() async throws -> Int {
    while true {
      let line = try await readLine()
      guard
        line.count >= 3,
        let code = Int(line.prefix(3))
      else {
        throw SMTPMailError.invalidMessage
      }
      let separator = line.dropFirst(3).first
      if separator == " " { return code }
      guard separator == "-" else {
        throw SMTPMailError.responseCode(code)
      }
    }
  }

  private func readLine() async throws -> String {
    while !unreadResponse.contains("\r\n") {
      unreadResponse += try await task.read()
    }
    let range = unreadResponse.range(of: "\r\n")!
    let line = String(unreadResponse[..<range.upperBound])
    unreadResponse.removeSubrange(..<range.upperBound)
    return line
  }

  private func write(_ value: String) async throws {
    try Task.checkCancellation()
    try await task.write(value)
  }

  private static func dotStuffed(_ message: String) -> String {
    var normalized =
      message
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in line.hasPrefix(".") ? ".\(line)" : String(line) }
      .joined(separator: "\r\n")
    while normalized.hasSuffix("\r\n") {
      normalized.removeLast(2)
    }
    return normalized
  }
}

struct URLSessionGenericMailStreamTaskFactory: GenericMailStreamTaskCreating {
  func makeStreamTask(
    hostname: String,
    port: Int,
    minimumTransportVersion: MailTransportVersion
  ) -> GenericMailStreamTasking {
    let configuration = URLSessionConfiguration.ephemeral
    if minimumTransportVersion == .tls12OrNewer {
      configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
    }
    let session = URLSession(configuration: configuration)
    return URLSessionGenericMailStreamTask(
      session: session,
      task: session.streamTask(withHostName: hostname, port: port)
    )
  }
}

private final class URLSessionGenericMailStreamTask: GenericMailStreamTasking {
  private let session: URLSession
  private let task: URLSessionStreamTask

  init(session: URLSession, task: URLSessionStreamTask) {
    self.session = session
    self.task = task
  }

  func close() {
    task.closeRead()
    task.closeWrite()
    session.invalidateAndCancel()
  }

  func read() async throws -> String {
    let data = try await readData()
    guard let response = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    return response
  }

  func readData() async throws -> Data {
    try await readData(timeout: 15)
  }

  func readData(timeout: TimeInterval) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      task.readData(ofMinLength: 1, maxLength: 65_536, timeout: timeout) { data, _, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let data else {
          continuation.resume(throwing: KeychainStoreError.unexpectedData)
          return
        }
        continuation.resume(returning: data)
      }
    }
  }

  func resume() {
    task.resume()
  }

  func startSecureConnection() {
    task.startSecureConnection()
  }

  func write(_ value: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.write(Data(value.utf8), timeout: 15) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }
}
