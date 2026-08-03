import SwiftUI

struct RootView<SignedInContent: View>: View {
  let session: ProductAccountSession
  private let signedInContent: (ProductAccountSessionSnapshot) -> SignedInContent

  init(
    session: ProductAccountSession,
    @ViewBuilder signedInContent: @escaping (ProductAccountSessionSnapshot) -> SignedInContent
  ) {
    self.session = session
    self.signedInContent = signedInContent
  }

  var body: some View {
    Group {
      switch session.state {
      case .loading:
        ProgressView("Loading account...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .signedOut, .failed:
        SignInView(session: session)
      case .signedIn(let snapshot):
        signedInContent(snapshot)
      }
    }
    .task {
      await session.bootstrap()
    }
  }
}

extension RootView where SignedInContent == AccountView {
  init(session: ProductAccountSession) {
    self.init(session: session) { snapshot in
      AccountView(session: session, snapshot: snapshot)
    }
  }
}

#Preview {
  RootView(
    session: ProductAccountSession(
      appleSignInService: SignInWithAppleService(),
      productAccountService: ConvexProductAccountService()
    )
  )
}
