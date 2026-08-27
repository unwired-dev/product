import CryptoKit
import Foundation
import Observation
import Translation

// swiftlint:disable file_length

/// The mail content admitted to one explicit Translation operation.
enum MailTranslationContentKind: Equatable, Sendable {
  case draftSelection
  case incomingMessage
}

/// The device-reported readiness of one selected language pair.
enum MailTranslationAvailability: Equatable, Sendable {
  case downloadable
  case installed
  case unsupported
}

/// A product-owned translation request containing only explicit, already-local text.
struct MailTranslationRequest: Equatable, Sendable {
  let contentKind: MailTranslationContentKind
  let inputVersion: MailAssistanceInputVersion
  let profileId: MailProfileId
  let sourceLanguage: Locale.Language?
  let sourceText: String
  let targetLanguage: Locale.Language
}

/// The live product state that must still match before Translation starts.
struct MailTranslationValidationContext: Equatable, Sendable {
  let contentIsConcealed: Bool
  let inputVersion: MailAssistanceInputVersion
  let isEnabled: Bool
  let profileId: MailProfileId
}

/// A system translation response converted into product-owned value types.
struct MailTranslationResponse: Equatable, Sendable {
  let sourceLanguage: Locale.Language
  let sourceText: String
  let targetLanguage: Locale.Language
  let targetText: String
}

/// An ephemeral translated result bound to the exact Mail Profile and local input revision.
struct MailTranslationResult: Equatable, Sendable {
  let contentKind: MailTranslationContentKind
  let inputVersion: MailAssistanceInputVersion
  let profileId: MailProfileId
  let sourceLanguage: Locale.Language
  let sourceText: String
  let targetLanguage: Locale.Language
  let targetText: String

  /// Creates a result only when the system response matches the requested local input and pair.
  static func validated(
    response: MailTranslationResponse,
    request: MailTranslationRequest
  ) throws -> Self {
    guard response.sourceText == request.sourceText,
      response.targetLanguage.isEquivalent(to: request.targetLanguage),
      request.sourceLanguage.map({ response.sourceLanguage.isEquivalent(to: $0) }) ?? true,
      !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MailTranslationError.invalidResponse
    }
    return Self(
      contentKind: request.contentKind,
      inputVersion: request.inputVersion,
      profileId: request.profileId,
      sourceLanguage: response.sourceLanguage,
      sourceText: response.sourceText,
      targetLanguage: response.targetLanguage,
      targetText: response.targetText
    )
  }

  /// Reports whether this result still belongs to the visible Mail Profile and source text.
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

/// One item-driven Translation presentation containing only ephemeral local text.
struct MailTranslationPresentation: Identifiable {
  let contentKind: MailTranslationContentKind
  let draftTarget: ComposeAssistanceTarget?
  let id = UUID()
  let incomingMessageId: StableProviderMessageIdentity?
  let inputVersion: MailAssistanceInputVersion
  let profileId: MailProfileId
  let sourceText: String

  /// Creates a Translation request for the currently selected language pair.
  func request(
    sourceLanguage: Locale.Language?,
    targetLanguage: Locale.Language
  ) -> MailTranslationRequest {
    MailTranslationRequest(
      contentKind: contentKind,
      inputVersion: inputVersion,
      profileId: profileId,
      sourceLanguage: sourceLanguage,
      sourceText: sourceText,
      targetLanguage: targetLanguage
    )
  }
}

/// Failures that keep source mail unchanged during Translation.
enum MailTranslationError: LocalizedError, Equatable {
  case cancelled
  case downloadDeclined
  case emptyDraftSelection
  case invalidResponse
  case noLocalMessageText
  case staleInput
  case unavailable
  case unableToIdentifyLanguage

  var errorDescription: String? {
    switch self {
    case .cancelled:
      "Translation was cancelled."
    case .downloadDeclined:
      "The language download did not finish. Keep the original text or try again."
    case .emptyDraftSelection:
      "Select Draft text before translating it."
    case .invalidResponse:
      "Translation did not return a valid result. The original text is unchanged."
    case .noLocalMessageText:
      "Open this message before translating it. Missing message bodies are not fetched."
    case .staleInput:
      "The source text changed. Translate the current text again."
    case .unavailable:
      "This language pair is unavailable on this device."
    case .unableToIdentifyLanguage:
      "Choose the source language and try again."
    }
  }
}

/// Builds Translation presentations from already-local reader and editor text.
enum MailTranslationRequestBuilder {
  /// Builds an incoming-message presentation without fetching a missing body.
  static func incomingMessage(
    messageId: StableProviderMessageIdentity,
    localBodyText: String?,
    profileId: MailProfileId
  ) throws -> MailTranslationPresentation {
    guard let localBodyText, !localBodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MailTranslationError.noLocalMessageText
    }
    return MailTranslationPresentation(
      contentKind: .incomingMessage,
      draftTarget: nil,
      incomingMessageId: messageId,
      inputVersion: incomingInputVersion(messageId: messageId, localBodyText: localBodyText),
      profileId: profileId,
      sourceText: localBodyText
    )
  }

  /// Builds a Draft presentation for one explicit, nonempty editor selection.
  static func draftSelection(
    target: ComposeAssistanceTarget,
    inputVersion: MailAssistanceInputVersion,
    profileId: MailProfileId
  ) throws -> MailTranslationPresentation {
    guard target.scope == .selection,
      !target.targetDocument.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MailTranslationError.emptyDraftSelection
    }
    return MailTranslationPresentation(
      contentKind: .draftSelection,
      draftTarget: target,
      incomingMessageId: nil,
      inputVersion: inputVersion,
      profileId: profileId,
      sourceText: target.targetDocument.plainText
    )
  }

  /// Returns the revision fence for one already-local incoming message body.
  static func incomingInputVersion(
    messageId: StableProviderMessageIdentity,
    localBodyText: String?
  ) -> MailAssistanceInputVersion {
    guard let localBodyText else { return MailAssistanceInputVersion() }
    var data = Data()
    for component in [messageId.rawValue, localBodyText] {
      data.append(contentsOf: component.utf8)
      data.append(0)
    }
    let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return MailAssistanceInputVersion(
      draftRevision: "not-applicable",
      selectionRevision: "not-applicable",
      threadRevision: revision
    )
  }
}

/// Reports system-supported languages and the readiness of a selected pair.
protocol MailTranslationAvailabilityChecking: Sendable {
  func availability(
    for sourceText: String,
    sourceLanguage: Locale.Language?,
    targetLanguage: Locale.Language
  ) async throws -> MailTranslationAvailability

  func supportedLanguages() async -> [Locale.Language]
}

/// Reads Translation framework language support without retaining mail text.
struct SystemMailTranslationAvailabilityChecker: MailTranslationAvailabilityChecking {
  func availability(
    for sourceText: String,
    sourceLanguage: Locale.Language?,
    targetLanguage: Locale.Language
  ) async throws -> MailTranslationAvailability {
    let service = LanguageAvailability()
    let status: LanguageAvailability.Status
    if let sourceLanguage {
      status = await service.status(from: sourceLanguage, to: targetLanguage)
    } else {
      status = try await service.status(for: sourceText, to: targetLanguage)
    }
    switch status {
    case .installed:
      return .installed
    case .supported:
      return .downloadable
    case .unsupported:
      return .unsupported
    @unknown default:
      return .unsupported
    }
  }

  func supportedLanguages() async -> [Locale.Language] {
    await LanguageAvailability().supportedLanguages
  }
}

/// The narrow Translation session behavior used by the presentation model.
protocol MailTranslationSession: Sendable {
  func cancel() async
  func prepareTranslation() async throws
  func translate(_ sourceText: String) async throws -> MailTranslationResponse
}

/// Adapts one SwiftUI-provided system Translation session to the product boundary.
actor SystemMailTranslationSession: MailTranslationSession {
  private let session: TranslationSession

  init(_ session: TranslationSession) {
    self.session = session
  }

  func cancel() {
    session.cancel()
  }

  func prepareTranslation() async throws {
    try await session.prepareTranslation()
  }

  func translate(_ sourceText: String) async throws -> MailTranslationResponse {
    let response = try await session.translate(sourceText)
    return MailTranslationResponse(
      sourceLanguage: response.sourceLanguage,
      sourceText: response.sourceText,
      targetLanguage: response.targetLanguage,
      targetText: response.targetText
    )
  }
}

/// Presentation state for explicit, cancellable Translation operations.
@MainActor
@Observable
final class MailTranslationViewModel {
  enum Phase: Equatable {
    case checkingAvailability
    case idle
    case reviewing
    case translating
  }

  private(set) var availability: MailTranslationAvailability?
  private(set) var errorMessage: String?
  private(set) var phase = Phase.idle
  private(set) var result: MailTranslationResult?
  private(set) var supportedLanguages: [Locale.Language] = []

  private var activeTranslation: Task<MailTranslationResult, any Error>?
  private var availabilityCheck: Task<MailTranslationAvailability, any Error>?
  private let availabilityChecker: any MailTranslationAvailabilityChecking
  private var availabilityOperationId = UUID()
  private var languageLoad: Task<[Locale.Language], Never>?
  private var operationId = UUID()
  private var translationOperationId = UUID()

  init(
    availabilityChecker: any MailTranslationAvailabilityChecking =
      SystemMailTranslationAvailabilityChecker()
  ) {
    self.availabilityChecker = availabilityChecker
  }

  var hasRetainedMailContent: Bool {
    activeTranslation != nil || result != nil
  }

  /// Loads the exact language catalog reported by this device.
  func loadSupportedLanguages() async {
    languageLoad?.cancel()
    let currentOperationId = operationId
    let load = Task { await availabilityChecker.supportedLanguages() }
    languageLoad = load
    let languages = await load.value
    guard operationId == currentOperationId, !Task.isCancelled else { return }
    languageLoad = nil
    supportedLanguages = Array(Set(languages)).sorted {
      $0.minimalIdentifier < $1.minimalIdentifier
    }
  }

  /// Refreshes installed, downloadable, or unsupported state for one selected pair.
  func refreshAvailability(
    sourceText: String,
    sourceLanguage: Locale.Language?,
    targetLanguage: Locale.Language
  ) async {
    availabilityCheck?.cancel()
    activeTranslation?.cancel()
    availabilityOperationId = UUID()
    translationOperationId = UUID()
    availability = nil
    result = nil
    errorMessage = nil
    phase = .checkingAvailability
    let currentAvailabilityOperationId = availabilityOperationId
    let check = Task {
      try await availabilityChecker.availability(
        for: sourceText,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage
      )
    }
    availabilityCheck = check
    do {
      let status = try await check.value
      guard availabilityOperationId == currentAvailabilityOperationId, !Task.isCancelled else {
        return
      }
      availabilityCheck = nil
      availability = status
      phase = .idle
    } catch is CancellationError {
      guard availabilityOperationId == currentAvailabilityOperationId else { return }
      availabilityCheck = nil
      phase = .idle
    } catch {
      guard availabilityOperationId == currentAvailabilityOperationId else { return }
      availabilityCheck = nil
      availability = .unsupported
      phase = .idle
      errorMessage = Self.message(for: error)
    }
  }

  /// Creates a fenced request after verifying enablement, Profile ownership, and input freshness.
  func beginTranslation(
    presentation: MailTranslationPresentation,
    sourceLanguage: Locale.Language?,
    targetLanguage: Locale.Language,
    validation: MailTranslationValidationContext
  ) throws -> MailTranslationRequest {
    guard validation.isEnabled, !validation.contentIsConcealed else {
      throw MailTranslationError.unavailable
    }
    guard presentation.profileId == validation.profileId,
      presentation.inputVersion == validation.inputVersion
    else {
      throw MailTranslationError.staleInput
    }
    guard availability == .installed || availability == .downloadable else {
      throw MailTranslationError.unavailable
    }
    if let sourceLanguage, sourceLanguage.isEquivalent(to: targetLanguage) {
      throw MailTranslationError.unavailable
    }
    errorMessage = nil
    result = nil
    phase = .translating
    return presentation.request(
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
  }

  /// Prepares any required system download and translates the exact requested text.
  func perform(
    _ request: MailTranslationRequest,
    using session: any MailTranslationSession
  ) async {
    activeTranslation?.cancel()
    translationOperationId = UUID()
    let currentTranslationOperationId = translationOperationId
    let translation = Task {
      try await withTaskCancellationHandler {
        try await session.prepareTranslation()
        try Task.checkCancellation()
        let response = try await session.translate(request.sourceText)
        try Task.checkCancellation()
        return try MailTranslationResult.validated(response: response, request: request)
      } onCancel: {
        Task { await session.cancel() }
      }
    }
    activeTranslation = translation
    do {
      let translatedResult = try await translation.value
      guard translationOperationId == currentTranslationOperationId else { return }
      activeTranslation = nil
      result = translatedResult
      phase = .reviewing
    } catch is CancellationError {
      guard translationOperationId == currentTranslationOperationId else { return }
      activeTranslation = nil
      phase = .idle
    } catch {
      guard translationOperationId == currentTranslationOperationId else { return }
      activeTranslation = nil
      result = nil
      phase = .idle
      errorMessage = Self.message(for: error)
    }
  }

  /// Cancels in-flight work and destroys all retained source and translated text.
  func cancelAndDestroy() {
    operationId = UUID()
    availabilityOperationId = UUID()
    translationOperationId = UUID()
    activeTranslation?.cancel()
    availabilityCheck?.cancel()
    languageLoad?.cancel()
    activeTranslation = nil
    availabilityCheck = nil
    languageLoad = nil
    availability = nil
    errorMessage = nil
    phase = .idle
    result = nil
  }

  /// Records an application failure without retaining an unusable translated result.
  func applicationFailed() {
    result = nil
    phase = .idle
    errorMessage = MailTranslationError.staleInput.errorDescription
  }

  /// Presents a preparation or application error without retaining a result.
  func record(_ error: any Error) {
    result = nil
    phase = .idle
    errorMessage = Self.message(for: error)
  }

  private static func message(for error: any Error) -> String {
    if TranslationError.unableToIdentifyLanguage ~= error {
      return MailTranslationError.unableToIdentifyLanguage.errorDescription ?? ""
    }
    if TranslationError.unsupportedSourceLanguage ~= error
      || TranslationError.unsupportedTargetLanguage ~= error
      || TranslationError.unsupportedLanguagePairing ~= error
    {
      return MailTranslationError.unavailable.errorDescription ?? ""
    }
    if TranslationError.notInstalled ~= error {
      return MailTranslationError.downloadDeclined.errorDescription ?? ""
    }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
