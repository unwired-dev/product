import SwiftUI

struct SignInView: View {
  let session: ProductAccountSession
  @State private var isRestoringRecovery = false
  @State private var recoveryKey = ""

  #if DEBUG && !targetEnvironment(macCatalyst)
    @State private var showsAppearance = false
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Unwired Mail")
          .font(.largeTitle.bold())
        Text("Product Account")
          .font(.title2)
          .foregroundStyle(.secondary)
      }

      Text(
        """
        Sign in with Apple to create or resume your Product Account and register \
        this device with the backend using only operational account data.
        """
      )
      .foregroundStyle(.secondary)

      Button {
        Task {
          await session.signInWithApple()
        }
      } label: {
        Label("Sign in with Apple", systemImage: "apple.logo")
          .frame(maxWidth: 320, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)

      if session.requiresProductSyncRecovery {
        VStack(alignment: .leading, spacing: 12) {
          Text("Restore Product Sync")
            .font(.headline)
          Text(
            "Enter the Recovery Key saved from another Trusted Device to restore encrypted data."
          )
          .foregroundStyle(.secondary)
          SecureField("Recovery Key", text: $recoveryKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
          Button("Restore with Recovery Key") {
            Task {
              guard !isRestoringRecovery else { return }
              isRestoringRecovery = true
              defer { isRestoringRecovery = false }
              await session.restoreProductSyncMaterial(recoveryKey: recoveryKey)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(recoveryKey.isEmpty || isRestoringRecovery)
        }
      }

      #if DEBUG && !targetEnvironment(macCatalyst)
        Button {
          showsAppearance = true
        } label: {
          Label("Appearance", systemImage: "paintpalette")
            .frame(maxWidth: 320, minHeight: 44)
        }
        .buttonStyle(.bordered)
      #endif

      if case .failed(let message) = session.state {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    #if DEBUG && !targetEnvironment(macCatalyst)
      .sheet(isPresented: $showsAppearance) {
        SignedOutAppearanceSettings()
      }
    #endif
  }
}

#if DEBUG && !targetEnvironment(macCatalyst)
  private struct SignedOutAppearanceSettings: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        AppearanceSettingsView()
          .navigationTitle("Appearance")
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") {
                dismiss()
              }
            }
          }
      }
    }
  }
#endif

#Preview {
  SignInView(
    session: ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-preview",
          identityToken: "preview-token"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview)
    )
  )
}
