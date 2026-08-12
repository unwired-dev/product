import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftData

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

// swiftlint:disable file_length function_parameter_count type_body_length

#if canImport(UIKit)
  private let microsoftGraphCanRegisterPush = true
#else
  private let microsoftGraphCanRegisterPush = false
#endif

extension MailProviderId {
  static let microsoftGraph = MailProviderId(rawValue: "microsoft-graph")
}

extension MailboxConnectionCapabilities {
  static let microsoftGraph = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: true,
    canReadMessages: true,
    canRequestReadReceipts: true,
    canRegisterPush: microsoftGraphCanRegisterPush,
    canReply: true,
    canRespondToReadReceipts: false,
    canSearchProvider: false,
    canSend: true,
    canSynchronizeMetadata: true,
    providerActions: [.markRead, .markUnread]
  )

  static func microsoftGraph(
    folders: [MicrosoftGraphFolder]
  ) -> MailboxConnectionCapabilities {
    var actions: Set<ProviderMailAction> = [.markRead, .markUnread]
    let roles = Set(folders.compactMap(\.role))
    if roles.contains(.archive) { actions.insert(.archive) }
    if roles.contains(.trash) { actions.insert(.delete) }
    if roles.contains(.spam) { actions.insert(.spam) }
    if roles.contains(.inbox) {
      actions.formUnion([.notSpam, .restore])
    }
    if folders.contains(where: { $0.role == nil }) {
      actions.insert(.move)
    }
    return MailboxConnectionCapabilities(
      canCategorizeHistorical: false,
      canForward: true,
      canReadMessages: true,
      canRequestReadReceipts: true,
      canRegisterPush: microsoftGraphCanRegisterPush,
      canReply: true,
      canRespondToReadReceipts: false,
      canSearchProvider: false,
      canSend: true,
      canSynchronizeMetadata: true,
      providerActions: actions
    )
  }
}

struct MicrosoftGraphTokens: Codable, Equatable, Sendable {
  let accessToken: String
  let authorizationGeneration: Int
  let expiresAtMilliseconds: Int64
  let grantedScopes: Set<String>?
  let refreshToken: String

  init(
    accessToken: String,
    authorizationGeneration: Int = 0,
    expiresAtMilliseconds: Int64,
    grantedScopes: Set<String>? = nil,
    refreshToken: String
  ) {
    self.accessToken = accessToken
    self.authorizationGeneration = authorizationGeneration
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.grantedScopes = grantedScopes
    self.refreshToken = refreshToken
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accessToken = try container.decode(String.self, forKey: .accessToken)
    authorizationGeneration =
      try container.decodeIfPresent(Int.self, forKey: .authorizationGeneration) ?? 0
    expiresAtMilliseconds = try container.decode(Int64.self, forKey: .expiresAtMilliseconds)
    grantedScopes = try container.decodeIfPresent(Set<String>.self, forKey: .grantedScopes)
    refreshToken = try container.decode(String.self, forKey: .refreshToken)
  }

  var hasFullMailAccess: Bool {
    guard let grantedScopes else { return false }
    let normalized = Set(grantedScopes.map { $0.lowercased() })
    return normalized.contains("mail.readwrite") && normalized.contains("mail.send")
  }

  func withAuthorizationGeneration(_ authorizationGeneration: Int) -> Self {
    MicrosoftGraphTokens(
      accessToken: accessToken,
      authorizationGeneration: authorizationGeneration,
      expiresAtMilliseconds: expiresAtMilliseconds,
      grantedScopes: grantedScopes,
      refreshToken: refreshToken
    )
  }

  private enum CodingKeys: String, CodingKey {
    case accessToken
    case authorizationGeneration
    case expiresAtMilliseconds
    case grantedScopes
    case refreshToken
  }
}

struct MicrosoftGraphAccount: Equatable, Sendable {
  let displayName: String
  let emailAddress: String
  let id: String
}

@MainActor
protocol MicrosoftGraphAuthorizing {
  func authorize() async throws -> MicrosoftGraphTokens
  func authorize(selectingAccount: Bool) async throws -> MicrosoftGraphTokens
  func refresh(_ tokens: MicrosoftGraphTokens) async throws -> MicrosoftGraphTokens
}

extension MicrosoftGraphAuthorizing {
  func authorize(selectingAccount _: Bool) async throws -> MicrosoftGraphTokens {
    try await authorize()
  }
}

protocol MicrosoftGraphAuthorizationPersisting {
  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
  func clearAll(productAccountId: String) throws
  func providerAccountIdentifiers(productAccountId: String) throws -> Set<String>
  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> MicrosoftGraphTokens?
  func save(
    _ tokens: MicrosoftGraphTokens,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws
}

struct KeychainMicrosoftGraphAuthorizationStore: MicrosoftGraphAuthorizationPersisting {
  private let service = "dev.unwired.mail.microsoft-graph-authorization"

  func clear(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    try KeychainStore.delete(
      service: service,
      account: tokenAccount(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    )
    var identifiers = try providerIdentifiers(productAccountId: productAccountId)
    identifiers.remove(providerAccountIdentifier)
    try saveProviderIdentifiers(identifiers, productAccountId: productAccountId)
  }

  func clearAll(productAccountId: String) throws {
    for identifier in try providerIdentifiers(productAccountId: productAccountId) {
      try KeychainStore.delete(
        service: service,
        account: tokenAccount(
          productAccountId: productAccountId,
          providerAccountIdentifier: identifier
        )
      )
    }
    try KeychainStore.delete(service: service, account: manifestAccount(productAccountId))
  }

  func providerAccountIdentifiers(productAccountId: String) throws -> Set<String> {
    try providerIdentifiers(productAccountId: productAccountId)
  }

  func load(
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws -> MicrosoftGraphTokens? {
    guard
      let json = try KeychainStore.readString(
        service: service,
        account: tokenAccount(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier
        )
      ),
      let data = json.data(using: .utf8)
    else { return nil }
    return try JSONDecoder().decode(MicrosoftGraphTokens.self, from: data)
  }

  func save(
    _ tokens: MicrosoftGraphTokens,
    productAccountId: String,
    providerAccountIdentifier: String
  ) throws {
    let data = try JSONEncoder().encode(tokens)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    let previousIdentifiers = try providerIdentifiers(productAccountId: productAccountId)
    var identifiers = previousIdentifiers
    identifiers.insert(providerAccountIdentifier)
    try saveProviderIdentifiers(identifiers, productAccountId: productAccountId)
    do {
      try KeychainStore.writeString(
        json,
        service: service,
        account: tokenAccount(
          productAccountId: productAccountId,
          providerAccountIdentifier: providerAccountIdentifier
        ),
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    } catch {
      try? saveProviderIdentifiers(previousIdentifiers, productAccountId: productAccountId)
      throw error
    }
  }

  private func providerIdentifiers(productAccountId: String) throws -> Set<String> {
    guard
      let json = try KeychainStore.readString(
        service: service,
        account: manifestAccount(productAccountId)
      ),
      let data = json.data(using: .utf8)
    else { return [] }
    return Set(try JSONDecoder().decode([String].self, from: data))
  }

  private func saveProviderIdentifiers(
    _ identifiers: Set<String>,
    productAccountId: String
  ) throws {
    guard !identifiers.isEmpty else {
      try KeychainStore.delete(service: service, account: manifestAccount(productAccountId))
      return
    }
    let data = try JSONEncoder().encode(identifiers.sorted())
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      json,
      service: service,
      account: manifestAccount(productAccountId),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }

  private func manifestAccount(_ productAccountId: String) -> String {
    "identities-\(productAccountId)"
  }

  private func tokenAccount(
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> String {
    "\(productAccountId)-\(providerAccountIdentifier)"
  }
}

#if DEBUG || TESTING
  final class InMemoryMicrosoftGraphAuthorizationStore:
    MicrosoftGraphAuthorizationPersisting
  {
    private var tokensByAccount: [String: MicrosoftGraphTokens] = [:]

    func clear(
      productAccountId: String,
      providerAccountIdentifier: String
    ) throws {
      tokensByAccount[key(productAccountId, providerAccountIdentifier)] = nil
    }

    func clearAll(productAccountId: String) throws {
      let prefix = "\(productAccountId)\0"
      tokensByAccount = tokensByAccount.filter { !$0.key.hasPrefix(prefix) }
    }

    func providerAccountIdentifiers(productAccountId: String) throws -> Set<String> {
      let prefix = "\(productAccountId)\0"
      return Set(
        tokensByAccount.keys.compactMap { key in
          key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        }
      )
    }

    func load(
      productAccountId: String,
      providerAccountIdentifier: String
    ) throws -> MicrosoftGraphTokens? {
      tokensByAccount[key(productAccountId, providerAccountIdentifier)]
    }

    func save(
      _ tokens: MicrosoftGraphTokens,
      productAccountId: String,
      providerAccountIdentifier: String
    ) throws {
      tokensByAccount[key(productAccountId, providerAccountIdentifier)] = tokens
    }

    private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
      "\(productAccountId)\0\(providerAccountIdentifier)"
    }
  }
#endif

struct MicrosoftGraphFolder: Codable, Equatable, Hashable, Sendable {
  let displayName: String
  let id: String
  let parentFolderId: String?
  let wellKnownName: String?

  var role: MailboxRole? {
    switch wellKnownName?.lowercased() {
    case "inbox":
      return .inbox
    case "drafts":
      return .drafts
    case "sentitems":
      return .sent
    case "archive":
      return .archive
    case "junkemail":
      return .spam
    case "deleteditems":
      return .trash
    default:
      return nil
    }
  }

  static func areOrdered(_ lhs: MicrosoftGraphFolder, _ rhs: MicrosoftGraphFolder) -> Bool {
    if lhs.role == .inbox, rhs.role != .inbox { return true }
    if rhs.role == .inbox, lhs.role != .inbox { return false }
    let displayNameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
    if displayNameOrder != .orderedSame { return displayNameOrder == .orderedAscending }
    return lhs.id < rhs.id
  }
}

struct MicrosoftGraphInternetMessageHeader: Codable, Equatable, Sendable {
  let name: String
  let value: String
}

struct MicrosoftGraphProviderMessage: Codable, Equatable, Sendable {
  var categoryId: String?
  var categoryIds: [String]?
  let ccRecipients: [String]
  let conversationId: String?
  let from: String?
  var hasAttachments: Bool? = .none
  let id: String
  let internetMessageHeaders: [MicrosoftGraphInternetMessageHeader]?
  let internetMessageId: String?
  let isRead: Bool
  let parentFolderId: String?
  let receivedDateTime: String?
  let sentDateTime: String?
  let removed: Bool
  let replyTo: [String]
  let subject: String
  let bodyPreview: String
  let toRecipients: [String]

  init(
    categoryId: String? = nil,
    categoryIds: [String]? = nil,
    ccRecipients: [String],
    conversationId: String?,
    from: String?,
    hasAttachments: Bool? = nil,
    id: String,
    internetMessageHeaders: [MicrosoftGraphInternetMessageHeader]? = nil,
    internetMessageId: String?,
    isRead: Bool,
    parentFolderId: String?,
    receivedDateTime: String?,
    sentDateTime: String? = nil,
    removed: Bool = false,
    replyTo: [String],
    subject: String,
    bodyPreview: String,
    toRecipients: [String]
  ) {
    self.categoryId = categoryId
    self.categoryIds = categoryIds
    self.ccRecipients = ccRecipients
    self.conversationId = conversationId
    self.from = from
    self.hasAttachments = hasAttachments
    self.id = id
    self.internetMessageHeaders = internetMessageHeaders
    self.internetMessageId = internetMessageId
    self.isRead = isRead
    self.parentFolderId = parentFolderId
    self.receivedDateTime = receivedDateTime
    self.sentDateTime = sentDateTime
    self.removed = removed
    self.replyTo = replyTo
    self.subject = subject
    self.bodyPreview = bodyPreview
    self.toRecipients = toRecipients
  }

  func mailboxMetadata(
    connectionId: MailboxConnectionId,
    connectedAt: Int64,
    foldersById: [String: MicrosoftGraphFolder]
  ) -> MailboxMessageMetadata? {
    guard !removed else { return nil }
    let folder = parentFolderId.flatMap { foldersById[$0] }
    var providerStateIds: [String] = []
    if !isRead { providerStateIds.append("UNREAD") }
    if let role = folder?.role {
      providerStateIds.append(role.providerStateId)
    } else if let parentFolderId {
      providerStateIds.append(Self.customFolderStateId(parentFolderId))
    }
    let dateMilliseconds = Self.dateMilliseconds(
      folder?.role == .sent ? sentDateTime ?? receivedDateTime : receivedDateTime
    )
    return MailboxMessageMetadata(
      categoryId: categoryId,
      connectionId: connectionId,
      from: from,
      isHistorical: dateMilliseconds < connectedAt,
      providerInternalDateMilliseconds: dateMilliseconds,
      providerMessageId: id,
      providerStateIds: providerStateIds.sorted(),
      providerThreadId: conversationId?.nonEmpty ?? "message:\(connectionId.rawValue):\(id)",
      recipientHeaders: (toRecipients + ccRecipients).isEmpty ? nil : toRecipients + ccRecipients,
      replyTo: replyTo.first,
      rfcMessageId: internetMessageId,
      snippet: bodyPreview,
      subject: subject,
      categoryIds: categoryIds,
      hasAttachments: hasAttachments ?? false,
      unsubscribeSuggestion: UnsubscribeSuggestionParser.suggestion(
        headers: (internetMessageHeaders ?? []).map { ($0.name, $0.value) }
      )
    )
  }

  static func customFolderStateId(_ folderId: String) -> String {
    let encoded = Data(folderId.utf8).graphBase64URLString()
    return "graph-folder:\(encoded)"
  }

  static func folderId(fromCustomFolderStateId stateId: String) -> String? {
    let prefix = "graph-folder:"
    guard stateId.hasPrefix(prefix) else { return nil }
    var encoded = String(stateId.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)?.nonEmpty
  }

  private static func dateMilliseconds(_ value: String?) -> Int64 {
    guard let value else { return 0 }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date =
      formatter.date(from: value)
      ?? ISO8601DateFormatter().date(from: value)
    return Int64((date?.timeIntervalSince1970 ?? 0) * 1_000)
  }
}

struct MicrosoftGraphAttachmentDescriptor: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case file
    case inlineImage
    case unsupportedItem
    case unsupportedReference
    case unsupported
  }

  let byteCount: Int
  let filename: String
  let id: String
  let kind: Kind
  let mimeType: String

  var mailboxAttachment: MailboxMessageAttachment? {
    guard kind == .file else { return nil }
    return MailboxMessageAttachment(
      byteCount: byteCount,
      filename: filename,
      id: id,
      mimeType: mimeType
    )
  }
}

extension MailboxRole {
  fileprivate var providerStateId: String {
    switch self {
    case .inbox:
      return "INBOX"
    case .drafts:
      return "DRAFT"
    case .sent:
      return "SENT"
    case .archive:
      return "ARCHIVE"
    case .spam:
      return "SPAM"
    case .trash:
      return "TRASH"
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct MicrosoftGraphMetadataPage: Equatable, Sendable {
  let messages: [MicrosoftGraphProviderMessage]
  let nextLink: URL?
  let deltaLink: URL?
}

enum MicrosoftGraphClientError: LocalizedError, Equatable {
  case deltaTokenExpired
  case invalidProviderResponse
  case invalidContinuationURL
  case missingMessageBody
  case requestFailed(Int)

  var errorDescription: String? {
    switch self {
    case .deltaTokenExpired:
      return "Microsoft Graph synchronization history expired and must be rebuilt."
    case .invalidProviderResponse:
      return "Microsoft Graph returned an invalid response."
    case .invalidContinuationURL:
      return "Microsoft Graph returned an unsafe continuation URL."
    case .missingMessageBody:
      return "Microsoft Graph did not return a readable message body."
    case .requestFailed(let status):
      return "Microsoft Graph request failed with HTTP status \(status)."
    }
  }
}

struct MicrosoftGraphSendError: LocalizedError {
  enum Stage: Equatable {
    case preparation
    case providerHandoff
  }

  let stage: Stage
  let underlyingError: Error
  let providerDraftId: String?

  init(
    stage: Stage,
    underlyingError: Error,
    providerDraftId: String? = nil
  ) {
    self.stage = stage
    self.underlyingError = underlyingError
    self.providerDraftId = providerDraftId
  }

  var errorDescription: String? {
    (underlyingError as? LocalizedError)?.errorDescription
  }
}

protocol MicrosoftGraphClient {
  func deleteDraft(_ draftId: String, accessToken: String) async throws
  func deliveryStatus(
    rfcMessageId: String,
    accessToken: String
  ) async throws -> MailboxDeliveryStatus
  func verifyAccount(accessToken: String) async throws -> MicrosoftGraphAccount
  func loadFolders(accessToken: String) async throws -> [MicrosoftGraphFolder]
  func loadRecentMetadataPage(
    folder: MicrosoftGraphFolder,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage
  func loadRecentDeltaMetadataPage(
    folder: MicrosoftGraphFolder,
    receivedAfterMilliseconds: Int64,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage
  func loadMetadataPage(
    folder: MicrosoftGraphFolder,
    continuationURL: URL?,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage
  func loadAttachmentDescriptors(
    messageId: String,
    accessToken: String
  ) async throws -> [MicrosoftGraphAttachmentDescriptor]
  func loadAttachmentData(
    messageId: String,
    attachmentId: String,
    expectedByteCount: Int,
    maximumByteCount: Int,
    accessToken: String
  ) async throws -> Data
  func loadTextBody(messageId: String, accessToken: String) async throws -> String
  func moveMessage(
    messageId: String,
    destinationFolderId: String,
    accessToken: String
  ) async throws
  func send(_ message: OutgoingMessage, accessToken: String) async throws
  func setMessageRead(
    _ isRead: Bool,
    messageId: String,
    accessToken: String
  ) async throws
}

struct URLSessionMicrosoftGraphClient: MicrosoftGraphClient {
  private static let baseURL = URL(string: "https://graph.microsoft.com/v1.0")!
  private static let outboxPropertyId =
    "String {576B35CE-054C-4D8A-8D4F-B90700B843D2} Name UnwiredOutboxId"
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func deliveryStatus(
    rfcMessageId: String,
    accessToken: String
  ) async throws -> MailboxDeliveryStatus {
    let idempotencyKey =
      rfcMessageId
      .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
      .replacingOccurrences(of: "@outbox.unwired.mail", with: "")
    return try await messageIdentifier(
      folder: "sentitems",
      idempotencyKey: idempotencyKey,
      accessToken: accessToken
    ) == nil ? .unknown : .sent
  }

  private func messageIdentifier(
    folder: String,
    idempotencyKey: String,
    accessToken: String
  ) async throws -> GraphMessageIdentifierResponse? {
    var components = URLComponents(
      url: try graphURL(pathComponents: ["me", "mailFolders", folder, "messages"]),
      resolvingAgainstBaseURL: false
    )!
    let propertyId = Self.outboxPropertyId.replacingOccurrences(of: "'", with: "''")
    let propertyValue = idempotencyKey.replacingOccurrences(of: "'", with: "''")
    components.queryItems = [
      URLQueryItem(
        name: "$filter",
        value:
          "singleValueExtendedProperties/Any(ep: ep/id eq '\(propertyId)' "
          + "and ep/value eq '\(propertyValue)')"
      ),
      URLQueryItem(name: "$select", value: "id"),
      URLQueryItem(name: "$top", value: "1"),
    ]
    let response: GraphMessageIdentifierPageResponse = try await get(
      try requiredURL(components),
      accessToken: accessToken,
      preferences: [#"IdType="ImmutableId""#]
    )
    return response.value.first
  }

  func verifyAccount(accessToken: String) async throws -> MicrosoftGraphAccount {
    var components = URLComponents(
      url: Self.baseURL.appendingPathComponent("me"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "$select", value: "id,displayName,mail,userPrincipalName")
    ]
    let response: GraphUserResponse = try await get(
      try requiredURL(components),
      accessToken: accessToken
    )
    let emailAddress = response.mail?.nonEmpty ?? response.userPrincipalName.nonEmpty
    guard let emailAddress else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    return MicrosoftGraphAccount(
      displayName: response.displayName.nonEmpty ?? emailAddress,
      emailAddress: emailAddress,
      id: response.id
    )
  }

  func loadFolders(accessToken: String) async throws -> [MicrosoftGraphFolder] {
    var pendingURLs = [try folderListURL(parentFolderId: nil)]
    var foldersById: [String: MicrosoftGraphFolder] = [:]
    while !pendingURLs.isEmpty {
      try Task.checkCancellation()
      let url = pendingURLs.removeFirst()
      let response: GraphFolderPageResponse = try await get(
        url,
        accessToken: accessToken,
        preferences: [#"IdType="ImmutableId""#]
      )
      for graphFolder in response.value {
        let folder = graphFolder.folder
        foldersById[folder.id] = folder
        if graphFolder.childFolderCount > 0 {
          pendingURLs.append(try folderListURL(parentFolderId: folder.id))
        }
      }
      if let nextLink = response.nextLink {
        pendingURLs.insert(try safeContinuationURL(nextLink), at: 0)
      }
    }
    for wellKnownName in Self.wellKnownFolderNames {
      guard
        let id = try await loadWellKnownFolderId(
          wellKnownName,
          accessToken: accessToken
        ),
        let folder = foldersById[id]
      else { continue }
      foldersById[id] = MicrosoftGraphFolder(
        displayName: folder.displayName,
        id: folder.id,
        parentFolderId: folder.parentFolderId,
        wellKnownName: wellKnownName
      )
    }
    return foldersById.values.sorted(by: Self.foldersAreOrdered)
  }

  func loadMetadataPage(
    folder: MicrosoftGraphFolder,
    continuationURL: URL?,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage {
    let url =
      if let continuationURL {
        try safeContinuationURL(continuationURL)
      } else {
        try metadataURL(folder: folder, pageSize: pageSize)
      }
    let response: GraphMessagePageResponse = try await get(
      url,
      accessToken: accessToken,
      preferences: [
        #"IdType="ImmutableId""#,
        "odata.maxpagesize=\(pageSize)",
      ]
    )
    return MicrosoftGraphMetadataPage(
      messages: response.value.map(\.providerMessage),
      nextLink: try response.nextLink.map(safeContinuationURL),
      deltaLink: try response.deltaLink.map(safeContinuationURL)
    )
  }

  func loadRecentMetadataPage(
    folder: MicrosoftGraphFolder,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage {
    let response: GraphMessagePageResponse = try await get(
      try recentMetadataURL(folder: folder, pageSize: pageSize),
      accessToken: accessToken,
      preferences: [#"IdType="ImmutableId""#]
    )
    return MicrosoftGraphMetadataPage(
      messages: response.value.map(\.providerMessage),
      nextLink: nil,
      deltaLink: nil
    )
  }

  func loadRecentDeltaMetadataPage(
    folder: MicrosoftGraphFolder,
    receivedAfterMilliseconds: Int64,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage {
    let response: GraphMessagePageResponse = try await get(
      try metadataURL(
        folder: folder,
        pageSize: pageSize,
        receivedAfterMilliseconds: receivedAfterMilliseconds
      ),
      accessToken: accessToken,
      preferences: [
        #"IdType="ImmutableId""#,
        "odata.maxpagesize=\(pageSize)",
      ]
    )
    return MicrosoftGraphMetadataPage(
      messages: response.value.map(\.providerMessage),
      nextLink: try response.nextLink.map(safeContinuationURL),
      deltaLink: try response.deltaLink.map(safeContinuationURL)
    )
  }

  func loadTextBody(messageId: String, accessToken: String) async throws -> String {
    var components = URLComponents(
      url: try graphURL(pathComponents: ["me", "messages", messageId]),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "$select", value: "body")]
    let response: GraphMessageBodyResponse = try await get(
      try requiredURL(components),
      accessToken: accessToken,
      preferences: [
        #"IdType="ImmutableId""#,
        #"outlook.body-content-type="text""#,
      ]
    )
    guard response.body.contentType.lowercased() == "text" else {
      throw MicrosoftGraphClientError.missingMessageBody
    }
    return response.body.content
  }

  func loadAttachmentDescriptors(
    messageId: String,
    accessToken: String
  ) async throws -> [MicrosoftGraphAttachmentDescriptor] {
    var components = URLComponents(
      url: try graphURL(pathComponents: ["me", "messages", messageId, "attachments"]),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "$select", value: "id,name,contentType,size,isInline")
    ]
    var nextURL: URL? = try requiredURL(components)
    var descriptors: [MicrosoftGraphAttachmentDescriptor] = []
    while let url = nextURL {
      try Task.checkCancellation()
      let response: GraphAttachmentPageResponse = try await get(
        url,
        accessToken: accessToken,
        preferences: [#"IdType="ImmutableId""#]
      )
      descriptors.append(contentsOf: try response.value.map { try $0.descriptor })
      nextURL = try response.nextLink.map(safeContinuationURL)
    }
    return descriptors
  }

  func loadAttachmentData(
    messageId: String,
    attachmentId: String,
    expectedByteCount: Int,
    maximumByteCount: Int,
    accessToken: String
  ) async throws -> Data {
    guard expectedByteCount >= 0, maximumByteCount >= 0,
      expectedByteCount == 0 || expectedByteCount <= maximumByteCount
    else { throw MailboxMessageAttachmentError.invalidResponse }
    let url = try graphURL(
      pathComponents: ["me", "messages", messageId, "attachments", attachmentId, "$value"]
    )
    return try await boundedResponseData(
      url,
      expectedByteCount: expectedByteCount,
      maximumByteCount: maximumByteCount,
      accessToken: accessToken,
      preferences: [#"IdType="ImmutableId""#]
    )
  }

  func moveMessage(
    messageId: String,
    destinationFolderId: String,
    accessToken: String
  ) async throws {
    let url = try graphURL(pathComponents: ["me", "messages", messageId, "move"])
    try await requestNoContent(
      url,
      method: "POST",
      body: GraphMoveMessageRequest(destinationId: destinationFolderId),
      accessToken: accessToken,
      preferences: [#"IdType="ImmutableId""#],
      acceptedStatusCodes: 200..<300
    )
  }

  func setMessageRead(
    _ isRead: Bool,
    messageId: String,
    accessToken: String
  ) async throws {
    let url = try graphURL(pathComponents: ["me", "messages", messageId])
    try await requestNoContent(
      url,
      method: "PATCH",
      body: GraphReadStateRequest(isRead: isRead),
      accessToken: accessToken,
      acceptedStatusCodes: 200..<300
    )
  }

  func deleteDraft(_ draftId: String, accessToken: String) async throws {
    do {
      try await requestNoContent(
        try graphURL(pathComponents: ["me", "messages", draftId]),
        method: "DELETE",
        body: Optional<String>.none,
        accessToken: accessToken,
        acceptedStatusCodes: 200..<300
      )
    } catch MicrosoftGraphClientError.requestFailed(404) {
      // The draft was already sent or removed, so cleanup is complete.
    }
  }

  func send(_ message: OutgoingMessage, accessToken: String) async throws {
    guard let idempotencyKey = message.idempotencyKey else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    let draftResponse = try await preparedDraft(
      for: message,
      idempotencyKey: idempotencyKey,
      accessToken: accessToken
    )
    let sendURL = try graphURL(pathComponents: ["me", "messages", draftResponse.id, "send"])
    do {
      try await requestNoContent(
        sendURL,
        method: "POST",
        body: Optional<String>.none,
        accessToken: accessToken,
        acceptedStatusCodes: 200..<300
      )
    } catch {
      throw MicrosoftGraphSendError(
        stage: .providerHandoff,
        underlyingError: error,
        providerDraftId: draftResponse.id
      )
    }
  }

  private func preparedDraft(
    for message: OutgoingMessage,
    idempotencyKey: String,
    accessToken: String
  ) async throws -> GraphMessageIdentifierResponse {
    let recipients = Self.recipientAddresses(in: message.recipient)
    guard !recipients.isEmpty else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    let draft = GraphDraftRequest(
      body: GraphDraftRequest.Body(content: message.body, contentType: "Text"),
      internetMessageHeaders: message.kind == .reply
        ? nil
        : message.inReplyTo.map {
          [
            GraphDraftRequest.Header(name: "In-Reply-To", value: $0),
            GraphDraftRequest.Header(name: "References", value: $0),
          ]
        },
      isReadReceiptRequested: message.requestsReadReceipt == true,
      singleValueExtendedProperties: [
        GraphSingleValueExtendedProperty(
          id: Self.outboxPropertyId,
          value: idempotencyKey
        )
      ],
      subject: message.subject,
      toRecipients: recipients.map {
        GraphDraftRequest.Recipient(
          emailAddress: GraphDraftRequest.EmailAddress(address: $0)
        )
      }
    )
    let draftResponse: GraphMessageIdentifierResponse
    do {
      let existingDraft = try await messageIdentifier(
        folder: "drafts",
        idempotencyKey: idempotencyKey,
        accessToken: accessToken
      )
      if let existingDraft {
        draftResponse = existingDraft
      } else {
        draftResponse = try await createDraft(
          draft,
          for: message,
          accessToken: accessToken
        )
      }
    } catch {
      throw MicrosoftGraphSendError(stage: .preparation, underlyingError: error)
    }
    return draftResponse
  }

  private func createDraft(
    _ draft: GraphDraftRequest,
    for message: OutgoingMessage,
    accessToken: String
  ) async throws -> GraphMessageIdentifierResponse {
    guard message.kind == .reply else {
      return try await request(
        try graphURL(pathComponents: ["me", "messages"]),
        method: "POST",
        body: draft,
        accessToken: accessToken,
        preferences: [#"IdType="ImmutableId""#],
        acceptedStatusCodes: 200..<300
      )
    }
    guard let sourceMessageId = message.sourceProviderMessageId?.nonEmpty else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    let response: GraphMessageIdentifierResponse = try await request(
      try graphURL(pathComponents: ["me", "messages", sourceMessageId, "createReply"]),
      method: "POST",
      body: GraphReplyOrForwardDraftRequest(message: draft),
      accessToken: accessToken,
      preferences: [#"IdType="ImmutableId""#],
      acceptedStatusCodes: 200..<300
    )
    return response
  }

  private static func recipientAddresses(in value: String) -> [String] {
    var mailboxes: [String] = []
    var mailbox = ""
    var isEscaped = false
    var isQuoted = false
    var angleBracketDepth = 0

    for character in value {
      if isEscaped {
        mailbox.append(character)
        isEscaped = false
        continue
      }
      if character == "\\" && isQuoted {
        mailbox.append(character)
        isEscaped = true
        continue
      }
      switch character {
      case "\"":
        isQuoted.toggle()
      case "<" where !isQuoted:
        angleBracketDepth += 1
      case ">" where !isQuoted:
        angleBracketDepth = max(0, angleBracketDepth - 1)
      case "," where !isQuoted && angleBracketDepth == 0,
        ";" where !isQuoted && angleBracketDepth == 0:
        mailboxes.append(mailbox)
        mailbox = ""
        continue
      default:
        break
      }
      mailbox.append(character)
    }
    mailboxes.append(mailbox)
    return mailboxes.compactMap(mailboxAddress)
  }

  private static func mailboxAddress(in value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let address: String
    if let opening = trimmed.lastIndex(of: "<"),
      let closing = trimmed.lastIndex(of: ">"),
      opening < closing
    {
      address = String(trimmed[trimmed.index(after: opening)..<closing])
    } else {
      address = trimmed
    }
    return address.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
  }

  private func folderListURL(parentFolderId: String?) throws -> URL {
    var pathComponents = ["me", "mailFolders"]
    if let parentFolderId {
      pathComponents.append(parentFolderId)
      pathComponents.append("childFolders")
    }
    var components = URLComponents(
      url: try graphURL(pathComponents: pathComponents),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(
        name: "$select",
        value: "id,displayName,parentFolderId,childFolderCount"
      ),
      URLQueryItem(name: "$top", value: "100"),
    ]
    return try requiredURL(components)
  }

  private func loadWellKnownFolderId(
    _ wellKnownName: String,
    accessToken: String
  ) async throws -> String? {
    var components = URLComponents(
      url: Self.baseURL
        .appendingPathComponent("me")
        .appendingPathComponent("mailFolders")
        .appendingPathComponent(wellKnownName),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "$select", value: "id")]
    do {
      let response: GraphFolderIdentifierResponse = try await get(
        try requiredURL(components),
        accessToken: accessToken,
        preferences: [#"IdType="ImmutableId""#]
      )
      return response.id
    } catch MicrosoftGraphClientError.requestFailed(404) {
      return nil
    }
  }

  private func metadataURL(
    folder: MicrosoftGraphFolder,
    pageSize: Int,
    receivedAfterMilliseconds: Int64? = nil
  ) throws -> URL {
    var components = URLComponents(
      url: try graphURL(
        pathComponents: ["me", "mailFolders", folder.id, "messages", "delta"]
      ),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(
        name: "$select",
        value:
          "id,conversationId,parentFolderId,receivedDateTime,sentDateTime,subject,bodyPreview,"
          + "internetMessageId,internetMessageHeaders,isRead,hasAttachments,from,replyTo,"
          + "toRecipients,ccRecipients"
      ),
      URLQueryItem(name: "$top", value: String(pageSize)),
      URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
    ]
    if let receivedAfterMilliseconds {
      components.queryItems?.append(
        URLQueryItem(
          name: "$filter",
          value:
            "receivedDateTime ge "
            + ISO8601DateFormatter().string(
              from: Date(timeIntervalSince1970: Double(receivedAfterMilliseconds) / 1_000)
            )
        )
      )
    }
    return try requiredURL(components)
  }

  private func recentMetadataURL(
    folder: MicrosoftGraphFolder,
    pageSize: Int
  ) throws -> URL {
    var components = URLComponents(
      url: try graphURL(
        pathComponents: ["me", "mailFolders", folder.id, "messages"]
      ),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(
        name: "$select",
        value:
          "id,conversationId,parentFolderId,receivedDateTime,sentDateTime,subject,bodyPreview,"
          + "internetMessageId,internetMessageHeaders,isRead,hasAttachments,from,replyTo,"
          + "toRecipients,ccRecipients"
      ),
      URLQueryItem(name: "$top", value: String(pageSize)),
      URLQueryItem(name: "$orderby", value: "sentDateTime desc"),
    ]
    return try requiredURL(components)
  }

  private func get<Response: Decodable>(
    _ url: URL,
    accessToken: String,
    preferences: [String] = []
  ) async throws -> Response {
    try await request(
      url,
      method: "GET",
      body: Optional<String>.none,
      accessToken: accessToken,
      preferences: preferences,
      acceptedStatusCodes: 200..<300
    )
  }

  private func request<Response: Decodable, Body: Encodable>(
    _ url: URL,
    method: String,
    body: Body?,
    accessToken: String,
    preferences: [String] = [],
    acceptedStatusCodes: Range<Int>
  ) async throws -> Response {
    let data = try await responseData(
      url,
      method: method,
      body: body,
      accessToken: accessToken,
      preferences: preferences,
      acceptedStatusCodes: acceptedStatusCodes
    )
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
  }

  private func requestNoContent<Body: Encodable>(
    _ url: URL,
    method: String,
    body: Body?,
    accessToken: String,
    preferences: [String] = [],
    acceptedStatusCodes: Range<Int>
  ) async throws {
    _ = try await responseData(
      url,
      method: method,
      body: body,
      accessToken: accessToken,
      preferences: preferences,
      acceptedStatusCodes: acceptedStatusCodes
    )
  }

  private func responseData<Body: Encodable>(
    _ url: URL,
    method: String,
    body: Body?,
    accessToken: String,
    preferences: [String],
    acceptedStatusCodes: Range<Int>
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if !preferences.isEmpty {
      request.setValue(preferences.joined(separator: ", "), forHTTPHeaderField: "Prefer")
    }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    if response.statusCode == 410 {
      throw MicrosoftGraphClientError.deltaTokenExpired
    }
    guard acceptedStatusCodes.contains(response.statusCode) else {
      throw MicrosoftGraphClientError.requestFailed(response.statusCode)
    }
    return data
  }

  private func boundedResponseData(
    _ url: URL,
    expectedByteCount: Int,
    maximumByteCount: Int,
    accessToken: String,
    preferences: [String]
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if !preferences.isEmpty {
      request.setValue(preferences.joined(separator: ", "), forHTTPHeaderField: "Prefer")
    }
    return try await MicrosoftGraphAttachmentDataDelegate(
      expectedByteCount: expectedByteCount,
      maximumByteCount: maximumByteCount
    ).load(request, configuration: session.configuration)
  }

  private func safeContinuationURL(_ url: URL) throws -> URL {
    guard
      url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "graph.microsoft.com"
    else { throw MicrosoftGraphClientError.invalidContinuationURL }
    return url
  }

  private func requiredURL(_ components: URLComponents) throws -> URL {
    guard let url = components.url else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    return url
  }

  private func graphURL(pathComponents: [String]) throws -> URL {
    var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
    var allowedCharacters = CharacterSet.urlPathAllowed
    allowedCharacters.remove(charactersIn: "/")
    let encodedPathComponents = try pathComponents.map { component in
      guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
      else { throw MicrosoftGraphClientError.invalidProviderResponse }
      return encoded
    }
    components.percentEncodedPath += "/" + encodedPathComponents.joined(separator: "/")
    return try requiredURL(components)
  }

  private static func foldersAreOrdered(
    _ lhs: MicrosoftGraphFolder,
    _ rhs: MicrosoftGraphFolder
  ) -> Bool {
    MicrosoftGraphFolder.areOrdered(lhs, rhs)
  }

  private static let wellKnownFolderNames = [
    "inbox",
    "drafts",
    "sentitems",
    "archive",
    "junkemail",
    "deleteditems",
  ]
}

private final class MicrosoftGraphAttachmentDataDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let expectedByteCount: Int
  private let lock = NSLock()
  private let maximumByteCount: Int
  private var continuation: CheckedContinuation<Data, Error>?
  private var data = Data()
  private var isCancelled = false
  private var session: URLSession?
  private var task: URLSessionDataTask?

  init(expectedByteCount: Int, maximumByteCount: Int) {
    self.expectedByteCount = expectedByteCount
    self.maximumByteCount = maximumByteCount
  }

  func load(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
    let data: Data = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          guard !isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          self.continuation = continuation
          let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
          let task = session.dataTask(with: request)
          self.session = session
          self.task = task
          task.resume()
        }
      }
    } onCancel: {
      cancel()
    }
    try Task.checkCancellation()
    return data
  }

  func urlSession(
    _: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let error: Error?
    if let response = response as? HTTPURLResponse {
      if (200..<300).contains(response.statusCode) {
        let declaredByteCount = response.expectedContentLength
        if declaredByteCount < 0 || declaredByteCount <= Int64(maximumByteCount),
          expectedByteCount == 0 || declaredByteCount < 0
            || declaredByteCount <= Int64(expectedByteCount)
        {
          if declaredByteCount > 0 {
            lock.withLock { data.reserveCapacity(Int(declaredByteCount)) }
          }
          error = nil
        } else {
          error = MailboxMessageAttachmentError.invalidResponse
        }
      } else {
        error = MicrosoftGraphClientError.requestFailed(response.statusCode)
      }
    } else {
      error = MicrosoftGraphClientError.invalidProviderResponse
    }
    guard let error else {
      completionHandler(.allow)
      return
    }
    completionHandler(.cancel)
    dataTask.cancel()
    finish(.failure(error))
  }

  func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    let exceedsLimit = lock.withLock {
      let (receivedByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
      guard !overflow, receivedByteCount <= maximumByteCount,
        expectedByteCount == 0 || receivedByteCount <= expectedByteCount
      else { return true }
      data.append(chunk)
      return false
    }
    if exceedsLimit {
      dataTask.cancel()
      finish(.failure(MailboxMessageAttachmentError.invalidResponse))
    }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    let state = lock.withLock { (isCancelled, data) }
    if let error {
      if state.0 || (error as? URLError)?.code == .cancelled {
        finish(.failure(CancellationError()))
      } else {
        finish(.failure(error))
      }
    } else {
      finish(.success(state.1))
    }
  }

  private func cancel() {
    let task = lock.withLock {
      isCancelled = true
      return self.task
    }
    task?.cancel()
  }

  private func finish(_ result: Result<Data, Error>) {
    let completion = lock.withLock {
      let completion = (continuation, session)
      continuation = nil
      session = nil
      task = nil
      return completion
    }
    completion.1?.finishTasksAndInvalidate()
    completion.0?.resume(with: result)
  }
}

private struct GraphUserResponse: Decodable {
  let displayName: String
  let id: String
  let mail: String?
  let userPrincipalName: String
}

private struct GraphFolderPageResponse: Decodable {
  let nextLink: URL?
  let value: [GraphFolderResponse]

  enum CodingKeys: String, CodingKey {
    case nextLink = "@odata.nextLink"
    case value
  }
}

private struct GraphFolderResponse: Decodable {
  let childFolderCount: Int
  let displayName: String
  let id: String
  let parentFolderId: String?
  let wellKnownName: String?

  var folder: MicrosoftGraphFolder {
    MicrosoftGraphFolder(
      displayName: displayName,
      id: id,
      parentFolderId: parentFolderId,
      wellKnownName: wellKnownName
    )
  }
}

private struct GraphFolderIdentifierResponse: Decodable {
  let id: String
}

private struct GraphMessageIdentifierResponse: Decodable {
  let id: String
}

private struct GraphMessageIdentifierPageResponse: Decodable {
  let value: [GraphMessageIdentifierResponse]
}

private struct GraphMoveMessageRequest: Encodable {
  let destinationId: String
}

private struct GraphReadStateRequest: Encodable {
  let isRead: Bool
}

private struct GraphSingleValueExtendedProperty: Encodable {
  let id: String
  let value: String
}

private struct GraphDraftRequest: Encodable {
  struct Body: Encodable {
    let content: String
    let contentType: String
  }

  struct EmailAddress: Encodable {
    let address: String
  }

  struct Header: Encodable {
    let name: String
    let value: String
  }

  struct Recipient: Encodable {
    let emailAddress: EmailAddress
  }

  let body: Body
  let internetMessageHeaders: [Header]?
  let isReadReceiptRequested: Bool
  let singleValueExtendedProperties: [GraphSingleValueExtendedProperty]
  let subject: String
  let toRecipients: [Recipient]
}

private struct GraphReplyOrForwardDraftRequest: Encodable {
  let message: GraphDraftRequest
}

private struct GraphMessagePageResponse: Decodable {
  let deltaLink: URL?
  let nextLink: URL?
  let value: [GraphMessageResponse]

  enum CodingKeys: String, CodingKey {
    case deltaLink = "@odata.deltaLink"
    case nextLink = "@odata.nextLink"
    case value
  }
}

private struct GraphAttachmentPageResponse: Decodable {
  let nextLink: URL?
  let value: [GraphAttachmentResponse]

  enum CodingKeys: String, CodingKey {
    case nextLink = "@odata.nextLink"
    case value
  }
}

private struct GraphAttachmentResponse: Decodable {
  let contentType: String?
  let id: String
  let isInline: Bool?
  let name: String?
  let odataType: String
  let size: Int

  enum CodingKeys: String, CodingKey {
    case contentType
    case id
    case isInline
    case name
    case odataType = "@odata.type"
    case size
  }

  var descriptor: MicrosoftGraphAttachmentDescriptor {
    get throws {
      guard !id.isEmpty, size >= 0 else {
        throw MicrosoftGraphClientError.invalidProviderResponse
      }
      let kind: MicrosoftGraphAttachmentDescriptor.Kind
      switch odataType.lowercased() {
      case "#microsoft.graph.fileattachment":
        kind = isInline == true ? .inlineImage : .file
      case "#microsoft.graph.itemattachment":
        kind = .unsupportedItem
      case "#microsoft.graph.referenceattachment":
        kind = .unsupportedReference
      default:
        kind = .unsupported
      }
      return MicrosoftGraphAttachmentDescriptor(
        byteCount: size,
        filename: name?.nonEmpty ?? "Attachment",
        id: id,
        kind: kind,
        mimeType: contentType?.nonEmpty ?? "application/octet-stream"
      )
    }
  }
}

private struct GraphEmailAddressResponse: Decodable {
  let address: String
  let name: String?

  var displayValue: String {
    guard let name = name?.nonEmpty else { return address }
    return "\(name) <\(address)>"
  }
}

private struct GraphRecipientResponse: Decodable {
  let emailAddress: GraphEmailAddressResponse
}

private struct GraphRemovedResponse: Decodable {
  let reason: String?
}

private struct GraphMessageResponse: Decodable {
  private static let unsubscribeHeaderNames = Set([
    "list-id", "list-unsubscribe", "list-unsubscribe-post",
  ])

  let bodyPreview: String?
  let ccRecipients: [GraphRecipientResponse]?
  let conversationId: String?
  let from: GraphRecipientResponse?
  let hasAttachments: Bool?
  let id: String
  let internetMessageHeaders: [MicrosoftGraphInternetMessageHeader]?
  let internetMessageId: String?
  let isRead: Bool?
  let parentFolderId: String?
  let receivedDateTime: String?
  let sentDateTime: String?
  let removed: GraphRemovedResponse?
  let replyTo: [GraphRecipientResponse]?
  let subject: String?
  let toRecipients: [GraphRecipientResponse]?

  enum CodingKeys: String, CodingKey {
    case bodyPreview
    case ccRecipients
    case conversationId
    case from
    case hasAttachments
    case id
    case internetMessageHeaders
    case internetMessageId
    case isRead
    case parentFolderId
    case receivedDateTime
    case sentDateTime
    case removed = "@removed"
    case replyTo
    case subject
    case toRecipients
  }

  var providerMessage: MicrosoftGraphProviderMessage {
    MicrosoftGraphProviderMessage(
      ccRecipients: ccRecipients?.map(\.emailAddress.displayValue) ?? [],
      conversationId: conversationId,
      from: from?.emailAddress.displayValue,
      hasAttachments: hasAttachments,
      id: id,
      internetMessageHeaders: internetMessageHeaders?.filter {
        Self.unsubscribeHeaderNames.contains($0.name.lowercased())
      },
      internetMessageId: internetMessageId,
      isRead: isRead ?? true,
      parentFolderId: parentFolderId,
      receivedDateTime: receivedDateTime,
      sentDateTime: sentDateTime,
      removed: removed != nil,
      replyTo: replyTo?.map(\.emailAddress.displayValue) ?? [],
      subject: subject ?? "",
      bodyPreview: bodyPreview ?? "",
      toRecipients: toRecipients?.map(\.emailAddress.displayValue) ?? []
    )
  }
}

private struct GraphMessageBodyResponse: Decodable {
  struct Body: Decodable {
    let content: String
    let contentType: String
  }

  let body: Body
}

struct MicrosoftGraphFolderSyncState: Codable, Equatable, Sendable {
  let folder: MicrosoftGraphFolder
  var deltaLink: URL?
  var nextLink: URL?
}

struct MicrosoftGraphMetadataSyncState: Codable, Equatable, Sendable {
  static let currentMetadataContractVersion = 2

  var folders: [MicrosoftGraphFolderSyncState]
  var hasInitialMailboxAvailability: Bool
  var initialCrawlMessageIdsByFolderId: [String: Set<String>]?
  var metadataContractVersion: Int?
  var recentInboxDeltaLink: URL?
  var recentInboxNextLink: URL?
  var seededMessageIdsByFolderId: [String: Set<String>]?

  init(
    folders: [MicrosoftGraphFolderSyncState],
    hasInitialMailboxAvailability: Bool,
    initialCrawlMessageIdsByFolderId: [String: Set<String>]? = nil,
    metadataContractVersion: Int? = Self.currentMetadataContractVersion,
    recentInboxDeltaLink: URL? = nil,
    recentInboxNextLink: URL? = nil,
    seededMessageIdsByFolderId: [String: Set<String>]? = nil
  ) {
    self.folders = folders
    self.hasInitialMailboxAvailability = hasInitialMailboxAvailability
    self.initialCrawlMessageIdsByFolderId = initialCrawlMessageIdsByFolderId
    self.metadataContractVersion = metadataContractVersion
    self.recentInboxDeltaLink = recentInboxDeltaLink
    self.recentInboxNextLink = recentInboxNextLink
    self.seededMessageIdsByFolderId = seededMessageIdsByFolderId
  }

  var historicalMetadataBackfillIsComplete: Bool {
    hasInitialMailboxAvailability && folders.allSatisfy { $0.deltaLink != nil }
  }

  var hasCompletedInitialCheckpoint: Bool {
    !hasInitialMailboxAvailability && folders.allSatisfy { $0.deltaLink != nil }
  }
}

protocol MicrosoftGraphMetadataPersisting {
  func clear(productAccountId: String) throws
  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
  func loadMessages(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [MicrosoftGraphProviderMessage]
  func loadState(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphMetadataSyncState?
  func replacePage(
    _ messages: [MicrosoftGraphProviderMessage],
    folderId: String,
    state: MicrosoftGraphMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
  func savePage(
    _ messages: [MicrosoftGraphProviderMessage],
    folderId: String,
    state: MicrosoftGraphMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    removingMessageIds: Set<String>
  ) throws
  func updateCategory(
    _ categoryId: String,
    messageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphProviderMessage
}

extension MicrosoftGraphMetadataPersisting {
  func savePage(
    _ messages: [MicrosoftGraphProviderMessage],
    folderId: String,
    state: MicrosoftGraphMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    try savePage(
      messages,
      folderId: folderId,
      state: state,
      productAccountId: productAccountId,
      connectionId: connectionId,
      removingMessageIds: []
    )
  }
}

@Model
final class DurableMicrosoftGraphMessageRecord {
  var connectionIdRawValue: String
  var encodedMessage: Data
  var parentFolderId: String?
  var productAccountId: String
  @Attribute(.unique) var storageKey: String
  var stableProviderMessageId: String

  init(
    connectionIdRawValue: String,
    encodedMessage: Data,
    parentFolderId: String?,
    productAccountId: String,
    storageKey: String,
    stableProviderMessageId: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedMessage = encodedMessage
    self.parentFolderId = parentFolderId
    self.productAccountId = productAccountId
    self.storageKey = storageKey
    self.stableProviderMessageId = stableProviderMessageId
  }

  func message() throws -> MicrosoftGraphProviderMessage {
    try JSONDecoder().decode(MicrosoftGraphProviderMessage.self, from: encodedMessage)
  }
}

@Model
final class MicrosoftGraphSyncCheckpointRecord {
  var connectionIdRawValue: String
  var encodedState: Data
  var productAccountId: String
  @Attribute(.unique) var storageKey: String

  init(
    connectionIdRawValue: String,
    encodedState: Data,
    productAccountId: String,
    storageKey: String
  ) {
    self.connectionIdRawValue = connectionIdRawValue
    self.encodedState = encodedState
    self.productAccountId = productAccountId
    self.storageKey = storageKey
  }
}

struct SwiftDataMicrosoftGraphMetadataStore: MicrosoftGraphMetadataPersisting {
  private let containerResult: Result<ModelContainer, Error>

  init(container: ModelContainer? = nil) {
    containerResult = Result {
      if let container { return container }
      let configuration = ModelConfiguration("MicrosoftGraphMetadata", schema: Self.schema)
      return try ModelContainer(for: Self.schema, configurations: [configuration])
    }
  }

  static func inMemory() throws -> SwiftDataMicrosoftGraphMetadataStore {
    let configuration = ModelConfiguration(
      "MicrosoftGraphMetadataTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    return SwiftDataMicrosoftGraphMetadataStore(
      container: try ModelContainer(for: schema, configurations: [configuration])
    )
  }

  func clear(productAccountId: String) throws {
    let context = try makeContext()
    let messages = try context.fetch(
      FetchDescriptor<DurableMicrosoftGraphMessageRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    messages.forEach(context.delete)
    let checkpoints = try context.fetch(
      FetchDescriptor<MicrosoftGraphSyncCheckpointRecord>(
        predicate: #Predicate { $0.productAccountId == productAccountId }
      )
    )
    checkpoints.forEach(context.delete)
    try context.save()
  }

  func clear(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    for record in try records(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      context.delete(record)
    }
    if let checkpoint = try checkpoint(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      context.delete(checkpoint)
    }
    try context.save()
  }

  func loadMessages(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> [MicrosoftGraphProviderMessage] {
    try records(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: makeContext()
    ).map { try $0.message() }
  }

  func loadState(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphMetadataSyncState? {
    let context = try makeContext()
    guard
      let checkpoint = try checkpoint(
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      )
    else { return nil }
    return try JSONDecoder().decode(
      MicrosoftGraphMetadataSyncState.self,
      from: checkpoint.encodedState
    )
  }

  func savePage(
    _ messages: [MicrosoftGraphProviderMessage],
    folderId: String,
    state: MicrosoftGraphMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    removingMessageIds: Set<String> = []
  ) throws {
    let context = try makeContext()
    let messageIds = Set(messages.map(\.id))
    let existing = Dictionary(
      uniqueKeysWithValues: try records(
        matching: messageIds.union(removingMessageIds),
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      ).map { ($0.stableProviderMessageId, $0) }
    )
    for messageId in removingMessageIds.subtracting(messageIds) {
      if let record = existing[messageId], record.parentFolderId == folderId {
        context.delete(record)
      }
    }
    for var message in messages {
      if message.removed {
        if let record = existing[message.id], record.parentFolderId == folderId {
          context.delete(record)
        }
        continue
      }
      if let record = existing[message.id] {
        preserveCategory(of: &message, from: record)
        record.encodedMessage = try JSONEncoder().encode(message)
        record.parentFolderId = message.parentFolderId
      } else {
        context.insert(
          DurableMicrosoftGraphMessageRecord(
            connectionIdRawValue: connectionId.rawValue,
            encodedMessage: try JSONEncoder().encode(message),
            parentFolderId: message.parentFolderId,
            productAccountId: productAccountId,
            storageKey: Self.messageStorageKey(
              productAccountId: productAccountId,
              connectionId: connectionId,
              messageId: message.id
            ),
            stableProviderMessageId: message.id
          )
        )
      }
    }
    try save(
      state: state,
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    )
    try context.save()
  }

  func replacePage(
    _ messages: [MicrosoftGraphProviderMessage],
    folderId _: String,
    state: MicrosoftGraphMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    for record in try records(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      context.delete(record)
    }
    if let checkpoint = try checkpoint(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      context.delete(checkpoint)
    }
    for message in messages where !message.removed {
      context.insert(
        DurableMicrosoftGraphMessageRecord(
          connectionIdRawValue: connectionId.rawValue,
          encodedMessage: try JSONEncoder().encode(message),
          parentFolderId: message.parentFolderId,
          productAccountId: productAccountId,
          storageKey: Self.messageStorageKey(
            productAccountId: productAccountId,
            connectionId: connectionId,
            messageId: message.id
          ),
          stableProviderMessageId: message.id
        )
      )
    }
    try save(
      state: state,
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    )
    try context.save()
  }

  private func preserveCategory(
    of message: inout MicrosoftGraphProviderMessage,
    from record: DurableMicrosoftGraphMessageRecord
  ) {
    guard message.categoryId == nil,
      let existingMessage = try? JSONDecoder().decode(
        MicrosoftGraphProviderMessage.self,
        from: record.encodedMessage
      )
    else { return }
    message.categoryId = existingMessage.categoryId
  }

  func updateCategory(
    _ categoryId: String,
    messageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphProviderMessage {
    let context = try makeContext()
    guard
      let record = try records(
        matching: [messageId],
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      ).first
    else { throw MicrosoftGraphClientError.invalidProviderResponse }
    var message = try record.message()
    message.categoryId = categoryId
    record.encodedMessage = try JSONEncoder().encode(message)
    try context.save()
    return message
  }

  private static let schema = Schema([
    DurableMicrosoftGraphMessageRecord.self,
    MicrosoftGraphSyncCheckpointRecord.self,
  ])

  private func makeContext() throws -> ModelContext {
    try ModelContext(containerResult.get())
  }

  private func records(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> [DurableMicrosoftGraphMessageRecord] {
    let connectionIdRawValue = connectionId.rawValue
    return try context.fetch(
      FetchDescriptor<DurableMicrosoftGraphMessageRecord>(
        predicate: #Predicate {
          $0.productAccountId == productAccountId
            && $0.connectionIdRawValue == connectionIdRawValue
        }
      )
    )
  }

  private func records(
    matching messageIds: Set<String>,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> [DurableMicrosoftGraphMessageRecord] {
    let connectionIdRawValue = connectionId.rawValue
    return try context.fetch(
      FetchDescriptor<DurableMicrosoftGraphMessageRecord>(
        predicate: #Predicate {
          $0.productAccountId == productAccountId
            && $0.connectionIdRawValue == connectionIdRawValue
            && messageIds.contains($0.stableProviderMessageId)
        }
      )
    )
  }

  private func checkpoint(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws -> MicrosoftGraphSyncCheckpointRecord? {
    let connectionIdRawValue = connectionId.rawValue
    var descriptor = FetchDescriptor<MicrosoftGraphSyncCheckpointRecord>(
      predicate: #Predicate {
        $0.productAccountId == productAccountId
          && $0.connectionIdRawValue == connectionIdRawValue
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func save(
    state: MicrosoftGraphMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId,
    context: ModelContext
  ) throws {
    let encoded = try JSONEncoder().encode(state)
    if let checkpoint = try checkpoint(
      productAccountId: productAccountId,
      connectionId: connectionId,
      context: context
    ) {
      checkpoint.encodedState = encoded
    } else {
      context.insert(
        MicrosoftGraphSyncCheckpointRecord(
          connectionIdRawValue: connectionId.rawValue,
          encodedState: encoded,
          productAccountId: productAccountId,
          storageKey: Self.checkpointStorageKey(
            productAccountId: productAccountId,
            connectionId: connectionId
          )
        )
      )
    }
  }

  private static func messageStorageKey(
    productAccountId: String,
    connectionId: MailboxConnectionId,
    messageId: String
  ) -> String {
    gmailSafeFileComponent("\(productAccountId)\0\(connectionId.rawValue)\0\(messageId)")
  }

  private static func checkpointStorageKey(
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) -> String {
    gmailSafeFileComponent("\(productAccountId)\0\(connectionId.rawValue)")
  }
}

struct MicrosoftGraphMetadataService {
  static let initialPageSize = 50

  private let client: MicrosoftGraphClient
  private let shouldContinueHistoricalBackfill: () -> Bool
  private let store: MicrosoftGraphMetadataPersisting

  init(
    client: MicrosoftGraphClient,
    shouldContinueHistoricalBackfill: @escaping () -> Bool = {
      !ProcessInfo.processInfo.isLowPowerModeEnabled
    },
    store: MicrosoftGraphMetadataPersisting
  ) {
    self.client = client
    self.shouldContinueHistoricalBackfill = shouldContinueHistoricalBackfill
    self.store = store
  }

  func load(
    connection: MailboxConnection,
    productAccountId: String,
    providerCursorIsExpired: Bool = false
  ) throws -> MailboxMetadataSyncResult {
    let state = try store.loadState(
      productAccountId: productAccountId,
      connectionId: connection.id
    )
    let folders = state?.folders.map(\.folder) ?? []
    let foldersById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    let messages = try store.loadMessages(
      productAccountId: productAccountId,
      connectionId: connection.id
    ).compactMap {
      $0.mailboxMetadata(
        connectionId: connection.id,
        connectedAt: connection.connectedAt,
        foldersById: foldersById
      )
    }
    .sorted(by: Self.messagesAreOrdered)
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: false,
      messages: messages,
      newMessageIds: nil,
      providerCursorIsExpired: providerCursorIsExpired,
      threads: MailboxThread.group(messages),
      hasInitialMailboxAvailability: state?.hasInitialMailboxAvailability ?? false,
      historicalMetadataBackfillIsComplete:
        state?.historicalMetadataBackfillIsComplete ?? false
    )
  }

  // swiftlint:disable:next function_body_length cyclomatic_complexity
  func sync(
    connection: MailboxConnection,
    productAccountId: String,
    accessToken: String,
    shouldPersist: @escaping () -> Bool = { true }
  ) async throws -> MailboxMetadataSyncResult {
    let folders = try await client.loadFolders(accessToken: accessToken)
      .sorted(by: Self.foldersAreOrdered)
    guard shouldPersist() else { throw CancellationError() }
    guard !folders.isEmpty else {
      return MailboxMetadataSyncResult(
        hasUnlistedNewMessages: false,
        messages: [],
        newMessageIds: nil,
        providerCursorIsExpired: false,
        threads: []
      )
    }
    var state = try store.loadState(
      productAccountId: productAccountId,
      connectionId: connection.id
    )
    let shouldReplaceStoredMetadata =
      state.map { state in
        state.metadataContractVersion
          != MicrosoftGraphMetadataSyncState.currentMetadataContractVersion
          || state.folders.map(\.folder.id) != folders.map(\.id)
      } ?? false
    state = try refreshedState(
      state,
      folders: folders,
      productAccountId: productAccountId,
      connectionId: connection.id
    )
    guard var state else {
      return try await start(
        folders: folders,
        connection: connection,
        productAccountId: productAccountId,
        accessToken: accessToken,
        cursorExpired: false,
        shouldReplaceStoredMetadata: shouldReplaceStoredMetadata,
        shouldPersist: shouldPersist
      )
    }
    if state.hasCompletedInitialCheckpoint {
      state.hasInitialMailboxAvailability = true
      try store.savePage(
        [],
        folderId: state.folders[0].folder.id,
        state: state,
        productAccountId: productAccountId,
        connectionId: connection.id
      )
    }
    do {
      for index in state.folders.indices {
        guard let deltaLink = state.folders[index].deltaLink else { continue }
        var continuation: URL? = deltaLink
        repeat {
          try Task.checkCancellation()
          let page = try await client.loadMetadataPage(
            folder: state.folders[index].folder,
            continuationURL: continuation,
            pageSize: Self.initialPageSize,
            accessToken: accessToken
          )
          guard shouldPersist() else { throw CancellationError() }
          state.folders[index].nextLink = page.nextLink
          state.folders[index].deltaLink = page.deltaLink ?? state.folders[index].deltaLink
          try store.savePage(
            page.messages,
            folderId: state.folders[index].folder.id,
            state: state,
            productAccountId: productAccountId,
            connectionId: connection.id
          )
          continuation = page.nextLink
        } while continuation != nil
      }
      guard state.historicalMetadataBackfillIsComplete else {
        if state.folders[0].deltaLink == nil {
          try await syncRecentInboxDelta(
            state: &state,
            connection: connection,
            productAccountId: productAccountId,
            accessToken: accessToken,
            shouldPersist: shouldPersist
          )
        }
        return try load(connection: connection, productAccountId: productAccountId)
          .limitedInitialPage(to: Self.initialPageSize)
      }
      return try load(connection: connection, productAccountId: productAccountId)
    } catch MicrosoftGraphClientError.deltaTokenExpired {
      try Task.checkCancellation()
      try store.clear(productAccountId: productAccountId, connectionId: connection.id)
      return try await start(
        folders: folders,
        connection: connection,
        productAccountId: productAccountId,
        accessToken: accessToken,
        cursorExpired: true,
        shouldPersist: shouldPersist
      )
    }
  }

  // swiftlint:disable:next function_body_length
  func continueBackfill(
    connection: MailboxConnection,
    productAccountId: String,
    accessToken: String
  ) async throws -> MailboxMetadataSyncResult {
    guard
      var state = try store.loadState(
        productAccountId: productAccountId,
        connectionId: connection.id
      )
    else {
      return try await sync(
        connection: connection,
        productAccountId: productAccountId,
        accessToken: accessToken
      )
    }
    guard
      state.metadataContractVersion
        == MicrosoftGraphMetadataSyncState.currentMetadataContractVersion
    else {
      return try await sync(
        connection: connection,
        productAccountId: productAccountId,
        accessToken: accessToken
      )
    }
    do {
      backfill: while let index = state.folders.firstIndex(where: { $0.deltaLink == nil }) {
        var continuation = state.folders[index].nextLink
        repeat {
          try Task.checkCancellation()
          guard shouldContinueHistoricalBackfill() else { break backfill }
          let page = try await client.loadMetadataPage(
            folder: state.folders[index].folder,
            continuationURL: continuation,
            pageSize: Self.initialPageSize,
            accessToken: accessToken
          )
          try Task.checkCancellation()
          state.folders[index].nextLink = page.nextLink
          state.folders[index].deltaLink = page.deltaLink
          let folderId = state.folders[index].folder.id
          if state.seededMessageIdsByFolderId?[folderId] != nil {
            var observedByFolder = state.initialCrawlMessageIdsByFolderId ?? [:]
            observedByFolder[folderId, default: []].formUnion(
              page.messages.compactMap { message in
                !message.removed && message.parentFolderId == folderId ? message.id : nil
              }
            )
            state.initialCrawlMessageIdsByFolderId = observedByFolder
          }
          var removingMessageIds: Set<String> = []
          if page.deltaLink != nil,
            let seededMessageIds = state.seededMessageIdsByFolderId?[folderId]
          {
            removingMessageIds =
              seededMessageIds.subtracting(
                state.initialCrawlMessageIdsByFolderId?[folderId] ?? []
              )
            state.seededMessageIdsByFolderId?[folderId] = nil
            state.initialCrawlMessageIdsByFolderId?[folderId] = nil
          }
          try store.savePage(
            page.messages,
            folderId: folderId,
            state: state,
            productAccountId: productAccountId,
            connectionId: connection.id,
            removingMessageIds: removingMessageIds
          )
          continuation = page.nextLink
        } while continuation != nil
      }
    } catch MicrosoftGraphClientError.deltaTokenExpired {
      try Task.checkCancellation()
      try store.clear(productAccountId: productAccountId, connectionId: connection.id)
      return try await sync(
        connection: connection,
        productAccountId: productAccountId,
        accessToken: accessToken
      )
    }
    return try load(connection: connection, productAccountId: productAccountId)
  }

  func overrideCategory(
    _ categoryId: String,
    message: MailboxMessageMetadata,
    connection: MailboxConnection,
    productAccountId: String
  ) throws -> MailboxMessageMetadata {
    let providerMessage = try store.updateCategory(
      categoryId,
      messageId: message.providerMessageId,
      productAccountId: productAccountId,
      connectionId: connection.id
    )
    let state = try store.loadState(
      productAccountId: productAccountId,
      connectionId: connection.id
    )
    let folders = state?.folders.map(\.folder) ?? []
    let foldersById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    guard
      let metadata = providerMessage.mailboxMetadata(
        connectionId: connection.id,
        connectedAt: connection.connectedAt,
        foldersById: foldersById
      )
    else { throw MicrosoftGraphClientError.invalidProviderResponse }
    return metadata
  }

  // swiftlint:disable:next function_body_length
  private func start(
    folders: [MicrosoftGraphFolder],
    connection: MailboxConnection,
    productAccountId: String,
    accessToken: String,
    cursorExpired: Bool,
    shouldReplaceStoredMetadata: Bool = false,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    var state = MicrosoftGraphMetadataSyncState(
      folders: folders.map {
        MicrosoftGraphFolderSyncState(folder: $0, deltaLink: nil, nextLink: nil)
      },
      hasInitialMailboxAvailability: false
    )
    try await syncRecentInboxDelta(
      state: &state,
      connection: connection,
      productAccountId: productAccountId,
      accessToken: accessToken,
      shouldPersist: shouldPersist,
      persistPages: false
    )
    var shouldReplaceStoredMetadata = shouldReplaceStoredMetadata
    for index in state.folders.indices {
      var continuation: URL?
      var messages: [MicrosoftGraphProviderMessage] = []
      if state.folders[index].folder.role == .sent {
        let recentPage = try await client.loadRecentMetadataPage(
          folder: state.folders[index].folder,
          pageSize: Self.initialPageSize,
          accessToken: accessToken
        )
        messages = recentPage.messages
        var seededByFolder = state.seededMessageIdsByFolderId ?? [:]
        seededByFolder[state.folders[index].folder.id] = Set(messages.map(\.id))
        state.seededMessageIdsByFolderId = seededByFolder
      } else {
        repeat {
          let page = try await client.loadMetadataPage(
            folder: state.folders[index].folder,
            continuationURL: continuation,
            pageSize: Self.initialPageSize - messages.count,
            accessToken: accessToken
          )
          try Task.checkCancellation()
          guard shouldPersist() else { throw CancellationError() }
          messages.append(contentsOf: page.messages)
          state.folders[index].nextLink = page.nextLink
          state.folders[index].deltaLink = page.deltaLink
          continuation = page.nextLink
        } while messages.count < Self.initialPageSize && continuation != nil
      }
      try Task.checkCancellation()
      guard shouldPersist() else { throw CancellationError() }
      if shouldReplaceStoredMetadata {
        try store.replacePage(
          messages,
          folderId: state.folders[index].folder.id,
          state: state,
          productAccountId: productAccountId,
          connectionId: connection.id
        )
        shouldReplaceStoredMetadata = false
      } else {
        try store.savePage(
          messages,
          folderId: state.folders[index].folder.id,
          state: state,
          productAccountId: productAccountId,
          connectionId: connection.id
        )
      }
    }
    if !state.historicalMetadataBackfillIsComplete {
      try await syncRecentInboxDelta(
        state: &state,
        connection: connection,
        productAccountId: productAccountId,
        accessToken: accessToken,
        shouldPersist: shouldPersist,
        startIfNeeded: false
      )
    }
    state.hasInitialMailboxAvailability = true
    try store.savePage(
      [],
      folderId: state.folders[0].folder.id,
      state: state,
      productAccountId: productAccountId,
      connectionId: connection.id
    )
    return try load(
      connection: connection,
      productAccountId: productAccountId,
      providerCursorIsExpired: cursorExpired
    )
    .limitedInitialPage(to: Self.initialPageSize)
  }

  private func updatedState(
    _ state: MicrosoftGraphMetadataSyncState,
    folders: [MicrosoftGraphFolder],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphMetadataSyncState {
    let updatedState = MicrosoftGraphMetadataSyncState(
      folders: zip(state.folders, folders).map { cursor, folder in
        MicrosoftGraphFolderSyncState(
          folder: folder,
          deltaLink: cursor.deltaLink,
          nextLink: cursor.nextLink
        )
      },
      hasInitialMailboxAvailability: state.hasInitialMailboxAvailability,
      initialCrawlMessageIdsByFolderId: state.initialCrawlMessageIdsByFolderId,
      metadataContractVersion: state.metadataContractVersion,
      recentInboxDeltaLink: state.recentInboxDeltaLink,
      recentInboxNextLink: state.recentInboxNextLink,
      seededMessageIdsByFolderId: state.seededMessageIdsByFolderId
    )
    try store.savePage(
      [],
      folderId: updatedState.folders[0].folder.id,
      state: updatedState,
      productAccountId: productAccountId,
      connectionId: connectionId
    )
    return updatedState
  }

  private func syncRecentInboxDelta(
    state: inout MicrosoftGraphMetadataSyncState,
    connection: MailboxConnection,
    productAccountId: String,
    accessToken: String,
    shouldPersist: () -> Bool,
    startIfNeeded: Bool = true,
    persistPages: Bool = true
  ) async throws {
    guard
      let inboxIndex = state.folders.firstIndex(where: { $0.folder.role == .inbox }),
      state.folders[inboxIndex].deltaLink == nil
    else { return }
    var continuation = state.recentInboxNextLink ?? state.recentInboxDeltaLink
    guard continuation != nil || startIfNeeded else { return }
    repeat {
      try Task.checkCancellation()
      let page: MicrosoftGraphMetadataPage
      if let continuation {
        page = try await client.loadMetadataPage(
          folder: state.folders[inboxIndex].folder,
          continuationURL: continuation,
          pageSize: Self.initialPageSize,
          accessToken: accessToken
        )
      } else {
        page = try await client.loadRecentDeltaMetadataPage(
          folder: state.folders[inboxIndex].folder,
          receivedAfterMilliseconds: connection.connectedAt,
          pageSize: Self.initialPageSize,
          accessToken: accessToken
        )
      }
      guard shouldPersist() else { throw CancellationError() }
      state.recentInboxNextLink = page.nextLink
      state.recentInboxDeltaLink = page.deltaLink ?? state.recentInboxDeltaLink
      if persistPages {
        try store.savePage(
          page.messages,
          folderId: state.folders[inboxIndex].folder.id,
          state: state,
          productAccountId: productAccountId,
          connectionId: connection.id
        )
      }
      continuation = page.nextLink
    } while continuation != nil
  }

  private func refreshedState(
    _ state: MicrosoftGraphMetadataSyncState?,
    folders: [MicrosoftGraphFolder],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphMetadataSyncState? {
    guard let state else { return nil }
    guard
      state.metadataContractVersion
        == MicrosoftGraphMetadataSyncState.currentMetadataContractVersion
    else {
      return nil
    }
    guard state.folders.map(\.folder.id) == folders.map(\.id) else {
      return nil
    }
    return try updatedState(
      state,
      folders: folders,
      productAccountId: productAccountId,
      connectionId: connectionId
    )
  }

  private static func foldersAreOrdered(
    _ lhs: MicrosoftGraphFolder,
    _ rhs: MicrosoftGraphFolder
  ) -> Bool {
    MicrosoftGraphFolder.areOrdered(lhs, rhs)
  }

  private static func messagesAreOrdered(
    _ lhs: MailboxMessageMetadata,
    _ rhs: MailboxMessageMetadata
  ) -> Bool {
    if lhs.providerInternalDateMilliseconds == rhs.providerInternalDateMilliseconds {
      return lhs.providerMessageId < rhs.providerMessageId
    }
    return lhs.providerInternalDateMilliseconds > rhs.providerInternalDateMilliseconds
  }
}

private struct MicrosoftGraphMessageBodyCachePayload: Codable {
  private static let header = Data("unwired-microsoft-graph-body-cache-v1\n".utf8)

  struct DecodedValue {
    let body: MailboxMessageBody
    let didResolveAttachments: Bool
    let isLegacy: Bool
  }

  let attachments: [MailboxMessageAttachment]?
  let text: String

  static func encode(
    text: String,
    attachments: [MailboxMessageAttachment]?
  ) throws -> Data {
    var data = header
    data.append(try JSONEncoder().encode(Self(attachments: attachments, text: text)))
    return data
  }

  static func decode(_ data: Data) throws -> DecodedValue {
    guard data.starts(with: header) else {
      guard let text = String(data: data, encoding: .utf8) else {
        throw MicrosoftGraphClientError.missingMessageBody
      }
      return DecodedValue(
        body: MailboxMessageBody(text: text),
        didResolveAttachments: false,
        isLegacy: true
      )
    }
    let payload = try JSONDecoder().decode(
      Self.self,
      from: Data(data.dropFirst(header.count))
    )
    return DecodedValue(
      body: MailboxMessageBody(text: payload.text, attachments: payload.attachments ?? []),
      didResolveAttachments: payload.attachments != nil,
      isLegacy: false
    )
  }
}

struct MicrosoftGraphMessageBodyService {
  private let cache: GmailMessageBodyCaching
  private let client: MicrosoftGraphClient
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting

  init(
    cache: GmailMessageBodyCaching,
    client: MicrosoftGraphClient,
    keyMaterialStore: ProductSyncKeyMaterialPersisting
  ) {
    self.cache = cache
    self.client = client
    self.keyMaterialStore = keyMaterialStore
  }

  func clear(session: ProductAccountSessionSnapshot) throws {
    try cache.clearMessageBodies(productAccountId: session.productAccountId)
  }

  func clear(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.clearMessageBodies(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
  }

  func loadCached(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws -> MailboxMessageBody? {
    guard let cached = try loadCachedValue(message: message, session: session) else { return nil }
    guard cached.didResolveAttachments || (cached.isLegacy && !message.hasAttachments) else {
      return nil
    }
    return cached.body
  }

  func load(
    message: MailboxMessageMetadata,
    accessToken: String,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    if let cached = try loadCached(message: message, session: session) {
      try? cache.recordMessageBodyAccess(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId,
        accessedAt: Date()
      )
      return cached
    }
    let fallback = try loadCachedValue(message: message, session: session)?.body
    let text: String
    do {
      text = try await client.loadTextBody(
        messageId: message.providerMessageId,
        accessToken: accessToken
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if let fallback { return fallback }
      throw error
    }
    let attachments: [MailboxMessageAttachment]?
    if message.hasAttachments {
      attachments = try await loadAttachments(
        messageId: message.providerMessageId,
        accessToken: accessToken
      )
    } else {
      attachments = []
    }
    let material = try requiredMaterial(productAccountId: session.productAccountId)
    try? cache.saveMessageBody(
      material.encryptPayload(
        try MicrosoftGraphMessageBodyCachePayload.encode(
          text: text,
          attachments: attachments
        ),
        associatedData: associatedData(message.stableProviderMessageId)
      ),
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
    return MailboxMessageBody(text: text, attachments: attachments ?? [])
  }

  func recordAccess(message: MailboxMessageMetadata, session: ProductAccountSessionSnapshot) {
    try? cache.recordMessageBodyAccess(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId,
      accessedAt: Date()
    )
  }

  func loadAttachment(
    _ attachment: MailboxMessageAttachment,
    message: MailboxMessageMetadata,
    accessToken: String
  ) async throws -> Data {
    try await client.loadAttachmentData(
      messageId: message.providerMessageId,
      attachmentId: attachment.id,
      expectedByteCount: attachment.byteCount,
      maximumByteCount: MailboxMessageAttachmentPolicy.maximumByteCount,
      accessToken: accessToken
    )
  }

  func prefetch(
    messages: [MailboxMessageMetadata],
    connectionId: MailboxConnectionId,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    accessToken: String,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let protectedMessageIds = Set(messages.map(\.stableProviderMessageId))
    try cache.reconcileSelection(
      productAccountId: session.productAccountId,
      connectionId: connectionId,
      protectedMessageIds: protectedMessageIds,
      pinnedMessageIds: Set(pinnedMessageIds.map(\.rawValue))
    )
    let material = try requiredMaterial(productAccountId: session.productAccountId)
    for message in messages where try loadCached(message: message, session: session) == nil {
      try Task.checkCancellation()
      let text: String
      do {
        text = try await client.loadTextBody(
          messageId: message.providerMessageId,
          accessToken: accessToken
        )
      } catch MicrosoftGraphClientError.requestFailed(404) {
        continue
      }
      let attachments: [MailboxMessageAttachment]?
      if message.hasAttachments {
        attachments = try await loadAttachments(
          messageId: message.providerMessageId,
          accessToken: accessToken
        )
      } else {
        attachments = []
      }
      _ = try cache.saveMessageBody(
        GmailMessageBodyCacheWrite(
          cachedAt: Date(
            timeIntervalSince1970: TimeInterval(message.providerInternalDateMilliseconds) / 1_000
          ),
          isPinned: pinnedMessageIds.contains(message.id),
          isProtected: true,
          payload: material.encryptPayload(
            try MicrosoftGraphMessageBodyCachePayload.encode(
              text: text,
              attachments: attachments
            ),
            associatedData: associatedData(message.stableProviderMessageId)
          ),
          retention: .prefetched
        ),
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    }
  }

  func remove(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
  }

  private func requiredMaterial(productAccountId: String) throws -> ProductSyncKeyMaterial {
    guard let material = try keyMaterialStore.load(productAccountId: productAccountId) else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }
    return material
  }

  private func associatedData(_ stableProviderMessageId: String) -> Data {
    Data("microsoft-graph-body-cache:\(stableProviderMessageId)".utf8)
  }

  private func loadAttachments(
    messageId: String,
    accessToken: String
  ) async throws -> [MailboxMessageAttachment]? {
    do {
      return try await client.loadAttachmentDescriptors(
        messageId: messageId,
        accessToken: accessToken
      ).compactMap(\.mailboxAttachment)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch MicrosoftGraphClientError.requestFailed(401) {
      throw MicrosoftGraphClientError.requestFailed(401)
    } catch {
      return nil
    }
  }

  private func loadCachedValue(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws -> MicrosoftGraphMessageBodyCachePayload.DecodedValue? {
    guard
      let payload = try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    else { return nil }
    let material = try requiredMaterial(productAccountId: session.productAccountId)
    do {
      return try MicrosoftGraphMessageBodyCachePayload.decode(
        material.decryptPayload(
          payload,
          associatedData: associatedData(message.stableProviderMessageId)
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      return nil
    }
  }
}

protocol MicrosoftGraphPushRegistering {
  func registerOrRenew(
    connection: MailboxConnection,
    accessToken: String,
    session: ProductAccountSessionSnapshot
  ) async throws

  func clear(
    accessToken: String?,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws

  func clearAll(
    accessTokensByProviderAccountIdentifier: [String: String],
    session: ProductAccountSessionSnapshot
  ) async throws
}

struct MicrosoftGraphMailboxConnectionAdapter: MailboxConnectionAdapter {
  private let assignmentSync: MessageCategoryAssignmentSyncing
  private let attachmentStore: DownloadedAttachmentStore
  private let authorizer: MicrosoftGraphAuthorizing
  private let bodyService: MicrosoftGraphMessageBodyService
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let metadataService: MicrosoftGraphMetadataService
  private let metadataStore: MicrosoftGraphMetadataPersisting
  private let now: () -> Date
  private let outboxService: OutboxDeliveryService
  private let pendingActionService: PendingProviderActionService
  private let pushRegistrar: MicrosoftGraphPushRegistering
  private let syncGate: MailboxConnectionSyncGate
  private let tokenStore: MicrosoftGraphAuthorizationPersisting

  init(
    assignmentSync: MessageCategoryAssignmentSyncing = MessageCategoryAssignmentSyncService(),
    attachmentStore: DownloadedAttachmentStore = DownloadedAttachmentStore(),
    authorizer: MicrosoftGraphAuthorizing = MicrosoftGraphOAuthService(),
    bodyCache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: MicrosoftGraphClient = URLSessionMicrosoftGraphClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing = MailboxConnectionSyncService(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    metadataStore: MicrosoftGraphMetadataPersisting =
      SwiftDataMicrosoftGraphMetadataStore(),
    now: @escaping () -> Date = Date.init,
    outboxService: OutboxDeliveryService = .shared,
    pendingActionService: PendingProviderActionService = .shared,
    pushRegistrar: MicrosoftGraphPushRegistering = MicrosoftGraphPushSubscriptionService(),
    shouldContinueHistoricalBackfill: @escaping () -> Bool = {
      !ProcessInfo.processInfo.isLowPowerModeEnabled
    },
    syncGate: MailboxConnectionSyncGate = .shared,
    tokenStore: MicrosoftGraphAuthorizationPersisting =
      KeychainMicrosoftGraphAuthorizationStore()
  ) {
    self.assignmentSync = assignmentSync
    self.attachmentStore = attachmentStore
    self.authorizer = authorizer
    self.bodyService = MicrosoftGraphMessageBodyService(
      cache: bodyCache,
      client: client,
      keyMaterialStore: keyMaterialStore
    )
    self.definitionSyncService = definitionSyncService
    self.metadataService = MicrosoftGraphMetadataService(
      client: client,
      shouldContinueHistoricalBackfill: shouldContinueHistoricalBackfill,
      store: metadataStore
    )
    self.metadataStore = metadataStore
    self.now = now
    self.outboxService = outboxService
    self.pendingActionService = pendingActionService
    self.pushRegistrar = pushRegistrar
    self.syncGate = syncGate
    self.tokenStore = tokenStore
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      var firstError: Error?
      var accessTokensByProviderAccountIdentifier: [String: String] = [:]
      for providerAccountIdentifier in try tokenStore.providerAccountIdentifiers(
        productAccountId: session.productAccountId)
      {
        do {
          accessTokensByProviderAccountIdentifier[providerAccountIdentifier] =
            try await accessTokenForCleanup(
              productAccountId: session.productAccountId,
              providerAccountIdentifier: providerAccountIdentifier
            )
        } catch {
          firstError = firstError ?? error
        }
      }
      do {
        try await pushRegistrar.clearAll(
          accessTokensByProviderAccountIdentifier: accessTokensByProviderAccountIdentifier,
          session: session
        )
      } catch {
        firstError = firstError ?? error
      }
      do {
        try tokenStore.clearAll(productAccountId: session.productAccountId)
      } catch {
        firstError = firstError ?? error
      }
      do {
        try metadataStore.clear(productAccountId: session.productAccountId)
      } catch {
        firstError = firstError ?? error
      }
      do {
        try bodyService.clear(session: session)
      } catch {
        firstError = firstError ?? error
      }
      do {
        try await pendingActionService.clear(session: session)
      } catch {
        firstError = firstError ?? error
      }
      if let firstError { throw firstError }
    }
  }

  func rebuildLocalIndexes(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      try metadataStore.clear(productAccountId: session.productAccountId)
    }
  }

  func clearLocalMailboxData(session: ProductAccountSessionSnapshot) async throws {
    try await syncGate.withAllConnectionsLocked {
      var firstError: Error?
      do {
        try metadataStore.clear(productAccountId: session.productAccountId)
      } catch {
        firstError = error
      }
      do {
        try bodyService.clear(session: session)
      } catch {
        firstError = firstError ?? error
      }
      if let firstError { throw firstError }
    }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await clearLocalConnection(
      connection,
      session: session,
      reportsPushFailure: true
    )
  }

  private func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    reportsPushFailure: Bool,
    revalidatesLocalCleanup: Bool = false
  ) async throws {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    try await syncGate.withLock(connection.id) {
      let cleanupSnapshot: MailboxConnectionSyncSnapshot?
      if revalidatesLocalCleanup {
        cleanupSnapshot = try await localCleanupSnapshotIfRequired(
          connection.id,
          session: session
        )
        guard cleanupSnapshot != nil else { return }
      } else {
        cleanupSnapshot = nil
      }
      try await performLocalCleanupWithinLock(
        connection,
        session: session,
        reportsPushFailure: reportsPushFailure
      )
      if let cleanupSnapshot {
        try definitionSyncService.recordLocalCleanup(
          in: cleanupSnapshot,
          connectionId: connection.id,
          session: session
        )
      }
    }
  }

  private func localCleanupSnapshotIfRequired(
    _ connectionId: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionSyncSnapshot? {
    let currentSnapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
      session: session
    )
    let authorizationGeneration =
      try? tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connectionId.providerMailboxIdentity.value
      )?.authorizationGeneration
    return try definitionSyncService.requiresLocalCleanup(
      in: currentSnapshot,
      connectionId: connectionId,
      localAuthorizationGeneration: authorizationGeneration,
      session: session
    ) ? currentSnapshot : nil
  }

  // swiftlint:disable:next function_body_length
  private func performLocalCleanupWithinLock(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    reportsPushFailure: Bool
  ) async throws {
    var firstError: Error?
    let accessToken: String?
    do {
      accessToken = try await accessTokenForCleanup(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
    } catch {
      accessToken = nil
      firstError = error
    }
    do {
      try await pushRegistrar.clear(
        accessToken: accessToken,
        connection: connection,
        session: session
      )
    } catch {
      if reportsPushFailure {
        firstError = firstError ?? error
      }
    }
    var outboxCleanupSucceeded = false
    do {
      try await outboxService.clear(connection: connection, session: session)
      outboxCleanupSucceeded = true
    } catch let error as OutboxProviderDraftCleanupExhaustedError {
      outboxCleanupSucceeded = true
      firstError = firstError ?? error
    } catch {
      firstError = firstError ?? error
    }
    if outboxCleanupSucceeded {
      do {
        try clearLocalConnectionWithoutLock(connection, session: session)
      } catch {
        firstError = firstError ?? error
      }
    }
    do {
      try await pendingActionService.clear(connection: connection, session: session)
    } catch {
      firstError = firstError ?? error
    }
    do {
      try attachmentStore.clear(connectionId: connection.id)
    } catch {
      firstError = firstError ?? error
    }
    if let firstError {
      throw firstError
    }
  }

  private func clearLocalConnectionWithoutLock(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    var firstError: Error?
    do {
      try tokenStore.clear(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
    } catch {
      firstError = error
    }
    do {
      try metadataStore.clear(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    } catch {
      firstError = firstError ?? error
    }
    do {
      try bodyService.clear(connection: connection, session: session)
    } catch {
      firstError = firstError ?? error
    }
    if let firstError { throw firstError }
  }

  @MainActor
  // swiftlint:disable:next function_body_length
  func connect(
    expectedConnectionId: MailboxConnectionId?,
    removalObservation: MailboxConnectionRemovalObservation?,
    session: ProductAccountSessionSnapshot,
    isSessionCurrent: @escaping (ProductAccountSessionSnapshot) -> Bool
  ) async throws -> MailboxConnection? {
    let tokens = try await authorizer.authorize(selectingAccount: expectedConnectionId == nil)
    let client = metadataService.clientForAccountVerification
    let account = try await client.verifyAccount(accessToken: tokens.accessToken)
    try Task.checkCancellation()
    guard isSessionCurrent(session) else { return nil }
    let connectionId = MailboxConnectionId(
      providerMailboxIdentity: StableProviderMailboxIdentity(
        providerId: .microsoftGraph,
        value: account.id
      )
    )
    if let expectedConnectionId, expectedConnectionId != connectionId {
      throw MailboxConnectionAdapterError.unexpectedAuthorizedAccount
    }
    let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    let previousDefinition = snapshot.connections.first { definition in
      definition.provider == MailProviderId.microsoftGraph.rawValue
        && definition.providerAccountIdentifier == account.id
    }
    let connection = MailboxConnection(
      authorizationGeneration: previousDefinition?.authorizationGeneration ?? 0,
      authorizationState: .authorized,
      capabilities: .microsoftGraph,
      connectedAt: previousDefinition?.connectedAt ?? timestamp,
      displayName: account.emailAddress,
      id: connectionId,
      lastVerifiedAt: timestamp,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: timestamp
    )
    return try await syncGate.withLock(connection.id) {
      guard isSessionCurrent(session) else { throw CancellationError() }
      let currentSnapshot = try await definitionSyncService.loadSnapshotForProviderAccess(
        session: session
      )
      var localGeneration = try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: account.id
      )?.authorizationGeneration
      if try definitionSyncService.requiresLocalCleanup(
        in: currentSnapshot,
        connectionId: connection.id,
        localAuthorizationGeneration: localGeneration,
        session: session
      ) {
        try await performLocalCleanupWithinLock(
          connection,
          session: session,
          reportsPushFailure: false
        )
        try definitionSyncService.recordLocalCleanup(
          in: currentSnapshot,
          connectionId: connection.id,
          session: session
        )
        localGeneration = nil
      }
      let savedSnapshot: MailboxConnectionSyncSnapshot
      do {
        savedSnapshot =
          if expectedConnectionId == nil {
            try await definitionSyncService.recreateDefinition(
              connection.definition,
              after: removalObservation,
              session: session
            )
          } else {
            try await definitionSyncService.saveConnection(connection, session: session)
          }
      } catch let error as MailboxConnectionSyncError {
        if case .connectionRemoved = error {
          try? await performLocalCleanupWithinLock(
            connection,
            session: session,
            reportsPushFailure: false
          )
        }
        throw error
      }
      let savedGeneration =
        savedSnapshot.connections.first(where: { $0.id == connection.id })?
        .authorizationGeneration
        ?? connection.authorizationGeneration
      if try definitionSyncService.requiresLocalCleanup(
        in: savedSnapshot,
        connectionId: connection.id,
        localAuthorizationGeneration: localGeneration,
        session: session
      ) {
        try await performLocalCleanupWithinLock(
          connection,
          session: session,
          reportsPushFailure: false
        )
        try definitionSyncService.recordLocalCleanup(
          in: savedSnapshot,
          connectionId: connection.id,
          session: session
        )
      }
      try tokenStore.save(
        tokens.withAuthorizationGeneration(savedGeneration),
        productAccountId: session.productAccountId,
        providerAccountIdentifier: account.id
      )
      return connection.withAuthorizationGeneration(savedGeneration)
    }
  }

  func loadConnection(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection? {
    try await loadConnections(session: session).first
  }

  func loadConnections(
    session: ProductAccountSessionSnapshot
  ) async throws -> [MailboxConnection] {
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    for connectionId in snapshot.connectionIdsRequiringLocalCleanup
    where connectionId.providerId == .microsoftGraph {
      let removed = placeholderConnection(
        definition: MailboxConnectionDefinition(
          connectedAt: 0,
          displayName: "",
          provider: connectionId.providerId.rawValue,
          providerAccountIdentifier: connectionId.providerMailboxIdentity.value,
          stableProviderConnectionKey: ""
        ),
        session: session,
        authorized: true,
        updatedAt: snapshot.updatedAt
      )
      try await clearLocalConnection(
        removed,
        session: session,
        reportsPushFailure: false,
        revalidatesLocalCleanup: true
      )
    }
    return try snapshot.connections.compactMap { definition in
      guard definition.provider == MailProviderId.microsoftGraph.rawValue else { return nil }
      let authorized =
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: definition.providerAccountIdentifier
        ).map {
          $0.hasFullMailAccess
            && $0.authorizationGeneration == definition.authorizationGeneration
        } == true
      return placeholderConnection(
        definition: definition,
        session: session,
        authorized: authorized,
        updatedAt: snapshot.updatedAt
      )
    }
  }

  func loadDefaultSendingConnectionId(
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnectionId? {
    try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
      .defaultSendingConnectionId
  }

  func removeMailboxConnectionEverywhere(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    var firstError: Error?
    do {
      try await clearLocalConnection(connection, session: session)
    } catch {
      firstError = error
    }
    do {
      _ = try await definitionSyncService.removeConnection(connection.id, session: session)
    } catch {
      firstError = firstError ?? error
    }
    if let firstError { throw firstError }
  }

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    if let connection {
      try validate(connection: connection, session: session, requiresAuthorization: true)
    }
    _ = try await definitionSyncService.setDefaultSendingConnection(
      connection?.id,
      session: session
    )
  }

  func categorizeHistorical(
    scope _: HistoricalCategorizationScope,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func loadInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let cached = try await syncGate.withLock(connection.id) {
      let active = try await activeConnectionWithinSyncGate(id: connection.id, session: session)
      return try metadataService.load(
        connection: active,
        productAccountId: session.productAccountId
      )
    }
    let categorized = try await applyingSyncedCategories(
      to: cached,
      session: session
    )
    return try await pendingActionService.project(
      categorized,
      connection: connection,
      session: session
    )
    .limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let cached = try await syncGate.withLock(connection.id) {
      let active = try await activeConnectionWithinSyncGate(id: connection.id, session: session)
      return try metadataService.load(
        connection: active,
        productAccountId: session.productAccountId
      )
    }
    let categorized = try await applyingSyncedCategories(
      to: cached,
      session: session
    )
    let result = try await pendingActionService.project(
      categorized,
      collection: collection,
      connection: connection,
      session: session
    )
    return collection == .allObserved
      ? result : result.limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    let state = try await syncGate.withLock(connection.id) {
      _ = try await activeConnectionWithinSyncGate(id: connection.id, session: session)
      return try metadataStore.loadState(
        productAccountId: session.productAccountId,
        connectionId: connection.id
      )
    }
    return (state?.folders ?? []).compactMap { cursor in
      guard cursor.folder.role == nil else { return nil }
      return ProviderMailbox(
        id: MicrosoftGraphProviderMessage.customFolderStateId(cursor.folder.id),
        title: cursor.folder.displayName
      )
    }
  }

  func continueHistoricalBackfill(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let result = try await syncGate.withLock(connection.id) {
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await metadataService.continueBackfill(
          connection: connection,
          productAccountId: session.productAccountId,
          accessToken: token
        )
      }
    }
    return try await applyingSyncedCategories(to: result, session: session)
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let result = try await syncGate.withLock(connection.id) {
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await metadataService.sync(
          connection: connection,
          productAccountId: session.productAccountId,
          accessToken: token
        )
      }
    }
    let categorized = try await applyingSyncedCategories(to: result, session: session)
    try? await registerOrRenewPush(connection: connection, session: session)
    try await reconcileAndResumePendingActions(
      messages: categorized.messages,
      removesContradictedActions: categorized.historicalMetadataBackfillIsComplete,
      connection: connection,
      session: session
    )
    return try await pendingActionService.project(
      categorized,
      connection: connection,
      session: session
    )
    .limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
  }

  func syncRecentInbox(
    connection: MailboxConnection,
    includingHistoryCandidates _: Bool,
    session: ProductAccountSessionSnapshot,
    sinceHistoryId _: String?,
    throughHistoryId _: String?,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    guard shouldPersist() else { throw CancellationError() }
    let result = try await syncGate.withLock(connection.id) {
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await metadataService.sync(
          connection: connection,
          productAccountId: session.productAccountId,
          accessToken: token,
          shouldPersist: shouldPersist
        )
      }
    }
    let categorized = try await applyingSyncedCategories(to: result, session: session)
    try await reconcileAndResumePendingActions(
      messages: categorized.messages,
      removesContradictedActions: categorized.historicalMetadataBackfillIsComplete,
      connection: connection,
      session: session
    )
    return try await pendingActionService.project(
      categorized,
      connection: connection,
      session: session
    )
    .limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    let connection = try await connection(id: message.connectionId, session: session)
    return try await syncGate.withLock(connection.id) {
      let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
      let assignment = try await assignmentSync.saveUserOverride(
        MessageCategoryAssignment(
          categoryId: categoryId,
          overrideTimestamp: timestamp,
          source: .userOverride,
          stableProviderMessageId: message.stableProviderMessageId
        ),
        session: session
      )
      return try metadataService.overrideCategory(
        assignment.categoryId,
        message: message,
        connection: connection,
        productAccountId: session.productAccountId
      )
    }
  }

  func setCategories(
    _ categoryIds: [String],
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    let categoryId = try singleCategoryIdentifier(categoryIds)
    return try await overrideCategory(categoryId, for: message, session: session)
  }

  func searchProvider(
    query _: String,
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws -> [MailboxMessageMetadata] {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try bodyService.clear(session: session)
  }

  func clearCachedMessageBodies(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    try bodyService.clear(connection: connection, session: session)
  }

  func loadMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageBody {
    guard message.connectionId.providerId == .microsoftGraph else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    return try await syncGate.withLock(message.connectionId) {
      let connection = try await activeConnectionWithinSyncGate(
        id: message.connectionId,
        session: session
      )
      if let cached = try bodyService.loadCached(message: message, session: session) {
        bodyService.recordAccess(message: message, session: session)
        return cached
      }
      return try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await bodyService.load(
          message: message,
          accessToken: token,
          session: session
        )
      }
    }
  }

  func loadMessageAttachment(
    _ attachment: MailboxMessageAttachment,
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> Data {
    guard message.connectionId.providerId == .microsoftGraph else {
      throw MailboxMessageAttachmentError.unsupportedProvider
    }
    guard attachment.byteCount >= 0,
      attachment.byteCount <= MailboxMessageAttachmentPolicy.maximumByteCount
    else { throw MailboxMessageAttachmentError.invalidResponse }
    let connectionAndToken: (connection: MailboxConnection, accessToken: String) =
      try await syncGate.withLock(message.connectionId) {
        let connection = try await activeConnectionWithinSyncGate(
          id: message.connectionId,
          session: session
        )
        let accessToken = try await accessToken(
          connection: connection,
          session: session,
          isWithinSyncGate: true
        )
        return (connection: connection, accessToken: accessToken)
      }
    do {
      return try await bodyService.loadAttachment(
        attachment,
        message: message,
        accessToken: connectionAndToken.accessToken
      )
    } catch let error where isUnauthorized(error) {
      let refreshedToken = try await syncGate.withLock(message.connectionId) {
        let activeConnection = try await activeConnectionWithinSyncGate(
          id: message.connectionId,
          session: session
        )
        guard
          activeConnection.authorizationGeneration
            == connectionAndToken.connection.authorizationGeneration
        else {
          throw MailboxConnectionAdapterError.authorizationRequired
        }
        return try await refreshAccessToken(connection: activeConnection, session: session)
      }
      return try await bodyService.loadAttachment(
        attachment,
        message: message,
        accessToken: refreshedToken
      )
    }
  }

  // swiftlint:disable:next function_body_length
  private func activeConnectionWithinSyncGate(
    id: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection {
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    let tokens = try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: id.providerMailboxIdentity.value
    )
    if snapshot.removedConnectionIds.contains(id) {
      let removed = cleanupPlaceholderConnection(
        id: id,
        session: session,
        updatedAt: snapshot.updatedAt
      )
      try await performLocalCleanupWithinLock(
        removed,
        session: session,
        reportsPushFailure: false
      )
      try definitionSyncService.recordLocalCleanup(
        in: snapshot,
        connectionId: id,
        session: session
      )
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    if try definitionSyncService.requiresLocalCleanup(
      in: snapshot,
      connectionId: id,
      localAuthorizationGeneration: tokens?.authorizationGeneration,
      session: session
    ) {
      let stale = cleanupPlaceholderConnection(
        id: id,
        session: session,
        updatedAt: snapshot.updatedAt
      )
      try await performLocalCleanupWithinLock(
        stale,
        session: session,
        reportsPushFailure: false
      )
      try definitionSyncService.recordLocalCleanup(
        in: snapshot,
        connectionId: id,
        session: session
      )
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    guard
      let definition = snapshot.connections.first(where: { $0.id == id }),
      definition.provider == MailProviderId.microsoftGraph.rawValue
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    guard tokens?.authorizationGeneration == definition.authorizationGeneration else {
      let stale = placeholderConnection(
        definition: definition,
        session: session,
        authorized: true,
        updatedAt: snapshot.updatedAt
      )
      try await performLocalCleanupWithinLock(
        stale,
        session: session,
        reportsPushFailure: false
      )
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    return placeholderConnection(
      definition: definition,
      session: session,
      authorized: true,
      updatedAt: snapshot.updatedAt
    )
  }

  private func cleanupPlaceholderConnection(
    id: MailboxConnectionId,
    session: ProductAccountSessionSnapshot,
    updatedAt: Int64?
  ) -> MailboxConnection {
    placeholderConnection(
      definition: MailboxConnectionDefinition(
        connectedAt: 0,
        displayName: "",
        provider: id.providerId.rawValue,
        providerAccountIdentifier: id.providerMailboxIdentity.value,
        stableProviderConnectionKey: ""
      ),
      session: session,
      authorized: true,
      updatedAt: updatedAt
    )
  }

  private func applyingSyncedCategories(
    to result: MailboxMetadataSyncResult,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    let observedMessages = Dictionary(
      (result.messages + result.threads.flatMap(\.messages)).map {
        ($0.stableProviderMessageId, $0)
      },
      uniquingKeysWith: { first, _ in first }
    ).values
    let assignments = try await assignmentSync.loadAssignments(
      stableProviderMessageIds: observedMessages.map(\.stableProviderMessageId),
      session: session
    )
    let applyAssignment: (MailboxMessageMetadata) -> MailboxMessageMetadata = { message in
      guard
        let assignment = assignments[message.stableProviderMessageId],
        message.categoryId == nil || assignment.source == .userOverride
      else { return message }
      return message.assigningCategory(assignment.categoryId)
    }
    let messages = result.messages.map(applyAssignment)
    return MailboxMetadataSyncResult(
      hasUnlistedNewMessages: result.hasUnlistedNewMessages,
      messages: messages,
      newMessageIds: result.newMessageIds,
      providerCursorIsExpired: result.providerCursorIsExpired,
      threads: MailboxThread.group(result.threads.flatMap(\.messages).map(applyAssignment)),
      hasInitialMailboxAvailability: result.hasInitialMailboxAvailability,
      historicalMetadataBackfillIsComplete: result.historicalMetadataBackfillIsComplete
    )
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedThreadIds: Set<StableThreadIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let observed = try await loadMailbox(.allObserved, connection: connection, session: session)
    let recentCutoff = referenceDate.addingTimeInterval(-30 * 24 * 60 * 60)
    let allowed = observed.messages.filter { message in
      let states = Set(message.providerStateIds ?? [])
      return states.isDisjoint(with: ["DRAFT", "SPAM", "TRASH"])
    }
    let pinnedMessageIds = Set(
      allowed.filter { pinnedThreadIds.contains($0.threadIdentity) }.map(\.id)
    )
    let pinned = allowed.filter { pinnedMessageIds.contains($0.id) }
    let recent = allowed.filter { message in
      message.providerInternalDateMilliseconds
        >= Int64(recentCutoff.timeIntervalSince1970 * 1_000)
        && message.providerInternalDateMilliseconds
          <= Int64(referenceDate.timeIntervalSince1970 * 1_000)
        && (message.providerStateIds ?? []).contains(where: { $0 == "INBOX" || $0 == "SENT" })
    }
    let recentMessages = Array(recent.prefix(500))
    let recentIds = Set(recentMessages.map(\.id))
    let selected = pinned.filter { !recentIds.contains($0.id) } + recentMessages
    try await syncGate.withLock(connection.id) {
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await bodyService.prefetch(
          messages: selected,
          connectionId: connection.id,
          pinnedMessageIds: pinnedMessageIds,
          accessToken: token,
          session: session
        )
      }
    }
  }

  func removeCachedMessageBody(
    message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    guard message.connectionId.providerId == .microsoftGraph else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    try bodyService.remove(message: message, session: session)
  }

  func registerOrRenewPush(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await pushRegistrar.registerOrRenew(
          connection: connection,
          accessToken: token,
          session: session
        )
      }
    }
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await perform(
      action,
      targetProviderMailboxId: nil,
      messages: messages,
      connection: connection,
      session: session
    )
  }

  func perform(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let selection = try await performTracked(
      action,
      sourceProviderMailboxId: nil,
      targetProviderMailboxId: targetProviderMailboxId,
      targetProviderStateIds: [],
      messages: messages,
      connection: connection,
      session: session
    )
    if let selection {
      await pendingActionService.releaseSelection(selection)
    }
  }

  // swiftlint:disable:next function_parameter_count
  func performTracked(
    _ action: ProviderMailAction,
    sourceProviderMailboxId _: String?,
    targetProviderMailboxId: String?,
    targetProviderStateIds _: Set<String>,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxProviderActionSelection? {
    try await syncGate.withLock(connection.id) {
      _ = try await accessToken(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      )
      guard connection.capabilities.supports(action) else {
        throw MailboxConnectionAdapterError.unsupportedCapability
      }
      return try await pendingActionService.enqueue(
        action,
        targetProviderMailboxId: targetProviderMailboxId,
        messages: messages,
        connection: connection,
        session: session
      )
    }
  }

  func releasePendingActionSelection(
    _ selection: MailboxProviderActionSelection,
    connection _: MailboxConnection
  ) async {
    await pendingActionService.releaseSelection(selection)
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connections: connections,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func resumePendingActions(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    await withTaskGroup(of: (Int, String?).self, returning: String?.self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          let error = await resumePendingActions(
            connection: connection,
            session: session,
            revalidateProviderAccess: revalidateProviderAccess
          )
          return (index, error.map { "\(connection.displayName): \($0)" })
        }
      }
      var errors: [(Int, String)] = []
      for await (index, error) in group {
        if let error { errors.append((index, error)) }
      }
      let descriptions = errors.sorted { $0.0 < $1.0 }.map(\.1)
      return descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
    }
  }

  func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resumePendingActions(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  private func resumePendingActions(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    var description: String?
    do {
      try await pendingActionService.resume(
        connection: connection,
        session: session,
        revalidateProviderAccess: revalidateProviderAccess,
        provider: pendingActionPerformer(connection: connection, session: session)
      )
    } catch is CancellationError {
      return nil
    } catch {
      description = error.localizedDescription
    }
    return
      (try? await pendingActionService.failureDescription(
        connection: connection,
        session: session
      )) ?? description
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await retryBlockedPendingAction(
      connection: connection,
      session: session,
      revalidateProviderAccess: { true }
    )
  }

  func retryBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool
  ) async -> String? {
    await resolveBlockedPendingAction(
      connection: connection,
      session: session,
      discarding: false,
      revalidateProviderAccess: revalidateProviderAccess
    )
  }

  func discardBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await resolveBlockedPendingAction(
      connection: connection,
      session: session,
      discarding: true
    )
  }

  func blockedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var connectionIds: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasBlockedAction(
        connection: connection,
        session: session
      )) == true
    {
      connectionIds.append(connection.id)
    }
    return connectionIds
  }

  func failedPendingActionConnectionIds(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxConnectionId] {
    var connectionIds: [MailboxConnectionId] = []
    for connection in connections
    where
      (try? await pendingActionService.hasFailedAction(
        connection: connection,
        session: session
      )) == true
    {
      connectionIds.append(connection.id)
    }
    return connectionIds
  }

  func pendingActionFailureDetails(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> [MailboxProviderActionFailureDetail]? {
    try? await pendingActionService.failureDetails(
      action,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func pendingActionFailureLookup(
    _ action: ProviderMailAction,
    selection: MailboxProviderActionSelection?,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> MailboxProviderActionFailureLookup? {
    try? await pendingActionService.failureLookup(
      action,
      selectedActionIds: selection?.pendingActionIds,
      messageIds: Set(messages.map(\.providerMessageId)),
      connection: connection,
      session: session
    )
  }

  func waitForPendingActionRetries(
    connections: [MailboxConnection],
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await withTaskGroup(of: (Int, String?).self, returning: String?.self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          let error = await waitForPendingActionRetries(
            connection: connection,
            session: session
          )
          return (index, error.map { "\(connection.displayName): \($0)" })
        }
      }
      var errors: [(Int, String)] = []
      for await (index, error) in group {
        if let error { errors.append((index, error)) }
      }
      let descriptions = errors.sorted { $0.0 < $1.0 }.map(\.1)
      return descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
    }
  }

  func waitForPendingActionRetries(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async -> String? {
    await pendingActionService.waitForScheduledRetries(
      connection: connection,
      session: session
    )
    return try? await pendingActionService.failureDescription(
      connection: connection,
      session: session
    )
  }

  func acknowledgePendingActionFailures(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async {
    try? await pendingActionService.acknowledgeFailures(
      connection: connection,
      session: session
    )
  }

  private func resolveBlockedPendingAction(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    discarding: Bool,
    revalidateProviderAccess: @escaping @Sendable () async -> Bool = { true }
  ) async -> String? {
    do {
      let provider = pendingActionPerformer(connection: connection, session: session)
      if discarding {
        try await pendingActionService.discardBlockedAction(
          connection: connection,
          session: session,
          provider: provider
        )
      } else {
        try await pendingActionService.retryBlockedAction(
          connection: connection,
          session: session,
          revalidateProviderAccess: revalidateProviderAccess,
          provider: provider
        )
      }
      return await waitForPendingActionRetries(connection: connection, session: session)
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func pendingActionPerformer(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) -> PendingProviderActionPerformer {
    { action, _, targetProviderMailboxId, messageIds in
      do {
        try await performProviderAction(
          action,
          targetProviderMailboxId: targetProviderMailboxId,
          messageIds: messageIds,
          connection: connection,
          session: session
        )
      } catch let error as URLError {
        if error.code == .cancelled || Task.isCancelled {
          throw CancellationError()
        }
        let actionMayHaveMovedMessage =
          switch action {
          case .archive, .delete, .move, .notSpam, .restore, .spam: true
          case .markRead, .markUnread, .star, .unstar: false
          }
        if actionMayHaveMovedMessage, !Self.isDefinitePreDeliveryNetworkFailure(error) {
          throw GraphAmbiguousActionError()
        }
        throw error
      }
    }
  }

  private static func isDefinitePreDeliveryNetworkFailure(_ error: URLError) -> Bool {
    switch error.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
      .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
      return true
    default:
      return false
    }
  }

  private func performProviderAction(
    _ action: ProviderMailAction,
    targetProviderMailboxId: String?,
    messageIds: [String],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      let destinationFolderId = try destinationFolderId(
        for: action,
        targetProviderMailboxId: targetProviderMailboxId,
        connection: connection,
        session: session
      )
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        for messageId in messageIds {
          switch action {
          case .markRead:
            try await metadataService.clientForAccountVerification.setMessageRead(
              true,
              messageId: messageId,
              accessToken: token
            )
          case .markUnread:
            try await metadataService.clientForAccountVerification.setMessageRead(
              false,
              messageId: messageId,
              accessToken: token
            )
          case .archive, .delete, .move, .notSpam, .restore, .spam:
            guard let destinationFolderId else {
              throw MailboxConnectionAdapterError.providerMailboxTargetRequired
            }
            try await metadataService.clientForAccountVerification.moveMessage(
              messageId: messageId,
              destinationFolderId: destinationFolderId,
              accessToken: token
            )
          case .star, .unstar:
            throw MailboxConnectionAdapterError.unsupportedCapability
          }
        }
      }
    }
  }

  private func destinationFolderId(
    for action: ProviderMailAction,
    targetProviderMailboxId: String?,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) throws -> String? {
    let role: MailboxRole?
    switch action {
    case .archive:
      role = .archive
    case .delete:
      role = .trash
    case .notSpam, .restore:
      role = .inbox
    case .spam:
      role = .spam
    case .move:
      guard let targetProviderMailboxId,
        let folderId = MicrosoftGraphProviderMessage.folderId(
          fromCustomFolderStateId: targetProviderMailboxId
        )
      else { throw MailboxConnectionAdapterError.providerMailboxTargetRequired }
      return folderId
    case .markRead, .markUnread:
      return nil
    case .star, .unstar:
      throw MailboxConnectionAdapterError.unsupportedCapability
    }
    let state = try metadataStore.loadState(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
    guard
      let role,
      let folderId = state?.folders.first(where: { $0.folder.role == role })?.folder.id
    else { throw MailboxConnectionAdapterError.unsupportedCapability }
    return folderId
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await syncGate.withLock(connection.id) {
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await metadataService.clientForAccountVerification.send(message, accessToken: token)
      }
    }
  }

  func deleteOutboxDraft(
    _ providerDraftId: String,
    connectionId: MailboxConnectionId,
    productAccountId: String
  ) async throws {
    guard connectionId.providerId == .microsoftGraph else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    guard
      let accessToken = try await accessTokenForCleanup(
        productAccountId: productAccountId,
        providerAccountIdentifier: connectionId.providerMailboxIdentity.value
      )
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    try await metadataService.clientForAccountVerification.deleteDraft(
      providerDraftId,
      accessToken: accessToken
    )
  }

  func deliveryStatus(
    idempotencyKey: String,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxDeliveryStatus {
    try await syncGate.withLock(connection.id) {
      try await withAccessTokenRetry(
        connection: connection,
        session: session,
        isWithinSyncGate: true
      ) { token in
        try await metadataService.clientForAccountVerification.deliveryStatus(
          rfcMessageId: OutgoingMessage.rfcMessageId(for: idempotencyKey),
          accessToken: token
        )
      }
    }
  }

  private func reconcileAndResumePendingActions(
    messages: [MailboxMessageMetadata],
    removesContradictedActions: Bool,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try await pendingActionService.reconcileProviderSync(
      messages: messages,
      removesContradictedActions: removesContradictedActions,
      connection: connection,
      session: session
    )
    _ = await resumePendingActions(connection: connection, session: session)
  }

  private func accessToken(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    isWithinSyncGate: Bool = false
  ) async throws -> String {
    try validate(connection: connection, session: session, requiresAuthorization: true)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    guard !snapshot.removedConnectionIds.contains(connection.id) else {
      if isWithinSyncGate {
        try clearLocalConnectionWithoutLock(connection, session: session)
      } else {
        try await clearLocalConnection(connection, session: session)
      }
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard
      var tokens = try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    guard
      let definition = snapshot.connections.first(where: { $0.id == connection.id })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    guard
      connection.authorizationGeneration == definition.authorizationGeneration,
      tokens.authorizationGeneration == definition.authorizationGeneration
    else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    let refreshBoundary = Int64(now().addingTimeInterval(60).timeIntervalSince1970 * 1_000)
    if tokens.expiresAtMilliseconds <= refreshBoundary {
      do {
        tokens = try await authorizer.refresh(tokens)
          .withAuthorizationGeneration(definition.authorizationGeneration)
      } catch MicrosoftGraphOAuthError.authorizationRejected {
        try tokenStore.clear(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: connection.providerMailboxIdentity.value
        )
        throw MailboxConnectionAdapterError.authorizationRequired
      }
      try tokenStore.save(
        tokens,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
    }
    return tokens.accessToken
  }

  private func accessTokenForCleanup(
    productAccountId: String,
    providerAccountIdentifier: String
  ) async throws -> String? {
    guard
      var tokens = try tokenStore.load(
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    else { return nil }
    let refreshBoundary = Int64(now().addingTimeInterval(60).timeIntervalSince1970 * 1_000)
    guard tokens.expiresAtMilliseconds <= refreshBoundary else {
      return tokens.accessToken
    }
    do {
      let authorizationGeneration = tokens.authorizationGeneration
      tokens = try await authorizer.refresh(tokens)
        .withAuthorizationGeneration(authorizationGeneration)
    } catch MicrosoftGraphOAuthError.authorizationRejected {
      return nil
    }
    try tokenStore.save(
      tokens,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    return tokens.accessToken
  }

  private func withAccessTokenRetry<T>(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    isWithinSyncGate: Bool,
    operation: (String) async throws -> T
  ) async throws -> T {
    let token = try await accessToken(
      connection: connection,
      session: session,
      isWithinSyncGate: isWithinSyncGate
    )
    do {
      return try await operation(token)
    } catch let error where isUnauthorized(error) {
      return try await operation(
        try await refreshAccessToken(connection: connection, session: session)
      )
    }
  }

  private func isUnauthorized(_ error: Error) -> Bool {
    if case .requestFailed(401) = error as? MicrosoftGraphClientError {
      return true
    }
    guard let sendError = error as? MicrosoftGraphSendError else { return false }
    return isUnauthorized(sendError.underlyingError)
  }

  private func refreshAccessToken(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> String {
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    guard !snapshot.removedConnectionIds.contains(connection.id) else {
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard
      let definition = snapshot.connections.first(where: { $0.id == connection.id })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    guard
      let tokens = try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    guard
      connection.authorizationGeneration == definition.authorizationGeneration,
      tokens.authorizationGeneration == definition.authorizationGeneration
    else {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    let refreshed: MicrosoftGraphTokens
    do {
      refreshed = try await authorizer.refresh(tokens)
        .withAuthorizationGeneration(definition.authorizationGeneration)
    } catch MicrosoftGraphOAuthError.authorizationRejected {
      try tokenStore.clear(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
      throw MailboxConnectionAdapterError.authorizationRequired
    }
    try tokenStore.save(
      refreshed,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: connection.providerMailboxIdentity.value
    )
    return refreshed.accessToken
  }

  private func connection(
    id: MailboxConnectionId,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxConnection {
    guard let connection = try await loadConnections(session: session).first(where: { $0.id == id })
    else { throw MailboxConnectionAdapterError.connectionRemoved }
    return connection
  }

  private func placeholderConnection(
    definition: MailboxConnectionDefinition,
    session: ProductAccountSessionSnapshot,
    authorized: Bool,
    updatedAt: Int64?
  ) -> MailboxConnection {
    let folders =
      try? metadataStore.loadState(
        productAccountId: session.productAccountId,
        connectionId: definition.id
      )?.folders.map(\.folder)
    return MailboxConnection(
      authorizationGeneration: definition.authorizationGeneration,
      authorizationState: authorized ? .authorized : .required,
      capabilities: authorized ? .microsoftGraph(folders: folders ?? []) : .none,
      connectedAt: definition.connectedAt,
      displayName: definition.displayName,
      id: definition.id,
      lastVerifiedAt: authorized ? definition.connectedAt : 0,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: updatedAt ?? definition.connectedAt
    )
  }

  private func validate(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot,
    requiresAuthorization: Bool
  ) throws {
    guard connection.productAccountId == ProductAccountId(session.productAccountId) else {
      throw MailboxConnectionAdapterError.productAccountMismatch
    }
    guard connection.providerId == .microsoftGraph else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    if requiresAuthorization, connection.authorizationState != .authorized {
      throw MailboxConnectionAdapterError.authorizationRequired
    }
  }
}

extension MicrosoftGraphMetadataService {
  fileprivate var clientForAccountVerification: MicrosoftGraphClient {
    client
  }
}

enum MicrosoftGraphOAuthError: LocalizedError, Equatable {
  case authorizationRejected
  case configurationMissing
  case invalidAuthorizationCallback
  case invalidAuthorizationState
  case tokenExchangeFailed(status: Int?)
  case webAuthenticationUnavailable

  var errorDescription: String? {
    switch self {
    case .authorizationRejected:
      return "Microsoft Graph authorization was rejected."
    case .configurationMissing:
      return "Microsoft Graph sign-in is not configured."
    case .invalidAuthorizationCallback:
      return "Microsoft sign-in returned an invalid callback."
    case .invalidAuthorizationState:
      return "Microsoft sign-in could not verify the authorization state."
    case .tokenExchangeFailed:
      return "Microsoft sign-in could not exchange the authorization code."
    case .webAuthenticationUnavailable:
      return "Microsoft sign-in could not open the authentication window."
    }
  }
}

extension MailboxMessageMetadata {
  fileprivate func assigningCategory(_ categoryId: String) -> MailboxMessageMetadata {
    MailboxMessageMetadata(
      categoryId: categoryId,
      connectionId: connectionId,
      from: from,
      isHistorical: isHistorical,
      providerInternalDateMilliseconds: providerInternalDateMilliseconds,
      providerMessageId: providerMessageId,
      providerStateIds: providerStateIds,
      providerThreadId: providerThreadId,
      recipientHeaders: recipientHeaders,
      replyTo: replyTo,
      rfcMessageId: rfcMessageId,
      snippet: snippet,
      subject: subject,
      categoryIds: [categoryId],
      bccRecipients: bccRecipients
    )
  }
}

@MainActor
final class MicrosoftGraphOAuthService: NSObject, MicrosoftGraphAuthorizing {
  nonisolated fileprivate static let scopes =
    "openid profile email offline_access User.Read Mail.ReadWrite Mail.Send"

  private let callbackScheme: String?
  private let clientIdentifier: String?
  nonisolated private let now: @Sendable () -> Date
  nonisolated private let presentationAnchorStore: AuthenticationPresentationAnchorStore
  private let session: URLSession
  private var authenticationContinuation: CheckedContinuation<URL, Error>?
  private var webAuthenticationSession: ASWebAuthenticationSession?

  nonisolated init(
    callbackScheme: String? =
      ProcessInfo.processInfo.environment["MICROSOFT_GRAPH_CALLBACK_SCHEME"]
      ?? DotEnvFile.value(for: "MICROSOFT_GRAPH_CALLBACK_SCHEME")
      ?? Bundle.main.object(forInfoDictionaryKey: "MicrosoftGraphCallbackScheme") as? String,
    clientIdentifier: String? =
      ProcessInfo.processInfo.environment["MICROSOFT_GRAPH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "MICROSOFT_GRAPH_CLIENT_ID")
      ?? Bundle.main.object(forInfoDictionaryKey: "MicrosoftGraphClientId") as? String,
    now: @escaping @Sendable () -> Date = { Date() },
    session: URLSession = .shared,
    presentationAnchorStore: AuthenticationPresentationAnchorStore =
      AuthenticationPresentationAnchorStore()
  ) {
    self.callbackScheme = callbackScheme?.nonEmpty
    self.clientIdentifier = clientIdentifier?.nonEmpty
    self.now = now
    self.presentationAnchorStore = presentationAnchorStore
    self.session = session
  }

  func authorize() async throws -> MicrosoftGraphTokens {
    try await authorize(selectingAccount: false)
  }

  func authorize(selectingAccount: Bool) async throws -> MicrosoftGraphTokens {
    guard let clientIdentifier, let callbackScheme else {
      throw MicrosoftGraphOAuthError.configurationMissing
    }
    let request = MicrosoftGraphOAuthRequest(
      callbackScheme: callbackScheme,
      clientIdentifier: clientIdentifier,
      selectingAccount: selectingAccount
    )
    let callback = try await authenticate(
      authorizationURL: request.authorizationURL,
      callbackScheme: callbackScheme
    )
    let code = try request.authorizationCode(from: callback)
    return try await exchange(
      parameters: [
        "client_id": clientIdentifier,
        "code": code,
        "code_verifier": request.codeVerifier,
        "grant_type": "authorization_code",
        "redirect_uri": request.redirectURI.absoluteString,
        "scope": Self.scopes,
      ]
    )
  }

  func refresh(_ tokens: MicrosoftGraphTokens) async throws -> MicrosoftGraphTokens {
    guard let clientIdentifier else {
      throw MicrosoftGraphOAuthError.configurationMissing
    }
    return try await exchange(
      parameters: [
        "client_id": clientIdentifier,
        "grant_type": "refresh_token",
        "refresh_token": tokens.refreshToken,
        "scope": Self.scopes,
      ],
      fallbackRefreshToken: tokens.refreshToken,
      fallbackScopes: tokens.grantedScopes
    )
  }

  private func exchange(
    parameters: [String: String],
    fallbackRefreshToken: String? = nil,
    fallbackScopes: Set<String>? = nil
  ) async throws -> MicrosoftGraphTokens {
    var request = URLRequest(
      url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
    )
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = parameters.graphFormURLEncodedData()
    let (data, response) = try await session.data(for: request)
    if let rejection = try? JSONDecoder().decode(MicrosoftGraphTokenErrorResponse.self, from: data),
      rejection.code == "invalid_grant"
    {
      throw MicrosoftGraphOAuthError.authorizationRejected
    }
    guard let response = response as? HTTPURLResponse else {
      throw MicrosoftGraphOAuthError.tokenExchangeFailed(status: nil)
    }
    guard
      (200..<300).contains(response.statusCode),
      let payload = try? JSONDecoder().decode(MicrosoftGraphTokenResponse.self, from: data),
      let refreshToken = payload.refreshToken?.nonEmpty ?? fallbackRefreshToken?.nonEmpty
    else { throw MicrosoftGraphOAuthError.tokenExchangeFailed(status: response.statusCode) }
    let requestedScopes = Set(
      Self.scopes.split(whereSeparator: \.isWhitespace).map(String.init)
    )
    return MicrosoftGraphTokens(
      accessToken: payload.accessToken,
      expiresAtMilliseconds: Int64(
        now().addingTimeInterval(TimeInterval(payload.expiresIn)).timeIntervalSince1970 * 1_000
      ),
      grantedScopes: payload.scope.map {
        Set($0.split(whereSeparator: \.isWhitespace).map(String.init))
      } ?? fallbackScopes ?? requestedScopes,
      refreshToken: refreshToken
    )
  }

  private func authenticate(
    authorizationURL: URL,
    callbackScheme: String
  ) async throws -> URL {
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard presentationAnchorStore.captureCurrent() else {
          continuation.resume(throwing: MicrosoftGraphOAuthError.webAuthenticationUnavailable)
          return
        }
        authenticationContinuation = continuation
        let authenticationSession = ASWebAuthenticationSession(
          url: authorizationURL,
          callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
          Task { @MainActor in
            self?.finishAuthentication(callbackURL: callbackURL, error: error)
          }
        }
        authenticationSession.presentationContextProvider = self
        authenticationSession.prefersEphemeralWebBrowserSession = false
        webAuthenticationSession = authenticationSession
        if !authenticationSession.start() {
          finishAuthentication(
            callbackURL: nil,
            error: MicrosoftGraphOAuthError.webAuthenticationUnavailable
          )
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelAuthentication() }
    }
  }

  private func cancelAuthentication() {
    let continuation = authenticationContinuation
    authenticationContinuation = nil
    webAuthenticationSession?.cancel()
    webAuthenticationSession = nil
    presentationAnchorStore.clear()
    continuation?.resume(throwing: CancellationError())
  }

  private func finishAuthentication(callbackURL: URL?, error: Error?) {
    guard let continuation = authenticationContinuation else { return }
    authenticationContinuation = nil
    webAuthenticationSession = nil
    presentationAnchorStore.clear()
    if let authenticationError = error as? ASWebAuthenticationSessionError,
      authenticationError.code == .canceledLogin
    {
      continuation.resume(throwing: CancellationError())
    } else if let error {
      continuation.resume(throwing: error)
    } else if let callbackURL {
      continuation.resume(returning: callbackURL)
    } else {
      continuation.resume(throwing: MicrosoftGraphOAuthError.invalidAuthorizationCallback)
    }
  }
}

extension MicrosoftGraphOAuthService: ASWebAuthenticationPresentationContextProviding {
  nonisolated func presentationAnchor(
    for session: ASWebAuthenticationSession
  ) -> ASPresentationAnchor {
    presentationAnchorStore.current()
  }
}

struct MicrosoftGraphOAuthRequest {
  let authorizationURL: URL
  let codeVerifier: String
  let redirectURI: URL
  private let state: String

  init(callbackScheme: String, clientIdentifier: String, selectingAccount: Bool = false) {
    codeVerifier = Self.randomValue(byteCount: 32)
    state = Self.randomValue(byteCount: 24)
    redirectURI = URL(string: "\(callbackScheme)://auth")!
    let challenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).graphBase64URLString()
    var components = URLComponents(
      string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    )!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientIdentifier),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "response_mode", value: "query"),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: MicrosoftGraphOAuthService.scopes),
      URLQueryItem(name: "state", value: state),
    ]
    if selectingAccount {
      components.queryItems?.append(URLQueryItem(name: "prompt", value: "select_account"))
    }
    authorizationURL = components.url!
  }

  func authorizationCode(from callbackURL: URL) throws -> String {
    guard
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      components.queryItems?.first(where: { $0.name == "state" })?.value == state
    else { throw MicrosoftGraphOAuthError.invalidAuthorizationState }
    guard
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value?.nonEmpty
    else { throw MicrosoftGraphOAuthError.invalidAuthorizationCallback }
    return code
  }

  private static func randomValue(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    precondition(
      SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess,
      "Secure random generation failed"
    )
    return Data(bytes).graphBase64URLString()
  }
}

private struct MicrosoftGraphTokenResponse: Decodable {
  let accessToken: String
  let expiresIn: Int
  let refreshToken: String?
  let scope: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
  }
}

private struct MicrosoftGraphTokenErrorResponse: Decodable {
  let code: String

  enum CodingKeys: String, CodingKey {
    case code = "error"
  }
}

extension Data {
  fileprivate func graphBase64URLString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension Dictionary where Key == String, Value == String {
  fileprivate func graphFormURLEncodedData() -> Data {
    map { key, value in
      "\(key.graphFormURLEncoded())=\(value.graphFormURLEncoded())"
    }
    .sorted()
    .joined(separator: "&")
    .data(using: .utf8) ?? Data()
  }
}

extension String {
  fileprivate func graphFormURLEncoded() -> String {
    addingPercentEncoding(
      withAllowedCharacters: CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._~")
      )
    ) ?? self
  }
}
