import CryptoKit
import Foundation

/// The kind of source-linked fact presented by Understanding Assistance.
enum UnderstandingAssistanceItemKind: String, Codable, CaseIterable, Equatable, Sendable {
  case action
  case inferredDate
  case openQuestion
  case statedDate
  case statedDeadline
  case summary
}

/// One source-linked statement produced by Understanding Assistance.
struct UnderstandingAssistanceItem: Codable, Equatable, Identifiable, Sendable {
  let kind: UnderstandingAssistanceItemKind
  let responsiblePerson: String?
  let sourceMessageIds: [String]
  let text: String
  let uncertainty: String?

  var id: String {
    ([kind.rawValue, text, responsiblePerson ?? "", uncertainty ?? ""] + sourceMessageIds)
      .joined(separator: "\u{1F}")
  }

  var responsibilityDescription: String {
    responsiblePerson ?? "Not stated"
  }
}

/// One local message, or local message prefix, admitted to an understanding request.
struct UnderstandingAssistanceSource: Codable, Equatable, Identifiable, Sendable {
  let availableCharacterCount: Int
  let includedCharacterCount: Int
  let messageId: String
  let senderDisplayName: String?
  let sentAtMilliseconds: Int64

  var id: String { messageId }
  var isTruncated: Bool { includedCharacterCount < availableCharacterCount }

  var accessibilityLabel: String {
    guard let senderDisplayName, !senderDisplayName.isEmpty else {
      return "Open source message"
    }
    return "Open source message from \(senderDisplayName)"
  }
}

/// The exact local portion of a Thread admitted to an understanding request.
struct UnderstandingAssistanceScope: Codable, Equatable, Sendable {
  let includedSources: [UnderstandingAssistanceSource]
  let locallyAvailableMessageCount: Int
  let omittedForLimitMessageCount: Int
  let unavailableLocalMessageCount: Int
  let totalThreadMessageCount: Int

  var hasOmittedContent: Bool {
    unavailableLocalMessageCount > 0
      || omittedForLimitMessageCount > 0
      || includedSources.contains(where: \UnderstandingAssistanceSource.isTruncated)
  }
}

/// A validated, source-linked Understanding Assistance result and its local input scope.
struct UnderstandingAssistanceResult: Equatable, Sendable {
  let items: [UnderstandingAssistanceItem]
  let scope: UnderstandingAssistanceScope

  static func validated(
    items: [UnderstandingAssistanceItem],
    scope: UnderstandingAssistanceScope
  ) throws -> Self {
    let admittedMessageIds = Set(scope.includedSources.map(\.messageId))
    guard !items.isEmpty, items.contains(where: { $0.kind == .summary }) else {
      throw MailAssistanceError.guardrailViolation
    }
    guard
      items.allSatisfy({ item in
        !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !item.sourceMessageIds.isEmpty
          && Set(item.sourceMessageIds).isSubset(of: admittedMessageIds)
          && (item.kind == .action || item.responsiblePerson == nil)
      })
    else {
      throw MailAssistanceError.guardrailViolation
    }
    var seenItemIds: Set<String> = []
    let uniqueItems = items.filter { seenItemIds.insert($0.id).inserted }
    return UnderstandingAssistanceResult(items: uniqueItems, scope: scope)
  }
}

extension MailAssistancePreview {
  static func understanding(
    items: [UnderstandingAssistanceItem],
    scope: UnderstandingAssistanceScope,
    request: MailAssistanceRequest
  ) throws -> Self {
    let result = try UnderstandingAssistanceResult.validated(items: items, scope: scope)
    guard let summary = result.items.first(where: { $0.kind == .summary }) else {
      throw MailAssistanceError.guardrailViolation
    }
    return Self(
      content: summary.text,
      inputVersion: request.context.inputVersion,
      kind: .content,
      profileId: request.context.profileId,
      understanding: result
    )
  }
}

/// Failures that prevent an already-local Thread from becoming an assistance request.
enum UnderstandingAssistancePreparationError: LocalizedError, Equatable {
  case localTextExceedsDeterministicLimit
  case noLocalMessageText

  var errorDescription: String? {
    switch self {
    case .localTextExceedsDeterministicLimit:
      "This Thread’s local text exceeds the on-device analysis limit. "
        + "Open a shorter Thread and try again."
    case .noLocalMessageText:
      "Open at least one message before asking for Understanding Assistance. Missing bodies are not fetched."
    }
  }
}

/// Builds deterministic, newest-first Understanding Assistance requests from local text only.
struct UnderstandingAssistanceRequestBuilder {
  let limits: MailAssistanceContextLimits

  init(limits: MailAssistanceContextLimits = .standard) {
    self.limits = limits
  }

  func makeRequest(
    for thread: MailboxThread,
    profileId: MailProfileId,
    localeIdentifier: String,
    localBodyText: (StableProviderMessageIdentity) -> String?
  ) throws -> MailAssistanceRequest {
    let localMessages = localMessages(in: thread, localBodyText: localBodyText)
    guard !localMessages.isEmpty else {
      throw UnderstandingAssistancePreparationError.noLocalMessageText
    }
    let admitted = admittedSources(from: localMessages)
    let sourceMessages = admitted.messages
    guard !sourceMessages.isEmpty else {
      throw UnderstandingAssistancePreparationError.localTextExceedsDeterministicLimit
    }
    let scope = UnderstandingAssistanceScope(
      includedSources: admitted.sources,
      locallyAvailableMessageCount: localMessages.count,
      omittedForLimitMessageCount: localMessages.count - admitted.sources.count,
      unavailableLocalMessageCount: thread.messages.count - localMessages.count,
      totalThreadMessageCount: thread.messages.count
    )
    let revision = Self.threadRevision(for: thread, localBodyText: localBodyText)
    return MailAssistanceRequest(
      context: MailAssistanceContext(
        draft: nil,
        inputVersion: MailAssistanceInputVersion(
          draftRevision: "not-applicable",
          selectionRevision: "not-applicable",
          threadRevision: revision
        ),
        profileId: profileId,
        recipientDisplayNames: [],
        sourceMessages: sourceMessages,
        understandingScope: scope
      ),
      localeIdentifier: localeIdentifier,
      operation: .understand
    )
  }

  private func localMessages(
    in thread: MailboxThread,
    localBodyText: (StableProviderMessageIdentity) -> String?
  ) -> [LocalMessage] {
    thread.messages.compactMap { message in
      guard let body = localBodyText(message.id), !body.isEmpty else { return nil }
      return LocalMessage(body: body, message: message)
    }
  }

  private func admittedSources(
    from localMessages: [LocalMessage]
  ) -> (messages: [MailAssistanceSourceMessage], sources: [UnderstandingAssistanceSource]) {
    var messages: [MailAssistanceSourceMessage] = []
    var sources: [UnderstandingAssistanceSource] = []
    var characterCount = 0

    for localMessage in localMessages {
      guard messages.count < limits.maximumSourceMessageCount else { break }
      let message = localMessage.message
      let metadataCharacterCount = [
        message.id.rawValue,
        message.sender ?? message.from ?? "",
        message.subject,
        String(message.providerInternalDateMilliseconds),
      ].reduce(0) { $0 + $1.count }
      let remainingCount = limits.maximumCharacterCount - characterCount - metadataCharacterCount
      guard remainingCount > 0 else { break }
      let admittedBody = String(localMessage.body.prefix(remainingCount))
      let sourceMessage = MailAssistanceSourceMessage(
        body: admittedBody,
        senderDisplayName: message.sender ?? message.from,
        sentAtMilliseconds: message.providerInternalDateMilliseconds,
        sourceMessageId: message.id.rawValue,
        subject: message.subject
      )
      messages.append(sourceMessage)
      sources.append(source(for: localMessage, includedCharacterCount: admittedBody.count))
      characterCount += sourceMessage.characterCount
      if admittedBody.count < localMessage.body.count { break }
    }
    return (messages, sources)
  }

  private func source(
    for localMessage: LocalMessage,
    includedCharacterCount: Int
  ) -> UnderstandingAssistanceSource {
    UnderstandingAssistanceSource(
      availableCharacterCount: localMessage.body.count,
      includedCharacterCount: includedCharacterCount,
      messageId: localMessage.message.id.rawValue,
      senderDisplayName: localMessage.message.sender ?? localMessage.message.from,
      sentAtMilliseconds: localMessage.message.providerInternalDateMilliseconds
    )
  }

  static func inputVersion(
    for thread: MailboxThread,
    localBodyText: (StableProviderMessageIdentity) -> String?
  ) -> MailAssistanceInputVersion {
    MailAssistanceInputVersion(
      draftRevision: "not-applicable",
      selectionRevision: "not-applicable",
      threadRevision: threadRevision(for: thread, localBodyText: localBodyText)
    )
  }

  private static func threadRevision(
    for thread: MailboxThread,
    localBodyText: (StableProviderMessageIdentity) -> String?
  ) -> String {
    var input = Data()
    for message in thread.messages {
      for component in [
        message.id.rawValue,
        String(message.providerInternalDateMilliseconds),
        message.subject,
        message.sender ?? message.from ?? "",
        localBodyText(message.id) ?? "<body-not-local>",
      ] {
        input.append(contentsOf: component.utf8)
        input.append(0)
      }
    }
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
  }

  private struct LocalMessage {
    let body: String
    let message: MailboxMessageMetadata
  }
}
