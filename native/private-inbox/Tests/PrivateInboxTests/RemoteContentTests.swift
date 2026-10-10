import Foundation
import Network
import Security
import Testing

@testable import PrivateInbox

extension PrivateInboxTests {
  // Only globally routable unicast destinations may receive a remote image request; NAT64 carries
  // the IPv4 destination it embeds.
  @Test func remoteContentRefusesNonPublicAddresses() {
    func allowed(_ text: String) -> Bool {
      RemoteAddress.isPublic((IPv4Address(text).map { $0 as IPAddress } ?? IPv6Address(text))!)
    }
    for refused in [
      "0.1.2.3", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.16.0.1",
      "192.0.0.8", "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.51.100.1", "203.0.113.1",
      "224.0.0.1", "255.255.255.255", "::", "::1", "::ffff:8.8.8.8", "fc00::1", "fe80::1",
      "ff02::1", "2001:db8::1", "2001::1", "2002:0808:0808::1", "64:ff9b::7f00:1",
      "3fff::1", "3fff:fff:ffff::1",
    ] {
      #expect(!allowed(refused), "\(refused)")
    }
    for permitted in ["8.8.8.8", "93.184.216.34", "2606:4700::1111", "64:ff9b::808:808"] {
      #expect(allowed(permitted), "\(permitted)")
    }
  }

  // Destinations are HTTPS without credentials; a literal or resolved non-public address, even
  // one answer among several, refuses the name; the request carries no cookie or credential.
  @Test func remoteContentValidatesEveryDestination() async throws {
    let fetcher = RemoteContentFetcher(
      resolve: { host in
        switch host {
        case "images.example": [IPv4Address("93.184.216.34")!, IPv6Address("2606:4700::1111")!]
        case "rebind.example": [IPv4Address("93.184.216.34")!, IPv4Address("10.0.0.2")!]
        default: throw RemoteContentError.unavailable
        }
      },
      exchange: { _ in throw RemoteContentError.unavailable })
    for refused in [
      "http://images.example/a.png", "https://user:secret@images.example/a.png",
      "https://127.0.0.1/a.png", "https://[::1]/a.png", "https://rebind.example/a.png",
      "https://bücher.example/a.png", "ftp://images.example/a.png",
    ] {
      await #expect(throws: RemoteContentError.refused, "\(refused)") {
        _ = try await fetcher.destination(try #require(URL(string: refused)))
      }
    }
    let destination = try await fetcher.destination(
      try #require(URL(string: "https://Images.Example:8443/p/a%20b.png?x=1#fragment")))
    #expect(destination.address as? IPv4Address == IPv4Address("93.184.216.34"))
    #expect(destination.host == "images.example")
    #expect(destination.port == 8443)
    let request = try #require(String(data: destination.request, encoding: .utf8))
    #expect(request.hasPrefix("GET /p/a%20b.png?x=1 HTTP/1.1\r\nHost: images.example:8443\r\n"))
    for header in ["cookie", "authorization", "referer", "origin", "user-agent"] {
      #expect(!request.lowercased().contains(header + ":"))
    }
  }

  // Every redirect repeats the destination checks, the chain is bounded, and response framing
  // and size are enforced.
  @Test func remoteContentRechecksRedirectsAndBoundsResponses() async throws {
    let responses: [String: String] = [
      "/start": "HTTP/1.1 302 Found\r\nLocation: /next\r\n\r\n",
      "/next": "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n",
      "/private": "HTTP/1.1 301 Moved\r\nLocation: https://10.0.0.1/a.png\r\n\r\n",
      "/plain": "HTTP/1.1 307 Temporary\r\nLocation: http://images.example/a.png\r\n\r\n",
      "/loop": "HTTP/1.1 302 Found\r\nLocation: /loop\r\n\r\n",
      "/missing": "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
      "/short": "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc",
      "/framing": "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd",
    ]
    let fetcher = RemoteContentFetcher(
      resolve: { _ in [IPv4Address("93.184.216.34")!] },
      exchange: { destination in
        let request = String(decoding: destination.request, as: UTF8.self)
        let path = String(request.split(separator: " ")[1])
        return Data((responses[path] ?? "HTTP/1.1 500 Error\r\n\r\n").utf8)
      })
    func fetch(_ path: String) async throws -> Data {
      try await fetcher.fetch(try #require(URL(string: "https://images.example\(path)")))
    }
    #expect(try await fetch("/start") == Data("abcde".utf8))
    for refused in ["/private", "/plain", "/loop", "/missing"] {
      await #expect(throws: RemoteContentError.refused, "\(refused)") { _ = try await fetch(refused) }
    }
    for unreadable in ["/short", "/framing"] {
      await #expect(throws: RemoteContentError.unavailable, "\(unreadable)") {
        _ = try await fetch(unreadable)
      }
    }
    let oversized = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
      + Data(count: RemoteContentFetcher.byteLimit + 1)
    #expect(throws: RemoteContentError.refused) { _ = try RemoteContentFetcher.response(oversized) }
    // A hostile chunk size must fail as a response, never trap on indexing or integer overflow.
    for chunks in ["\r\n", ";\r\n", "7fffffffffffffff\r\na", "1\r\naXX0\r\n\r\n", "0\r\n"] {
      #expect(throws: RemoteContentError.unavailable) {
        _ = try RemoteContentFetcher.response(
          Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunks).utf8))
      }
    }
    #expect(throws: RemoteContentError.unavailable) {
      _ = try RemoteContentFetcher.response(
        Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n0\r\n\r\n".utf8))
    }
  }

  // A controlled HTTPS server: the request reaches the pinned address with TLS authenticating
  // the original host name, and a certificate for another name is refused.
  @Test func remoteContentAuthenticatesTheOriginalHost() async throws {
    let server = try ImageServer()
    defer { server.stop() }
    let port = try await server.start()
    let anchor = try #require(
      SecCertificateCreateWithData(nil, Data(base64Encoded: Self.fixtureCertificate)! as CFData))
    let fetcher = RemoteContentFetcher(
      resolve: { _ in [IPv4Address("127.0.0.1")!] }, permits: { _ in true },
      exchange: {
        try await RemoteTransport(
          anchors: [anchor], verifyDate: Date(timeIntervalSince1970: 1_780_000_000),
          timeout: .seconds(10)
        ).exchange($0)
      })
    let bytes = try await fetcher.fetch(
      try #require(URL(string: "https://images.test:\(port)/pixel.png")))
    #expect(bytes == Data("PNGDATA".utf8))
    let request = try #require(server.requests.first)
    #expect(request.hasPrefix("GET /pixel.png HTTP/1.1\r\nHost: images.test:\(port)\r\n"))
    #expect(!request.lowercased().contains("cookie:"))
    await #expect(throws: (any Error).self) {
      _ = try await fetcher.fetch(try #require(URL(string: "https://other.test:\(port)/pixel.png")))
    }
    // One presentation meters all wire bytes across independent connections, including headers.
    let reply = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 7\r\n\r\nPNGDATA"
    let budget = RemoteContentBudget(bytes: reply.utf8.count + 1)
    let bounded = RemoteContentFetcher(
      resolve: { _ in [IPv4Address("127.0.0.1")!] }, permits: { _ in true },
      exchange: {
        try await RemoteTransport(
          anchors: [anchor], verifyDate: Date(timeIntervalSince1970: 1_780_000_000),
          timeout: .seconds(10), budget: budget
        ).exchange($0)
      }, budget: budget)
    let target = try #require(URL(string: "https://images.test:\(port)/pixel.png"))
    #expect(try await bounded.fetch(target) == Data("PNGDATA".utf8))
    await #expect(throws: RemoteContentError.refused) { _ = try await bounded.fetch(target) }
    let expired = RemoteContentFetcher(budget: RemoteContentBudget(timeout: .zero))
    await #expect(throws: RemoteContentError.unavailable) { _ = try await expired.fetch(target) }
  }

  // Entries are sealed to their account, mailbox, message and destination; least recently shown
  // entries go first, displayed resources stay, and clearing or removing the mailbox deletes them.
  @Test @MainActor func authorizedRemoteContentCacheIsScopedAndBounded() async throws {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    defer {
      try? keys.remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let cache = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { true })
    let store = google.store(keys: keys, mailCache: cache, deviceRevoked: { _ in false })
    let connection = MailboxConnection.id(subject: google.subject)
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let generation = store.generation(google.subject)
    let account = try #require((try store.load())?.product?.productAccountId)
    // Remote content follows an opened mailbox, whose first commit creates the store key.
    _ = try store.commitMailbox(
      connection: connection, address: google.address, expectedRevision: 0, document: "{}",
      generation: generation)
    let image = Data("remote image bytes".utf8)

    let committed = try await store.commitRemoteContent(
      connection: connection, address: google.address, generation: generation, id: "m1",
      url: "https://images.example/a.png",
      admission: ["data": image.base64EncodedString(), "protected": [[connection, "m1", "https://images.example/a.png"]]])
    #expect(committed["admitted"] as? Bool == true)
    func open(_ id: String, _ url: String, address: String? = nil) async throws -> Any? {
      try await store.openRemoteContent(
        connection: connection, address: address ?? google.address, generation: generation,
        id: id, url: url)["data"]
    }
    #expect(try await open("m1", "https://images.example/a.png") as? String == image.base64EncodedString())
    #expect(try await open("m2", "https://images.example/a.png") is NSNull)
    #expect(try await open("m1", "https://images.example/b.png") is NSNull)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await open("m1", "https://images.example/a.png", address: "other@example.com")
    }

    // A small budget: the least recently shown entry goes, a displayed one stays.
    let small = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { true }, remoteLimit: 200)
    let bytes = Data(repeating: 7, count: 60)
    func admit(_ url: String, protecting: [String] = []) throws -> Bool {
      try small.commitRemoteContent(
        account: account, connection: connection, address: google.address, subject: google.subject, id: "m1", url: url,
        data: bytes, protected: protecting.map { (connection: connection, address: google.address, subject: google.subject, id: "m1", url: $0) })
    }
    func stored(_ url: String) throws -> Bool {
      try small.openRemoteContent(
        account: account, connection: connection, address: google.address, subject: google.subject, id: "m1", url: url)
        != nil
    }
    try small.clearRemoteContent()
    #expect(try admit("https://a.example/1"))
    #expect(try admit("https://a.example/2"))
    _ = try stored("https://a.example/1")
    #expect(try admit("https://a.example/3"))
    #expect(try !stored("https://a.example/2"))
    #expect(try !admit("https://a.example/4", protecting: ["https://a.example/1", "https://a.example/3"]))
    #expect(try stored("https://a.example/1") && stored("https://a.example/3"))
    // A resource larger than the entire budget is refused without evicting anything.
    #expect(
      try !small.commitRemoteContent(
        account: account, connection: connection, address: google.address, subject: google.subject, id: "m1",
        url: "https://a.example/oversized", data: Data(count: 201), protected: []))
    #expect(try stored("https://a.example/1") && stored("https://a.example/3"))

    // Another connection cannot evict displayed resources from the first connection.
    try small.clearRemoteContent()
    #expect(try admit("https://a.example/protected"))
    let otherConnection = MailboxConnection.id(subject: "other-google-subject")
    let protected = [(connection: connection, address: google.address, subject: google.subject,
      id: "m1", url: "https://a.example/protected")]
    #expect(try small.commitRemoteContent(
      account: account, connection: otherConnection, address: google.address, subject: google.subject,
      id: "m1", url: "https://a.example/other", data: bytes, protected: protected))
    #expect(try small.commitRemoteContent(
      account: account, connection: otherConnection, address: google.address, subject: google.subject,
      id: "m1", url: "https://a.example/new", data: bytes, protected: protected))
    #expect(try stored("https://a.example/protected"))
    #expect(try small.openRemoteContent(
      account: account, connection: otherConnection, address: google.address, subject: google.subject,
      id: "m1", url: "https://a.example/other") == nil)

    // Replay the first connection's ciphertext at the other's actual resource file.
    let firstFolder = directory.appendingPathComponent("mailboxes/\(connection)/remote")
    let secondFolder = directory.appendingPathComponent("mailboxes/\(otherConnection)/remote")
    let original = try #require(try FileManager.default.contentsOfDirectory(
      at: firstFolder, includingPropertiesForKeys: nil).first)
    let replacement = try #require(try FileManager.default.contentsOfDirectory(
      at: secondFolder, includingPropertiesForKeys: nil).first)
    try Data(contentsOf: original).write(to: replacement)
    #expect(try small.openRemoteContent(
      account: account, connection: otherConnection, address: google.address, subject: google.subject,
      id: "m1", url: "https://a.example/new") == nil)
    #expect(try stored("https://a.example/protected"))
    #expect(try small.openRemoteContent(
      account: "another-product-account", connection: connection, address: google.address,
      subject: google.subject, id: "m1", url: "https://a.example/protected") == nil)

    // Missing key custody is an error, not permission to delete intact ciphertext.
    let database = DeviceKeychain(service: service + ".database")
    let key = try #require(try database.read("encryption-key"))
    try database.remove("encryption-key")
    #expect(throws: PrivateInboxError.unavailable) { _ = try stored("https://a.example/protected") }
    #expect(FileManager.default.fileExists(atPath: original.path))
    try database.save(key, account: "encryption-key")
    #expect(try stored("https://a.example/protected"))

    // Clear Remote Content removes every entry; removing the mailbox removes its directory.
    try small.clearRemoteContent()
    #expect(try !stored("https://a.example/1"))
    #expect(try admit("https://a.example/5"))
    try small.removeMailbox(connection: connection)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("mailboxes/\(connection)/remote").path))
  }

  // A self-signed `images.test` certificate (P-256, valid 2026-01-01 to 2027-12-01), trusted only
  // as these tests' anchor at a fixed instant, and its PKCS #12 identity (password "fixture").
  static let fixtureCertificate =
    "MIIBmTCCAUCgAwIBAgIUAbaTMUdZdQDYUKQldyUkhotxoBEwCgYIKoZIzj0EAwIwFjEUMBIGA1UEAwwLaW1hZ2VzLnRlc3QwHhcNMjYwMTAxMDAwMDAwWhcNMjcxMjAxMDAwMDAwWjAWMRQwEgYDVQQDDAtpbWFnZXMudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABO+GVcu0EqQJH3sLxJP3bYmfDn5DOTIUk0kCWDLPO0eUxOyV9dPSOqKp2YOLc2nrspd+ugba7rQyHwB2LA9ryL+jbDBqMB0GA1UdDgQWBBQrS+ryB0139HB8kMrotFWPg4Hc8DAWBgNVHREEDzANggtpbWFnZXMudGVzdDATBgNVHSUEDDAKBggrBgEFBQcDATAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDAKBggqhkjOPQQDAgNHADBEAiBtok1JYC6wbQJ36koEmsDJ8sFI/mQUhT+jClA2JbwbUwIgPoYp3BiIxesYE78EY2WRVntpQDJMXXEN9SghYV8aL90="
  static let fixtureIdentity =
    "MIIERAIBAzCCA/IGCSqGSIb3DQEHAaCCA+MEggPfMIID2zCCAooGCSqGSIb3DQEHBqCCAnswggJ3AgEAMIICcAYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBAw0MVajieRY6Y4zbQogyr5AgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQAKmWWa+vrP47iCYWn4u+JoCCAgABUkd9bcsnid8c84axP2zKftOWO4hppXdi3wdE9TvFxmEvOofB9jTEG2tsF3yd8/vyDtoJjCnLEC+fa5dq2IkfFunCfwyBb3Of4AnoGhIUgKUgfCd+sH45qmXV8bfqOcP3DMugo0z3YCwVY8ocHU/Rz+PwRYyxgZTy4bFPdP8+M9r74X3w2ESVeMG6+Y+Am0HIVTKDv3LIuuc3lciwQKHSS/67bVD1ct6UnRYUpfFoQsZqfEnzM/ggeAClpdHBAg/8OMYqUt5/Gzjfqo28551OiU6fSK2wdT0fseVr2ZXHuG9ewbDoG4Bq6Yk2LUyTdmXo3qUjmXBMfnnNnspqGrjT5FHe49KjUQDSjcvWXfJaLza4V6cl+lXoQ9cinYjSUqywcqvZUYjKNYoKnawWCS7YbkFlulgfc0Dr08jENm5IQSEh8dBEink9s3Rj4qvyUZyAiiCtY844lgMa6GudWsn8Ybd6yHPmXHwQvXcUA/WcfyXM3vOTSp1aJZI24EIuqqPu+vliO1jM3X/C1JCu54knaJZDO35ey2/SNE7YQ9bwK1r1oKR0qT0qEk9Eyoy0+Reb+Q0WTmFXL40b7RxHoYzT6P5e5J2ZOqdDFEepv06AMrlcSJ5OkyZJsDkRsdRWeAZiHPwwWZ66FijFjrcMIUCi4tOtj5ZvL/pK5nCGf3g8zTCCAUkGCSqGSIb3DQEHAaCCAToEggE2MIIBMjCCAS4GCyqGSIb3DQEMCgECoIH3MIH0MF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBDq0AKCNtxEWNryb7u7LBk1AgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQlI8g9vS1f3lnWWN3hQsICwSBkE0iqfuGr80IBxgc9wQE+r+ALev8FsTYhgazUAGVgkVkaFe7XewofE08cu4d6BSJAqkh2Uzv3QFphs6Y4RD7ravqVk7MbQbEt+zf1AOl79ByA7B6glGelJXlfbFAdMn6p9M473DmeM4lvn3orwvjXOj3Zy4Ued6NcrmBV0wpmxQCmvoGnpS2peA0RgkxjslEbTElMCMGCSqGSIb3DQEJFTEWBBRhPZcxWYVtRTgTJgt3vDT5MDxuGDBJMDEwDQYJYIZIAWUDBAIBBQAEIC8sgSb9k4IvniZ214Qdy3MeIK4np8w6IcwOOQteLCzVBBBDTfkgkUFfyY8zG1yw7hEXAgIIAA=="
}

// A loopback HTTPS server presenting the fixture identity, answering every request with one image
// and recording the requests it received.
private final class ImageServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.unwired.remote-content.tests")
  private let lock = NSLock()
  private var received: [String] = []
  var requests: [String] { lock.withLock { received } }

  init() throws {
    var items: CFArray?
    let status = SecPKCS12Import(
      Data(base64Encoded: PrivateInboxTests.fixtureIdentity)! as CFData,
      [kSecImportExportPassphrase: "fixture", kSecImportToMemoryOnly: true] as CFDictionary,
      &items)
    guard status == errSecSuccess,
      let entry = (items as? [[String: Any]])?.first,
      let identity = entry[kSecImportItemIdentity as String]
    else { throw RemoteContentError.unavailable }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(
      tls.securityProtocolOptions, sec_identity_create(identity as! SecIdentity)!)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [self] connection in
      connection.start(queue: queue)
      read(connection, Data())
    }
    return try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let error): continuation.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener.cancel() }

  private func read(_ connection: NWConnection, _ buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [self] data, _, complete, error in
      let next = buffer + (data ?? Data())
      if next.range(of: Data("\r\n\r\n".utf8)) != nil {
        lock.withLock { received.append(String(decoding: next, as: UTF8.self)) }
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 7\r\n\r\nPNGDATA"
        connection.send(
          content: Data(reply.utf8), isComplete: true,
          completion: .contentProcessed { _ in connection.cancel() })
      } else if complete || error != nil {
        connection.cancel()
      } else {
        read(connection, next)
      }
    }
  }
}
