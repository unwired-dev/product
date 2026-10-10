import Foundation
import Testing

@testable import PrivateInbox

// The sequencing of sign-out and Product Account deletion moved to TypeScript
// (packages/mail-core/test/registration-flow.test.ts). Each retired flow test names its replacement:
// - interruptedRemovalNeverReopensAccessAndResumesAcknowledgedCleanup: "never reopens … access during
//   an unanswered … and resumes acknowledged cleanup" and "keeps a … deletion pending when a retry
//   is refused before fencing anything"
// - signingOutUnregistersFirstAndAnotherAccountSeesNothingOfTheLast: "signs out only after
//   unregistering and never before the Recovery Key is backed up", plus purge below
// - appleSignOutAsksAppleAgainForTheSameIdentity: "asks Apple again for the same identity before
//   signing out"
// - expiredPendingDeviceDeletesWithExistingProofOrRenewsMissingProof: "deletes from an expired
//   Pending Device with its existing proof" and "renews a missing Pending Device proof before
//   recording deletion intent"
// - deletionNeedsAFreshSignInAndEveryReachableDevicePurges: "deletes only after a fresh sign-in and
//   purges every device that reaches the account"
// Native code keeps the Keychain work: recording removal intent, protecting the Recovery Key and
// purging everything the device held.

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
  @Test(arguments: ["signed-out", "deleted", "revoked"]) @MainActor
  func purgingKeepsNothingOfTheProductAccount(_ notice: String) async throws {
    let keys = removalDevice()
    let account = "account-synthetic-product-subject"
    defer { removeItems(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    google.scopes = [RegistrationStore.gmailScope]
    let store = SyntheticProductSyncBackend().store(keys: keys, google: google)
    _ = try await store.signIn()
    #expect(try await store.authorizeGmail()["kind"] == "connected")
    try keys.save(Data("pending approval".utf8), account: store.enrollmentAccount(account))
    #expect(try keys.read("product-sync." + account) != nil)
    try await store.purge(notice: notice)
    #expect(try holdsNothing(keys, account: account))
    #expect(store.session == nil)
    #expect(store.identity == nil)
    #expect(store.mailboxAuthorization == nil)
    #expect(store.verifiedMailboxes.isEmpty)
    #expect(try store.registration() == nil)
  }

  @Test @MainActor func signOutPreparationProtectsTheRecoveryKeyAndRecordsIntent() async throws {
    let keys = removalDevice()
    let account = "account-synthetic-product-subject"
    defer { removeItems(keys, accounts: [account]) }
    let google = SyntheticGoogleRegistrationProvider()
    let store = SyntheticProductSyncBackend().store(keys: keys, google: google)
    let shown = try #require(try await store.signIn()["recoveryKey"])
    _ = try await store.signInIdentity(.google, hint: true)
    // Signing out cannot discard the only Recovery Key before its backup is confirmed.
    #expect(try await store.prepareSignOut() == false)
    _ = try store.flowConfirmRecoveryKey(String(shown.suffix(4)))
    #expect(try await store.prepareSignOut() == true)
    // Another identity cannot sign this account out.
    google.subject = "synthetic-other-subject"
    _ = try await store.signInIdentity(.google, hint: false)
    await #expect(throws: RegistrationError.invalidIdentity) { try await store.prepareSignOut() }
    // Removal intent is recorded before the backend request and can be withdrawn after a refusal.
    #expect(throws: RegistrationError.unavailable) { try store.recordRemoval(.revoked) }
    try store.recordRemoval(.signOut)
    #expect(try store.load()?.accountRemoval?.operation == .signOut)
    #expect(try store.load()?.accountRemoval?.acknowledged == false)
    #expect(
      (try store.registration()?["removal"] as? [String: Any])?["operation"] as? String
        == "signOut")
    try store.recordRemoval(nil)
    #expect(try store.load()?.accountRemoval == nil)
    #expect(try keys.read("product-sync." + account) != nil)
  }
}
