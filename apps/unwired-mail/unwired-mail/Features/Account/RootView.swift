import SwiftUI

struct RootView<SignedInContent: View>: View {
  let session: ProductAccountSession
  private let signedInContent: (ProductAccountSessionSnapshot) -> SignedInContent

  @Environment(SettingsRouter.self) private var settingsRouter
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var navigationPath = NavigationPath()
  @State private var regularSettingsRequest: SettingsRouteRequest?
  @State private var settingsMailProfileContext = SettingsMailProfileContext()
  @State private var settingsPresentationOwnerID = UUID()

  init(
    session: ProductAccountSession,
    @ViewBuilder signedInContent: @escaping (ProductAccountSessionSnapshot) -> SignedInContent
  ) {
    self.session = session
    self.signedInContent = signedInContent
  }

  var body: some View {
    #if targetEnvironment(macCatalyst)
      accountContent
    #else
      Group {
        if usesCompactSettingsNavigation, !isSignedIn {
          NavigationStack(path: $navigationPath) {
            accountContent
              .navigationDestination(for: SettingsRouteRequest.self) { _ in
                SettingsRootView(
                  session: session,
                  usesParentCompactNavigation: true
                )
              }
          }
        } else if regularSettingsRequest != nil {
          SettingsRootView(
            session: session,
            showsDismissButton: true,
            dismissAction: { regularSettingsRequest = nil }
          )
        } else {
          accountContent
        }
      }
      .onAppear(perform: presentPendingSettingsRequest)
      .onChange(of: settingsRouter.request?.id) { _, _ in
        presentPendingSettingsRequest()
      }
      .environment(settingsMailProfileContext)
    #endif
  }

  private var accountContent: some View {
    Group {
      switch session.state {
      case .loading:
        ProgressView("Loading account...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .signedOut, .failed:
        SignInView(session: session)
      case .signedIn(let snapshot):
        signedInContent(snapshot)
          .id(snapshot.productAccountId)
      }
    }
    .background(MailTheme.canvas)
    .task {
      await session.bootstrap()
    }
  }

  private func presentPendingSettingsRequest() {
    guard
      let request = settingsRouter.request,
      !(usesCompactSettingsNavigation && isSignedIn),
      settingsRouter.claimPresentation(request.id, ownerID: settingsPresentationOwnerID)
    else { return }
    if usesCompactSettingsNavigation {
      navigationPath = NavigationPath()
      navigationPath.append(request)
    } else {
      regularSettingsRequest = request
    }
  }

  private var isSignedIn: Bool {
    if case .signedIn = session.state { return true }
    return false
  }

  private var usesCompactSettingsNavigation: Bool {
    return SettingsNavigationLayout.resolve(horizontalSizeClass) == .compact
  }
}

extension RootView where SignedInContent == AccountView {
  @MainActor
  init(
    session: ProductAccountSession,
    profileDeepLinkRouter: MailProfileDeepLinkRouter
  ) {
    self.init(session: session) { snapshot in
      AccountView(
        session: session,
        snapshot: snapshot,
        profileDeepLinkRouter: profileDeepLinkRouter
      )
    }
  }
}

#Preview {
  RootView(
    session: ProductAccountSession(
      appleSignInService: SignInWithAppleService(),
      productAccountService: ConvexProductAccountService()
    ),
    profileDeepLinkRouter: MailProfileDeepLinkRouter()
  )
}
