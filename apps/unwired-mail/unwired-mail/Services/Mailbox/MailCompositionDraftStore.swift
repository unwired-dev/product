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
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "UnwiredMail/Drafts", directoryHint: .isDirectory)
    self.storageLimit = storageLimit
  }

  func clear(productAccountId: String) throws {
    try Self.mutationLock.withLock {
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
      try loadWithoutLock(productAccountId: productAccountId, profileId: profileId)
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
    let projectedSize = directorySize(rootDirectory) - currentFileSize + encryptedData.count
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
  private let store: any MailCompositionDraftPersisting

  init(store: any MailCompositionDraftPersisting = FileMailCompositionDraftStore()) {
    self.store = store
  }

  func drafts(
    productAccountId: String,
    profileId: MailProfileId
  ) throws -> [MailShellCompositionDraft] {
    try store.load(productAccountId: productAccountId, profileId: profileId)
  }

  func remove(
    _ draftId: UUID,
    productAccountId: String,
    profileId: MailProfileId
  ) throws {
    try store.remove(draftId, productAccountId: productAccountId, profileId: profileId)
  }

  func save(
    _ draft: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId
  ) throws {
    try store.save(draft, productAccountId: productAccountId, profileId: profileId)
  }
}
