import Foundation

enum UndoSendWindow: Int, CaseIterable, Codable, Identifiable, Sendable {
  case off = 0
  case tenSeconds = 10
  case twentySeconds = 20
  case thirtySeconds = 30

  var id: Self { self }

  var title: String {
    switch self {
    case .off:
      return "Off"
    case .tenSeconds:
      return "10 Seconds"
    case .twentySeconds:
      return "20 Seconds"
    case .thirtySeconds:
      return "30 Seconds"
    }
  }

  var nanoseconds: UInt64 {
    UInt64(rawValue) * 1_000_000_000
  }
}

struct ComposePreferences: Codable, Equatable, Sendable {
  static let defaults = ComposePreferences()
  static let primaryIdentifier = "mail-workflow-preferences:compose"
  static let supportedSchemaVersion = 2

  var includesForwardedAttachments: Bool
  var includesQuotedText: Bool
  var showsFormattingToolbar: Bool
  var undoSendWindow: UndoSendWindow
  let schemaVersion: Int

  init(
    undoSendWindow: UndoSendWindow = .tenSeconds,
    showsFormattingToolbar: Bool = true,
    includesQuotedText: Bool = true,
    includesForwardedAttachments: Bool = true
  ) {
    self.includesForwardedAttachments = includesForwardedAttachments
    self.includesQuotedText = includesQuotedText
    self.showsFormattingToolbar = showsFormattingToolbar
    self.undoSendWindow = undoSendWindow
    schemaVersion = Self.supportedSchemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case includesForwardedAttachments
    case includesQuotedText
    case schemaVersion
    case showsFormattingToolbar
    case undoSendWindow
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Compose preference schema is newer than this client supports."
      )
    }
    includesForwardedAttachments =
      (try? container.decode(Bool.self, forKey: .includesForwardedAttachments))
      ?? Self.defaults.includesForwardedAttachments
    includesQuotedText =
      (try? container.decode(Bool.self, forKey: .includesQuotedText))
      ?? Self.defaults.includesQuotedText
    showsFormattingToolbar =
      (try? container.decode(Bool.self, forKey: .showsFormattingToolbar))
      ?? Self.defaults.showsFormattingToolbar
    undoSendWindow =
      (try? container.decode(UndoSendWindow.self, forKey: .undoSendWindow))
      ?? Self.defaults.undoSendWindow
    schemaVersion = max(1, decodedSchemaVersion)
  }
}

enum ComposePreferenceField: String, CaseIterable, Codable, Identifiable, Sendable {
  case forwardedAttachments
  case formattingToolbar
  case quotedText
  case undoSend

  var id: Self { self }

  var title: String {
    switch self {
    case .forwardedAttachments:
      return "Forwarded Attachments"
    case .formattingToolbar:
      return "Formatting Toolbar"
    case .quotedText:
      return "Quoted Text"
    case .undoSend:
      return "Undo Send"
    }
  }
}

enum ComposePreferenceValue: Codable, Equatable, Sendable {
  case boolean(Bool)
  case undoSend(UndoSendWindow)

  var title: String {
    switch self {
    case .boolean(let value):
      return value ? "On" : "Off"
    case .undoSend(let value):
      return value.title
    }
  }
}

extension ComposePreferences {
  func value(for field: ComposePreferenceField) -> ComposePreferenceValue {
    switch field {
    case .forwardedAttachments:
      return .boolean(includesForwardedAttachments)
    case .formattingToolbar:
      return .boolean(showsFormattingToolbar)
    case .quotedText:
      return .boolean(includesQuotedText)
    case .undoSend:
      return .undoSend(undoSendWindow)
    }
  }

  mutating func set(_ value: ComposePreferenceValue, for field: ComposePreferenceField) {
    switch (field, value) {
    case (.forwardedAttachments, .boolean(let enabled)):
      includesForwardedAttachments = enabled
    case (.formattingToolbar, .boolean(let enabled)):
      showsFormattingToolbar = enabled
    case (.quotedText, .boolean(let enabled)):
      includesQuotedText = enabled
    case (.undoSend, .undoSend(let window)):
      undoSendWindow = window
    default:
      assertionFailure("Compose preference field and value did not match")
    }
  }
}

struct ComposePreferenceSyncSnapshot: Equatable, Sendable {
  let preferences: ComposePreferences
  let updatedAt: Int64?

  init(preferences: ComposePreferences, updatedAt: Int64?) {
    self.preferences = preferences
    self.updatedAt = updatedAt
  }

  init(preferences: ComposePreferences, revision: ProductSyncRecordRevision) {
    self.preferences = preferences
    updatedAt = revision.legacyUpdatedAt
  }
}

enum ComposePreferenceConditionalSaveResult: Equatable, Sendable {
  case committed(ComposePreferenceSyncSnapshot)
  case conflict(ComposePreferenceSyncSnapshot)
}

protocol ComposePreferenceSyncing {
  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceSyncSnapshot?

  func savePreferences(
    _ preferences: ComposePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceConditionalSaveResult
}

enum ComposePreferenceSyncError: LocalizedError, Equatable {
  case missingProductSyncKeyMaterial
  case retryLimitExceeded

  var errorDescription: String? {
    switch self {
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Compose preferences."
    case .retryLimitExceeded:
      return "Compose preferences kept changing on another device. Try syncing again."
    }
  }
}

final class ComposePreferenceSyncService: ComposePreferenceSyncing {
  private let preferenceRecord: ProductSyncSingletonHandle<ComposePreferences>

  init(
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(ComposePreferences.primaryIdentifier),
        cachePolicy: .authoritative
      )
    )
  }

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceSyncSnapshot? {
    do {
      guard let record = try await preferenceRecord.read(session: session) else { return nil }
      return ComposePreferenceSyncSnapshot(
        preferences: record.value,
        revision: record.revision
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func savePreferences(
    _ preferences: ComposePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> ComposePreferenceConditionalSaveResult {
    do {
      let expectedRevision = expectedUpdatedAt.map(
        ProductSyncRecordRevision.init(legacyUpdatedAt:)
      )
      switch try await preferenceRecord.writeIfUnchanged(
        preferences,
        expectedRevision: expectedRevision,
        session: session
      ) {
      case .committed(let record):
        return .committed(
          ComposePreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          ))
      case .conflict(let record):
        return .conflict(
          ComposePreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          ))
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    switch error as? ProductSyncRecordBoundaryError {
    case .missingProductSyncKeyMaterial:
      return ComposePreferenceSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return ComposePreferenceSyncError.retryLimitExceeded
    default:
      return error
    }
  }
}
