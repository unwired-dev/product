import Foundation
import Testing

@testable import PrivateInbox

extension PrivateInboxTests {
  // A Downloaded Attachment is saved only with exactly its declared bytes, under a name confined
  // to its own directory, for the current generation of its connection, and leaves with the file,
  // the connection, the account or the process.
  @Test @MainActor func downloadedAttachmentsStayWithTheirConnection() async throws {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let attachments = directory.appendingPathComponent("temporary")
    let keys = DeviceKeychain(service: service)
    defer {
      try? keys.remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let cache = PrivateInboxStore(
      directory: directory, service: service, attachments: attachments,
      protectedDataAvailable: { true })
    let store = google.store(keys: keys, mailCache: cache, deviceRevoked: { _ in false })
    let first = MailboxConnection.id(subject: google.subject)
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let generation = store.generation(google.subject)
    let bytes = Data("%PDF-1.7 synthetic".utf8)
    let data = bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")

    func save(_ name: String, _ data: String, size: Int) async throws -> String {
      let reply = try await store.saveAttachment(
        connection: first, address: google.address, generation: generation, name: name,
        data: data, size: size)
      return try #require(reply["file"] as? String)
    }

    let file = try await save("../../report.pdf", data, size: bytes.count)
    let url = try await store.attachmentFile(
      connection: first, address: google.address, generation: generation, file: file)
    #expect(url.lastPathComponent == "attachment")
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == first)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(PrivateInboxStore.attachmentName("../x") == "attachment")
    #expect(PrivateInboxStore.attachmentName("a/b:c.txt") == "a_b_c.txt")

    // Bytes that do not decode to the declared size are refused and nothing is written.
    await #expect(throws: PrivateInboxError.unavailable) {
      _ = try await save("short.pdf", data, size: bytes.count + 1)
    }
    await #expect(throws: PrivateInboxError.unavailable) {
      _ = try await save("garbled.pdf", "***", size: 2)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: attachments.appendingPathComponent(first), includingPropertiesForKeys: nil
      ).map(\.lastPathComponent) == [file])

    // Another generation or address neither saves nor presents files; only the opaque name of
    // a file in this connection's own directory resolves.
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.saveAttachment(
        connection: first, address: google.address, generation: UUID().uuidString, name: "a",
        data: data, size: bytes.count)
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.attachmentFile(
        connection: first, address: "other@example.invalid", generation: generation, file: file)
    }
    await #expect(throws: PrivateInboxError.invalidStore) {
      _ = try await store.attachmentFile(
        connection: first, address: google.address, generation: generation, file: "../\(file)")
    }

    // Discarding deletes the file; a missing file cannot be presented.
    try await store.discardAttachment(connection: first, file: file)
    await #expect(throws: PrivateInboxError.attachmentMissing) {
      _ = try await store.attachmentFile(
        connection: first, address: google.address, generation: generation, file: file)
    }

    // Removing the connection, the account's caches or a relaunch clears the files.
    _ = try await save("one.pdf", data, size: bytes.count)
    try cache.removeMailbox(connection: first)
    #expect(!FileManager.default.fileExists(atPath: attachments.appendingPathComponent(first).path))
    _ = try await save("two.pdf", data, size: bytes.count)
    try cache.removeMailboxes()
    #expect(!FileManager.default.fileExists(atPath: attachments.path))
    _ = try await save("three.pdf", data, size: bytes.count)
    try cache.removeAttachments()
    #expect(!FileManager.default.fileExists(atPath: attachments.path))

    // The aggregate budget spans connections and evicts the least recently used file.
    let bounded = PrivateInboxStore(
      directory: directory, service: service, attachments: attachments,
      protectedDataAvailable: { true }, attachmentLimit: bytes.count)
    let older = try bounded.saveAttachment(
      connection: first, name: "old.pdf", data: data, size: bytes.count)
    let other = MailboxConnection.id(subject: "another-synthetic-subject")
    let newer = try bounded.saveAttachment(
      connection: other, name: "new.pdf", data: data, size: bytes.count)
    #expect(try bounded.attachmentFile(connection: first, file: older) == nil)
    #expect(try bounded.attachmentFile(connection: other, file: newer) != nil)
    // A preview/share retains its file against another connection's download without adding quota.
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try bounded.saveAttachment(
        connection: first, name: "blocked.pdf", data: data, size: bytes.count,
        protectedFiles: [newer])
    }
    #expect(try bounded.attachmentFile(connection: other, file: newer) != nil)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: attachments.appendingPathComponent(first), includingPropertiesForKeys: nil).isEmpty)
    let afterPresentation = try bounded.saveAttachment(
      connection: first, name: "after.pdf", data: data, size: bytes.count)
    #expect(try bounded.attachmentFile(connection: other, file: newer) == nil)
    #expect(try bounded.attachmentFile(connection: first, file: afterPresentation) != nil)

    // Admission skips even the oldest leased file and evicts only an unleased neighbour.
    try bounded.removeAttachments()
    let twoFiles = PrivateInboxStore(
      directory: directory, service: service, attachments: attachments,
      protectedDataAvailable: { true }, attachmentLimit: 2 * bytes.count)
    let leased = try twoFiles.saveAttachment(
      connection: other, name: "leased.pdf", data: data, size: bytes.count)
    let leasedURL = try #require(try twoFiles.attachmentFile(connection: other, file: leased))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: leasedURL.path)
    let unleased = try twoFiles.saveAttachment(
      connection: first, name: "unleased.pdf", data: data, size: bytes.count)
    let admitted = try twoFiles.saveAttachment(
      connection: first, name: "admitted.pdf", data: data, size: bytes.count,
      protectedFiles: [leased])
    #expect(try twoFiles.attachmentFile(connection: other, file: leased) != nil)
    #expect(try twoFiles.attachmentFile(connection: first, file: unleased) == nil)
    #expect(try twoFiles.attachmentFile(connection: first, file: admitted) != nil)
    #expect(throws: PrivateInboxError.unavailable) {
      _ = try bounded.saveAttachment(
        connection: first, name: "large", data: "", size: 25 * 1024 * 1024 + 1)
    }

    // A cache deletion failure still attempts the independent plaintext attachment cleanup.
    let mailboxRoot = directory.appendingPathComponent("mailboxes")
    let mailboxFolder = mailboxRoot.appendingPathComponent(other)
    try FileManager.default.createDirectory(at: mailboxFolder, withIntermediateDirectories: true)
    try Data([1]).write(to: mailboxFolder.appendingPathComponent("mailbox.enc"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: mailboxRoot.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: mailboxRoot.path)
    }
    #expect(throws: (any Error).self) { try bounded.removeMailbox(connection: other) }
    #expect(!FileManager.default.fileExists(atPath: attachments.appendingPathComponent(other).path))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: mailboxRoot.path)

    // A device that locks after the write rejects completion and removes its unacknowledged file.
    let lockedFiles = directory.appendingPathComponent("locked-after-write")
    let lockingCache = PrivateInboxStore(
      directory: directory, service: service, attachments: lockedFiles,
      protectedDataAvailable: { !FileManager.default.fileExists(atPath: lockedFiles.path) })
    let lockingStore = google.store(
      keys: keys, mailCache: lockingCache, deviceRevoked: { _ in false })
    _ = try await lockingStore.restore()
    await #expect(throws: PrivateInboxError.locked) {
      _ = try await lockingStore.saveAttachment(
        connection: first, address: google.address,
        generation: lockingStore.generation(google.subject),
        name: "locked.pdf", data: data, size: bytes.count)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: lockedFiles.appendingPathComponent(first), includingPropertiesForKeys: nil
      ).isEmpty)
  }
}

// Controlled responses exercise the production URLSession boundary, including transfer termination.
private final class AttachmentHTTP: URLProtocol, @unchecked Sendable {
  static let started = AsyncStream<Void>.makeStream()
  static let stopped = AsyncStream<Void>.makeStream()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let headers = request.url!.lastPathComponent == "length" ? ["Content-Length": "4"] : [:]
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
    if request.url!.lastPathComponent == "wait" {
      Self.started.continuation.yield(())
    } else {
      client?.urlProtocol(self, didLoad: Data([4]))
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {
    if request.url!.lastPathComponent == "wait" { Self.stopped.continuation.yield(()) }
  }
}

extension PrivateInboxTests {
  @Test func attachmentTransportBoundsAndCancellation() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AttachmentHTTP.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (status, bytes) = try await GmailTransport.send(
      token: "synthetic-access", url: URL(string: "https://gmail.googleapis.com/chunked")!,
      body: nil, session: session, limit: 4)
    #expect(status == 200 && bytes == Data([1, 2, 3, 4]))
    for part in ["length", "chunked"] {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await GmailTransport.send(
          token: "synthetic-access",
          url: URL(string: "https://gmail.googleapis.com/\(part)")!, body: nil, session: session,
          limit: 3)
      }
    }
    let transfer = Task {
      try await GmailTransport.send(
        token: "synthetic-access",
        url: URL(string: "https://gmail.googleapis.com/wait")!, body: nil, session: session)
    }
    _ = await AttachmentHTTP.started.stream.first { _ in true }
    transfer.cancel()
    await #expect(throws: CancellationError.self) { _ = try await transfer.value }
    _ = await AttachmentHTTP.stopped.stream.first { _ in true }

    // A suspended task can finish cancellation before send installs its continuation.
    let early = CancelledAttachmentResponse()
    let cancelled = session.dataTask(with: URL(string: "https://gmail.googleapis.com/wait")!)
    cancelled.delegate = early
    cancelled.cancel()
    _ = await early.completed.stream.first { _ in true }
    await #expect {
      let _: (Int, Data) = try await withCheckedThrowingContinuation { continuation in
        early.receiver.start(continuation)
        cancelled.resume()
      }
    } throws: { error in
      (error as? URLError)?.code == .cancelled
    }
    let preCancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await GmailTransport.send(
        token: "synthetic-access", url: URL(string: "https://gmail.googleapis.com/wait")!,
        body: nil, session: session)
    }
    await #expect(throws: CancellationError.self) { _ = try await preCancelled.value }
  }
}

private final class CancelledAttachmentResponse: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let receiver = BoundedResponse(limit: 4)
  let completed = AsyncStream<Void>.makeStream()

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    receiver.urlSession(session, task: task, didCompleteWithError: error)
    completed.continuation.yield(())
  }
}
