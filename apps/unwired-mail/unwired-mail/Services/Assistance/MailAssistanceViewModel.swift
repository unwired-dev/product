import Foundation
import Observation

@MainActor
@Observable
final class MailAssistanceViewModel {
  enum Phase: Equatable {
    case checkingAvailability
    case generating
    case idle
    case previewing
  }

  private(set) var activeProfileId: MailProfileId
  private(set) var availability: MailAssistanceAvailability?
  private(set) var contentIsConcealed: Bool
  private(set) var errorMessage: String?
  private(set) var phase = Phase.idle
  private(set) var preview: MailAssistancePreview?
  var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      store.setEnabled(
        isEnabled,
        productAccountId: productAccountId,
        profileId: activeProfileId
      )
      if !isEnabled {
        cancelAndDestroy()
      }
    }
  }

  private var activeGeneration: Task<MailAssistancePreview, any Error>?
  private var availabilityCheck: Task<MailAssistanceAvailability, Never>?
  private let engine: any MailAssistanceEngine
  private let localeIdentifier: () -> String
  private var operationId = UUID()
  private let productAccountId: String
  private var retainedRequest: MailAssistanceRequest?
  private let store: MailAssistanceEnablementPersisting

  init(
    productAccountId: String,
    profileId: MailProfileId,
    contentIsConcealed: Bool = false,
    store: MailAssistanceEnablementPersisting =
      UserDefaultsMailAssistanceStore(),
    engine: any MailAssistanceEngine = SystemMailAssistanceEngine(),
    localeIdentifier: @escaping () -> String = { Locale.current.identifier }
  ) {
    self.productAccountId = productAccountId
    activeProfileId = profileId
    self.contentIsConcealed = contentIsConcealed
    self.store = store
    self.engine = engine
    self.localeIdentifier = localeIdentifier
    isEnabled = store.isEnabled(
      productAccountId: productAccountId,
      profileId: profileId
    )
  }

  var hasRetainedSensitiveContent: Bool {
    retainedRequest != nil || preview != nil
  }

  var statusMessage: String {
    if let errorMessage {
      return errorMessage
    }
    if contentIsConcealed {
      return "Unlock this Mail Profile to use Mail Assistance."
    }
    if !isEnabled {
      return "Mail Assistance is off for this Mail Profile on this device."
    }
    if phase == .checkingAvailability {
      return "Checking on-device availability…"
    }
    switch availability {
    case .available:
      return "Mail Assistance is ready on this device."
    case .unavailable(let reason):
      return reason.errorDescription
    case nil:
      return "Check whether Mail Assistance is available on this device."
    }
  }

  func activateProfile(
    _ profileId: MailProfileId,
    contentIsConcealed: Bool
  ) {
    cancelAndDestroy()
    activeProfileId = profileId
    self.contentIsConcealed = contentIsConcealed
    isEnabled = store.isEnabled(
      productAccountId: productAccountId,
      profileId: profileId
    )
  }

  func discardPreview() {
    cancelAndDestroy()
  }

  func perform(_ request: MailAssistanceRequest) async -> MailAssistancePreview? {
    guard isEnabled else {
      errorMessage = "Turn on Mail Assistance for this Mail Profile first."
      return nil
    }
    guard !contentIsConcealed else {
      errorMessage = "Unlock this Mail Profile to use Mail Assistance."
      return nil
    }
    guard request.context.profileId == activeProfileId else {
      errorMessage = "The assistance request belongs to another Mail Profile."
      return nil
    }

    cancelAndDestroy()
    let currentOperationId = operationId
    retainedRequest = request
    phase = .generating
    let generation = Task { try await engine.generate(request) }
    activeGeneration = generation
    do {
      let generatedPreview = try await generation.value
      guard operationId == currentOperationId, !contentIsConcealed else { return nil }
      activeGeneration = nil
      retainedRequest = nil
      preview = generatedPreview
      phase = .previewing
      return generatedPreview
    } catch {
      guard operationId == currentOperationId else { return nil }
      activeGeneration = nil
      retainedRequest = nil
      preview = nil
      phase = .idle
      errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      return nil
    }
  }

  func profileDidLock() {
    contentIsConcealed = true
    cancelAndDestroy()
  }

  func profileDidUnlock() {
    contentIsConcealed = false
  }

  func refreshAvailability() async {
    guard isEnabled, !contentIsConcealed else { return }
    cancelAndDestroy()
    let currentOperationId = operationId
    phase = .checkingAvailability
    let check = Task { await engine.availability(for: localeIdentifier()) }
    availabilityCheck = check
    let result = await check.value
    guard operationId == currentOperationId, !contentIsConcealed else { return }
    availabilityCheck = nil
    availability = result
    phase = .idle
  }

  private func cancelAndDestroy() {
    operationId = UUID()
    activeGeneration?.cancel()
    availabilityCheck?.cancel()
    activeGeneration = nil
    availabilityCheck = nil
    availability = nil
    errorMessage = nil
    phase = .idle
    preview = nil
    retainedRequest = nil
  }
}
