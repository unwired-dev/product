import SwiftUI

struct RootView: View {
  let session: ProductAccountSession

  var body: some View {
    Group {
      switch session.state {
      case .loading:
        ProgressView("Loading account...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .signedOut, .failed:
        SignInView(session: session)
      case .signedIn(let snapshot):
        AccountView(session: session, snapshot: snapshot)
          .id(snapshot.identityToken)
      }
    }
    .task {
      await session.bootstrap()
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
