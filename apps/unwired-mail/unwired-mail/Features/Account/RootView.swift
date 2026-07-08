import SwiftUI

struct RootView: View {
  @State private var session = ProductAccountSession(
    appleSignInService: SignInWithAppleService(),
    productAccountService: ConvexProductAccountService()
  )

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
      }
    }
    .task {
      await session.bootstrap()
    }
  }
}

#Preview {
  RootView()
}
