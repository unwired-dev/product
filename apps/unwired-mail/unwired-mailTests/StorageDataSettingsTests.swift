import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length type_body_length nesting

@Suite(.serialized)
struct StorageDataSettingsTests {
  private struct ExportFixture: Codable, Sendable {
    let assetContent: Data
    let body: String
    let categoryIds: [String]
    let profileId: String
  }

  private struct ExportResult {
    let data: Data
    let exportedAt: Date
    let identifiers: [String]
  }

  private struct StorageFixture {
    let metadataFile: URL
    let service: LocalMailStorageService
  }

  private actor ScriptedExportTransport: ProductSyncRecordTransport {
    struct Request: Sendable {
      let cursor: String?
      let limit: Int
    }

    private var pages: [EncryptedProductSyncPayloadPage]
    private(set) var requests: [Request] = []

    init(pages: [EncryptedProductSyncPayloadPage]) {
      self.pages = pages
    }

    func listEncryptedProductSyncPayloads(
      session _: ProductAccountSessionSnapshot,
      payloadIdentifierPrefix _: String,
      cursor: String?,
      limit: Int
    ) async throws -> EncryptedProductSyncPayloadPage {
      requests.append(Request(cursor: cursor, limit: limit))
      guard pages.isEmpty == false else { throw ProductSyncExportError.incompletePagination }
      return pages.removeFirst()
    }

    func recordedRequests() -> [Request] {
      requests
    }

    func getEncryptedProductSyncPayloads(
      session _: ProductAccountSessionSnapshot,
      payloadIdentifiers _: [String]
    ) async throws -> [EncryptedProductSyncPayload] {
      []
    }

    func putEncryptedProductSyncPayloadIfUnchanged(
      session _: ProductAccountSessionSnapshot,
      payloadIdentifier _: String,
      encryptedPayload _: ProductSyncEncryptedPayload,
      expectedUpdatedAt _: Int64?
    ) async throws -> EncryptedProductSyncPayload {
      throw ProductSyncExportError.incompletePagination
    }
  }

  private let session = ProductAccountSessionSnapshot(
    appleUserIdentifier: "apple-user",
    identityToken: "private-identity-token",
    productAccountId: "product-account",
    trustedDeviceId: "trusted-device"
  )

  @Test(.bug(id: 127))
  func productSyncExportDecryptsEveryPageIntoReadableSortedJSON() async throws {
    let result = try await makeProductSyncExport()
    let document = try JSONDecoder.productSyncExport.decode(
      ProductSyncExportDocument.self,
      from: result.data
    )

    #expect(document.exportedAt == result.exportedAt)
    #expect(document.formatVersion == 1)
    #expect(document.productAccountId == session.productAccountId)
    #expect(document.records.map(\.payloadIdentifier) == result.identifiers.sorted())
    let categoryRecord = try #require(
      document.records.first { $0.payloadIdentifier == "message-categories.v1.message-a" }
    )
    #expect(
      categoryRecord.value
        == .object([
          "assetContent": .string(Data("asset".utf8).base64EncodedString()),
          "body": .string("Semantic Draft body"),
          "categoryIds": .array([.string("important"), .string("travel")]),
          "profileId": .string("profile-a"),
        ])
    )
    let exportedText = try #require(String(data: result.data, encoding: .utf8))
    #expect(exportedText.contains(session.identityToken) == false)
    #expect(exportedText.contains(session.trustedDeviceId) == false)
  }

  @Test(.bug(id: 127))
  func productSyncExportFailsClosedWithoutLocalKeyMaterial() async {
    await #expect(throws: ProductSyncExportError.missingKeyMaterial) {
      try await ProductSyncExportService(
        keyMaterialStore: InMemoryProductSyncKeyMaterialStore(),
        transport: InMemoryProductSyncRecordTransport()
      ).export(session: session)
    }
  }

  @Test(.bug(id: 127))
  func productSyncExportSkipsRecoveryPayload() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let payload = try makeEncryptedPayload(
      identifier: "product-account-recovery-v1",
      material: material
    )
    let document = try await exportDocument(
      keyStore: keyStore,
      transport: ScriptedExportTransport(
        pages: [EncryptedProductSyncPayloadPage(continueCursor: "", isDone: true, page: [payload])]
      )
    )

    #expect(document.records.isEmpty)
  }

  @Test(.bug(id: 127))
  func productSyncExportAllowsMoreThanOneHundredPages() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let payloads = try (0..<101).map {
      try makeEncryptedPayload(identifier: "export-record-\($0)", material: material)
    }
    let pages = payloads.enumerated().map { index, payload in
      EncryptedProductSyncPayloadPage(
        continueCursor: index == payloads.count - 1 ? "" : String(index + 1),
        isDone: index == payloads.count - 1,
        page: [payload]
      )
    }
    let transport = ScriptedExportTransport(pages: pages)
    let document = try await exportDocument(
      keyStore: keyStore,
      transport: transport
    )

    #expect(document.records.count == 101)
    let requests = await transport.recordedRequests()
    let expectedCursors: [String?] = [nil] + (1..<101).map(String.init)
    #expect(requests.map(\.cursor) == expectedCursors)
    #expect(requests.allSatisfy { $0.limit == 100 })
  }

  @Test(.bug(id: 127))
  func productSyncExportRejectsDuplicatePayloadIdentifiers() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let payload = try makeEncryptedPayload(identifier: "duplicate", material: material)
    let transport = ScriptedExportTransport(pages: [
      EncryptedProductSyncPayloadPage(continueCursor: "next", isDone: false, page: [payload]),
      EncryptedProductSyncPayloadPage(continueCursor: "", isDone: true, page: [payload]),
    ])

    await #expect(throws: ProductSyncExportError.duplicatePayloadIdentifier) {
      try await ProductSyncExportService(keyMaterialStore: keyStore, transport: transport)
        .export(session: session)
    }
  }

  @Test(.bug(id: 127))
  func productSyncExportRejectsRepeatedPaginationCursor() async throws {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    let material = try keyStore.ensureMaterial(
      productAccountId: session.productAccountId,
      allowCreation: true
    )
    let payload = try makeEncryptedPayload(identifier: "repeated-cursor", material: material)
    let transport = ScriptedExportTransport(pages: [
      EncryptedProductSyncPayloadPage(continueCursor: "same", isDone: false, page: [payload]),
      EncryptedProductSyncPayloadPage(continueCursor: "same", isDone: false, page: []),
    ])

    await #expect(throws: ProductSyncExportError.incompletePagination) {
      try await ProductSyncExportService(keyMaterialStore: keyStore, transport: transport)
        .export(session: session)
    }
  }

  @Test(.bug(id: 127))
  func storageInspectionReportsPendingAssetsAndClearPreservesDurableData() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
      path: "StorageDataSettingsTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? fileManager.removeItem(at: root) }
    let fixture = try makeStorageFixture(root: root)

    let before = try await fixture.service.snapshot()
    #expect(before.cachedBodyByteCount == 7)
    #expect(before.downloadedAttachmentByteCount == 11)
    #expect(before.draftByteCount > 0)
    #expect(before.metadataByteCount == 5)
    #expect(before.pendingDraftAssetByteCount == 13)
    #expect(before.pendingDraftAssetCount == 1)

    try await fixture.service.clearEvictableContent()
    let after = try await fixture.service.snapshot()
    #expect(after.cachedBodyByteCount == 0)
    #expect(after.downloadedAttachmentByteCount == 0)
    #expect(after.draftByteCount == before.draftByteCount)
    #expect(after.metadataByteCount == 5)
    #expect(after.pendingDraftAssetByteCount == before.pendingDraftAssetByteCount)
    #expect(after.pendingDraftAssetCount == before.pendingDraftAssetCount)
    #expect(fileManager.fileExists(atPath: fixture.metadataFile.path))
  }

  @Test(.bug(id: 132))
  func signedOutStorageInspectionClearsOnlyDeviceCaches() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
      path: "SignedOutStorageDataSettingsTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? fileManager.removeItem(at: root) }
    let bodyDirectory = root.appending(path: "Bodies", directoryHint: .isDirectory)
    let attachmentDirectory = root.appending(path: "Attachments", directoryHint: .isDirectory)
    let draftDirectory = root.appending(path: "Drafts", directoryHint: .isDirectory)
    let metadataFile = root.appending(path: "Metadata.store")
    for directory in [bodyDirectory, attachmentDirectory, draftDirectory] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data(repeating: 0x01, count: 7).write(
      to: bodyDirectory.appending(path: "cached-body")
    )
    try Data(repeating: 0x02, count: 11).write(
      to: attachmentDirectory.appending(path: "attachment")
    )
    try Data(repeating: 0x03, count: 13).write(
      to: draftDirectory.appending(path: "draft")
    )
    try Data(repeating: 0x04, count: 5).write(to: metadataFile)
    let service = DeviceLocalMailStorageService(
      fileManager: fileManager,
      paths: LocalMailStoragePaths(
        attachmentDirectory: attachmentDirectory,
        bodyCacheDirectory: bodyDirectory,
        draftDirectory: draftDirectory,
        metadataLocations: [metadataFile]
      )
    )

    let before = try await service.snapshot()
    #expect(before.cachedBodyByteCount == 7)
    #expect(before.downloadedAttachmentByteCount == 11)
    #expect(before.draftByteCount == 13)
    #expect(before.metadataByteCount == 5)

    try await service.clearEvictableContent()
    let after = try await service.snapshot()
    #expect(after.cachedBodyByteCount == 0)
    #expect(after.downloadedAttachmentByteCount == 0)
    #expect(after.draftByteCount == 13)
    #expect(after.metadataByteCount == 5)
  }

  @MainActor
  @Test(.bug(id: 127))
  func cancellingExportClearsWorkingStateWithoutPresentingAFile() async {
    let viewModel = StorageDataSettingsViewModel(
      exporter: SuspendingProductSyncExporter(),
      readReceiptSummary: "Incoming: Ask Every Time. Outgoing: Never.",
      storage: EmptyLocalMailStorageManager()
    )

    viewModel.startExport(session: session)
    viewModel.cancelExport()
    await viewModel.waitForExport()

    #expect(viewModel.exportData == nil)
    #expect(viewModel.isExporting == false)
    #expect(viewModel.statusMessage == "Export cancelled.")
  }

  @MainActor
  @Test
  func reconfigurationDiscardsStaleRefreshAndLoadsReplacementStorage() async {
    let oldStorage = ControlledLocalMailStorageManager(
      snapshotValue: makeSnapshot(cachedBodyByteCount: 1),
      suspendsSnapshot: true
    )
    let newStorage = ControlledLocalMailStorageManager(
      snapshotValue: makeSnapshot(cachedBodyByteCount: 2),
      suspendsSnapshot: false
    )
    let viewModel = StorageDataSettingsViewModel(
      exporter: SuspendingProductSyncExporter(),
      readReceiptSummary: "Incoming: Ask Every Time. Outgoing: Never.",
      storage: oldStorage
    )

    let oldRefresh = Task { await viewModel.refresh() }
    await oldStorage.waitForSnapshotRequest()
    viewModel.updateConfiguration(
      session: session,
      profileIds: [MailProfileId(rawValue: "profile-a")],
      readingPreferences: .defaults,
      storage: newStorage
    )
    await newStorage.waitForSnapshotRequest()
    await oldStorage.releaseSnapshot()
    await oldRefresh.value

    #expect(viewModel.snapshot == makeSnapshot(cachedBodyByteCount: 2))
    #expect(viewModel.isLoading == false)
    #expect(viewModel.alertMessage == nil)
  }

  @MainActor
  @Test(.bug(id: 557))
  func failedRefreshRetainsStorageSnapshotUntilRetrySucceeds() async {
    let initialSnapshot = makeSnapshot(cachedBodyByteCount: 1)
    let recoveredSnapshot = makeSnapshot(cachedBodyByteCount: 2)
    let storage = RetryingLocalMailStorageManager(snapshot: initialSnapshot)
    let viewModel = StorageDataSettingsViewModel(
      exporter: SuspendingProductSyncExporter(),
      readReceiptSummary: "Incoming: Ask Every Time. Outgoing: Never.",
      storage: storage
    )
    await viewModel.refresh()
    await storage.failSnapshots()

    await viewModel.refresh()

    #expect(viewModel.snapshot == initialSnapshot)
    #expect(viewModel.loadErrorMessage != nil)
    #expect(viewModel.alertMessage == nil)

    await storage.resumeSnapshots(with: recoveredSnapshot)
    await viewModel.refresh()

    #expect(viewModel.snapshot == recoveredSnapshot)
    #expect(viewModel.loadErrorMessage == nil)
  }

  @MainActor
  @Test
  func reconfigurationDiscardsStaleClearSuccess() async {
    let oldStorage = ControlledLocalMailStorageManager(
      snapshotValue: makeSnapshot(cachedBodyByteCount: 1),
      suspendsSnapshot: false,
      suspendsClear: true
    )
    let newStorage = ControlledLocalMailStorageManager(
      snapshotValue: makeSnapshot(cachedBodyByteCount: 2),
      suspendsSnapshot: false
    )
    let viewModel = StorageDataSettingsViewModel(
      exporter: SuspendingProductSyncExporter(),
      readReceiptSummary: "Incoming: Ask Every Time. Outgoing: Never.",
      storage: oldStorage
    )

    let oldClear = Task { await viewModel.clearCaches() }
    await oldStorage.waitForClearRequest()
    viewModel.updateConfiguration(
      session: session,
      profileIds: [MailProfileId(rawValue: "profile-a")],
      readingPreferences: .defaults,
      storage: newStorage
    )
    await newStorage.waitForSnapshotRequest()
    await oldStorage.releaseClear()
    await oldClear.value

    #expect(viewModel.snapshot == makeSnapshot(cachedBodyByteCount: 2))
    #expect(viewModel.isClearing == false)
    #expect(viewModel.statusMessage == nil)
    #expect(viewModel.alertMessage == nil)
  }

  @MainActor
  @Test
  func reconfigurationDiscardsStaleClearFailure() async {
    let oldStorage = ControlledLocalMailStorageManager(
      snapshotValue: makeSnapshot(cachedBodyByteCount: 1),
      suspendsSnapshot: false,
      suspendsClear: true,
      clearError: .clearFailed
    )
    let newStorage = ControlledLocalMailStorageManager(
      snapshotValue: makeSnapshot(cachedBodyByteCount: 2),
      suspendsSnapshot: false
    )
    let viewModel = StorageDataSettingsViewModel(
      exporter: SuspendingProductSyncExporter(),
      readReceiptSummary: "Incoming: Ask Every Time. Outgoing: Never.",
      storage: oldStorage
    )

    let oldClear = Task { await viewModel.clearCaches() }
    await oldStorage.waitForClearRequest()
    viewModel.updateConfiguration(
      session: session,
      profileIds: [MailProfileId(rawValue: "profile-a")],
      readingPreferences: .defaults,
      storage: newStorage
    )
    await newStorage.waitForSnapshotRequest()
    await oldStorage.releaseClear()
    await oldClear.value

    #expect(viewModel.snapshot == makeSnapshot(cachedBodyByteCount: 2))
    #expect(viewModel.isClearing == false)
    #expect(viewModel.statusMessage == nil)
    #expect(viewModel.alertMessage == nil)
  }

  private func makeSnapshot(cachedBodyByteCount: Int64) -> LocalMailStorageSnapshot {
    LocalMailStorageSnapshot(
      cachedBodyByteCount: cachedBodyByteCount,
      downloadedAttachmentByteCount: 0,
      draftByteCount: 0,
      metadataByteCount: 0,
      pendingDraftAssetByteCount: 0,
      pendingDraftAssetCount: 0
    )
  }

  private func makeProductSyncExport() async throws -> ExportResult {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    let transport = InMemoryProductSyncRecordTransport(pageSize: 1)
    let boundary = ProductSyncRecordBoundary(keyMaterialStore: keyStore, transport: transport)
    let fixtures = [
      (
        "message-categories.v1.message-a",
        ExportFixture(
          assetContent: Data("asset".utf8),
          body: "Semantic Draft body",
          categoryIds: ["important", "travel"],
          profileId: "profile-a"
        )
      ),
      (
        "thread-pin.v2.thread-a",
        ExportFixture(assetContent: Data(), body: "", categoryIds: [], profileId: "profile-a")
      ),
    ]
    for (identifier, fixture) in fixtures.reversed() {
      let definition = ProductSyncSingletonDefinition<ExportFixture>(
        identifier: identifier,
        cachePolicy: .authoritative
      )
      _ = try await boundary.singleton(definition).update(session: session) { _ in .write(fixture) }
    }
    let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let data = try await ProductSyncExportService(
      keyMaterialStore: keyStore,
      now: { exportedAt },
      transport: transport
    ).export(session: session)
    return ExportResult(data: data, exportedAt: exportedAt, identifiers: fixtures.map(\.0))
  }

  private func makeEncryptedPayload(
    identifier: String,
    material: ProductSyncKeyMaterial
  ) throws -> EncryptedProductSyncPayload {
    let value = ExportFixture(
      assetContent: Data(), body: "value", categoryIds: [], profileId: "profile-a"
    )
    return EncryptedProductSyncPayload(
      encryptedPayload: try material.encryptPayload(
        JSONEncoder().encode(value),
        associatedData: Data(identifier.utf8)
      ),
      payloadIdentifier: identifier,
      updatedAt: 1
    )
  }

  private func exportDocument(
    keyStore: InMemoryProductSyncKeyMaterialStore,
    transport: ProductSyncRecordTransport
  ) async throws -> ProductSyncExportDocument {
    let data = try await ProductSyncExportService(
      keyMaterialStore: keyStore,
      transport: transport
    ).export(session: session)
    return try JSONDecoder.productSyncExport.decode(ProductSyncExportDocument.self, from: data)
  }

  private func makeStorageFixture(root: URL) throws -> StorageFixture {
    let fileManager = FileManager.default
    let bodyDirectory = root.appending(path: "Bodies", directoryHint: .isDirectory)
    let attachmentDirectory = root.appending(path: "Attachments", directoryHint: .isDirectory)
    let draftDirectory = root.appending(path: "Drafts", directoryHint: .isDirectory)
    let metadataFile = root.appending(path: "Metadata.store")
    try fileManager.createDirectory(at: bodyDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
    try Data(repeating: 0x01, count: 5).write(to: metadataFile)
    let bodyFile = bodyDirectory.appending(
      path: "\(gmailSafeFileComponent(session.productAccountId))-body.json"
    )
    try Data(repeating: 0x02, count: 7).write(to: bodyFile)
    try Data(repeating: 0x03, count: 11).write(
      to: attachmentDirectory.appending(path: "attachment.bin")
    )
    let service = LocalMailStorageService(
      productAccountId: session.productAccountId,
      profileIds: [MailProfileId(rawValue: "profile-a")],
      session: session,
      attachmentStore: DownloadedAttachmentStore(rootDirectory: attachmentDirectory),
      bodyCache: FileGmailMessageBodyCache(rootDirectory: bodyDirectory),
      draftRepository: try makeDraftRepository(root: draftDirectory),
      fileManager: fileManager,
      paths: LocalMailStoragePaths(
        attachmentDirectory: attachmentDirectory,
        bodyCacheDirectory: bodyDirectory,
        draftDirectory: draftDirectory,
        metadataLocations: [metadataFile]
      )
    )
    return StorageFixture(metadataFile: metadataFile, service: service)
  }

  private func makeDraftRepository(root: URL) throws -> MailCompositionDraftRepository {
    let keyStore = InMemoryProductSyncKeyMaterialStore()
    _ = try keyStore.ensureMaterial(productAccountId: session.productAccountId, allowCreation: true)
    var draft = MailShellCompositionDraft(
      body: "Draft body",
      connectionId: nil,
      recipient: "recipient@example.com",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "Draft"
    )
    draft.assets = [
      MailDraftAsset(
        data: Data(repeating: 0x04, count: 13),
        filename: "pending.bin",
        mediaType: "application/octet-stream"
      ).metadataOnly
    ]
    let store = FileMailCompositionDraftStore(
      keyMaterialStore: keyStore,
      rootDirectory: root
    )
    try store.save(
      draft,
      productAccountId: session.productAccountId,
      profileId: MailProfileId(rawValue: "profile-a")
    )
    return MailCompositionDraftRepository(
      store: store,
      syncService: FixedDraftSyncService(drafts: [draft])
    )
  }
}

extension JSONDecoder {
  fileprivate static var productSyncExport: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

private actor FixedDraftSyncService: MailCompositionDraftSyncing {
  let drafts: [MailShellCompositionDraft]

  init(drafts: [MailShellCompositionDraft]) {
    self.drafts = drafts
  }

  func snapshot(
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSnapshot {
    MailCompositionDraftSyncSnapshot(drafts: drafts, removedDraftIds: [])
  }

  func remove(
    _: UUID,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {}

  func save(
    _: MailShellCompositionDraft,
    profileId _: MailProfileId,
    session _: ProductAccountSessionSnapshot
  ) async throws {}
}

private actor SuspendingProductSyncExporter: ProductSyncExporting {
  func export(session _: ProductAccountSessionSnapshot) async throws -> Data {
    try await Task.sleep(for: .seconds(60))
    return Data()
  }
}

private actor EmptyLocalMailStorageManager: LocalMailStorageManaging {
  func clearEvictableContent() async throws {}

  func snapshot() async throws -> LocalMailStorageSnapshot {
    LocalMailStorageSnapshot(
      cachedBodyByteCount: 0,
      downloadedAttachmentByteCount: 0,
      draftByteCount: 0,
      metadataByteCount: 0,
      pendingDraftAssetByteCount: 0,
      pendingDraftAssetCount: 0
    )
  }
}

private enum StorageTestError: Error, Sendable {
  case clearFailed
  case snapshotFailed
}

private actor RetryingLocalMailStorageManager: LocalMailStorageManaging {
  private var snapshotValue: LocalMailStorageSnapshot
  private var snapshotsFail = false

  init(snapshot: LocalMailStorageSnapshot) {
    snapshotValue = snapshot
  }

  func clearEvictableContent() async throws {}

  func snapshot() async throws -> LocalMailStorageSnapshot {
    if snapshotsFail { throw StorageTestError.snapshotFailed }
    return snapshotValue
  }

  func failSnapshots() {
    snapshotsFail = true
  }

  func resumeSnapshots(with snapshot: LocalMailStorageSnapshot) {
    snapshotValue = snapshot
    snapshotsFail = false
  }
}

private actor ControlledLocalMailStorageManager: LocalMailStorageManaging {
  private let snapshotValue: LocalMailStorageSnapshot
  private let suspendsSnapshot: Bool
  private let suspendsClear: Bool
  private let clearError: StorageTestError?
  private var snapshotRequested = false
  private var snapshotRequestContinuation: CheckedContinuation<Void, Never>?
  private var snapshotReleaseContinuation: CheckedContinuation<Void, Never>?
  private var clearRequested = false
  private var clearRequestContinuation: CheckedContinuation<Void, Never>?
  private var clearReleaseContinuation: CheckedContinuation<Void, Never>?

  init(
    snapshotValue: LocalMailStorageSnapshot,
    suspendsSnapshot: Bool,
    suspendsClear: Bool = false,
    clearError: StorageTestError? = nil
  ) {
    self.snapshotValue = snapshotValue
    self.suspendsSnapshot = suspendsSnapshot
    self.suspendsClear = suspendsClear
    self.clearError = clearError
  }

  func clearEvictableContent() async throws {
    clearRequested = true
    clearRequestContinuation?.resume()
    clearRequestContinuation = nil
    if suspendsClear {
      await withCheckedContinuation { continuation in
        clearReleaseContinuation = continuation
      }
    }
    if let clearError {
      throw clearError
    }
  }

  func snapshot() async throws -> LocalMailStorageSnapshot {
    snapshotRequested = true
    snapshotRequestContinuation?.resume()
    snapshotRequestContinuation = nil
    if suspendsSnapshot {
      await withCheckedContinuation { continuation in
        snapshotReleaseContinuation = continuation
      }
    }
    return snapshotValue
  }

  func waitForSnapshotRequest() async {
    guard !snapshotRequested else { return }
    await withCheckedContinuation { continuation in
      snapshotRequestContinuation = continuation
    }
  }

  func waitForClearRequest() async {
    guard !clearRequested else { return }
    await withCheckedContinuation { continuation in
      clearRequestContinuation = continuation
    }
  }

  func releaseSnapshot() {
    snapshotReleaseContinuation?.resume()
    snapshotReleaseContinuation = nil
  }

  func releaseClear() {
    clearReleaseContinuation?.resume()
    clearReleaseContinuation = nil
  }
}
