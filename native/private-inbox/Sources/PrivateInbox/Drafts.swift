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
  func commitDrafts(owner: String, expectedRevision: Int, document: String) async throws
    -> [String: Any]
  {
    let (_, revision) = try await draftWork { store, current in
      guard owner == current else { throw PrivateInboxError.mailboxInvalidated }
      return try store.commitDraftDocument(owner: owner, expectedRevision: expectedRevision, document: document)
    }
    return ["owner": owner, "revision": revision]
  }
}
