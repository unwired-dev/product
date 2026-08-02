import Foundation
import Observation

enum RemoteContentLoadPolicy: String, CaseIterable, Identifiable {
  case ask
  case never
  case alwaysLoad

  var id: Self { self }

  var title: String {
    switch self {
    case .ask:
      return "Ask"
    case .never:
      return "Never"
    case .alwaysLoad:
      return "Always Load"
    }
  }
}

enum AttachmentDownloadNetwork {
  case cellular
  case offline
  case wifi
}

enum AttachmentDownloadPolicy: String, CaseIterable, Identifiable {
  case onDemand
  case wifi
  case always

  var id: Self { self }

  var title: String {
    switch self {
    case .onDemand:
      return "On Demand"
    case .wifi:
      return "Wi-Fi"
    case .always:
      return "Always"
    }
  }

  func allowsAutomaticDownload(on network: AttachmentDownloadNetwork) -> Bool {
    switch (self, network) {
    case (_, .offline), (.onDemand, _), (.wifi, .cellular):
      return false
    case (.wifi, .wifi), (.always, .cellular), (.always, .wifi):
      return true
    }
  }
}

@MainActor
@Observable
final class MessageContentPreferences {
  enum StorageKey: String {
    case attachmentDownloadPolicy = "privacy.attachmentDownloadPolicy"
    case remoteContentOverrides = "privacy.remoteContentOverrides"
    case remoteContentPolicy = "privacy.remoteContentPolicy"
  }

  var remoteContentPolicy: RemoteContentLoadPolicy {
    didSet {
      defaults.set(remoteContentPolicy.rawValue, forKey: StorageKey.remoteContentPolicy.rawValue)
    }
  }

  var attachmentDownloadPolicy: AttachmentDownloadPolicy {
    didSet {
      defaults.set(
        attachmentDownloadPolicy.rawValue,
        forKey: StorageKey.attachmentDownloadPolicy.rawValue
      )
    }
  }

  private var remoteContentOverrides: [String: RemoteContentLoadPolicy]
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    remoteContentPolicy =
      defaults.string(forKey: StorageKey.remoteContentPolicy.rawValue)
      .flatMap(RemoteContentLoadPolicy.init(rawValue:))
      ?? .ask
    attachmentDownloadPolicy =
      defaults.string(forKey: StorageKey.attachmentDownloadPolicy.rawValue)
      .flatMap(AttachmentDownloadPolicy.init(rawValue:))
      ?? .onDemand
    remoteContentOverrides =
      (defaults.dictionary(forKey: StorageKey.remoteContentOverrides.rawValue) as? [String: String])?
      .compactMapValues(RemoteContentLoadPolicy.init(rawValue:))
      ?? [:]
  }

  func remoteContentOverride(
    for connectionId: MailboxConnectionId
  ) -> RemoteContentLoadPolicy? {
    remoteContentOverrides[connectionId.rawValue]
  }

  func remoteContentPolicy(for connectionId: MailboxConnectionId?) -> RemoteContentLoadPolicy {
    guard let connectionId else { return remoteContentPolicy }
    return remoteContentOverride(for: connectionId) ?? remoteContentPolicy
  }

  func setRemoteContentOverride(
    _ policy: RemoteContentLoadPolicy?,
    for connectionId: MailboxConnectionId
  ) {
    remoteContentOverrides[connectionId.rawValue] = policy
    defaults.set(
      remoteContentOverrides.mapValues(\.rawValue),
      forKey: StorageKey.remoteContentOverrides.rawValue
    )
  }
}
