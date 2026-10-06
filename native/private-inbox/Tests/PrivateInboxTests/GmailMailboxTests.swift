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

// Only the network response is synthetic; GmailTransport builds and sends the real URLRequest.
private final class GmailHTTPProbe: @unchecked Sendable {
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
private final class ControlledGmailHTTP: URLProtocol, @unchecked Sendable {
  static let probe = GmailHTTPProbe()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.probe.record(request)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"id":"101","labelIds":["INBOX","STARRED"]}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

extension PrivateInboxTests {
  // TypeScript names only the connected mailbox's Gmail resources; its cache belongs to that
  // mailbox, replaces only the revision it read, and leaves with a reselection or the account.
  @Test @MainActor func gmailReadsAndMailboxCacheStayWithTheConnectedMailbox() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledGmailHTTP.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transportURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/101/modify")!
    let transportBody = try JSONSerialization.data(withJSONObject: [
      "addLabelIds": ["STARRED"], "removeLabelIds": [String](),
    ])
    let (transportStatus, transportData) = try await GmailTransport.send(
      token: "synthetic-access", url: transportURL, body: transportBody, session: session)
    #expect(transportStatus == 200)
    #expect(String(decoding: transportData, as: UTF8.self).contains("STARRED"))
    let transported = try #require(ControlledGmailHTTP.probe.requests().last)
    #expect(transported.url == transportURL)
    #expect(transported.httpMethod == "POST")
    #expect(transported.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
    #expect(transported.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(transported.timeoutInterval == 30)
    // URLSession may convert a body to a stream; read that stream without logging it.
    var sentBody = transported.httpBody
    if let stream = transported.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var bytes = [UInt8](repeating: 0, count: 1024)
      let count = stream.read(&bytes, maxLength: bytes.count)
      #expect(count >= 0)
      sentBody = Data(bytes.prefix(max(0, count)))
    }
    #expect(sentBody == transportBody)
    _ = try await GmailTransport.send(
      token: "synthetic-access", url: transportURL, body: nil, session: session)
    #expect(ControlledGmailHTTP.probe.requests().last?.httpMethod == "GET")
    let redirected = await RefusingRedirects().urlSession(
      session, task: session.dataTask(with: transportURL),
      willPerformHTTPRedirection: HTTPURLResponse(
        url: transportURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!,
      newRequest: URLRequest(url: URL(string: "https://example.invalid")!))
    #expect(redirected == nil)

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
    var revocationQueries = 0
    var validationUnavailable = false
    let store = google.store(
      keys: keys, mailCache: PrivateInboxStore(directory: directory, service: service),
      deviceRevoked: { _ in
        revocationQueries += 1
        if validationUnavailable { throw RegistrationError.unavailable }
        return revoked
      })
    let file = directory.appendingPathComponent("mailbox.enc")
    _ = try await store.signIn()
    google.gmailRequests = []
    // Before any mailbox is connected, nothing reaches Gmail or the cache.
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], address: google.address,
        generation: store.mailboxGeneration.uuidString)
    }

    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox() }
    _ = try await store.authorizeGmail(reselect: false)

    for path in [
      "../../oauth2/v3/tokeninfo", "messages/1/attachments/2", "drafts", "https://example.invalid",
      "profile?alt=media", "messages/../../settings", "messages/1/modify", "labels/Label_1",
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.gmail(
          path: path, query: [], address: google.address,
          generation: store.mailboxGeneration.uuidString)
      }
    }
    #expect(google.gmailRequests.isEmpty)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(
        path: "profile", query: [], address: "previous@example.invalid",
        generation: store.mailboxGeneration.uuidString)
    }
    #expect(google.gmailRequests.isEmpty)
    // Gmail reads never ask the backend about this device; opening and committing the cache do.
    let queriesBeforeReads = revocationQueries
    let response = try await store.gmail(
      path: "messages/19a0c0ffee000001",
      query: [
        URLQueryItem(name: "format", value: "metadata"),
        URLQueryItem(name: "metadataHeaders", value: "From"),
        URLQueryItem(name: "metadataHeaders", value: "Subject"),
      ], address: google.address, generation: store.mailboxGeneration.uuidString)
    #expect(response["status"] as? Int == 200)
    #expect(response["body"] as? String == #"{"historyId":"7"}"#)
    #expect(
      google.gmailRequests.map(\.absoluteString) == [
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/19a0c0ffee000001"
          + "?format=metadata&metadataHeaders=From&metadataHeaders=Subject"
      ])
    _ = try await store.gmail(
      path: "profile", query: [], address: google.address,
      generation: store.mailboxGeneration.uuidString)
    _ = try await store.gmail(
      path: "labels", query: [], address: google.address,
      generation: store.mailboxGeneration.uuidString)
    #expect(google.gmailBodies.allSatisfy { $0 == nil })
    // The one write changes one message's labels; native code writes its body.
    google.gmailRequests = []
    google.gmailBodies = []
    for (message, add, remove) in [
      ("../settings", ["STARRED"], [String]()), ("19a0c0ffee000001", ["INBOX\"x"], []),
      ("19a0c0ffee000001", [], [String](repeating: "UNREAD", count: 101)),
      ("19a0c0ffee000001?alt=media", ["TRASH"], []),
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.gmailModify(
          message: message, add: add, remove: remove, address: google.address,
          generation: store.mailboxGeneration.uuidString)
      }
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmailModify(
        message: "19a0c0ffee000001", add: ["TRASH"], remove: ["INBOX"],
        address: "previous@example.invalid", generation: store.mailboxGeneration.uuidString)
    }
    #expect(google.gmailRequests.isEmpty)
    let modified = try await store.gmailModify(
      message: "19a0c0ffee000001", add: ["TRASH", "Label_12"], remove: ["INBOX"],
      address: google.address, generation: store.mailboxGeneration.uuidString)
    #expect(modified["status"] as? Int == 200)
    #expect(
      google.gmailRequests.map(\.absoluteString) == [
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/19a0c0ffee000001/modify"
      ])
    let sent = try JSONSerialization.jsonObject(with: try #require(google.gmailBodies.first ?? nil))
    #expect(
      sent as? [String: [String]] == [
        "addLabelIds": ["TRASH", "Label_12"], "removeLabelIds": ["INBOX"],
      ])
    #expect(revocationQueries == queriesBeforeReads + 1)
    // Failed revalidation leaves the action unsent; cached read availability cannot authorize it.
    validationUnavailable = true
    let writesBeforeFailure = google.gmailRequests.count
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmailModify(
        message: "19a0c0ffee000001", add: ["STARRED"], remove: [],
        address: google.address, generation: store.mailboxGeneration.uuidString)
    }
    #expect(google.gmailRequests.count == writesBeforeFailure)
    validationUnavailable = false

    let empty = try store.openMailbox()
    #expect(empty["revision"] as? Int == 0)
    #expect(empty["address"] as? String == "same@example.invalid")
    #expect(empty["document"] is NSNull)
    let document = #"{"subject":"Private synthetic subject"}"#
    let committed = try store.commitMailbox(
      address: "same@example.invalid", expectedRevision: 0, document: document,
      generation: store.mailboxGeneration.uuidString)
    #expect(committed["revision"] as? Int == 1)
    #expect(try Data(contentsOf: file).range(of: Data("Private synthetic".utf8)) == nil)
    // A commit from an older read, or for another mailbox, changes nothing.
    #expect(throws: PrivateInboxError.conflict) {
      _ = try store.commitMailbox(
        address: "same@example.invalid", expectedRevision: 0, document: "{}",
        generation: store.mailboxGeneration.uuidString)
    }
    #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try store.commitMailbox(
        address: "other@example.invalid", expectedRevision: 1, document: "{}",
        generation: store.mailboxGeneration.uuidString)
    }
    #expect(try store.openMailbox()["document"] as? String == document)

    // Another mailbox never sees this one's cache.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    // A reconnect cannot silently select another mailbox and delete its pending document.
    _ = try await store.authorizeGmail(reselect: false)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(try store.openMailbox()["document"] as? String == document)
    #expect(try store.openMailbox()["address"] as? String == "same@example.invalid")
    _ = try await store.authorizeGmail(reselect: true)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let other = try store.openMailbox()
    #expect(other["address"] as? String == "other@example.invalid")
    #expect(other["document"] is NSNull)
    _ = try store.commitMailbox(
      address: "other@example.invalid", expectedRevision: 0, document: document,
      generation: store.mailboxGeneration.uuidString)
    let beforeReselection = other
    // Another Google account that reuses the address does not inherit the cache, and a cache left
    // behind by a failed removal still reads as empty for it.
    google.subject = "synthetic-recycled-mailbox"
    _ = try await store.authorizeGmail(reselect: true)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try store.openMailbox()["document"] is NSNull)
    #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try store.commitMailbox(
        address: "other@example.invalid", expectedRevision: 0, document: document,
        generation: try #require(beforeReselection["generation"] as? String))
    }
    let readsBeforeStaleRequest = google.gmailRequests.count
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(
        path: "profile", query: [], address: "other@example.invalid",
        generation: try #require(beforeReselection["generation"] as? String))
    }
    #expect(google.gmailRequests.count == readsBeforeStaleRequest)
    #expect(try store.openMailbox()["document"] is NSNull)
    let shared = PrivateInboxStore(directory: directory, service: service)
    _ = try shared.commitMailbox(
      address: "other@example.invalid", subject: "synthetic-other-mailbox", expectedRevision: 0,
      document: document)
    #expect(
      try shared.openMailbox(
        address: "other@example.invalid", subject: "synthetic-recycled-mailbox")[
          "document"] is NSNull)
    #expect(try store.openMailbox()["document"] is NSNull)
    try shared.removeMailbox()

    // The account leaves with its mailbox cache, and a removed account reaches no Gmail.
    _ = try store.purge()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(
        path: "profile", query: [], address: google.address,
        generation: store.mailboxGeneration.uuidString)
    }
    // A transport outage permits only the verified mailbox's cache, never provider access.
    _ = try await store.signIn()
    _ = try await store.authorizeGmail(reselect: false)
    _ = try store.commitMailbox(
      address: google.address, expectedRevision: 0, document: document,
      generation: store.mailboxGeneration.uuidString)
    google.refreshFailure = URLError(.notConnectedToInternet)
    #expect(try await store.restore()["kind"] == "cached")
    #expect(try store.openMailbox()["document"] as? String == document)
    #expect(try store.openMailbox()["availability"] as? String == "retry")
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], address: google.address,
        generation: store.mailboxGeneration.uuidString)
    }
    #expect(throws: RegistrationError.unavailable) {
      _ = try store.commitMailbox(
        address: google.address, expectedRevision: 1, document: "{}",
        generation: store.mailboxGeneration.uuidString)
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

    // Each mutation revalidates before provider renewal and purges on a positive rejection.
    revoked = true
    let readsBeforeRevokedWrite = google.gmailRequests.count
    await #expect(throws: RegistrationError.revoked) {
      _ = try await store.gmailModify(
        message: "19a0c0ffee000001", add: ["TRASH"], remove: ["INBOX"],
        address: google.address, generation: store.mailboxGeneration.uuidString)
    }
    #expect(google.gmailRequests.count == readsBeforeRevokedWrite)
    #expect(try keys.read("registration") == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    revoked = false

    // Cleanup at either suspension prevents old provider work from returning private data.
    for stage in ["refresh", "response", "reselect"] {
      _ = try await store.signIn()
      _ = try await store.authorizeGmail(reselect: false)
      google.gmailRequests = []
      let pause = MailboxPause()
      if stage == "response" {
        google.beforeGmail = { await pause.wait() }
      } else {
        google.beforeRefresh = { await pause.wait() }
      }
      let reading = Task {
        _ = try await store.gmail(
          path: "profile", query: [], address: google.address,
          generation: store.mailboxGeneration.uuidString)
      }
      await pause.reached()
      if stage == "reselect" {
        google.subject = "synthetic-final-mailbox"
        google.address = "final@example.invalid"
        _ = try await store.authorizeGmail(reselect: true)
      } else {
        _ = try store.purge()
      }
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
    // The preflight that purges a removed device reports the removal itself.
    await #expect(throws: RegistrationError.revoked) { try await cleanup.value }
    #expect(try keys.read("registration") == nil)
    revoked = false
    _ = try await store.signIn()
    _ = try await store.authorizeGmail(reselect: false)
    // The two caches share a key; a surviving fixture forbids silently replacing its missing key.
    try DeviceKeychain(service: service + ".database").remove("encryption-key")
    try Data([1, 2, 3]).write(to: directory.appendingPathComponent("inbox.enc"))
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try store.commitMailbox(
        address: google.address, expectedRevision: 0, document: document,
        generation: store.mailboxGeneration.uuidString)
    }
    #expect(try DeviceKeychain(service: service + ".database").read("encryption-key") == nil)
  }
}
