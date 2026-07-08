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

  init(
    appleSignInService: AppleSignInPerforming,
    productAccountService: ProductAccountConnecting = ConvexProductAccountService(),
    sessionStore: ProductAccountSessionPersisting = KeychainProductAccountSessionStore()
  ) {
    self.appleSignInService = appleSignInService
    self.productAccountService = productAccountService
    self.sessionStore = sessionStore
  }

  func bootstrap() async {
    state = .loading

    do {
      if let snapshot = try sessionStore.load() {
        let credential = try await appleSignInService.restoreSession(
          appleUserIdentifier: snapshot.appleUserIdentifier
        )
        let response = try await productAccountService.connect(
          identityToken: credential.identityToken
        )
        let refreshedSnapshot = ProductAccountSessionSnapshot(
          appleUserIdentifier: credential.appleUserIdentifier,
          identityToken: credential.identityToken,
          productAccountId: response.productAccountId,
          trustedDeviceId: response.trustedDeviceId
        )
        try sessionStore.save(refreshedSnapshot)
        state = .signedIn(refreshedSnapshot)
        return
      }
    } catch {
      try? sessionStore.clear()
      state = .signedOut
      return
    }

    state = .signedOut
  }

  func signInWithApple() async {
    state = .loading

    do {
      let credential = try await appleSignInService.signIn()
      let response = try await productAccountService.connect(
        identityToken: credential.identityToken
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
    try? sessionStore.clear()
    state = .signedOut
  }
}
