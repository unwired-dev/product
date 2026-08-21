import CryptoKit
import Foundation

/// The deliberate Compose Assistance transformations available from every composer.
enum ComposeAssistancePreset: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
  case professional
  case friendly
  case direct
  case empathetic
  case neutral
  case shorten
  case expand
  case improveClarity

  var id: String { rawValue }

  var title: String {
    switch self {
    case .direct: "Direct"
    case .empathetic: "Empathetic"
    case .expand: "Expand"
    case .friendly: "Friendly"
    case .improveClarity: "Improve Clarity"
    case .neutral: "Neutral"
    case .professional: "Professional"
    case .shorten: "Shorten"
    }
  }

  var instruction: String {
    switch self {
    case .direct:
      "Make the writing direct while preserving every fact, question, and commitment."
    case .empathetic:
      "Make the writing empathetic without adding feelings, facts, promises, or commitments."
    case .expand:
      "Expand the explanation using only facts already present in the text."
    case .friendly:
      "Make the writing friendly while preserving every fact, question, and commitment."
    case .improveClarity:
      "Improve clarity without adding facts, removing obligations, or changing the meaning."
    case .neutral:
      "Make the writing neutral while preserving every fact, question, and commitment."
    case .professional:
      "Make the writing professional while preserving every fact, question, and commitment."
    case .shorten:
      "Shorten the writing without removing facts, questions, obligations, or commitments."
    }
  }
}

/// One explicit Compose Assistance action and its editor application behavior.
enum ComposeAssistanceAction: Equatable, Sendable {
  case generateBody(prompt: String)
  case proofread
  case refine(instruction: String)
  case suggestSubject
  case transform(ComposeAssistancePreset)

  var application: ComposeAssistanceApplication {
    switch self {
    case .generateBody:
      .insert
    case .suggestSubject:
      .replaceSubject
    case .proofread, .refine, .transform:
      .replaceTarget
    }
  }

  var operation: MailAssistanceOperation {
    switch self {
    case .generateBody(let prompt):
      .compose(prompt: prompt)
    case .proofread:
      .proofread
    case .refine(let instruction):
      .refine(instruction: instruction)
    case .suggestSubject:
      .suggestSubject
    case .transform(let preset):
      .transform(instruction: preset.instruction)
    }
  }
}

/// The single semantic mutation performed when an Assistance Preview is accepted.
enum ComposeAssistanceApplication: Equatable, Sendable {
  case insert
  case replaceSubject
  case replaceTarget
}

/// A captured authored-body or selection target used for revision fencing and atomic acceptance.
struct ComposeAssistanceTarget: Equatable, Sendable {
  enum Scope: String, Equatable, Sendable {
    case authoredBody
    case selection
  }

  let insertionOffset: Int
  let range: Range<Int>?
  let scope: Scope
  let sourceDocument: SemanticMessageDocument
  let targetDocument: SemanticMessageDocument

  var title: String {
    switch scope {
    case .authoredBody: "Authored Body"
    case .selection: "Selected Text"
    }
  }
}

enum ComposeAssistancePreparationError: LocalizedError, Equatable {
  case emptyPrompt
  case emptyRefinement
  case emptyTarget
  case invalidSelection

  var errorDescription: String? {
    switch self {
    case .emptyPrompt:
      "Describe the body you want to draft."
    case .emptyRefinement:
      "Describe how to refine the current Assistance Preview."
    case .emptyTarget:
      "Write or select text before transforming it."
    case .invalidSelection:
      "The selected text changed. Select it again and retry."
    }
  }
}

/// Builds bounded Compose Assistance requests without fetching or persisting mail content.
struct ComposeAssistanceRequestBuilder {
  // swiftlint:disable:next function_parameter_count
  func makeRequest(
    action: ComposeAssistanceAction,
    target: ComposeAssistanceTarget,
    subject: String,
    recipientDisplayNames: [String],
    profileId: MailProfileId,
    localeIdentifier: String
  ) throws -> MailAssistanceRequest {
    try validate(action: action, target: target)
    return MailAssistanceRequest(
      context: MailAssistanceContext(
        draft: MailAssistanceDraftContext(
          authoredBody: target.sourceDocument.plainText,
          selectedText: target.scope == .selection ? target.targetDocument.plainText : nil,
          subject: subject,
          formattedTarget: target.targetDocument
        ),
        inputVersion: Self.inputVersion(
          document: target.sourceDocument,
          target: target,
          subject: subject,
          recipientDisplayNames: recipientDisplayNames
        ),
        profileId: profileId,
        recipientDisplayNames: recipientDisplayNames,
        sourceMessages: []
      ),
      localeIdentifier: localeIdentifier,
      operation: action.operation
    )
  }

  func makeRefinementRequest(
    instruction: String,
    preview: MailAssistancePreview,
    originalRequest: MailAssistanceRequest
  ) throws -> MailAssistanceRequest {
    let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty else {
      throw ComposeAssistancePreparationError.emptyRefinement
    }
    guard let originalDraft = originalRequest.context.draft else {
      throw MailAssistanceError.guardrailViolation
    }
    let previewDocument =
      preview.semanticDocument
      ?? SemanticMessageDocument(plainText: preview.content)
    let draft: MailAssistanceDraftContext
    let operation: MailAssistanceOperation
    if preview.kind == .clarification {
      let clarification = "Clarification question: \(preview.content)\nAnswer: \(instruction)"
      draft = originalDraft
      switch originalRequest.operation {
      case .compose(let prompt):
        operation = .compose(prompt: "\(prompt)\n\(clarification)")
      case .suggestSubject:
        operation = .refineSubject(instruction: clarification)
      default:
        operation = .refine(instruction: clarification)
      }
    } else if case .suggestSubject = originalRequest.operation {
      draft = MailAssistanceDraftContext(
        authoredBody: originalDraft.authoredBody,
        selectedText: originalDraft.selectedText,
        subject: preview.content,
        formattedTarget: originalDraft.formattedTarget
      )
      operation = .refineSubject(instruction: instruction)
    } else {
      draft = MailAssistanceDraftContext(
        authoredBody: preview.content,
        selectedText: nil,
        subject: originalDraft.subject,
        formattedTarget: previewDocument
      )
      operation = .refine(instruction: instruction)
    }
    return MailAssistanceRequest(
      context: MailAssistanceContext(
        draft: draft,
        inputVersion: originalRequest.context.inputVersion,
        profileId: originalRequest.context.profileId,
        recipientDisplayNames: originalRequest.context.recipientDisplayNames,
        sourceMessages: []
      ),
      localeIdentifier: originalRequest.localeIdentifier,
      operation: operation
    )
  }

  static func inputVersion(
    document: SemanticMessageDocument,
    target: ComposeAssistanceTarget,
    subject: String,
    recipientDisplayNames: [String]
  ) -> MailAssistanceInputVersion {
    let draftRevision = digest(
      encodable: document,
      additionalComponents: [subject] + recipientDisplayNames
    )
    let selectedDocument = Self.document(in: document, range: target.range)
    let selectionRevision = digest(
      encodable: selectedDocument,
      additionalComponents: [
        target.scope.rawValue,
        String(target.range?.lowerBound ?? target.insertionOffset),
        String(target.range?.upperBound ?? target.insertionOffset),
      ]
    )
    return MailAssistanceInputVersion(
      draftRevision: draftRevision,
      selectionRevision: selectionRevision,
      threadRevision: "not-applicable"
    )
  }

  private func validate(
    action: ComposeAssistanceAction,
    target: ComposeAssistanceTarget
  ) throws {
    switch action {
    case .generateBody(let prompt):
      guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ComposeAssistancePreparationError.emptyPrompt
      }
    case .refine(let instruction):
      guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ComposeAssistancePreparationError.emptyRefinement
      }
    case .proofread, .transform:
      guard
        !target.targetDocument.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      else {
        throw ComposeAssistancePreparationError.emptyTarget
      }
    case .suggestSubject:
      guard
        !target.sourceDocument.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      else {
        throw ComposeAssistancePreparationError.emptyTarget
      }
    }
  }

  private static func document(
    in source: SemanticMessageDocument,
    range: Range<Int>?
  ) -> SemanticMessageDocument {
    guard let range else { return source }
    let attributed = source.attributedText
    guard range.lowerBound >= 0,
      range.upperBound <= attributed.characters.count,
      range.lowerBound <= range.upperBound
    else {
      return SemanticMessageDocument(plainText: "<invalid-selection>")
    }
    let lower = attributed.characters.index(attributed.startIndex, offsetBy: range.lowerBound)
    let upper = attributed.characters.index(attributed.startIndex, offsetBy: range.upperBound)
    return SemanticMessageDocument(attributedText: AttributedString(attributed[lower..<upper]))
  }

  private static func digest<T: Encodable>(
    encodable: T,
    additionalComponents: [String]
  ) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var input = (try? encoder.encode(encodable)) ?? Data()
    for component in additionalComponents {
      input.append(0)
      input.append(contentsOf: component.utf8)
    }
    return Data(SHA256.hash(data: input)).base64EncodedString()
  }
}

/// Rejects transformed output that changes formatting or drops high-risk factual tokens.
enum ComposeAssistanceOutputValidator {
  static func validate(
    _ output: SemanticMessageDocument,
    for request: MailAssistanceRequest
  ) throws {
    guard let source = request.context.draft?.formattedTarget else {
      throw MailAssistanceError.guardrailViolation
    }
    switch request.operation {
    case .compose:
      guard
        output.blocks.allSatisfy({ block in
          block.runs.allSatisfy { $0.inlineAssetId == nil }
        })
      else {
        throw MailAssistanceError.guardrailViolation
      }
    case .proofread, .refine, .refineSubject, .transform:
      guard preservesFormatting(from: source, to: output),
        preservesFactualTokens(from: source.plainText, to: output.plainText)
      else {
        throw MailAssistanceError.guardrailViolation
      }
    case .respond, .suggestSubject, .understand:
      break
    }
  }

  private static func preservesFormatting(
    from source: SemanticMessageDocument,
    to output: SemanticMessageDocument
  ) -> Bool {
    guard source.blocks.count == output.blocks.count else { return false }
    return zip(source.blocks, output.blocks).allSatisfy { sourceBlock, outputBlock in
      guard sourceBlock.kind == outputBlock.kind,
        sourceBlock.runs.count == outputBlock.runs.count
      else { return false }
      return zip(sourceBlock.runs, outputBlock.runs).allSatisfy { sourceRun, outputRun in
        sourceRun.inlineAssetId == outputRun.inlineAssetId
          && sourceRun.isBold == outputRun.isBold
          && sourceRun.isCode == outputRun.isCode
          && sourceRun.isItalic == outputRun.isItalic
          && sourceRun.isStruckThrough == outputRun.isStruckThrough
          && sourceRun.isUnderlined == outputRun.isUnderlined
          && sourceRun.link == outputRun.link
      }
    }
  }

  private static func preservesFactualTokens(from source: String, to output: String) -> Bool {
    let patterns = [
      #"https?://[^\s]+"#,
      #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
      #"(?:[$€£])?\b\d[\d,.:%/-]*\b"#,
      #"[\"“][^\"”]+[\"”]"#,
    ]
    let sourceTokens = patterns.flatMap { matches(of: $0, in: source) }
    let outputTokens = patterns.flatMap { matches(of: $0, in: output) }
    guard tokenCounts(sourceTokens) == tokenCounts(outputTokens) else { return false }
    guard source.count(where: { $0 == "?" }) <= output.count(where: { $0 == "?" }) else {
      return false
    }
    let obligationWords = ["commit", "deadline", "due", "must", "need", "owe", "promise", "will"]
    let sourceWords = source.lowercased().split { !$0.isLetter }.map(String.init)
    let outputWords = output.lowercased().split { !$0.isLetter }.map(String.init)
    return obligationWords.allSatisfy { word in
      sourceWords.count(where: { $0 == word }) <= outputWords.count(where: { $0 == word })
    }
  }

  private static func matches(of pattern: String, in value: String) -> [String] {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      )
    else { return [] }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      Range(match.range, in: value).map { String(value[$0]) }
    }
  }

  private static func tokenCounts(_ tokens: [String]) -> [String: Int] {
    tokens.reduce(into: [:]) { counts, token in
      counts[token, default: 0] += 1
    }
  }
}
