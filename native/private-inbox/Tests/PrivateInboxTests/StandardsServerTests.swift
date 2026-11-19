import Foundation
import Testing

@testable import PrivateInbox

extension PrivateInboxTests {
  // The unchanged engine against the controlled standards server, Dovecot and Postfix with
  // synthetic mailboxes, which `integration/standards-server.zsh` starts. Its ports, in order:
  // IMAP 993 and 143, SMTP 465, 587 and 2525, then IMAP 993 and SMTP 465 of a server presenting
  // an untrusted self-signed certificate.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["UNWIRED_STANDARDS_SERVER_PORTS"] != nil))
  func swiftMailUsesTheControlledStandardsServer() async throws {
    let ports = try #require(ProcessInfo.processInfo.environment["UNWIRED_STANDARDS_SERVER_PORTS"])
      .split(separator: ",").compactMap { Int($0) }
    try #require(ports.count == 7)
    let password = "synthetic-password"
    func imap(_ port: Int, _ user: String) throws -> ImapAccount {
      try JSONDecoder().decode(
        ImapAccount.self,
        from: Data(#"{"host":"localhost","port":\#(port),"username":"\#(user)@example.test"}"#.utf8))
    }
    func smtp(_ port: Int, startTLS: Bool) throws -> SmtpAccount {
      try JSONDecoder().decode(
        SmtpAccount.self,
        from: Data(
          #"{"host":"localhost","port":\#(port),"startTLS":\#(startTLS),"username":"alex@example.test"}"#
            .utf8))
    }
    let imapProvider = SwiftMailImap()
    let smtpProvider = SwiftMailSmtp()
    let token = UUID().uuidString
    func boundary(_ subject: String) -> String { "=_\(subject)\(token)" }
    func messageId(_ subject: String) -> String { "\(subject).\(token)@example.test" }
    func message(_ subject: String) -> Data {
      Data(
        ("From: alex@example.test\r\nTo: sam@example.test\r\nSubject: \(subject) \(token)\r\n"
          + "Message-ID: <\(messageId(subject))>\r\n"
          + "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"\(boundary(subject))\"\r\n\r\n"
          + "--\(boundary(subject))\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
          + "Standards body \(token)\r\n--\(boundary(subject))--\r\n").utf8)
    }

    // Password login over implicit TLS, and submission over implicit TLS and STARTTLS.
    try await imapProvider.verify(imap(ports[0], "sam"), password: password)
    await #expect(throws: ImapFailure.authentication) {
      try await imapProvider.verify(imap(ports[0], "sam"), password: "refused")
    }
    try await smtpProvider.verify(smtp(ports[2], startTLS: false), password: password)
    await #expect(throws: SmtpFailure.authentication) {
      try await smtpProvider.verify(smtp(ports[2], startTLS: false), password: "refused")
    }
    for (port, startTLS, subject) in [(ports[2], false, "Implicit"), (ports[3], true, "STARTTLS")] {
      try await smtpProvider.send(
        smtp(port, startTLS: startTLS), password: password, from: "alex@example.test",
        to: ["sam@example.test"], message: message(subject))
    }

    // Both submissions are delivered: listed with their roles, read, searched and moved.
    let session = try await imapProvider.open(imap(ports[0], "sam"), password: password)
    do {
      let roles = Dictionary(
        uniqueKeysWithValues: try await session.folders().map { ($0.name, Set($0.attributes)) })
      for role in ["Archive", "Drafts", "Junk", "Sent", "Trash"] {
        #expect(roles[role]?.contains("\\\(role)") == true)
      }
      #expect(
        Set(try await session.capabilities().map { $0.uppercased() })
          .isSuperset(of: ["MOVE", "UIDPLUS", "SPECIAL-USE"]))
      var matches = try await session.search("INBOX", for: .text(token), newest: 10)
      for _ in 0..<50 where matches.total < 2 {
        try await Task.sleep(for: .milliseconds(200))
        matches = try await session.search("INBOX", for: .text(token), newest: 10)
      }
      #expect(matches.total == 2)
      let selection = try await session.examine("INBOX")
      #expect(selection.uidValidity == matches.uidValidity)
      let envelopes = try await session.envelopes(.uids(matches.uids))
      #expect(Set(envelopes.map(\.subject)) == ["Implicit \(token)", "STARTTLS \(token)"])
      #expect(envelopes.allSatisfy { $0.address == "alex@example.test" })
      let uid = try #require(matches.uids.first)
      let raw = try await imapProvider.message(
        imap(ports[0], "sam"), password: password, folder: "INBOX",
        uidValidity: matches.uidValidity, uid: uid, limit: RegistrationStore.imapMessageLimit)
      #expect(String(decoding: raw, as: UTF8.self).contains("Standards body \(token)"))
      #expect(try await session.select("INBOX") == matches.uidValidity)
      try await session.store(uid, flag: .seen, set: true)
      #expect(try await session.flags([uid])[uid]?.contains("\\Seen") == true)
      let moved = try #require(try await session.move(uid, to: "Archive"))
      #expect(try await session.search("Archive", for: .text(token), newest: 1).uids == [moved.uid])
      #expect(try await session.search("INBOX", for: .text(token), newest: 10).total == 1)
      await session.close()
    } catch {
      await session.close()
      throw error
    }

    // The submitted message's copy is filed in the sender's Sent folder and found by its Message-ID.
    let sent = try await imapProvider.open(imap(ports[0], "alex"), password: password)
    do {
      let copy = ImapSearchCriterion.messageId(messageId("Implicit"))
      #expect(try await sent.search("Sent", for: copy, newest: 1).total == 0)
      try await sent.append("Sent", message: message("Implicit"))
      #expect(try await sent.search("Sent", for: copy, newest: 1).total == 1)
      await sent.close()
    } catch {
      await sent.close()
      throw error
    }

    // Refusals before any password: IMAP on 143, which allows LOGIN without TLS; SMTP offering
    // AUTH without STARTTLS; and the untrusted certificate on IMAP and SMTP. The runner checks the
    // server logs show no login on any of them.
    await #expect(throws: ImapFailure.insecure) {
      try await imapProvider.verify(imap(ports[1], "sam"), password: password)
    }
    await #expect(throws: SmtpFailure.insecure) {
      try await smtpProvider.verify(smtp(ports[4], startTLS: true), password: password)
    }
    await #expect(throws: ImapFailure.insecure) {
      try await imapProvider.verify(imap(ports[5], "sam"), password: password)
    }
    await #expect(throws: SmtpFailure.insecure) {
      try await smtpProvider.verify(smtp(ports[6], startTLS: false), password: password)
    }
  }
}
