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
    google.gmailFailure = RegistrationError.unavailable
    await #expect(throws: PrivateInboxError.deliveryUnknown) {
      _ = try await store.gmailSend(
        segments: segments, threadId: nil, connection: connection, address: google.address,
        generation: generation)
    }
    #expect(google.gmailRequests.count == requests + 2)
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
    backend.offline = true
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await phone.claimDelivery(draft: "draft-3")
    }
  }
}
