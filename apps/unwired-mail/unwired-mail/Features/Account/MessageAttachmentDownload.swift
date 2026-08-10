import CryptoKit
import Network
import Observation
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

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

enum AttachmentPreviewAvailability: Equatable {
  case quickLook
  case thumbnailAndQuickLook
  case unavailable

  init(attachment: MailboxMessageAttachment) {
    let mimeContentType = UTType(mimeType: attachment.mimeType)
    let filenameContentType = UTType(
      filenameExtension: URL(fileURLWithPath: attachment.filename).pathExtension
    )
    let contentType =
      mimeContentType == .data
      ? filenameContentType ?? mimeContentType
      : mimeContentType ?? filenameContentType
    guard let contentType else {
      self = .unavailable
      return
    }
    if contentType.conforms(to: .image) || contentType.conforms(to: .pdf) {
      self = .thumbnailAndQuickLook
    } else if contentType.conforms(to: .plainText)
      || contentType.conforms(to: .audio)
      || contentType.conforms(to: .movie)
    {
      self = .quickLook
    } else {
      self = .unavailable
    }
  }

  var supportsQuickLook: Bool {
    self != .unavailable
  }

  var supportsThumbnail: Bool {
    self == .thumbnailAndQuickLook
  }
}

enum AttachmentDownloadGate {
  static let maximumByteCount = MailboxMessageAttachmentPolicy.maximumByteCount

  static func allowsDownload(
    policy: AttachmentDownloadPolicy,
    network: AttachmentDownloadNetwork,
    trigger: AttachmentDownloadTrigger,
    isLocallyAvailable: Bool = false
  ) -> Bool {
    switch trigger {
    case .userInitiated:
      return isLocallyAvailable || network != .offline
    case .automatic:
      guard policy != .onDemand else { return false }
      return isLocallyAvailable || policy.allowsAutomaticDownload(on: network)
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
      allowsDownload(
        policy: policy,
        network: network,
        trigger: trigger,
        isLocallyAvailable: isLocallyAvailable
      )
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
  @State private var isDownloading = false
  @State private var quickLookURL: URL?
  @State private var requestTracker = AttachmentDownloadRequestTracker()

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let downloadedURL, previewAvailability.supportsThumbnail {
        Button {
          presentQuickLook()
        } label: {
          AttachmentThumbnail(
            url: downloadedURL,
            accessURL: accessPreviewURL
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(attachment.filename)")
      } else {
        Image(systemName: "paperclip")
          .frame(width: 56, height: 56)
          .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      }
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
        } else {
          Text(downloadStateDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(previewStateDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let downloadedURL {
        if previewAvailability.supportsQuickLook {
          Button {
            presentQuickLook()
          } label: {
            Label("Quick Look", systemImage: "eye")
          }
          .accessibilityIdentifier("preview-message-attachment")
        } else {
          ShareLink(item: downloadedURL) {
            Label("Share / Open", systemImage: "square.and.arrow.up")
          }
        }
      } else {
        Button(errorMessage == nil ? "Download" : "Try Again") {
          requestTracker.request()
        }
        .accessibilityIdentifier("download-message-attachment")
        .disabled(isPresentationDataUnavailable)
      }
    }
    .quickLookPreview($quickLookURL)
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
        !AttachmentDownloadGate.allowsDownload(
          policy: policy,
          network: network,
          trigger: trigger,
          isLocallyAvailable: isLocallyAvailable
        )
      {
        return
      }
      do {
        let writePermit = store.makeWritePermit(connectionId: messageId.connectionId)
        if trigger == .automatic {
          guard await AutomaticAttachmentDownloadCoordinator.shared.acquire() else { return }
        }
        isDownloading = true
        defer {
          isDownloading = false
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
      quickLookURL = nil
    }
  }

  private var previewAvailability: AttachmentPreviewAvailability {
    AttachmentPreviewAvailability(attachment: attachment)
  }

  private var downloadStateDescription: String {
    if downloadedURL != nil { return "Downloaded" }
    if isDownloading { return "Downloading…" }
    if isPresentationDataUnavailable {
      return "Close another open message, then reopen this message to load the attachment."
    }
    if attachment.byteCount > AttachmentDownloadGate.maximumByteCount {
      return "Exceeds the 25 MB download limit"
    }
    let policy = preferences?.attachmentDownloadPolicy ?? .onDemand
    let network = networkMonitor?.network ?? .offline
    if network == .offline { return "Offline · \(policy.title) policy" }
    if policy == .wifi, network == .cellular { return "Waiting for Wi-Fi" }
    if policy == .onDemand { return "Available on demand" }
    return "Ready · \(policy.title) policy"
  }

  private var previewStateDescription: String {
    switch (previewAvailability, downloadedURL != nil) {
    case (.thumbnailAndQuickLook, true):
      return "Thumbnail and Quick Look available"
    case (.thumbnailAndQuickLook, false):
      return "Thumbnail and Quick Look after download"
    case (.quickLook, true):
      return "Quick Look available"
    case (.quickLook, false):
      return "Quick Look after download"
    case (.unavailable, true):
      return "Quick Look unavailable · use Share / Open"
    case (.unavailable, false):
      return "Quick Look unavailable after download"
    }
  }

  private func accessPreviewURL() -> URL? {
    do {
      return try store.previewURL(attachment: attachment, messageId: messageId)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func presentQuickLook() {
    guard let url = accessPreviewURL() else {
      downloadedURL = nil
      quickLookURL = nil
      return
    }
    quickLookURL = url
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

private struct AttachmentThumbnail: View {
  let url: URL
  let accessURL: () -> URL?

  @Environment(\.displayScale) private var displayScale
  @State private var image: Image?

  var body: some View {
    Group {
      if let image {
        image
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "doc")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 56, height: 56)
    .background(.secondary.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .task(id: url) {
      guard let accessedURL = accessURL() else { return }
      image = await AttachmentThumbnailGenerator.image(
        for: accessedURL,
        size: CGSize(width: 56, height: 56),
        scale: displayScale
      )
    }
  }
}

private enum AttachmentThumbnailGenerator {
  static func image(for url: URL, size: CGSize, scale: CGFloat) async -> Image? {
    let generator = QLThumbnailGenerator.shared
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: size,
      scale: scale,
      representationTypes: .thumbnail
    )
    let representation = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        generator.generateBestRepresentation(for: request) { representation, _ in
          continuation.resume(returning: representation)
        }
      }
    } onCancel: {
      generator.cancel(request)
    }
    guard !Task.isCancelled, let representation else { return nil }
    return Image(decorative: representation.cgImage, scale: scale)
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
  private let notificationCenter: NotificationCenter
  private let rootDirectory: URL

  init(
    fileManager: FileManager = .default,
    rootDirectory: URL? = nil,
    maximumStoredByteCount: Int = Self.maximumStoredByteCount,
    notificationCenter: NotificationCenter = .default
  ) {
    self.fileManager = fileManager
    self.maximumStoredByteCount = maximumStoredByteCount
    self.notificationCenter = notificationCenter
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

  func previewURL(
    attachment: MailboxMessageAttachment,
    messageId: StableProviderMessageIdentity,
    accessedAt: Date = Date()
  ) throws -> URL? {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let destination = destinationURL(attachment: attachment, messageId: messageId)
    guard fileManager.fileExists(atPath: destination.path) else { return nil }
    try fileManager.setAttributes(
      [.modificationDate: accessedAt],
      ofItemAtPath: destination.path
    )
    return destination
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
    let isSeparatorOnly = pathComponent.trimmingCharacters(
      in: CharacterSet(charactersIn: "/\\")
    ).isEmpty
    let displayFilename =
      isSeparatorOnly || pathComponent == "." || pathComponent == ".."
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
      Task { @MainActor [notificationCenter] in
        notificationCenter.post(name: .downloadedAttachmentStoreDidEvict, object: nil)
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
