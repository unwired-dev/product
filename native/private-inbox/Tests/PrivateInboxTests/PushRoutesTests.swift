import Foundation
import Testing

@testable import PrivateInbox

// Convex's push relay as the vault calls it: device registration, Gmail connection proofs, watch
// verification and route removal, each under the Trusted Device proof.
@MainActor private final class SyntheticRelay {
  var requests: [(endpoint: BackendRequest.Endpoint, path: String, args: [String: Any])] = []
  var verified = true
  var stopsWatch = true
  var remainingConnections = false
  // Paths that cannot reach Convex.
  var unreachable: Set<String> = []
  // A Convex error code every call is refused with.
  var refusal: String?

  func send(_ request: BackendRequest) throws -> (Int, Data) {
    requests.append((request.endpoint, request.path, request.args))
    if unreachable.contains(request.path) { throw URLError(.notConnectedToInternet) }
    if let refusal {
      return (200, try reply(["status": "error", "errorData": ["code": refusal]]))
    }
    let value: Any =
      switch request.path {
      case "pushRelay:verifyGmailWatch":
        ["routeId": "route-" + (request.args["opaqueConnectionId"] as? String ?? ""), "verified": verified]
      case "pushRelay:shouldStopGmailWatch": stopsWatch
      case "pushRelay:removeGmailConnection":
        ["hasRemainingGmailConnections": remainingConnections, "removed": true]
      default: ["registered": request.path == "pushRelay:registerDevice"]
      }
    return (200, try reply(["status": "success", "value": value]))
  }

  private func reply(_ body: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: body)
  }
}

@MainActor private func pushDevice(
  sync: SyntheticProductSyncBackend? = nil, microsoft: (any MicrosoftMailProvider)? = nil
) -> (
  RegistrationStore, SyntheticGoogleRegistrationProvider, SyntheticRelay, DeviceKeychain
) {
  let keys = DeviceKeychain(service: "dev.unwired.push.tests.\(UUID().uuidString)")
  let google = SyntheticGoogleRegistrationProvider()
  google.scopes = [RegistrationStore.gmailScope]
  let relay = SyntheticRelay()
  let store = RegistrationStore(
    keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
    provider: google, microsoft: microsoft, productSync: sync?.backend,
    transport: { request in
      if let sync, request.path.hasPrefix("productSync:") { return try sync.transport(request) }
      return try relay.send(request)
    },
    connect: { identity, installation, _ in
      if let sync { return try sync.connect("account-" + identity.subject, device: installation) }
      return ProductRegistrationReceipt(
        productAccountId: "account-" + identity.subject, trustedDeviceId: "synthetic-device",
        trustedDeviceCredential: String(repeating: "a", count: 64))
    })
  store.wakes = PushWakes(deadline: .milliseconds(50))
  return (store, google, relay, keys)
}

private let topic = "projects/synthetic-project/topics/gmail-push"
private let device = PushDevice(token: "0a1b2c", environment: "sandbox")
private let subject = "synthetic-product-subject"
private let relayConnection = RegistrationStore.relayConnection(
  account: "account-" + subject, subject: subject)

private func watch(historyId: String, expiration: Double) -> (Int, Data) {
  (200, Data(#"{"historyId":"\#(historyId)","expiration":"\#(Int(expiration))"}"#.utf8))
}

extension PrivateInboxTests {
  @Test @MainActor func routesEachVerifiedMailboxAndRenewsItsWatchBeforeGmailEndsIt() async throws {
    let (store, google, relay, keys) = pushDevice()
    defer { try? keys.remove("registration") }
    _ = try await store.signIn()
    #expect(try await store.authorizeGmail()["kind"] == "connected")
    let id = MailboxConnection.id(subject: subject)
    let expiration = 1_000_000_000.0
    google.gmailResponse = watch(historyId: "4242", expiration: expiration)

    // Without a configured topic or an APNs registration, nothing reaches the relay or Gmail.
    try await store.routeMailboxes(device: nil, topic: topic, now: 0)
    try await store.routeMailboxes(device: device, topic: nil, now: 0)
    #expect(relay.requests.isEmpty)
    #expect(google.gmailRequests.isEmpty)

    // First-launch routing already ran without a device; the later token must create its routes.
    try await store.pushDeviceChanged(device: device, topic: topic, now: 0)
    #expect(
      relay.requests.map(\.path) == [
        "pushRelay:registerDevice", "pushRelay:registerGmailConnection",
        "pushRelay:verifyGmailWatch",
      ])
    #expect(relay.requests.map(\.endpoint) == [.mutation, .action, .action])
    for request in relay.requests {
      #expect(request.args["trustedDeviceId"] as? String == "synthetic-device")
      #expect(request.args["trustedDeviceCredential"] as? String == String(repeating: "a", count: 64))
    }
    #expect(relay.requests[0].args["apnsToken"] as? String == "0a1b2c")
    #expect(relay.requests[0].args["apnsEnvironment"] as? String == "sandbox")
    #expect(relay.requests[1].args["gmailIdentityToken"] as? String == "synthetic-id-token-" + subject)
    #expect(relay.requests[1].args["opaqueConnectionId"] as? String == relayConnection)
    #expect(relay.requests[2].args["historyId"] as? String == "4242")
    #expect(relay.requests[2].args["opaqueConnectionId"] as? String == relayConnection)
    // The watch covers the Inbox alone, published to the configured topic.
    #expect(google.gmailRequests == [URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/watch")!])
    let body = try #require(google.gmailBodies.last.flatMap { $0 })
    let request = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(request["labelIds"] as? [String] == ["INBOX"])
    #expect(request["labelFilterBehavior"] as? String == "include")
    #expect(request["topicName"] as? String == topic)

    let route = "route-" + relayConnection
    #expect(try store.mailboxRoutes(now: 0)["routes"] as? [String: String] == [route: id])
    #expect(try store.mailboxRoutes(now: 0)["complete"] as? Bool == true)
    // The device keeps the opaque route and expiry, never Gmail's history ID or identity token.
    let record = String(decoding: try #require(try keys.read("registration")), as: UTF8.self)
    #expect(record.contains(route))
    #expect(!record.contains("4242"))
    #expect(!record.contains("synthetic-id-token"))

    // A current route needs nothing more.
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    #expect(relay.requests.count == 3)

    // Within a day of Gmail ending it, the watch renews with the relay's record of this device.
    let renewal = expiration - 3_600_000
    #expect(try store.mailboxRoutes(now: renewal)["complete"] as? Bool == false)
    google.gmailResponse = watch(historyId: "4343", expiration: expiration * 2)
    try await store.routeMailboxes(device: device, topic: topic, now: renewal)
    #expect(
      relay.requests.dropFirst(3).map(\.path) == [
        "pushRelay:registerDevice", "pushRelay:registerGmailConnection",
        "pushRelay:verifyGmailWatch",
      ])
    #expect(try store.mailboxRoutes(now: expiration)["routes"] as? [String: String] == [route: id])
    // An expired watch's route wakes nothing.
    #expect(try store.mailboxRoutes(now: expiration * 2)["routes"] as? [String: String] == [:])

    // A pending Pub/Sub proof keeps its route usable for late wakes but never suppresses polling.
    let pending = expiration * 2 - 3_600_000
    relay.verified = false
    google.gmailResponse = watch(historyId: "4545", expiration: expiration * 3)
    try await store.routeMailboxes(device: device, topic: topic, now: pending)
    #expect(try store.mailboxRoutes(now: pending)["routes"] as? [String: String] == [route: id])
    #expect(try store.mailboxRoutes(now: pending)["complete"] as? Bool == false)
    relay.verified = true
    try await store.routeMailboxes(device: device, topic: topic, now: pending)
    #expect(try store.mailboxRoutes(now: pending)["complete"] as? Bool == true)

    // An unreachable relay waits for a later verification; only the end of access fails routing.
    let due = expiration * 3 - 3_600_000
    relay.unreachable = ["pushRelay:registerDevice", "pushRelay:registerGmailConnection"]
    try await store.routeMailboxes(device: device, topic: topic, now: due)
    #expect(try store.mailboxRoutes(now: due)["complete"] as? Bool == false)
    relay.unreachable = []
    relay.refusal = "TRUSTED_DEVICE_REVOKED"
    await #expect(throws: RegistrationError.revoked) {
      try await store.routeMailboxes(device: device, topic: topic, now: due)
    }

    // Rotation updates existing routes even before this process verifies any mailbox.
    relay.refusal = nil
    relay.requests = []
    google.gmailRequests = []
    store.verifiedMailboxes = []
    let rotated = PushDevice(token: "4d5e6f", environment: "sandbox")
    store.wakes.device = rotated
    #expect(try store.mailboxRoutes(now: 0)["complete"] as? Bool == false)
    try await store.pushDeviceChanged(device: rotated, topic: topic, now: 0)
    #expect(relay.requests.map(\.path) == ["pushRelay:registerDevice"])
    #expect(relay.requests[0].args["apnsToken"] as? String == rotated.token)
    #expect(try store.saved().pushDevice == rotated)
    #expect(google.gmailRequests.isEmpty)
    #expect(try store.mailboxRoutes(now: 0)["routes"] as? [String: String] == [route: id])
    #expect(try store.mailboxRoutes(now: 0)["complete"] as? Bool == true)
    try await store.pushDeviceChanged(device: rotated, topic: topic, now: 0)
    #expect(relay.requests.count == 1)

    // Native-initiated rejection has no JS caller to purge: it must end local access itself.
    for refusal in ["TRUSTED_DEVICE_REVOKED", "PRODUCT_ACCOUNT_DELETED"] {
      relay.refusal = refusal
      try await store.pushDeviceChanged(device: device, topic: topic, now: 0)
      #expect(try keys.read("registration") == nil)
      #expect(store.session == nil)
      #expect(store.verifiedMailboxes.isEmpty)
      #expect(try store.mailboxRoutes(now: 0)["routes"] as? [String: String] == [:])
      let rejection: RegistrationError =
        refusal == "TRUSTED_DEVICE_REVOKED" ? .revoked : .deleted
      // Cleanup must retain the fixed rejection until the shared flow acknowledges its notice.
      #expect(throws: rejection) { try store.registration() }
      #expect(throws: rejection) { try store.registration() }
      try await store.purge(notice: rejection.code)
      #expect(try store.registration() == nil)
      if refusal == "TRUSTED_DEVICE_REVOKED" {
        relay.refusal = nil
        _ = try await store.signIn()
        _ = try await store.authorizeGmail()
        try await store.routeMailboxes(device: rotated, topic: topic, now: 0)
      }
    }
  }

  @Test @MainActor func removingAMailboxStopsItsWatchRemovesItsRouteAndDropsItsWakes() async throws {
    let microsoft = SyntheticMicrosoftMailProvider()
    microsoft.subject = subject
    let (store, google, relay, keys) = pushDevice(microsoft: microsoft)
    defer { try? keys.remove("registration") }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let id = MailboxConnection.id(subject: subject)
    let route = "route-" + relayConnection
    google.gmailResponse = watch(historyId: "1", expiration: 1_000_000_000)
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    var results: [String] = []
    relay.requests = []
    google.gmailRequests = []

    // Another provider can use the same subject; removing it must preserve Gmail's watch and route.
    _ = try await store.signInMailbox(nil, suggest: true, provider: .microsoftGraph)
    let verified = try await store.verifyMailbox()
    let microsoftId = try #require(verified["connection"] as? String)
    try store.storeMailbox()
    let refreshes = google.refreshes
    _ = try await store.flowRemoveMailbox(microsoftId)
    #expect(google.refreshes == refreshes)
    #expect(google.gmailRequests.isEmpty)
    #expect(relay.requests.isEmpty)
    #expect(try store.saved().connection(microsoftId) == nil)
    #expect(try store.saved().connection(id)?.pushVerified == true)
    #expect(try store.saved().pushDevice == device)
    #expect(try store.mailboxRoutes(now: 0)["complete"] as? Bool == true)

    // Its last route ends this device's wakes; a waiting wake for it reads nothing.
    store.wakes.receive(["provider": "gmail", "routeId": route]) { results.append($0) }
    google.gmailResponse = (204, Data())
    _ = try await store.flowRemoveMailbox(id)
    #expect(results == ["ignored"])
    #expect(
      relay.requests.map(\.path) == [
        "pushRelay:shouldStopGmailWatch", "pushRelay:removeGmailConnection",
        "pushRelay:unregisterDevice",
      ])
    #expect(relay.requests[1].args["opaqueConnectionId"] as? String == relayConnection)
    #expect(google.gmailRequests == [URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!])
    #expect(try store.saved().connection(id) == nil)
    #expect(try store.saved().pushDevice == nil)
    #expect(try store.mailboxRoutes(now: 0)["routes"] as? [String: String] == [:])

    // Another device's route still needs the watch, and the relay cannot be reached: removal
    // still completes on this device and its route is removed at the next routing.
    _ = try await store.authorizeGmail()
    google.gmailResponse = watch(historyId: "2", expiration: 1_000_000_000)
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    relay.requests = []
    google.gmailRequests = []
    relay.stopsWatch = false
    relay.unreachable = ["pushRelay:removeGmailConnection"]
    _ = try await store.flowRemoveMailbox(id)
    #expect(google.gmailRequests.isEmpty)
    #expect(try store.saved().connection(id) == nil)
    #expect(try store.saved().pushRouteRemovals == [relayConnection])
    relay.unreachable = []
    relay.requests = []
    try await store.routeMailboxes(device: nil, topic: topic, now: 0)
    #expect(
      relay.requests.map(\.path) == ["pushRelay:removeGmailConnection", "pushRelay:unregisterDevice"])
    #expect(try store.saved().pushRouteRemovals == [])

    // Sign-out and deletion stop each routed watch before the backend removes this device.
    _ = try await store.authorizeGmail()
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    relay.stopsWatch = true
    // Pending removal after relaunch also fences callbacks without an in-memory stop marker.
    let rotated = PushDevice(token: "4d5e6f", environment: "sandbox")
    try store.recordRemoval(.signOut)
    relay.requests = []
    google.gmailRequests = []
    try await store.pushDeviceChanged(device: rotated, topic: topic, now: 0)
    #expect(relay.requests.isEmpty)
    #expect(google.gmailRequests.isEmpty)
    try store.recordRemoval(nil)
    google.gmailRequests = []
    google.gmailResponse = (204, Data())
    try await store.stopMailboxWatches()
    #expect(google.gmailRequests == [URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!])
    // The callback cannot restart that watch between the flow's stop and removal-intent calls.
    relay.requests = []
    google.gmailRequests = []
    try await store.pushDeviceChanged(device: rotated, topic: topic, now: 0)
    #expect(relay.requests.isEmpty)
    #expect(google.gmailRequests.isEmpty)
    #expect(try store.saved().pushDevice == device)
    // A refused sign-out or deletion retains this account: stopped watches must renew immediately.
    #expect(try store.mailboxRoutes(now: 0)["complete"] as? Bool == false)
    google.gmailResponse = watch(historyId: "3", expiration: 1_000_000_000)
    google.gmailRequests = []
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    #expect(google.gmailRequests == [URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/watch")!])
    #expect(try store.mailboxRoutes(now: 0)["complete"] as? Bool == true)
    // Purging drops every waiting wake.
    store.wakes.receive(["provider": "gmail", "routeId": route]) { results.append($0) }
    try await store.purge(notice: "signed-out")
    #expect(results == ["ignored", "ignored"])
  }

  @Test @MainActor func failedWatchVerificationStillCleansUpItsRegistration() async throws {
    let (store, google, relay, keys) = pushDevice()
    defer { try? keys.remove("registration") }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    let id = MailboxConnection.id(subject: subject)
    google.gmailResponse = watch(historyId: "1", expiration: 1_000_000_000)
    relay.unreachable = ["pushRelay:verifyGmailWatch"]
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    #expect(try store.saved().connection(id)?.pushRoute == nil)
    relay.unreachable = []
    relay.requests = []
    google.gmailRequests = []
    google.gmailResponse = (204, Data())
    // A saved credential naming another mailbox cannot stop that mailbox's watch.
    var saved = try store.saved()
    let credential = try #require(saved.connection(id)?.credential)
    saved.update(id) { $0.credential = google.value("synthetic-other-subject").credential }
    try store.save(saved)
    try await store.stopMailboxWatches()
    #expect(google.gmailRequests.isEmpty)
    saved = try store.saved()
    saved.update(id) { $0.credential = credential }
    try store.save(saved)
    try await store.stopMailboxWatches()
    #expect(google.gmailRequests == [URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!])
    relay.requests = []
    _ = try await store.flowRemoveMailbox(id)
    #expect(relay.requests.map(\.path) == [
      "pushRelay:shouldStopGmailWatch", "pushRelay:removeGmailConnection", "pushRelay:unregisterDevice",
    ])
    #expect(try store.saved().pushDevice == nil)
  }

  @Test @MainActor func offlineRemovalDefersRelayDeletionUntilItsTombstoneIsAcknowledged() async throws {
    let backend = SyntheticProductSyncBackend()
    let (store, google, relay, keys) = pushDevice(sync: backend)
    let account = "account-" + subject
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? keys.remove("product-sync-enrollment." + account)
    }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    google.gmailResponse = watch(historyId: "1", expiration: 1_000_000_000)
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    let id = MailboxConnection.id(subject: subject)
    let ring = try #require(try store.loadVault(account)).ring
    let identifier = try ring.identifier("mailbox", "gmail:" + subject)
    backend.offline = true
    relay.requests = []
    google.gmailResponse = (204, Data())
    _ = try await store.flowRemoveMailbox(id)
    #expect(try store.saved().connection(id) == nil)
    #expect(try store.saved().mailboxRemovals?.count == 1)
    #expect(try store.saved().pushRouteRemovals == [relayConnection])
    #expect(relay.requests.map(\.path) == ["pushRelay:shouldStopGmailWatch"])
    // A routing retry cannot delete before the pending removal has reached Product Sync.
    try await store.routeMailboxes(device: nil, topic: nil, now: 0)
    #expect(relay.requests.map(\.path) == ["pushRelay:shouldStopGmailWatch"])
    // Once Product Sync records the tombstone, the queued cleanup runs, even with no mailbox or
    // topic left. TypeScript marks the tombstone (packages/mail-core/test/product-sync.test.ts).
    try store.recordMailboxChanges(connections: [], settledRemovals: [identifier])
    #expect(try store.saved().mailboxRemovals == nil)
    try await store.removeQueuedPushRoutes()
    #expect(relay.requests.map(\.path) == [
      "pushRelay:shouldStopGmailWatch", "pushRelay:removeGmailConnection", "pushRelay:unregisterDevice",
    ])
    #expect(try store.saved().pushRouteRemovals == [])
    #expect(try store.saved().pushDevice == nil)
  }

  @Test @MainActor func synchronizedRemovalStopsTheWatchBeforeDiscardingItsCredential() async throws {
    let backend = SyntheticProductSyncBackend()
    let (store, google, relay, keys) = pushDevice(sync: backend)
    let account = "account-" + subject
    defer {
      try? keys.remove("registration")
      try? keys.remove("product-sync." + account)
      try? keys.remove("product-sync-enrollment." + account)
    }
    _ = try await store.signIn()
    _ = try await store.authorizeGmail()
    google.gmailResponse = watch(historyId: "1", expiration: 1_000_000_000)
    try await store.routeMailboxes(device: device, topic: topic, now: 0)
    relay.requests = []
    google.gmailRequests = []
    google.gmailResponse = (204, Data())
    // Another device removed it; synchronization purges the connection here.
    try await store.purgeMailbox(MailboxConnection.id(subject: subject))
    #expect(try store.saved().connections.isEmpty)
    #expect(google.gmailRequests == [URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!])
    #expect(relay.requests.map(\.path) == [
      "pushRelay:shouldStopGmailWatch", "pushRelay:removeGmailConnection", "pushRelay:unregisterDevice",
    ])
    #expect(try store.saved().pushDevice == nil)
    #expect(try store.saved().pushRouteRemovals?.isEmpty != false)
  }

  @Test @MainActor func wakeQueueHandsJavaScriptOnlyTheRouteAndCompletesEachWakeOnce() async throws {
    let wakes = PushWakes(deadline: .milliseconds(50))
    var results: [String] = []
    // Only a Gmail hint naming a route waits for JavaScript.
    wakes.receive(["provider": "microsoft-graph", "routeId": "route-a"]) { results.append($0) }
    wakes.receive(["provider": "gmail"]) { results.append($0) }
    #expect(results == ["ignored", "ignored"])

    wakes.receive([
      "aps": ["content-available": 1], "provider": "gmail", "routeId": "route-a",
      "historyId": "987654321", "emailAddress": "alex@example.invalid",
    ]) { results.append($0) }
    let delivered = try #require(await wakes.next())
    let id = delivered.id
    // Gmail's history ID and the address never reach JavaScript.
    #expect(PushWakes.hint(delivered)["id"] as? String == id)
    #expect(
      PushWakes.hint(delivered)["hint"] as? [String: String]
        == ["provider": "gmail", "routeId": "route-a"])
    wakes.settle(id, "synchronized")
    wakes.settle(id, "failed")
    #expect(results == ["ignored", "ignored", "synchronized"])

    // A reader waits for the next wake; one JavaScript never settles fails at the deadline.
    async let waiting = wakes.next()
    try await Task.sleep(for: .milliseconds(10))
    wakes.receive(["provider": "gmail", "routeId": "route-b"]) { results.append($0) }
    #expect((await waiting)?.route == "route-b")
    try await Task.sleep(for: .milliseconds(150))
    #expect(results == ["ignored", "ignored", "synchronized", "failed"])

    // A reloaded JavaScript context replaces the earlier reader, which receives nothing.
    async let replaced = wakes.next()
    try await Task.sleep(for: .milliseconds(10))
    async let current = wakes.next()
    try await Task.sleep(for: .milliseconds(10))
    #expect(await replaced == nil)
    wakes.receive(["provider": "gmail", "routeId": "route-c"]) { results.append($0) }
    #expect((await current)?.route == "route-c")

    // A development profile selects the APNs sandbox; a build without one uses production.
    #expect(PushDevice(token: Data([0x0a, 0xff])) == PushDevice(token: "0aff", environment: "production"))
  }
}
