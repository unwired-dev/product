import Foundation
import Testing

@testable import PrivateInbox

extension PrivateInboxTests {
  // The unchanged engine against the dedicated iCloud Mail and Seznam Email test mailboxes, which
  // `integration/providers.zsh` reads from the password manager. Each mailbox sends one message to
  // the other, which is delivered, searched, read, marked, filed in Sent and removed. Records only
  // provider names, roles, capabilities and outcomes, never an address or password.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["UNWIRED_SEZNAM_PASSWORD"] != nil))
  func swiftMailUsesTheCertificationMailboxes() async throws {
    struct Provider {
      let name: String
      let address: String
      let password: String
      var imap: ImapAccount
      let smtp: SmtpAccount
    }
    let environment = ProcessInfo.processInfo.environment
    func provider(_ name: String, _ key: String, imap: String, smtp: String, startTLS: Bool)
      throws -> Provider
    {
      let address = try #require(environment["UNWIRED_\(key)_ADDRESS"])
      let password = try #require(environment["UNWIRED_\(key)_PASSWORD"])
      // iCloud Mail's catalogued IMAP user name is the name part of the address.
      let user = key == "ICLOUD" ? String(address.prefix { $0 != "@" }) : address
      return Provider(
        name: name, address: address, password: password,
        imap: try ImapAccount(host: imap, port: 993, username: user),
        smtp: try SmtpAccount(host: smtp, port: startTLS ? 587 : 465, startTLS: startTLS, username: address))
    }
    var providers = [
      try provider("iCloud Mail", "ICLOUD", imap: "imap.mail.me.com", smtp: "smtp.mail.me.com", startTLS: true),
      try provider("Seznam Email", "SEZNAM", imap: "imap.seznam.cz", smtp: "smtp.seznam.cz", startTLS: false),
    ]
    // The test host's standard output never reaches the xcodebuild log; standard error does.
    func record(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }
    let imapProvider = SwiftMailImap()
    let smtpProvider = SwiftMailSmtp()
    let token = UUID().uuidString

    // Logins with the mail-client password, retrying iCloud Mail once with the full address as the
    // product does; a wrong password is refused as an authentication failure.
    for index in providers.indices {
      let provider = providers[index]
      do {
        try await imapProvider.verify(provider.imap, password: provider.password)
        record("\(provider.name): IMAP login with the catalogued user name")
      } catch ImapFailure.authentication where provider.imap.username != provider.address {
        providers[index].imap = try ImapAccount(
          host: provider.imap.host, port: 993, username: provider.address)
        try await imapProvider.verify(providers[index].imap, password: provider.password)
        record("\(provider.name): IMAP login with the full address")
      }
      await #expect(throws: ImapFailure.authentication) {
        try await imapProvider.verify(providers[index].imap, password: "refused-\(token)")
      }
      try await smtpProvider.verify(provider.smtp, password: provider.password)
      await #expect(throws: SmtpFailure.authentication) {
        try await smtpProvider.verify(provider.smtp, password: "refused-\(token)")
      }
    }

    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    let date = format.string(from: Date())
    func boundary(_ provider: Provider) -> String { "=_\(provider.name.prefix(6))\(token)" }
    func message(from sender: Provider, to recipient: Provider) -> Data {
      let mark = boundary(sender)
      let lines: [String] = [
        "From: \(sender.address)", "To: \(recipient.address)",
        "Subject: Unwired certification \(token)",
        "Message-ID: <\(sender.name.prefix(6))\(token)@unwired.dev>", "Date: \(date)",
        "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"\(mark)\"", "",
        "--\(mark)", "Content-Type: text/plain; charset=utf-8", "",
        "Certification body \(token)", "--\(mark)--", "",
      ]
      return Data(lines.joined(separator: "\r\n").utf8)
    }
    for (sender, recipient) in [(providers[0], providers[1]), (providers[1], providers[0])] {
      try await smtpProvider.send(
        sender.smtp, password: sender.password, from: sender.address, to: [recipient.address],
        message: message(from: sender, to: recipient))
    }

    for (index, provider) in providers.enumerated() {
      let sender = providers[1 - index]
      let session = try await imapProvider.open(provider.imap, password: provider.password)
      do {
        let folders = try await session.folders()
        func role(_ role: String) -> [String] {
          folders.filter { $0.attributes.contains("\\\(role)") }.map(\.name)
        }
        let roles = ["Archive", "Drafts", "Junk", "Sent", "Trash"].map { "\($0): \(role($0).count)" }
        let capabilities = try await session.capabilities().map { $0.uppercased() }
        record("\(provider.name): \(folders.count) folders, roles \(roles), capabilities \(capabilities.sorted())")
        // Sending needs exactly one Sent folder, and organizing a Trash folder.
        let sent = role("Sent").count == 1 ? role("Sent").first : nil
        let trash = role("Trash").first
        if provider.name == "iCloud Mail" {
          withKnownIssue("The iCloud Mail test mailbox lists only INBOX (#2401)") {
            #expect(sent != nil && trash != nil)
          }
        } else {
          #expect(sent != nil && trash != nil)
        }

        // The other mailbox's message is delivered, found by search, read and marked.
        var matches = try await session.search("INBOX", for: .text(token), newest: 10)
        for _ in 0..<45 where matches.total == 0 {
          try await Task.sleep(for: .seconds(2))
          matches = try await session.search("INBOX", for: .text(token), newest: 10)
        }
        try #require(matches.total == 1)
        let uid = try #require(matches.uids.first)
        _ = try await session.examine("INBOX")
        let envelope = try #require(try await session.envelopes(.uids([uid])).first)
        #expect(envelope.subject == "Unwired certification \(token)")
        // Compared as a value, so a failure prints no address.
        let fromSender = envelope.address.lowercased() == sender.address.lowercased()
        #expect(fromSender)
        let raw = try await imapProvider.message(
          provider.imap, password: provider.password, folder: "INBOX",
          uidValidity: matches.uidValidity, uid: uid, limit: RegistrationStore.imapMessageLimit)
        #expect(String(decoding: raw, as: UTF8.self).contains("Certification body \(token)"))
        #expect(try await session.select("INBOX") == matches.uidValidity)
        try await session.store(uid, flag: .seen, set: true)
        #expect(try await session.flags([uid])[uid]?.contains("\\Seen") == true)

        // Moved to Trash; and filing appends the submitted message unless a copy with its
        // boundary is already in Sent.
        if let trash {
          _ = try await session.move(uid, to: trash)
          #expect(try await session.search("INBOX", for: .text(token), newest: 1).total == 0)
        }
        if let sent {
          let file = {
            let filed = try await session.search(sent, for: .boundary(boundary(provider)), newest: 1).total
            record("\(provider.name): \(filed) Sent copy filed by the provider")
            if filed == 0 {
              try await session.append(sent, message: message(from: provider, to: sender))
            }
            #expect(try await session.search(sent, for: .boundary(boundary(provider)), newest: 2).total == 1)
          }
          if provider.name == "Seznam Email" {
            await withKnownIssue("Seznam Email drops the connection on a Content-Type search (#2402)") {
              try await file()
            }
          } else {
            try await file()
          }
        }
        await session.close()
      } catch {
        await session.close()
        throw error
      }

      // Removes this run's messages, and any an interrupted run left, in a new session.
      let cleanup = try await imapProvider.open(provider.imap, password: provider.password)
      do {
        let folders = try await cleanup.folders().filter {
          $0.name == "INBOX" || !Set($0.attributes).isDisjoint(with: ["\\Sent", "\\Trash"])
        }
        for folder in folders.map(\.name) {
          let leftovers = try await cleanup.search(folder, for: .text("Unwired certification"), newest: 50)
          _ = try await cleanup.select(folder)
          for uid in leftovers.uids {
            try await cleanup.store(uid, flag: .deleted, set: true)
            try await cleanup.expunge(uid)
          }
          #expect(try await cleanup.search(folder, for: .text(token), newest: 1).total == 0)
        }
        await cleanup.close()
      } catch {
        await cleanup.close()
        throw error
      }
    }
  }
}
