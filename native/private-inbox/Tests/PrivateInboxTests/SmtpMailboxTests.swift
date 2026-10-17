import Foundation
import Testing

@testable import PrivateInbox

extension PrivateInboxTests {
  // SMTP is verified on its own before a connection is added. A submission names the connection's
  // address and SMTP password and submits the message TypeScript composed unchanged, and files a
  // Sent copy; stale work and malformed envelopes reach no server.
  @Test @MainActor func imapConnectionSendsThroughSmtpAndFilesItsSentCopy() async throws {
    let service = "dev.unwired.registration.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = DeviceKeychain(service: service)
    defer {
      try? keys.remove("registration")
      try? DeviceKeychain(service: service + ".database").remove("encryption-key")
      try? FileManager.default.removeItem(at: directory)
    }
    let imap = ControlledImap()
    let smtp = ControlledSmtp()
    var proofAvailable = true
    var revoked = false
    let store = RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: SyntheticGoogleRegistrationProvider(), imap: imap, smtp: smtp,
      deviceRevoked: { _ in
        guard proofAvailable else { throw RegistrationError.unavailable }
        return revoked
      },
      mailCache: PrivateInboxStore(directory: directory, service: service),
      connect: { identity, _, _ in
        ProductRegistrationReceipt(
          productAccountId: "account-" + identity.subject, trustedDeviceId: "synthetic-device",
          trustedDeviceCredential: String(repeating: "a", count: 64))
      })
    _ = try await store.signIn()
    let account = try ImapAccount(host: "imap.example.invalid", port: 993, username: "alex")
    let outgoing = try SmtpAccount(
      host: "SMTP.Example.Invalid", port: 587, startTLS: true, username: "alex-smtp")
    #expect(outgoing.host == "smtp.example.invalid")
    #expect(throws: RegistrationError.unavailable) {
      _ = try SmtpAccount(
        host: "smtp.example.invalid", port: 587, startTLS: true, username: "alex\r\nQUIT")
    }

    // IMAP accepts, SMTP refuses: nothing is added, and the refusal names SMTP.
    smtp.failure = SmtpFailure.authentication
    await #expect(throws: SmtpFailure.authentication) {
      _ = try await store.connectImap(
        address: "alex@example.invalid", account: account, password: "app-password",
        smtp: outgoing, smtpPassword: "smtp-password")
    }
    #expect(try store.saved().connections.isEmpty)
    #expect(RegistrationStore.rejectionCode(SmtpFailure.authentication) == "smtp-refused")
    smtp.failure = nil
    let id = try #require(
      try await store.connectImap(
        address: "alex@example.invalid", account: account, password: "app-password",
        smtp: outgoing, smtpPassword: "smtp-password")["connection"] as? String)
    #expect(smtp.logins().map(\.1) == ["smtp-password", "smtp-password"])
    let projection = try #require(try store.registration())
    let listed = try #require((projection["mailboxes"] as? [[String: Any]])?.first)
    #expect(
      listed["smtp"] as? [String: AnyHashable]
        == [
          "host": "smtp.example.invalid", "port": 587, "security": "starttls",
          "username": "alex-smtp",
        ])
    let encoded = try JSONSerialization.data(withJSONObject: projection)
    #expect(encoded.range(of: Data("smtp-password".utf8)) == nil)

    let generation = store.mailboxGeneration(id).uuidString
    let head =
      "From: alex@example.invalid\r\nTo: Sam <sam@example.invalid>\r\nBcc: Jo\r\n <jo@example.invalid>\r\n"
      + "Subject: Lunch\r\nContent-Type: multipart/mixed; boundary=\"=_sentcopy1\"\r\n\r\n"
    let body = "--=_sentcopy1\r\n--=_sentcopy1--\r\n"
    let recipients = ["sam@example.invalid", "jo@example.invalid"]
    let reply = try await store.imapSend(
      segments: [["text": head + body]], recipients: recipients, connection: id,
      address: "alex@example.invalid", generation: generation)
    #expect(reply["accepted"] as? Bool == true)
    #expect(
      smtp.submissions()
        == [
          ControlledSmtp.Submission(
            account: outgoing, password: "smtp-password", from: "alex@example.invalid",
            to: recipients,
            message: Data((head + body).utf8))
        ])
    // Malformed envelopes and work from another generation reach no server.
    for refused in [[], ["sam@example.invalid\r\nRCPT TO:<x@example.invalid>"], ["<sam@example.invalid>"]]
    {
      await #expect(throws: RegistrationError.unavailable) {
        _ = try await store.imapSend(
          segments: [["text": head + body]], recipients: refused, connection: id,
          address: "alex@example.invalid", generation: generation)
      }
    }
    await #expect(throws: PrivateInboxError.mailboxInvalidated) {
      _ = try await store.imapSend(
        segments: [["text": head + body]], recipients: recipients, connection: id,
        address: "alex@example.invalid", generation: UUID().uuidString)
    }
    smtp.failure = PrivateInboxError.deliveryUnknown
    await #expect(throws: PrivateInboxError.deliveryUnknown) {
      _ = try await store.imapSend(
        segments: [["text": head + body]], recipients: recipients, connection: id,
        address: "alex@example.invalid", generation: generation)
    }
    smtp.failure = nil
    #expect(smtp.submissions().count == 1)

    // Filing the Sent copy again finds it.
    _ = try await store.imapFileSent(
      segments: [["text": head + body]], folder: "Sent", boundary: "=_sentcopy1", connection: id,
      address: "alex@example.invalid", generation: generation)
    #expect(imap.copy("=_sentcopy1") == Data((head + body).utf8))
    let found = try await store.imapFindSent(
      folder: "Sent", boundary: "=_sentcopy1", connection: id, address: "alex@example.invalid",
      generation: generation)
    #expect(found["count"] as? Double == 1)
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.imapFindSent(
        folder: "Sent", boundary: "=_sent copy", connection: id, address: "alex@example.invalid",
        generation: generation)
    }
    #expect(imap.requests().allSatisfy { $0.1 == "app-password" })
    // Filing is a provider write too: no server access without a current device proof.
    let requests = imap.requests().count
    proofAvailable = false
    await #expect(throws: RegistrationError.unavailable) {
      _ = try await store.imapFileSent(
        segments: [["text": head + body]], folder: "Sent", boundary: "=_sentcopy1", connection: id,
        address: "alex@example.invalid", generation: generation)
    }
    proofAvailable = true
    revoked = true
    await #expect(throws: RegistrationError.revoked) {
      _ = try await store.imapFileSent(
        segments: [["text": head + body]], folder: "Sent", boundary: "=_sentcopy1", connection: id,
        address: "alex@example.invalid", generation: generation)
    }
    #expect(imap.requests().count == requests)
    #expect(try store.load() == nil)
  }

  // The unchanged SwiftMail SMTP client over verified implicit TLS and STARTTLS: a server that
  // offers no STARTTLS is left before any password, and each submission outcome keeps its meaning.
  // Sent copies are searched and appended through the real IMAP engine.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["UNWIRED_SMTP_TLS_TEST_PORTS"] != nil))
  func swiftMailSubmitsOverVerifiedTLSAndFilesSentCopies() async throws {
    let ports = try #require(ProcessInfo.processInfo.environment["UNWIRED_SMTP_TLS_TEST_PORTS"])
      .split(separator: ",").compactMap { Int($0) }
    try #require(ports.count == 3)
    func endpoint(_ port: Int, startTLS: Bool, _ user: String) throws -> SmtpAccount {
      try JSONDecoder().decode(
        SmtpAccount.self,
        from: Data(
          #"{"host":"localhost","port":\#(port),"startTLS":\#(startTLS),"username":"\#(user)"}"#
            .utf8))
    }
    let provider = SwiftMailSmtp()
    let message = Data(
      "From: alex@example.invalid\r\nTo: sam@example.invalid\r\nSubject: Controlled SMTP\r\n\r\nBody\r\n"
        .utf8)
    func send(_ smtp: SmtpAccount) async throws {
      try await provider.send(
        smtp, password: "synthetic-password", from: "alex@example.invalid",
        to: ["sam@example.invalid", "jo@example.invalid"], message: message)
    }
    try await provider.verify(endpoint(ports[0], startTLS: false, "synthetic"), password: "synthetic-password")
    try await send(endpoint(ports[0], startTLS: false, "synthetic"))
    try await send(endpoint(ports[1], startTLS: true, "synthetic"))
    await #expect(throws: SmtpFailure.insecure) {
      try await send(endpoint(ports[2], startTLS: true, "synthetic"))
    }
    await #expect(throws: SmtpFailure.authentication) {
      try await provider.verify(endpoint(ports[0], startTLS: false, "refused"), password: "synthetic-password")
    }
    await #expect(throws: SmtpFailure.offline) {
      try await send(endpoint(ports[0], startTLS: false, "busy"))
    }
    await #expect(throws: SmtpFailure.rejected) {
      try await send(endpoint(ports[0], startTLS: false, "reject"))
    }
    await #expect(throws: PrivateInboxError.deliveryUnknown) {
      try await send(endpoint(ports[1], startTLS: true, "drop"))
    }

    // Lost replies before message content remain safe; any content-phase interruption is unknown.
    for phase in ["drop-mail", "drop-rcpt", "drop-data"] {
      await #expect(throws: SmtpFailure.offline) {
        try await send(endpoint(ports[0], startTLS: false, phase))
      }
    }
    await #expect(throws: PrivateInboxError.deliveryUnknown) {
      try await send(endpoint(ports[0], startTLS: false, "drop-body"))
    }
    // One accepted recipient plus one refused recipient must never submit partial delivery.
    await #expect(throws: SmtpFailure.rejected) {
      try await send(endpoint(ports[0], startTLS: false, "reject-recipient"))
    }

    let imapPort = try #require(
      Int(ProcessInfo.processInfo.environment["UNWIRED_IMAP_TLS_TEST_PORT"] ?? ""))
    let imap = try JSONDecoder().decode(
      ImapAccount.self,
      from: Data(#"{"host":"localhost","port":\#(imapPort),"username":"synthetic"}"#.utf8))
    let copy = Data(
      ("From: alex@example.invalid\r\nBcc: jo@example.invalid\r\n"
        + "Content-Type: multipart/mixed; boundary=\"=_sentcopy1\"\r\n\r\n--=_sentcopy1--\r\n").utf8)
    let engine = SwiftMailImap()
    #expect(
      try await engine.findSent(
        imap, password: "synthetic-password", folder: "Sent", boundary: "=_sentcopy1") == 0)
    try await engine.fileSent(
      imap, password: "synthetic-password", folder: "Sent", boundary: "=_sentcopy1", message: copy)
    // Filing again finds the copy; the fixture refuses a second append.
    try await engine.fileSent(
      imap, password: "synthetic-password", folder: "Sent", boundary: "=_sentcopy1", message: copy)
    #expect(
      try await engine.findSent(
        imap, password: "synthetic-password", folder: "Sent", boundary: "=_sentcopy1") == 1)
  }
}
