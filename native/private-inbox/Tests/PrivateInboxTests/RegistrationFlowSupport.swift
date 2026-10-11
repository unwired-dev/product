import Foundation

@testable import PrivateInbox

// Test support only. Native tests reach and observe registration states through the vault
// operations in the order TypeScript's registration flow calls them, and read its status values.
// The flow and its decisions live in packages/mail-core/src/registration-flow.ts and
// product-sync.ts, which are tested there; this mirror exists so native Product Sync, Gmail and
// storage tests can set up the same states and keeps only what those tests need. Mailbox
// descriptor synchronization is not mirrored: packages/mail-core/test/product-sync.test.ts covers
// it over the same vault operations.
extension RegistrationStore {
  // MARK: Status values

  func status() throws -> [String: String] { try status(saved()) }

  func status(_ saved: SavedRegistration) throws -> [String: String] {
    let states = saved.usableConnections.map(mailboxState)
    guard saved.product?.pending != true, !states.isEmpty else { return try pending(saved) }
    var result = try account(saved, kind: states.contains("connected") ? "connected" : "cached")
    if let mailboxes = try mailboxList(saved) { result["mailboxes"] = mailboxes }
    return result
  }

  func account(_ saved: SavedRegistration, kind: String) throws -> [String: String] {
    guard let product = saved.product else { throw RegistrationError.unavailable }
    var result = [
      "kind": kind, "productAccountId": product.productAccountId,
      "signInProvider": saved.provider.rawValue,
    ]
    if let email = saved.contactEmail, !email.isEmpty { result["contactEmail"] = email }
    if let alternate = product.signInProviders?.first(where: { $0 != saved.provider }) {
      result["alternateSignIn"] = alternate.rawValue
    }
    result = result.merging(try privateSyncStatus(saved)) { $1 }
    if !(saved.mailboxRemovals ?? []).isEmpty || !(saved.mailboxCacheRemovals ?? []).isEmpty {
      result["privateSyncPending"] = "mailbox"
    }
    return result
  }

  func pending(_ saved: SavedRegistration) throws -> [String: String] {
    if saved.product?.pending == true { return try account(saved, kind: "device-pending") }
    var result = try account(saved, kind: "mailbox-needed")
    let reason =
      saved.mailboxSetupReason ?? (saved.connections.isEmpty ? nil : "gmail-unavailable")
    if let reason { result["reason"] = reason }
    if reason != "unavailable", reason != "interrupted", let mailboxes = try mailboxList(saved) {
      result["mailboxes"] = mailboxes
    }
    return result
  }

  func mailboxState(_ connection: MailboxConnection) -> String {
    if connection.authorizationNeeded == true { return "authorization" }
    return cacheOnlyMailboxes.contains(connection.id) ? "cached" : "connected"
  }

  func mailboxList(_ saved: SavedRegistration) throws -> String? {
    guard saved.product?.pending != true, !saved.connections.isEmpty else { return nil }
    let entries = saved.connections.map { connection in
      var entry = [
        "id": connection.id, "address": connection.receipt.address,
        "state": mailboxState(connection),
      ]
      if let epoch = connection.epoch { entry["epoch"] = epoch }
      return entry
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(entries), as: UTF8.self)
  }

  // The status values TypeScript derives from the Product Sync projection.
  func privateSyncStatus(_ saved: SavedRegistration) throws -> [String: String] {
    let state: [String: Any]
    do {
      guard let projected = try productSyncState(saved) else { return [:] }
      state = projected
    } catch {
      return ["privateSync": "unavailable"]
    }
    if state["pending"] as? Bool == true {
      guard state["materialInitialized"] as? Bool == true else {
        return ["privateSync": "setup-pending"]
      }
      guard let enrollment = state["enrollment"] as? [String: Any],
        let code = enrollment["code"] as? String
      else { return ["privateSync": "enrollment-needed"] }
      var result = ["privateSync": "enrollment-pending", "enrollmentCode": code]
      if let notice = enrollment["notice"] as? String { result["enrollmentNotice"] = notice }
      return result
    }
    guard let vault = state["vault"] as? [String: Any] else {
      return [
        "privateSync": state["materialInitialized"] as? Bool == true
          ? "enrollment-needed" : "setup-pending"
      ]
    }
    let holdsKey = state["deviceKey"] as? Bool == true
    let published = vault["published"] as? Bool == true
    let confirmed = vault["recoveryKeyConfirmed"] as? Bool == true
    let recoveryKey = vault["recoveryKey"] as? String
    let revocation = vault["revocation"] as? [String: Any]
    let unsettled =
      (recoveryKey != nil && !confirmed) || revocation?["submitted"] as? Bool == true
    if published, !unsettled, !holdsKey { return ["privateSync": "enrollment-needed"] }
    var result: [String: String] = [:]
    if !published {
      result["privateSync"] = "setup-pending"
    } else if !confirmed, let recoveryKey {
      result["privateSync"] = "recovery-key"
      result["recoveryKey"] = recoveryKey
    } else {
      result["privateSync"] = holdsKey ? "ready" : "enrollment-needed"
    }
    if published, holdsKey,
      let request = (state["requests"] as? [[String: Any]])?.max(by: {
        ($0["expiresAt"] as? Double ?? 0) < ($1["expiresAt"] as? Double ?? 0)
      })
    {
      result["enrollmentRequest"] = request["id"] as? String
      result["enrollmentDevice"] = request["device"] as? String
    }
    if published, holdsKey, let devices = state["trustedDevices"] as? [[String: Any]],
      !devices.isEmpty
    {
      result["trustedDevices"] = String(
        decoding: try JSONSerialization.data(withJSONObject: devices), as: UTF8.self)
    }
    if let revocation {
      result["revocationDevice"] = revocation["device"] as? String
      result["revocationRecoveryKey"] = revocation["recoveryKey"] as? String
    }
    if let mailboxes = vault["readMailboxes"] as? [String], !mailboxes.isEmpty {
      result["privateSyncMailboxes"] = mailboxes.joined(separator: "\n")
    }
    var records: [String: String] = [:]
    for entry in vault["mailboxes"] as? [[String: Any]] ?? [] {
      if let id = entry["id"] as? String { records[id] = entry["record"] as? String }
    }
    let confirmedMailboxes = vault["savedMailboxes"] as? [String: String] ?? [:]
    if published,
      saved.usableConnections.contains(where: {
        confirmedMailboxes[records[$0.id] ?? ""] != $0.receipt.address
      })
    {
      result["privateSyncPending"] = "mailbox"
    }
    return result
  }

  // MARK: Product Sync, in the order packages/mail-core/src/product-sync.ts calls the vault

  // Synchronizes with this process's verified sign-in; only the end of access fails it.
  func synchronizeRegistration() async throws {
    defer { finishSynchronization() }
    guard productSync != nil, session != nil, let saved = try load(), saved.product != nil else {
      return
    }
    _ = try await retryMailboxCleanup(saved)
    do {
      try await settleProductSync()
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {}
  }

  func settleProductSync() async throws {
    func current() throws -> (ProductRegistrationReceipt, ProductSyncVault?, Bool) {
      let saved = try self.saved()
      guard let product = saved.product else { throw RegistrationError.unavailable }
      let account = product.productAccountId
      let vault = try loadVault(account)
      return (product, vault, try keys.read(deviceKeyAccount(account)) != nil)
    }
    var (product, vault, holdsKey) = try current()
    if product.pending != true,
      product.productSyncMaterialInitialized == true || vault?.published == true, !holdsKey
    {
      if vault?.revocation?.submitted == true {
        try await adoptLatestRotation()
        (product, vault, holdsKey) = try current()
      }
      if vault?.holdsUnsettledKeys == true { return }
      try await reenroll()
      (product, vault, holdsKey) = try current()
    }
    if product.pending == true {
      guard product.productSyncMaterialInitialized == true, try await admitPendingDevice() else {
        return
      }
      (product, vault, holdsKey) = try current()
    }
    if vault == nil, product.productSyncMaterialInitialized != false { return }
    if vault?.published == true {
      try await adoptLatestRotation()
    } else {
      let ring = try createKeyRing()
      let reply = try await call([
        "endpoint": "mutation", "path": "productSync:initialize",
        "args": [
          "encryptedPayload": ring["recoveryEnvelope"] as Any,
          "recoveryVerifier": ring["recoveryVerifier"] as Any,
          "deviceEncryptionPublicKey": ring["deviceKey"] as Any,
        ],
        "session": true, "device": true,
      ])
      struct Initialized: Decodable { let initialized: Bool }
      guard reply["status"] as? Int == 200,
        let body = (reply["body"] as? String).map({ Data($0.utf8) }),
        let envelope = try? JSONDecoder().decode(ConvexEnvelope<Initialized>.self, from: body),
        envelope.status == "success", let initialized = envelope.value?.initialized
      else { throw RegistrationError.unavailable }
      try recordInitialization(initialized)
      guard initialized else { return }
    }
    try await refreshDevices()
  }

  func failure(_ reason: String) throws -> [String: String] {
    try recordMailboxSetup(reason)
    return try pending(saved())
  }

  // MARK: The flow's call order

  func establish(replacing: Bool = false) async throws {
    try saveIdentity(replacing: replacing)
    try await connectIdentity(.establish)
    try await synchronizeRegistration()
  }

  func reconfirm(_ saved: SavedRegistration) async throws {
    switch saved.provider {
    case .google:
      guard try await renewIdentity()["matches"] as? Bool == true else {
        throw RegistrationError.invalidIdentity
      }
      try await establish()
    case .apple:
      guard saved.product != nil, try await appleCredentialState() == "authorized" else {
        throw RegistrationError.unavailable
      }
    }
  }

  func signIn(with signInProvider: SignInProvider = .google) async throws -> [String: String] {
    let saved = try load()
    if let saved, saved.product != nil, saved.provider != signInProvider {
      _ = try await signInIdentity(signInProvider, hint: false)
      try await connectIdentity(.switch)
      try await synchronizeRegistration()
      return try await mailboxStatus()
    }
    let signedIn = try await signInIdentity(signInProvider, hint: saved?.provider == .google)
    try await establish(
      replacing: saved == nil || (saved?.product == nil && signedIn["matches"] as? Bool != true))
    return try await mailboxStatus()
  }

  func checkedGmail(_ scopes: [String]) async throws {
    guard scopes.contains(Self.gmailScope) || scopes.contains("https://mail.google.com/") else {
      throw RegistrationError.declined
    }
    _ = try await verifyGmail()
  }

  func mailboxStatus() async throws -> [String: String] {
    let saved = try saved()
    guard saved.product?.pending != true, !saved.connections.isEmpty else {
      return try pending(saved)
    }
    for connection in saved.connections {
      do {
        try await checkedGmail(refreshMailbox(connection.id)["scopes"] as? [String] ?? [])
        try confirmMailbox(connection.id)
      } catch let error as RegistrationError where error.endsAccess {
        throw error
      } catch {
        let offline = connection.authorizationNeeded == true ? "unverified" : "cached"
        try markMailbox(
          connection.id,
          access: Self.rejectionCode(error) == "offline" ? offline : "authorization")
      }
    }
    if try self.saved().usableConnections.contains(where: { verifiedMailboxes.contains($0.id) }) {
      try await synchronizeRegistration()
    }
    return try status()
  }

  func cachedMailbox(_ saved: SavedRegistration) throws -> [String: String]? {
    guard saved.product != nil, saved.accountRemoval == nil, !saved.usableConnections.isEmpty
    else { return nil }
    for connection in saved.usableConnections { try markMailbox(connection.id, access: "cached") }
    return try status()
  }

  func restore() async throws -> [String: String] {
    forgetMailboxAccess()
    guard let retained = try load() else { return ["kind": "signed-out"] }
    if let removal = try await removalStatus(retained) { return removal }
    try await retryMailboxCleanup()
    let saved = try saved()
    if saved.provider == .apple, saved.product == nil { return ["kind": "signed-out"] }
    do {
      try await reconfirm(saved)
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      if Self.rejectionCode(error) == "offline", let cached = try cachedMailbox((try? load()) ?? saved)
      {
        return cached
      }
      if saved.product != nil { return try failure("unavailable") }
      throw error
    }
    return try await mailboxStatus()
  }

  func authorizeGmail(connection id: String? = nil, chooseAccount: Bool = false) async throws
    -> [String: String]
  {
    guard let saved = try load(), let product = saved.product, product.pending != true else {
      throw RegistrationError.unavailable
    }
    let existing = id.flatMap(saved.connection)
    if id != nil, existing == nil { throw RegistrationError.unavailable }
    let keepsMailboxes = saved.usableConnections.contains { $0.id != id }
    do {
      try await reconfirm(saved)
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      return try failure(saved.provider == .apple ? "unavailable" : "interrupted")
    }
    let suggest = !chooseAccount && saved.connections.isEmpty && saved.provider == .google
    do {
      let scopes = try await signInMailbox(id, suggest: suggest)["scopes"] as? [String] ?? []
      try await checkedGmail(scopes)
      if let existing,
        mailboxAuthorization?.receipt.map({ MailboxConnection.id(subject: $0.subject) })
          != existing.id
      {
        throw RegistrationError.gmailUnavailable
      }
      try await retryMailboxCleanup()
      try storeMailbox()
      try await synchronizeRegistration()
      return try status()
    } catch let error as RegistrationError where error.endsAccess {
      throw error
    } catch {
      if keepsMailboxes { throw error }
      switch error {
      case RegistrationError.cancelled: return try failure("cancelled")
      case RegistrationError.declined: return try failure("declined")
      case RegistrationError.gmailUnavailable: return try failure("gmail-unavailable")
      default: return try failure("interrupted")
      }
    }
  }

  func removalStatus(_ saved: SavedRegistration) async throws -> [String: String]? {
    guard let removal = saved.accountRemoval else { return nil }
    if removal.acknowledged {
      let notice =
        removal.operation == .deletion
        ? "deleted" : removal.operation == .signOut ? "signed-out" : "revoked"
      try await purge(notice: notice)
      return notice == "signed-out" ? ["kind": "signed-out"] : ["kind": "signed-out", "notice": notice]
    }
    endSession()
    guard let product = saved.product else { throw RegistrationError.unavailable }
    return [
      "kind": "mailbox-needed", "productAccountId": product.productAccountId,
      "signInProvider": saved.provider.rawValue, "reason": "unavailable",
      "privateSync": "unavailable",
      "removalPending": removal.operation == .signOut ? "sign-out" : "deletion",
    ]
  }

  func purgingIfRevoked(_ operation: (RegistrationStore) async throws -> [String: String])
    async throws -> [String: String]
  {
    do {
      if let saved = try? load(), saved.accountRemoval != nil,
        let status = try await removalStatus(saved)
      {
        return status
      }
      if let product = (try? load())?.product { try await requireNotRevoked(product) }
      return try await operation(self)
    } catch RegistrationError.revoked {
      try await purge(notice: "revoked")
      return ["kind": "signed-out", "notice": "revoked"]
    } catch RegistrationError.deleted {
      try await purge(notice: "deleted")
      return ["kind": "signed-out", "notice": "deleted"]
    }
  }

  func refreshPrivateSync() async throws -> [String: String] {
    let saved = try saved()
    guard let product = saved.product else { throw RegistrationError.unavailable }
    switch saved.provider {
    case .google:
      try await reconfirm(saved)
    case .apple:
      guard session != nil else { return try await signIn(with: .apple) }
      if product.pending == true {
        try reuseSession()
        try await establish()
      } else {
        try await synchronizeRegistration()
      }
    }
    return try status()
  }

  // MARK: Operations that now resolve without a status

  func flowRemoveMailbox(_ id: String) async throws -> [String: String] {
    try await removeMailbox(id)
    try await synchronizeRegistration()
    return try status()
  }

  func flowConfirmRecoveryKey(_ entry: String) throws -> [String: String] {
    try confirmRecoveryKey(entry)
    return try status()
  }

  func flowApproveEnrollment(_ requestId: String, code: String) async throws -> [String: String] {
    try await approveEnrollment(requestId, code: code)
    return try status()
  }

  func flowDeclineEnrollment(_ requestId: String) async throws -> [String: String] {
    try await declineEnrollment(requestId)
    return try status()
  }

  func flowRecover(with entry: String) async throws -> [String: String] {
    let saved = try saved()
    guard productSync != nil, saved.product != nil else { throw RegistrationError.unavailable }
    let readable = readsAsRecoveryKey(entry)
    if readable {
      if saved.provider == .google {
        try await reconfirm(saved)
      } else {
        _ = try await signIn(with: .apple)
      }
    }
    let rejected = try await readable ? recover(with: entry) : true
    if !rejected { try await synchronizeRegistration() }
    var result = try status()
    if rejected { result["recoveryNotice"] = "rejected" }
    return result
  }

  func flowRevoke(_ trustedDeviceId: String) async throws -> [String: String] {
    let saved = try saved()
    guard
      try await signInIdentity(saved.provider, hint: saved.provider == .google)["matches"] as? Bool
        == true
    else { throw RegistrationError.invalidIdentity }
    return try await revocationStatus(revoke(trustedDeviceId))
  }

  // A removal step's notice; a settled removal's depends on the epoch held after synchronizing.
  func revocationStatus(_ reply: RevocationReply) async throws -> [String: String] {
    if reply.synchronize { try await synchronizeRegistration() }
    var result = try status()
    var notice = reply.notice
    if let settlement = reply.settlement {
      let saved = try saved()
      let epoch: Int?
      do {
        epoch =
          try saved.product.flatMap { try loadVault($0.productAccountId) }?.ring.current
          ?? (saved.product?.pending == true ? settlement.settledEpoch : nil)
      } catch {
        epoch = nil
      }
      if let epoch {
        notice =
          settlement.recoveryKeyCurrent && settlement.keyEpoch == epoch ? "removed" : "superseded"
      }
    }
    if let notice { result["revocationNotice"] = notice }
    return result
  }

  // A sign-in that is no longer recent is renewed interactively, then the removal confirmed again.
  func flowConfirmRevocation(_ entry: String) async throws -> [String: String] {
    let reply: RevocationReply
    do {
      reply = try await confirmRevocation(entry)
    } catch RegistrationError.staleAuthentication {
      let saved = try saved()
      guard
        try await signInIdentity(saved.provider, hint: saved.provider == .google)["matches"]
          as? Bool == true
      else { throw RegistrationError.invalidIdentity }
      reply = try await confirmRevocation(entry)
    }
    return try await revocationStatus(reply)
  }

  func flowCancelRevocation() async throws -> [String: String] {
    try await revocationStatus(cancelRevocation())
  }
}
