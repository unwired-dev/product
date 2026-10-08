import Foundation

// The signed-in Product Account's Drafts for TypeScript's composer. They need no Gmail access, so
// they open offline and while a mailbox waits for authorization; an account that is pending or
// being removed has none.
extension RegistrationStore {
  private func draftOwner() throws -> (PrivateInboxStore, String) {
    guard let mailCache else { throw RegistrationError.unavailable }
    guard let saved = try load(), saved.accountRemoval == nil, let product = saved.product,
      product.pending != true
    else { throw PrivateInboxError.mailboxInvalidated }
    return (mailCache, product.productAccountId)
  }

  private func draftWork<Value: Sendable>(
    _ work: @escaping @Sendable (PrivateInboxStore, String) throws -> Value
  ) async throws -> (String, Value) {
    let (store, owner) = try draftOwner()
    guard store.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
    let value: Value
    do {
      value = try await Task.detached(priority: .userInitiated) { try work(store, owner) }.value
    } catch {
      guard store.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
      throw error
    }
    guard store.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
    let (_, current) = try draftOwner()
    guard current == owner else { throw PrivateInboxError.mailboxInvalidated }
    return (owner, value)
  }

  func openDrafts() async throws -> [String: Any] {
    let (owner, opened) = try await draftWork { try $0.openDraftDocument(owner: $1) }
    return ["owner": owner, "revision": opened.revision, "document": opened.document ?? NSNull()]
  }

  // A save read for another Product Account, or after its removal began, changes nothing.
  func commitDrafts(
    owner: String, expectedRevision: Int, document: String, keep: [String] = []
  )
    async throws -> [String: Any]
  {
    let (_, revision) = try await draftWork { store, current in
      guard owner == current else { throw PrivateInboxError.mailboxInvalidated }
      return try store.commitDraftDocument(
        owner: owner, expectedRevision: expectedRevision, document: document, keep: keep)
    }
    return ["owner": owner, "revision": revision]
  }

  // Files the system pickers copied for this process; launch removes any left behind.
  nonisolated public static var pickedDraftFiles: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("draft-picks", isDirectory: true)
  }

  // Only the picker owns immediate UUID subfolders of its root; a similar path is not ours.
  nonisolated static func isPickedDraftFile(_ file: URL) -> Bool {
    let folder = file.standardizedFileURL.deletingLastPathComponent()
    return file.isFileURL
      && folder.deletingLastPathComponent() == pickedDraftFiles.standardizedFileURL
      && UUID(uuidString: folder.lastPathComponent) != nil
  }

  nonisolated public static func discardPickedDraftFile(_ file: URL) {
    guard isPickedDraftFile(file) else { return }
    try? FileManager.default.removeItem(at: file.standardizedFileURL.deletingLastPathComponent())
  }

  // JavaScript names a file only as a picker's copy or, on Mac, a file outside this app's own
  // container that the person chose or dropped. Any other path, such as a Downloaded Attachment's
  // plaintext, is refused, so it cannot skip that attachment's mailbox generation check.
  nonisolated static func allowsDraftFile(_ file: URL) -> Bool {
    if isPickedDraftFile(file) { return true }
    #if os(macOS)
      let resolved = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath().path }
      let container = resolved(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
      let path = resolved(file)
      return file.isFileURL && path != container && !path.hasPrefix(container + "/")
    #else
      return false
    #endif
  }

  // Copies an asset's bytes into Draft storage for `owner`: a picked or dropped file, pasted
  // `data:` bytes, or a Downloaded Attachment of a current mailbox generation. The Draft keeps
  // only the bytes, never the mailbox they came from.
  func importDraftAsset(owner: String, id: String, source: [String: Any]) async throws
    -> [String: Any]
  {
    let kind = source["kind"] as? String
    var file: URL?
    var data: String?
    switch kind {
    case "file":
      guard let uri = source["uri"] as? String else { throw RegistrationError.unavailable }
      let chosen = uri.hasPrefix("file:") ? URL(string: uri) : URL(fileURLWithPath: uri)
      guard let chosen, Self.allowsDraftFile(chosen) else { throw RegistrationError.unavailable }
      file = chosen
    case "data":
      data = source["uri"] as? String
    case "received":
      guard let mailbox = source["mailbox"] as? [String: Any],
        let connection = mailbox["connection"] as? String,
        let address = mailbox["address"] as? String,
        let generation = mailbox["generation"] as? String,
        let name = source["file"] as? String
      else { throw RegistrationError.unavailable }
      file = try await attachmentFile(
        connection: connection, address: address, generation: generation, file: name)
    default:
      throw RegistrationError.unavailable
    }
    guard file != nil || data != nil else { throw RegistrationError.unavailable }
    defer { if let file { Self.discardPickedDraftFile(file) } }
    let (_, imported) = try await draftWork { [file, data] store, current in
      guard owner == current else { throw PrivateInboxError.mailboxInvalidated }
      let bytes = try file.map(Self.draftFileBytes) ?? Self.draftDataBytes(data ?? "")
      return try store.importDraftAsset(owner: owner, id: id, bytes: bytes)
    }
    return ["owner": owner, "size": imported.size, "digest": imported.digest]
  }

  nonisolated private static func draftFileBytes(_ url: URL) throws -> Data {
    // A file the person dropped or chose stays readable while this process holds its grant.
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw PrivateInboxError.unavailable }
    guard (values.fileSize ?? 0) <= PrivateInboxStore.draftAssetLimit else {
      throw PrivateInboxError.tooLarge
    }
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= PrivateInboxStore.draftAssetLimit else { throw PrivateInboxError.tooLarge }
    return bytes
  }

  nonisolated private static func draftDataBytes(_ uri: String) throws -> Data {
    guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","),
      uri[..<comma].hasSuffix(";base64")
    else { throw PrivateInboxError.unavailable }
    let encoded = uri[uri.index(after: comma)...]
    guard encoded.utf8.count <= 4 * ((PrivateInboxStore.draftAssetLimit + 2) / 3) else {
      throw PrivateInboxError.tooLarge
    }
    guard let bytes = Data(base64Encoded: String(encoded)) else {
      throw PrivateInboxError.unavailable
    }
    return bytes
  }

  // Verifies an asset's bytes; with `preview`, returns them as a `data:` URL for showing an image
  // in the composer, and otherwise returns nothing, so an attachment's bytes stay native.
  func readDraftAsset(
    owner: String, id: String, digest: String, type: String, preview: Bool = true
  ) async throws -> [String: Any] {
    let (_, bytes) = try await draftWork { store, current in
      guard owner == current else { throw PrivateInboxError.mailboxInvalidated }
      return try store.readDraftAsset(owner: owner, id: id, digest: digest)
    }
    guard preview else { return [:] }
    let mime =
      type.range(of: "^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$", options: .regularExpression) == nil
      ? "application/octet-stream" : type
    // ponytail: the whole image crosses the bridge as base64; a file URL scales past 25 MiB.
    return ["uri": "data:\(mime);base64,\(bytes.base64EncodedString())"]
  }

  // Removes bytes no stored Draft names; needs no key, so it also runs while the device is locked.
  func discardDraftAsset(id: String) async throws {
    guard let mailCache else { return }
    try await Task.detached(priority: .userInitiated) {
      try mailCache.discardDraftAsset(id: id)
    }.value
  }
}
