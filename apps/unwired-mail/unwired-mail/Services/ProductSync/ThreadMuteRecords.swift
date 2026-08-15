import Foundation
import Security

struct ThreadMuteLocalState: Codable, Equatable, Sendable {
  var cachedRecordsByProfile: [String: [String: ThreadMuteSyncPayload]]
  var pendingRecordsByProfile: [String: [String: ThreadMuteSyncPayload]]

  static let empty = ThreadMuteLocalState(
    cachedRecordsByProfile: [:],
    pendingRecordsByProfile: [:]
  )
}

protocol ThreadMuteLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> ThreadMuteLocalState?
  func save(_ state: ThreadMuteLocalState, productAccountId: String) throws
}

struct KeychainThreadMuteLocalStateStore: ThreadMuteLocalStatePersisting {
  private static let service = "dev.unwired.mail.thread-mute-local-state"

  func clear(productAccountId: String) throws {
    try KeychainStore.delete(service: Self.service, account: productAccountId)
  }

  func load(productAccountId: String) throws -> ThreadMuteLocalState? {
    guard
      let encoded = try KeychainStore.readString(
        service: Self.service,
        account: productAccountId
      ),
      let data = encoded.data(using: .utf8)
    else { return nil }
    do {
      return try JSONDecoder().decode(ThreadMuteLocalState.self, from: data)
    } catch {
      try KeychainStore.delete(service: Self.service, account: productAccountId)
      return nil
    }
  }

  func save(_ state: ThreadMuteLocalState, productAccountId: String) throws {
    let data = try JSONEncoder().encode(state)
    guard let encoded = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      encoded,
      service: Self.service,
      account: productAccountId,
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }
}

struct ThreadMuteSyncPayload: Codable, Equatable, Sendable {
  let anchorProviderMessageId: String
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let isMuted: Bool
  let profileId: String
  let provider: String
  let providerAccountIdentifier: String
  let providerThreadId: String
  let schemaVersion: Int

  var mute: ThreadMute {
    ThreadMute(
      anchorMessageId: StableProviderMessageIdentity(
        connectionId: threadId.connectionId,
        providerMessageId: anchorProviderMessageId
      ),
      profileId: MailProfileId(rawValue: profileId),
      threadId: threadId
    )
  }

  var threadId: StableThreadIdentity {
    StableThreadIdentity(
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: MailProviderId(rawValue: provider),
          value: providerAccountIdentifier
        )
      ),
      providerThreadId: providerThreadId
    )
  }

  func isNewer(than other: Self) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }
}

struct ThreadMuteRedirectPayload: Codable, Equatable, Sendable {
  let changedAtMilliseconds: Int64
  let changedByTrustedDeviceId: String
  let formerProviderThreadId: String
  let profileId: String
  let provider: String
  let providerAccountIdentifier: String
  let schemaVersion: Int
  let targetProviderThreadId: String

  var formerThreadId: StableThreadIdentity {
    StableThreadIdentity(connectionId: connectionId, providerThreadId: formerProviderThreadId)
  }

  var targetThreadId: StableThreadIdentity {
    StableThreadIdentity(connectionId: connectionId, providerThreadId: targetProviderThreadId)
  }

  func isNewer(than other: Self) -> Bool {
    if changedAtMilliseconds != other.changedAtMilliseconds {
      return changedAtMilliseconds > other.changedAtMilliseconds
    }
    return changedByTrustedDeviceId > other.changedByTrustedDeviceId
  }

  private var connectionId: MailboxConnectionId {
    MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: MailProviderId(rawValue: provider),
        value: providerAccountIdentifier
      )
    )
  }
}
