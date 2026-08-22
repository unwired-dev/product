import Foundation

/// Projects the app's current Profile and Sending Identity state into encrypted extension storage.
@MainActor
struct ShareExtensionCatalogSynchronizer {
  private let identitySyncFactory: (MailProfileRecordScope) -> any SendingIdentitySyncing
  private let lockStore: any MailProfileLockPersisting
  private let store: any ShareExtensionStoring

  /// Creates the app-side catalog projection boundary.
  init(
    store: any ShareExtensionStoring,
    lockStore: any MailProfileLockPersisting = UserDefaultsMailProfileLockStore(),
    identitySyncFactory: @escaping (MailProfileRecordScope) -> any SendingIdentitySyncing = {
      SendingIdentitySyncService(recordScope: $0)
    }
  ) {
    self.identitySyncFactory = identitySyncFactory
    self.lockStore = lockStore
    self.store = store
  }

  /// Refreshes every Profile while preserving a usable cached identity set during offline failures.
  func synchronize(
    session: ProductAccountSessionSnapshot,
    profileSnapshot: MailProfileSyncSnapshot,
    startupProfileId: MailProfileId?
  ) async throws {
    let existingCatalog = try? await store.loadCatalog()
    var profiles: [ShareExtensionProfile] = []
    for profile in profileSnapshot.profiles {
      try Task.checkCancellation()
      profiles.append(
        await makeProfile(
          profile,
          session: session,
          profileSnapshot: profileSnapshot,
          cachedCatalog: existingCatalog
        )
      )
    }
    let selectedStartupProfileId =
      startupProfileId.flatMap { candidate in
        profileSnapshot.profiles.contains { $0.id == candidate } ? candidate : nil
      } ?? profileSnapshot.defaultProfileId
    try await store.saveCatalog(
      ShareExtensionCatalog(
        productAccountId: session.productAccountId,
        profiles: profiles.sorted {
          $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        },
        startupProfileId: selectedStartupProfileId.rawValue,
        updatedAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1_000)
      )
    )
  }

  private func makeProfile(
    _ profile: MailProfileDefinition,
    session: ProductAccountSessionSnapshot,
    profileSnapshot: MailProfileSyncSnapshot,
    cachedCatalog: ShareExtensionCatalog?
  ) async -> ShareExtensionProfile {
    let cachedProfile = cachedCatalog?.profiles.first { $0.id == profile.id.rawValue }
    let loadedSnapshot = try? await identitySyncFactory(profile.recordScope).load(session: session)
    let connectionIds = Set(
      profileSnapshot.assignments.compactMap { connectionId, assignedProfileId in
        assignedProfileId == profile.id ? connectionId : nil
      }
    )
    let identities =
      loadedSnapshot?.preferences.identities.filter {
        connectionIds.contains($0.connectionId)
      }.map(ShareExtensionSendingIdentity.init) ?? cachedProfile?.sendingIdentities ?? []
    let loadedDefaultId = loadedSnapshot?.preferences.defaultIdentityId?.rawValue
    let defaultIdentityId =
      identities.contains { $0.id == loadedDefaultId }
      ? loadedDefaultId
      : cachedProfile?.defaultSendingIdentityId
    let lockConfiguration = lockStore.load(
      productAccountId: session.productAccountId,
      profileId: profile.id
    )
    return ShareExtensionProfile(
      colorName: profile.appearance.colorName,
      defaultSendingIdentityId: defaultIdentityId,
      id: profile.id.rawValue,
      isLocked: lockConfiguration.isEnabled,
      name: profile.name,
      sendingIdentities: identities.sorted { $0.title < $1.title },
      symbolName: profile.appearance.symbolName
    )
  }
}

extension ShareExtensionSendingIdentity {
  /// Creates the non-secret extension projection for one synchronized identity.
  fileprivate init(_ identity: SendingIdentity) {
    self.init(
      address: identity.address,
      connectionId: identity.connectionId.rawValue,
      displayName: identity.displayName,
      id: identity.id.rawValue
    )
  }
}
