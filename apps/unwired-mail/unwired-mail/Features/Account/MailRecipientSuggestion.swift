import Foundation

#if canImport(Contacts)
  import Contacts
#endif

enum MailRecipientSuggestionSource: Int, Codable, Equatable, Sendable {
  case recent = 0
  case correspondent = 1
  case contact = 2
}

struct MailRecipientSuggestion: Equatable, Identifiable, Sendable {
  let displayName: String?
  let emailAddress: String
  let source: MailRecipientSuggestionSource

  var id: String { emailAddress.lowercased() }

  var headerValue: String {
    RFCMailbox(displayName: displayName, emailAddress: emailAddress).headerValue
  }
}

/// Editable To, Cc, and Bcc state backed by RFC mailbox header strings.
struct MailRecipientEditor: Equatable, Sendable {
  enum Field: Equatable, Sendable {
    case bcc
    case cc  // swiftlint:disable:this identifier_name
    case to  // swiftlint:disable:this identifier_name
  }

  enum Issue: Equatable, Sendable {
    case alreadyAdded
    case invalidAddress

    var message: String {
      switch self {
      case .alreadyAdded: "Already added"
      case .invalidAddress: "Enter a complete email address."
      }
    }
  }

  struct Token: Equatable, Identifiable, Sendable {
    let displayName: String?
    let emailAddress: String

    init(_ mailbox: RFCMailbox) {
      displayName = mailbox.displayName
      emailAddress = mailbox.emailAddress
    }

    var id: String { emailAddress.lowercased() }

    var headerValue: String {
      RFCMailbox(displayName: displayName, emailAddress: emailAddress).headerValue
    }

    var title: String {
      guard let displayName, !displayName.isEmpty else { return emailAddress }
      return "\(displayName) <\(emailAddress)>"
    }
  }

  private struct Entry: Equatable, Sendable {
    var issue: Issue?
    var pendingText: String
    var tokens: [Token]

    init(headerValue: String) {
      let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        issue = nil
        pendingText = ""
        tokens = []
        return
      }
      guard let mailboxes = RFCMailboxHeaderParser.recipientMailboxes(in: trimmed) else {
        issue = .invalidAddress
        pendingText = headerValue
        tokens = []
        return
      }
      issue = nil
      pendingText = ""
      tokens = mailboxes.map(Token.init)
    }

    var headerValue: String {
      let pendingText = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
      return (tokens.map(\.headerValue) + (pendingText.isEmpty ? [] : [pendingText]))
        .joined(separator: ", ")
    }
  }

  struct Headers: Equatable, Sendable {
    let bcc: String
    let cc: String  // swiftlint:disable:this identifier_name
    let to: String  // swiftlint:disable:this identifier_name
  }

  private var bcc: Entry
  private var cc: Entry  // swiftlint:disable:this identifier_name
  private var to: Entry  // swiftlint:disable:this identifier_name

  init(to: String, cc: String, bcc: String) {  // swiftlint:disable:this identifier_name
    self.bcc = Entry(headerValue: bcc)
    self.cc = Entry(headerValue: cc)
    self.to = Entry(headerValue: to)
  }

  var headers: Headers {
    Headers(bcc: bcc.headerValue, cc: cc.headerValue, to: to.headerValue)
  }

  var hasPopulatedOptionalRecipients: Bool {
    !cc.headerValue.isEmpty || !bcc.headerValue.isEmpty
  }

  func contains(emailAddress: String) -> Bool {
    allEmailAddresses.contains(emailAddress.lowercased())
  }

  func issue(in field: Field) -> Issue? {
    entry(for: field).issue
  }

  func pendingText(in field: Field) -> String {
    entry(for: field).pendingText
  }

  func tokens(in field: Field) -> [Token] {
    entry(for: field).tokens
  }

  mutating func updatePendingText(_ value: String, in field: Field) {
    var entry = entry(for: field)
    entry.issue = nil
    entry.pendingText = value
    setEntry(entry, for: field)
    guard Self.normalizingStructuralDelimiters(in: value).hasTrailingDelimiter else { return }
    entry.pendingText.removeLast()
    setEntry(entry, for: field)
    commitPendingText(in: field)
  }

  mutating func commitPendingText(in field: Field) {
    var entry = entry(for: field)
    let pendingText = entry.pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pendingText.isEmpty else {
      entry.issue = nil
      entry.pendingText = ""
      setEntry(entry, for: field)
      return
    }
    let normalized = Self.normalizingStructuralDelimiters(in: pendingText).value
    guard let mailboxes = RFCMailboxHeaderParser.recipientMailboxes(in: normalized) else {
      entry.issue = .invalidAddress
      setEntry(entry, for: field)
      return
    }

    var knownAddresses = allEmailAddresses
    var foundDuplicate = false
    for mailbox in mailboxes {
      let comparisonKey = mailbox.emailAddress.lowercased()
      guard knownAddresses.insert(comparisonKey).inserted else {
        foundDuplicate = true
        continue
      }
      entry.tokens.append(Token(mailbox))
    }
    entry.issue = foundDuplicate ? .alreadyAdded : nil
    entry.pendingText = ""
    setEntry(entry, for: field)
  }

  mutating func accept(_ suggestion: MailRecipientSuggestion, in field: Field) {
    var entry = entry(for: field)
    let address = suggestion.emailAddress.lowercased()
    guard !allEmailAddresses.contains(address) else {
      entry.issue = .alreadyAdded
      entry.pendingText = ""
      setEntry(entry, for: field)
      return
    }
    guard let mailbox = RFCMailboxHeaderParser.singleRecipientMailbox(in: suggestion.headerValue)
    else {
      entry.issue = .invalidAddress
      setEntry(entry, for: field)
      return
    }
    entry.issue = nil
    entry.pendingText = ""
    entry.tokens.append(Token(mailbox))
    setEntry(entry, for: field)
  }

  mutating func remove(_ token: Token, from field: Field) {
    var entry = entry(for: field)
    entry.tokens.removeAll { $0.id == token.id }
    entry.issue = nil
    setEntry(entry, for: field)
  }

  private var allEmailAddresses: Set<String> {
    Set((to.tokens + cc.tokens + bcc.tokens).map(\.id))
  }

  private static func normalizingStructuralDelimiters(
    in value: String
  ) -> (value: String, hasTrailingDelimiter: Bool) {
    var angleDepth = 0
    var commentDepth = 0
    var isEscaped = false
    var isQuoted = false
    var normalized = ""
    var trailingDelimiter = false
    for character in value {
      var isStructuralDelimiter = false
      if isEscaped {
        isEscaped = false
      } else if character == "\\", isQuoted || commentDepth > 0 {
        isEscaped = true
      } else if character == "\"", commentDepth == 0 {
        isQuoted.toggle()
      } else if !isQuoted {
        if character == "(" {
          commentDepth += 1
        } else if character == ")", commentDepth > 0 {
          commentDepth -= 1
        } else if commentDepth == 0, character == "<" {
          angleDepth += 1
        } else if commentDepth == 0, character == ">", angleDepth > 0 {
          angleDepth -= 1
        } else if commentDepth == 0, angleDepth == 0,
          character == "," || character == ";"
        {
          isStructuralDelimiter = true
        }
      }
      normalized.append(isStructuralDelimiter && character == ";" ? "," : character)
      trailingDelimiter = isStructuralDelimiter
    }
    return (normalized, trailingDelimiter)
  }

  private func entry(for field: Field) -> Entry {
    switch field {
    case .bcc: bcc
    case .cc: cc
    case .to: to
    }
  }

  private mutating func setEntry(_ entry: Entry, for field: Field) {
    switch field {
    case .bcc: bcc = entry
    case .cc: cc = entry
    case .to: to = entry
    }
  }
}

actor MailRecipientSuggestionService {
  private var contactSuggestions: [MailRecipientSuggestion]?

  func suggestions(
    matching query: String,
    messages: [MailboxMessageMetadata]
  ) async -> [MailRecipientSuggestion] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    let localSuggestions = localSuggestions(matching: query, messages: messages)
    let contacts = systemContactSuggestions(matching: query)
    return ranked(
      localSuggestions + contacts,
      matching: query
    )
  }

  private func localSuggestions(
    matching query: String,
    messages: [MailboxMessageMetadata]
  ) -> [MailRecipientSuggestion] {
    var suggestions: [MailRecipientSuggestion] = []
    for message in messages.sorted(by: {
      $0.providerInternalDateMilliseconds > $1.providerInternalDateMilliseconds
    }) {
      let isSent = message.providerStateIds?.contains("SENT") == true
      let source: MailRecipientSuggestionSource = isSent ? .recent : .correspondent
      let headers =
        isSent
        ? (message.recipientHeaders ?? []) + (message.bccRecipients ?? [])
        : [message.replyTo, message.from, message.sender].compactMap { $0 }
          + (message.replyToIdentities ?? [])
      for header in headers {
        guard let mailboxes = RFCMailboxHeaderParser.mailboxes(in: header) else { continue }
        suggestions += mailboxes.map {
          MailRecipientSuggestion(
            displayName: $0.displayName,
            emailAddress: $0.emailAddress,
            source: source
          )
        }
      }
    }
    return suggestions.filter { matches($0, query: query) }
  }

  private func ranked(
    _ suggestions: [MailRecipientSuggestion],
    matching query: String
  ) -> [MailRecipientSuggestion] {
    var bestByAddress: [String: MailRecipientSuggestion] = [:]
    for suggestion in suggestions where matches(suggestion, query: query) {
      let key = suggestion.emailAddress.lowercased()
      if let existing = bestByAddress[key], existing.source.rawValue <= suggestion.source.rawValue {
        continue
      }
      bestByAddress[key] = suggestion
    }
    return bestByAddress.values.sorted { lhs, rhs in
      if lhs.source.rawValue != rhs.source.rawValue {
        return lhs.source.rawValue < rhs.source.rawValue
      }
      let lhsPrefix = lhs.emailAddress.localizedStandardContains(query) ? 0 : 1
      let rhsPrefix = rhs.emailAddress.localizedStandardContains(query) ? 0 : 1
      if lhsPrefix != rhsPrefix { return lhsPrefix < rhsPrefix }
      return lhs.emailAddress.localizedCaseInsensitiveCompare(rhs.emailAddress) == .orderedAscending
    }
    .prefix(8)
    .map { $0 }
  }

  private func matches(_ suggestion: MailRecipientSuggestion, query: String) -> Bool {
    suggestion.emailAddress.localizedStandardContains(query)
      || suggestion.displayName?.localizedStandardContains(query) == true
  }

  private func systemContactSuggestions(
    matching query: String
  ) -> [MailRecipientSuggestion] {
    #if canImport(Contacts)
      let authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
      guard authorizationStatus == .authorized || authorizationStatus == .limited else {
        contactSuggestions = nil
        return []
      }
      if let contactSuggestions {
        return contactSuggestions.filter { matches($0, query: query) }
      }
      let store = CNContactStore()
      let request = CNContactFetchRequest(keysToFetch: [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
      ])
      var suggestions: [MailRecipientSuggestion] = []
      do {
        try store.enumerateContacts(with: request) { contact, stop in
          guard !Task.isCancelled else {
            stop.pointee = true
            return
          }
          var name = PersonNameComponents()
          name.givenName = contact.givenName
          name.familyName = contact.familyName
          let displayName = name.formatted().trimmingCharacters(in: .whitespacesAndNewlines)
          for email in contact.emailAddresses {
            guard let mailbox = RFCMailboxHeaderParser.singleMailbox(in: String(email.value)) else {
              continue
            }
            suggestions.append(
              MailRecipientSuggestion(
                displayName: displayName.isEmpty ? nil : displayName,
                emailAddress: mailbox.emailAddress,
                source: .contact
              )
            )
          }
        }
      } catch {
        return []
      }
      guard !Task.isCancelled else { return [] }
      contactSuggestions = suggestions
      return suggestions.filter { matches($0, query: query) }
    #else
      return []
    #endif
  }
}
