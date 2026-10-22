// swiftlint:disable function_body_length
// One journey keeps the assembled upload, its refusals and its unknown outcome together.
import Foundation
import Testing

@testable import PrivateInbox

struct OutboxTests {
  @Test @MainActor func sendInsertsVerifiedFileBytesAndTellsUnknownOutcomesApart() async throws {
    let service = "dev.unwired.outbox.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    let backend = SyntheticProductSyncBackend()
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, productSync: backend.backend,
      deviceRevoked: { [backend] product in backend.revoked.contains(product.trustedDeviceId) },
      transport: { try backend.transport($0) },
      mailCache: PrivateInboxStore(directory: directory, service: service),
      connect: { [backend] identity, device, _ in
        try backend.connect("account-" + identity.subject, device: device)
      })
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync.account-synthetic-subject")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let owner = try #require(try store.load()?.product?.productAccountId)
    let connection = MailboxConnection.id(subject: google.subject)
    let generation = store.generation(google.subject)
    let bytes = Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let imported = try await store.importDraftAsset(
      owner: owner, id: "assetabc123",
      source: ["kind": "data", "uri": "data:image/png;base64," + bytes.base64EncodedString()])
    let digest = try #require(imported["digest"] as? String)
    let head = "Subject: Plan\r\n\r\n--=_b\r\n"
    let segments: [Any] = [
      ["text": head], ["asset": ["id": "assetabc123", "digest": digest]], ["text": "\r\n--=_b--"],
    ]
    google.gmailRequests = []
    // The app lost its execution opportunity while credentials were being refreshed. Nothing
    // reached Gmail, and returning to the foreground permits the same admitted intent later.
    var executionAllowed = true
    store.deliveryAllowed = { executionAllowed }
    google.beforeRefresh = { executionAllowed = false }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmailSend(
        segments: segments, threadId: nil, connection: connection, address: google.address,
        generation: generation)
    }
    #expect(google.gmailRequests.isEmpty)
    google.beforeRefresh = nil
    executionAllowed = true

    let sent = try await store.gmailSend(
      segments: segments, threadId: "thread7", connection: connection, address: google.address,
      generation: generation)

    #expect(sent["status"] as? Int == 200)
    #expect(
      google.gmailRequests.map(\.absoluteString) == [
        "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart"
      ])
    let contentType = try #require(google.gmailContentTypes.last)
    let prefix = "multipart/related; boundary="
    #expect(contentType.hasPrefix(prefix + "unwired-upload-"))
    let boundary = String(contentType.dropFirst(prefix.count))
    let encoded = bytes.base64EncodedString(options: [
      .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
    ])
    let upload = String(decoding: try #require(google.gmailBodies.last ?? nil), as: UTF8.self)
    #expect(
      upload
        == "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
        + #"{"threadId":"thread7"}"#
        + "\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n"
        + head + encoded + "\r\n--=_b--" + "\r\n--\(boundary)--\r\n")
    #expect(encoded.split(separator: "\r\n").allSatisfy { $0.count <= 76 })

    // Malformed segments, bytes the device no longer has, and another mailbox generation reach
    // nothing; each is a definite refusal.
    let requests = google.gmailRequests.count
    for invalid: [Any] in [
      [["text": "Subject: Plán\r\n"]], [["asset": ["id": "../x", "digest": digest]]], ["text"],
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.gmailSend(
          segments: invalid, threadId: nil, connection: connection, address: google.address,
          generation: generation)
      }
    }
    await #expect(throws: PrivateInboxError.attachmentMissing) {
      _ = try await store.gmailSend(
        segments: [["asset": ["id": "assetabc123", "digest": String(repeating: "0", count: 64)]]],
        threadId: nil, connection: connection, address: google.address, generation: generation)
    }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmailSend(
        segments: segments, threadId: "../thread", connection: connection,
        address: google.address, generation: generation)
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmailSend(
        segments: segments, threadId: nil, connection: connection, address: google.address,
        generation: UUID().uuidString)
    }
    #expect(google.gmailRequests.count == requests)

    // A refusal Gmail answers is returned; a failure after the request starts may follow
    // acceptance, so it is unknown rather than a retry.
    google.gmailResponse = (400, Data(#"{"error":{}}"#.utf8))
    let refused = try await store.gmailSend(
      segments: segments, threadId: nil, connection: connection, address: google.address,
      generation: generation)
    #expect(refused["status"] as? Int == 400)
    // A transport failure that proves the request never left this device stays a retry.
    google.gmailFailure = RegistrationError.unavailable
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmailSend(
        segments: segments, threadId: nil, connection: connection, address: google.address,
        generation: generation)
    }
    google.gmailFailure = GmailRequestInterrupted()
    await #expect(throws: PrivateInboxError.deliveryUnknown) {
      _ = try await store.gmailSend(
        segments: segments, threadId: nil, connection: connection, address: google.address,
        generation: generation)
    }
    // A read that fails the same way is only a retry.
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: connection, address: google.address,
        generation: generation)
    }
    #expect(google.gmailRequests.count == requests + 4)
    // URLSession failures that prove nothing left the device are told apart from the rest.
    for code: URLError.Code in [.notConnectedToInternet, .cannotFindHost, .secureConnectionFailed]
    {
      #expect(GmailTransport.failure(URLError(code)) as? RegistrationError == .unavailable)
    }
    for code: URLError.Code in [.networkConnectionLost, .timedOut, .badServerResponse] {
      #expect(GmailTransport.failure(URLError(code)) is GmailRequestInterrupted)
    }
    #expect(GmailTransport.failure(URLError(.cancelled)) is CancellationError)
    // A trust change during credential refresh must be observed before a new provider handoff.
    let device = try #require(try store.load()?.product?.trustedDeviceId)
    let beforeRevocation = google.gmailRequests.count
    google.gmailFailure = nil
    google.beforeRefresh = { backend.revoked.insert(device) }
    await #expect(throws: RegistrationError.revoked) {
      _ = try await store.gmailSend(
        segments: segments, threadId: nil, connection: connection, address: google.address,
        generation: generation)
    }
    #expect(google.gmailRequests.count == beforeRevocation)
  }

  @Test(arguments: [false, true]) @MainActor
  func revokedDeviceNeverRefreshesSendingCredentials(microsoftMailbox: Bool) async throws {
    let service = "dev.unwired.outbox-revoked.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    let backend = SyntheticProductSyncBackend()
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let microsoft = SyntheticMicrosoftMailProvider()
    let account = "account-" + google.subject
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, microsoft: microsoft, productSync: backend.backend,
      deviceRevoked: { [backend] product in backend.revoked.contains(product.trustedDeviceId) },
      transport: { try backend.transport($0) },
      mailCache: PrivateInboxStore(directory: directory, service: service),
      connect: { [backend] identity, device, _ in
        try backend.connect("account-" + identity.subject, device: device)
      })
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? keys.remove("product-sync-enrollment." + account)
      try? keys.remove("product-sync-device-key." + account)
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    var connection = MailboxConnection.id(subject: google.subject)
    var address = google.address
    if microsoftMailbox {
      _ = try await store.signInMailbox(nil, suggest: false, provider: .microsoftGraph)
      let verified = try await store.verifyMailbox()
      connection = try #require(verified["connection"] as? String)
      address = microsoft.address
      try await store.retryMailboxCleanup()
      try store.storeMailbox()
      try await store.synchronizeRegistration()
    }
    let generation = store.mailboxGeneration(connection).uuidString
    let device = try #require(try store.load()?.product?.trustedDeviceId)
    let refreshes = (google.refreshes, microsoft.refreshes)
    google.gmailRequests = []
    microsoft.graphSends = []
    backend.revoked.insert(device)
    let segments: [Any] = [["text": "Subject: Plan\r\n\r\nHello\r\n"]]
    await #expect(throws: RegistrationError.revoked) {
      if microsoftMailbox {
        _ = try await store.graphSend(
          segments: segments, connection: connection, address: address, generation: generation)
      } else {
        _ = try await store.gmailSend(
          segments: segments, threadId: nil, connection: connection, address: address,
          generation: generation)
      }
    }
    #expect(google.refreshes == refreshes.0 && microsoft.refreshes == refreshes.1)
    #expect(google.gmailRequests.isEmpty && microsoft.graphSends.isEmpty)
    #expect(try keys.read("registration") == nil)
  }

  @Test @MainActor func deliveryClaimsNameNoDraftAndAreHeldByOneTrustedDevice() async throws {
    let service = "dev.unwired.outbox-claim.tests.\(UUID().uuidString)"
    let keys = DeviceKeychain(service: service)
    let backend = SyntheticProductSyncBackend()
    let google = SyntheticGoogleRegistrationProvider()
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, productSync: backend.backend,
      deviceRevoked: { [backend] product in backend.revoked.contains(product.trustedDeviceId) },
      transport: { try backend.transport($0) },
      connect: { [backend] identity, device, _ in
        try backend.connect("account-" + identity.subject, device: device)
      })
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync.account-synthetic-subject")
    }
    _ = try await store.signIn()
    let owner = try #require(try store.load()?.product?.productAccountId)
    let phone = try store.draftSync(owner: owner)
    backend.devices[owner, default: []].append("device-mac")
    let mac = DraftSync(
      backend: backend.backend, session: phone.session,
      product: ProductRegistrationReceipt(
        productAccountId: owner, trustedDeviceId: "device-mac",
        trustedDeviceCredential: String(repeating: "a", count: 64)),
      ring: phone.ring)

    #expect(try await phone.claimDelivery(draft: "draft-1")["claimed"] as? Bool == true)
    // Asking again keeps the claim, as after a lost reply; another device is refused.
    #expect(try await phone.claimDelivery(draft: "draft-1")["claimed"] as? Bool == true)
    #expect(try await mac.claimDelivery(draft: "draft-1")["claimed"] as? Bool == false)
    #expect(try await mac.claimDelivery(draft: "draft-2")["owner"] as? String == owner)
    let identifiers = try #require(backend.claims[owner]).keys.sorted()
    #expect(identifiers.count == 2)
    #expect(
      identifiers.allSatisfy {
        $0.range(of: "^draft-delivery\\.[0-9a-f]{32}$", options: .regularExpression) != nil
      })
    // #983: a Sign in with Apple relaunch has no Product Sign-In session. Drafts wait for one, but
    // the device credential still claims, so queued mail sends.
    store.session = nil
    #expect(throws: RegistrationError.unavailable) { _ = try store.draftSync(owner: owner) }
    let relaunched = try store.draftSync(owner: owner, signedIn: false)
    #expect(try await relaunched.claimDelivery(draft: "draft-1")["claimed"] as? Bool == true)
    backend.offline = true
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await phone.claimDelivery(draft: "draft-3")
    }
  }
}
