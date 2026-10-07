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
  // TypeScript names only a connection's own Gmail resources; its cache belongs to that connection,
  // replaces only the revision it read, and leaves with the connection or the account.
  @Test @MainActor func gmailReadsAndMailboxCacheStayWithTheirConnection() async throws {
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
    func file(_ subject: String) -> URL {
      directory.appendingPathComponent(
        "mailboxes/\(MailboxConnection.id(subject: subject))/mailbox.enc")
    }
    let first = MailboxConnection.id(subject: google.subject)
    let firstSubject = google.subject
    _ = try await store.signIn()
    google.gmailRequests = []
    // Before any mailbox is connected, nothing reaches Gmail or the cache.
    await #expect(throws: RegistrationError.gmailUnavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: first, address: google.address,
        generation: store.generation(firstSubject))
    }

    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox(first) }
    _ = try await store.authorizeGmail()

    for path in [
      "../../oauth2/v3/tokeninfo", "messages/1/attachments/a.b", "messages/1/modify", "drafts",
      "https://example.invalid", "profile?alt=media", "messages/../../settings", "labels/Label_1",
    ] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.gmail(
          path: path, query: [], connection: first, address: google.address,
          generation: store.generation(firstSubject))
      }
    }
    #expect(google.gmailRequests.isEmpty)
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: first, address: "previous@example.invalid",
        generation: store.generation(firstSubject))
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
      ], connection: first, address: google.address, generation: store.generation(firstSubject))
    #expect(response["status"] as? Int == 200)
    #expect(response["body"] as? String == #"{"historyId":"7"}"#)
    #expect(
      google.gmailRequests.map(\.absoluteString) == [
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/19a0c0ffee000001"
          + "?format=metadata&metadataHeaders=From&metadataHeaders=Subject"
      ])
    _ = try await store.gmail(
      path: "profile", query: [], connection: first, address: google.address,
      generation: store.generation(firstSubject))
    _ = try await store.gmail(
      path: "labels", query: [], connection: first, address: google.address,
      generation: store.generation(firstSubject))
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
          message: message, add: add, remove: remove, connection: first, address: google.address,
          generation: store.generation(firstSubject))
      }
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmailModify(
        message: "19a0c0ffee000001", add: ["TRASH"], remove: ["INBOX"],
        connection: first, address: "previous@example.invalid", generation: store.generation(firstSubject))
    }
    #expect(google.gmailRequests.isEmpty)
    let modified = try await store.gmailModify(
      message: "19a0c0ffee000001", add: ["TRASH", "Label_12"], remove: ["INBOX"],
      connection: first, address: google.address, generation: store.generation(firstSubject))
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
        message: "19a0c0ffee000001", add: ["STARRED"], remove: [], connection: first,
        address: google.address, generation: store.generation(firstSubject))
    }
    #expect(google.gmailRequests.count == writesBeforeFailure)
    validationUnavailable = false

    let empty = try store.openMailbox(first)
    #expect(empty["revision"] as? Int == 0)
    #expect(empty["address"] as? String == "same@example.invalid")
    #expect(empty["document"] is NSNull)
    let document = #"{"subject":"Private synthetic subject"}"#
    let committed = try store.commitMailbox(
      connection: first, address: "same@example.invalid", expectedRevision: 0, document: document,
      generation: store.generation(firstSubject))
    #expect(committed["revision"] as? Int == 1)
    #expect(try Data(contentsOf: file(firstSubject)).range(of: Data("Private synthetic".utf8)) == nil)
    // A commit from an older read, or for another mailbox, changes nothing.
    #expect(throws: PrivateInboxError.conflict) {
      _ = try store.commitMailbox(
        connection: first, address: "same@example.invalid", expectedRevision: 0, document: "{}",
        generation: store.generation(firstSubject))
    }
    #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try store.commitMailbox(
        connection: first, address: "other@example.invalid", expectedRevision: 1, document: "{}",
        generation: store.generation(firstSubject))
    }
    #expect(try store.openMailbox(first)["document"] as? String == document)

    // Another mailbox never sees this one's cache.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    // Reauthorizing a connection cannot silently switch it to another Google account.
    #expect(try await store.authorizeGmail(connection: first)["kind"] == "mailbox-needed")
    #expect(FileManager.default.fileExists(atPath: file(firstSubject).path))
    #expect(try store.openMailbox(first)["document"] as? String == document)
    #expect(try store.openMailbox(first)["address"] as? String == "same@example.invalid")
    // Adding another mailbox keeps this one, its cache and its pending document.
    let second = MailboxConnection.id(subject: google.subject)
    let added = try await store.authorizeGmail(chooseAccount: true)
    #expect(added["kind"] == "connected")
    #expect(
      try mailboxDisplay(added["mailboxes"])
        == mailboxList([
          (firstSubject, "same@example.invalid", "connected"),
          ("synthetic-other-mailbox", "other@example.invalid", "connected"),
        ]))
    #expect(try store.openMailbox(first)["document"] as? String == document)
    let other = try store.openMailbox(second)
    #expect(other["address"] as? String == "other@example.invalid")
    #expect(other["document"] is NSNull)
    _ = try store.commitMailbox(
      connection: second, address: "other@example.invalid", expectedRevision: 0,
      document: document, generation: store.generation("synthetic-other-mailbox"))
    // A connection's generation never opens another connection, even at the same address.
    let otherGeneration = store.generation("synthetic-other-mailbox")
    #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try store.commitMailbox(
        connection: first, address: "same@example.invalid", expectedRevision: 1,
        document: "{}", generation: otherGeneration)
    }
    // Another Google account that reuses the address is another connection with its own cache.
    google.subject = "synthetic-recycled-mailbox"
    let recycled = MailboxConnection.id(subject: google.subject)
    _ = try await store.authorizeGmail(chooseAccount: true)
    #expect(try store.load()?.connections.count == 3)
    #expect(try store.openMailbox(recycled)["document"] is NSNull)
    #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try store.commitMailbox(
        connection: recycled, address: "other@example.invalid", expectedRevision: 0,
        document: document, generation: otherGeneration)
    }
    let readsBeforeStaleRequest = google.gmailRequests.count
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: recycled, address: "other@example.invalid",
        generation: otherGeneration)
    }
    #expect(google.gmailRequests.count == readsBeforeStaleRequest)
    // Within one connection's directory, a cache for another Google account reads as empty.
    let shared = PrivateInboxStore(directory: directory, service: service)
    #expect(
      try shared.openMailbox(
        connection: second, address: "other@example.invalid",
        subject: "synthetic-recycled-mailbox")["document"] is NSNull)
    #expect(
      try shared.openMailbox(
        connection: second, address: "other@example.invalid",
        subject: "synthetic-other-mailbox")["document"] as? String == document)
    // A connection ID never names a path outside the cache.
    #expect(throws: PrivateInboxError.invalidStore) {
      _ = try shared.openMailbox(
        connection: "../../escape", address: "other@example.invalid", subject: "escape")
    }

    // Removing a connection removes its cache and invalidates its work; the others stay.
    let secondGeneration = store.generation("synthetic-other-mailbox")
    let removed = try await store.removeMailbox(second)
    #expect(!FileManager.default.fileExists(atPath: file("synthetic-other-mailbox").path))
    #expect(FileManager.default.fileExists(atPath: file(firstSubject).path))
    #expect(
      try mailboxDisplay(removed["mailboxes"])
        == mailboxList([
          (firstSubject, "same@example.invalid", "connected"),
          ("synthetic-recycled-mailbox", "other@example.invalid", "connected"),
        ]))
    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox(second) }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: second, address: "other@example.invalid",
        generation: secondGeneration)
    }
    #expect(try store.load()?.mailboxRemovals?.map(\.subject) == ["synthetic-other-mailbox"])

    // The account leaves with every connection's cache, and a removed account reaches no Gmail.
    _ = try await store.purge()
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mailboxes").path))
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: first, address: google.address,
        generation: store.generation(firstSubject))
    }
    // A transport outage permits only the verified mailbox's cache, never provider access.
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let current = MailboxConnection.id(subject: google.subject)
    let currentSubject = google.subject
    _ = try store.commitMailbox(
      connection: current, address: google.address, expectedRevision: 0, document: document,
      generation: store.generation(currentSubject))
    google.refreshFailure = URLError(.notConnectedToInternet)
    #expect(try await store.restore()["kind"] == "cached")
    #expect(try store.openMailbox(current)["document"] as? String == document)
    #expect(try store.openMailbox(current)["availability"] as? String == "retry")
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.gmail(
        path: "profile", query: [], connection: current, address: google.address,
        generation: store.generation(currentSubject))
    }
    #expect(throws: RegistrationError.unavailable) {
      _ = try store.commitMailbox(
        connection: current, address: google.address, expectedRevision: 1, document: "{}",
        generation: store.generation(currentSubject))
    }
    google.refreshFailure = nil
    #expect(try await store.restore()["kind"] == "connected")
    google.verificationFailure = URLError(.timedOut)
    #expect(try await store.restore()["kind"] == "cached")
    google.verificationFailure = RegistrationError.gmailUnavailable
    let refused = try await store.restore()
    #expect(refused["kind"] == "mailbox-needed")
    #expect(refused["reason"] == "gmail-unavailable")
    #expect(
      try mailboxDisplay(refused["mailboxes"])
        == mailboxList([(currentSubject, google.address, "authorization")]))
    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox(current) }
    // A refused grant stays refused while Gmail is unreachable, then verifies again by itself.
    google.verificationFailure = URLError(.timedOut)
    #expect(try await store.restore()["kind"] == "mailbox-needed")
    #expect(throws: RegistrationError.gmailUnavailable) { _ = try store.openMailbox(current) }
    google.verificationFailure = nil
    #expect(try await store.restore()["kind"] == "connected")

    // Each mutation revalidates before provider renewal and purges on a positive rejection.
    revoked = true
    let readsBeforeRevokedWrite = google.gmailRequests.count
    await #expect(throws: RegistrationError.revoked) {
      _ = try await store.gmailModify(
        message: "19a0c0ffee000001", add: ["TRASH"], remove: ["INBOX"], connection: current,
        address: google.address, generation: store.generation(currentSubject))
    }
    #expect(google.gmailRequests.count == readsBeforeRevokedWrite)
    #expect(try keys.read("registration") == nil)
    #expect(!FileManager.default.fileExists(atPath: file(currentSubject).path))
    revoked = false

    // Cleanup at either suspension prevents old provider work from returning private data.
    for stage in ["refresh", "response", "remove"] {
      _ = try await store.signIn()
      _ = try await store.authorizeGmail()
      google.gmailRequests = []
      let pause = MailboxPause()
      if stage == "response" {
        google.beforeGmail = { await pause.wait() }
      } else {
        google.beforeRefresh = { await pause.wait() }
      }
      let reading = Task {
        _ = try await store.gmail(
          path: "profile", query: [], connection: current, address: google.address,
          generation: store.generation(currentSubject))
      }
      await pause.reached()
      if stage == "remove" {
        _ = try await store.removeMailbox(current)
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
    _ = try await store.authorizeGmail()
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
        try await store.prepareMailbox(current)
      }
    }
    restoring.resume()
    try await restoration.value
    // The preflight that purges a removed device reports the removal itself.
    await #expect(throws: RegistrationError.revoked) { try await cleanup.value }
    #expect(try keys.read("registration") == nil)
    revoked = false
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    // The two caches share a key; a surviving fixture forbids silently replacing its missing key.
    try DeviceKeychain(service: service + ".database").remove("encryption-key")
    try Data([1, 2, 3]).write(to: directory.appendingPathComponent("inbox.enc"))
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try store.commitMailbox(
        connection: current, address: google.address, expectedRevision: 0, document: document,
        generation: store.generation(currentSubject))
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
    let first = MailboxConnection.id(subject: google.subject)
    let firstSubject = google.subject
    let bodies = directory.appendingPathComponent("mailboxes/\(first)/bodies")
    func files() throws -> [URL] {
      (try? FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil))
        ?? []
    }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    var generation = store.generation(firstSubject)
    _ = try store.commitMailbox(
      connection: first, address: google.address, expectedRevision: 0, document: "{}", generation: generation)
    #expect(
      try await store.openMessageBody(connection: first, address: google.address, generation: generation, id: "a")[
        "document"] is NSNull)
    let body = "Private synthetic body"
    _ = try await store.commitMessageBody(
      connection: first, address: google.address, generation: generation, id: "a",
      admission: ["document": body, "tier": "opened", "protectedIds": [String]()])
    _ = try await store.commitMessageBody(
      connection: first, address: google.address, generation: generation, id: "b",
      admission: ["document": body + " b", "tier": "opened", "protectedIds": [String]()])
    #expect(
      try await store.openMessageBody(connection: first, address: google.address, generation: generation, id: "a")[
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
      _ = try await store.openMessageBody(connection: first, address: google.address, generation: generation, id: "a")
    }
    threads.unlock()
    #expect(
      try await store.openMessageBody(connection: first, address: google.address, generation: generation, id: "a")[
        "document"] as? String == body)
    // An owner invalidated during suspension must never receive the worker's plaintext.
    threads.onWorker = {
      DispatchQueue.main.sync {
        MainActor.assumeIsolated { store.mailboxGenerations[first] = UUID() }
      }
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.openMessageBody(connection: first, address: google.address, generation: generation, id: "a")
    }
    threads.onWorker = nil
    generation = store.generation(firstSubject)
    // Stale work and other mailboxes neither read nor write bodies.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.openMessageBody(
        connection: first, address: "other@example.invalid", generation: generation, id: "a")
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.commitMessageBody(
        connection: first, address: google.address, generation: UUID().uuidString, id: "c",
        admission: ["document": body, "tier": "opened", "protectedIds": [String]()])
    }

    // A body moved to another message's file, or damaged, is discarded rather than shown.
    let cache = PrivateInboxStore(directory: directory, service: service)
    let sealed = try files()
    let firstFile = try #require(sealed.first)
    let secondFile = try #require(sealed.last)
    try FileManager.default.removeItem(at: secondFile)
    try FileManager.default.copyItem(at: firstFile, to: secondFile)
    let opened = try ["a", "b"].map {
      try cache.openMessageBody(connection: first, address: google.address, subject: google.subject, id: $0)
    }
    #expect(opened.compactMap { $0 }.count == 1)
    #expect(try files().map(\.lastPathComponent) == [firstFile.lastPathComponent])
    try Data([1, 2, 3]).write(to: firstFile)
    #expect(
      try await store.openMessageBody(connection: first, address: google.address, generation: generation, id: "a")[
        "document"] is NSNull)
    #expect(
      try await store.openMessageBody(connection: first, address: google.address, generation: generation, id: "b")[
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
        connection: first, address: google.address, subject: google.subject, id: id, document: text, tier: tier,
        protectedIds: protecting)
    }
    func stored(_ ids: [String]) throws -> [String] {
      try small.listMessageBodies(connection: first, address: google.address, subject: google.subject, ids: ids).stored
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
        connection: first, address: google.address, subject: google.subject, id: "oversized",
        document: String(repeating: "x", count: 201), tier: .opened, protectedIds: []))
    #expect(try stored(["prefetched", "protected"]) == ["prefetched", "protected"])
    // A prefetch exclusion marker is listed apart from saved bodies, and a later download
    // replaces it with an opened body.
    let unmarked = Set(try files())
    let markers = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { true }, bodyLimit: 1000)
    func listed(_ ids: [String]) throws -> (stored: [String], excluded: [String]) {
      try markers.listMessageBodies(
        connection: first, address: google.address, subject: google.subject, ids: ids)
    }
    #expect(
      try markers.commitMessageBody(
        connection: first, address: google.address, subject: google.subject, id: "marker",
        document: "marker", tier: .excluded, protectedIds: []))
    #expect(try listed(["protected", "marker"]) == (["protected", "marker"], ["marker"]))
    #expect(
      try markers.openMessageBody(
        connection: first, address: google.address, subject: google.subject, id: "marker")
        == "marker")
    #expect(
      try markers.commitMessageBody(
        connection: first, address: google.address, subject: google.subject, id: "marker",
        document: "body", tier: .opened, protectedIds: []))
    #expect(try listed(["protected", "marker"]) == (["protected", "marker"], []))
    #expect(try !files().contains { $0.pathExtension == "x" })
    for file in Set(try files()).subtracting(unmarked) {
      try FileManager.default.removeItem(at: file)
    }

    // Tier changes reserve both ciphertexts before deletion; refusal preserves usable mail.
    #expect(try !admit("prefetched", .opened, protecting: ["prefetched", "protected"]))
    #expect(try files().count == 2)
    #expect(try stored(["prefetched", "protected"]) == ["prefetched", "protected"])
    #expect(
      try small.openMessageBody(
        connection: first, address: google.address, subject: google.subject, id: "prefetched") == text)
    try small.retainMessageBodies(
      connection: first, address: google.address, subject: google.subject, expectedRevision: 1,
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
        connection: first, address: google.address, subject: google.subject, id: "prefetched") == nil)
    #expect(try admit("prefetched", .prefetched, protecting: ["prefetched"]))
    #expect(
      try reopened.openMessageBody(
        connection: first, address: google.address, subject: google.subject, id: "prefetched") == text)
    #expect(try files().count == 1)
    #expect(try files().first?.pathExtension == "p")
    #expect(try admit("protected", .prefetched, protecting: ["prefetched", "protected"]))

    // Pruning reconciles an over-budget directory left by an interrupted older writer. Protected
    // bodies that fit, in working-set order, stay; one that no longer fits is evicted.
    #expect(
      try cache.commitMessageBody(
        connection: first, address: google.address, subject: google.subject, id: "d", document: text,
        tier: .opened, protectedIds: []))
    #expect(try files().count == 3)
    try small.retainMessageBodies(
      connection: first, address: google.address, subject: google.subject, expectedRevision: 1,
      ids: ["prefetched", "protected", "d"], protectedIds: ["d", "protected", "prefetched"])
    #expect(try files().reduce(0) { $0 + (try Data(contentsOf: $1).count) } <= 200)
    #expect(try stored(["prefetched", "protected", "d"]) == ["protected", "d"])

    // A message that left the Inbox takes its body; the cache-only path reads but never writes.
    let locked = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { false })
    #expect(throws: PrivateInboxError.locked) {
      try locked.retainMessageBodies(
        connection: first, address: google.address, subject: google.subject, expectedRevision: 1,
        ids: [], protectedIds: [])
    }
    #expect(try files().count == 2)
    await #expect(throws: PrivateInboxError.conflict) {
      _ = try await store.retainMessageBodies(
        connection: first, address: google.address, generation: generation, expectedRevision: 0,
        ids: [], protectedIds: [])
    }
    #expect(try files().count == 2)
    _ = try await store.retainMessageBodies(
      connection: first, address: google.address, generation: generation, expectedRevision: 1,
      ids: ["protected"], protectedIds: [])
    #expect(try files().count == 1)
    google.refreshFailure = URLError(.notConnectedToInternet)
    #expect(try await store.restore()["kind"] == "cached")
    let cached = store.generation(firstSubject)
    let cachedFile = try #require(files().first)
    let cachedReadTime = Date(timeIntervalSince1970: 123)
    try FileManager.default.setAttributes(
      [.modificationDate: cachedReadTime], ofItemAtPath: cachedFile.path)
    #expect(
      try await store.openMessageBody(connection: first, address: google.address, generation: cached, id: "protected")[
        "document"] as? String == text)
    #expect(
      try FileManager.default.attributesOfItem(atPath: cachedFile.path)[.modificationDate] as? Date
        == cachedReadTime)
    #expect(
      try await store.listMessageBodies(
        connection: first, address: google.address, generation: cached, ids: ["protected"])[
          "stored"] as? [String] == ["protected"])
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.commitMessageBody(
        connection: first, address: google.address, generation: cached, id: "d",
        admission: ["document": body, "tier": "opened", "protectedIds": [String]()])
    }
    // Cache-only access returns absence for corrupt ciphertext without pruning or touching it.
    let damaged = Data([1, 2, 3])
    try damaged.write(to: cachedFile)
    try FileManager.default.setAttributes(
      [.modificationDate: cachedReadTime], ofItemAtPath: cachedFile.path)
    #expect(
      try await store.openMessageBody(connection: first, address: google.address, generation: cached, id: "protected")[
        "document"] is NSNull)
    #expect(try Data(contentsOf: cachedFile) == damaged)
    #expect(
      try FileManager.default.attributesOfItem(atPath: cachedFile.path)[.modificationDate] as? Date
        == cachedReadTime)
    google.refreshFailure = nil
    #expect(try await store.restore()["kind"] == "connected")

    // Another mailbox keeps its own bodies; removing a mailbox, or the account leaving, removes
    // its bodies.
    google.subject = "synthetic-other-mailbox"
    google.address = "other@example.invalid"
    let other = MailboxConnection.id(subject: google.subject)
    _ = try await store.authorizeGmail(chooseAccount: true)
    #expect(try files().count == 1)
    _ = try store.commitMailbox(
      connection: other, address: google.address, expectedRevision: 0, document: "{}",
      generation: store.generation("synthetic-other-mailbox"))
    _ = try await store.commitMessageBody(
      connection: other, address: google.address,
      generation: store.generation("synthetic-other-mailbox"), id: "a",
      admission: ["document": body, "tier": "prefetched", "protectedIds": ["a"]])
    // The device-wide limit counts every connection's bodies: with room for only Other's bodies,
    // admitting another evicts the first mailbox's remaining body.
    let otherBodies = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent("mailboxes/\(other)/bodies"),
      includingPropertiesForKeys: nil)
    let shared = PrivateInboxStore(
      directory: directory, service: service, protectedDataAvailable: { true },
      // AES-GCM adds a 12-byte nonce and a 16-byte tag to each body.
      bodyLimit: try otherBodies.reduce(text.count + 28) { $0 + (try Data(contentsOf: $1).count) })
    #expect(
      try shared.commitMessageBody(
        connection: other, address: google.address, subject: google.subject, id: "b",
        document: text, tier: .opened, protectedIds: ["a", "b"]))
    #expect(try files().isEmpty)
    _ = try await store.removeMailbox(first)
    #expect(!FileManager.default.fileExists(atPath: bodies.path))
    #expect(
      try await store.listMessageBodies(
        connection: other, address: google.address,
        generation: store.generation("synthetic-other-mailbox"), ids: ["a", "b"])[
          "stored"] as? [String] == ["a", "b"])
    // Purging waits for the store's lock off the main actor, so the interface keeps running.
    let held = Darwin.open(directory.appendingPathComponent("store.lock").path, O_RDWR)
    try #require(held >= 0)
    try #require(flock(held, LOCK_EX) == 0)
    let purged = PurgeProgress()
    let purgeGeneration = store.mailboxGeneration(other)
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
    #expect(store.mailboxGeneration(other) != purgeGeneration)
    #expect(!purged.finished)
    unlock.signal()
    #expect(await release.value)
    try await purging.value
    #expect(purged.finished)
    #expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("mailboxes").path))
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
