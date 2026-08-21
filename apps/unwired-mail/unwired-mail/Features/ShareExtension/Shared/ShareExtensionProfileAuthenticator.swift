import LocalAuthentication

/// Verifies device ownership before a locked Profile reveals Sending Identities.
@MainActor
protocol ShareExtensionProfileAuthenticating {
  func authenticate(profileName: String) async throws -> Bool
}

/// Uses the system device-owner policy for Profile Lock in the Share Extension.
@MainActor
struct LocalShareExtensionProfileAuthenticator: ShareExtensionProfileAuthenticating {
  func authenticate(profileName: String) async throws -> Bool {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      throw error ?? LAError(.authenticationFailed)
    }
    return try await context.evaluatePolicy(
      .deviceOwnerAuthentication,
      localizedReason: "Unlock \(profileName) before creating a Draft."
    )
  }
}
