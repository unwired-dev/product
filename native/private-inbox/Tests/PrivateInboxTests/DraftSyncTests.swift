// swiftlint:disable function_body_length
// One journey keeps both devices' records, chunks and rejected tampering together.
import Foundation
import Testing

@testable import PrivateInbox

struct DraftSyncTests {
  @Test @MainActor func draftsAndFilesSynchronizeSealedToTheirAccountDraftAndPosition() async throws
  {
    let service = "dev.unwired.draft-sync.tests.\(UUID().uuidString)"
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
    let owner = try #require(try store.load()?.product?.productAccountId)
    let phone = try store.draftSync(owner: owner)
    // Work prepared for another Product Account is refused.
    #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try store.draftSync(owner: "another-account")
    }
    // Another Trusted Device of the account, holding the same keys.
    backend.devices[owner, default: []].append("device-mac")
    let mac = DraftSync(
      backend: backend.backend, session: phone.session,
      product: ProductRegistrationReceipt(
        productAccountId: owner, trustedDeviceId: "device-mac",
        trustedDeviceCredential: String(repeating: "a", count: 64)),
      ring: phone.ring)

    // A Draft record holds ciphertext under an opaque identifier.
    let json = #"{"id":"draft-1","subject":"Private draft subject"}"#
    let pushed = try await phone.push(id: "draft-1", version: 1, draft: json, expected: nil)
    #expect(pushed["committed"] as? Bool == true)
    let updatedAt = try #require(pushed["updatedAt"] as? Double)
    let identifier = try phone.identifier(draft: "draft-1")
    #expect(identifier.hasPrefix("draft.") && !identifier.contains("draft-1"))
    let stored = try #require(backend.records[owner]?[identifier])
    let ciphertext = try #require(Data(base64Encoded: stored.encryptedPayload.ciphertextBase64))
    #expect(ciphertext.range(of: Data("Private draft subject".utf8)) == nil)

    let pulled = try await mac.pull(known: [])
    let records = try #require(pulled["records"] as? [[String: Any]])
    #expect(records.count == 1)
    #expect(records.first?["id"] as? String == "draft-1")
    #expect(records.first?["version"] as? Int == 1)
    #expect(records.first?["draft"] as? String == json)
    #expect(records.first?["updatedAt"] as? Double == updatedAt)
    // A write against an older revision is not committed.
    let stale = try await mac.push(id: "draft-1", version: 2, draft: "{}", expected: updatedAt - 1)
    #expect(stale["committed"] as? Bool == false)

    // A record moved under another Draft's identifier is reported unreadable for that known Draft
    // and never listed. Another account's keys cannot even locate the records.
    let moved = try phone.identifier(draft: "draft-2")
    backend.records[owner]?[moved] = StoredPayload(
      payloadIdentifier: moved, encryptedPayload: stored.encryptedPayload, updatedAt: updatedAt)
    let tampered = try await mac.pull(known: ["draft-2"])
    #expect(tampered["unreadable"] as? [String] == ["draft-2"])
    #expect((tampered["records"] as? [[String: Any]])?.count == 1)
    let stranger = DraftSync(
      backend: backend.backend, session: phone.session, product: mac.product,
      ring: ProductSyncKeyRing.create())
    let foreign = try await stranger.pull(known: ["draft-1"])
    #expect((foreign["records"] as? [[String: Any]])?.isEmpty == true)
    #expect((foreign["unreadable"] as? [String])?.isEmpty == true)
    // Deletion compares the revision too.
    let deleted = try await phone.push(id: "draft-1", version: 2, draft: nil, expected: updatedAt)
    #expect(deleted["committed"] as? Bool == true)
    #expect(backend.records[owner]?[identifier] != nil)
    let removedRecords = try await phone.pull(known: ["draft-1"])
    let tombstone = try #require((removedRecords["records"] as? [[String: Any]])?.first)
    #expect(tombstone["version"] as? Int == 2)
    #expect(tombstone["draft"] is NSNull)

    // A file spanning several chunks downloads only as the exact verified bytes.
    let bytes = Data((0..<(DraftSync.chunkSize * 2 + 100)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let imported = try await store.importDraftAsset(
      owner: owner, id: "assetabc123",
      source: ["kind": "data", "uri": "data:image/png;base64," + bytes.base64EncodedString()])
    let digest = try #require(imported["digest"] as? String)
    try await phone.upload(
      try await store.draftAssetBytes(owner: owner, id: "assetabc123", digest: digest),
      id: "assetabc123", digest: digest)
    let chunks = try phone.identifiers(asset: "assetabc123", digest: digest, size: bytes.count)
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { backend.records[owner]?[$0] != nil })
    #expect(try await mac.download(id: "assetabc123", digest: digest, size: bytes.count) == bytes)

    // Chunks swapped between positions, or one missing, leave the file incomplete.
    let first = try #require(backend.records[owner]?[chunks[0]])
    let second = try #require(backend.records[owner]?[chunks[1]])
    backend.records[owner]?[chunks[0]] = StoredPayload(
      payloadIdentifier: chunks[0], encryptedPayload: second.encryptedPayload, updatedAt: 1)
    backend.records[owner]?[chunks[1]] = StoredPayload(
      payloadIdentifier: chunks[1], encryptedPayload: first.encryptedPayload, updatedAt: 1)
    await #expect(throws: PrivateInboxError.attachmentMissing) {
      _ = try await mac.download(id: "assetabc123", digest: digest, size: bytes.count)
    }
    // Existing chunks must verify during upload too; a tampered reply cannot admit publication.
    await #expect(throws: PrivateInboxError.attachmentMissing) {
      try await phone.upload(bytes, id: "assetabc123", digest: digest)
    }
    backend.records[owner]?[chunks[0]] = first
    backend.records[owner]?[chunks[1]] = nil
    await #expect(throws: PrivateInboxError.attachmentMissing) {
      _ = try await mac.download(id: "assetabc123", digest: digest, size: bytes.count)
    }

    // Uploading again restores what is missing without replacing stored chunks, and downloaded
    // bytes are stored for the signed-in account only.
    try await phone.upload(bytes, id: "assetabc123", digest: digest)
    #expect(backend.records[owner]?[chunks[0]] == first)
    try await store.discardDraftAsset(id: "assetabc123")
    let downloaded = try await mac.download(id: "assetabc123", digest: digest, size: bytes.count)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.storeDraftAsset(owner: "another-account", id: "assetabc123", bytes: downloaded)
    }
    let restored = try await store.storeDraftAsset(owner: owner, id: "assetabc123", bytes: downloaded)
    #expect(restored["digest"] as? String == digest)
    #expect(
      try await store.draftAssetBytes(owner: owner, id: "assetabc123", digest: digest) == bytes)

    // A revoked device cannot use its cached sync context; preflight purges local keys and data.
    backend.revoked.insert(phone.product.trustedDeviceId)
    await #expect(throws: RegistrationError.revoked) {
      _ = try await phone.push(id: "draft-1", version: 3, draft: json, expected: updatedAt)
    }
    await #expect(throws: RegistrationError.revoked) {
      _ = try await store.prepareDraftSync(owner: owner)
    }
    #expect(try keys.read("registration") == nil)
    #expect(try keys.read("product-sync." + owner) == nil)
  }
}
