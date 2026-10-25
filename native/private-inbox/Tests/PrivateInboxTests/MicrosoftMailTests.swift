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
  // Messages sendMail received: URL and base64 MIME body. `sendReply` answers each, or throws as
  // a request interrupted after it started.
  var graphSends: [(url: String, body: Data)] = []
  var sendReply: () throws -> (Int, Data) = { (202, Data()) }
  // Answers every Graph request in place of the replies above when set: method, URL and body.
  var graphReply: ((String, URL, Data?) throws -> (Int, Data))?
  // Upload session ranges as Microsoft receives them, and its answer to each.
  var uploads: [(url: URL, range: String, body: Data)] = []
  var uploadReply: () throws -> (Int, Data) = { (200, Data()) }

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
  func graph(
    _ identity: MicrosoftMailIdentity, url: URL, method: String, body: Data?, contentType: String
  ) async throws -> (Int, Data) {
    if let graphReply { return try graphReply(method, url, body) }
    guard let body else {
      graphRequests.append(url)
      return (200, Data(#"{"value":[]}"#.utf8))
    }
    if contentType == "text/plain" {
      graphSends.append((url.absoluteString, body))
      return try sendReply()
    }
    graphWrites.append(
      (method, url.absoluteString,
       try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]))
    return (200, Data(#"{"id":"AAMk-id=","parentFolderId":"AQMk-archive=","isRead":true}"#.utf8))
  }
  func upload(url: URL, body: Data, range: String) async throws -> (Int, Data) {
    uploads.append((url, range, body))
    return try uploadReply()
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
    let mime = "From: casey@example.invalid\r\nTo: sam@example.invalid\r\n\r\nHello\r\n"
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.graphSend(
        segments: [["text": mime]], connection: id, address: "casey@example.invalid",
        generation: generation)
    }
    #expect(microsoft.refreshes == beforeProofFailure)
    #expect(microsoft.graphWrites.isEmpty && microsoft.graphSends.isEmpty)
    proofUnavailable = false

    // Sending writes the whole message, base64 encoded, to sendMail; Graph accepts it with 202.
    let sent = try await store.graphSend(
      segments: [["text": mime]], connection: id, address: "casey@example.invalid",
      generation: generation)
    #expect(sent["status"] as? Int == 202)
    #expect(microsoft.graphSends.map(\.url) == ["https://graph.microsoft.com/v1.0/me/sendMail"])
    #expect(microsoft.graphSends.first.flatMap { Data(base64Encoded: $0.body) } == Data(mime.utf8))
    // Malformed segments and a message over Graph's request limit never reach Microsoft.
    for segments in [[["text": "Žluťoučký kůň"]], [["asset": ["id": "../x", "digest": "00"]]]] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.graphSend(
          segments: segments, connection: id, address: "casey@example.invalid",
          generation: generation)
      }
    }
    await #expect(throws: PrivateInboxError.tooLarge) {
      _ = try await store.graphSend(
        segments: [["text": String(repeating: "a", count: RegistrationStore.graphMessageLimit + 1)]],
        connection: id, address: "casey@example.invalid", generation: generation)
    }
    #expect(microsoft.graphSends.count == 1)
    // A request that never left this device may be sent again; one interrupted later may already
    // be sent, so its outcome is unknown.
    microsoft.sendReply = { throw RegistrationError.unavailable }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.graphSend(
        segments: [["text": mime]], connection: id, address: "casey@example.invalid",
        generation: generation)
    }
    microsoft.sendReply = { throw GmailRequestInterrupted() }
    await #expect(throws: PrivateInboxError.deliveryUnknown) {
      _ = try await store.graphSend(
        segments: [["text": mime]], connection: id, address: "casey@example.invalid",
        generation: generation)
    }
    microsoft.sendReply = { (202, Data()) }

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
    // A connection granted only reading, or reading and organizing, keeps its grant on refresh;
    // organizing and sending ask again.
    #expect(GraphMailProvider.refreshScopes(["Mail.Read", "User.Read"]) == "offline_access User.Read Mail.Read")
    #expect(
      GraphMailProvider.refreshScopes(["https://graph.microsoft.com/Mail.ReadWrite"])
        == "offline_access User.Read Mail.ReadWrite")
    #expect(
      GraphMailProvider.refreshScopes([
        "https://graph.microsoft.com/Mail.ReadWrite", "https://graph.microsoft.com/Mail.Send",
      ]) == GraphMailProvider.scopes)
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
      method: "PATCH", body: Data(#"{"isRead":true}"#.utf8), contentType: "application/json")
    #expect(written.0 == 200)
    let write = try #require(ControlledMicrosoftHTTP.probe.requests().last)
    #expect(write.httpMethod == "PATCH")
    #expect(write.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(write.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true)
    // A send carries the base64 encoded message as text.
    _ = try await provider.graph(
      identity, url: #require(URL(string: GraphMailProvider.graph + "/me/sendMail")),
      method: "POST", body: Data("RnJvbTo=".utf8), contentType: "text/plain")
    let send = try #require(ControlledMicrosoftHTTP.probe.requests().last)
    #expect(send.httpMethod == "POST")
    #expect(send.value(forHTTPHeaderField: "Content-Type") == "text/plain")
    // An upload session's range goes to its own pre-authorized URL without the Graph token.
    let uploadURL = "https://outlook.office.com/api/v2.0/me/Messages('AAMk-id=')/AttachmentSessions('s')?authtoken=t"
    _ = try await provider.upload(
      url: #require(URL(string: uploadURL)), body: Data([1, 2, 3]), range: "bytes 0-2/3")
    let range = try #require(ControlledMicrosoftHTTP.probe.requests().last)
    #expect(range.url?.absoluteString == uploadURL && range.httpMethod == "PUT")
    #expect(range.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(range.value(forHTTPHeaderField: "Content-Range") == "bytes 0-2/3")
    #expect(range.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
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

  // A message too large for one sendMail request becomes an Outlook draft before its handoff: the
  // drafts an interrupted attempt left under its Message-ID are deleted, its MIME without files is
  // saved, a small file is attached in one request and a large one through an upload session,
  // which never receives the Graph token. A refusal deletes the new draft; only sending the draft
  // can be unknown.
  @Test @MainActor func largeMicrosoftMessagesBecomeDraftsWithVerifiedFiles() async throws {
    let service = "dev.unwired.microsoft-drafts.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    let account = "account-synthetic-subject"
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let google = SyntheticGoogleRegistrationProvider()
    let microsoft = SyntheticMicrosoftMailProvider()
    microsoft.scopes = ["Mail.ReadWrite", "Mail.Send", "User.Read", "offline_access"]
    let backend = SyntheticProductSyncBackend()
    var proofUnavailable = false
    var revoked = false
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, microsoft: microsoft, productSync: backend.backend,
      deviceRevoked: { _ in
        if proofUnavailable { throw RegistrationError.unavailable }
        return revoked
      }, transport: { try backend.transport($0) },
      mailCache: PrivateInboxStore(directory: directory, service: service),
      connect: { identity, device, _ in
        try backend.connect("account-" + identity.subject, device: device)
      })
    _ = try await store.signIn()
    let owner = try #require(try store.load()?.product?.productAccountId)
    _ = try await store.signInMailbox(nil, suggest: true, provider: .microsoftGraph)
    let id = try #require(try await store.verifyMailbox()["connection"] as? String)
    try await store.retryMailboxCleanup()
    try store.storeMailbox()
    let generation = store.mailboxGeneration(id).uuidString
    let address = microsoft.address

    func imported(_ asset: String, _ bytes: Data) async throws -> [String: Any] {
      let stored = try await store.importDraftAsset(
        owner: owner, id: asset,
        source: ["kind": "data", "uri": "data:image/png;base64," + bytes.base64EncodedString()])
      return ["id": asset, "digest": try #require(stored["digest"] as? String)]
    }
    let small = Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let large = Data((0..<(RegistrationStore.graphUploadRange + 10)).map {
      UInt8(truncatingIfNeeded: $0 &* 13)
    })
    let files: [Any] = [
      [
        "asset": try await imported("assetsmall1", small), "name": "chart.png", "type": "image/png",
        "contentId": "assetsmall1@unwired.invalid",
      ],
      ["asset": try await imported("assetlarge1", large), "name": "plan.pdf", "type": "application/pdf"],
    ]
    let mime = "From: casey@example.invalid\r\nMessage-ID: <m1.b1@example.invalid>\r\n\r\nHello\r\n"
    let messages = "https://graph.microsoft.com/v1.0/me/messages"
    var writes: [(request: String, body: Data?)] = []
    var leftover = true
    microsoft.graphReply = { method, url, body in
      writes.append(("\(method) \(url.absoluteString)", body))
      switch (method, url.path) {
      case ("GET", "/v1.0/me/mailFolders/drafts/messages"):
        return (200, Data((leftover ? #"{"value":[{"id":"AAMk-left="}]}"# : #"{"value":[]}"#).utf8))
      case ("DELETE", _): return (204, Data())
      case ("POST", "/v1.0/me/messages"): return (201, Data(#"{"id":"AAMk-draft="}"#.utf8))
      case ("POST", "/v1.0/me/messages/AAMk-draft=/attachments"): return (201, Data("{}".utf8))
      case ("POST", "/v1.0/me/messages/AAMk-draft=/attachments/createUploadSession"):
        return (201, Data(#"{"uploadUrl":"https://outlook.office.com/api/v2.0/Messages('AAMk-draft=')/AttachmentSessions('s1')?authtoken=t"}"#.utf8))
      case ("POST", "/v1.0/me/messages/AAMk-draft=/send"): return try microsoft.sendReply()
      default: return (400, Data())
      }
    }
    func prepare(_ files: [Any]) async throws -> [String: Any] {
      try await store.graphPrepare(
        segments: [["text": mime]], messageId: "m1.b1@example.invalid", files: files,
        connection: id, address: address, generation: generation)
    }
    func rangeReply() throws -> (Int, Data) {
      let range = try #require(microsoft.uploads.last?.range)
      let final = "bytes \(RegistrationStore.graphUploadRange)-\(large.count - 1)/\(large.count)"
      return (range == final ? 201 : 200, Data())
    }
    microsoft.uploadReply = rangeReply

    let kept = try await prepare(files)
    #expect(kept["status"] as? Int == 201 && kept["body"] as? String == #"{"id":"AAMk-draft="}"#)
    #expect(writes.map(\.request) == [
      "GET https://graph.microsoft.com/v1.0/me/mailFolders/drafts/messages?$filter=internetMessageId%20eq%20'%3Cm1.b1@example.invalid%3E'&$select=id",
      "DELETE \(messages)/AAMk-left=",
      "POST \(messages)",
      "POST \(messages)/AAMk-draft=/attachments",
      "POST \(messages)/AAMk-draft=/attachments/createUploadSession",
    ])
    #expect(writes[2].body.flatMap { Data(base64Encoded: $0) } == Data(mime.utf8))
    func json(_ index: Int) throws -> NSDictionary {
      let body = try #require(writes[index].body)
      return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }
    #expect(try json(3) == [
      "@odata.type": "#microsoft.graph.fileAttachment", "name": "chart.png",
      "contentType": "image/png", "isInline": true, "contentId": "assetsmall1@unwired.invalid",
      "contentBytes": small.base64EncodedString(),
    ])
    #expect(try json(4) == [
      "AttachmentItem": [
        "attachmentType": "file", "name": "plan.pdf", "contentType": "application/pdf",
        "isInline": false, "size": large.count,
      ],
    ])
    #expect(microsoft.uploads.map(\.range) == [
      "bytes 0-\(RegistrationStore.graphUploadRange - 1)/\(large.count)",
      "bytes \(RegistrationStore.graphUploadRange)-\(large.count - 1)/\(large.count)",
    ])
    #expect(microsoft.uploads.reduce(Data()) { $0 + $1.body } == large)
    #expect(microsoft.uploads.allSatisfy { $0.url.host == "outlook.office.com" })

    // Each range requires fresh device proof, even though its URL carries upload permission.
    let beforeUnavailable = microsoft.uploads.count
    microsoft.uploadReply = {
      proofUnavailable = true
      return (200, Data())
    }
    await #expect(throws: RegistrationError.unavailable) { _ = try await prepare(files) }
    #expect(microsoft.uploads.count == beforeUnavailable + 1)
    proofUnavailable = false
    microsoft.uploadReply = rangeReply

    // Sending the draft is the only request whose outcome may be unknown.
    let sent = try await store.graphSendDraft(
      draft: "AAMk-draft=", connection: id, address: address, generation: generation)
    #expect(sent["status"] as? Int == 202 && writes.last?.request == "POST \(messages)/AAMk-draft=/send")
    microsoft.sendReply = { throw GmailRequestInterrupted() }
    await #expect(throws: PrivateInboxError.deliveryUnknown) {
      _ = try await store.graphSendDraft(
        draft: "AAMk-draft=", connection: id, address: address, generation: generation)
    }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.graphSendDraft(
        draft: "../send", connection: id, address: address, generation: generation)
    }

    // Only Graph's final 201 confirms the attachment. An incomplete or unexpected success must
    // not make the draft sendable without its file.
    for status in [200, 201, 202, 204] {
      microsoft.uploadReply = { (status, Data()) }
      writes = []
      await #expect(throws: RegistrationError.unavailable) { _ = try await prepare(files) }
      #expect(writes.last?.request == "DELETE \(messages)/AAMk-draft=")
    }

    // A refused range returns Microsoft's answer and deletes the new draft; an upload URL outside
    // Microsoft, or a file whose bytes no longer verify, reaches nothing and deletes it too.
    leftover = false
    microsoft.uploadReply = { (500, Data("busy".utf8)) }
    writes = []
    let refused = try await prepare(files)
    #expect(refused["status"] as? Int == 500 && refused["body"] as? String == "busy")
    #expect(writes.last?.request == "DELETE \(messages)/AAMk-draft=")
    microsoft.uploadReply = rangeReply
    let reply = try #require(microsoft.graphReply)
    microsoft.graphReply = { method, url, body in
      url.path.hasSuffix("/createUploadSession")
        ? (201, Data(#"{"uploadUrl":"https://uploads.example.invalid/s?authtoken=t"}"#.utf8))
        : try reply(method, url, body)
    }
    let uploaded = microsoft.uploads.count
    writes = []
    await #expect(throws: RegistrationError.unavailable) { _ = try await prepare(files) }
    #expect(microsoft.uploads.count == uploaded)
    #expect(writes.last?.request == "DELETE \(messages)/AAMk-draft=")
    writes = []
    let missing: [Any] = [[
      "asset": ["id": "assetsmall1", "digest": String(repeating: "0", count: 64)],
      "name": "chart.png", "type": "image/png",
    ]]
    await #expect(throws: PrivateInboxError.attachmentMissing) { _ = try await prepare(missing) }
    #expect(writes.last?.request == "DELETE \(messages)/AAMk-draft=")
    // Malformed files or Message-IDs are refused before any request.
    writes = []
    for invalid: [Any] in [
      [["asset": ["id": "../x", "digest": String(repeating: "0", count: 64)], "name": "a", "type": "image/png"]],
      [["asset": ["id": "assetsmall1", "digest": String(repeating: "0", count: 64)], "name": "a", "type": "image png"]],
    ] {
      await #expect(throws: RegistrationError.unavailable) { _ = try await prepare(invalid) }
    }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.graphPrepare(
        segments: [["text": mime]], messageId: "m1' or 1 eq 1", files: [], connection: id,
        address: address, generation: generation)
    }
    #expect(writes.isEmpty)

    // Cleanup resumes after a lost reply and removes every matching draft, including another
    // page whose offset would change as messages disappear.
    var remaining = ["AAMk-orphan1=", "AAMk-orphan2="]
    microsoft.graphReply = { method, url, _ in
      if method == "GET" {
        let found = remaining.first.map { [["id": $0]] } ?? []
        return (200, try JSONSerialization.data(withJSONObject: ["value": found]))
      }
      if method == "DELETE", let draft = remaining.first, url.path.hasSuffix(draft) {
        remaining.removeFirst()
        return (204, Data())
      }
      return (400, Data())
    }
    let cleaned = try await store.graphDiscard(messageId: "m1.b1@example.invalid", connection: id,
      address: address, generation: generation)
    #expect(cleaned["status"] as? Int == 204 && remaining.isEmpty)

    // A positive revocation between ranges purges local authorization before any later PUT.
    microsoft.graphReply = reply
    let beforeRevoked = microsoft.uploads.count
    microsoft.uploadReply = {
      revoked = true
      return (200, Data())
    }
    await #expect(throws: RegistrationError.revoked) { _ = try await prepare(files) }
    #expect(microsoft.uploads.count == beforeRevoked + 1)
    #expect(try store.load() == nil)
  }

}
