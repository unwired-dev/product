import Foundation

private struct MailCompositionDraftSyncRecordId: Hashable, Sendable {
  let draftId: UUID
  let profileId: MailProfileId
}

private struct MailDraftChunkSyncRecordId: Hashable, Sendable {
  let assetId: UUID
  let draftId: UUID
  let index: Int
}

private struct MailCompositionDraftSyncPayload: Codable, Sendable {
  let draft: MailShellCompositionDraft?
  let updatedAtMilliseconds: Int64
}

private struct MailDraftChunkSyncPayload: Codable, Sendable {
  let chunk: MailDraftAssetChunk?
  let updatedAtMilliseconds: Int64
}

struct MailCompositionDraftSyncSnapshot: Sendable {
  let drafts: [MailShellCompositionDraft]
  let removedDraftUpdatedAtMilliseconds: [UUID: Int64]

  var removedDraftIds: Set<UUID> {
    Set(removedDraftUpdatedAtMilliseconds.keys)
  }

  init(
    drafts: [MailShellCompositionDraft],
    removedDraftIds: Set<UUID>
  ) {
    self.drafts = drafts
    removedDraftUpdatedAtMilliseconds = Dictionary(
      uniqueKeysWithValues: removedDraftIds.map { ($0, .max) }
    )
  }

  init(
    drafts: [MailShellCompositionDraft],
    removedDraftUpdatedAtMilliseconds: [UUID: Int64]
  ) {
    self.drafts = drafts
    self.removedDraftUpdatedAtMilliseconds = removedDraftUpdatedAtMilliseconds
  }
}

enum MailCompositionDraftSyncSaveResult: Sendable {
  case removed
  case saved
}

protocol MailCompositionDraftSyncing: Sendable {
  func snapshot(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSnapshot
  func remove(
    _ draftId: UUID,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws
  func save(
    _ draft: MailShellCompositionDraft,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSaveResult
}

/// Synchronizes encrypted Draft metadata and independently encrypted asset chunks.
actor MailCompositionDraftSyncService: MailCompositionDraftSyncing {
  private static let chunkPrefix = "mail-draft-chunk.v1."
  private static let draftPrefix = "mail-composition-draft.v1."

  private let chunks:
    ProductSyncRecordFamilyHandle<MailDraftChunkSyncRecordId, MailDraftChunkSyncPayload>
  private let drafts:
    ProductSyncRecordFamilyHandle<MailCompositionDraftSyncRecordId, MailCompositionDraftSyncPayload>

  init(recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()) {
    chunks = recordBoundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { Self.chunkIdentifier($0) },
        identifierPrefix: Self.chunkPrefix,
        recordId: { Self.chunkRecordId($0) },
        cachePolicy: .authoritative
      )
    )
    drafts = recordBoundary.family(
      ProductSyncRecordFamilyDefinition(
        identifier: { Self.draftIdentifier($0) },
        identifierPrefix: Self.draftPrefix,
        recordId: { Self.draftRecordId($0) },
        cachePolicy: .authoritative
      )
    )
  }

  func snapshot(
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSnapshot {
    let records = try await drafts.list(session: session)
    var loaded: [MailShellCompositionDraft] = []
    var removedDraftUpdatedAtMilliseconds: [UUID: Int64] = [:]
    for (recordId, record) in records
    where recordId.profileId == profileId {
      try Task.checkCancellation()
      guard var draft = record.value.draft else {
        removedDraftUpdatedAtMilliseconds[recordId.draftId] =
          record.value.updatedAtMilliseconds
        continue
      }
      let requestedChunks = draft.assets.flatMap { asset in
        (0..<asset.expectedChunkCount).map {
          MailDraftChunkSyncRecordId(assetId: asset.id, draftId: draft.id, index: $0)
        }
      }
      let chunkRecords = try await chunks.readValid(requestedChunks, session: session)
      draft.assets = draft.assets.map { asset in
        let values = (0..<asset.expectedChunkCount).compactMap {
          chunkRecords[
            MailDraftChunkSyncRecordId(assetId: asset.id, draftId: draft.id, index: $0)
          ]?.value.chunk
        }
        return asset.replacingChunks(values)
      }
      loaded.append(draft)
    }
    return MailCompositionDraftSyncSnapshot(
      drafts: loaded.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds },
      removedDraftUpdatedAtMilliseconds: removedDraftUpdatedAtMilliseconds
    )
  }

  func save(
    _ draft: MailShellCompositionDraft,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailCompositionDraftSyncSaveResult {
    let recordId = MailCompositionDraftSyncRecordId(draftId: draft.id, profileId: profileId)
    if !draft.assets.isEmpty,
      let current = try await drafts.read([recordId], session: session)[recordId],
      current.value.draft == nil
    {
      return .removed
    }
    try await saveChunks(for: draft, session: session)
    var metadata = draft
    metadata.assets = draft.assets.map(\.metadataOnly)
    let record = try await drafts.update(recordId, session: session) { current in
      if current?.value.draft == nil, current != nil {
        return .acceptAuthoritative
      }
      guard current?.value.updatedAtMilliseconds ?? .min <= metadata.updatedAtMilliseconds else {
        return .acceptAuthoritative
      }
      return .write(
        MailCompositionDraftSyncPayload(
          draft: metadata,
          updatedAtMilliseconds: metadata.updatedAtMilliseconds
        )
      )
    }
    guard let record, record.value.draft == nil else { return .saved }
    try await removeRejectedChunks(
      for: draft,
      removedAtMilliseconds: record.value.updatedAtMilliseconds,
      session: session
    )
    return .removed
  }

  func remove(
    _ draftId: UUID,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let recordId = MailCompositionDraftSyncRecordId(draftId: draftId, profileId: profileId)
    let record = try await drafts.read([recordId], session: session)[recordId]
    let removedAtMilliseconds = Int64(Date.now.timeIntervalSince1970 * 1_000)
    let chunkIds = (record?.value.draft?.assets ?? []).flatMap { asset in
      (0..<asset.expectedChunkCount).map {
        MailDraftChunkSyncRecordId(assetId: asset.id, draftId: draftId, index: $0)
      }
    }
    try await removeChunks(
      chunkIds,
      updatedAtMilliseconds: removedAtMilliseconds,
      session: session
    )
    _ = try await drafts.update(recordId, session: session) { current in
      guard current?.value.updatedAtMilliseconds ?? .min <= removedAtMilliseconds else {
        return .acceptAuthoritative
      }
      return .write(
        MailCompositionDraftSyncPayload(
          draft: nil,
          updatedAtMilliseconds: removedAtMilliseconds
        )
      )
    }
  }

  private static func draftIdentifier(_ id: MailCompositionDraftSyncRecordId) -> String {
    draftPrefix + encoded(id.profileId.rawValue) + "." + id.draftId.uuidString.lowercased()
  }

  private func removeRejectedChunks(
    for draft: MailShellCompositionDraft,
    removedAtMilliseconds: Int64,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let cleanupTimestamp = max(draft.updatedAtMilliseconds, removedAtMilliseconds)
    let chunkIds = draft.assets.flatMap { asset in
      asset.chunks.map { chunk in
        MailDraftChunkSyncRecordId(
          assetId: asset.id,
          draftId: draft.id,
          index: chunk.index
        )
      }
    }
    try await removeChunks(
      chunkIds,
      updatedAtMilliseconds: cleanupTimestamp,
      session: session
    )
  }

  private func saveChunks(
    for draft: MailShellCompositionDraft,
    session: ProductAccountSessionSnapshot
  ) async throws {
    for asset in draft.assets {
      for chunk in asset.chunks {
        try Task.checkCancellation()
        let recordId = MailDraftChunkSyncRecordId(
          assetId: asset.id,
          draftId: draft.id,
          index: chunk.index
        )
        _ = try await chunks.update(recordId, session: session) { current in
          guard current?.value.updatedAtMilliseconds ?? .min <= draft.updatedAtMilliseconds else {
            return .acceptAuthoritative
          }
          return .write(
            MailDraftChunkSyncPayload(
              chunk: chunk,
              updatedAtMilliseconds: draft.updatedAtMilliseconds
            )
          )
        }
      }
    }
  }

  private func removeChunks(
    _ recordIds: [MailDraftChunkSyncRecordId],
    updatedAtMilliseconds: Int64,
    session: ProductAccountSessionSnapshot
  ) async throws {
    for recordId in recordIds {
      try Task.checkCancellation()
      _ = try await chunks.update(recordId, session: session) { current in
        guard current?.value.updatedAtMilliseconds ?? .min <= updatedAtMilliseconds else {
          return .acceptAuthoritative
        }
        return .write(
          MailDraftChunkSyncPayload(
            chunk: nil,
            updatedAtMilliseconds: updatedAtMilliseconds
          )
        )
      }
    }
  }

  private static func draftRecordId(_ identifier: String) -> MailCompositionDraftSyncRecordId? {
    guard identifier.hasPrefix(draftPrefix) else { return nil }
    let suffix = identifier.dropFirst(draftPrefix.count)
    let parts = suffix.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let profile = decoded(String(parts[0])),
      let draftId = UUID(uuidString: String(parts[1]))
    else { return nil }
    return MailCompositionDraftSyncRecordId(
      draftId: draftId,
      profileId: MailProfileId(rawValue: profile)
    )
  }

  private static func chunkIdentifier(_ id: MailDraftChunkSyncRecordId) -> String {
    chunkPrefix + id.draftId.uuidString.lowercased() + "."
      + id.assetId.uuidString.lowercased() + "." + String(id.index)
  }

  private static func chunkRecordId(_ identifier: String) -> MailDraftChunkSyncRecordId? {
    guard identifier.hasPrefix(chunkPrefix) else { return nil }
    let parts = identifier.dropFirst(chunkPrefix.count).split(separator: ".")
    guard parts.count == 3,
      let draftId = UUID(uuidString: String(parts[0])),
      let assetId = UUID(uuidString: String(parts[1])),
      let index = Int(parts[2]),
      index >= 0
    else { return nil }
    return MailDraftChunkSyncRecordId(assetId: assetId, draftId: draftId, index: index)
  }

  private static func encoded(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
      .replacing("=", with: "")
  }

  private static func decoded(_ value: String) -> String? {
    let base64 = value.replacing("-", with: "+").replacing("_", with: "/")
    let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: padded) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
