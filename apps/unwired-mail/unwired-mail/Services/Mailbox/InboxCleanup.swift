import CryptoKit
import Foundation
import Observation

enum InboxCleanupScope: Equatable, Hashable, Sendable {
  case connection(MailboxConnectionId)
  case unified

  init?(mailboxSelection: MailShellMailboxSelection?) {
    switch mailboxSelection {
    case .connection(let connectionId, .role(.inbox)):
      self = .connection(connectionId)
    case .unified(.inbox):
      self = .unified
    default:
      return nil
    }
  }

  var preferenceIdentifier: String {
    switch self {
    case .connection(let connectionId):
      let digest = SHA256.hash(data: Data(connectionId.rawValue.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
      return "connection:\(digest)"
    case .unified:
      "unified"
    }
  }
}

struct InboxCleanupCandidate: Equatable, Identifiable, Sendable {
  let message: MailboxMessageMetadata
  let normalizedSenderAddress: String?

  var id: StableProviderMessageIdentity { message.id }
  var threadId: MailboxThreadIdentity { message.threadIdentity }
}

struct InboxCleanupCandidateGroup: Equatable, Identifiable, Sendable {
  let candidates: [InboxCleanupCandidate]
  let id: MailboxThreadIdentity

  var title: String {
    candidates.first?.message.from ?? candidates.first?.message.subject ?? "Messages"
  }
}

struct InboxCleanupProposal: Equatable, Identifiable, Sendable {
  let candidates: [InboxCleanupCandidate]
  let eligibleCandidateCount: Int
  let scope: InboxCleanupScope

  init(
    candidates: [InboxCleanupCandidate],
    scope: InboxCleanupScope,
    eligibleCandidateCount: Int? = nil
  ) {
    self.candidates = candidates
    self.eligibleCandidateCount = eligibleCandidateCount ?? candidates.count
    self.scope = scope
  }

  var id: String {
    scope.preferenceIdentifier + ":" + candidates.map(\.id.rawValue).joined(separator: "|")
  }

  var groups: [InboxCleanupCandidateGroup] {
    Dictionary(grouping: candidates, by: \.threadId)
      .map { threadId, candidates in
        InboxCleanupCandidateGroup(candidates: candidates, id: threadId)
      }
      .sorted { first, second in
        let firstDate = first.candidates.map(\.message.providerInternalDateMilliseconds).min() ?? 0
        let secondDate =
          second.candidates.map(\.message.providerInternalDateMilliseconds).min() ?? 0
        if firstDate != secondDate { return firstDate < secondDate }
        return first.id.rawValue < second.id.rawValue
      }
  }
}

struct InboxCleanupRevalidation: Equatable, Sendable {
  let eligibleCandidates: [InboxCleanupCandidate]
  let skippedMessageIds: Set<StableProviderMessageIdentity>
}

@MainActor
@Observable
final class InboxCleanupReviewModel: Identifiable {
  let id = UUID()
  let proposal: InboxCleanupProposal
  private(set) var candidates: [InboxCleanupCandidate]
  private(set) var groups: [InboxCleanupCandidateGroup]
  private(set) var selectedMessageIds: Set<StableProviderMessageIdentity>
  private(set) var skippedMessageIds: Set<StableProviderMessageIdentity> = []
  var isPerforming = false

  init(proposal: InboxCleanupProposal) {
    self.proposal = proposal
    candidates = proposal.candidates
    groups = proposal.groups
    selectedMessageIds = Set(proposal.candidates.map(\.id))
  }

  var selectedCandidates: [InboxCleanupCandidate] {
    candidates.filter { selectedMessageIds.contains($0.id) }
  }

  func isSelected(_ candidate: InboxCleanupCandidate) -> Bool {
    selectedMessageIds.contains(candidate.id)
  }

  func toggle(_ candidate: InboxCleanupCandidate) {
    if selectedMessageIds.contains(candidate.id) {
      selectedMessageIds.remove(candidate.id)
    } else {
      selectedMessageIds.insert(candidate.id)
    }
    skippedMessageIds.remove(candidate.id)
  }

  func setSelected(_ selected: Bool, group: InboxCleanupCandidateGroup) {
    let messageIds = Set(group.candidates.map(\.id))
    if selected {
      selectedMessageIds.formUnion(messageIds)
    } else {
      selectedMessageIds.subtract(messageIds)
    }
    skippedMessageIds.subtract(messageIds)
  }

  func apply(_ revalidation: InboxCleanupRevalidation) {
    candidates = revalidation.eligibleCandidates
    groups = InboxCleanupProposal(
      candidates: revalidation.eligibleCandidates,
      scope: proposal.scope
    ).groups
    selectedMessageIds = Set(revalidation.eligibleCandidates.map(\.id))
    skippedMessageIds = revalidation.skippedMessageIds
  }
}

enum InboxCleanupDetector {
  static let maximumProposalMessageCount = 500
  private static let minimumCandidateCount = 50
  private static let minimumSenderCandidateCount = 10
  private static let promotionsCategoryId = "system:promotions"
  private static let excludedCategoryIds: Set<String> = [
    "system:people", "system:invites", "system:invoices", "system:flights",
  ]
  private static let maximumHeaderByteCount = 16 * 1_024
  private static let minimumAgeMilliseconds: Int64 = 90 * 24 * 60 * 60 * 1_000
  private static let senderAddressExpression: NSRegularExpression? = {
    let pattern =
      #"(?i)[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
      + #"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+"#
    return try? NSRegularExpression(pattern: pattern)
  }()

  static func proposal(
    messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]],
    connections: [MailboxConnection],
    pinnedThreadIds: Set<StableThreadIdentity>,
    scope: InboxCleanupScope,
    now: Date = .now
  ) -> InboxCleanupProposal? {
    let candidates = candidates(
      messagesByConnection: messagesByConnection,
      connections: connections,
      pinnedThreadIds: pinnedThreadIds,
      scope: scope,
      now: now
    )
    let senderCounts = candidates.reduce(into: [String: Int]()) { counts, candidate in
      guard let normalizedSenderAddress = candidate.normalizedSenderAddress else { return }
      counts[normalizedSenderAddress, default: 0] += 1
    }
    guard
      candidates.count >= minimumCandidateCount
        || senderCounts.values.contains(where: { $0 >= minimumSenderCandidateCount })
    else { return nil }
    return InboxCleanupProposal(
      candidates: Array(candidates.prefix(maximumProposalMessageCount)),
      scope: scope,
      eligibleCandidateCount: candidates.count
    )
  }

  static func revalidate(
    _ selectedMessageIds: Set<StableProviderMessageIdentity>,
    messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]],
    connections: [MailboxConnection],
    pinnedThreadIds: Set<StableThreadIdentity>,
    scope: InboxCleanupScope,
    now: Date = .now
  ) -> InboxCleanupRevalidation {
    let currentCandidates = candidates(
      messagesByConnection: messagesByConnection,
      connections: connections,
      pinnedThreadIds: pinnedThreadIds,
      scope: scope,
      now: now
    )
    let candidatesById = Dictionary(uniqueKeysWithValues: currentCandidates.map { ($0.id, $0) })
    let eligibleCandidates = selectedMessageIds.compactMap { candidatesById[$0] }.sorted(
      by: ordersBefore
    )
    return InboxCleanupRevalidation(
      eligibleCandidates: eligibleCandidates,
      skippedMessageIds: selectedMessageIds.subtracting(eligibleCandidates.map(\.id))
    )
  }

  private static func candidates(
    messagesByConnection: [MailboxConnectionId: [MailboxMessageMetadata]],
    connections: [MailboxConnection],
    pinnedThreadIds: Set<StableThreadIdentity>,
    scope: InboxCleanupScope,
    now: Date
  ) -> [InboxCleanupCandidate] {
    let selectedConnections = connections.filter { connection in
      guard
        connection.providerId == .gmail,
        connection.authorizationState == .authorized,
        connection.capabilities.supports(.delete)
      else { return false }
      switch scope {
      case .connection(let connectionId):
        return connection.id == connectionId
      case .unified:
        return true
      }
    }
    let selectedConnectionIds = Set(selectedConnections.map(\.id))
    let messages = selectedConnectionIds.flatMap { messagesByConnection[$0] ?? [] }
    let messagesByThread = Dictionary(grouping: messages, by: \.threadIdentity)
    let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
    let cutoffMilliseconds = nowMilliseconds - minimumAgeMilliseconds
    return messages.compactMap { message in
      guard
        message.belongs(to: .inbox),
        message.isUnread == false,
        message.providerInternalDateMilliseconds < cutoffMilliseconds,
        message.messageCategoryIds.contains(promotionsCategoryId),
        Set(message.messageCategoryIds).isDisjoint(with: excludedCategoryIds),
        message.belongs(to: .spam) == false,
        message.belongs(to: .trash) == false,
        pinnedThreadIds.contains(message.threadIdentity) == false,
        messagesByThread[message.threadIdentity]?.contains(where: { $0.belongs(to: .sent) })
          == false
      else { return nil }
      return InboxCleanupCandidate(
        message: message,
        normalizedSenderAddress: normalizedSenderAddress(
          message.from,
          providerId: message.connectionId.providerId
        )
      )
    }
    .sorted(by: ordersBefore)
  }

  private static func ordersBefore(
    _ first: InboxCleanupCandidate,
    _ second: InboxCleanupCandidate
  ) -> Bool {
    if first.message.providerInternalDateMilliseconds
      != second.message.providerInternalDateMilliseconds
    {
      return first.message.providerInternalDateMilliseconds
        < second.message.providerInternalDateMilliseconds
    }
    return first.id.rawValue < second.id.rawValue
  }

  private static func normalizedSenderAddress(
    _ header: String?,
    providerId: MailProviderId
  ) -> String? {
    guard let header, header.utf8.count <= maximumHeaderByteCount else { return nil }
    let withoutComments = removingComments(from: header)
    let mailbox = mailboxAddress(in: withoutComments)
    guard let expression = senderAddressExpression else { return nil }
    let range = NSRange(mailbox.startIndex..<mailbox.endIndex, in: mailbox)
    let matches = expression.matches(in: mailbox, range: range)
    guard matches.count == 1,
      let matchRange = Range(matches[0].range, in: mailbox)
    else { return nil }
    let address = String(mailbox[matchRange])
    guard let separator = address.lastIndex(of: "@") else { return nil }
    let localPart = String(address[..<separator])
    let domain = String(address[address.index(after: separator)...]).lowercased()
    let normalizedLocalPart = providerId == .gmail ? localPart.lowercased() : localPart
    return "\(providerId.rawValue):\(normalizedLocalPart)@\(domain)"
  }

  private static func mailboxAddress(in value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let opening = trimmed.lastIndex(of: "<"),
      let closing = trimmed.lastIndex(of: ">"),
      opening < closing
    else { return trimmed }
    return String(trimmed[trimmed.index(after: opening)..<closing])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func removingComments(from value: String) -> String {
    var result = ""
    var commentDepth = 0
    var isEscaped = false
    var isQuoted = false
    for character in value {
      if isEscaped {
        if commentDepth == 0 { result.append(character) }
        isEscaped = false
        continue
      }
      if character == "\\" {
        if commentDepth == 0 { result.append(character) }
        isEscaped = true
      } else if character == "\"", commentDepth == 0 {
        isQuoted.toggle()
        result.append(character)
      } else if character == "(", isQuoted == false {
        commentDepth += 1
      } else if character == ")", isQuoted == false, commentDepth > 0 {
        commentDepth -= 1
      } else if commentDepth == 0 {
        result.append(character)
      }
    }
    return result
  }
}
