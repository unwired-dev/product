import Foundation
import Testing

@testable import PrivateInbox

@MainActor private final class MailboxPause {
  private var release: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      release = continuation
      entered?.resume()
      entered = nil
    }
  }
  func reached() async {
    if release != nil { return }
    await withCheckedContinuation { entered = $0 }
  }
  func resume() {
    release?.resume()
    release = nil
  }
}

extension PrivateInboxTests {
  // TypeScript names only the connected mailbox's Gmail resources; its cache belongs to that
  // mailbox, replaces only the revision it read, and leaves with a reselection or the account.
  @Test @MainActor func gmailReadsAndMailboxCacheStayWithTheConnectedMailbox() async throws {
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
    var revoked = false
    let store = google.store(
      keys: keys, mailCache: PrivateInboxStore(directory: directory, service: service),
      deviceRevoked: { _ in revoked })
    let file = directory.appendingPathComponent("mailbox.enc")
    _ = try await store.signIn()
    google.gmailRequests = []
    // Before any mailbox is connected, nothing reaches Gmail or the cache.
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.gmail(path: "profile", query: [], address: google.address)
    }

    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox() }
    _ = try await store.authorizeGmail(reselect: false)

    for path in [
      "../../oauth2/v3/tokeninfo", "messages/1/attachments/2", "drafts", "https://example.invalid",
      "profile?alt=media", "messages/../../settings",
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.gmail(path: path, query: [], address: google.address)
      }
    }
    #expect(google.gmailRequests.isEmpty)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(path: "profile", query: [], address: "previous@example.invalid")
    }
    #expect(google.gmailRequests.isEmpty)
    let response = try await store.gmail(
      path: "messages/19a0c0ffee000001",
      query: [
        URLQueryItem(name: "format", value: "metadata"),
        URLQueryItem(name: "metadataHeaders", value: "From"),
        URLQueryItem(name: "metadataHeaders", value: "Subject"),
      ], address: google.address)
    #expect(response["status"] as? Int == 200)
    #expect(response["body"] as? String == #"{"historyId":"7"}"#)
    #expect(
      google.gmailRequests.map(\.absoluteString) == [
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/19a0c0ffee000001"
          + "?format=metadata&metadataHeaders=From&metadataHeaders=Subject"
      ])

    let empty = try store.openMailbox()
    #expect(empty["revision"] as? Int == 0)
    #expect(empty["address"] as? String == "same@example.invalid")
    #expect(empty["document"] is NSNull)
    let document = #"{"subject":"Private synthetic subject"}"#
    let committed = try store.commitMailbox(
      address: "same@example.invalid", expectedRevision: 0, document: document)
    #expect(committed["revision"] as? Int == 1)
    #expect(try Data(contentsOf: file).range(of: Data("Private synthetic".utf8)) == nil)
    // A commit from an older read, or for another mailbox, changes nothing.
    #expect(throws: PrivateInboxError.conflict) {
      _ = try store.commitMailbox(
        address: "same@example.invalid", expectedRevision: 0, document: "{}")
    }
    #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try store.commitMailbox(
        address: "other@example.invalid", expectedRevision: 1, document: "{}")
    }
    #expect(try store.openMailbox()["document"] as? String == document)

    // Another mailbox never sees this one's cache.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    _ = try await store.authorizeGmail(reselect: true)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let other = try store.openMailbox()
    #expect(other["address"] as? String == "other@example.invalid")
    #expect(other["document"] is NSNull)
    _ = try store.commitMailbox(
      address: "other@example.invalid", expectedRevision: 0, document: document)

    // The account leaves with its mailbox cache, and a removed account reaches no Gmail.
    _ = try store.purge()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(path: "profile", query: [], address: google.address)
    }
    // A transport outage permits only the verified mailbox's cache, never provider access.
    _ = try await store.signIn()
    _ = try await store.authorizeGmail(reselect: false)
    _ = try store.commitMailbox(address: google.address, expectedRevision: 0, document: document)
    google.refreshFailure = URLError(.notConnectedToInternet)
    #expect(try await store.restore()["kind"] == "cached")
    #expect(try store.openMailbox()["document"] as? String == document)
    #expect(try store.openMailbox()["availability"] as? String == "retry")
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmail(path: "profile", query: [], address: google.address)
    }
    #expect(throws: RegistrationError.unavailable) {
      _ = try store.commitMailbox(address: google.address, expectedRevision: 1, document: "{}")
    }
    google.refreshFailure = nil
    #expect(try await store.restore()["kind"] == "connected")
    google.verificationFailure = URLError(.timedOut)
    #expect(try await store.restore()["kind"] == "cached")
    google.verificationFailure = RegistrationError.gmailUnavailable
    #expect(try await store.restore()["kind"] == "mailbox-needed")
    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox() }
    google.verificationFailure = nil
    _ = try await store.authorizeGmail(reselect: false)

    // Revocation is checked before renewing a credential or revealing cache data.
    revoked = true
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await store.prepareMailbox() }
    #expect(try keys.read("registration") == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    revoked = false

    // Cleanup at either suspension prevents old provider work from returning private data.
    for stage in ["refresh", "response", "reselect"] {
      _ = try await store.signIn()
      _ = try await store.authorizeGmail(reselect: false)
      google.gmailRequests = []
      let pause = MailboxPause()
      if stage == "response" { google.beforeGmail = { await pause.wait() } }
      else { google.beforeRefresh = { await pause.wait() } }
      let reading = Task { _ = try await store.gmail(path: "profile", query: [], address: google.address) }
      await pause.reached()
      if stage == "reselect" {
        google.subject = "synthetic-final-mailbox"
        google.address = "final@example.invalid"
        _ = try await store.authorizeGmail(reselect: true)
      } else { _ = try store.purge() }
      pause.resume()
      await #expect(throws: PrivateInboxError.mailboxInvalidated) { _ = try await reading.value }
      #expect(google.gmailRequests.count == (stage == "response" ? 1 : 0))
    }
    // A revocation preflight queues behind captured registration writes, then purges their result.
    _ = try store.purge()
    _ = try await store.signIn()
    _ = try await store.authorizeGmail(reselect: false)
    let gate = RegistrationOperationGate()
    let restoring = MailboxPause()
    google.beforeRefresh = { await restoring.wait() }
    let restoration = Task {
      _ = try await gate.perform {
        try await store.purgingIfRevoked { try await $0.restore() }
      }
    }
    await restoring.reached()
    let cleanup = Task {
      try await gate.perform {
        revoked = true
        try await store.prepareMailbox()
      }
    }
    restoring.resume()
    try await restoration.value
    await #expect(throws: PrivateInboxError.mailboxInvalidated) { try await cleanup.value }
    #expect(try keys.read("registration") == nil)
    revoked = false
    _ = try await store.signIn()
    _ = try await store.authorizeGmail(reselect: false)
    // The two caches share a key; a surviving fixture forbids silently replacing its missing key.
    try DeviceKeychain(service: service + ".database").remove("encryption-key")
    try Data([1, 2, 3]).write(to: directory.appendingPathComponent("inbox.enc"))
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try store.commitMailbox(address: google.address, expectedRevision: 0, document: document)
    }
    #expect(try DeviceKeychain(service: service + ".database").read("encryption-key") == nil)
  }
}
