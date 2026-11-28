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
    // Decode the content-free conditional-write refusal; unknown codes cannot become conflicts.
    let refusal = try JSONDecoder().decode(
      ConvexEnvelope<StoredPayload>.self,
      from: Data(#"{"status":"error","errorData":{"code":"PRODUCT_SYNC_PAYLOAD_CHANGED"}}"#.utf8))
    let code = try #require(refusal.errorData?.code)
    #expect(ProductSyncWriteFailure(rawValue: code) == .payloadChanged)
    #expect(ProductSyncWriteFailure(rawValue: "unavailable") == nil)
    // A write against a record deleted meanwhile is a conflict too; any other failure is reported.
    let gone = try #require(
      try await phone.push(id: "draft-gone", version: 1, draft: "{}", expected: nil)["updatedAt"]
        as? Double)
    backend.records[owner]?[try phone.identifier(draft: "draft-gone")] = nil
    let vanished = try await mac.push(id: "draft-gone", version: 2, draft: "{}", expected: gone)
    #expect(vanished["committed"] as? Bool == false)
    backend.beforePut = { _, _ in throw URLError(.timedOut) }
    await #expect(throws: URLError.self) {
      _ = try await mac.push(id: "draft-1", version: 2, draft: "{}", expected: updatedAt)
    }
    await #expect(throws: URLError.self) {
      _ = try await mac.push(id: "draft-gone", version: 2, draft: "{}", expected: gone)
    }
    backend.beforePut = { _, _ in throw RegistrationError.unavailable }
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await mac.push(id: "draft-gone", version: 2, draft: "{}", expected: gone)
    }
    backend.beforePut = nil

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

    // A Mail Template record is ciphertext under its own opaque identifier; a Draft record moved
    // there does not open, and a removal leaves a sealed tombstone.
    let template = #"{"id":"template-1","profile":"work","name":"Private template name"}"#
    let written = try await phone.push(
      MailTemplateRecord(id: "template-1", version: 1, content: template), expected: nil)
    let written1 = try #require(written["updatedAt"] as? Double)
    let templateIdentifier = try phone.identifier(MailTemplateRecord.self, "template-1")
    #expect(
      templateIdentifier.hasPrefix("profile-template.") && !templateIdentifier.contains("template-1"))
    let sealedTemplate = try #require(backend.records[owner]?[templateIdentifier])
    let templateCiphertext = try #require(
      Data(base64Encoded: sealedTemplate.encryptedPayload.ciphertextBase64))
    #expect(templateCiphertext.range(of: Data("Private template name".utf8)) == nil)
    let movedTemplate = try phone.identifier(MailTemplateRecord.self, "template-2")
    backend.records[owner]?[movedTemplate] = StoredPayload(
      payloadIdentifier: movedTemplate, encryptedPayload: stored.encryptedPayload,
      updatedAt: updatedAt)
    let templates = try await mac.pull(MailTemplateRecord.self, known: ["template-2"])
    #expect(templates["unreadable"] as? [String] == ["template-2"])
    let templateRecords = try #require(templates["records"] as? [[String: Any]])
    #expect(templateRecords.count == 1)
    #expect(templateRecords.first?["template"] as? String == template)
    #expect(templateRecords.first?["updatedAt"] as? Double == written1)
    let removedTemplate = try await mac.push(
      MailTemplateRecord(id: "template-1", version: 2, content: nil), expected: written1)
    #expect(removedTemplate["committed"] as? Bool == true)
    let templateTombstone = try #require(
      (try await phone.pull(MailTemplateRecord.self, known: [])["records"] as? [[String: Any]])?
        .first)
    #expect(templateTombstone["version"] as? Int == 2)
    #expect(templateTombstone["template"] is NSNull)

    // A Profile's Blocked Senders record is ciphertext under an identifier that names neither the
    // Profile nor a sender, and a template record moved there does not open.
    let senders =
      #"{"profile":"work","changes":[{"address":"offers@growthleads.io","blocked":true,"at":1}]}"#
    let blocked = try await phone.push(
      BlockedSendersRecord(id: "work", version: 1, content: senders), expected: nil)
    #expect(blocked["committed"] as? Bool == true)
    let sendersIdentifier = try phone.identifier(BlockedSendersRecord.self, "work")
    #expect(
      sendersIdentifier.hasPrefix("profile-blocked-senders.") && !sendersIdentifier.contains("work"))
    let sealedSenders = try #require(backend.records[owner]?[sendersIdentifier])
    let sendersCiphertext = try #require(
      Data(base64Encoded: sealedSenders.encryptedPayload.ciphertextBase64))
    #expect(sendersCiphertext.range(of: Data("growthleads".utf8)) == nil)
    let movedSenders = try phone.identifier(BlockedSendersRecord.self, "home")
    backend.records[owner]?[movedSenders] = StoredPayload(
      payloadIdentifier: movedSenders, encryptedPayload: sealedTemplate.encryptedPayload,
      updatedAt: updatedAt)
    let pulledSenders = try await mac.pull(BlockedSendersRecord.self, known: ["home"])
    #expect(pulledSenders["unreadable"] as? [String] == ["home"])
    let sendersRecords = try #require(pulledSenders["records"] as? [[String: Any]])
    #expect(sendersRecords.count == 1)
    #expect(sendersRecords.first?["id"] as? String == "work")
    #expect(sendersRecords.first?["senders"] as? String == senders)

    // A Profile's Inbox preferences record is ciphertext under an identifier that does not name the
    // Profile, and a Blocked Senders record moved there does not open.
    let preferences = #"{"profile":"work","fields":{"density":{"value":"compact","at":1}}}"#
    let preferred = try await phone.push(
      InboxPreferencesRecord(id: "work", version: 1, content: preferences), expected: nil)
    #expect(preferred["committed"] as? Bool == true)
    let preferencesIdentifier = try phone.identifier(InboxPreferencesRecord.self, "work")
    #expect(
      preferencesIdentifier.hasPrefix("profile-inbox-preferences.")
        && !preferencesIdentifier.contains("work"))
    let sealedPreferences = try #require(backend.records[owner]?[preferencesIdentifier])
    let preferencesCiphertext = try #require(
      Data(base64Encoded: sealedPreferences.encryptedPayload.ciphertextBase64))
    #expect(preferencesCiphertext.range(of: Data("compact".utf8)) == nil)
    let movedPreferences = try phone.identifier(InboxPreferencesRecord.self, "home")
    backend.records[owner]?[movedPreferences] = StoredPayload(
      payloadIdentifier: movedPreferences, encryptedPayload: sealedSenders.encryptedPayload,
      updatedAt: updatedAt)
    let pulledPreferences = try await mac.pull(InboxPreferencesRecord.self, known: ["home"])
    #expect(pulledPreferences["unreadable"] as? [String] == ["home"])
    let preferencesRecords = try #require(pulledPreferences["records"] as? [[String: Any]])
    #expect(preferencesRecords.count == 1)
    #expect(preferencesRecords.first?["preferences"] as? String == preferences)

    // A Profile's reading preferences record is ciphertext under its own identifier, and an Inbox
    // preferences record moved there does not open.
    let reading = #"{"profile":"work","fields":{"markRead":{"value":"manually","at":1}}}"#
    let read = try await phone.push(
      ReadingPreferencesRecord(id: "work", version: 1, content: reading), expected: nil)
    #expect(read["committed"] as? Bool == true)
    let readingIdentifier = try phone.identifier(ReadingPreferencesRecord.self, "work")
    #expect(
      readingIdentifier.hasPrefix("profile-reading-preferences.")
        && !readingIdentifier.contains("work"))
    let sealedReading = try #require(backend.records[owner]?[readingIdentifier])
    #expect(
      try #require(Data(base64Encoded: sealedReading.encryptedPayload.ciphertextBase64))
        .range(of: Data("manually".utf8)) == nil)
    let movedReading = try phone.identifier(ReadingPreferencesRecord.self, "home")
    backend.records[owner]?[movedReading] = StoredPayload(
      payloadIdentifier: movedReading, encryptedPayload: sealedPreferences.encryptedPayload,
      updatedAt: updatedAt)
    let pulledReading = try await mac.pull(ReadingPreferencesRecord.self, known: ["home"])
    #expect(pulledReading["unreadable"] as? [String] == ["home"])
    let readingRecords = try #require(pulledReading["records"] as? [[String: Any]])
    #expect(readingRecords.first?["preferences"] as? String == reading)

    // A Send Reminder record is ciphertext under its own opaque identifier; another Draft's record
    // moved there does not open.
    let reminder =
      #"{"reminder":{"draft":"draft-1","profile":"work","dueAt":1,"timeZone":"Europe/Prague"},"write":"w"}"#
    let reminded = try await phone.push(
      SendReminderRecord(id: "draft-1", version: 1, content: reminder), expected: nil)
    #expect(reminded["committed"] as? Bool == true)
    let reminderIdentifier = try phone.identifier(SendReminderRecord.self, "draft-1")
    #expect(reminderIdentifier.hasPrefix("send-reminder.") && !reminderIdentifier.contains("draft-1"))
    let sealedReminder = try #require(backend.records[owner]?[reminderIdentifier])
    let reminderCiphertext = try #require(
      Data(base64Encoded: sealedReminder.encryptedPayload.ciphertextBase64))
    #expect(reminderCiphertext.range(of: Data("Europe/Prague".utf8)) == nil)
    let movedReminder = try phone.identifier(SendReminderRecord.self, "draft-2")
    backend.records[owner]?[movedReminder] = StoredPayload(
      payloadIdentifier: movedReminder, encryptedPayload: sealedReminder.encryptedPayload,
      updatedAt: updatedAt)
    let pulledReminders = try await mac.pull(SendReminderRecord.self, known: ["draft-2"])
    #expect(pulledReminders["unreadable"] as? [String] == ["draft-2"])
    let reminderRecords = try #require(pulledReminders["records"] as? [[String: Any]])
    #expect(reminderRecords.count == 1)
    #expect(reminderRecords.first?["reminder"] as? String == reminder)

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
    // Downloaded bytes are not an unfinished import: a stored document without them reclaims them.
    let revision = try #require(try await store.openDrafts()["revision"] as? Int)
    _ = try await store.commitDrafts(
      owner: owner, expectedRevision: revision, document: #"{"version":1,"drafts":[]}"#)
    await #expect(throws: PrivateInboxError.attachmentMissing) {
      _ = try await store.draftAssetBytes(owner: owner, id: "assetabc123", digest: digest)
    }

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
