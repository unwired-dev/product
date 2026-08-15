import Foundation

#if canImport(Contacts)
  import Contacts
#endif

enum MailRecipientSuggestionSource: Int, Codable, Equatable, Sendable {
  case recent = 0
  case correspondent = 1
  case contact = 2
  case providerDirectory = 3
}

struct MailRecipientSuggestion: Equatable, Identifiable, Sendable {
  let displayName: String?
  let emailAddress: String
  let source: MailRecipientSuggestionSource

  var id: String { emailAddress.lowercased() }

  var headerValue: String {
    guard let displayName, !displayName.isEmpty else { return emailAddress }
    let escapedName = displayName.replacing("\"", with: "\\\"")
    return "\"\(escapedName)\" <\(emailAddress)>"
  }
}

protocol MailProviderDirectorySearching: Sendable {
  func suggestions(matching query: String) async -> [MailRecipientSuggestion]
}

struct EmptyMailProviderDirectory: MailProviderDirectorySearching {
  func suggestions(matching _: String) async -> [MailRecipientSuggestion] { [] }
}

actor MailRecipientSuggestionService {
  private let providerDirectory: any MailProviderDirectorySearching

  init(
    providerDirectory: any MailProviderDirectorySearching = EmptyMailProviderDirectory()
  ) {
    self.providerDirectory = providerDirectory
  }

  func suggestions(
    matching query: String,
    messages: [MailboxMessageMetadata]
  ) async -> [MailRecipientSuggestion] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    async let providerSuggestions = providerDirectory.suggestions(matching: query)
    async let contactSuggestions = systemContactSuggestions(matching: query)
    let localSuggestions = localSuggestions(matching: query, messages: messages)
    let (contacts, provider) = await (contactSuggestions, providerSuggestions)
    return ranked(
      localSuggestions + contacts + provider,
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
      guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
      let store = CNContactStore()
      let request = CNContactFetchRequest(keysToFetch: [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
      ])
      var suggestions: [MailRecipientSuggestion] = []
      try? store.enumerateContacts(with: request) { contact, _ in
        var name = PersonNameComponents()
        name.givenName = contact.givenName
        name.familyName = contact.familyName
        let displayName = name.formatted().trimmingCharacters(in: .whitespacesAndNewlines)
        for email in contact.emailAddresses {
          let address = String(email.value)
          let suggestion = MailRecipientSuggestion(
            displayName: displayName.isEmpty ? nil : displayName,
            emailAddress: address,
            source: .contact
          )
          if matches(suggestion, query: query) {
            suggestions.append(suggestion)
          }
        }
      }
      return suggestions
    #else
      return []
    #endif
  }
}
