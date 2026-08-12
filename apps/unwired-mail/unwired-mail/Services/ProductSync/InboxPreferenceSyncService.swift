import Foundation

enum InboxThreadDensity: String, CaseIterable, Codable, Identifiable, Sendable {
  case compact
  case comfortable
  case spacious

  var id: Self { self }

  var title: String {
    rawValue.capitalized
  }
}

enum InboxPreviewLength: Int, CaseIterable, Codable, Identifiable, Sendable {
  case none = 0
  case one = 1
  case two = 2
  case three = 3

  var id: Self { self }

  var title: String {
    switch self {
    case .none:
      return "None"
    case .one:
      return "1 Line"
    case .two:
      return "2 Lines"
    case .three:
      return "3 Lines"
    }
  }
}

struct InboxPreferences: Codable, Equatable, Sendable {
  static let defaults = InboxPreferences()
  static let primaryIdentifier = "mail-workflow-preferences:inbox"
  static let supportedSchemaVersion = 2

  var mailViewConfiguration: MailViewConfiguration
  var threadDensity: InboxThreadDensity
  var previewLength: InboxPreviewLength
  var showsContactImages: Bool
  var showsCategoryBadges: Bool
  var showsAttachmentIndicators: Bool
  let schemaVersion: Int

  init(
    mailViewConfiguration: MailViewConfiguration = .defaults,
    threadDensity: InboxThreadDensity = .comfortable,
    previewLength: InboxPreviewLength = .two,
    showsContactImages: Bool = true,
    showsCategoryBadges: Bool = true,
    showsAttachmentIndicators: Bool = true
  ) {
    self.mailViewConfiguration = mailViewConfiguration
    self.threadDensity = threadDensity
    self.previewLength = previewLength
    self.showsContactImages = showsContactImages
    self.showsCategoryBadges = showsCategoryBadges
    self.showsAttachmentIndicators = showsAttachmentIndicators
    schemaVersion = Self.supportedSchemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case mailViewConfiguration
    case previewLength
    case schemaVersion
    case showsAttachmentIndicators
    case showsCategoryBadges
    case showsContactImages
    case threadDensity
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Inbox preference schema is newer than this client supports."
      )
    }
    threadDensity =
      try container.decodeIfPresent(InboxThreadDensity.self, forKey: .threadDensity)
      ?? Self.defaults.threadDensity
    mailViewConfiguration =
      try container.decodeIfPresent(
        MailViewConfiguration.self,
        forKey: .mailViewConfiguration
      ) ?? Self.defaults.mailViewConfiguration
    previewLength =
      try container.decodeIfPresent(InboxPreviewLength.self, forKey: .previewLength)
      ?? Self.defaults.previewLength
    showsContactImages =
      try container.decodeIfPresent(Bool.self, forKey: .showsContactImages)
      ?? Self.defaults.showsContactImages
    showsCategoryBadges =
      try container.decodeIfPresent(Bool.self, forKey: .showsCategoryBadges)
      ?? Self.defaults.showsCategoryBadges
    showsAttachmentIndicators =
      try container.decodeIfPresent(Bool.self, forKey: .showsAttachmentIndicators)
      ?? Self.defaults.showsAttachmentIndicators
    schemaVersion = Self.supportedSchemaVersion
  }
}

enum InboxPreferenceField: String, CaseIterable, Codable, Identifiable, Sendable {
  case attachmentIndicators
  case categoryBadges
  case contactImages
  case mailViews
  case previewLength
  case threadDensity

  var id: Self { self }

  var title: String {
    switch self {
    case .attachmentIndicators:
      return "Attachment Indicators"
    case .categoryBadges:
      return "Category Badges"
    case .contactImages:
      return "Contact Images"
    case .mailViews:
      return "Mail Views"
    case .previewLength:
      return "Preview Length"
    case .threadDensity:
      return "Thread-List Density"
    }
  }
}

enum InboxPreferenceValue: Codable, Equatable, Sendable {
  case boolean(Bool)
  case mailViewConfiguration(MailViewConfiguration)
  case previewLength(InboxPreviewLength)
  case threadDensity(InboxThreadDensity)

  var title: String {
    switch self {
    case .boolean(let value):
      return value ? "On" : "Off"
    case .mailViewConfiguration(let configuration):
      let configuredCount = configuration.categorySlots.compactMap { $0 }.count
      return "Important and \(configuredCount) Category views"
    case .previewLength(let value):
      return value.title
    case .threadDensity(let value):
      return value.title
    }
  }
}

extension InboxPreferences {
  func value(for field: InboxPreferenceField) -> InboxPreferenceValue {
    switch field {
    case .attachmentIndicators:
      return .boolean(showsAttachmentIndicators)
    case .categoryBadges:
      return .boolean(showsCategoryBadges)
    case .contactImages:
      return .boolean(showsContactImages)
    case .mailViews:
      return .mailViewConfiguration(mailViewConfiguration)
    case .previewLength:
      return .previewLength(previewLength)
    case .threadDensity:
      return .threadDensity(threadDensity)
    }
  }

  mutating func set(_ value: InboxPreferenceValue, for field: InboxPreferenceField) {
    switch (field, value) {
    case (.attachmentIndicators, .boolean(let enabled)):
      showsAttachmentIndicators = enabled
    case (.categoryBadges, .boolean(let enabled)):
      showsCategoryBadges = enabled
    case (.contactImages, .boolean(let enabled)):
      showsContactImages = enabled
    case (.mailViews, .mailViewConfiguration(let configuration)):
      mailViewConfiguration = configuration
    case (.previewLength, .previewLength(let length)):
      previewLength = length
    case (.threadDensity, .threadDensity(let density)):
      threadDensity = density
    default:
      assertionFailure("Inbox preference field and value did not match")
    }
  }
}

struct InboxPreferenceSyncSnapshot: Equatable, Sendable {
  let preferences: InboxPreferences
  let updatedAt: Int64?

  init(preferences: InboxPreferences, updatedAt: Int64?) {
    self.preferences = preferences
    self.updatedAt = updatedAt
  }

  init(preferences: InboxPreferences, revision: ProductSyncRecordRevision) {
    self.preferences = preferences
    updatedAt = revision.legacyUpdatedAt
  }
}

enum InboxPreferenceConditionalSaveResult: Equatable, Sendable {
  case committed(InboxPreferenceSyncSnapshot)
  case conflict(InboxPreferenceSyncSnapshot)
}

protocol InboxPreferenceSyncing {
  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceSyncSnapshot?

  func savePreferences(
    _ preferences: InboxPreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceConditionalSaveResult
}

enum InboxPreferenceSyncError: LocalizedError, Equatable {
  case missingProductSyncKeyMaterial
  case retryLimitExceeded

  var errorDescription: String? {
    switch self {
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Inbox preferences."
    case .retryLimitExceeded:
      return "Inbox preferences kept changing on another device. Try syncing again."
    }
  }
}

final class InboxPreferenceSyncService: InboxPreferenceSyncing {
  private let preferenceRecord: ProductSyncSingletonHandle<InboxPreferences>

  init(
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(InboxPreferences.primaryIdentifier),
        cachePolicy: .authoritative
      )
    )
  }

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceSyncSnapshot? {
    do {
      guard let record = try await preferenceRecord.read(session: session) else { return nil }
      return InboxPreferenceSyncSnapshot(
        preferences: record.value,
        revision: record.revision
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func savePreferences(
    _ preferences: InboxPreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> InboxPreferenceConditionalSaveResult {
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
          InboxPreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          ))
      case .conflict(let record):
        return .conflict(
          InboxPreferenceSyncSnapshot(
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
      return InboxPreferenceSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return InboxPreferenceSyncError.retryLimitExceeded
    default:
      return error
    }
  }
}
