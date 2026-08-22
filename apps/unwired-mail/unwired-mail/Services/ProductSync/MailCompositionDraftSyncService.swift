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
  let removedDraftIds: Set<UUID>
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
  ) async throws
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
    var removedDraftIds: Set<UUID> = []
    for (recordId, record) in records
    where recordId.profileId == profileId {
      try Task.checkCancellation()
      guard var draft = record.value.draft else {
        removedDraftIds.insert(recordId.draftId)
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
      removedDraftIds: removedDraftIds
    )
  }

  func save(
    _ draft: MailShellCompositionDraft,
    profileId: MailProfileId,
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
          guard
            current?.value.updatedAtMilliseconds ?? .min <= draft.updatedAtMilliseconds
          else { return .acceptAuthoritative }
          return .write(
            MailDraftChunkSyncPayload(
              chunk: chunk,
              updatedAtMilliseconds: draft.updatedAtMilliseconds
            )
          )
        }
      }
    }
    var metadata = draft
    metadata.assets = draft.assets.map(\.metadataOnly)
    let recordId = MailCompositionDraftSyncRecordId(draftId: draft.id, profileId: profileId)
    _ = try await drafts.update(recordId, session: session) { current in
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
  }

  func remove(
    _ draftId: UUID,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let recordId = MailCompositionDraftSyncRecordId(draftId: draftId, profileId: profileId)
    let record = try await drafts.read([recordId], session: session)[recordId]
    let removedAtMilliseconds = Int64(Date.now.timeIntervalSince1970 * 1_000)
    for asset in record?.value.draft?.assets ?? [] {
      for index in 0..<asset.expectedChunkCount {
        try Task.checkCancellation()
        let chunkId = MailDraftChunkSyncRecordId(
          assetId: asset.id,
          draftId: draftId,
          index: index
        )
        _ = try await chunks.update(chunkId, session: session) { current in
          guard current?.value.updatedAtMilliseconds ?? .min <= removedAtMilliseconds else {
            return .acceptAuthoritative
          }
          return .write(
            MailDraftChunkSyncPayload(
              chunk: nil,
              updatedAtMilliseconds: removedAtMilliseconds
            )
          )
        }
      }
    }
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
