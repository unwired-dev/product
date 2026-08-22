import Foundation

// swiftlint:disable file_length

struct SignatureTextRun: Codable, Equatable, Sendable {
  var isBold: Bool
  var isItalic: Bool
  var isUnderlined: Bool
  var link: String?
  var text: String

  init(
    _ text: String,
    isBold: Bool = false,
    isItalic: Bool = false,
    isUnderlined: Bool = false,
    link: String? = nil
  ) {
    self.isBold = isBold
    self.isItalic = isItalic
    self.isUnderlined = isUnderlined
    self.link = link
    self.text = text
  }
}

struct SignatureDocument: Codable, Equatable, Sendable {
  var runs: [SignatureTextRun]

  init(runs: [SignatureTextRun]) {
    self.runs = runs
  }

  init(
    text: String,
    isBold: Bool = false,
    isItalic: Bool = false,
    isUnderlined: Bool = false,
    link: String? = nil
  ) {
    runs = [
      SignatureTextRun(
        text,
        isBold: isBold,
        isItalic: isItalic,
        isUnderlined: isUnderlined,
        link: link
      )
    ]
  }

  var plainText: String {
    runs.map(\.text).joined()
  }

  var html: String {
    runs.map { run in
      var value = Self.escapeHTML(run.text)
        .replacingOccurrences(of: "\n", with: "<br>")
      if let link = run.link {
        value = "<a href=\"\(Self.escapeHTML(link))\">\(value)</a>"
      }
      if run.isUnderlined { value = "<u>\(value)</u>" }
      if run.isItalic { value = "<em>\(value)</em>" }
      if run.isBold { value = "<strong>\(value)</strong>" }
      return value
    }.joined()
  }

  fileprivate func validated() throws -> SignatureDocument {
    guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SignatureSyncError.emptyBody
    }
    for run in runs {
      guard let link = run.link else { continue }
      guard
        let components = URLComponents(string: link),
        let scheme = components.scheme?.lowercased(),
        ["http", "https", "mailto"].contains(scheme),
        scheme == "mailto" || components.host?.isEmpty == false
      else {
        throw SignatureSyncError.invalidLink
      }
    }
    return self
  }

  private static func escapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}

struct MailSignature: Codable, Equatable, Identifiable, Sendable {
  let id: String
  var conflictSourceId: String?
  var document: SignatureDocument
  var name: String

  init(
    id: String = UUID().uuidString,
    name: String,
    document: SignatureDocument,
    conflictSourceId: String? = nil
  ) {
    self.id = id
    self.conflictSourceId = conflictSourceId
    self.document = document
    self.name = name
  }
}

enum SignatureComposeContext: String, Codable, Sendable {
  case newMessage
  case replyOrForward
}

struct SignatureAssignment: Codable, Equatable, Sendable {
  var newMessageSignatureId: String?
  var replyOrForwardSignatureId: String?
}

struct SignaturePreferences: Codable, Equatable, Sendable {
  static let empty = SignaturePreferences()
  static let primaryIdentifier = "mail-workflow-preferences:signatures"
  static let supportedSchemaVersion = 1

  var assignments: [String: SignatureAssignment]
  let schemaVersion: Int
  var signatures: [MailSignature]

  init(
    signatures: [MailSignature] = [],
    assignments: [String: SignatureAssignment] = [:]
  ) {
    self.assignments = assignments
    schemaVersion = Self.supportedSchemaVersion
    self.signatures = signatures
  }

  private enum CodingKeys: String, CodingKey {
    case assignments
    case legacySignature = "signature"
    case schemaVersion
    case signatures
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion <= Self.supportedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Signature preference schema is newer than this client supports."
      )
    }
    assignments =
      try container.decodeIfPresent([String: SignatureAssignment].self, forKey: .assignments) ?? [:]
    if let decoded = try container.decodeIfPresent([MailSignature].self, forKey: .signatures) {
      signatures = decoded
    } else if let legacy = try container.decodeIfPresent(
      MailSignature.self,
      forKey: .legacySignature
    ) {
      signatures = [legacy]
    } else {
      signatures = []
    }
    schemaVersion = max(1, decodedSchemaVersion)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(assignments, forKey: .assignments)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(signatures, forKey: .signatures)
  }

  func signature(
    for connectionId: MailboxConnectionId?,
    context: SignatureComposeContext
  ) -> MailSignature? {
    guard let connectionId, let assignment = assignments[connectionId.rawValue] else { return nil }
    let signatureId =
      context == .newMessage
      ? assignment.newMessageSignatureId
      : assignment.replyOrForwardSignatureId
    return signatures.first { $0.id == signatureId }
  }

  func value(for field: SignaturePreferenceField) -> SignaturePreferenceValue {
    switch field.kind {
    case .signature(let id):
      return .signature(signatures.first { $0.id == id })
    case .newMessage(let connectionId):
      return .identifier(assignments[connectionId]?.newMessageSignatureId)
    case .replyOrForward(let connectionId):
      return .identifier(assignments[connectionId]?.replyOrForwardSignatureId)
    }
  }

  mutating func set(
    _ value: SignaturePreferenceValue,
    for field: SignaturePreferenceField
  ) {
    switch (field.kind, value) {
    case (.signature(let id), .signature(let signature)):
      signatures.removeAll { $0.id == id }
      if let signature { signatures.append(signature) }
      signatures.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case (.newMessage(let connectionId), .identifier(let signatureId)):
      var assignment = assignments[connectionId] ?? SignatureAssignment()
      assignment.newMessageSignatureId = signatureId
      assignments[connectionId] = assignment.isEmpty ? nil : assignment
    case (.replyOrForward(let connectionId), .identifier(let signatureId)):
      var assignment = assignments[connectionId] ?? SignatureAssignment()
      assignment.replyOrForwardSignatureId = signatureId
      assignments[connectionId] = assignment.isEmpty ? nil : assignment
    default:
      assertionFailure("Signature preference field and value did not match")
    }
  }

  func validated() throws -> SignaturePreferences {
    var normalized: [MailSignature] = []
    var names: Set<String> = []
    for var signature in signatures {
      signature.name = signature.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...80).contains(signature.name.count) else {
        throw SignatureSyncError.invalidName
      }
      guard
        names.insert(
          signature.name.folding(
            options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")
          )
        ).inserted
      else {
        throw SignatureSyncError.duplicateName
      }
      signature.document = try signature.document.validated()
      normalized.append(signature)
    }
    let availableIds = Set(normalized.map(\.id))
    let normalizedAssignments = assignments.compactMapValues { assignment in
      let normalized = SignatureAssignment(
        newMessageSignatureId: assignment.newMessageSignatureId.flatMap {
          availableIds.contains($0) ? $0 : nil
        },
        replyOrForwardSignatureId: assignment.replyOrForwardSignatureId.flatMap {
          availableIds.contains($0) ? $0 : nil
        }
      )
      return normalized.isEmpty ? nil : normalized
    }
    return SignaturePreferences(signatures: normalized, assignments: normalizedAssignments)
  }
}

extension SignatureAssignment {
  fileprivate var isEmpty: Bool {
    newMessageSignatureId == nil && replyOrForwardSignatureId == nil
  }
}

struct SignaturePreferenceField: Codable, Hashable, Identifiable, Sendable {
  enum Kind {
    case newMessage(String)
    case replyOrForward(String)
    case signature(String)
  }

  let rawValue: String
  var id: String { rawValue }

  static func newMessage(_ connectionId: String) -> Self {
    Self(rawValue: "new-message:\(connectionId)")
  }

  static func replyOrForward(_ connectionId: String) -> Self {
    Self(rawValue: "reply-forward:\(connectionId)")
  }

  static func signature(_ id: String) -> Self {
    Self(rawValue: "signature:\(id)")
  }

  var kind: Kind {
    if rawValue.hasPrefix("new-message:") {
      return .newMessage(String(rawValue.dropFirst("new-message:".count)))
    }
    if rawValue.hasPrefix("reply-forward:") {
      return .replyOrForward(String(rawValue.dropFirst("reply-forward:".count)))
    }
    return .signature(String(rawValue.dropFirst("signature:".count)))
  }
}

enum SignaturePreferenceValue: Codable, Equatable, Sendable {
  case identifier(String?)
  case signature(MailSignature?)
}

struct SignaturePreferenceSyncSnapshot: Equatable, Sendable {
  let preferences: SignaturePreferences
  let updatedAt: Int64?

  init(preferences: SignaturePreferences, updatedAt: Int64?) {
    self.preferences = preferences
    self.updatedAt = updatedAt
  }

  init(preferences: SignaturePreferences, revision: ProductSyncRecordRevision) {
    self.preferences = preferences
    updatedAt = revision.legacyUpdatedAt
  }
}

enum SignaturePreferenceConditionalSaveResult: Equatable, Sendable {
  case committed(SignaturePreferenceSyncSnapshot)
  case conflict(SignaturePreferenceSyncSnapshot)
}

protocol SignaturePreferenceSyncing {
  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> SignaturePreferenceSyncSnapshot?

  func savePreferences(
    _ preferences: SignaturePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> SignaturePreferenceConditionalSaveResult
}

enum SignatureSyncError: LocalizedError, Equatable {
  case duplicateName
  case emptyBody
  case invalidLink
  case invalidName
  case missingProductSyncKeyMaterial
  case retryLimitExceeded

  var errorDescription: String? {
    switch self {
    case .duplicateName:
      return "Choose a signature name that is not already in use."
    case .emptyBody:
      return "A signature must contain visible text."
    case .invalidLink:
      return "Signature links must use HTTP, HTTPS, or mailto."
    case .invalidName:
      return "Signature names must contain between 1 and 80 characters."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing signatures."
    case .retryLimitExceeded:
      return "Signatures kept changing on another device. Try syncing again."
    }
  }
}

final class SignatureSyncService: SignaturePreferenceSyncing {
  private let preferenceRecord: ProductSyncSingletonHandle<SignaturePreferences>

  init(
    recordScope: MailProfileRecordScope = .legacyProductAccount,
    recordBoundary: ProductSyncRecordBoundary = ProductSyncRecordBoundary()
  ) {
    preferenceRecord = recordBoundary.singleton(
      ProductSyncSingletonDefinition(
        identifier: recordScope.productSyncIdentifier(SignaturePreferences.primaryIdentifier),
        cachePolicy: .authoritative
      )
    )
  }

  func loadPreferences(
    session: ProductAccountSessionSnapshot
  ) async throws -> SignaturePreferenceSyncSnapshot? {
    do {
      guard let record = try await preferenceRecord.read(session: session) else { return nil }
      return SignaturePreferenceSyncSnapshot(
        preferences: try record.value.validated(),
        revision: record.revision
      )
    } catch {
      throw mapBoundaryError(error)
    }
  }

  func savePreferences(
    _ preferences: SignaturePreferences,
    expectedUpdatedAt: Int64?,
    session: ProductAccountSessionSnapshot
  ) async throws -> SignaturePreferenceConditionalSaveResult {
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
          SignaturePreferenceSyncSnapshot(
            preferences: record.value,
            revision: record.revision
          ))
      case .conflict(let record):
        return .conflict(
          SignaturePreferenceSyncSnapshot(
            preferences: try record.value.validated(),
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
      return SignatureSyncError.missingProductSyncKeyMaterial
    case .retryLimitExceeded:
      return SignatureSyncError.retryLimitExceeded
    default:
      return error
    }
  }
}
