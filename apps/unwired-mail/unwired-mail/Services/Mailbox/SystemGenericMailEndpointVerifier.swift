import Foundation

protocol GenericMailStreamTasking: AnyObject {
  func close()
  func read() async throws -> String
  func resume()
  func startSecureConnection()
  func write(_ value: String) async throws
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

    let discoveredRoleMappings = try await withTaskCancellationHandler {
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
      discoveredRoleMappings: discoveredRoleMappings,
      transportVersion: .tls12OrNewer
    )
  }
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

  func verify() async throws -> [CanonicalMailboxRole: String] {
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
      return try await discoverIMAPRoleMappings()
    }
    return [:]
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
    try await write("a3 LIST \"\" \"*\" RETURN (SPECIAL-USE)\r\n")
    let response = try await readIMAPResponse(tag: "A3")
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

private struct URLSessionGenericMailStreamTaskFactory: GenericMailStreamTaskCreating {
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
    try await withCheckedThrowingContinuation { continuation in
      task.readData(ofMinLength: 1, maxLength: 65_536, timeout: 15) { data, _, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let data, let response = String(data: data, encoding: .utf8) else {
          continuation.resume(throwing: KeychainStoreError.unexpectedData)
          return
        }
        continuation.resume(returning: response)
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
