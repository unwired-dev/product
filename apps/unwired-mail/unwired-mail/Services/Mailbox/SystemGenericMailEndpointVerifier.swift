import Foundation

protocol GenericMailStreamTasking: AnyObject {
  func close()
  func read() async throws -> String
  func readData() async throws -> Data
  func resume()
  func startSecureConnection()
  func write(_ value: String) async throws
}

extension GenericMailStreamTasking {
  func readData() async throws -> Data {
    Data(try await read().utf8)
  }
}

protocol GenericMailStreamTaskCreating {
  func makeStreamTask(
    hostname: String,
    port: Int,
    minimumTransportVersion: MailTransportVersion
  ) -> GenericMailStreamTasking
}

/// SwiftMail owns IMAP and SMTP verification. The product-owned stream is retained only for
/// POP3, which is outside SwiftMail's protocol surface.
final class SystemGenericMailEndpointVerifier: NSObject, GenericMailEndpointVerifying {
  private let streamTaskFactory: GenericMailStreamTaskCreating
  private let swiftMailVerifier: any SwiftMailEndpointVerifying

  init(
    streamTaskFactory: GenericMailStreamTaskCreating = URLSessionGenericMailStreamTaskFactory(),
    swiftMailVerifier: any SwiftMailEndpointVerifying = SwiftMailEndpointVerifier()
  ) {
    self.streamTaskFactory = streamTaskFactory
    self.swiftMailVerifier = swiftMailVerifier
  }

  func verify(
    endpoint: GenericMailEndpoint,
    username: String,
    credential: String,
    authorizationMethod: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification {
    guard endpoint.mailProtocol == .pop3 else {
      return try await swiftMailVerifier.verify(
        endpoint: endpoint,
        username: username,
        credential: credential,
        authorizationMethod: authorizationMethod
      )
    }
    guard !username.contains("\r"), !username.contains("\n"), !credential.contains("\r"),
      !credential.contains("\n")
    else {
      throw GenericMailSetupError.authenticationFailed(.pop3)
    }

    let task = streamTaskFactory.makeStreamTask(
      hostname: endpoint.hostname,
      port: endpoint.port,
      minimumTransportVersion: .tls12OrNewer
    )
    task.resume()
    defer { task.close() }
    try await withTaskCancellationHandler {
      try await POP3EndpointConversation(
        authorizationMethod: authorizationMethod,
        credential: credential,
        endpoint: endpoint,
        task: task,
        username: username
      ).verify()
    } onCancel: {
      task.close()
    }
    return GenericMailEndpointVerification(
      authenticated: true,
      transportVersion: .tls12OrNewer
    )
  }
}

private final class POP3EndpointConversation {
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

  func verify() async throws {
    if endpoint.security == .implicitTLS { task.startSecureConnection() }
    guard try await readResponse().uppercased().hasPrefix("+OK") else {
      throw GenericMailSetupError.authenticationFailed(.pop3)
    }
    if endpoint.security == .startTLS {
      try await task.write("STLS\r\n")
      guard try await readResponse().uppercased().hasPrefix("+OK") else {
        throw GenericMailSetupError.secureTransportRequired(.pop3)
      }
      unreadResponse = ""
      task.startSecureConnection()
    }

    if authorizationMethod == .oauth {
      let payload = Data(
        "user=\(username)\u{1}auth=Bearer \(credential)\u{1}\u{1}".utf8
      ).base64EncodedString()
      try await task.write("AUTH XOAUTH2 \(payload)\r\n")
    } else {
      try await task.write("USER \(username)\r\n")
      guard try await readResponse().uppercased().hasPrefix("+OK") else {
        throw GenericMailSetupError.authenticationFailed(.pop3)
      }
      try await task.write("PASS \(credential)\r\n")
    }
    guard try await readResponse().uppercased().hasPrefix("+OK") else {
      throw GenericMailSetupError.authenticationFailed(.pop3)
    }
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
    try await withCheckedThrowingContinuation { continuation in
      task.readData(ofMinLength: 1, maxLength: 65_536, timeout: 15) { data, _, error in
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
