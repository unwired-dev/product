import SwiftMail

enum QualificationMailboxRole: String, Sendable {
  case inbox
  case junk
  case sent
}

struct ResolvedQualificationMailbox: Sendable {
  let mailbox: Mailbox.Info
  let source: String
}

enum MailboxRoleResolver {
  static func resolve(
    _ role: QualificationMailboxRole,
    from mailboxes: [Mailbox.Info],
    explicitName: String?
  ) throws -> ResolvedQualificationMailbox {
    if role == .inbox {
      let inboxes = mailboxes.filter {
        $0.name.caseInsensitiveCompare("INBOX") == .orderedSame
      }
      guard inboxes.count == 1, let inbox = inboxes.first else {
        throw QualificationError.failed("The provider did not expose one canonical INBOX.")
      }
      return ResolvedQualificationMailbox(mailbox: inbox, source: "canonical-inbox")
    }

    let attributed = mailboxes.filter { mailbox in
      switch role {
      case .inbox: false
      case .junk: mailbox.attributes.contains(.junk)
      case .sent: mailbox.attributes.contains(.sent)
      }
    }
    if attributed.count == 1, let mailbox = attributed.first {
      return ResolvedQualificationMailbox(mailbox: mailbox, source: "special-use")
    }
    if attributed.count > 1 {
      throw QualificationError.failed("The provider exposed an ambiguous \(role.rawValue) role.")
    }

    guard let explicitName else {
      throw QualificationError.failed(
        "The provider omitted the \(role.rawValue) role and no explicit mapping was configured."
      )
    }
    let explicitlyMapped = mailboxes.filter { $0.name == explicitName && $0.isSelectable }
    guard explicitlyMapped.count == 1, let mailbox = explicitlyMapped.first else {
      throw QualificationError.failed(
        "The explicit \(role.rawValue) role did not identify one selectable mailbox."
      )
    }
    return ResolvedQualificationMailbox(mailbox: mailbox, source: "explicit-validated")
  }
}
