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
  private let productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    appleSignInService: AppleSignInPerforming,
    productAccountService: ProductAccountConnecting = ConvexProductAccountService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore(),
    productSyncKeyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore()
  ) {
    self.appleSignInService = appleSignInService
    self.productAccountService = productAccountService
    self.sessionStore = sessionStore
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
        productAccountId: response.productAccountId
      )
      let refreshedSnapshot = ProductAccountSessionSnapshot(
        appleUserIdentifier: credential.appleUserIdentifier,
        identityToken: credential.identityToken,
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      try sessionStore.save(refreshedSnapshot)
      state = .signedIn(refreshedSnapshot)
    } catch let error as AppleSignInError {
      switch error {
      case .notAuthorized:
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
        productAccountId: response.productAccountId
      )
      let snapshot = ProductAccountSessionSnapshot(
        appleUserIdentifier: credential.appleUserIdentifier,
        identityToken: credential.identityToken,
        productAccountId: response.productAccountId,
        trustedDeviceId: response.trustedDeviceId
      )
      try sessionStore.save(snapshot)
      state = .signedIn(snapshot)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func signOut() {
    do {
      try sessionStore.clear()
      state = .signedOut
    } catch {
      state = .failed(error.localizedDescription)
    }
  }
}
