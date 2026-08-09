import Foundation

// swiftlint:disable file_length

enum MessageReadTiming: String, CaseIterable, Codable, Identifiable, Sendable {
  case immediately
  case afterOneSecond
  case afterThreeSeconds
  case afterFiveSeconds
  case manually

  var id: Self { self }

  var delay: Duration? {
    switch self {
    case .immediately:
      .zero
    case .afterOneSecond:
      .seconds(1)
    case .afterThreeSeconds:
      .seconds(3)
    case .afterFiveSeconds:
      .seconds(5)
    case .manually:
      nil
    }
  }

  var title: String {
    switch self {
    case .immediately:
      "Immediately"
    case .afterOneSecond:
      "After 1 Second"
    case .afterThreeSeconds:
      "After 3 Seconds"
    case .afterFiveSeconds:
      "After 5 Seconds"
    case .manually:
      "Manually"
    }
  }
}

enum IncomingReadReceiptPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
  case askEveryTime
  case never

  var id: Self { self }

  var title: String {
    switch self {
    case .askEveryTime:
      "Ask Every Time"
    case .never:
      "Never"
    }
  }
}

enum OutgoingReadReceiptPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
  case never
  case askWhileSending
  case requestByDefault

  var id: Self { self }

  var title: String {
    switch self {
    case .never:
      "Never"
    case .askWhileSending:
      "Ask While Sending"
    case .requestByDefault:
      "Request by Default"
    }
  }
}

struct ReadingConnectionPreferences: Codable, Equatable, Sendable {
  var incomingReadReceipts: IncomingReadReceiptPolicy?
  var outgoingReadReceipts: OutgoingReadReceiptPolicy?

  init(
    incomingReadReceipts: IncomingReadReceiptPolicy? = nil,
    outgoingReadReceipts: OutgoingReadReceiptPolicy? = nil
  ) {
    self.incomingReadReceipts = incomingReadReceipts
    self.outgoingReadReceipts = outgoingReadReceipts
  }

  var isEmpty: Bool {
    incomingReadReceipts == nil && outgoingReadReceipts == nil
  }
}

struct ReadingPreferences: Codable, Equatable, Sendable {
  static let defaults = ReadingPreferences()
  static let primaryIdentifier = "mail-workflow-preferences:reading"
  static let supportedSchemaVersion = 1

  var connectionOverrides: [String: ReadingConnectionPreferences]
  var incomingReadReceipts: IncomingReadReceiptPolicy
  var markReadAfter: MessageReadTiming
  var marksReadOnArchiveOrDelete: Bool
  var marksReadOnReply: Bool
  var outgoingReadReceipts: OutgoingReadReceiptPolicy
  let schemaVersion: Int

  init(
    connectionOverrides: [String: ReadingConnectionPreferences] = [:],
    incomingReadReceipts: IncomingReadReceiptPolicy = .askEveryTime,
    markReadAfter: MessageReadTiming = .immediately,
    marksReadOnArchiveOrDelete: Bool = false,
    marksReadOnReply: Bool = true,
    outgoingReadReceipts: OutgoingReadReceiptPolicy = .never
  ) {
    self.connectionOverrides = connectionOverrides.filter { !$0.value.isEmpty }
    self.incomingReadReceipts = incomingReadReceipts
    self.markReadAfter = markReadAfter
    self.marksReadOnArchiveOrDelete = marksReadOnArchiveOrDelete
    self.marksReadOnReply = marksReadOnReply
    self.outgoingReadReceipts = outgoingReadReceipts
    schemaVersion = Self.supportedSchemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case connectionOverrides
    case incomingReadReceipts
    case markReadAfter
    case marksReadOnArchiveOrDelete
    case marksReadOnReply
    case outgoingReadReceipts
    case schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Reading preference schema is newer than this client supports."
      )
    }
    connectionOverrides =
      try container.decodeIfPresent(
        [String: ReadingConnectionPreferences].self,
        forKey: .connectionOverrides
      )?.filter { !$0.value.isEmpty } ?? [:]
    incomingReadReceipts =
      try container.decodeIfPresent(
        IncomingReadReceiptPolicy.self,
        forKey: .incomingReadReceipts
      ) ?? Self.defaults.incomingReadReceipts
    markReadAfter =
      try container.decodeIfPresent(MessageReadTiming.self, forKey: .markReadAfter)
      ?? Self.defaults.markReadAfter
    marksReadOnArchiveOrDelete =
      try container.decodeIfPresent(Bool.self, forKey: .marksReadOnArchiveOrDelete)
      ?? Self.defaults.marksReadOnArchiveOrDelete
    marksReadOnReply =
      try container.decodeIfPresent(Bool.self, forKey: .marksReadOnReply)
      ?? Self.defaults.marksReadOnReply
    outgoingReadReceipts =
      try container.decodeIfPresent(
        OutgoingReadReceiptPolicy.self,
        forKey: .outgoingReadReceipts
      ) ?? Self.defaults.outgoingReadReceipts
    schemaVersion = max(1, decodedSchemaVersion)
  }

  func incomingReadReceiptPolicy(
    for connectionId: MailboxConnectionId
  ) -> IncomingReadReceiptPolicy {
    connectionOverrides[connectionId.rawValue]?.incomingReadReceipts ?? incomingReadReceipts
  }

  func outgoingReadReceiptPolicy(
    for connectionId: MailboxConnectionId
  ) -> OutgoingReadReceiptPolicy {
    connectionOverrides[connectionId.rawValue]?.outgoingReadReceipts ?? outgoingReadReceipts
  }
}

enum ReadingPreferenceField: Hashable, Codable, Sendable {
  case connectionIncomingReadReceipts(String)
  case connectionOutgoingReadReceipts(String)
  case incomingReadReceipts
  case markReadAfter
  case marksReadOnArchiveOrDelete
  case marksReadOnReply
  case outgoingReadReceipts

  var sortKey: String {
    switch self {
    case .markReadAfter:
      "00-mark-read-after"
    case .marksReadOnReply:
      "01-marks-read-on-reply"
    case .marksReadOnArchiveOrDelete:
      "02-marks-read-on-archive-or-delete"
    case .incomingReadReceipts:
      "03-incoming-read-receipts"
    case .outgoingReadReceipts:
      "04-outgoing-read-receipts"
    case .connectionIncomingReadReceipts(let id):
      "05-\(id)-incoming"
    case .connectionOutgoingReadReceipts(let id):
      "05-\(id)-outgoing"
    }
  }
}

enum ReadingPreferenceValue: Codable, Equatable, Sendable {
  case boolean(Bool)
  case incomingReadReceipts(IncomingReadReceiptPolicy?)
  case markReadAfter(MessageReadTiming)
  case outgoingReadReceipts(OutgoingReadReceiptPolicy?)

  var title: String {
    switch self {
    case .boolean(let value):
      value ? "On" : "Off"
    case .incomingReadReceipts(let value):
      value?.title ?? "Use Global Setting"
    case .markReadAfter(let value):
      value.title
    case .outgoingReadReceipts(let value):
      value?.title ?? "Use Global Setting"
    }
  }
}

extension ReadingPreferences {
  func value(for field: ReadingPreferenceField) -> ReadingPreferenceValue {
    switch field {
    case .connectionIncomingReadReceipts(let connectionId):
      .incomingReadReceipts(connectionOverrides[connectionId]?.incomingReadReceipts)
    case .connectionOutgoingReadReceipts(let connectionId):
      .outgoingReadReceipts(connectionOverrides[connectionId]?.outgoingReadReceipts)
    case .incomingReadReceipts:
      .incomingReadReceipts(incomingReadReceipts)
    case .markReadAfter:
      .markReadAfter(markReadAfter)
    case .marksReadOnArchiveOrDelete:
      .boolean(marksReadOnArchiveOrDelete)
    case .marksReadOnReply:
      .boolean(marksReadOnReply)
    case .outgoingReadReceipts:
      .outgoingReadReceipts(outgoingReadReceipts)
    }
  }

  mutating func set(_ value: ReadingPreferenceValue, for field: ReadingPreferenceField) {
    switch (field, value) {
    case (.connectionIncomingReadReceipts(let connectionId), .incomingReadReceipts(let policy)):
      var override = connectionOverrides[connectionId] ?? ReadingConnectionPreferences()
      override.incomingReadReceipts = policy
      connectionOverrides[connectionId] = override.isEmpty ? nil : override
    case (.connectionOutgoingReadReceipts(let connectionId), .outgoingReadReceipts(let policy)):
      var override = connectionOverrides[connectionId] ?? ReadingConnectionPreferences()
      override.outgoingReadReceipts = policy
      connectionOverrides[connectionId] = override.isEmpty ? nil : override
    case (.incomingReadReceipts, .incomingReadReceipts(let policy)):
      if let policy { incomingReadReceipts = policy }
    case (.markReadAfter, .markReadAfter(let timing)):
      markReadAfter = timing
    case (.marksReadOnArchiveOrDelete, .boolean(let enabled)):
      marksReadOnArchiveOrDelete = enabled
    case (.marksReadOnReply, .boolean(let enabled)):
      marksReadOnReply = enabled
    case (.outgoingReadReceipts, .outgoingReadReceipts(let policy)):
      if let policy { outgoingReadReceipts = policy }
    default:
      assertionFailure("Reading preference field and value did not match")
    }
  }

  static func fields(including preferences: ReadingPreferences) -> [ReadingPreferenceField] {
    let globals: [ReadingPreferenceField] = [
      .markReadAfter,
      .marksReadOnReply,
      .marksReadOnArchiveOrDelete,
      .incomingReadReceipts,
      .outgoingReadReceipts,
    ]
    return globals
      + preferences.connectionOverrides.keys.sorted().flatMap {
        [
          .connectionIncomingReadReceipts($0),
          .connectionOutgoingReadReceipts($0),
        ]
      }
  }
}

struct ReadingPreferenceSyncSnapshot: Equatable, Sendable {
  let preferences: ReadingPreferences
  let updatedAt: Int64?

  init(preferences: ReadingPreferences, updatedAt: Int64?) {
    self.preferences = preferences
    self.updatedAt = updatedAt
  }

  init(preferences: ReadingPreferences, revision: ProductSyncRecordRevision) {
    self.preferences = preferences
    updatedAt = revision.legacyUpdatedAt
  }
}

enum ReadingPreferenceConditionalSaveResult: Equatable, Sendable {
  case committed(ReadingPreferenceSyncSnapshot)
  case conflict(ReadingPreferenceSyncSnapshot)
}

protocol ReadingPreferenceSyncing {
  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceSyncSnapshot?

  func savePreferences(
    _ preferences: ReadingPreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceConditionalSaveResult
}

enum ReadingPreferenceSyncError: LocalizedError, Equatable {
  case missingProductSyncKeyMaterial
  case retryLimitExceeded

  var errorDescription: String? {
    switch self {
    case .missingProductSyncKeyMaterial:
      "Restore Product Sync key material before changing Reading preferences."
    case .retryLimitExceeded:
      "Reading preferences kept changing on another device. Try syncing again."
    }
  }
}

final class ReadingPreferenceSyncService: ReadingPreferenceSyncing {
  private let preferenceRecord: ProductSyncSingletonHandle<ReadingPreferences>

  init(recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: ReadingPreferences.primaryIdentifier,
        cachePolicy: .authoritative
      )
    )
  }

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceSyncSnapshot? {
    do {
      guard let record = try await preferenceRecord.read(session: session) else { return nil }
      return ReadingPreferenceSyncSnapshot(
        preferences: record.value,
        revision: record.revision
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func savePreferences(
    _ preferences: ReadingPreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> ReadingPreferenceConditionalSaveResult {
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
          ReadingPreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          ))
      case .conflict(let record):
        return .conflict(
          ReadingPreferenceSyncSnapshot(
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
      ReadingPreferenceSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      ReadingPreferenceSyncError.retryLimitExceeded
    default:
      error
    }
  }
}
