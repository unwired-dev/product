import SwiftUI

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Unwired Mail")
          .font(.largeTitle.bold())
        Text("Product Account")
          .font(.title2)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Label("Signed in with Apple", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.headline)
        Text("Product account: \(snapshot.productAccountId)")
        Text("Trusted device: \(snapshot.trustedDeviceId)")
          .foregroundStyle(.secondary)
      }

      SmokeView(service: ConvexBackendHealthService())

      Button("Sign Out", role: .destructive) {
        session.signOut()
      }
      .buttonStyle(.bordered)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

#Preview {
  AccountView(
    session: ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-preview",
          identityToken: "preview-token"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview)
    ),
    snapshot: ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-preview",
      identityToken: "preview-token",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
  )
}
