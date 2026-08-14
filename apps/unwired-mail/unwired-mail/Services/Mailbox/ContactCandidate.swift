import Contacts
import CryptoKit
import Foundation

enum ContactCandidateEvidence: String, Equatable, Sendable {
  case repeatedCorrespondence
  case reply
}

struct ContactCandidate: Equatable, Sendable {
  let displayName: String
  let emailAddress: String
  let evidence: ContactCandidateEvidence
  let organizationName: String?
  let phoneNumber: String?
  let postalAddress: String?
  let urlString: String?

  var opaqueDismissalIdentifier: String {
    let values = [
      Self.canonicalText(displayName),
      emailAddress,
      evidence.rawValue,
    ]
    return SHA256.hash(data: Data(values.joined(separator: "\u{1f}").utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func canonicalText(_ value: String) -> String {
    value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ").lowercased()
  }
}

enum ContactCandidateDetector {
  private struct MailboxIdentity: Equatable {
    let displayName: String
    let emailAddress: String
  }

  private struct SignatureFields {
    let organizationName: String?
    let phoneNumber: String?
    let postalAddress: String?
    let urlString: String?
  }

  private static let maximumHeaderByteCount = 16 * 1_024
  private static let maximumSignatureByteCount = 4 * 1_024
  private static let peopleCategoryId = "system:people"
  private static let automatedMailboxFragments = [
    "do-not-reply", "donotreply", "mailer-daemon", "no-reply", "noreply", "postmaster",
  ]

  static func candidate(
    for message: MailboxMessageMetadata,
    threadMessages: [MailboxMessageMetadata],
    mailboxAddress: String,
    cachedBodyText: String?
  ) -> ContactCandidate? {
    guard let sender = qualifyingIncomingSender(message, mailboxAddress: mailboxAddress) else {
      return nil
    }

    let scopedMessages = threadMessages.filter {
      $0.connectionId == message.connectionId && $0.providerThreadId == message.providerThreadId
    }
    let evidence: ContactCandidateEvidence
    if scopedMessages.contains(where: { $0.belongs(to: .sent) }) {
      evidence = .reply
    } else {
      let matchingIncomingCount = scopedMessages.count { threadMessage in
        qualifyingIncomingSender(threadMessage, mailboxAddress: mailboxAddress)?.emailAddress
          == sender.emailAddress
      }
      guard matchingIncomingCount >= 2 else { return nil }
      evidence = .repeatedCorrespondence
    }
    guard
      scopedMessages.first(where: {
        qualifyingIncomingSender($0, mailboxAddress: mailboxAddress)?.emailAddress
          == sender.emailAddress
      })?.id == message.id
    else { return nil }

    let signatureFields =
      cachedBodyText.flatMap(signatureFields)
      ?? SignatureFields(
        organizationName: nil,
        phoneNumber: nil,
        postalAddress: nil,
        urlString: nil
      )
    return ContactCandidate(
      displayName: sender.displayName,
      emailAddress: sender.emailAddress,
      evidence: evidence,
      organizationName: signatureFields.organizationName,
      phoneNumber: signatureFields.phoneNumber,
      postalAddress: signatureFields.postalAddress,
      urlString: signatureFields.urlString
    )
  }

  private static func qualifyingIncomingSender(
    _ message: MailboxMessageMetadata,
    mailboxAddress: String
  ) -> MailboxIdentity? {
    guard
      [.exchangeWebServices, .gmail].contains(message.connectionId.providerId),
      !message.belongs(to: .sent),
      message.messageCategoryIds.contains(peopleCategoryId),
      message.unsubscribeSuggestion == nil,
      let sender = mailboxIdentity(message.from),
      !isAutomated(sender.emailAddress),
      isDirectMessage(message, mailboxAddress: mailboxAddress)
    else { return nil }

    if message.connectionId.providerId == .exchangeWebServices {
      guard
        let providerSender = message.sender.flatMap(singleEmailAddress),
        providerSender == sender.emailAddress
      else { return nil }
      if let organizer = message.organizer {
        guard singleEmailAddress(organizer) == sender.emailAddress else { return nil }
      }
    }

    let replyToIdentities =
      message.connectionId.providerId == .exchangeWebServices
      ? message.replyToIdentities ?? [message.replyTo].compactMap { $0 }
      : [message.replyTo].compactMap { $0 }
    guard replyToIdentities.count <= 1 else { return nil }
    if let replyTo = replyToIdentities.first?.trimmingCharacters(in: .whitespacesAndNewlines),
      !replyTo.isEmpty,
      singleEmailAddress(replyTo) != sender.emailAddress
    {
      return nil
    }
    return sender
  }

  private static func isDirectMessage(
    _ message: MailboxMessageMetadata,
    mailboxAddress: String
  ) -> Bool {
    guard let ownAddress = singleEmailAddress(mailboxAddress) else { return false }
    let recipients = Set((message.recipientHeaders ?? []).flatMap(emailAddresses))
    return recipients == [ownAddress]
  }

  private static func isAutomated(_ emailAddress: String) -> Bool {
    guard let localPart = emailAddress.split(separator: "@", maxSplits: 1).first else {
      return true
    }
    let normalized = localPart.lowercased()
    return automatedMailboxFragments.contains { normalized.contains($0) }
  }

  private static func mailboxIdentity(_ value: String?) -> MailboxIdentity? {
    guard let value else { return nil }
    let unfolded = value.replacingOccurrences(
      of: #"\r?\n[\t ]+"#,
      with: " ",
      options: .regularExpression
    )
    guard
      unfolded.utf8.count <= maximumHeaderByteCount,
      !unfolded.contains("\r"),
      !unfolded.contains("\n")
    else { return nil }
    guard let emailAddress = singleEmailAddress(unfolded) else { return nil }
    let displayName =
      unfolded
      .replacingOccurrences(of: #"<[^<>]+>"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: emailAddress, with: "", options: [.caseInsensitive])
      .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
    guard !displayName.isEmpty, displayName.caseInsensitiveCompare(emailAddress) != .orderedSame
    else { return nil }
    return MailboxIdentity(displayName: displayName, emailAddress: emailAddress)
  }

  private static func emailAddresses(_ value: String) -> [String] {
    let pattern =
      #"(?i)[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
      + #"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard let range = Range(match.range, in: value) else { return nil }
      return String(value[range]).lowercased()
    }
  }

  private static func singleEmailAddress(_ value: String) -> String? {
    let addresses = emailAddresses(value)
    guard addresses.count == 1 else { return nil }
    return addresses[0]
  }

  private static func signatureFields(_ bodyText: String) -> SignatureFields? {
    let markers = ["\n-- \n", "\n--\n"]
    let utf8 = bodyText.utf8
    var scanStart = utf8.index(
      utf8.endIndex,
      offsetBy: -min(utf8.count, maximumSignatureByteCount + 5)
    )
    while String.Index(scanStart, within: bodyText) == nil {
      scanStart = utf8.index(after: scanStart)
    }
    guard let scanStart = String.Index(scanStart, within: bodyText) else { return nil }
    let scanText = String(bodyText[scanStart...])
    guard
      let boundary = markers.compactMap({ scanText.range(of: $0, options: .backwards) }).max(
        by: { $0.lowerBound < $1.lowerBound }
      )
    else { return nil }
    let signature = String(scanText[boundary.upperBound...])
    guard !signature.isEmpty, signature.utf8.count <= maximumSignatureByteCount else { return nil }
    let lines = signature.split(whereSeparator: \Character.isNewline).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }

    return SignatureFields(
      organizationName: labeledValue(in: lines, labels: ["company", "organization"]),
      phoneNumber: firstMatch(
        in: signature,
        pattern: #"(?<![A-Za-z0-9])(?:\+?\d[\d .()/-]{6,}\d)"#
      ),
      postalAddress: labeledValue(in: lines, labels: ["address"]),
      urlString: firstMatch(
        in: signature,
        pattern: #"(?i)https://[^\s<>]+"#
      )
    )
  }

  private static func labeledValue(in lines: [String], labels: [String]) -> String? {
    for line in lines {
      for label in labels {
        let prefix = label + ":"
        guard line.lowercased().hasPrefix(prefix) else { continue }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.count <= 160 { return value }
      }
    }
    return nil
  }

  private static func firstMatch(in value: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range),
      let matchRange = Range(match.range, in: value)
    else { return nil }
    return String(value[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct ContactReview: Equatable, Identifiable, Sendable {
  let candidate: ContactCandidate
  let matchingContactCount: Int
  let id = UUID()
}

enum ContactReviewError: LocalizedError, Equatable {
  case contactsAccessDenied

  var errorDescription: String? {
    switch self {
    case .contactsAccessDenied:
      "Allow Contacts access in Settings to review this candidate."
    }
  }
}

@MainActor
final class ContactReviewService {
  typealias MatchingContactCount = (ContactCandidate) throws -> Int
  typealias RequestAccess = () async throws -> Bool

  private let matchingContactCount: MatchingContactCount
  private let requestAccess: RequestAccess

  init() {
    let contactStore = CNContactStore()
    requestAccess = {
      switch CNContactStore.authorizationStatus(for: .contacts) {
      case .authorized, .limited:
        true
      case .notDetermined:
        try await contactStore.requestAccess(for: .contacts)
      case .denied, .restricted:
        false
      @unknown default:
        false
      }
    }
    matchingContactCount = { candidate in
      var identifiers: Set<String> = []
      let keys = [CNContactIdentifierKey as CNKeyDescriptor]
      let emailMatches = try contactStore.unifiedContacts(
        matching: CNContact.predicateForContacts(matchingEmailAddress: candidate.emailAddress),
        keysToFetch: keys
      )
      identifiers.formUnion(emailMatches.map(\.identifier))
      if let phoneNumber = candidate.phoneNumber {
        let phoneMatches = try contactStore.unifiedContacts(
          matching: CNContact.predicateForContacts(
            matching: CNPhoneNumber(stringValue: phoneNumber)),
          keysToFetch: keys
        )
        identifiers.formUnion(phoneMatches.map(\.identifier))
      }
      return identifiers.count
    }
  }

  init(
    requestAccess: @escaping RequestAccess,
    matchingContactCount: @escaping MatchingContactCount
  ) {
    self.requestAccess = requestAccess
    self.matchingContactCount = matchingContactCount
  }

  func prepare(_ candidate: ContactCandidate) async throws -> ContactReview {
    guard try await requestAccess() else { throw ContactReviewError.contactsAccessDenied }
    try Task.checkCancellation()
    return try ContactReview(
      candidate: candidate,
      matchingContactCount: matchingContactCount(candidate)
    )
  }
}
