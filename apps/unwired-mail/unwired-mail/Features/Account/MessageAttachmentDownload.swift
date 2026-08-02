import CryptoKit
import Network
import Observation
import SwiftUI

enum AttachmentDownloadTrigger {
  case automatic
  case userInitiated
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
  @State private var manualRequest = 0

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
          manualRequest += 1
        }
        .accessibilityIdentifier("download-message-attachment")
      }
    }
    .task(id: taskId) {
      let trigger: AttachmentDownloadTrigger = manualRequest == 0 ? .automatic : .userInitiated
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
    return "\(policy):\(network):\(manualRequest)"
  }
}

struct DownloadedAttachmentStore {
  private let fileManager: FileManager
  private let rootDirectory: URL

  init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
    self.fileManager = fileManager
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

  private func destinationURL(
    attachment: MailboxMessageAttachment,
    messageId: StableProviderMessageIdentity
  ) -> URL {
    let digest = SHA256.hash(data: Data("\(messageId.rawValue):\(attachment.id)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let directory = rootDirectory.appendingPathComponent(digest, isDirectory: true)
    let pathComponent = URL(fileURLWithPath: attachment.filename).lastPathComponent
    let filename =
      pathComponent.isEmpty || pathComponent == "." || pathComponent == ".."
      ? "Attachment" : pathComponent
    return directory.appendingPathComponent(filename)
  }
}
