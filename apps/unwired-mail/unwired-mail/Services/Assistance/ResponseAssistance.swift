import CryptoKit
import Foundation

/// One deliberate reply direction offered by Response Assistance.
struct ResponseAssistanceSuggestion: Equatable, Identifiable, Sendable {
  let document: SemanticMessageDocument
  let intent: String

  var id: String {
    [intent, document.plainText]
      .map { "\($0.utf8.count):\($0)" }
      .joined()
  }
}

/// The kind of source request evaluated by the answer-completeness check.
enum ResponseAssistanceCompletenessKind: String, Codable, Equatable, Sendable {
  case question
  case request
}

/// Whether the authored Draft addresses one explicit source question or request.
enum ResponseAssistanceCompletenessStatus: String, Codable, Equatable, Sendable {
  case addressed
  case unresolved
}

/// One read-only, source-linked answer-completeness finding.
struct ResponseAssistanceCompletenessItem: Equatable, Identifiable, Sendable {
  let kind: ResponseAssistanceCompletenessKind
  let sourceMessageIds: [String]
  let status: ResponseAssistanceCompletenessStatus
  let text: String

  var id: String {
    ([kind.rawValue, status.rawValue, text] + sourceMessageIds)
      .map { "\($0.utf8.count):\($0)" }
      .joined()
  }
}

/// Metadata for one already-local source message admitted to Response Assistance.
struct ResponseAssistanceSource: Codable, Equatable, Identifiable, Sendable {
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

/// The exact local portion of a Thread admitted to one response request.
struct ResponseAssistanceScope: Codable, Equatable, Sendable {
  let includedSources: [ResponseAssistanceSource]
  let locallyAvailableMessageCount: Int
  let omittedForLimitMessageCount: Int
  let unavailableLocalMessageCount: Int
  let totalThreadMessageCount: Int

  var hasOmittedContent: Bool {
    unavailableLocalMessageCount > 0
      || omittedForLimitMessageCount > 0
      || includedSources.contains(where: \ResponseAssistanceSource.isTruncated)
  }
}

/// A validated set of reply options and a read-only answer-completeness check.
struct ResponseAssistanceResult: Equatable, Sendable {
  let completenessItems: [ResponseAssistanceCompletenessItem]
  let fullReply: SemanticMessageDocument
  let scope: ResponseAssistanceScope
  let suggestions: [ResponseAssistanceSuggestion]

  static func validated(
    suggestions: [ResponseAssistanceSuggestion],
    fullReply: SemanticMessageDocument,
    completenessItems: [ResponseAssistanceCompletenessItem],
    scope: ResponseAssistanceScope
  ) throws -> Self {
    let admittedMessageIds = Set(scope.includedSources.map(\.messageId))
    let normalizedIntents = Set(
      suggestions.map { $0.intent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    )
    let normalizedReplies = Set(
      suggestions.map {
        $0.document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }
    )
    guard suggestions.count == 3,
      normalizedIntents.count == 3,
      normalizedReplies.count == 3,
      suggestions.allSatisfy({ suggestion in
        !suggestion.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !suggestion.document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && containsNoInlineAssets(suggestion.document)
      }),
      !fullReply.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      containsNoInlineAssets(fullReply),
      completenessItems.allSatisfy({ item in
        !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !item.sourceMessageIds.isEmpty
          && Set(item.sourceMessageIds).isSubset(of: admittedMessageIds)
      })
    else {
      throw MailAssistanceError.guardrailViolation
    }

    var seenItemIds: Set<String> = []
    let uniqueItems = completenessItems.filter { seenItemIds.insert($0.id).inserted }
    return ResponseAssistanceResult(
      completenessItems: uniqueItems,
      fullReply: fullReply,
      scope: scope,
      suggestions: suggestions
    )
  }

  private static func containsNoInlineAssets(_ document: SemanticMessageDocument) -> Bool {
    document.blocks.allSatisfy { block in
      block.runs.allSatisfy { $0.inlineAssetId == nil }
    }
  }
}

extension MailAssistancePreview {
  static func response(
    suggestions: [ResponseAssistanceSuggestion],
    fullReply: SemanticMessageDocument,
    completenessItems: [ResponseAssistanceCompletenessItem],
    scope: ResponseAssistanceScope,
    request: MailAssistanceRequest
  ) throws -> Self {
    let result = try ResponseAssistanceResult.validated(
      suggestions: suggestions,
      fullReply: fullReply,
      completenessItems: completenessItems,
      scope: scope
    )
    try ComposeAssistanceOutputValidator.validate(result.fullReply, for: request)
    return Self(
      content: result.fullReply.plainText,
      inputVersion: request.context.inputVersion,
      kind: .content,
      profileId: request.context.profileId,
      response: result
    )
  }
}

/// Failures that prevent an already-local reply from becoming an assistance request.
enum ResponseAssistancePreparationError: LocalizedError, Equatable {
  case localTextExceedsDeterministicLimit
  case noLocalMessageText
  case notReplyDraft

  var errorDescription: String? {
    switch self {
    case .localTextExceedsDeterministicLimit:
      "This reply and its local Thread text exceed the on-device analysis limit."
    case .noLocalMessageText:
      "Open at least one message before using Response Assistance. Missing bodies are not fetched."
    case .notReplyDraft:
      "Open Response Assistance from a Reply or Reply All Draft."
    }
  }
}

/// Builds bounded response requests from an authored reply and already-local Thread text.
struct ResponseAssistanceRequestBuilder {
  let limits: MailAssistanceContextLimits

  init(limits: MailAssistanceContextLimits = .standard) {
    self.limits = limits
  }

  func makeRequest(
    for thread: MailboxThread,
    draft: MailShellCompositionDraft,
    profileId: MailProfileId,
    localeIdentifier: String,
    localBodyText: (StableProviderMessageIdentity) -> String?
  ) throws -> MailAssistanceRequest {
    guard draft.kind == .reply || draft.kind == .replyAll else {
      throw ResponseAssistancePreparationError.notReplyDraft
    }
    let localMessages = localMessages(in: thread, localBodyText: localBodyText)
    guard !localMessages.isEmpty else {
      throw ResponseAssistancePreparationError.noLocalMessageText
    }
    let recipientDisplayNames = Self.recipientDisplayNames(in: draft)
    let draftContext = MailAssistanceDraftContext(
      authoredBody: draft.document.plainText,
      selectedText: nil,
      subject: draft.subject,
      formattedTarget: draft.document
    )
    let baseCharacterCount =
      draftContext.authoredBody.count
      + draftContext.subject.count
      + (draftContext.formattedTarget?.plainText.count ?? 0)
      + recipientDisplayNames.reduce(0) { $0 + $1.count }
    let admitted = admittedSources(
      from: localMessages,
      initialCharacterCount: baseCharacterCount
    )
    guard !admitted.messages.isEmpty else {
      throw ResponseAssistancePreparationError.localTextExceedsDeterministicLimit
    }
    let scope = ResponseAssistanceScope(
      includedSources: admitted.sources,
      locallyAvailableMessageCount: localMessages.count,
      omittedForLimitMessageCount: localMessages.count - admitted.sources.count,
      unavailableLocalMessageCount: thread.messages.count - localMessages.count,
      totalThreadMessageCount: thread.messages.count
    )
    return MailAssistanceRequest(
      context: MailAssistanceContext(
        draft: draftContext,
        inputVersion: Self.inputVersion(
          for: thread,
          draft: draft,
          localBodyText: localBodyText
        ),
        profileId: profileId,
        recipientDisplayNames: recipientDisplayNames,
        sourceMessages: admitted.messages,
        responseScope: scope
      ),
      localeIdentifier: localeIdentifier,
      operation: .respond(instruction: nil)
    )
  }

  static func inputVersion(
    for thread: MailboxThread,
    draft: MailShellCompositionDraft,
    localBodyText: (StableProviderMessageIdentity) -> String?
  ) -> MailAssistanceInputVersion {
    let threadVersion = UnderstandingAssistanceRequestBuilder.inputVersion(
      for: thread,
      localBodyText: localBodyText
    )
    return MailAssistanceInputVersion(
      draftRevision: digest(
        draft: draft
      ),
      selectionRevision: "not-applicable",
      threadRevision: threadVersion.threadRevision
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
    from localMessages: [LocalMessage],
    initialCharacterCount: Int
  ) -> (messages: [MailAssistanceSourceMessage], sources: [ResponseAssistanceSource]) {
    var messages: [MailAssistanceSourceMessage] = []
    var sources: [ResponseAssistanceSource] = []
    var characterCount = initialCharacterCount

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
      sources.append(
        ResponseAssistanceSource(
          availableCharacterCount: localMessage.body.count,
          includedCharacterCount: admittedBody.count,
          messageId: message.id.rawValue,
          senderDisplayName: message.sender ?? message.from,
          sentAtMilliseconds: message.providerInternalDateMilliseconds
        )
      )
      characterCount += sourceMessage.characterCount
      if admittedBody.count < localMessage.body.count { break }
    }
    return (messages, sources)
  }

  private static func recipientDisplayNames(
    in draft: MailShellCompositionDraft
  ) -> [String] {
    var seen: Set<String> = []
    return [draft.recipient, draft.ccRecipients]
      .flatMap { RFCMailboxHeaderParser.mailboxes(in: $0) ?? [] }
      .compactMap(\.displayName)
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private static func digest(draft: MailShellCompositionDraft) -> String {
    var normalizedDraft = draft
    normalizedDraft.updatedAtMilliseconds = 0
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let input = (try? encoder.encode(normalizedDraft)) ?? Data()
    return Data(SHA256.hash(data: input)).base64EncodedString()
  }

  private struct LocalMessage {
    let body: String
    let message: MailboxMessageMetadata
  }
}
