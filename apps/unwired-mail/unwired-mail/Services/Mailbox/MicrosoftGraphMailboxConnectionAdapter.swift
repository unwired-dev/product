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

extension MailProviderId {
  static let microsoftGraph = MailProviderId(rawValue: "microsoft-graph")
}

extension MailboxConnectionCapabilities {
  static let microsoftGraphRead = MailboxConnectionCapabilities(
    canCategorizeHistorical: false,
    canForward: false,
    canReadMessages: true,
    canRegisterPush: false,
    canReply: false,
    canSearchProvider: false,
    canSend: false,
    canSynchronizeMetadata: true,
    providerActions: []
  )
}

struct MicrosoftGraphTokens: Codable, Equatable, Sendable {
  let accessToken: String
  let expiresAtMilliseconds: Int64
  let refreshToken: String
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

#if DEBUG
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
    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
  }
}

struct MicrosoftGraphProviderMessage: Codable, Equatable, Sendable {
  var categoryId: String?
  let ccRecipients: [String]
  let conversationId: String?
  let from: String?
  let id: String
  let internetMessageId: String?
  let isRead: Bool
  let parentFolderId: String?
  let receivedDateTime: String?
  let removed: Bool
  let replyTo: [String]
  let subject: String
  let bodyPreview: String
  let toRecipients: [String]

  init(
    categoryId: String? = nil,
    ccRecipients: [String],
    conversationId: String?,
    from: String?,
    id: String,
    internetMessageId: String?,
    isRead: Bool,
    parentFolderId: String?,
    receivedDateTime: String?,
    removed: Bool = false,
    replyTo: [String],
    subject: String,
    bodyPreview: String,
    toRecipients: [String]
  ) {
    self.categoryId = categoryId
    self.ccRecipients = ccRecipients
    self.conversationId = conversationId
    self.from = from
    self.id = id
    self.internetMessageId = internetMessageId
    self.isRead = isRead
    self.parentFolderId = parentFolderId
    self.receivedDateTime = receivedDateTime
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
    let dateMilliseconds = Self.dateMilliseconds(receivedDateTime)
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
      subject: subject
    )
  }

  static func customFolderStateId(_ folderId: String) -> String {
    let encoded = Data(folderId.utf8).graphBase64URLString()
    return "graph-folder:\(encoded)"
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

protocol MicrosoftGraphClient {
  func verifyAccount(accessToken: String) async throws -> MicrosoftGraphAccount
  func loadFolders(accessToken: String) async throws -> [MicrosoftGraphFolder]
  func loadMetadataPage(
    folder: MicrosoftGraphFolder,
    continuationURL: URL?,
    pageSize: Int,
    accessToken: String
  ) async throws -> MicrosoftGraphMetadataPage
  func loadTextBody(messageId: String, accessToken: String) async throws -> String
}

struct URLSessionMicrosoftGraphClient: MicrosoftGraphClient {
  private static let baseURL = URL(string: "https://graph.microsoft.com/v1.0")!
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
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
      let response: GraphFolderPageResponse = try await get(url, accessToken: accessToken)
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
        try metadataURL(folderId: folder.id, pageSize: pageSize)
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

  func loadTextBody(messageId: String, accessToken: String) async throws -> String {
    var components = URLComponents(
      url: Self.baseURL
        .appendingPathComponent("me")
        .appendingPathComponent("messages")
        .appendingPathComponent(messageId),
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

  private func folderListURL(parentFolderId: String?) throws -> URL {
    var url = Self.baseURL.appendingPathComponent("me").appendingPathComponent("mailFolders")
    if let parentFolderId {
      url = url.appendingPathComponent(parentFolderId).appendingPathComponent("childFolders")
    }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "includeHiddenFolders", value: "true"),
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
        accessToken: accessToken
      )
      return response.id
    } catch MicrosoftGraphClientError.requestFailed(404) {
      return nil
    }
  }

  private func metadataURL(folderId: String, pageSize: Int) throws -> URL {
    var components = URLComponents(
      url: Self.baseURL
        .appendingPathComponent("me")
        .appendingPathComponent("mailFolders")
        .appendingPathComponent(folderId)
        .appendingPathComponent("messages")
        .appendingPathComponent("delta"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(
        name: "$select",
        value:
          "id,conversationId,parentFolderId,receivedDateTime,subject,bodyPreview,"
          + "internetMessageId,isRead,from,replyTo,toRecipients,ccRecipients"
      ),
      URLQueryItem(name: "$top", value: String(pageSize)),
      URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
    ]
    return try requiredURL(components)
  }

  private func get<Response: Decodable>(
    _ url: URL,
    accessToken: String,
    preferences: [String] = []
  ) async throws -> Response {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if !preferences.isEmpty {
      request.setValue(preferences.joined(separator: ", "), forHTTPHeaderField: "Prefer")
    }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
    if response.statusCode == 410 {
      throw MicrosoftGraphClientError.deltaTokenExpired
    }
    guard (200..<300).contains(response.statusCode) else {
      throw MicrosoftGraphClientError.requestFailed(response.statusCode)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw MicrosoftGraphClientError.invalidProviderResponse
    }
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
  let bodyPreview: String?
  let ccRecipients: [GraphRecipientResponse]?
  let conversationId: String?
  let from: GraphRecipientResponse?
  let id: String
  let internetMessageId: String?
  let isRead: Bool?
  let parentFolderId: String?
  let receivedDateTime: String?
  let removed: GraphRemovedResponse?
  let replyTo: [GraphRecipientResponse]?
  let subject: String?
  let toRecipients: [GraphRecipientResponse]?

  enum CodingKeys: String, CodingKey {
    case bodyPreview
    case ccRecipients
    case conversationId
    case from
    case id
    case internetMessageId
    case isRead
    case parentFolderId
    case receivedDateTime
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
      id: id,
      internetMessageId: internetMessageId,
      isRead: isRead ?? true,
      parentFolderId: parentFolderId,
      receivedDateTime: receivedDateTime,
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
  var folders: [MicrosoftGraphFolderSyncState]
  var hasInitialMailboxAvailability: Bool

  var historicalMetadataBackfillIsComplete: Bool {
    hasInitialMailboxAvailability && folders.allSatisfy { $0.deltaLink != nil }
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
  func savePage(
    _ messages: [MicrosoftGraphProviderMessage],
    folderId: String,
    state: MicrosoftGraphMetadataSyncState,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws
  func updateCategory(
    _ categoryId: String,
    messageId: String,
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphProviderMessage
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
    connectionId: MailboxConnectionId
  ) throws {
    let context = try makeContext()
    let existing = Dictionary(
      uniqueKeysWithValues: try records(
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      ).map { ($0.stableProviderMessageId, $0) }
    )
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
        productAccountId: productAccountId,
        connectionId: connectionId,
        context: context
      ).first(where: { $0.stableProviderMessageId == messageId })
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
  private let store: MicrosoftGraphMetadataPersisting

  init(
    client: MicrosoftGraphClient,
    store: MicrosoftGraphMetadataPersisting
  ) {
    self.client = client
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

  // swiftlint:disable:next function_body_length
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
        shouldPersist: shouldPersist
      )
    }
    guard state.historicalMetadataBackfillIsComplete else {
      return try load(connection: connection, productAccountId: productAccountId)
        .limitedInitialPage(to: Self.initialPageSize)
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
      return try load(connection: connection, productAccountId: productAccountId)
    } catch MicrosoftGraphClientError.deltaTokenExpired {
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
    while let index = state.folders.firstIndex(where: { $0.deltaLink == nil }) {
      var continuation = state.folders[index].nextLink
      repeat {
        try Task.checkCancellation()
        let page = try await client.loadMetadataPage(
          folder: state.folders[index].folder,
          continuationURL: continuation,
          pageSize: Self.initialPageSize,
          accessToken: accessToken
        )
        try Task.checkCancellation()
        state.folders[index].nextLink = page.nextLink
        state.folders[index].deltaLink = page.deltaLink
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

  private func start(
    folders: [MicrosoftGraphFolder],
    connection: MailboxConnection,
    productAccountId: String,
    accessToken: String,
    cursorExpired: Bool,
    shouldPersist: @escaping () -> Bool
  ) async throws -> MailboxMetadataSyncResult {
    var state = MicrosoftGraphMetadataSyncState(
      folders: folders.map {
        MicrosoftGraphFolderSyncState(folder: $0, deltaLink: nil, nextLink: nil)
      },
      hasInitialMailboxAvailability: false
    )
    var continuation: URL?
    var messages: [MicrosoftGraphProviderMessage] = []
    repeat {
      let page = try await client.loadMetadataPage(
        folder: state.folders[0].folder,
        continuationURL: continuation,
        pageSize: Self.initialPageSize,
        accessToken: accessToken
      )
      try Task.checkCancellation()
      guard shouldPersist() else { throw CancellationError() }
      messages.append(contentsOf: page.messages)
      state.folders[0].nextLink = page.nextLink
      state.folders[0].deltaLink = page.deltaLink
      continuation = page.nextLink
    } while messages.count < Self.initialPageSize && continuation != nil
    state.hasInitialMailboxAvailability = true
    try store.savePage(
      messages,
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
      hasInitialMailboxAvailability: state.hasInitialMailboxAvailability
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

  private func refreshedState(
    _ state: MicrosoftGraphMetadataSyncState?,
    folders: [MicrosoftGraphFolder],
    productAccountId: String,
    connectionId: MailboxConnectionId
  ) throws -> MicrosoftGraphMetadataSyncState? {
    guard let state else { return nil }
    guard state.folders.map(\.folder.id) == folders.map(\.id) else {
      try store.clear(productAccountId: productAccountId, connectionId: connectionId)
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
    guard
      let payload = try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    else { return nil }
    let material = try requiredMaterial(productAccountId: session.productAccountId)
    do {
      let data = try material.decryptPayload(
        payload,
        associatedData: associatedData(message.stableProviderMessageId)
      )
      guard let text = String(data: data, encoding: .utf8) else {
        throw MicrosoftGraphClientError.missingMessageBody
      }
      return MailboxMessageBody(text: text)
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      return nil
    }
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
    let text = try await client.loadTextBody(
      messageId: message.providerMessageId,
      accessToken: accessToken
    )
    let material = try requiredMaterial(productAccountId: session.productAccountId)
    try cache.saveMessageBody(
      material.encryptPayload(
        Data(text.utf8),
        associatedData: associatedData(message.stableProviderMessageId)
      ),
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
    return MailboxMessageBody(text: text)
  }

  func recordAccess(message: MailboxMessageMetadata, session: ProductAccountSessionSnapshot) {
    try? cache.recordMessageBodyAccess(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId,
      accessedAt: Date()
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
      let text = try await client.loadTextBody(
        messageId: message.providerMessageId,
        accessToken: accessToken
      )
      _ = try cache.saveMessageBody(
        GmailMessageBodyCacheWrite(
          cachedAt: Date(
            timeIntervalSince1970: TimeInterval(message.providerInternalDateMilliseconds) / 1_000
          ),
          isPinned: pinnedMessageIds.contains(message.id),
          isProtected: true,
          payload: material.encryptPayload(
            Data(text.utf8),
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
}

struct MicrosoftGraphMailboxConnectionAdapter: MailboxConnectionAdapter {
  private let authorizer: MicrosoftGraphAuthorizing
  private let bodyService: MicrosoftGraphMessageBodyService
  private let definitionSyncService: MailboxConnectionDefinitionSyncing
  private let metadataService: MicrosoftGraphMetadataService
  private let metadataStore: MicrosoftGraphMetadataPersisting
  private let now: () -> Date
  private let syncGate: MailboxConnectionSyncGate
  private let tokenStore: MicrosoftGraphAuthorizationPersisting

  init(
    authorizer: MicrosoftGraphAuthorizing = MicrosoftGraphOAuthService(),
    bodyCache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    client: MicrosoftGraphClient = URLSessionMicrosoftGraphClient(),
    definitionSyncService: MailboxConnectionDefinitionSyncing = MailboxConnectionSyncService(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting =
      KeychainProductSyncKeyMaterialStore(),
    metadataStore: MicrosoftGraphMetadataPersisting =
      SwiftDataMicrosoftGraphMetadataStore(),
    now: @escaping () -> Date = Date.init,
    syncGate: MailboxConnectionSyncGate = .shared,
    tokenStore: MicrosoftGraphAuthorizationPersisting =
      KeychainMicrosoftGraphAuthorizationStore()
  ) {
    self.authorizer = authorizer
    self.bodyService = MicrosoftGraphMessageBodyService(
      cache: bodyCache,
      client: client,
      keyMaterialStore: keyMaterialStore
    )
    self.definitionSyncService = definitionSyncService
    self.metadataService = MicrosoftGraphMetadataService(client: client, store: metadataStore)
    self.metadataStore = metadataStore
    self.now = now
    self.syncGate = syncGate
    self.tokenStore = tokenStore
  }

  func clearLocalConnection(session: ProductAccountSessionSnapshot) async throws {
    var firstError: Error?
    do {
      try tokenStore.clearAll(productAccountId: session.productAccountId)
    } catch {
      firstError = error
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
    if let firstError { throw firstError }
  }

  func clearLocalConnection(
    _ connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    try validate(connection: connection, session: session, requiresAuthorization: false)
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
  func connect(
    expectedConnectionId: MailboxConnectionId?,
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
    let connection = MailboxConnection(
      authorizationState: .authorized,
      capabilities: .microsoftGraphRead,
      connectedAt: timestamp,
      displayName: account.emailAddress,
      id: connectionId,
      lastVerifiedAt: timestamp,
      productAccountId: ProductAccountId(session.productAccountId),
      trustedDeviceId: session.trustedDeviceId,
      updatedAt: timestamp
    )
    let previousTokens = try savedTokens(for: account, session: session)
    try tokenStore.save(
      tokens,
      productAccountId: session.productAccountId,
      providerAccountIdentifier: account.id
    )
    do {
      _ = try await definitionSyncService.saveConnection(connection, session: session)
      return connection
    } catch {
      restore(previousTokens, for: account, session: session)
      throw error
    }
  }

  private func savedTokens(
    for account: MicrosoftGraphAccount,
    session: ProductAccountSessionSnapshot
  ) throws -> MicrosoftGraphTokens? {
    try tokenStore.load(
      productAccountId: session.productAccountId,
      providerAccountIdentifier: account.id
    )
  }

  private func restore(
    _ previousTokens: MicrosoftGraphTokens?,
    for account: MicrosoftGraphAccount,
    session: ProductAccountSessionSnapshot
  ) {
    if let previousTokens {
      try? tokenStore.save(
        previousTokens,
        productAccountId: session.productAccountId,
        providerAccountIdentifier: account.id
      )
    } else {
      try? tokenStore.clear(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: account.id
      )
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
    for connectionId in snapshot.removedConnectionIds
    where connectionId.providerId == .microsoftGraph {
      if try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connectionId.providerMailboxIdentity.value
      ) != nil {
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
        try await clearLocalConnection(removed, session: session)
      }
    }
    return try snapshot.connections.compactMap { definition in
      guard definition.provider == MailProviderId.microsoftGraph.rawValue else { return nil }
      let authorized =
        try tokenStore.load(
          productAccountId: session.productAccountId,
          providerAccountIdentifier: definition.providerAccountIdentifier
        ) != nil
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
    try await clearLocalConnection(connection, session: session)
    _ = try await definitionSyncService.removeConnection(connection.id, session: session)
  }

  func setDefaultSendingConnection(
    _ connection: MailboxConnection?,
    session: ProductAccountSessionSnapshot
  ) async throws {
    if let connection {
      try validate(connection: connection, session: session, requiresAuthorization: true)
      throw MailboxConnectionAdapterError.unsupportedCapability
    }
    _ = try await definitionSyncService.setDefaultSendingConnection(nil, session: session)
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
    try validate(connection: connection, session: session, requiresAuthorization: false)
    return try metadataService.load(
      connection: connection,
      productAccountId: session.productAccountId
    )
    .projected(to: .role(.inbox))
    .limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
  }

  func loadMailbox(
    _ collection: MailboxMessageCollection,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    let result = try metadataService.load(
      connection: connection,
      productAccountId: session.productAccountId
    ).projected(to: collection)
    return collection == .allObserved
      ? result : result.limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
  }

  func loadProviderMailboxes(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> [ProviderMailbox] {
    try validate(connection: connection, session: session, requiresAuthorization: false)
    let state = try metadataStore.loadState(
      productAccountId: session.productAccountId,
      connectionId: connection.id
    )
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
    try await syncGate.withLock(connection.id) {
      let token = try await accessToken(connection: connection, session: session)
      return try await metadataService.continueBackfill(
        connection: connection,
        productAccountId: session.productAccountId,
        accessToken: token
      )
    }
  }

  func syncInbox(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMetadataSyncResult {
    try await syncGate.withLock(connection.id) {
      let token = try await accessToken(connection: connection, session: session)
      return try await metadataService.sync(
        connection: connection,
        productAccountId: session.productAccountId,
        accessToken: token
      )
      .projected(to: .role(.inbox))
      .limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
    }
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
    return try await syncGate.withLock(connection.id) {
      let token = try await accessToken(connection: connection, session: session)
      return try await metadataService.sync(
        connection: connection,
        productAccountId: session.productAccountId,
        accessToken: token,
        shouldPersist: shouldPersist
      )
      .projected(to: .role(.inbox))
      .limitedInitialPage(to: MicrosoftGraphMetadataService.initialPageSize)
    }
  }

  func overrideCategory(
    _ categoryId: String,
    for message: MailboxMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailboxMessageMetadata {
    let connection = try await connection(id: message.connectionId, session: session)
    return try metadataService.overrideCategory(
      categoryId,
      message: message,
      connection: connection,
      productAccountId: session.productAccountId
    )
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
    if let cached = try bodyService.loadCached(message: message, session: session) {
      bodyService.recordAccess(message: message, session: session)
      return cached
    }
    let connection = try await connection(id: message.connectionId, session: session)
    return try await bodyService.load(
      message: message,
      accessToken: accessToken(connection: connection, session: session),
      session: session
    )
  }

  func prefetchMessageBodies(
    connection: MailboxConnection,
    pinnedMessageIds: Set<StableProviderMessageIdentity>,
    referenceDate: Date,
    session: ProductAccountSessionSnapshot
  ) async throws {
    let observed = try await loadMailbox(.allObserved, connection: connection, session: session)
    let recentCutoff = referenceDate.addingTimeInterval(-30 * 24 * 60 * 60)
    let allowed = observed.messages.filter { message in
      let states = Set(message.providerStateIds ?? [])
      return states.isDisjoint(with: ["SPAM", "TRASH"])
    }
    let pinned = allowed.filter { pinnedMessageIds.contains($0.id) }
    let recent = allowed.filter { message in
      message.providerInternalDateMilliseconds >= Int64(recentCutoff.timeIntervalSince1970 * 1_000)
        && (message.providerStateIds ?? []).contains(where: { $0 == "INBOX" || $0 == "SENT" })
    }
    var selectedById: [StableProviderMessageIdentity: MailboxMessageMetadata] = [:]
    for message in pinned + Array(recent.prefix(500)) {
      selectedById[message.id] = message
    }
    try await bodyService.prefetch(
      messages: Array(selectedById.values),
      connectionId: connection.id,
      pinnedMessageIds: pinnedMessageIds,
      accessToken: try await accessToken(connection: connection, session: session),
      session: session
    )
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
    connection _: MailboxConnection,
    session _: ProductAccountSessionSnapshot
  ) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func perform(
    _ action: ProviderMailAction,
    messages: [MailboxMessageMetadata],
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  func send(
    _ message: OutgoingMessage,
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws {
    throw MailboxConnectionAdapterError.unsupportedCapability
  }

  private func accessToken(
    connection: MailboxConnection,
    session: ProductAccountSessionSnapshot
  ) async throws -> String {
    try validate(connection: connection, session: session, requiresAuthorization: true)
    let snapshot = try await definitionSyncService.loadSnapshotForProviderAccess(session: session)
    guard !snapshot.removedConnectionIds.contains(connection.id) else {
      try await clearLocalConnection(connection, session: session)
      throw MailboxConnectionAdapterError.connectionRemoved
    }
    guard
      var tokens = try tokenStore.load(
        productAccountId: session.productAccountId,
        providerAccountIdentifier: connection.providerMailboxIdentity.value
      )
    else { throw MailboxConnectionAdapterError.authorizationRequired }
    let refreshBoundary = Int64(now().addingTimeInterval(60).timeIntervalSince1970 * 1_000)
    if tokens.expiresAtMilliseconds <= refreshBoundary {
      do {
        tokens = try await authorizer.refresh(tokens)
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
    MailboxConnection(
      authorizationState: authorized ? .authorized : .required,
      capabilities: authorized ? .microsoftGraphRead : .none,
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
  case tokenExchangeFailed
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

@MainActor
final class MicrosoftGraphOAuthService: NSObject, MicrosoftGraphAuthorizing {
  nonisolated fileprivate static let scopes =
    "openid profile email offline_access User.Read Mail.Read"

  private let callbackScheme: String?
  private let clientIdentifier: String?
  nonisolated private let now: @Sendable () -> Date
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
    session: URLSession = .shared
  ) {
    self.callbackScheme = callbackScheme?.nonEmpty
    self.clientIdentifier = clientIdentifier?.nonEmpty
    self.now = now
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
      fallbackRefreshToken: tokens.refreshToken
    )
  }

  private func exchange(
    parameters: [String: String],
    fallbackRefreshToken: String? = nil
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
    guard
      let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      let payload = try? JSONDecoder().decode(MicrosoftGraphTokenResponse.self, from: data),
      let refreshToken = payload.refreshToken?.nonEmpty ?? fallbackRefreshToken?.nonEmpty
    else { throw MicrosoftGraphOAuthError.tokenExchangeFailed }
    return MicrosoftGraphTokens(
      accessToken: payload.accessToken,
      expiresAtMilliseconds: Int64(
        now().addingTimeInterval(TimeInterval(payload.expiresIn)).timeIntervalSince1970 * 1_000
      ),
      refreshToken: refreshToken
    )
  }

  private func authenticate(
    authorizationURL: URL,
    callbackScheme: String
  ) async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
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
    continuation?.resume(throwing: CancellationError())
  }

  private func finishAuthentication(callbackURL: URL?, error: Error?) {
    guard let continuation = authenticationContinuation else { return }
    authenticationContinuation = nil
    webAuthenticationSession = nil
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
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if canImport(UIKit)
      let scene =
        UIApplication.shared.connectedScenes.first {
          $0.activationState == .foregroundActive
        } as? UIWindowScene
      return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    #elseif canImport(AppKit)
      return NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
      return ASPresentationAnchor()
    #endif
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
    redirectURI = URL(string: "\(callbackScheme):/oauthredirect")!
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

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
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
