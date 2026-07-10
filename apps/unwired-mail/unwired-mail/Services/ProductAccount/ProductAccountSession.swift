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

  private let appleSignInService: AppleSignInPerforming
  private let productAccountService: ProductAccountConnecting
  private let sessionStore: ProductAccountSessionPersisting
  private let gmailProviderConnectionService: GmailProviderConnecting
  private let gmailMessageBodyReader: GmailMessageReading
  private let productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    appleSignInService: AppleSignInPerforming,
    productAccountService: ProductAccountConnecting = ConvexProductAccountService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    gmailProviderConnectionService: GmailProviderConnecting =
      GmailProviderConnectionService(),
    gmailMessageBodyReader: GmailMessageReading = GmailMessageBodyService(),
    productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.appleSignInService = appleSignInService
    self.productAccountService = productAccountService
    self.sessionStore = sessionStore
    self.gmailProviderConnectionService = gmailProviderConnectionService
    self.gmailMessageBodyReader = gmailMessageBodyReader
    self.productSyncKeyMaterialStore = productSyncKeyMaterialStore
  }

  func bootstrap() async {
    state = .loading

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
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      try sessionStore.save(refreshedSnapshot)
      clearLocalGmailConnectionIfProductAccountChanged(
        from: snapshot,
        to: refreshedSnapshot
      )
      state = .signedIn(refreshedSnapshot)
    } catch let error as AppleSignInError {
      switch error {
      case .notAuthorized:
        try? gmailProviderConnectionService.clearLocalConnection(session: snapshot)
        try? sessionStore.clear()
        state = .signedOut
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
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      let previousSnapshot = try? sessionStore.load()
      try sessionStore.save(snapshot)
      clearLocalGmailConnectionIfProductAccountChanged(
        from: previousSnapshot,
        to: snapshot
      )
      state = .signedIn(snapshot)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func signOut() {
    if let snapshot = currentSignedInSnapshot() ?? (try? sessionStore.load()) {
      try? gmailProviderConnectionService.clearLocalConnection(session: snapshot)
      try? gmailMessageBodyReader.clearCachedMessageBodies(session: snapshot)
    }

    do {
      try sessionStore.clear()
      state = .signedOut
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func isCurrent(_ snapshot: ProductAccountSessionSnapshot) -> Bool {
    currentSignedInSnapshot() == snapshot
  }

  private func shouldCreateProductSyncMaterialAfterSignIn(
    response: ProductAccountConnectResponse
  ) -> Bool {
    response.accountCreated
      || (!response.productSyncMaterialInitialized && !response.deviceRegistered)
  }

  private func clearLocalGmailConnectionIfProductAccountChanged(
    from existingSnapshot: ProductAccountSessionSnapshot?,
    to snapshot: ProductAccountSessionSnapshot
  ) {
    guard
      let existingSnapshot,
      existingSnapshot.productAccountId != snapshot.productAccountId
    else {
      return
    }

    try? gmailProviderConnectionService.clearLocalConnection(session: existingSnapshot)
    try? gmailMessageBodyReader.clearCachedMessageBodies(session: existingSnapshot)
  }

  private func currentSignedInSnapshot() -> ProductAccountSessionSnapshot? {
    guard case .signedIn(let snapshot) = state else {
      return nil
    }

    return snapshot
  }
}
