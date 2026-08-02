import CryptoKit
import Network
import Observation
import SwiftUI

enum AttachmentDownloadTrigger: Equatable {
  case automatic
  case userInitiated
}

struct AttachmentDownloadRequestTracker {
  private(set) var requestCount = 0
  private var consumedRequestCount = 0

  mutating func request() {
    requestCount += 1
  }

  mutating func consumeTrigger() -> AttachmentDownloadTrigger {
    guard requestCount > consumedRequestCount else { return .automatic }
    consumedRequestCount = requestCount
    return .userInitiated
  }
}

enum AttachmentDownloadError: LocalizedError {
  case blockedByPolicy
  case exceedsSizeLimit
  case networkUnavailable

  var errorDescription: String? {
    switch self {
    case .blockedByPolicy:
      return "The current attachment download policy blocked this request."
    case .exceedsSizeLimit:
      return "The attachment exceeds the 25 MB download limit."
    case .networkUnavailable:
      return "Connect to a network and try again."
    }
  }
}

enum AttachmentDownloadGate {
  static let maximumByteCount = 25 * 1_024 * 1_024

  static func allowsDownload(
    policy: AttachmentDownloadPolicy,
    network: AttachmentDownloadNetwork,
    trigger: AttachmentDownloadTrigger
  ) -> Bool {
    guard network != .offline else { return false }
    switch trigger {
    case .userInitiated:
      return true
    case .automatic:
      return policy.allowsAutomaticDownload(on: network)
    }
  }

  static func download(
    policy: AttachmentDownloadPolicy,
    network: AttachmentDownloadNetwork,
    trigger: AttachmentDownloadTrigger,
    expectedByteCount: Int,
    using operation: () async throws -> Data
  ) async throws -> Data {
    guard network != .offline else { throw AttachmentDownloadError.networkUnavailable }
    guard allowsDownload(policy: policy, network: network, trigger: trigger) else {
      throw AttachmentDownloadError.blockedByPolicy
    }
    guard expectedByteCount <= maximumByteCount else {
      throw AttachmentDownloadError.exceedsSizeLimit
    }
    try Task.checkCancellation()
    let data = try await operation()
    try Task.checkCancellation()
    guard data.count <= maximumByteCount,
      expectedByteCount == 0 || data.count <= expectedByteCount
    else { throw AttachmentDownloadError.exceedsSizeLimit }
    return data
  }
}

@MainActor
@Observable
final class AttachmentDownloadNetworkMonitor {
  private(set) var network: AttachmentDownloadNetwork = .offline
  private let monitor = NWPathMonitor()

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let network: AttachmentDownloadNetwork
      if path.status != .satisfied {
        network = .offline
      } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
        network = .wifi
      } else {
        network = .cellular
      }
      Task { @MainActor [weak self] in
        self?.network = network
      }
    }
    monitor.start(queue: DispatchQueue(label: "dev.unwired.mail.attachment-network"))
  }

  deinit {
    monitor.cancel()
  }
}

struct MessageAttachmentsView: View {
  let attachments: [MailboxMessageAttachment]
  let messageId: StableProviderMessageIdentity
  let download: (MailboxMessageAttachment) async throws -> Data

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Attachments")
        .font(.subheadline.bold())
      ForEach(attachments) { attachment in
        MessageAttachmentRow(
          attachment: attachment,
          messageId: messageId,
          download: download
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MessageAttachmentRow: View {
  let attachment: MailboxMessageAttachment
  let messageId: StableProviderMessageIdentity
  let download: (MailboxMessageAttachment) async throws -> Data

  @Environment(AttachmentDownloadNetworkMonitor.self) private var networkMonitor:
    AttachmentDownloadNetworkMonitor?
  @Environment(MessageContentPreferences.self) private var preferences: MessageContentPreferences?
  @State private var downloadedURL: URL?
  @State private var errorMessage: String?
  @State private var requestTracker = AttachmentDownloadRequestTracker()

  var body: some View {
    HStack {
      Image(systemName: "paperclip")
      VStack(alignment: .leading) {
        Text(attachment.filename)
        Text(
          ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      Spacer()
      if let downloadedURL {
        ShareLink(item: downloadedURL) {
          Label("Open", systemImage: "square.and.arrow.up")
        }
      } else {
        Button(errorMessage == nil ? "Download" : "Try Again") {
          requestTracker.request()
        }
        .accessibilityIdentifier("download-message-attachment")
      }
    }
    .task(id: taskId) {
      let trigger = requestTracker.consumeTrigger()
      let policy = preferences?.attachmentDownloadPolicy ?? .onDemand
      let network = networkMonitor?.network ?? .offline
      let store = DownloadedAttachmentStore()
      if let existingURL = store.existingURL(attachment: attachment, messageId: messageId) {
        downloadedURL = existingURL
        return
      }
      if case .automatic = trigger,
        !AttachmentDownloadGate.allowsDownload(
          policy: policy,
          network: network,
          trigger: trigger
        )
      {
        return
      }
      do {
        let data = try await AttachmentDownloadGate.download(
          policy: policy,
          network: network,
          trigger: trigger,
          expectedByteCount: attachment.byteCount
        ) {
          try await download(attachment)
        }
        downloadedURL = try store.save(
          data,
          attachment: attachment,
          messageId: messageId
        )
        errorMessage = nil
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private var taskId: String {
    let policy = preferences?.attachmentDownloadPolicy.rawValue ?? "onDemand"
    let network = String(describing: networkMonitor?.network ?? .offline)
    return "\(policy):\(network):\(requestTracker.requestCount)"
  }
}

struct DownloadedAttachmentStore {
  private struct StoredFile {
    let date: Date
    let size: Int
    let url: URL
  }

  static let maximumStoredByteCount = 250 * 1_024 * 1_024

  private let fileManager: FileManager
  private let maximumStoredByteCount: Int
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    rootDirectory: URL? = nil,
    maximumStoredByteCount: Int = Self.maximumStoredByteCount
  ) {
    self.fileManager = fileManager
    self.maximumStoredByteCount = maximumStoredByteCount
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/DownloadedAttachments", isDirectory: true)
  }

  func save(
    _ data: Data,
    attachment: MailboxMessageAttachment,
    messageId: StableProviderMessageIdentity
  ) throws -> URL {
    let destination = destinationURL(attachment: attachment, messageId: messageId)
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try makeRoom(for: data.count, excluding: destination)
    try data.write(to: destination, options: [.atomic, .completeFileProtection])
    return destination
  }

  func existingURL(
    attachment: MailboxMessageAttachment,
    messageId: StableProviderMessageIdentity
  ) -> URL? {
    let destination = destinationURL(attachment: attachment, messageId: messageId)
    return fileManager.fileExists(atPath: destination.path) ? destination : nil
  }

  func clear(connectionId: MailboxConnectionId) throws {
    let directory = connectionDirectory(connectionId)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }

  func clearAll() throws {
    guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
    try fileManager.removeItem(at: rootDirectory)
  }

  private func destinationURL(
    attachment: MailboxMessageAttachment,
    messageId: StableProviderMessageIdentity
  ) -> URL {
    let digest = SHA256.hash(data: Data("\(messageId.rawValue):\(attachment.id)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let directory = connectionDirectory(messageId.connectionId)
      .appendingPathComponent(digest, isDirectory: true)
    let pathComponent = URL(fileURLWithPath: attachment.filename).lastPathComponent
    let filename =
      pathComponent.isEmpty || pathComponent == "." || pathComponent == ".."
      ? "Attachment" : pathComponent
    return directory.appendingPathComponent(filename)
  }

  private func connectionDirectory(_ connectionId: MailboxConnectionId) -> URL {
    let digest = SHA256.hash(data: Data(connectionId.rawValue.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return rootDirectory.appendingPathComponent(digest, isDirectory: true)
  }

  private func makeRoom(for byteCount: Int, excluding destination: URL) throws {
    guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    guard
      let enumerator = fileManager.enumerator(
        at: rootDirectory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else { return }
    let files = enumerator.compactMap { item -> StoredFile? in
      guard let url = item as? URL, url != destination,
        let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else { return nil }
      return StoredFile(
        date: values.contentModificationDate ?? .distantPast,
        size: values.fileSize ?? 0,
        url: url
      )
    }
    var storedByteCount = files.reduce(0) { $0 + $1.size }
    for file in files.sorted(by: { $0.date < $1.date })
    where storedByteCount + byteCount > maximumStoredByteCount {
      try fileManager.removeItem(at: file.url)
      storedByteCount -= file.size
    }
  }
}
