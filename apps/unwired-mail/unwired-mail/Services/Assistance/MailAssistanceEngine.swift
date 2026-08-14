import Foundation

enum MailAssistanceCapability: String, Codable, Equatable, Sendable {
  case compose
  case respond
  case transform
  case understand
}

enum MailAssistanceOperation: Codable, Equatable, Sendable {
  case compose(prompt: String)
  case respond(instruction: String?)
  case transform(instruction: String)
  case understand

  var capability: MailAssistanceCapability {
    switch self {
    case .compose:
      .compose
    case .respond:
      .respond
    case .transform:
      .transform
    case .understand:
      .understand
    }
  }
}

struct MailAssistanceInputVersion: Codable, Equatable, Sendable {
  let draftRevision: String?
  let selectionRevision: String?
  let threadRevision: String?

  init(
    draftRevision: String? = nil,
    selectionRevision: String? = nil,
    threadRevision: String? = nil
  ) {
    self.draftRevision = draftRevision
    self.selectionRevision = selectionRevision
    self.threadRevision = threadRevision
  }

  var identifiesInput: Bool {
    draftRevision != nil && selectionRevision != nil && threadRevision != nil
  }
}

struct MailAssistanceDraftContext: Codable, Equatable, Sendable {
  let authoredBody: String
  let selectedText: String?
  let subject: String
}

struct MailAssistanceSourceMessage: Codable, Equatable, Sendable {
  let body: String
  let senderDisplayName: String?
}

/// The complete, already-local content explicitly admitted to one assistance operation.
///
/// This type intentionally has no provider, attachment, remote-content, or persistence
/// dependency. Callers decide which local text to admit before invoking an engine.
struct MailAssistanceContext: Codable, Equatable, Sendable {
  let draft: MailAssistanceDraftContext?
  let inputVersion: MailAssistanceInputVersion
  let profileId: MailProfileId
  let recipientDisplayNames: [String]
  let sourceMessages: [MailAssistanceSourceMessage]

  var characterCount: Int {
    var count = recipientDisplayNames.reduce(0) { $0 + $1.count }
    count += sourceMessages.reduce(0) {
      $0 + $1.body.count + ($1.senderDisplayName?.count ?? 0)
    }
    if let draft {
      count += draft.authoredBody.count + draft.subject.count + (draft.selectedText?.count ?? 0)
    }
    return count
  }
}

struct MailAssistanceRequest: Codable, Equatable, Sendable {
  let context: MailAssistanceContext
  let localeIdentifier: String
  let operation: MailAssistanceOperation
}

struct MailAssistanceContextLimits: Equatable, Sendable {
  let maximumCharacterCount: Int
  let maximumSourceMessageCount: Int

  static let standard = MailAssistanceContextLimits(
    maximumCharacterCount: 24_000,
    maximumSourceMessageCount: 32
  )
}

enum MailAssistanceUnavailableReason: Equatable, Sendable {
  case appleIntelligenceNotEnabled
  case deviceNotEligible
  case modelNotReady
  case unsupportedLanguageOrRegion(localeIdentifier: String)
}

enum MailAssistanceAvailability: Equatable, Sendable {
  case available
  case unavailable(MailAssistanceUnavailableReason)
}

enum MailAssistanceError: LocalizedError, Equatable, Sendable {
  case cancelled
  case concurrentRequest
  case contextTooLarge(maximumCharacterCount: Int, maximumSourceMessageCount: Int)
  case generationFailed
  case guardrailViolation
  case invalidInputVersion
  case rateLimited
  case refused
  case resourcesUnavailable
  case unavailable(MailAssistanceUnavailableReason)
  case unsupportedLanguageOrLocale

  var errorDescription: String? {
    switch self {
    case .cancelled:
      "Assistance was cancelled."
    case .concurrentRequest:
      "Another assistance request is still running."
    case .contextTooLarge:
      "The selected mail content is too large for on-device assistance."
    case .generationFailed:
      "On-device assistance could not produce a result."
    case .guardrailViolation:
      "On-device assistance could not process this request safely."
    case .invalidInputVersion:
      "The assistance request is not bound to a Draft, selection, or Thread revision."
    case .rateLimited:
      "On-device assistance is temporarily busy. Try again later."
    case .refused:
      "On-device assistance declined this request."
    case .resourcesUnavailable:
      "The on-device model does not currently have enough resources."
    case .unavailable(let reason):
      reason.errorDescription
    case .unsupportedLanguageOrLocale:
      "The on-device model does not support this language or region."
    }
  }
}

extension MailAssistanceUnavailableReason {
  var errorDescription: String {
    switch self {
    case .appleIntelligenceNotEnabled:
      "Turn on Apple Intelligence to use Mail Assistance."
    case .deviceNotEligible:
      "Mail Assistance is unavailable on this device."
    case .modelNotReady:
      "The on-device model is not ready yet."
    case .unsupportedLanguageOrRegion:
      "Mail Assistance is unavailable for the current language or region."
    }
  }
}

enum MailAssistancePreviewKind: Equatable, Sendable {
  case clarification
  case content
}

enum MailAssistancePreviewApplicationStatus: Equatable, Sendable {
  case current
  case stale
}

struct MailAssistancePreview: Equatable, Sendable {
  let content: String
  let inputVersion: MailAssistanceInputVersion
  let kind: MailAssistancePreviewKind
  let profileId: MailProfileId

  func applicationStatus(
    profileId currentProfileId: MailProfileId,
    inputVersion currentInputVersion: MailAssistanceInputVersion
  ) -> MailAssistancePreviewApplicationStatus {
    guard profileId == currentProfileId, inputVersion == currentInputVersion else {
      return .stale
    }
    return .current
  }
}

protocol MailAssistanceEngine: Sendable {
  func availability(for localeIdentifier: String) async -> MailAssistanceAvailability
  func generate(_ request: MailAssistanceRequest) async throws -> MailAssistancePreview
}

enum DeterministicMailAssistanceOutcome: Equatable, Sendable {
  case clarification(String)
  case failure(MailAssistanceError)
  case success(String)
  case suspendUntilCancelled
}

/// A deterministic engine for tests and previews that never invokes a system model.
struct DeterministicMailAssistanceEngine: MailAssistanceEngine {
  private let availabilityState: MailAssistanceAvailability
  private let limits: MailAssistanceContextLimits
  private let outcome: DeterministicMailAssistanceOutcome

  init(
    availability: MailAssistanceAvailability = .available,
    limits: MailAssistanceContextLimits = .standard,
    outcome: DeterministicMailAssistanceOutcome
  ) {
    availabilityState = availability
    self.limits = limits
    self.outcome = outcome
  }

  func availability(for _: String) async -> MailAssistanceAvailability {
    availabilityState
  }

  func generate(_ request: MailAssistanceRequest) async throws -> MailAssistancePreview {
    try validate(request)
    if case .unavailable(let reason) = availabilityState {
      throw MailAssistanceError.unavailable(reason)
    }
    guard !Task.isCancelled else {
      throw MailAssistanceError.cancelled
    }

    switch outcome {
    case .clarification(let content):
      return preview(content: content, kind: .clarification, request: request)
    case .failure(let error):
      throw error
    case .success(let content):
      return preview(content: content, kind: .content, request: request)
    case .suspendUntilCancelled:
      do {
        try await Task.sleep(for: .seconds(3_600))
        throw MailAssistanceError.generationFailed
      } catch is CancellationError {
        throw MailAssistanceError.cancelled
      }
    }
  }

  private func preview(
    content: String,
    kind: MailAssistancePreviewKind,
    request: MailAssistanceRequest
  ) -> MailAssistancePreview {
    MailAssistancePreview(
      content: content,
      inputVersion: request.context.inputVersion,
      kind: kind,
      profileId: request.context.profileId
    )
  }

  private func validate(_ request: MailAssistanceRequest) throws {
    guard request.context.inputVersion.identifiesInput else {
      throw MailAssistanceError.invalidInputVersion
    }
    guard
      request.context.characterCount <= limits.maximumCharacterCount,
      request.context.sourceMessages.count <= limits.maximumSourceMessageCount
    else {
      throw MailAssistanceError.contextTooLarge(
        maximumCharacterCount: limits.maximumCharacterCount,
        maximumSourceMessageCount: limits.maximumSourceMessageCount
      )
    }
  }
}
