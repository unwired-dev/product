import Foundation
import React

@objc(UnwiredPrivateInbox)
final class UnwiredPrivateInbox: NSObject {
  private static let queue = DispatchQueue(label: "dev.unwired.private-inbox")

  @objc static func requiresMainQueueSetup() -> Bool { false }

  private func perform(
    _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @Sendable (PrivateInboxStore) throws -> String
  ) {
    Task { @MainActor in
      do {
        let storage = try Self.store()
        guard storage.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
        let result: Result<String, any Error> = await withCheckedContinuation { continuation in
          Self.queue.async {
            continuation.resume(returning: Result { try operation(storage) })
          }
        }
        guard storage.isProtectedDataAvailable() else { throw PrivateInboxError.locked }
        resolve(try result.get())
      } catch PrivateInboxError.locked {
        reject("locked", "Private storage is locked.", nil)
      } catch { reject("unavailable", "Private storage could not be opened or saved.", nil) }
    }
  }

  // Registration clears this store's mailbox cache when the account or mailbox goes.
  static func store() throws -> PrivateInboxStore {
    guard let identifier = Bundle.main.bundleIdentifier else { throw PrivateInboxError.unavailable }
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return PrivateInboxStore(
      directory: base.appendingPathComponent(identifier).appendingPathComponent("PrivateInbox"),
      service: identifier + ".private-inbox")
  }

  @objc(open:resolver:rejecter:)
  func open(
    _ seed: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform(resolve, reject: reject) { try $0.open(seed: seed) }
  }

  @objc(setUnread:unread:resolver:rejecter:)
  func setUnread(
    _ id: String, unread: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform(resolve, reject: reject) { try $0.setUnread(id: id, unread: unread) }
  }
}
