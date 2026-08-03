import CryptoKit
import Network
import Observation
import SwiftUI

// swiftlint:disable file_length

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
    return .userInitiated
  }

  mutating func finish(requestCount handledRequestCount: Int) {
    consumedRequestCount = max(consumedRequestCount, min(handledRequestCount, requestCount))
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
  static let maximumByteCount = MailboxMessageAttachmentPolicy.maximumByteCount

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
    isLocallyAvailable: Bool = false,
    using operation: () async throws -> Data
  ) async throws -> Data {
    guard isLocallyAvailable || network != .offline else {
      throw AttachmentDownloadError.networkUnavailable
    }
    guard
      isLocallyAvailable
        || allowsDownload(policy: policy, network: network, trigger: trigger)
    else {
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
final class AutomaticAttachmentDownloadCoordinator {
  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let id: UUID
  }
  static let shared = AutomaticAttachmentDownloadCoordinator()

  private let maximumConcurrentDownloads: Int
  private var activeDownloadCount = 0
  private var waiters: [Waiter] = []

  init(maximumConcurrentDownloads: Int = 3) {
    self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
  }

  func acquire() async -> Bool {
    if activeDownloadCount < maximumConcurrentDownloads {
      activeDownloadCount += 1
      return true
    }
    let waiterId = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters.append(Waiter(continuation: continuation, id: waiterId))
      }
    } onCancel: {
      Task { @MainActor in self.cancelWaiter(waiterId) }
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      activeDownloadCount -= 1
      return
    }
    waiters.removeFirst().continuation.resume(returning: true)
  }

  private func cancelWaiter(_ waiterId: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterId }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
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
  let store: DownloadedAttachmentStore
  let download: (MailboxMessageAttachment) async throws -> Data

  init(
    attachments: [MailboxMessageAttachment],
    messageId: StableProviderMessageIdentity,
    store: DownloadedAttachmentStore = DownloadedAttachmentStore(),
    download: @escaping (MailboxMessageAttachment) async throws -> Data
  ) {
    self.attachments = attachments
    self.messageId = messageId
    self.store = store
    self.download = download
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Attachments")
        .font(.subheadline.bold())
      ForEach(attachments) { attachment in
        MessageAttachmentRow(
          attachment: attachment,
          messageId: messageId,
          store: store,
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
  let store: DownloadedAttachmentStore
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
        } else if isPresentationDataUnavailable {
          Text("Close another open message, then reopen this message to load the attachment.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
        .disabled(isPresentationDataUnavailable)
      }
    }
    .task(id: taskId) {
      let handledRequestCount = requestTracker.requestCount
      let trigger = requestTracker.consumeTrigger()
      let policy = preferences?.attachmentDownloadPolicy ?? .onDemand
      let network = networkMonitor?.network ?? .offline
      let isLocallyAvailable = attachment.presentationData != nil
      if let existingURL = store.existingURL(attachment: attachment, messageId: messageId) {
        downloadedURL = existingURL
        requestTracker.finish(requestCount: handledRequestCount)
        return
      }
      if case .automatic = trigger,
        !isLocallyAvailable,
        !AttachmentDownloadGate.allowsDownload(
          policy: policy,
          network: network,
          trigger: trigger
        )
      {
        return
      }
      do {
        let writePermit = store.makeWritePermit(connectionId: messageId.connectionId)
        if trigger == .automatic {
          guard await AutomaticAttachmentDownloadCoordinator.shared.acquire() else { return }
        }
        defer {
          if trigger == .automatic {
            AutomaticAttachmentDownloadCoordinator.shared.release()
          }
        }
        let data = try await AttachmentDownloadGate.download(
          policy: policy,
          network: network,
          trigger: trigger,
          expectedByteCount: attachment.byteCount,
          isLocallyAvailable: isLocallyAvailable
        ) {
          try await download(attachment)
        }
        downloadedURL = try await Task.detached(priority: .utility) {
          try store.save(
            data,
            attachment: attachment,
            messageId: messageId,
            writePermit: writePermit
          )
        }.value
        errorMessage = nil
        requestTracker.finish(requestCount: handledRequestCount)
      } catch is CancellationError {
        requestTracker.finish(requestCount: handledRequestCount)
      } catch {
        errorMessage = error.localizedDescription
        requestTracker.finish(requestCount: handledRequestCount)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .downloadedAttachmentStoreDidEvict)) { _ in
      guard downloadedURL != nil,
        store.existingURL(attachment: attachment, messageId: messageId) == nil
      else { return }
      downloadedURL = nil
    }
  }

  private var taskId: String {
    let policy = preferences?.attachmentDownloadPolicy.rawValue ?? "onDemand"
    let network = String(describing: networkMonitor?.network ?? .offline)
    return "\(policy):\(network):\(requestTracker.requestCount)"
  }

  private var isPresentationDataUnavailable: Bool {
    attachment.id.hasPrefix(GmailMessageAttachmentIdentifier.inlineDataPrefix)
      && attachment.presentationData == nil
  }
}

struct DownloadedAttachmentStore: @unchecked Sendable {
  struct WritePermit: Sendable {
    fileprivate let connectionGeneration: Int
    fileprivate let connectionKey: String
    fileprivate let rootGeneration: Int
    fileprivate let rootKey: String
  }

  private struct StoredFile {
    let date: Date
    let size: Int
    let url: URL
  }

  static let maximumStoredByteCount = 250 * 1_024 * 1_024
  private static let mutationLock = NSLock()
  private static var connectionGenerations: [String: Int] = [:]
  private static var rootGenerations: [String: Int] = [:]

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
    messageId: StableProviderMessageIdentity,
    writePermit: WritePermit? = nil
  ) throws -> URL {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    if let writePermit {
      guard writePermit.rootKey == rootKey,
        writePermit.connectionKey == connectionKey(messageId.connectionId),
        writePermit.rootGeneration == Self.rootGenerations[rootKey, default: 0],
        writePermit.connectionGeneration
          == Self.connectionGenerations[writePermit.connectionKey, default: 0]
      else { throw CancellationError() }
    }
    let destination = destinationURL(attachment: attachment, messageId: messageId)
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try makeRoom(for: data.count, excluding: destination)
    try data.write(to: destination, options: [.atomic, .completeFileProtection])
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var protectedDestination = destination
    try protectedDestination.setResourceValues(resourceValues)
    return destination
  }

  func makeWritePermit(connectionId: MailboxConnectionId) -> WritePermit {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let connectionKey = connectionKey(connectionId)
    return WritePermit(
      connectionGeneration: Self.connectionGenerations[connectionKey, default: 0],
      connectionKey: connectionKey,
      rootGeneration: Self.rootGenerations[rootKey, default: 0],
      rootKey: rootKey
    )
  }

  func existingURL(
    attachment: MailboxMessageAttachment,
    messageId: StableProviderMessageIdentity
  ) -> URL? {
    let destination = destinationURL(attachment: attachment, messageId: messageId)
    return fileManager.fileExists(atPath: destination.path) ? destination : nil
  }

  func clear(connectionId: MailboxConnectionId) throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let key = connectionKey(connectionId)
    Self.connectionGenerations[key, default: 0] += 1
    let directory = connectionDirectory(connectionId)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }

  func clearAll() throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    Self.rootGenerations[rootKey, default: 0] += 1
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
    let displayFilename =
      pathComponent.isEmpty || pathComponent == "." || pathComponent == ".."
      ? "Attachment" : pathComponent
    let filename = persistedFilename(displayFilename)
    return directory.appendingPathComponent(filename)
  }

  private func persistedFilename(_ filename: String) -> String {
    guard filename.utf8.count > 200 else { return filename }
    let digest = SHA256.hash(data: Data(filename.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let pathExtension = URL(fileURLWithPath: filename).pathExtension
    let suffix = pathExtension.utf8.count <= 32 && !pathExtension.isEmpty ? ".\(pathExtension)" : ""
    return "Attachment-\(digest)\(suffix)"
  }

  private func connectionDirectory(_ connectionId: MailboxConnectionId) -> URL {
    let digest = SHA256.hash(data: Data(connectionId.rawValue.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return rootDirectory.appendingPathComponent(digest, isDirectory: true)
  }

  private var rootKey: String {
    rootDirectory.standardizedFileURL.path
  }

  private func connectionKey(_ connectionId: MailboxConnectionId) -> String {
    "\(rootKey):\(connectionDirectory(connectionId).lastPathComponent)"
  }

  private func makeRoom(for byteCount: Int, excluding destination: URL) throws {
    guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    guard
      let enumerator = fileManager.enumerator(
        at: rootDirectory,
        includingPropertiesForKeys: Array(keys)
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
      Task { @MainActor in
        NotificationCenter.default.post(name: .downloadedAttachmentStoreDidEvict, object: nil)
      }
      storedByteCount -= file.size
    }
  }
}

extension Notification.Name {
  static let downloadedAttachmentStoreDidEvict = Notification.Name(
    "DownloadedAttachmentStoreDidEvict"
  )
}
