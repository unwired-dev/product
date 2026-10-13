import CryptoKit
import Foundation

@testable import PrivateInbox

// Convex's Product Sync rules for what native code still sends: one recovery envelope per account,
// compare-and-set records for native Draft sync, and Pending Devices that only an authorization at
// the newest key epoch admits. TypeScript sequences enrollment, recovery, rotation and removal; this
// answers the calls the vault makes itself because they carry a proof or issue a credential.
@MainActor final class SyntheticProductSyncBackend {
  struct PendingDevice {
    let account: String
    let installation: String
    var expiresAt: Double
    // The encryption key its approval or Recovery Key proof named, which admission binds.
    var deviceKey: Data?
    // A Trusted Device approved its request at the account's current epoch.
    var approved = false
    // The key epoch a matching Recovery Key proof authorized.
    var recovered: Int?
  }
  var recovery: [String: EncryptedPayload] = [:]
  // The digest of the proof of the Recovery Key that opens the committed recovery envelope.
  var verifiers: [String: String] = [:]
  var records: [String: [String: StoredPayload]] = [:]
  // Each account's Draft delivery claims and the Trusted Device holding each.
  var claims: [String: [String: String]] = [:]
  // Runs before each record write, as another device's write that lands first.
  var beforePut: ((String, String) throws -> Void)?
  // Controls read-back independently of the CAS response.
  var beforeList: ((String, String) throws -> Void)?
  // Pending Devices by id; each ends with its request unless it is renewed or approved.
  var pending: [String: PendingDevice] = [:]
  var revoked: Set<String> = []
  var initializations = 0
  var offline = false
  var clock = 1_000.0
  // Each account's key epoch and its Trusted Devices with their bound encryption keys.
  var committed: [String: Int] = [:]
  var deviceKeys: [String: Data] = [:]
  var devices: [String: [String]] = [:]

  func epoch(_ account: String) -> Int { committed[account] ?? 1 }

  func verifies(_ proof: Any?, _ account: String) -> Bool {
    guard let proof = proof as? String else { return false }
    return SHA256.hash(data: Data(proof.utf8)).map({ String(format: "%02x", $0) }).joined()
      == verifiers[account]
  }

  // Product Sign-In admits a returning Trusted Device, or the first device of an account without
  // keys or Trusted Devices. Any other device waits as a Pending Device; a removed one is refused.
  func connect(_ account: String, device installation: String) throws -> ProductRegistrationReceipt
  {
    let id = "device-" + installation
    guard !revoked.contains(id) else { throw RegistrationError.revoked }
    func receipt(_ id: String, pending: Bool? = nil) -> ProductRegistrationReceipt {
      ProductRegistrationReceipt(
        productAccountId: account, trustedDeviceId: id,
        trustedDeviceCredential: String(repeating: "a", count: 64), pending: pending,
        productSyncMaterialInitialized: recovery[account] != nil)
    }
    if devices[account]?.contains(id) == true { return receipt(id) }
    if devices[account, default: []].isEmpty, recovery[account] == nil {
      devices[account, default: []].append(id)
      return receipt(id)
    }
    // A record that ended is replaced by a new Pending Device.
    if let open = pending.first(where: {
      $0.value.installation == installation && $0.value.expiresAt > clock
    }) {
      return receipt(open.key, pending: true)
    }
    let pendingId = "pending-" + UUID().uuidString
    pending = pending.filter { $0.value.installation != installation }
    pending[pendingId] = PendingDevice(
      account: account, installation: installation, expiresAt: clock + 900_000)
    return receipt(pendingId, pending: true)
  }

  // Every call presents a live Trusted Device of the account.
  func trusted(_ product: ProductRegistrationReceipt) throws {
    guard !offline else { throw RegistrationError.unavailable }
    guard !revoked.contains(product.trustedDeviceId) else { throw RegistrationError.revoked }
    guard product.pending != true,
      devices[product.productAccountId]?.contains(product.trustedDeviceId) == true
    else { throw RegistrationError.unavailable }
  }

  // Admission calls present the caller's own unexpired Pending Device.
  func pendingDevice(_ product: ProductRegistrationReceipt) throws -> PendingDevice {
    guard !offline else { throw RegistrationError.unavailable }
    guard product.pending == true, let device = pending[product.trustedDeviceId],
      device.account == product.productAccountId, device.expiresAt > clock
    else { throw RegistrationError.pendingDeviceUnavailable }
    return device
  }

  // Convex's initialization: the first recovery envelope becomes the account's key material.
  func initialize(
    _ product: ProductRegistrationReceipt, envelope: EncryptedPayload, verifier: String,
    deviceKey: Data
  ) throws -> Bool {
    try trusted(product)
    let account = product.productAccountId
    if let existing = recovery[account] { return existing == envelope }
    recovery[account] = envelope
    verifiers[account] = verifier
    deviceKeys[product.trustedDeviceId] = deviceKey
    initializations += 1
    return true
  }

  // Admits at the newest epoch, which the approval or the Recovery Key proof authorized, with the
  // encryption key it named.
  func complete(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws -> Any {
    let device = try pendingDevice(product)
    let keyEpoch = epoch(product.productAccountId)
    guard args["keyVersion"] as? Int == keyEpoch,
      device.recovered == keyEpoch || device.approved,
      let deviceKey = (args["deviceEncryptionPublicKey"] as? String).flatMap({
        Data(base64Encoded: $0)
      }),
      device.deviceKey == deviceKey
    else { return ["admitted": false] }
    pending[product.trustedDeviceId] = nil
    let id = "device-" + device.installation
    devices[product.productAccountId, default: []].append(id)
    deviceKeys[id] = deviceKey
    return ["admitted": true, "trustedDeviceId": id]
  }

  // Only the current Recovery Key admits a device; a mismatch returns nothing.
  func recover(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws -> Any {
    _ = try pendingDevice(product)
    let account = product.productAccountId
    guard let envelope = recovery[account], verifies(args["recoveryProof"], account) else {
      return NSNull()
    }
    pending[product.trustedDeviceId]?.recovered = envelope.keyVersion
    pending[product.trustedDeviceId]?.deviceKey = (args["deviceEncryptionPublicKey"] as? String)
      .flatMap { Data(base64Encoded: $0) }
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
  }

  // Only the current Recovery Key binds a key, once; a different bound key is never replaced.
  func bind(_ product: ProductRegistrationReceipt, _ args: [String: Any]) throws -> Any {
    try trusted(product)
    guard verifies(args["recoveryProof"], product.productAccountId),
      let deviceKey = (args["deviceEncryptionPublicKey"] as? String).flatMap({
        Data(base64Encoded: $0)
      })
    else { return ["bound": false] }
    let bound = deviceKeys[product.trustedDeviceId]
    guard bound == nil || bound == deviceKey else { throw RegistrationError.unavailable }
    deviceKeys[product.trustedDeviceId] = deviceKey
    return ["bound": true]
  }

  // The Convex calls TypeScript names for Product Sync initialization, and those the vault makes
  // itself, answered as Convex would.
  func transport(_ request: BackendRequest) throws -> (Int, Data) {
    guard request.identity != nil, let product = request.product else {
      throw RegistrationError.unavailable
    }
    let value: Any
    switch request.path {
    case "productSync:initialize":
      guard let payload = request.args["encryptedPayload"],
        let verifier = request.args["recoveryVerifier"] as? String,
        let deviceKey = (request.args["deviceEncryptionPublicKey"] as? String)
          .flatMap({ Data(base64Encoded: $0) })
      else { throw RegistrationError.unavailable }
      value = [
        "initialized": try initialize(
          product,
          envelope: JSONDecoder().decode(
            EncryptedPayload.self, from: JSONSerialization.data(withJSONObject: payload)),
          verifier: verifier, deviceKey: deviceKey)
      ]
    case "productSyncEnrollment:complete": value = try complete(product, request.args)
    case "productSyncEnrollment:recover": value = try recover(product, request.args)
    case "productSync:bindDeviceEncryptionKey": value = try bind(product, request.args)
    default: throw RegistrationError.unavailable
    }
    return (
      200, try JSONSerialization.data(withJSONObject: ["status": "success", "value": value])
    )
  }

  var backend: ProductSyncBackend {
    ProductSyncBackend(
      list: { [self] _, product, prefix in
        try trusted(product)
        try beforeList?(product.productAccountId, prefix)
        return (records[product.productAccountId] ?? [:]).values
          .filter { $0.payloadIdentifier.hasPrefix(prefix) }
          .sorted { $0.payloadIdentifier < $1.payloadIdentifier }
      },
      put: { [self] _, product, identifier, payload, expected in
        try trusted(product)
        try beforePut?(product.productAccountId, identifier)
        guard payload.keyVersion == epoch(product.productAccountId) else {
          throw ProductSyncWriteFailure.keyRotationRequired
        }
        let existing = records[product.productAccountId]?[identifier]
        if let existing, existing.updatedAt != expected { return existing }
        // As Convex does, a compare-and-set against a record that no longer exists is refused.
        if existing == nil, expected != nil { throw ProductSyncWriteFailure.payloadChanged }
        clock += 1
        let stored = StoredPayload(
          payloadIdentifier: identifier, encryptedPayload: payload, updatedAt: clock)
        records[product.productAccountId, default: [:]][identifier] = stored
        return stored
      },
      get: { [self] _, product, identifier in
        try trusted(product)
        return records[product.productAccountId]?[identifier]
      },
      claimDelivery: { [self] _, product, identifier in
        try trusted(product)
        let holder =
          claims[product.productAccountId]?[identifier] ?? product.trustedDeviceId
        claims[product.productAccountId, default: [:]][identifier] = holder
        return holder == product.trustedDeviceId
      })
  }

  // Each installation is its own device of the account its sign-in reaches.
  func store(
    keys: DeviceKeychain, google: SyntheticGoogleRegistrationProvider,
    microsoft: (any MicrosoftMailProvider)? = nil
  ) -> RegistrationStore {
    RegistrationStore(
      keys: keys, deployment: "https://synthetic.example.invalid", clientID: "synthetic-client",
      provider: google, microsoft: microsoft, productSync: backend,
      deviceRevoked: { [self] product in revoked.contains(product.trustedDeviceId) },
      transport: { [self] request in try transport(request) },
      connect: { [self] identity, device, _ in
        try connect("account-" + identity.subject, device: device)
      })
  }
}
