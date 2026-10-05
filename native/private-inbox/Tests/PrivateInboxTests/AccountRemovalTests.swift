import Foundation
import Testing

@testable import PrivateInbox

// Sign-out and Product Account deletion over the real Keychain, with a synthetic backend.
@MainActor private final class SyntheticAccountRemoval {
  let backend = SyntheticProductSyncBackend()
  var deleted: Set<String> = []
  // Accounts that Sign in with Apple also opens.
  var linkedApple: Set<String> = []
  var unregistered: [(identity: ProductSignInIdentity, device: String, installation: String)] = []
  var deletions: [ProductSignInIdentity] = []
  var failure: (any Error)?
  var loseReply = false

  func store(
    _ keys: DeviceKeychain, google: SyntheticGoogleRegistrationProvider,
    apple: SyntheticAppleRegistrationProvider? = nil
  ) -> RegistrationStore {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, apple: apple, productSync: backend.backend,
      removal: AccountRemoval(
        unregister: { [self] identity, product, installation in
          if let failure { throw failure }
          unregistered.append((identity, product.trustedDeviceId, installation))
          if loseReply { throw URLError(.networkConnectionLost) }
        },
        delete: { [self] identity, product in
          if let failure { throw failure }
          deletions.append(identity)
          deleted.insert(product.productAccountId)
          if loseReply { throw URLError(.networkConnectionLost) }
        }),
      connect: { [self] identity, device, _ in
        let account = "account-" + identity.subject
        if deleted.contains(account) { throw RegistrationError.deleted }
        var receipt = backend.receipt(account, device: "device-" + device)
        if linkedApple.contains(account) { receipt.signInProviders = [identity.provider, .apple] }
        return receipt
      })
  }
}

private func removalDevice() -> DeviceKeychain {
  DeviceKeychain(service: "dev.unwired.account-removal.tests.\(UUID().uuidString)")
}

private func removeItems(_ keys: DeviceKeychain, accounts: [String]) {
  try? keys.remove("registration")
  for account in accounts {
    try? keys.remove("product-sync." + account)
    try? keys.remove("product-sync-enrollment." + account)
  }
}

private func holdsNothing(_ keys: DeviceKeychain, account: String) throws -> Bool {
  try keys.read("registration") == nil && keys.read("product-sync." + account) == nil
    && keys.read("product-sync-enrollment." + account) == nil
}

extension PrivateInboxTests {
  @Test @MainActor func interruptedRemovalNeverReopensAccessAndResumesAcknowledgedCleanup()
    async throws
  {
    for provider in [SignInProvider.google, .apple] {
      for operation in [AccountRemovalState.Operation.signOut, .deletion] {
        let keys = removalDevice()
        let google = SyntheticGoogleRegistrationProvider()
        let apple = SyntheticAppleRegistrationProvider()
        let removal = SyntheticAccountRemoval()
        let store = removal.store(keys, google: google, apple: apple)
        let snapshot = try await store.signIn(with: provider)
        let account = try #require(snapshot["productAccountId"])
        defer { removeItems(keys, accounts: [account]) }
        if let key = snapshot["recoveryKey"] {
          _ = try store.confirmRecoveryKey(String(key.suffix(4)))
        }
        let beforeRemoval = try #require(try store.load())
        removal.loseReply = true
        await #expect(throws: URLError.self) {
          if operation == .signOut {
            _ = try await store.signOut()
          } else {
            _ = try await store.deleteAccount()
          }
        }
        // The remote step happened, but a lost reply leaves local cleanup unacknowledged.
        #expect(try !holdsNothing(keys, account: account))
        google.outcome = .cancelled
        apple.outcome = .cancelled
        let relaunched = removal.store(keys, google: google, apple: apple)
        let paused = try await relaunched.purgingIfRevoked { try await $0.restore() }
        #expect(paused["kind"] == "mailbox-needed")
        #expect(paused["privateSync"] == "unavailable")
        #expect(paused["recoveryKey"] == nil)
        #expect(relaunched.session == nil)
        // Unrelated prompts cannot reopen the device while removal is unresolved.
        #expect(try await relaunched.purgingIfRevoked { try await $0.signIn() } == paused)

        google.outcome = nil
        apple.outcome = nil
        removal.loseReply = false
        let done = try await relaunched.purgingIfRevoked(
          {
            if operation == .signOut { return try await $0.signOut() }
            return try await $0.deleteAccount()
          }, removing: operation)
        #expect(done["kind"] == "signed-out")
        #expect(try holdsNothing(keys, account: account))

        // Model a crash after acknowledgement and vault deletion, before enrollment/registration
        // cleanup. Relaunch must finish without renewing an identity or asking a provider.
        var saved = beforeRemoval
        saved.accountRemoval = AccountRemovalState(operation: operation, acknowledged: true)
        try store.save(saved)
        try keys.save(Data("pending approval".utf8), account: store.enrollmentAccount(account))
        google.outcome = .cancelled
        apple.outcome = .cancelled
        let cleaned = try await removal.store(keys, google: google, apple: apple).restore()
        #expect(
          cleaned
            == (operation == .deletion
              ? ["kind": "signed-out", "notice": "deleted"] : ["kind": "signed-out"]))
        #expect(try holdsNothing(keys, account: account))
      }
    }
  }

  @Test @MainActor func signingOutUnregistersFirstAndAnotherAccountSeesNothingOfTheLast()
    async throws
  {
    let keys = removalDevice()
    let first = "account-synthetic-product-subject"
    let second = "account-synthetic-other-subject"
    defer { removeItems(keys, accounts: [first, second]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let removal = SyntheticAccountRemoval()
    _ = try await removal.store(keys, google: google).signIn()
    let connected = try await removal.store(keys, google: google).authorizeGmail(reselect: false)
    let recoveryKey = try #require(connected["recoveryKey"])
    #expect(connected["privateSyncMailboxes"] == "same@example.invalid")
    let installation = try #require(try removal.store(keys, google: google).load())
      .deviceIdentifier

    // Signing out cannot discard the only Recovery Key before its backup is confirmed.
    #expect(try await removal.store(keys, google: google).signOut()["recoveryKey"] == recoveryKey)
    #expect(removal.unregistered.isEmpty)
    _ = try removal.store(keys, google: google).confirmRecoveryKey(String(recoveryKey.suffix(4)))

    // Offline, sign-out changes nothing and can be retried.
    removal.failure = URLError(.notConnectedToInternet)
    await #expect(throws: URLError.self) {
      try await removal.store(keys, google: google).signOut()
    }
    #expect(try !holdsNothing(keys, account: first))
    removal.failure = nil

    #expect(try await removal.store(keys, google: google).signOut() == ["kind": "signed-out"])
    #expect(removal.unregistered.count == 1)
    #expect(removal.unregistered.first?.identity.subject == "synthetic-product-subject")
    #expect(removal.unregistered.first?.installation == installation)
    #expect(removal.unregistered.first?.device == "device-" + installation)
    #expect(removal.deletions.isEmpty)
    #expect(try holdsNothing(keys, account: first))
    #expect(try await removal.store(keys, google: google).restore() == ["kind": "signed-out"])

    // Another Product Account on this device gets none of the previous account's data.
    google.subject = "synthetic-other-subject"
    let other = try await removal.store(keys, google: google).signIn()
    #expect(other["productAccountId"] == second)
    #expect(other["privateSyncMailboxes"] == nil)
    #expect(other["recoveryKey"] != recoveryKey)
    #expect(try removal.store(keys, google: google).loadVault(first) == nil)
  }

  @Test @MainActor func appleSignOutAsksAppleAgainForTheSameIdentity() async throws {
    let keys = removalDevice()
    let account = "account-synthetic-apple-subject"
    defer { removeItems(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let removal = SyntheticAccountRemoval()
    _ = try await removal.store(keys, google: google, apple: apple).signIn(with: .apple)
    let key = try #require(
      removal.store(keys, google: google, apple: apple).loadVault(account)?.recoveryKey)
    _ = try removal.store(keys, google: google, apple: apple).confirmRecoveryKey(
      String(try RecoveryKey(bytes: key).display.suffix(4)))

    apple.outcome = .cancelled
    await #expect(throws: RegistrationError.cancelled) {
      try await removal.store(keys, google: google, apple: apple).signOut()
    }
    apple.outcome = nil
    apple.subject = "another-apple-subject"
    await #expect(throws: RegistrationError.invalidIdentity) {
      try await removal.store(keys, google: google, apple: apple).signOut()
    }
    #expect(removal.unregistered.isEmpty)
    #expect(try !holdsNothing(keys, account: account))

    apple.subject = "synthetic-apple-subject"
    let signIns = apple.signIns
    #expect(
      try await removal.store(keys, google: google, apple: apple).signOut()
        == ["kind": "signed-out"])
    #expect(apple.signIns == signIns + 1)
    #expect(removal.unregistered.first?.identity.provider == .apple)
    #expect(try holdsNothing(keys, account: account))
  }

  @Test @MainActor func deletionNeedsAFreshSignInAndEveryReachableDevicePurges() async throws {
    let current = removalDevice()
    let other = removalDevice()
    let linked = removalDevice()
    let account = "account-synthetic-product-subject"
    let linkedAccount = "account-synthetic-linked-subject"
    defer {
      for keys in [current, other, linked] {
        removeItems(keys, accounts: [account, linkedAccount])
      }
    }
    let google = SyntheticGoogleRegistrationProvider()
    let apple = SyntheticAppleRegistrationProvider()
    let removal = SyntheticAccountRemoval()
    func perform(
      _ keys: DeviceKeychain, removing: AccountRemovalState.Operation? = nil,
      _ operation: (RegistrationStore) async throws -> [String: String]
    ) async throws -> [String: String] {
      try await removal.store(keys, google: google, apple: apple).purgingIfRevoked(
        operation, removing: removing)
    }
    _ = try await perform(current) { try await $0.signIn() }
    _ = try await perform(other) { try await $0.signIn() }

    // A cancelled sign-in or a request that cannot reach Convex deletes nothing.
    google.outcome = .cancelled
    await #expect(throws: RegistrationError.cancelled) {
      try await perform(current, removing: .deletion) { try await $0.deleteAccount() }
    }
    google.outcome = nil
    removal.failure = URLError(.networkConnectionLost)
    await #expect(throws: URLError.self) {
      try await perform(current, removing: .deletion) { try await $0.deleteAccount() }
    }
    removal.failure = nil
    #expect(removal.deletions.isEmpty)
    #expect(try !holdsNothing(current, account: account))

    // Google deletion is confirmed by an interactive sign-in, not a silent renewal.
    let sessions = google.hints.count
    #expect(
      try await perform(current, removing: .deletion) { try await $0.deleteAccount() }
        == ["kind": "signed-out", "notice": "deleted"])
    #expect(google.hints.count == sessions + 1)
    #expect(removal.deletions.last?.provider == .google)
    #expect(removal.deletions.last?.authorizationCode == nil)
    #expect(try holdsNothing(current, account: account))

    // Another device of the account purges when it next reaches Convex.
    #expect(
      try await perform(other) { try await $0.restore() }
        == ["kind": "signed-out", "notice": "deleted"])
    #expect(try holdsNothing(other, account: account))
    // Signing in again finds the account deleted and keeps nothing.
    #expect(
      try await perform(current) { try await $0.signIn() }
        == ["kind": "signed-out", "notice": "deleted"])
    #expect(try holdsNothing(current, account: account))

    // An account Sign in with Apple also opens is deleted through Apple, with its code.
    google.subject = "synthetic-linked-subject"
    removal.linkedApple.insert(linkedAccount)
    _ = try await perform(linked) { try await $0.signIn() }
    let signIns = apple.signIns
    #expect(
      try await perform(linked, removing: .deletion) { try await $0.deleteAccount() }
        == ["kind": "signed-out", "notice": "deleted"])
    #expect(apple.signIns == signIns + 1)
    #expect(removal.deletions.last?.provider == .apple)
    #expect(removal.deletions.last?.authorizationCode == "synthetic-apple-code-\(apple.signIns)")
    #expect(try holdsNothing(linked, account: linkedAccount))
  }
}
