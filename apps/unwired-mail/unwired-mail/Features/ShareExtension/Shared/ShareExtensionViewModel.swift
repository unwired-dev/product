import Foundation
import Observation

/// Presentation state for the Profile-aware Share Extension flow.
@MainActor
@Observable
final class ShareExtensionViewModel {
  enum LoadState: Equatable {
    case idle
    case loading
    case ready
    case failed
  }

  enum SaveState: Equatable {
    case idle
    case saving
    case saved
  }

  private(set) var catalog: ShareExtensionCatalog?
  private(set) var errorMessage: String?
  private(set) var inputCount = 0
  private(set) var loadState: LoadState = .idle
  private(set) var saveState: SaveState = .idle
  var selectedIdentityId: String?
  private(set) var selectedProfileId: String?
  private(set) var unlockedProfileIds: Set<String> = []

  private let authenticator: any ShareExtensionProfileAuthenticating
  private let draftBuilder: ShareExtensionDraftBuilder
  private let draftId: UUID
  private let inputLoader: any ShareExtensionInputLoading
  private let makeStore: () throws -> any ShareExtensionStoring
  private var inputs: [ShareExtensionInput] = []
  private var store: (any ShareExtensionStoring)?

  /// Creates one testable extension flow with explicit effect boundaries.
  init(
    inputLoader: any ShareExtensionInputLoading,
    makeStore: @escaping () throws -> any ShareExtensionStoring = {
      try ShareExtensionStore.live()
    },
    authenticator: (any ShareExtensionProfileAuthenticating)? = nil,
    draftBuilder: ShareExtensionDraftBuilder = ShareExtensionDraftBuilder(),
    draftId: UUID = UUID()
  ) {
    self.authenticator = authenticator ?? LocalShareExtensionProfileAuthenticator()
    self.draftBuilder = draftBuilder
    self.draftId = draftId
    self.inputLoader = inputLoader
    self.makeStore = makeStore
  }

  var profiles: [ShareExtensionProfile] {
    catalog?.profiles ?? []
  }

  var selectedProfile: ShareExtensionProfile? {
    selectedProfileId.flatMap { profileId in profiles.first { $0.id == profileId } }
  }

  var selectedIdentity: ShareExtensionSendingIdentity? {
    guard selectedProfileIsUnlocked else { return nil }
    return selectedIdentityId.flatMap { identityId in
      selectedProfile?.sendingIdentities.first { $0.id == identityId }
    }
  }

  var selectedProfileIsUnlocked: Bool {
    guard let selectedProfile else { return false }
    return !selectedProfile.isLocked || unlockedProfileIds.contains(selectedProfile.id)
  }

  var canSave: Bool {
    loadState == .ready && saveState == .idle && selectedIdentity != nil && !inputs.isEmpty
  }

  func load() async {
    guard loadState == .idle else { return }
    loadState = .loading
    do {
      let store = try makeStore()
      self.store = store
      async let loadedCatalog = store.loadCatalog()
      async let loadedInputs = inputLoader.loadInputs()
      let (catalog, inputs) = try await (loadedCatalog, loadedInputs)
      try Task.checkCancellation()
      guard let catalog, let startupProfile = catalog.startupProfile else {
        throw ShareExtensionStoreError.configurationUnavailable
      }
      self.catalog = catalog
      self.inputs = inputs
      inputCount = inputs.count
      selectedProfileId = startupProfile.id
      if startupProfile.isLocked {
        selectedIdentityId = nil
      } else {
        selectedIdentityId = startupProfile.defaultSendingIdentity?.id
      }
      loadState = .ready
      errorMessage = identityAvailabilityError(for: startupProfile)
    } catch is CancellationError {
      loadState = .idle
    } catch {
      loadState = .failed
      errorMessage = error.localizedDescription
    }
  }

  func selectProfile(_ profileId: String) async {
    guard let profile = profiles.first(where: { $0.id == profileId }) else { return }
    if profile.isLocked, !unlockedProfileIds.contains(profile.id) {
      guard await authenticate(profile) else { return }
    }
    selectedProfileId = profile.id
    selectedIdentityId = profile.defaultSendingIdentity?.id
    errorMessage = identityAvailabilityError(for: profile)
  }

  func unlockSelectedProfile() async {
    guard let selectedProfile, await authenticate(selectedProfile) else { return }
    selectedIdentityId = selectedProfile.defaultSendingIdentity?.id
    errorMessage = identityAvailabilityError(for: selectedProfile)
  }

  func selectIdentity(_ identityId: String) {
    guard selectedProfileIsUnlocked,
      selectedProfile?.sendingIdentities.contains(where: { $0.id == identityId }) == true
    else { return }
    selectedIdentityId = identityId
    errorMessage = nil
  }

  /// Saves the pending encrypted Draft and returns its explicit app handoff URL.
  func save() async -> URL? {
    guard saveState == .idle, let store, let catalog, let selectedProfile,
      let selectedIdentity
    else { return nil }
    saveState = .saving
    do {
      let draft = try draftBuilder.makeDraft(
        id: draftId,
        inputs: inputs,
        catalog: catalog,
        profile: selectedProfile,
        identity: selectedIdentity
      )
      try Task.checkCancellation()
      try await store.savePendingDraft(draft)
      saveState = .saved
      errorMessage = nil
      return handoffURL(profileId: selectedProfile.id, draftId: draft.id)
    } catch is CancellationError {
      saveState = .idle
      return nil
    } catch {
      saveState = .idle
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func authenticate(_ profile: ShareExtensionProfile) async -> Bool {
    do {
      guard try await authenticator.authenticate(profileName: profile.name) else {
        errorMessage = "Profile authentication did not complete."
        return false
      }
      unlockedProfileIds.insert(profile.id)
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func identityAvailabilityError(for profile: ShareExtensionProfile) -> String? {
    guard !profile.isLocked || unlockedProfileIds.contains(profile.id) else { return nil }
    guard profile.defaultSendingIdentity != nil else {
      return "Open Unwired Mail and add a Sending Identity to \(profile.name)."
    }
    return nil
  }

  private func handoffURL(profileId: String, draftId: UUID) -> URL? {
    var components = URLComponents()
    components.scheme = "unwired-mail"
    components.host = "mail"
    components.queryItems = [
      URLQueryItem(name: "profileId", value: profileId),
      URLQueryItem(name: "draftId", value: draftId.uuidString.lowercased()),
    ]
    return components.url
  }
}
