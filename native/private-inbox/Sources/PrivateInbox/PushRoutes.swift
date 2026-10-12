import CryptoKit
import Foundation
import os

// This device's APNs registration, as Convex's relay addresses it.
struct PushDevice: Codable, Equatable {
  let token: String
  // "sandbox" or "production".
  let environment: String

  init(token: String, environment: String) {
    self.token = token
    self.environment = environment
  }

  // A development-signed build carries a provisioning profile granting the APNs sandbox; a
  // distributed build carries none or a production grant.
  init(token: Data, bundle: Bundle = .main) {
    let profile =
      bundle.url(forResource: "embedded", withExtension: "mobileprovision")
      ?? bundle.bundleURL.appending(path: "Contents/embedded.provisionprofile")
    // The signed profile embeds its entitlements as plain XML.
    let sandbox =
      (try? Data(contentsOf: profile)).map {
        String(decoding: $0, as: UTF8.self).range(
          of: #"aps-environment</key>\s*<string>development<"#, options: .regularExpression)
          != nil
      } ?? false
    self.init(
      token: token.map { String(format: "%02x", $0) }.joined(),
      environment: sandbox ? "sandbox" : "production")
  }
}

// Wake hints the host received, waiting for JavaScript to synchronize their routed mailboxes. Only
// a Gmail hint's opaque route is kept; its history ID and any address stay in the system payload.
@MainActor final class PushWakes {
  static let shared = PushWakes()
  // The latest APNs registration this process received.
  var device: PushDevice?

  struct Wake {
    let id: String
    let route: String
    // Receives "synchronized", "ignored" or "failed" exactly once.
    let complete: (String) -> Void
  }
  private var queued: [Wake] = []
  private var delivered: [String: Wake] = [:]
  private var reader: CheckedContinuation<(id: String, route: String)?, Never>?
  let deadline: Duration

  // iOS allows about 30 seconds for a background notification.
  init(deadline: Duration = .seconds(25)) { self.deadline = deadline }

  func receive(_ payload: [AnyHashable: Any], complete: @escaping (String) -> Void) {
    guard payload["provider"] as? String == "gmail", let route = payload["routeId"] as? String,
      !route.isEmpty
    else { return complete("ignored") }
    let wake = Wake(id: UUID().uuidString, route: route, complete: complete)
    Task {
      try? await Task.sleep(for: deadline)
      settle(wake.id, "failed")
    }
    if let reader {
      self.reader = nil
      delivered[wake.id] = wake
      reader.resume(returning: (wake.id, wake.route))
    } else {
      queued.append(wake)
    }
  }

  // The next wake for JavaScript. A reloaded JavaScript context replaces the earlier reader.
  func next() async -> (id: String, route: String)? {
    if !queued.isEmpty {
      let wake = queued.removeFirst()
      delivered[wake.id] = wake
      return (wake.id, wake.route)
    }
    reader?.resume(returning: nil)
    return await withCheckedContinuation { reader = $0 }
  }

  func settle(_ id: String, _ result: String) {
    if let wake = delivered.removeValue(forKey: id) {
      wake.complete(result)
    } else if let index = queued.firstIndex(where: { $0.id == id }) {
      queued.remove(at: index).complete(result)
    }
  }

  // Waiting wakes for routes this device no longer has read nothing; nil drops every route's.
  func drop(_ routes: Set<String>?) {
    let dropped = queued.filter { routes?.contains($0.route) ?? true }
    queued.removeAll { routes?.contains($0.route) ?? true }
    for wake in dropped { wake.complete("ignored") }
  }

  // What JavaScript reads of a wake.
  static func hint(_ wake: (id: String, route: String)) -> [String: Any] {
    ["id": wake.id, "hint": ["provider": "gmail", "routeId": wake.route]]
  }
}

// Content-free Gmail push. Each verified Mailbox Connection keeps a Gmail watch on its Inbox and the
// opaque route Convex's relay returned for it. Gmail's history ID, the mailbox's identity token and
// its address exist only in the requests that need them.
extension RegistrationStore {
  // Gmail watches last seven days; each renews within a day of expiring.
  static let watchRenewal: Double = 86_400_000
  private static let logger = Logger(subsystem: "dev.unwired.mail", category: "push")
  // Never JavaScript's: its Gmail reads are limited to `gmailURL`'s resources.
  private static let watchURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/watch")!
  private static let stopURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!

  // Convex's opaque name for a Google account's connection in this Product Account.
  nonisolated static func relayConnection(account: String, subject: String) -> String {
    Data(
      SHA256.hash(
        data: Data("dev.unwired.mail.gmail-operational-connection.v1\0\(account)\0\(subject)".utf8))
    ).base64EncodedString().replacing("+", with: "-").replacing("/", with: "_")
      .replacing("=", with: "")
  }

  private struct Ignored: Decodable {}
  private struct Removal: Decodable { let hasRemainingGmailConnections: Bool }
  private struct Verification: Decodable {
    let routeId: String
    let verified: Bool
  }
  private struct Watch: Decodable {
    let historyId: String
    let expiration: String
  }

  // One relay call with this Trusted Device's proof. Only the end of its access is distinguished.
  private func relay<Value: Decodable>(
    _ endpoint: BackendRequest.Endpoint, _ path: String, _ args: [String: Any],
    _ product: ProductRegistrationReceipt
  ) async throws -> Value {
    guard let transport else { throw RegistrationError.unavailable }
    let (status, data) = try await transport(
      BackendRequest(
        endpoint: endpoint, path: path, args: args.merging(Self.proof(product)) { $1 },
        product: product))
    guard let reply = try? JSONDecoder().decode(ConvexEnvelope<Value>.self, from: data) else {
      throw RegistrationError.unavailable
    }
    if reply.status == "success", status == 200, let value = reply.value { return value }
    switch reply.errorData?.code {
    case "TRUSTED_DEVICE_REVOKED": throw RegistrationError.revoked
    case "PRODUCT_ACCOUNT_DELETED": throw RegistrationError.deleted
    default: throw RegistrationError.unavailable
    }
  }

  // Registers this device for wakes and keeps each verified connection's watch and route current.
  // A connection that cannot be routed now retries at the next verification; only the end of this
  // device's access fails. Without a configured topic or an APNs registration nothing is routed.
  func routeMailboxes(device: PushDevice?, topic: String?, now: Double) async throws {
    pushRoutingPaused = false
    try await removeQueuedPushRoutes()
    guard let topic, let saved = try load(), let product = saved.product, product.pending != true,
      let device = device ?? saved.pushDevice
    else { return }
    // Only Gmail watches deliver wakes; Microsoft and IMAP mail keep the host's polling.
    let due = saved.usableConnections.filter {
      $0.receipt.mailProvider == .gmail && verifiedMailboxes.contains($0.id)
        && ($0.pushVerified != true || ($0.pushExpiration ?? 0) - now < Self.watchRenewal)
    }
    // Each renewal also renews the relay's record of this device, which otherwise expires unused;
    // a new APNs token replaces it for the routes already registered.
    let rerouted = device != saved.pushDevice && saved.connections.contains { $0.pushRoute != nil }
    guard rerouted || !due.isEmpty else { return }
    try await attempt {
      let _: Ignored = try await self.relay(
        .mutation, "pushRelay:registerDevice",
        ["apnsToken": device.token, "apnsEnvironment": device.environment], product)
      var next = try self.saved()
      next.pushDevice = device
      try self.save(next)
    }
    for connection in due {
      try await attempt {
        let (verification, expiration) = try await self.watch(connection, product, topic: topic)
        var next = try self.saved()
        next.update(connection.id) {
          $0.pushRoute = verification.routeId
          $0.pushExpiration = expiration
          $0.pushVerified = verification.verified
        }
        try self.save(next)
      }
    }
  }

  // APNs callbacks share native custody, but cannot enter the shared flow's removal sequence.
  func pushDeviceChanged(device: PushDevice?, topic: String?, now: Double) async throws {
    guard !pushRoutingPaused, (try load())?.accountRemoval == nil else { return }
    do {
      try await routeMailboxes(device: device, topic: topic, now: now)
    } catch let error as RegistrationError where error.endsAccess {
      try await purge(notice: error.code)
      pushRegistrationFailure = error
    }
  }

  // Runs a push step; a failure other than the end of this device's access waits for a later one.
  private func attempt(_ step: () async throws -> Void) async throws {
    do { try await step() } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      Self.logger.error("Gmail push step failed")
    }
  }

  // Watches the connection's Inbox on `topic`, then proves its ownership to the relay.
  private func watch(
    _ connection: MailboxConnection, _ product: ProductRegistrationReceipt, topic: String
  ) async throws -> (Verification, Double) {
    guard connection.receipt.mailProvider == .gmail else { throw RegistrationError.unavailable }
    let gmail = try await provider.refresh(connection.credential)
    guard gmail.subject == connection.receipt.subject else {
      throw RegistrationError.invalidIdentity
    }
    let relayConnection = Self.relayConnection(
      account: product.productAccountId, subject: gmail.subject)
    let _: Ignored = try await relay(
      .action, "pushRelay:registerGmailConnection",
      ["gmailIdentityToken": gmail.idToken, "opaqueConnectionId": relayConnection], product)
    let (status, data) = try await provider.gmail(
      gmail, url: Self.watchURL,
      body: try JSONSerialization.data(withJSONObject: [
        "labelIds": ["INBOX"], "labelFilterBehavior": "include", "topicName": topic,
      ]))
    guard status == 200, let watch = try? JSONDecoder().decode(Watch.self, from: data),
      let expiration = Double(watch.expiration)
    else { throw RegistrationError.unavailable }
    let verification: Verification = try await relay(
      .action, "pushRelay:verifyGmailWatch",
      [
        "gmailIdentityToken": gmail.idToken, "historyId": watch.historyId,
        "opaqueConnectionId": relayConnection,
      ], product)
    return (verification, expiration)
  }

  // Stops the connection's watch unless another device's route still needs it.
  private func stopWatch(_ connection: MailboxConnection, _ product: ProductRegistrationReceipt)
    async throws
  {
    // Only a Gmail connection has a Gmail watch.
    guard connection.receipt.mailProvider == .gmail else { return }
    let relayConnection = Self.relayConnection(
      account: product.productAccountId, subject: connection.receipt.subject)
    let stop: Bool = try await relay(
      .query, "pushRelay:shouldStopGmailWatch", ["opaqueConnectionId": relayConnection], product)
    guard stop else { return }
    // A stopped or interrupted stop cannot cover mail if sign-out or deletion is later refused.
    var next = try saved()
    next.update(connection.id) {
      $0.pushExpiration = nil
      $0.pushVerified = false
    }
    try save(next)
    let gmail = try await provider.refresh(connection.credential)
    guard gmail.subject == connection.receipt.subject else {
      throw RegistrationError.invalidIdentity
    }
    let (status, _) = try await provider.gmail(
      gmail, url: Self.stopURL, body: Data())
    guard (200..<300).contains(status) else { throw RegistrationError.unavailable }
  }

  // Removes a connection's route; the last one also ends this device's wakes.
  private func removeRoute(_ relayConnection: String, _ product: ProductRegistrationReceipt)
    async throws
  {
    let removal: Removal = try await relay(
      .mutation, "pushRelay:removeGmailConnection", ["opaqueConnectionId": relayConnection],
      product)
    guard !removal.hasRemainingGmailConnections else { return }
    let _: Ignored = try await relay(.mutation, "pushRelay:unregisterDevice", [:], product)
    var saved = try saved()
    saved.pushDevice = nil
    try save(saved)
  }

  // Before a removed connection's credential leaves: drops its waiting wakes, stops its watch and
  // removes its route. A route the relay could not remove is kept to retry without the credential.
  @discardableResult func unroute(_ id: String, deferRemoval: Bool = false) async throws -> String? {
    guard transport != nil, let saved = try load(), let product = saved.product,
      let connection = saved.connection(id), connection.receipt.mailProvider == .gmail
    else { return nil }
    if let route = connection.pushRoute { wakes.drop([route]) }
    try await attempt { try await self.stopWatch(connection, product) }
    let relayConnection = Self.relayConnection(
      account: product.productAccountId, subject: connection.receipt.subject)
    // Local removal records this locator with its tombstone intent in one durable write.
    if deferRemoval { return relayConnection }
    do { try await removeRoute(relayConnection, product) } catch let error as RegistrationError
      where error.endsAccess
    {
      throw error
    } catch {
      var next = try self.saved()
      next.pushRouteRemovals = (next.pushRouteRemovals ?? []) + [relayConnection]
      try self.save(next)
    }
    return nil
  }

  // Credentials are no longer needed here. A local removal waits for Product Sync to acknowledge
  // its tombstone (or a later recreation); relay failures retain only their opaque locators.
  func removeQueuedPushRoutes() async throws {
    guard transport != nil, let saved = try load(), let product = saved.product,
      product.pending != true
    else { return }
    let pending = Set((saved.mailboxRemovals ?? []).map {
      Self.relayConnection(account: product.productAccountId, subject: $0.subject)
    })
    for relayConnection in saved.pushRouteRemovals ?? [] {
      if productSync != nil && pending.contains(relayConnection) { continue }
      try await attempt {
        try await self.removeRoute(relayConnection, product)
        var next = try self.saved()
        next.pushRouteRemovals = next.pushRouteRemovals?.filter { $0 != relayConnection }
        try self.save(next)
      }
    }
  }

  // Before sign-out or deletion, whose backend step removes this device's routes.
  func stopMailboxWatches() async throws {
    pushRoutingPaused = true
    guard let saved = try load(), let product = saved.product else { return }
    for connection in saved.connections where connection.receipt.mailProvider == .gmail {
      try await attempt { try await self.stopWatch(connection, product) }
    }
  }

  // The routes a wake may name, and whether every usable connection holds one that needs no
  // renewal, so a host can rely on wakes alone.
  func mailboxRoutes(now: Double) throws -> [String: Any] {
    let saved = try load()
    let usable = saved?.product?.pending == true ? [] : saved?.usableConnections ?? []
    var routes: [String: String] = [:]
    for connection in usable where (connection.pushExpiration ?? 0) > now {
      if let route = connection.pushRoute { routes[route] = connection.id }
    }
    let complete =
      saved?.pushDevice != nil
      && (wakes.device == nil || wakes.device == saved?.pushDevice) && !usable.isEmpty
      && usable.allSatisfy {
        $0.pushRoute != nil && $0.pushVerified == true
          && ($0.pushExpiration ?? 0) - now >= Self.watchRenewal
      }
    return ["routes": routes, "complete": complete]
  }
}
