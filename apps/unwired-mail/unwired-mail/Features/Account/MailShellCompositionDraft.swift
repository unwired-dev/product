import Foundation

enum MailCompositionKind: String, Codable, Sendable {
  case editing
  case forward
  case newMessage
  case reply
  case replyAll
}

// swiftlint:disable:next type_body_length
struct MailShellCompositionDraft: Codable, Equatable, Identifiable, Sendable {
  var bccRecipients: String
  var body: String
  var ccRecipients: String
  var connectionId: MailboxConnectionId?
  var hasExplicitReadReceiptChoice: Bool
  let id: UUID
  let kind: MailCompositionKind
  var quotedText: String?
  var recipient: String
  let replyToMessage: MailboxMessageMetadata?
  var requestsReadReceipt: Bool
  let sourceMessage: MailboxMessageMetadata?
  var signature: MailSignature?
  var subject: String
  var updatedAtMilliseconds: Int64

  init(
    body: String,
    connectionId: MailboxConnectionId?,
    recipient: String,
    replyToMessage: MailboxMessageMetadata?,
    requestsReadReceipt: Bool = false,
    sourceMessage: MailboxMessageMetadata?,
    subject: String,
    bccRecipients: String = "",
    ccRecipients: String = "",
    hasExplicitReadReceiptChoice: Bool = false,
    id: UUID = UUID(),
    kind: MailCompositionKind = .newMessage,
    quotedText: String? = nil,
    signature: MailSignature? = nil,
    updatedAtMilliseconds: Int64 = Int64(Date.now.timeIntervalSince1970 * 1_000)
  ) {
    self.bccRecipients = bccRecipients
    self.body = body
    self.ccRecipients = ccRecipients
    self.connectionId = connectionId
    self.hasExplicitReadReceiptChoice = hasExplicitReadReceiptChoice
    self.id = id
    self.kind = kind
    self.quotedText = quotedText
    self.recipient = recipient
    self.replyToMessage = replyToMessage
    self.requestsReadReceipt = requestsReadReceipt
    self.sourceMessage = sourceMessage
    self.signature = signature
    self.subject = subject
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }

  var sourceMailboxIdentity: StableProviderMailboxIdentity? {
    sourceMessage?.connectionId.providerMailboxIdentity
  }

  var sourceThreadId: MailboxThreadIdentity? {
    sourceMessage?.threadIdentity
  }

  var forwardSourceMessage: MailboxMessageMetadata? {
    replyToMessage == nil ? sourceMessage : nil
  }

  var title: String {
    switch kind {
    case .editing: "Edit Message"
    case .forward: "Forward"
    case .newMessage: "New Message"
    case .reply: "Reply"
    case .replyAll: "Reply All"
    }
  }

  var deliveryRecipientHeader: String {
    [recipient, ccRecipients, bccRecipients]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  var deliveryBody: String {
    var composedBody = body
    if let signature {
      let signatureText = signature.document.plainText
      composedBody += composedBody.isEmpty ? "-- \n\(signatureText)" : "\n\n-- \n\(signatureText)"
    }
    guard let quotedText, !quotedText.isEmpty else { return composedBody }
    let quotedLines = quotedText.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> \($0)" }
      .joined(separator: "\n")
    return composedBody.isEmpty ? quotedLines : composedBody + "\n\n" + quotedLines
  }

  var hasUserState: Bool {
    [bccRecipients, body, ccRecipients, recipient, subject]
      .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      || signature != nil
  }

  var recipientsAreValid: Bool {
    let recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !recipient.isEmpty, RFCMailboxHeaderParser.mailboxes(in: recipient) != nil else {
      return false
    }
    return [ccRecipients, bccRecipients].allSatisfy { value in
      let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty || RFCMailboxHeaderParser.mailboxes(in: value) != nil
    }
  }

  var signatureContext: SignatureComposeContext {
    sourceMessage == nil ? .newMessage : .replyOrForward
  }

  mutating func applyDefaultSignature(from preferences: SignaturePreferences) {
    signature = preferences.signature(for: connectionId, context: signatureContext)
  }

  mutating func applyInitialReadReceiptPolicy(_ policy: OutgoingReadReceiptPolicy) {
    switch policy {
    case .never:
      requestsReadReceipt = false
    case .askWhileSending:
      break
    case .requestByDefault:
      if !hasExplicitReadReceiptChoice {
        requestsReadReceipt = true
      }
    }
  }

  mutating func recordReadReceiptChoice(_ requestsReadReceipt: Bool) {
    self.requestsReadReceipt = requestsReadReceipt
    hasExplicitReadReceiptChoice = true
  }

  mutating func markEdited(now: Date = .now) {
    updatedAtMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
  }

  static func new(
    defaultSendingConnectionId: MailboxConnectionId?,
    signatures: SignaturePreferences = .empty
  ) -> MailShellCompositionDraft {
    var draft = MailShellCompositionDraft(
      body: "",
      connectionId: defaultSendingConnectionId,
      recipient: "",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "",
      kind: .newMessage
    )
    draft.applyDefaultSignature(from: signatures)
    return draft
  }

  static func editing(_ attempt: OutgoingDeliveryAttempt) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: attempt.message.body,
      connectionId: attempt.mailboxConnectionId,
      recipient: attempt.message.recipient,
      replyToMessage: nil,
      requestsReadReceipt: attempt.message.requestsReadReceipt == true,
      sourceMessage: nil,
      subject: attempt.message.subject,
      bccRecipients: attempt.message.bccRecipients ?? "",
      ccRecipients: attempt.message.ccRecipients ?? "",
      hasExplicitReadReceiptChoice: true,
      kind: .editing
    )
  }

  static func reply(
    to message: MailboxMessageMetadata,
    quotedText: String? = nil
  ) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "",
      connectionId: message.connectionId,
      recipient: replyRecipient(for: message),
      replyToMessage: message,
      sourceMessage: message,
      subject: prefixedSubject("Re:", subject: message.subject),
      kind: .reply,
      quotedText: quotedText
    )
  }

  static func replyAll(
    to message: MailboxMessageMetadata,
    senderAddress: String,
    quotedText: String? = nil
  ) -> MailShellCompositionDraft {
    let senderAliases = Set(
      [normalizedMailboxAddress(senderAddress)]
        + (message.providerStateIds?.contains("SENT") == true
          ? mailboxValues(in: message.from ?? "").map(normalizedMailboxAddress)
          : [])
    )
    let isLegacyGmailSent =
      message.connectionId.providerId == .gmail
      && message.providerStateIds?.contains("SENT") == true
      && message.bccRecipients == nil
    let candidates =
      isLegacyGmailSent
      ? []
      : [message.replyTo ?? message.from].compactMap(\.self)
        + (message.recipientHeaders ?? []).flatMap(mailboxValues)
    var seenAddresses: Set<String> = []
    let recipients = candidates.filter { address in
      let normalizedAddress = normalizedMailboxAddress(address)
      guard !normalizedAddress.isEmpty, !senderAliases.contains(normalizedAddress) else {
        return false
      }
      return seenAddresses.insert(normalizedAddress).inserted
    }
    var draft = reply(to: message, quotedText: quotedText)
    draft.recipient =
      recipients.isEmpty && !isLegacyGmailSent
      ? message.replyTo ?? message.from ?? ""
      : recipients.joined(separator: ", ")
    return MailShellCompositionDraft(
      body: draft.body,
      connectionId: draft.connectionId,
      recipient: draft.recipient,
      replyToMessage: draft.replyToMessage,
      sourceMessage: draft.sourceMessage,
      subject: draft.subject,
      kind: .replyAll,
      quotedText: draft.quotedText
    )
  }

  static func replyAllIsApplicable(
    to message: MailboxMessageMetadata,
    senderAddress: String
  ) -> Bool {
    let replyRecipient = normalizedMailboxAddress(replyRecipient(for: message))
    return mailboxValues(in: replyAll(to: message, senderAddress: senderAddress).recipient)
      .map(normalizedMailboxAddress)
      .contains { !$0.isEmpty && $0 != replyRecipient }
  }

  static func replyRecipient(for message: MailboxMessageMetadata) -> String {
    if message.providerStateIds?.contains("SENT") == true {
      return message.recipientHeaders?.first ?? message.replyTo ?? message.from ?? ""
    }
    return message.replyTo ?? message.from ?? ""
  }

  static func forward(
    _ message: MailboxMessageMetadata,
    body: String
  ) -> MailShellCompositionDraft {
    MailShellCompositionDraft(
      body: "",
      connectionId: message.connectionId,
      recipient: "",
      replyToMessage: nil,
      sourceMessage: message,
      subject: prefixedSubject("Fwd:", subject: message.subject),
      kind: .forward,
      quotedText: "Forwarded message from \(message.from ?? "Unknown sender"):\n\(body)"
    )
  }

  private static func mailboxValues(in value: String) -> [String] {
    var mailboxes: [String] = []
    var mailbox = ""
    var isEscaped = false
    var isQuoted = false
    var angleBracketDepth = 0

    for character in value {
      if isEscaped {
        mailbox.append(character)
        isEscaped = false
        continue
      }
      if character == "\\" && isQuoted {
        mailbox.append(character)
        isEscaped = true
        continue
      }
      switch character {
      case "\"":
        isQuoted.toggle()
      case "<":
        angleBracketDepth += 1
      case ">":
        angleBracketDepth = max(0, angleBracketDepth - 1)
      case "," where !isQuoted && angleBracketDepth == 0:
        mailboxes.append(mailbox.trimmingCharacters(in: .whitespacesAndNewlines))
        mailbox = ""
        continue
      default:
        break
      }
      mailbox.append(character)
    }
    mailboxes.append(mailbox.trimmingCharacters(in: .whitespacesAndNewlines))
    return mailboxes
  }

  private static func normalizedMailboxAddress(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let opening = trimmed.lastIndex(of: "<"),
      let closing = trimmed.lastIndex(of: ">"),
      opening < closing
    else {
      return trimmed.lowercased()
    }
    return String(trimmed[trimmed.index(after: opening)..<closing])
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func prefixedSubject(_ prefix: String, subject: String) -> String {
    let trimmedSubject = subject == "(No subject)" ? "" : subject
    guard !trimmedSubject.isEmpty else { return prefix }
    guard trimmedSubject.range(of: prefix, options: [.caseInsensitive, .anchored]) == nil else {
      return trimmedSubject
    }
    return "\(prefix) \(trimmedSubject)"
  }
}
