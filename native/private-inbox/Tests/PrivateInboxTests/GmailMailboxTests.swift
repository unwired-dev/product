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
      "../../oauth2/v3/tokeninfo", "messages/1/attachments/a.b", "messages/1/modify", "drafts",
      "https://example.invalid", "profile?alt=media", "messages/../../settings", "labels/Label_1",
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
    _ = try await store.purge()
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
        _ = try await store.purge()
      }
      pause.resume()
      await #expect(throws: PrivateInboxError.mailboxInvalidated) { _ = try await reading.value }
      #expect(google.gmailRequests.count == (stage == "response" ? 1 : 0))
    }
    // A revocation preflight queues behind captured registration writes, then purges their result.
    _ = try await store.purge()
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

  // Bodies are sealed to their mailbox and message, open offline from the saved cache, keep
  // within the device limit by least recent reading, and leave with their message or mailbox.
  @Test @MainActor func messageBodiesStaySealedToTheirMailboxAndMessage() async throws {
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
    let threads = StoreThreads()
    let store = google.store(
      keys: keys,
      mailCache: PrivateInboxStore(
        directory: directory, service: service,
        protectedDataAvailable: { threads.check() }),
      deviceRevoked: { _ in false })
    let bodies = directory.appendingPathComponent("bodies")
    func files() throws -> [URL] {
      (try? FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil))
        ?? []
    }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail(reselect: false)
    var generation = store.mailboxGeneration.uuidString
    _ = try store.commitMailbox(
      address: google.address, expectedRevision: 0, document: "{}", generation: generation)
    #expect(
      try await store.openMessageBody(address: google.address, generation: generation, id: "a")[
        "document"] is NSNull)
    let body = "Private synthetic body"
    _ = try await store.commitMessageBody(
      address: google.address, generation: generation, id: "a",
      admission: ["document": body, "tier": "opened", "protectedIds": [String]()])
    _ = try await store.commitMessageBody(
      address: google.address, generation: generation, id: "b",
      admission: ["document": body + " b", "tier": "opened", "protectedIds": [String]()])
    #expect(
      try await store.openMessageBody(address: google.address, generation: generation, id: "a")[
        "document"] as? String == body)
    #expect(try files().count == 2)
    for file in try files() {
      #expect(try Data(contentsOf: file).range(of: Data("Private synthetic".utf8)) == nil)
    }
    // Body files are read, encrypted and written off the main thread.
    #expect(threads.ranOffMain)
    // Availability can change after preflight while a worker can still finish its read.
    threads.lockDuringWork()
    await #expect(throws: PrivateInboxError.locked) {
      _ = try await store.openMessageBody(address: google.address, generation: generation, id: "a")
    }
    threads.unlock()
    #expect(
      try await store.openMessageBody(address: google.address, generation: generation, id: "a")[
        "document"] as? String == body)
    // An owner invalidated during suspension must never receive the worker's plaintext.
    threads.onWorker = {
      DispatchQueue.main.sync {
        MainActor.assumeIsolated { store.mailboxGeneration = UUID() }
      }
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.openMessageBody(address: google.address, generation: generation, id: "a")
    }
    threads.onWorker = nil
    generation = store.mailboxGeneration.uuidString
    // Stale work and other mailboxes neither read nor write bodies.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.openMessageBody(
        address: "other@example.invalid", generation: generation, id: "a")
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.commitMessageBody(
        address: google.address, generation: UUID().uuidString, id: "c",
        admission: ["document": body, "tier": "opened", "protectedIds": [String]()])
    }

    // A body moved to another message's file, or damaged, is discarded rather than shown.
    let cache = PrivateInboxStore(directory: directory, service: service)
    let sealed = try files()
    let first = try #require(sealed.first)
    let second = try #require(sealed.last)
    try FileManager.default.removeItem(at: second)
    try FileManager.default.copyItem(at: first, to: second)
    let opened = try ["a", "b"].map {
      try cache.openMessageBody(address: google.address, subject: google.subject, id: $0)
    }
    #expect(opened.compactMap { $0 }.count == 1)
    #expect(try files().map(\.lastPathComponent) == [first.lastPathComponent])
    try Data([1, 2, 3]).write(to: first)
    #expect(
      try await store.openMessageBody(address: google.address, generation: generation, id: "a")[
        "document"] is NSNull)
    #expect(
      try await store.openMessageBody(address: google.address, generation: generation, id: "b")[
        "document"] is NSNull)
    #expect(try files().isEmpty)

    // Opened bodies go before prefetched ones, least recently read first; protected bodies stay,
    // and a body that cannot fit without evicting them is refused.
    let small = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { true }, bodyLimit: 200)
    let text = String(repeating: "x", count: 60)
    func admit(_ id: String, _ tier: PrivateInboxStore.BodyTier, protecting: [String] = [])
      throws -> Bool
    {
      try small.commitMessageBody(
        address: google.address, subject: google.subject, id: id, document: text, tier: tier,
        protectedIds: protecting)
    }
    func stored(_ ids: [String]) throws -> [String] {
      try small.listMessageBodies(address: google.address, subject: google.subject, ids: ids)
    }
    #expect(try admit("prefetched", .prefetched))
    #expect(try admit("older", .opened))
    #expect(try admit("newer", .opened))
    #expect(try stored(["prefetched", "older", "newer"]) == ["prefetched", "newer"])
    #expect(Set(try files().map(\.pathExtension)) == ["o", "p"])
    #expect(try !admit("refused", .prefetched, protecting: ["prefetched", "newer", "refused"]))
    #expect(try stored(["prefetched", "newer", "refused"]) == ["prefetched", "newer"])
    #expect(try admit("protected", .prefetched, protecting: ["prefetched", "protected"]))
    #expect(try stored(["prefetched", "newer", "protected"]) == ["prefetched", "protected"])
    // A body larger than the entire budget is refused without evicting usable mail.
    #expect(
      try !small.commitMessageBody(
        address: google.address, subject: google.subject, id: "oversized",
        document: String(repeating: "x", count: 201), tier: .opened, protectedIds: []))
    #expect(try stored(["prefetched", "protected"]) == ["prefetched", "protected"])

    // Tier changes reserve both ciphertexts before deletion; refusal preserves usable mail.
    #expect(try !admit("prefetched", .opened, protecting: ["prefetched", "protected"]))
    #expect(try files().count == 2)
    #expect(try stored(["prefetched", "protected"]) == ["prefetched", "protected"])
    #expect(
      try small.openMessageBody(
        address: google.address, subject: google.subject, id: "prefetched") == text)
    try small.retainMessageBodies(
      address: google.address, subject: google.subject, expectedRevision: 1,
      ids: ["prefetched"], protectedIds: [])
    #expect(try admit("prefetched", .opened, protecting: ["prefetched"]))
    #expect(try files().count == 1)
    #expect(try files().first?.pathExtension == "o")

    // A failed replacement must not leave the older tier readable after an interrupted move.
    // Obstruct the real atomic write instead of adding a production fault-injection hook.
    let oldTier = try #require(files().first)
    let blockedTier = oldTier.deletingPathExtension().appendingPathExtension("p")
    try FileManager.default.createDirectory(at: blockedTier, withIntermediateDirectories: false)
    try Data([0]).write(to: blockedTier.appendingPathComponent("obstruction"))
    #expect(throws: (any Error).self) {
      try admit("prefetched", .prefetched, protecting: ["prefetched"])
    }
    #expect(!FileManager.default.fileExists(atPath: oldTier.path))
    try FileManager.default.removeItem(at: blockedTier)
    let reopened = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { true }, bodyLimit: 200)
    #expect(
      try reopened.openMessageBody(
        address: google.address, subject: google.subject, id: "prefetched") == nil)
    #expect(try admit("prefetched", .prefetched, protecting: ["prefetched"]))
    #expect(
      try reopened.openMessageBody(
        address: google.address, subject: google.subject, id: "prefetched") == text)
    #expect(try files().count == 1)
    #expect(try files().first?.pathExtension == "p")
    #expect(try admit("protected", .prefetched, protecting: ["prefetched", "protected"]))

    // Pruning reconciles an over-budget directory left by an interrupted older writer. Protected
    // bodies that fit, in working-set order, stay; one that no longer fits is evicted.
    #expect(
      try cache.commitMessageBody(
        address: google.address, subject: google.subject, id: "d", document: text,
        tier: .opened, protectedIds: []))
    #expect(try files().count == 3)
    try small.retainMessageBodies(
      address: google.address, subject: google.subject, expectedRevision: 1,
      ids: ["prefetched", "protected", "d"], protectedIds: ["d", "protected", "prefetched"])
    #expect(try files().reduce(0) { $0 + (try Data(contentsOf: $1).count) } <= 200)
    #expect(try stored(["prefetched", "protected", "d"]) == ["protected", "d"])

    // A message that left the Inbox takes its body; the cache-only path reads but never writes.
    let locked = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { false })
    #expect(throws: PrivateInboxError.locked) {
      try locked.retainMessageBodies(
        address: google.address, subject: google.subject, expectedRevision: 1,
        ids: [], protectedIds: [])
    }
    #expect(try files().count == 2)
    await #expect(throws: PrivateInboxError.conflict) {
      _ = try await store.retainMessageBodies(
        address: google.address, generation: generation, expectedRevision: 0,
        ids: [], protectedIds: [])
    }
    #expect(try files().count == 2)
    _ = try await store.retainMessageBodies(
      address: google.address, generation: generation, expectedRevision: 1,
      ids: ["protected"], protectedIds: [])
    #expect(try files().count == 1)
    google.refreshFailure = URLError(.notConnectedToInternet)
    #expect(try await store.restore()["kind"] == "cached")
    let cached = store.mailboxGeneration.uuidString
    let cachedFile = try #require(files().first)
    let cachedReadTime = Date(timeIntervalSince1970: 123)
    try FileManager.default.setAttributes(
      [.modificationDate: cachedReadTime], ofItemAtPath: cachedFile.path)
    #expect(
      try await store.openMessageBody(address: google.address, generation: cached, id: "protected")[
        "document"] as? String == text)
    #expect(
      try FileManager.default.attributesOfItem(atPath: cachedFile.path)[.modificationDate] as? Date
        == cachedReadTime)
    #expect(
      try await store.listMessageBodies(
        address: google.address, generation: cached, ids: ["protected"])[
          "stored"] as? [String] == ["protected"])
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.commitMessageBody(
        address: google.address, generation: cached, id: "d",
        admission: ["document": body, "tier": "opened", "protectedIds": [String]()])
    }
    // Cache-only access returns absence for corrupt ciphertext without pruning or touching it.
    let damaged = Data([1, 2, 3])
    try damaged.write(to: cachedFile)
    try FileManager.default.setAttributes(
      [.modificationDate: cachedReadTime], ofItemAtPath: cachedFile.path)
    #expect(
      try await store.openMessageBody(address: google.address, generation: cached, id: "protected")[
        "document"] is NSNull)
    #expect(try Data(contentsOf: cachedFile) == damaged)
    #expect(
      try FileManager.default.attributesOfItem(atPath: cachedFile.path)[.modificationDate] as? Date
        == cachedReadTime)
    google.refreshFailure = nil
    #expect(try await store.restore()["kind"] == "connected")

    // Another mailbox, or the account leaving, removes every body.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    _ = try await store.authorizeGmail(reselect: true)
    #expect(try files().isEmpty)
    _ = try store.commitMailbox(
      address: google.address, expectedRevision: 0, document: "{}",
      generation: store.mailboxGeneration.uuidString)
    _ = try await store.commitMessageBody(
      address: google.address, generation: store.mailboxGeneration.uuidString, id: "a",
      admission: ["document": body, "tier": "prefetched", "protectedIds": ["a"]])
    // Purging waits for the store's lock off the main actor, so the interface keeps running.
    let held = Darwin.open(directory.appendingPathComponent("store.lock").path, O_RDWR)
    try #require(held >= 0)
    try #require(flock(held, LOCK_EX) == 0)
    let purged = PurgeProgress()
    let purgeGeneration = store.mailboxGeneration
    let unlock = DispatchSemaphore(value: 0)
    defer { unlock.signal() }
    // The timeout only releases a broken synchronous implementation so the test can fail.
    // A passing run releases the lock explicitly after observing main-actor progress.
    let releaseLock: @Sendable () -> Bool = {
      let progressed = unlock.wait(timeout: .now() + 10) == .success
      close(held)
      return progressed
    }
    let release = Task.detached(operation: releaseLock)
    let purging = Task { @MainActor in
      purged.begin()
      _ = try await store.purge()
      purged.finished = true
    }
    await purged.reached()
    #expect(store.mailboxGeneration != purgeGeneration)
    #expect(!purged.finished)
    unlock.signal()
    #expect(await release.value)
    try await purging.value
    #expect(purged.finished)
    #expect(!FileManager.default.fileExists(atPath: bodies.path))
  }
}

@MainActor private final class PurgeProgress {
  var finished = false
  private var started = false
  private var entered: CheckedContinuation<Void, Never>?

  func begin() {
    started = true
    entered?.resume()
    entered = nil
  }
  func reached() async {
    if started { return }
    await withCheckedContinuation { entered = $0 }
  }
}

// Which threads the store's protected-data checks ran on, as its transactions run them.
private final class StoreThreads: @unchecked Sendable {
  private let lock = NSLock()
  private var offMain = false
  private var locked = false
  private var lockOnWorker = false
  private var worker: (@Sendable () -> Void)?
  var onWorker: (@Sendable () -> Void)? {
    get { lock.withLock { worker } }
    set { lock.withLock { worker = newValue } }
  }
  func check() -> Bool {
    let main = Thread.isMainThread
    if !main { onWorker?() }
    return lock.withLock {
      offMain = offMain || !main
      if !main && lockOnWorker { locked = true }
      return !main || !locked
    }
  }
  func lockDuringWork() { lock.withLock { lockOnWorker = true } }
  func unlock() {
    lock.withLock {
      locked = false
      lockOnWorker = false
    }
  }
  var ranOffMain: Bool { lock.withLock { offMain } }
}
