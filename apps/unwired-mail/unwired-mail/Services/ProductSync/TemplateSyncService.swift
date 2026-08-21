import Foundation

/// Reusable subject and semantic body content owned by one Mail Profile.
struct MailTemplate: Codable, Equatable, Identifiable, Sendable {
  static let supportedSchemaVersion = 1

  let id: String
  var conflictSourceId: String?
  var document: SemanticMessageDocument
  var name: String
  let schemaVersion: Int
  var subject: String

  /// Creates a template using the current semantic document schema.
  init(
    id: String = UUID().uuidString,
    name: String,
    subject: String,
    document: SemanticMessageDocument,
    conflictSourceId: String? = nil
  ) {
    self.id = id
    self.conflictSourceId = conflictSourceId
    self.document = document
    self.name = name
    schemaVersion = Self.supportedSchemaVersion
    self.subject = subject
  }

  private enum CodingKeys: String, CodingKey {
    case legacyBody = "body"
    case conflictSourceId
    case document
    case id
    case name
    case schemaVersion
    case subject
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion == Self.supportedSchemaVersion else {
      throw TemplateSyncError.unsupportedVersion
    }
    id = try container.decode(String.self, forKey: .id)
    conflictSourceId = try container.decodeIfPresent(String.self, forKey: .conflictSourceId)
    if let decodedDocument = try container.decodeIfPresent(
      SemanticMessageDocument.self,
      forKey: .document
    ) {
      document = decodedDocument
    } else {
      document = SemanticMessageDocument(
        plainText: try container.decodeIfPresent(String.self, forKey: .legacyBody) ?? ""
      )
    }
    name = try container.decode(String.self, forKey: .name)
    schemaVersion = decodedSchemaVersion
    subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(conflictSourceId, forKey: .conflictSourceId)
    try container.encode(document, forKey: .document)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(subject, forKey: .subject)
  }
}

/// The synchronized template collection for one Mail Profile.
struct TemplatePreferences: Codable, Equatable, Sendable {
  static let empty = TemplatePreferences()
  static let primaryIdentifier = "mail-workflow-preferences:templates"
  static let supportedSchemaVersion = 1

  let schemaVersion: Int
  var templates: [MailTemplate]

  /// Creates a collection using the current preference schema.
  init(templates: [MailTemplate] = []) {
    schemaVersion = Self.supportedSchemaVersion
    self.templates = templates
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case templates
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion == Self.supportedSchemaVersion else {
      throw TemplateSyncError.unsupportedVersion
    }
    schemaVersion = decodedSchemaVersion
    templates = try container.decodeIfPresent([MailTemplate].self, forKey: .templates) ?? []
  }

  /// Returns the template with the requested stable identifier.
  func template(id: String) -> MailTemplate? {
    templates.first { $0.id == id }
  }

  /// Inserts, updates, or removes one template.
  mutating func set(_ template: MailTemplate?, id: String) {
    templates.removeAll { $0.id == id }
    if let template { templates.append(template) }
    templates.sort {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Returns a normalized collection or throws when names and identifiers are unsafe.
  func validated() throws -> TemplatePreferences {
    var identifiers: Set<String> = []
    var names: Set<String> = []
    var normalized: [MailTemplate] = []
    for var template in templates {
      guard !template.id.isEmpty, identifiers.insert(template.id).inserted else {
        throw TemplateSyncError.invalidIdentifier
      }
      template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...80).contains(template.name.count) else {
        throw TemplateSyncError.invalidName
      }
      guard template.subject.count <= 998 else {
        throw TemplateSyncError.subjectTooLong
      }
      let foldedName = template.name.folding(
        options: .caseInsensitive,
        locale: Locale(identifier: "en_US_POSIX")
      )
      guard names.insert(foldedName).inserted else {
        throw TemplateSyncError.duplicateName
      }
      normalized.append(template)
    }
    return TemplatePreferences(templates: normalized)
  }
}

/// One revisioned synchronized template collection.
struct TemplatePreferenceSyncSnapshot: Equatable, Sendable {
  let preferences: TemplatePreferences
  let updatedAt: Int64?

  init(preferences: TemplatePreferences, updatedAt: Int64?) {
    self.preferences = preferences
    self.updatedAt = updatedAt
  }

  init(preferences: TemplatePreferences, revision: ProductSyncRecordRevision) {
    self.preferences = preferences
    updatedAt = revision.legacyUpdatedAt
  }
}

/// The result of a conditional template-collection write.
enum TemplatePreferenceConditionalSaveResult: Equatable, Sendable {
  case committed(TemplatePreferenceSyncSnapshot)
  case conflict(TemplatePreferenceSyncSnapshot)
}

/// Loads and conditionally saves a Mail Profile's encrypted templates.
protocol TemplatePreferenceSyncing {
  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> TemplatePreferenceSyncSnapshot?

  func savePreferences(
    _ preferences: TemplatePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> TemplatePreferenceConditionalSaveResult
}

/// User-actionable template validation and synchronization failures.
enum TemplateSyncError: LocalizedError, Equatable {
  case duplicateName
  case invalidIdentifier
  case invalidName
  case missingProductSyncKeyMaterial
  case retryLimitExceeded
  case subjectTooLong
  case unsupportedVersion

  var errorDescription: String? {
    switch self {
    case .duplicateName:
      "Choose a template name that is not already in use."
    case .invalidIdentifier:
      "This template cannot be synchronized. Create it again."
    case .invalidName:
      "Template names must contain between 1 and 80 characters."
    case .missingProductSyncKeyMaterial:
      "Restore Product Sync key material before changing templates."
    case .retryLimitExceeded:
      "Templates kept changing on another device. Try syncing again."
    case .subjectTooLong:
      "Template subjects must contain no more than 998 characters."
    case .unsupportedVersion:
      "These templates were saved by a newer version of SwiftMail. "
        + "Update SwiftMail before editing them."
    }
  }
}

/// Synchronizes one Mail Profile's end-to-end encrypted template collection.
final class TemplateSyncService: TemplatePreferenceSyncing {
  private let preferenceRecord: ProductSyncSingletonHandle<TemplatePreferences>

  /// Creates a service scoped to one Mail Profile record namespace.
  init(
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(TemplatePreferences.primaryIdentifier),
        cachePolicy: .authoritative
      )
    )
  }

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> TemplatePreferenceSyncSnapshot? {
    do {
      guard let record = try await preferenceRecord.read(session: session) else { return nil }
      return TemplatePreferenceSyncSnapshot(
        preferences: try record.value.validated(),
        revision: record.revision
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func savePreferences(
    _ preferences: TemplatePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> TemplatePreferenceConditionalSaveResult {
    do {
      let normalized = try preferences.validated()
      let expectedRevision = expectedUpdatedAt.map(
        ProductSyncRecordRevision.init(legacyUpdatedAt:)
      )
      switch try await preferenceRecord.writeIfUnchanged(
        normalized,
        expectedRevision: expectedRevision,
        session: session
      ) {
      case .committed(let record):
        return .committed(
          TemplatePreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          )
        )
      case .conflict(let record):
        return .conflict(
          TemplatePreferenceSyncSnapshot(
            preferences: try record.value.validated(),
            revision: record.revision
          )
        )
      }
    } catch {
      throw mapBoundaryError(error)
    }
  }

  private func mapBoundaryError(_ error: Error) -> Error {
    switch error as? ProductSyncRecordBoundaryError {
    case .missingProductSyncKeyMaterial:
      TemplateSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      TemplateSyncError.retryLimitExceeded
    default:
      error
    }
  }
}
