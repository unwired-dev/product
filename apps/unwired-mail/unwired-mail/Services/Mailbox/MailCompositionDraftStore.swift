import Foundation

enum MailCompositionDraftStoreError: LocalizedError, Equatable {
  case storageLimitExceeded

  var errorDescription: String? {
    switch self {
    case .storageLimitExceeded:
      "Draft storage is full. Remove another Draft before continuing."
    }
  }
}

protocol MailCompositionDraftPersisting: Sendable {
  func clear(productAccountId: String) throws
  func load(
    productAccountId: String,
    profileId: MailProfileId
  ) throws -> [MailShellCompositionDraft]
  func remove(
    _ draftId: UUID,
    productAccountId: String,
    profileId: MailProfileId
  ) throws
  func save(
    _ draft: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId
  ) throws
}

private struct EncryptedMailCompositionDraftFile: Codable {
  let payload: ProductSyncEncryptedPayload
}

struct FileMailCompositionDraftStore: MailCompositionDraftPersisting, @unchecked Sendable {
  static let deviceStorageLimit = 100 * 1_024 * 1_024
  private static let mutationLock = NSLock()

  private let fileManager: FileManager
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let legacyRootDirectory: URL?
  private let quotaDirectory: URL
  private let rootDirectory: URL
  private let storageLimit: Int

  init(
    fileManager: FileManager = .default,
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    rootDirectory: URL? = nil,
    storageLimit: Int = Self.deviceStorageLimit
  ) {
    self.fileManager = fileManager
    self.keyMaterialStore = keyMaterialStore
    let legacyRootDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appending(path: "UnwiredMail/Drafts", directoryHint: .isDirectory)
    if let rootDirectory {
      self.rootDirectory = rootDirectory
      self.quotaDirectory = rootDirectory
      self.legacyRootDirectory = nil
    } else if let sharedRootDirectory = ShareExtensionConfiguration.sharedRootDirectory(
      fileManager: fileManager
    ) {
      self.rootDirectory = sharedRootDirectory.appending(
        path: "Drafts",
        directoryHint: .isDirectory
      )
      self.quotaDirectory = sharedRootDirectory
      self.legacyRootDirectory = legacyRootDirectory
    } else {
      self.rootDirectory = legacyRootDirectory
      self.quotaDirectory = legacyRootDirectory
      self.legacyRootDirectory = nil
    }
    self.storageLimit = storageLimit
  }

  func clear(productAccountId: String) throws {
    try Self.mutationLock.withLock {
      try migrateLegacyRootIfNeeded()
      let directory = accountDirectory(productAccountId: productAccountId)
      guard fileManager.fileExists(atPath: directory.path) else { return }
      try fileManager.removeItem(at: directory)
    }
  }

  func load(
    productAccountId: String,
    profileId: MailProfileId
  ) throws -> [MailShellCompositionDraft] {
    try Self.mutationLock.withLock {
      try migrateLegacyRootIfNeeded()
      return try loadWithoutLock(productAccountId: productAccountId, profileId: profileId)
    }
  }

  private func loadWithoutLock(
    productAccountId: String,
    profileId: MailProfileId
  ) throws -> [MailShellCompositionDraft] {
    let file = fileURL(productAccountId: productAccountId, profileId: profileId)
    guard fileManager.fileExists(atPath: file.path) else { return [] }
    let encryptedFile = try JSONDecoder().decode(
      EncryptedMailCompositionDraftFile.self,
      from: Data(contentsOf: file)
    )
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: false
    )
    let plaintext = try material.decryptPayload(
      encryptedFile.payload,
      associatedData: associatedData(productAccountId: productAccountId, profileId: profileId)
    )
    return try JSONDecoder().decode([MailShellCompositionDraft].self, from: plaintext)
      .sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
  }

  func remove(
    _ draftId: UUID,
    productAccountId: String,
    profileId: MailProfileId
  ) throws {
    try Self.mutationLock.withLock {
      try migrateLegacyRootIfNeeded()
      let remaining = try loadForMutation(
        productAccountId: productAccountId,
        profileId: profileId
      ).filter { $0.id != draftId }
      try write(remaining, productAccountId: productAccountId, profileId: profileId)
    }
  }

  func save(
    _ draft: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId
  ) throws {
    try Self.mutationLock.withLock {
      try migrateLegacyRootIfNeeded()
      var drafts = try loadForMutation(productAccountId: productAccountId, profileId: profileId)
      if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
        drafts[index] = draft
      } else {
        drafts.append(draft)
      }
      try write(
        drafts.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds },
        productAccountId: productAccountId,
        profileId: profileId
      )
    }
  }

  private func write(
    _ drafts: [MailShellCompositionDraft],
    productAccountId: String,
    profileId: MailProfileId
  ) throws {
    let file = fileURL(productAccountId: productAccountId, profileId: profileId)
    guard !drafts.isEmpty else {
      if fileManager.fileExists(atPath: file.path) {
        try fileManager.removeItem(at: file)
      }
      return
    }

    let plaintext = try JSONEncoder().encode(drafts)
    let material = try keyMaterialStore.ensureMaterial(
      productAccountId: productAccountId,
      allowCreation: false
    )
    let payload = try material.encryptPayload(
      plaintext,
      associatedData: associatedData(productAccountId: productAccountId, profileId: profileId)
    )
    let encryptedData = try JSONEncoder().encode(
      EncryptedMailCompositionDraftFile(payload: payload))
    let currentFileSize = fileSize(file)
    let projectedSize = directorySize(quotaDirectory) - currentFileSize + encryptedData.count
    guard projectedSize <= storageLimit else {
      throw MailCompositionDraftStoreError.storageLimitExceeded
    }
    let directory = accountDirectory(productAccountId: productAccountId)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try encryptedData.write(
      to: file,
      options: [.atomic]
    )
  }

  private func loadForMutation(
    productAccountId: String,
    profileId: MailProfileId
  ) throws -> [MailShellCompositionDraft] {
    do {
      return try loadWithoutLock(productAccountId: productAccountId, profileId: profileId)
    } catch {
      let file = fileURL(productAccountId: productAccountId, profileId: profileId)
      guard fileManager.fileExists(atPath: file.path) else { throw error }
      let quarantineFile = file.deletingLastPathComponent().appending(
        path: "\(file.lastPathComponent).unreadable-\(UUID().uuidString)"
      )
      try fileManager.moveItem(at: file, to: quarantineFile)
      return []
    }
  }

  private func accountDirectory(productAccountId: String) -> URL {
    rootDirectory.appending(
      path: gmailSafeFileComponent(productAccountId),
      directoryHint: .isDirectory
    )
  }

  private func migrateLegacyRootIfNeeded() throws {
    guard let legacyRootDirectory,
      fileManager.fileExists(atPath: legacyRootDirectory.path),
      !fileManager.fileExists(atPath: rootDirectory.path)
    else { return }
    try fileManager.createDirectory(
      at: rootDirectory.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.moveItem(at: legacyRootDirectory, to: rootDirectory)
  }

  private func associatedData(
    productAccountId: String,
    profileId: MailProfileId
  ) -> Data {
    Data("dev.unwired.mail.drafts.v1.\(productAccountId).\(profileId.rawValue)".utf8)
  }

  private func directorySize(_ directory: URL) -> Int {
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else { return 0 }
    return enumerator.compactMap { element in
      guard let url = element as? URL else { return nil }
      guard !url.lastPathComponent.contains(".unreadable-") else { return nil }
      return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
    .reduce(0, +)
  }

  private func fileSize(_ file: URL) -> Int {
    (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  private func fileURL(
    productAccountId: String,
    profileId: MailProfileId
  ) -> URL {
    accountDirectory(productAccountId: productAccountId).appending(
      path: "\(gmailSafeFileComponent(profileId.rawValue)).json"
    )
  }
}

actor MailCompositionDraftRepository {
  let reminderSyncService: any SendReminderSyncing
  let store: any MailCompositionDraftPersisting
  let syncService: any MailCompositionDraftSyncing

  init(
    store: any MailCompositionDraftPersisting = FileMailCompositionDraftStore(),
    syncService: any MailCompositionDraftSyncing = MailCompositionDraftSyncService(),
    reminderSyncService: any SendReminderSyncing = SendReminderSyncService()
  ) {
    self.reminderSyncService = reminderSyncService
    self.store = store
    self.syncService = syncService
  }

  func drafts(
    productAccountId: String,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot? = nil,
    claimsNotificationOwnership: Bool = false
  ) async throws -> [MailShellCompositionDraft] {
    var local = try store.load(productAccountId: productAccountId, profileId: profileId)
    guard let session else { return local }
    let snapshot: MailCompositionDraftSyncSnapshot
    do {
      snapshot = try await syncService.snapshot(profileId: profileId, session: session)
    } catch {
      return local
    }
    local = try resolvingRemovedDrafts(
      in: local,
      snapshot: snapshot,
      productAccountId: productAccountId,
      profileId: profileId
    )
    var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    let synchronizedById = Dictionary(uniqueKeysWithValues: snapshot.drafts.map { ($0.id, $0) })
    for draft in local
    where synchronizedById[draft.id]?.updatedAtMilliseconds ?? .min
      < draft.updatedAtMilliseconds
    {
      _ = try? await syncService.save(draft, profileId: profileId, session: session)
    }
    for var draft in snapshot.drafts {
      if let existing = merged[draft.id],
        existing.updatedAtMilliseconds > draft.updatedAtMilliseconds
      {
        continue
      }
      do {
        try store.save(draft, productAccountId: productAccountId, profileId: profileId)
      } catch MailCompositionDraftStoreError.storageLimitExceeded {
        draft.assets = draft.assets.map(\.metadataOnly)
      }
      merged[draft.id] = draft
    }
    return await reconcileSendReminders(
      in: Array(merged.values),
      profileId: profileId,
      session: session,
      claimsNotificationOwnership: claimsNotificationOwnership
    )
    .sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
  }

  func remove(
    _ draftId: UUID,
    productAccountId: String,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot? = nil
  ) async throws {
    if let session {
      _ = try await reminderSyncService.cancel(
        draftId: draftId,
        expectedRevision: nil,
        profileId: profileId,
        session: session
      )
      try await syncService.remove(draftId, profileId: profileId, session: session)
    }
    try store.remove(draftId, productAccountId: productAccountId, profileId: profileId)
  }

  private func resolvingRemovedDrafts(
    in local: [MailShellCompositionDraft],
    snapshot: MailCompositionDraftSyncSnapshot,
    productAccountId: String,
    profileId: MailProfileId
  ) throws -> [MailShellCompositionDraft] {
    var retained: [MailShellCompositionDraft] = []
    for draft in local {
      guard let removedAt = snapshot.removedDraftUpdatedAtMilliseconds[draft.id] else {
        retained.append(draft)
        continue
      }
      if draft.updatedAtMilliseconds > removedAt {
        do {
          let copy = try replaceWithConflictCopy(
            draft,
            productAccountId: productAccountId,
            profileId: profileId
          )
          retained.append(copy)
        } catch {
          retained.append(draft)
        }
      } else {
        try? store.remove(draft.id, productAccountId: productAccountId, profileId: profileId)
      }
    }
    return retained
  }

  func replaceWithConflictCopy(
    _ draft: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId
  ) throws -> MailShellCompositionDraft {
    let copy = draft.preservingAsConflictCopy()
    try store.save(copy, productAccountId: productAccountId, profileId: profileId)
    try store.remove(draft.id, productAccountId: productAccountId, profileId: profileId)
    return copy
  }

}
