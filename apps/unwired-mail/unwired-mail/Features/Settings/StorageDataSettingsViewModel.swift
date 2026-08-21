import Foundation

struct LocalMailStorageSnapshot: Equatable, Sendable {
  static let draftStorageLimit: Int64 = 100 * 1_024 * 1_024

  let cachedBodyByteCount: Int64
  let downloadedAttachmentByteCount: Int64
  let draftByteCount: Int64
  let metadataByteCount: Int64
  let pendingDraftAssetByteCount: Int64
  let pendingDraftAssetCount: Int

  var totalByteCount: Int64 {
    cachedBodyByteCount + downloadedAttachmentByteCount + draftByteCount + metadataByteCount
  }
}

protocol LocalMailStorageManaging: Sendable {
  /// Removes only device-local message bodies and downloaded incoming attachments.
  func clearEvictableContent() async throws

  /// Returns current device-local mail storage usage and pending Draft-asset state.
  func snapshot() async throws -> LocalMailStorageSnapshot
}

struct LocalMailStoragePaths: Sendable {
  let attachmentDirectory: URL
  let bodyCacheDirectory: URL
  let draftDirectory: URL
  let metadataLocations: [URL]

  static func live(fileManager: FileManager = .default) -> Self {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    let unwiredMail = applicationSupport.appending(
      path: "UnwiredMail",
      directoryHint: .isDirectory
    )
    let swiftDataStoreNames = [
      "EWSMetadata", "GmailMetadata", "IMAPMetadata", "MicrosoftGraphMetadata",
    ]
    let swiftDataLocations = swiftDataStoreNames.flatMap { name in
      [
        applicationSupport.appending(path: "\(name).store"),
        applicationSupport.appending(path: "\(name).store-shm"),
        applicationSupport.appending(path: "\(name).store-wal"),
      ]
    }
    return Self(
      attachmentDirectory: unwiredMail.appending(
        path: "DownloadedAttachments",
        directoryHint: .isDirectory
      ),
      bodyCacheDirectory: unwiredMail.appending(
        path: "GmailBodyCache",
        directoryHint: .isDirectory
      ),
      draftDirectory: unwiredMail.appending(path: "Drafts", directoryHint: .isDirectory),
      metadataLocations: swiftDataLocations + [
        unwiredMail.appending(path: "GmailMetadata", directoryHint: .isDirectory)
      ]
    )
  }
}

/// Inspects the app's known local mail stores without deleting durable user data.
actor LocalMailStorageService: LocalMailStorageManaging {
  private let attachmentStore: DownloadedAttachmentStore
  private let bodyCache: GmailMessageBodyCaching
  private let draftRepository: MailCompositionDraftRepository
  private let fileManager: FileManager
  private let paths: LocalMailStoragePaths
  private let productAccountId: String
  private let profileIds: [MailProfileId]
  private let session: ProductAccountSessionSnapshot

  init(
    productAccountId: String,
    profileIds: [MailProfileId],
    session: ProductAccountSessionSnapshot,
    attachmentStore: DownloadedAttachmentStore = DownloadedAttachmentStore(),
    bodyCache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    draftRepository: MailCompositionDraftRepository = MailCompositionDraftRepository(),
    fileManager: FileManager = .default,
    paths: LocalMailStoragePaths? = nil
  ) {
    self.attachmentStore = attachmentStore
    self.bodyCache = bodyCache
    self.draftRepository = draftRepository
    self.fileManager = fileManager
    self.paths = paths ?? .live(fileManager: fileManager)
    self.productAccountId = productAccountId
    self.profileIds = profileIds
    self.session = session
  }

  func snapshot() async throws -> LocalMailStorageSnapshot {
    var drafts: [MailShellCompositionDraft] = []
    for profileId in profileIds {
      try Task.checkCancellation()
      drafts += try await draftRepository.drafts(
        productAccountId: productAccountId,
        profileId: profileId,
        session: nil
      )
    }
    let pendingAssets = drafts.flatMap(\.assets).filter { $0.isComplete == false }
    return LocalMailStorageSnapshot(
      cachedBodyByteCount: cachedBodyByteCount(),
      downloadedAttachmentByteCount: fileByteCount(at: paths.attachmentDirectory),
      draftByteCount: fileByteCount(at: paths.draftDirectory),
      metadataByteCount: paths.metadataLocations.reduce(0) {
        $0 + fileByteCount(at: $1)
      },
      pendingDraftAssetByteCount: pendingAssets.reduce(0) {
        $0 + Int64($1.byteCount)
      },
      pendingDraftAssetCount: pendingAssets.count
    )
  }

  func clearEvictableContent() async throws {
    try Task.checkCancellation()
    try bodyCache.clearMessageBodies(productAccountId: productAccountId)
    try Task.checkCancellation()
    try attachmentStore.clearAll()
  }

  private func cachedBodyByteCount() -> Int64 {
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: paths.bodyCacheDirectory,
        includingPropertiesForKeys: [.fileSizeKey]
      )
    else { return 0 }
    let prefixes = [
      "\(gmailSafeFileComponent(productAccountId))-",
      "\(legacyGmailSafeFileComponent(productAccountId))-",
    ]
    return contents.reduce(0) { total, location in
      guard prefixes.contains(where: location.lastPathComponent.hasPrefix) else { return total }
      return total + fileByteCount(at: location)
    }
  }

  private func fileByteCount(at location: URL) -> Int64 {
    guard fileManager.fileExists(atPath: location.path) else { return 0 }
    if let values = try? location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let size = values.fileSize
    {
      return Int64(size)
    }
    guard
      let enumerator = fileManager.enumerator(
        at: location,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return 0 }
    return enumerator.reduce(into: Int64.zero) { total, element in
      guard let file = element as? URL,
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true,
        let size = values.fileSize
      else { return }
      total += Int64(size)
    }
  }
}

@MainActor
@Observable
final class StorageDataSettingsViewModel {
  private(set) var alertMessage: String?
  private(set) var exportData: Data?
  private(set) var isClearing = false
  private(set) var isExporting = false
  private(set) var isLoading = false
  private(set) var snapshot: LocalMailStorageSnapshot?
  private(set) var statusMessage: String?

  private(set) var readReceiptSummary: String

  private let exporter: ProductSyncExporting
  private var storage: LocalMailStorageManaging
  private var exportTask: Task<Void, Never>?
  private var exportGeneration = 0

  init(
    exporter: ProductSyncExporting,
    readReceiptSummary: String,
    storage: LocalMailStorageManaging
  ) {
    self.exporter = exporter
    self.readReceiptSummary = readReceiptSummary
    self.storage = storage
  }

  func updateConfiguration(
    session: ProductAccountSessionSnapshot,
    profileIds: [MailProfileId],
    readingPreferences: ReadingPreferences,
    draftRepository: MailCompositionDraftRepository = MailCompositionDraftRepository()
  ) {
    exportTask?.cancel()
    exportGeneration += 1
    isExporting = false
    exportData = nil
    snapshot = nil
    statusMessage = nil
    storage = LocalMailStorageService(
      productAccountId: session.productAccountId,
      profileIds: profileIds,
      session: session,
      draftRepository: draftRepository
    )
    readReceiptSummary = Self.readReceiptSummary(for: readingPreferences)
  }

  func refresh() async {
    isLoading = true
    defer { isLoading = false }
    do {
      snapshot = try await storage.snapshot()
    } catch is CancellationError {
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func clearCaches() async {
    guard !isClearing else { return }
    isClearing = true
    statusMessage = nil
    defer { isClearing = false }
    do {
      try await storage.clearEvictableContent()
      try Task.checkCancellation()
      snapshot = try await storage.snapshot()
      statusMessage = "Cached bodies and downloaded attachments cleared."
    } catch is CancellationError {
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func startExport(session: ProductAccountSessionSnapshot) {
    exportTask?.cancel()
    exportGeneration += 1
    let generation = exportGeneration
    isExporting = true
    statusMessage = nil
    exportTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == exportGeneration {
          isExporting = false
          exportTask = nil
        }
      }
      do {
        let data = try await exporter.export(session: session)
        try Task.checkCancellation()
        guard generation == exportGeneration else { return }
        exportData = data
      } catch is CancellationError {
        guard generation == exportGeneration else { return }
        statusMessage = "Export cancelled."
      } catch {
        guard generation == exportGeneration else { return }
        alertMessage = error.localizedDescription
      }
    }
  }

  func cancelExport() {
    exportTask?.cancel()
  }

  func clearAlert() {
    alertMessage = nil
  }

  func finishExport() {
    exportData = nil
  }

  func presentFileExportError(_ error: Error) {
    alertMessage = error.localizedDescription
  }

  func waitForExport() async {
    await exportTask?.value
  }

}

extension StorageDataSettingsViewModel {
  static func live(
    session: ProductAccountSessionSnapshot,
    profileIds: [MailProfileId],
    readingPreferences: ReadingPreferences,
    draftRepository: MailCompositionDraftRepository = MailCompositionDraftRepository()
  ) -> StorageDataSettingsViewModel {
    return StorageDataSettingsViewModel(
      exporter: ProductSyncExportService(),
      readReceiptSummary: Self.readReceiptSummary(for: readingPreferences),
      storage: LocalMailStorageService(
        productAccountId: session.productAccountId,
        profileIds: profileIds,
        session: session,
        draftRepository: draftRepository
      )
    )
  }

  private static func readReceiptSummary(for readingPreferences: ReadingPreferences) -> String {
    let overrideCount = readingPreferences.connectionOverrides.values.filter {
      $0.isEmpty == false
    }.count
    let overrideSummary = overrideCount == 0 ? "" : " \(overrideCount) connection override(s)."
    return "Incoming: \(readingPreferences.incomingReadReceipts.title). "
      + "Outgoing: \(readingPreferences.outgoingReadReceipts.title)."
      + overrideSummary
  }
}
