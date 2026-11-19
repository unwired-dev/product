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
    // Mailboxes the server accepted or may have accepted a message for that the test has not yet
    // finished waiting for. Polling for delivery shares one 70-second budget and cleanup's polling
    // one 16-second budget, within the test's 120-second allowance.
    var unread = Set<String>()
    var delivery = ContinuousClock.now
    var cleanup = ContinuousClock.now

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
    func messageId(_ provider: Provider) -> String { "\(provider.name.prefix(6))\(token)@unwired.dev" }
    func message(from sender: Provider, to recipient: Provider) -> Data {
      let mark = boundary(sender)
      let lines: [String] = [
        "From: \(sender.address)", "To: \(recipient.address)",
        "Subject: Unwired certification \(token)",
        "Message-ID: <\(messageId(sender))>", "Date: \(date)",
        "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"\(mark)\"", "",
        "--\(mark)", "Content-Type: text/plain; charset=utf-8", "",
        "Certification body \(token)", "--\(mark)--", "",
      ]
      return Data(lines.joined(separator: "\r\n").utf8)
    }
    // Each mailbox's messages are checked, then this run's messages are removed from both mailboxes
    // whatever happened, and the first failure is reported.
    func verify(_ provider: Provider, from sender: Provider) async throws {
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
        let inboxOnly = folders.map(\.name) == ["INBOX"]
        if provider.name == "iCloud Mail" {
          withKnownIssue("The iCloud Mail test mailbox lists only INBOX (#2401)") { #expect(!inboxOnly) }
        }
        if provider.name != "iCloud Mail" || !inboxOnly {
          #expect(sent != nil && trash != nil)
        }

        // The other mailbox's message is delivered, found by search, read and marked. Each write
        // first requires the folder's UIDVALIDITY to be the one the search's UIDs belong to.
        var matches = try await session.search("INBOX", for: .text(token), newest: 10)
        while matches.total == 0, ContinuousClock.now < delivery {
          try await Task.sleep(for: .seconds(2))
          matches = try await session.search("INBOX", for: .text(token), newest: 10)
        }
        try #require(matches.total == 1)
        unread.remove(provider.name)
        let uid = try #require(matches.uids.first)
        try #require(try await session.examine("INBOX").uidValidity == matches.uidValidity)
        let envelope = try #require(try await session.envelopes(.uids([uid])).first)
        #expect(envelope.subject == "Unwired certification \(token)")
        // Compared as values, so a failure prints no address.
        let fromSender = envelope.address.lowercased() == sender.address.lowercased()
        #expect(fromSender)
        let raw = try await imapProvider.message(
          provider.imap, password: provider.password, folder: "INBOX",
          uidValidity: matches.uidValidity, uid: uid, limit: RegistrationStore.imapMessageLimit)
        let hasBody = String(decoding: raw, as: UTF8.self).contains("Certification body \(token)")
        #expect(hasBody)
        try #require(try await session.select("INBOX") == matches.uidValidity)
        for seen in [false, true] {
          try await session.store(uid, flag: .seen, set: seen)
          #expect(try await session.flags([uid])[uid]?.contains("\\Seen") == seen)
        }

        // Moved to Trash: MOVE where the server offers it, else COPY and a targeted UID EXPUNGE.
        if let trash {
          if capabilities.contains("MOVE") {
            _ = try await session.move(uid, to: trash)
          } else {
            _ = try await session.copy(uid, to: trash)
            try await session.store(uid, flag: .deleted, set: true)
            try await session.expunge(uid)
          }
          #expect(try await session.search("INBOX", for: .text(token), newest: 1).total == 0)
          #expect(try await session.search(trash, for: .text(token), newest: 2).total == 1)
        }

        // The product's filing rule: a Message-ID lookup in Sent, an append only when it finds no
        // copy, and then exactly one copy.
        if let sent {
          func lookup() async throws -> Int {
            try await session.search(sent, for: .messageId(messageId(provider)), newest: 2).total
          }
          let filed = try await lookup()
          record("\(provider.name): \(filed) Sent copy filed by the provider")
          if filed == 0 {
            try await session.append(sent, message: message(from: provider, to: sender))
          }
          #expect(try await lookup() == 1)
          // Sent holds exactly this one outgoing copy, also when searched by text.
          #expect(try await session.search(sent, for: .text(token), newest: 2).total == 1)
        }
        await session.close()
      } catch {
        await session.close()
        throw error
      }
    }

    // Removes this run's messages from INBOX, Sent and Trash, trying every folder, and reports the
    // first failure. A message accepted for a mailbox whose INBOX the test never finished waiting
    // on is waited for here, until its INBOX holds one.
    func clean(_ provider: Provider) async throws {
      let session = try await imapProvider.open(provider.imap, password: provider.password)
      var failure: (any Error)?
      var delivered = 0
      do {
        let folders = try await session.folders().filter {
          $0.name == "INBOX" || !Set($0.attributes).isDisjoint(with: ["\\Sent", "\\Trash"])
        }
        func sweep() async {
          for folder in folders.map(\.name) {
            do {
              let leftovers = try await session.search(folder, for: .text(token), newest: 10)
              try #require(try await session.select(folder) == leftovers.uidValidity)
              for uid in leftovers.uids {
                try await session.store(uid, flag: .deleted, set: true)
                try await session.expunge(uid)
              }
              if folder == "INBOX" { delivered += leftovers.uids.count }
              #expect(try await session.search(folder, for: .text(token), newest: 1).total == 0)
            } catch {
              failure = failure ?? error
            }
          }
        }
        await sweep()
        while unread.contains(provider.name), delivered == 0, ContinuousClock.now < cleanup {
          try await Task.sleep(for: .seconds(2))
          await sweep()
        }
      } catch {
        failure = failure ?? error
      }
      await session.close()
      if let failure { throw failure }
    }

    var failure: (any Error)?
    do {
      for (sender, recipient) in [(providers[0], providers[1]), (providers[1], providers[0])] {
        do {
          try await smtpProvider.send(
            sender.smtp, password: sender.password, from: sender.address, to: [recipient.address],
            message: message(from: sender, to: recipient))
        } catch PrivateInboxError.deliveryUnknown {
          unread.insert(recipient.name)
          throw PrivateInboxError.deliveryUnknown
        }
        unread.insert(recipient.name)
      }
      delivery = .now + .seconds(70)
      for (index, provider) in providers.enumerated() {
        try await verify(provider, from: providers[1 - index])
      }
    } catch {
      failure = error
    }
    cleanup = .now + .seconds(16)
    for provider in providers {
      do { try await clean(provider) } catch { failure = failure ?? error }
    }
    if let failure { throw failure }
  }
}
