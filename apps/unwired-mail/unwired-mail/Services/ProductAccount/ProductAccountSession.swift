import Foundation
import Observation

enum ProductAccountSessionState: Equatable {
  case loading
  case signedOut
  case signedIn(ProductAccountSessionSnapshot)
  case failed(String)
}

@MainActor
@Observable
final class ProductAccountSession {
  private(set) var state: ProductAccountSessionState = .loading

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var mailboxFreshnessSession: ProductAccountSessionSnapshot?
  @ObservationIgnored private var mailboxFreshnessViewModel: MailboxFreshnessViewModel?
  @ObservationIgnored private var signOutSnapshot: ProductAccountSessionSnapshot?
  private var isSigningOut = false
  private let appleSignInService: AppleSignInPerforming
  private let devicePushUnregistrationService: DevicePushUnregistering
  private let productAccountService: ProductAccountConnecting
  private let sessionStore: ProductAccountSessionPersisting
  private let mailboxConnectionService: MailboxConnectionClearing
  private let productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    appleSignInService: AppleSignInPerforming,
    devicePushUnregistrationService: DevicePushUnregistering =
      DevicePushUnregistrationService(),
    productAccountService: ProductAccountConnecting = ConvexProductAccountService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    mailboxConnectionService: MailboxConnectionClearing = ProductAccountMailboxConnectionClearer(),
    productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.appleSignInService = appleSignInService
    self.devicePushUnregistrationService = devicePushUnregistrationService
    self.productAccountService = productAccountService
    self.sessionStore = sessionStore
    self.mailboxConnectionService = mailboxConnectionService
    self.productSyncKeyMaterialStore = productSyncKeyMaterialStore
  }

  func bootstrap() async {
    if let bootstrapTask {
      await bootstrapTask.value
      return
    }
    state = .loading
    let task = Task { await performBootstrap() }
    bootstrapTask = task
    await task.value
  }

  private func performBootstrap() async {
    guard let snapshot = try? sessionStore.load() else {
      state = .signedOut
      return
    }

    do {
      let credential = try await appleSignInService.restoreSession(snapshot: snapshot)
      let response = try await productAccountService.connect(
        identityToken: credential.identityToken
      )
      _ = try productSyncKeyMaterialStore.ensureMaterial(
        productAccountId: response.productAccountId,
        allowCreation: response.accountCreated
      )
      _ = try await productAccountService.markProductSyncMaterialInitialized(
        identityToken: credential.identityToken,
        trustedDeviceId: response.trustedDeviceId
      )
      let refreshedSnapshot = ProductAccountSessionSnapshot(
        appleUserIdentifier: credential.appleUserIdentifier,
        identityToken: credential.identityToken,
        identityTokenExpiresAt: AppleIdentityToken.expirationDate(
          from: credential.identityToken
        ),
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      try await replaceSessionAfterBootstrap(
        snapshot,
        with: refreshedSnapshot
      )
      state = .signedIn(refreshedSnapshot)
    } catch let error as AppleSignInError {
      switch error {
      case .notAuthorized:
        try? await devicePushUnregistrationService.unregister(session: snapshot)
        do {
          try await mailboxConnectionService.clearLocalConnection(session: snapshot)
          try sessionStore.clear()
          state = .signedOut
        } catch {
          state = .failed(error.localizedDescription)
        }
      default:
        state = .failed(error.localizedDescription)
      }
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func signInWithApple() async {
    state = .loading

    do {
      let credential = try await appleSignInService.signIn()
      let response = try await productAccountService.connect(
        identityToken: credential.identityToken
      )
      _ = try productSyncKeyMaterialStore.ensureMaterial(
        productAccountId: response.productAccountId,
        allowCreation: shouldCreateProductSyncMaterialAfterSignIn(response: response)
      )
      _ = try await productAccountService.markProductSyncMaterialInitialized(
        identityToken: credential.identityToken,
        trustedDeviceId: response.trustedDeviceId
      )
      let snapshot = ProductAccountSessionSnapshot(
        appleUserIdentifier: credential.appleUserIdentifier,
        identityToken: credential.identityToken,
        identityTokenExpiresAt: AppleIdentityToken.expirationDate(
          from: credential.identityToken
        ),
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      let previousSnapshot = try? sessionStore.load()
      try sessionStore.save(snapshot)
      do {
        try await clearLocalMailboxConnectionIfProductAccountChanged(
          from: previousSnapshot,
          to: snapshot
        )
      } catch {
        if let previousSnapshot {
          try? sessionStore.save(previousSnapshot)
        }
        throw error
      }
      await unregisterDeviceIfProductAccountChanged(
        from: previousSnapshot,
        to: snapshot
      )
      state = .signedIn(snapshot)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func signOut() async {
    beginSignOut()
    defer {
      isSigningOut = false
      signOutSnapshot = nil
    }
    let snapshot = signOutSnapshot ?? (try? sessionStore.load())
    if let snapshot {
      try? await devicePushUnregistrationService.unregister(session: snapshot)
      guard !signOutSnapshotWasReplaced(snapshot) else { return }
    }
    do {
      var mailboxCleanupError: Error?
      if let snapshot {
        do {
          try await mailboxConnectionService.clearLocalConnection(
            session: snapshot,
            isStillCurrent: {
              !self.signOutSnapshotWasReplaced(snapshot)
            }
          )
        } catch {
          mailboxCleanupError = error
        }
      }
      if let mailboxCleanupError {
        state = .failed(mailboxCleanupError.localizedDescription)
        return
      }
      guard !signOutSnapshotWasReplaced(snapshot) else { return }
      try sessionStore.clear()
      guard
        currentSignedInSnapshot() == nil || currentSignedInSnapshot() == snapshot,
        (try? sessionStore.load()) == nil
      else { return }
      state = .signedOut
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func isCurrent(_ snapshot: ProductAccountSessionSnapshot) -> Bool {
    !isSigningOut && currentSignedInSnapshot() == snapshot
  }

  private func signOutSnapshotWasReplaced(
    _ snapshot: ProductAccountSessionSnapshot?
  ) -> Bool {
    if let currentSnapshot = currentSignedInSnapshot() {
      return currentSnapshot != snapshot
    }
    if let storedSnapshot = try? sessionStore.load() {
      return storedSnapshot != snapshot
    }
    return false
  }

  private func shouldCreateProductSyncMaterialAfterSignIn(
    response: ProductAccountConnectResponse
  ) -> Bool {
    response.accountCreated
      || (!response.productSyncMaterialInitialized && !response.deviceRegistered)
  }

  private func replaceSessionAfterBootstrap(
    _ existingSnapshot: ProductAccountSessionSnapshot,
    with snapshot: ProductAccountSessionSnapshot
  ) async throws {
    try sessionStore.save(snapshot)
    do {
      try await clearLocalMailboxConnectionIfProductAccountChanged(
        from: existingSnapshot,
        to: snapshot
      )
    } catch {
      try? sessionStore.save(existingSnapshot)
      throw error
    }
    await unregisterDeviceIfProductAccountChanged(
      from: existingSnapshot,
      to: snapshot
    )
  }

  private func clearLocalMailboxConnectionIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) async throws {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    try await mailboxConnectionService.clearLocalConnection(session: existingSnapshot)
  }

  private func unregisterDeviceIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) async {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    try? await devicePushUnregistrationService.unregister(session: existingSnapshot)
  }

  private func currentSignedInSnapshot() -> ProductAccountSessionSnapshot? {
    guard case .signedIn(let snapshot) = state else {
      return nil
    }

    return snapshot
  }
}

extension ProductAccountSession {
  func beginSignOut() {
    guard !isSigningOut else { return }
    signOutSnapshot = currentSignedInSnapshot()
    isSigningOut = true
    state = .loading
    clearMailboxFreshnessViewModel()
  }

  func sharedMailboxFreshnessViewModel(
    for snapshot: ProductAccountSessionSnapshot,
    service: MailboxMetadataSyncing
  ) -> MailboxFreshnessViewModel {
    if mailboxFreshnessSession == snapshot, let mailboxFreshnessViewModel {
      return mailboxFreshnessViewModel
    }

    clearMailboxFreshnessViewModel()
    let viewModel = MailboxFreshnessViewModel(
      service: service,
      session: snapshot,
      isSessionCurrent: { self.isCurrent($0) }
    )
    mailboxFreshnessSession = snapshot
    mailboxFreshnessViewModel = viewModel
    return viewModel
  }

  private func clearMailboxFreshnessViewModel() {
    mailboxFreshnessViewModel?.cancelAll()
    mailboxFreshnessSession = nil
    mailboxFreshnessViewModel = nil
  }
}
