import Foundation
import Testing

@testable import PrivateInbox

// Only HTTP responses are controlled; the production adapter builds and decodes each request.
private final class MicrosoftHTTPProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [URLRequest] = []
  func record(_ request: URLRequest) {
    lock.lock()
    defer { lock.unlock() }
    captured.append(request)
  }
  func requests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }
}
private final class ControlledMicrosoftHTTP: URLProtocol, @unchecked Sendable {
  static let probe = MicrosoftHTTPProbe()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.probe.record(request)
    let url = request.url!
    // A request that cannot leave this device, as without a network.
    if request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-offline" {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let denied = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-denied"
    let body: String
    if url.path.hasSuffix("/token") {
      body = #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,"scope":"User.Read Mail.Read"}"#
    } else if url.path == "/v1.0/me" {
      body = #"{"id":"synthetic-microsoft","mail":"casey@example.invalid","userPrincipalName":"casey@example.invalid"}"#
    } else {
      body = #"{"id":"synthetic-inbox"}"#
    }
    let response = HTTPURLResponse(url: url, statusCode: denied ? 403 : 200,
      httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

// A controlled Microsoft authorization and Graph mailbox.
@MainActor final class SyntheticMicrosoftMailProvider: MicrosoftMailProvider {
  var subject = "synthetic-microsoft-account"
  var address = "casey@example.invalid"
  var scopes: Set<String> = ["Mail.Read", "User.Read", "offline_access"]
  var mailboxAvailable = true
  var refreshFailure: (any Error)?
  var hints: [String?] = []
  var refreshes = 0
  var graphRequests: [URL] = []
  // Writes as Graph receives them: method, URL and JSON body.
  var graphWrites: [(method: String, url: String, body: [String: Any])] = []

  private func identity() -> MicrosoftMailIdentity {
    MicrosoftMailIdentity(
      credential: Data("microsoft#\(refreshes)".utf8), accessToken: "synthetic-graph-token",
      scopes: scopes)
  }
  func signIn(hint: String?) async throws -> MicrosoftMailIdentity {
    hints.append(hint)
    return identity()
  }
  func refresh(_ credential: Data) async throws -> MicrosoftMailIdentity {
    if let refreshFailure { throw refreshFailure }
    refreshes += 1
    return identity()
  }
  func verify(_ identity: MicrosoftMailIdentity) async throws -> GmailRegistrationReceipt {
    guard mailboxAvailable else { throw RegistrationError.gmailUnavailable }
    return GmailRegistrationReceipt(subject: subject, address: address, provider: .microsoftGraph)
  }
  func graph(_ identity: MicrosoftMailIdentity, url: URL, method: String, body: Data?)
    async throws -> (Int, Data)
  {
    guard let body else {
      graphRequests.append(url)
      return (200, Data(#"{"value":[]}"#.utf8))
    }
    graphWrites.append(
      (method, url.absoluteString,
       try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]))
    return (200, Data(#"{"id":"AAMk-id=","parentFolderId":"AQMk-archive=","isRead":true}"#.utf8))
  }
}

extension PrivateInboxTests {
  // A Microsoft mailbox is its own connection beside Gmail, even for an account identifier Gmail
  // also uses: its own connection ID, credential and Product Sync descriptor record. Graph reads
  // reach only the person's own mail, Gmail never receives its credential, a refused grant asks
  // for Microsoft again, and removal leaves only its own descriptor to mark removed.
  @Test @MainActor func microsoftMailConnectsBesideGmailAndReadsOnlyItsOwnMail() async throws {
    let keys = DeviceKeychain(service: "dev.unwired.product-sync.tests.\(UUID().uuidString)")
    let account = "account-synthetic-product-subject"
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? keys.remove("product-sync-enrollment." + account)
      try? keys.remove("product-sync-device-key." + account)
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let microsoft = SyntheticMicrosoftMailProvider()
    microsoft.subject = "synthetic-product-subject"
    let backend = SyntheticProductSyncBackend()
    var proofUnavailable = false
    var revoked = false
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, microsoft: microsoft, productSync: backend.backend,
      deviceRevoked: { _ in
        if proofUnavailable { throw RegistrationError.unavailable }
        return revoked
      },
      transport: { try backend.transport($0) },
      connect: { identity, device, _ in
        try backend.connect("account-" + identity.subject, device: device)
      })
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let googlePrompts = google.hints

    // The vault operations in the order TypeScript's flow adds a Microsoft mailbox.
    let granted = try await store.signInMailbox(nil, suggest: true, provider: .microsoftGraph)
    #expect(granted["scopes"] as? [String] == ["Mail.Read", "User.Read", "offline_access"])
    // A Google Product Sign-In is never a Microsoft account hint.
    #expect(microsoft.hints == [nil])
    let verified = try await store.verifyMailbox()
    let id = try #require(verified["connection"] as? String)
    #expect(id != MailboxConnection.id(subject: "synthetic-product-subject"))
    #expect(verified["address"] as? String == "casey@example.invalid")
    try await store.retryMailboxCleanup()
    try store.storeMailbox()
    try await store.synchronizeRegistration()
    let listed = try #require(try store.registration()?["mailboxes"] as? [[String: Any]])
    #expect(listed.map { $0["provider"] as? String } == ["gmail", "microsoft-graph"])
    #expect(listed.map { $0["address"] as? String } == ["same@example.invalid", "casey@example.invalid"])

    // TypeScript publishes each descriptor under the record native names, by provider account.
    let ring = try #require(try store.loadVault(account)).ring
    let gmailRecord = try ring.identifier("mailbox", "gmail:synthetic-product-subject")
    let microsoftRecord = try ring.identifier("mailbox", "microsoft-graph:synthetic-product-subject")
    func synced(_ key: String) throws -> [[String: Any]] {
      let state = try store.productSyncState(try #require(try store.load()))
      return try #require((state?["vault"] as? [String: Any])?[key] as? [[String: Any]])
    }
    #expect(try synced("mailboxes").map { $0["record"] as? String } == [gmailRecord, microsoftRecord])

    let generation = store.mailboxGeneration(id).uuidString
    let inbox = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$top=200"
    let reply = try await store.graph(
      url: inbox, connection: id, address: "casey@example.invalid", generation: generation)
    #expect(reply["status"] as? Int == 200)
    #expect(microsoft.graphRequests.map(\.absoluteString) == [inbox])
    // The renewed tokens stay with the connection.
    #expect(try store.load()?.connection(id)?.credential == Data("microsoft#1".utf8))
    for refused in [
      "https://graph.microsoft.com/v1.0/me/sendMail",
      "https://graph.microsoft.com/v1.0/users/other@example.invalid/messages",
      "https://graph.microsoft.com/v1.0/me/messages/a%2F..%2Fsend",
      "https://graph.microsoft.com.example.invalid/v1.0/me/messages/a",
      "http://graph.microsoft.com/v1.0/me/messages/a",
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.graph(
          url: refused, connection: id, address: "casey@example.invalid", generation: generation)
      }
    }
    #expect(microsoft.graphRequests.count == 1)

    // Cache preflight permits offline reads, but neither Graph mutation may use an old proof.
    proofUnavailable = true
    try await store.prepareMailbox(id)
    let beforeProofFailure = microsoft.refreshes
    for (read, folder) in [(true, nil), (nil, "archive")] as [(Bool?, String?)] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.graphModify(
          message: "AAMk-id=", read: read, folder: folder, connection: id,
          address: "casey@example.invalid", generation: generation)
      }
    }
    #expect(microsoft.refreshes == beforeProofFailure)
    #expect(microsoft.graphWrites.isEmpty)
    proofUnavailable = false

    // Organizing writes one message's read state or moves it, in a request native code builds.
    _ = try await store.graphModify(
      message: "AAMk-id=", read: true, folder: nil, connection: id,
      address: "casey@example.invalid", generation: generation)
    _ = try await store.graphModify(
      message: "AAMk-id=", read: nil, folder: "archive", connection: id,
      address: "casey@example.invalid", generation: generation)
    #expect(microsoft.graphWrites.map { "\($0.method) \($0.url)" } == [
      "PATCH https://graph.microsoft.com/v1.0/me/messages/AAMk-id=",
      "POST https://graph.microsoft.com/v1.0/me/messages/AAMk-id=/move",
    ])
    #expect(microsoft.graphWrites.map { $0.body as NSDictionary } == [
      ["isRead": true], ["destinationId": "archive"],
    ])
    for (message, read, folder) in [
      ("a/../send", true, nil), ("AAMk-id=", nil, nil), ("AAMk-id=", true, "archive"),
      ("AAMk-id=", nil, "../sendMail"),
    ] as [(String, Bool?, String?)] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.graphModify(
          message: message, read: read, folder: folder, connection: id,
          address: "casey@example.invalid", generation: generation)
      }
    }
    #expect(microsoft.graphWrites.count == 2)
    google.gmailRequests = []
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: id, address: "casey@example.invalid",
        generation: generation)
    }
    #expect(google.gmailRequests.isEmpty)

    microsoft.refreshFailure = RegistrationError.gmailUnavailable
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.graph(
        url: inbox, connection: id, address: "casey@example.invalid", generation: generation)
    }
    // Reauthorization stays with Microsoft and suggests the connection's own account.
    microsoft.refreshFailure = nil
    _ = try await store.signInMailbox(id, suggest: true)
    #expect(microsoft.hints.last == "casey@example.invalid")
    _ = try await store.verifyMailbox()
    try store.confirmMailbox(id)
    // Microsoft authorization never prompts Google.
    #expect(google.hints == googlePrompts)

    // Only Gmail watches deliver wakes: routing never hands the Microsoft credential to Google,
    // and the host keeps polling while Microsoft mail has no route.
    let refreshes = google.refreshes
    try await store.routeMailboxes(
      device: PushDevice(token: "0a1b2c", environment: "sandbox"),
      topic: "projects/synthetic-project/topics/gmail-push", now: 0)
    #expect(google.refreshes == refreshes + 1)
    #expect(try store.mailboxRoutes(now: 0)["complete"] as? Bool == false)

    _ = try await store.flowRemoveMailbox(id)
    let removals = try synced("removals")
    #expect(removals.map { $0["record"] as? String } == [microsoftRecord])
    #expect(removals.map { $0["provider"] as? String } == ["microsoft-graph"])
    #expect(removals.map { $0["id"] as? String } == [id])
    #expect(try store.load()?.connections.map(\.receipt.mailProvider) == [.gmail])

    // Reconnecting explicitly restores access; revocation before a write purges that access.
    _ = try await store.signInMailbox(nil, suggest: false, provider: .microsoftGraph)
    _ = try await store.verifyMailbox()
    try await store.retryMailboxCleanup()
    try store.storeMailbox()
    try await store.synchronizeRegistration()
    let renewed = store.mailboxGeneration(id).uuidString
    let beforeRevocation = microsoft.refreshes
    revoked = true
    await #expect(throws: RegistrationError.revoked) {
      _ = try await store.graphModify(
        message: "AAMk-id=", read: nil, folder: "archive", connection: id,
        address: "casey@example.invalid", generation: renewed)
    }
    #expect(microsoft.refreshes == beforeRevocation)
    #expect(microsoft.graphWrites.count == 2)
    #expect(try keys.read("registration") == nil)
    #expect(try keys.read("product-sync." + account) == nil)
  }

  // The authorization callback names the outcome: a code for this request, a declined consent,
  // or a tenant or account Microsoft does not admit. PKCE follows RFC 7636.
  @Test @MainActor func microsoftAuthorizationCallbacksMapToSetupOutcomes() async throws {
    func code(_ query: String) throws -> String {
      try GraphMailProvider.authorizationCode(
        #require(URL(string: "msauth.dev.unwired.mail://auth?" + query)), state: "expected",
        callbackScheme: "msauth.dev.unwired.mail")
    }
    #expect(try code("code=granted&state=expected") == "granted")
    #expect(throws: RegistrationError.declined) { try code("error=access_denied&state=expected") }
    #expect(throws: RegistrationError.gmailUnavailable) {
      try code("error=consent_required&state=expected")
    }
    #expect(throws: RegistrationError.unavailable) { try code("code=granted&state=other") }
    #expect(throws: RegistrationError.unavailable) { try code("error=access_denied&state=other") }
    #expect(throws: RegistrationError.unavailable) { try code("error=access_denied") }
    #expect(throws: RegistrationError.unavailable) { try code("code=granted&state=expected&state=other") }
    #expect(throws: RegistrationError.unavailable) {
      try GraphMailProvider.authorizationCode(
        #require(URL(string: "msauth.dev.unwired.mail://other?code=granted&state=expected")),
        state: "expected", callbackScheme: "msauth.dev.unwired.mail")
    }
    #expect(
      GraphMailProvider.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledMicrosoftHTTP.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = GraphMailProvider(
      clientID: "synthetic-client", callbackScheme: "msauth.dev.unwired.mail",
      authenticate: { url, _ in
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "scope" }?.value == GraphMailProvider.scopes)
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        let state = try #require(query.first { $0.name == "state" }?.value)
        return try #require(URL(string: "msauth.dev.unwired.mail://auth?code=synthetic-code&state=" + state))
      }, session: session)
    let identity = try await provider.signIn(hint: nil)
    #expect(identity.scopes == ["User.Read", "Mail.Read"])
    let mailbox = try await provider.verify(identity)
    #expect(mailbox.subject == "synthetic-microsoft" && mailbox.mailProvider == .microsoftGraph)
    #expect(mailbox.address == "casey@example.invalid")
    let expired = MicrosoftTokens(
      accessToken: "synthetic-expired", refreshToken: "synthetic-old-refresh",
      expiresAt: .distantPast, scopes: ["Mail.Read"])
    // A connection granted only reading keeps reading on refresh; organizing asks again.
    #expect(GraphMailProvider.refreshScopes(["Mail.Read", "User.Read"]) == "offline_access User.Read Mail.Read")
    #expect(GraphMailProvider.refreshScopes(["https://graph.microsoft.com/Mail.ReadWrite"]) == GraphMailProvider.scopes)
    let refreshed = try await provider.refresh(JSONEncoder().encode(expired))
    #expect(try JSONDecoder().decode(MicrosoftTokens.self, from: refreshed.credential).refreshToken == "synthetic-refresh")
    let requests = ControlledMicrosoftHTTP.probe.requests()
    let tokenRequests = requests.filter { $0.url?.path.hasSuffix("/token") == true }
    #expect(tokenRequests.count == 2)
    #expect(tokenRequests.allSatisfy { $0.httpMethod == "POST" })
    #expect(tokenRequests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded" })
    #expect(tokenRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    // A write is sent with its own method, JSON body and immutable IDs.
    let written = try await provider.graph(
      identity, url: #require(URL(string: GraphMailProvider.graph + "/me/messages/AAMk-id=")),
      method: "PATCH", body: Data(#"{"isRead":true}"#.utf8))
    #expect(written.0 == 200)
    let write = try #require(ControlledMicrosoftHTTP.probe.requests().last)
    #expect(write.httpMethod == "PATCH")
    #expect(write.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(write.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true)
    let graph = ControlledMicrosoftHTTP.probe.requests().filter {
      $0.url?.host == "graph.microsoft.com" && $0.httpMethod == "GET"
    }
    #expect(graph.map { $0.url!.path } == ["/v1.0/me", "/v1.0/me/mailFolders/inbox"])
    #expect(graph.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access" })
    #expect(graph.allSatisfy { $0.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true })
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await provider.verify(MicrosoftMailIdentity(
        credential: Data(), accessToken: "synthetic-denied", scopes: ["Mail.Read"]))
    }
    // Offline verification is transient, so the flow keeps the saved Inbox open instead of asking
    // for Microsoft again.
    do {
      _ = try await provider.verify(MicrosoftMailIdentity(
        credential: Data(), accessToken: "synthetic-offline", scopes: ["Mail.Read"]))
      Issue.record("Offline verification succeeded")
    } catch {
      #expect(RegistrationStore.rejectionCode(error) == "offline")
    }
    for path in [
      "/v1.0/me/mailfolders('AQMk-id=')/messages/delta?$skiptoken=opaque",
      "/v1.0/me/mailFolders/AQMk-id=/messages/delta?$deltatoken=opaque",
      "/v1.0/me/mailfolders('AQMk-id=')/messages?$skip=50",
      "/v1.0/me/mailFolders/inbox/messages/AAMk-id=?$select=id",
      "/v1.0/me/messages/AAMk-id=/attachments?$skip=50",
      "/v1.0/me/mailFolders?$select=id,displayName&$top=100",
      "/v1.0/me/mailFolders/deleteditems?$select=id",
      "/v1.0/me/mailFolders/AQMk-id=/childFolders?$select=id,displayName&$top=100",
      "/v1.0/me/messages/AAMk-id=?$select=id,parentFolderId,isRead",
      "/v1.0/me/messages?$search=%22plan%22&$top=20",
    ] {
      #expect(try RegistrationStore.graphURL("https://graph.microsoft.com" + path).host == "graph.microsoft.com")
    }
  }
}
