import Foundation

// swiftlint:disable file_length type_body_length

enum EWSServiceError: LocalizedError, Equatable {
  case authenticationRejected
  case invalidResponse
  case response(code: String, message: String)

  var errorDescription: String? {
    switch self {
    case .authenticationRejected:
      return "Exchange rejected the device-local authorization."
    case .invalidResponse:
      return "Exchange returned an invalid EWS response."
    case .response(let code, let message):
      return message.isEmpty ? "Exchange EWS request failed: \(code)." : message
    }
  }

  var isItemNotFound: Bool {
    if case .response(let code, _) = self {
      return code == "ErrorItemNotFound"
    }
    return false
  }
}

/// Sends mailbox-targeted SOAP requests directly to an on-premises Exchange server.
///
/// Example:
/// ```swift
/// let account = try await SystemEWSClient().verify(authorization)
/// ```
struct SystemEWSClient: EWSClient {
  private static let unsubscribeHeaderPropertiesXML = """
    <t:ExtendedFieldURI DistinguishedPropertySetId="InternetHeaders"
      PropertyName="List-ID" PropertyType="String"/>
    <t:ExtendedFieldURI DistinguishedPropertySetId="InternetHeaders"
      PropertyName="List-Unsubscribe" PropertyType="String"/>
    <t:ExtendedFieldURI DistinguishedPropertySetId="InternetHeaders"
      PropertyName="List-Unsubscribe-Post" PropertyType="String"/>
    """

  private let session: URLSession

  init(session: URLSession? = nil) {
    self.session = session ?? Self.makeProductionSession()
  }

  static func makeProductionSession() -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
    return URLSession(configuration: configuration)
  }

  /// Verifies mailbox identity and the supported on-premises server version.
  func verify(_ authorization: DeviceLocalEWSAuthorization) async throws -> EWSAccount {
    let document = try await request(
      """
      <m:GetFolder>
        <m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape>
        <m:FolderIds><t:DistinguishedFolderId Id="inbox">
          \(mailboxXML(authorization))
        </t:DistinguishedFolderId></m:FolderIds>
      </m:GetFolder>
      """,
      authorization: authorization
    )
    guard
      let inbox = document.descendants.first(where: Self.isFolderNode),
      let providerMailboxIdentifier = inbox.child(named: "FolderId")?.attributes["Id"],
      !providerMailboxIdentifier.isEmpty
    else {
      throw EWSSetupError.invalidMailboxIdentity
    }
    let primaryEmail = authorization.definition.emailAddress
    return EWSAccount(
      displayName: primaryEmail,
      primaryEmailAddress: primaryEmail,
      providerMailboxIdentifier: providerMailboxIdentifier,
      serverVersion: try serverVersion(document)
    )
  }

  /// Loads provider folders and resolves Exchange distinguished folder roles.
  func loadFolders(
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    try await loadFolders(authorization: authorization, knownFolders: [])
  }

  func loadFolders(
    authorization: DeviceLocalEWSAuthorization,
    knownFolders: [EWSFolder]
  ) async throws -> [EWSFolder] {
    var folders = try await loadFolderHierarchy(
      rootDistinguishedId: "msgfolderroot",
      isArchiveHierarchy: false,
      authorization: authorization
    )
    do {
      folders += try await loadFolderHierarchy(
        rootDistinguishedId: "archivemsgfolderroot",
        isArchiveHierarchy: true,
        authorization: authorization
      )
    } catch EWSServiceError.response(let code, _)
      where code == "ErrorFolderNotFound"
    {}
    folders = Dictionary(grouping: folders, by: \.id).compactMap { $0.value.first }
    let resolvedFolders = try await resolveFolderRoles(
      folders,
      knownFolders: knownFolders,
      authorization: authorization
    )
    let foldersWithOutbox = try await markOutbox(
      resolvedFolders,
      authorization: authorization
    )
    let foldersWithArchiveTrash = try await markArchiveTrashHierarchy(
      foldersWithOutbox,
      authorization: authorization
    )
    return try await markArchiveSentHierarchy(
      foldersWithArchiveTrash,
      authorization: authorization
    ).filter(\.isMailFolder)
  }

  private func loadFolderHierarchy(
    rootDistinguishedId: String,
    isArchiveHierarchy: Bool,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    let pageSize = 100
    var offset = 0
    var folders: [EWSFolder] = []
    while true {
      let document = try await loadFolderPage(
        offset: offset,
        pageSize: pageSize,
        rootDistinguishedId: rootDistinguishedId,
        authorization: authorization
      )
      let folderNodes = document.descendants.filter(Self.isFolderNode)
      folders += try folderNodes.map { node in
        guard let parsed = folder(node) else {
          throw EWSServiceError.invalidResponse
        }
        return EWSFolder(
          changeKey: parsed.changeKey,
          displayName: parsed.displayName,
          folderClass: parsed.folderClass,
          id: parsed.id,
          isArchiveHierarchy: isArchiveHierarchy,
          isSearchFolder: parsed.isSearchFolder,
          isSentHierarchy: parsed.isSentHierarchy,
          isTrashHierarchy: parsed.isTrashHierarchy,
          parentFolderId: parsed.parentFolderId,
          role: parsed.role
        )
      }
      guard let rootFolder = document.firstDescendant(named: "RootFolder") else {
        throw EWSServiceError.invalidResponse
      }
      if rootFolder.attributes["IncludesLastItemInRange"] == "true" { break }
      guard
        let nextOffset = rootFolder.attributes["IndexedPagingOffset"].flatMap(Int.init),
        nextOffset > offset
      else { throw EWSServiceError.invalidResponse }
      offset = nextOffset
    }
    return folders
  }

  // swiftlint:disable:next function_body_length
  private func resolveFolderRoles(
    _ discoveredFolders: [EWSFolder],
    knownFolders: [EWSFolder],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    var folders = discoveredFolders
    for role in EWSFolderRole.allCases {
      if let known = knownFolders.first(where: { $0.role == role }),
        let index = folders.firstIndex(where: { $0.id == known.id })
      {
        folders[index] = EWSFolder(
          changeKey: folders[index].changeKey,
          displayName: folders[index].displayName,
          folderClass: folders[index].folderClass,
          id: folders[index].id,
          isArchiveHierarchy: folders[index].isArchiveHierarchy,
          isOutbox: folders[index].isOutbox,
          isSearchFolder: folders[index].isSearchFolder,
          isSentHierarchy: role == .sent || folders[index].isSentHierarchy == true,
          isTrashHierarchy: folders[index].isTrashHierarchy,
          parentFolderId: folders[index].parentFolderId,
          role: role
        )
        continue
      }
      guard let distinguished = Self.distinguishedFolderId(role) else { continue }
      let resolved: EWSFolder?
      do {
        resolved = try await loadFolder(
          distinguishedId: distinguished,
          role: role,
          authorization: authorization
        )
      } catch EWSServiceError.response(let code, _)
        where code == "ErrorFolderNotFound"
      {
        continue
      }
      guard let resolved else { continue }
      if let index = folders.firstIndex(where: { $0.id == resolved.id }) {
        folders[index] = EWSFolder(
          changeKey: folders[index].changeKey,
          displayName: folders[index].displayName,
          folderClass: folders[index].folderClass,
          id: folders[index].id,
          isArchiveHierarchy: folders[index].isArchiveHierarchy,
          isOutbox: folders[index].isOutbox,
          isSearchFolder: folders[index].isSearchFolder,
          isSentHierarchy: role == .sent || folders[index].isSentHierarchy == true,
          isTrashHierarchy: folders[index].isTrashHierarchy,
          parentFolderId: folders[index].parentFolderId,
          role: role
        )
      } else {
        folders.append(resolved)
      }
    }
    return folders.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private func markOutbox(
    _ discoveredFolders: [EWSFolder],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    let outbox: EWSFolder?
    do {
      outbox = try await loadFolder(
        distinguishedId: "outbox",
        role: nil,
        isOutbox: true,
        authorization: authorization
      )
    } catch EWSServiceError.response(let code, _)
      where code == "ErrorFolderNotFound"
    {
      return discoveredFolders
    }
    guard let outbox else { return discoveredFolders }
    var folders = discoveredFolders
    if let index = folders.firstIndex(where: { $0.id == outbox.id }) {
      let folder = folders[index]
      folders[index] = EWSFolder(
        changeKey: folder.changeKey,
        displayName: folder.displayName,
        folderClass: folder.folderClass,
        id: folder.id,
        isArchiveHierarchy: folder.isArchiveHierarchy,
        isOutbox: true,
        isSearchFolder: folder.isSearchFolder,
        isSentHierarchy: folder.isSentHierarchy,
        isTrashHierarchy: folder.isTrashHierarchy,
        parentFolderId: folder.parentFolderId,
        role: folder.role
      )
    } else {
      folders.append(outbox)
    }
    return folders
  }

  private func markArchiveTrashHierarchy(
    _ discoveredFolders: [EWSFolder],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    let archiveTrash: EWSFolder?
    do {
      archiveTrash = try await loadFolder(
        distinguishedId: "archivedeleteditems",
        role: nil,
        isArchiveHierarchy: true,
        isTrashHierarchy: true,
        authorization: authorization
      )
    } catch EWSServiceError.response(let code, _)
      where code == "ErrorFolderNotFound"
    {
      return discoveredFolders
    }
    guard let archiveTrash else { return discoveredFolders }
    var folders = discoveredFolders
    if let index = folders.firstIndex(where: { $0.id == archiveTrash.id }) {
      let folder = folders[index]
      folders[index] = EWSFolder(
        changeKey: folder.changeKey,
        displayName: folder.displayName,
        folderClass: folder.folderClass,
        id: folder.id,
        isArchiveHierarchy: true,
        isOutbox: folder.isOutbox,
        isSearchFolder: folder.isSearchFolder,
        isSentHierarchy: folder.isSentHierarchy,
        isTrashHierarchy: true,
        parentFolderId: folder.parentFolderId,
        role: folder.role
      )
    } else {
      folders.append(archiveTrash)
    }
    return folders
  }

  private func markArchiveSentHierarchy(
    _ discoveredFolders: [EWSFolder],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    guard let sentFolder = discoveredFolders.first(where: { $0.role == .sent }) else {
      return discoveredFolders
    }
    let archiveRoot: EWSFolder?
    do {
      archiveRoot = try await loadFolder(
        distinguishedId: "archivemsgfolderroot",
        role: nil,
        isArchiveHierarchy: true,
        authorization: authorization
      )
    } catch EWSServiceError.response(let code, _)
      where code == "ErrorFolderNotFound"
    {
      return discoveredFolders
    }
    guard let archiveRoot else { return discoveredFolders }
    let candidates = discoveredFolders.filter {
      $0.isArchiveHierarchy == true
        && $0.role == nil
        && $0.parentFolderId == archiveRoot.id
        && $0.displayName.localizedCaseInsensitiveCompare(sentFolder.displayName) == .orderedSame
    }
    guard candidates.count == 1, let archiveSentId = candidates.first?.id else {
      return discoveredFolders
    }
    return discoveredFolders.map { folder in
      guard folder.id == archiveSentId else { return folder }
      return EWSFolder(
        changeKey: folder.changeKey,
        displayName: folder.displayName,
        folderClass: folder.folderClass,
        id: folder.id,
        isArchiveHierarchy: true,
        isOutbox: folder.isOutbox,
        isSearchFolder: folder.isSearchFolder,
        isSentHierarchy: true,
        isTrashHierarchy: folder.isTrashHierarchy,
        parentFolderId: folder.parentFolderId,
        role: nil
      )
    }
  }

  private func loadFolderPage(
    offset: Int,
    pageSize: Int,
    rootDistinguishedId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSXMLNode {
    try await request(
      """
      <m:FindFolder Traversal="Deep">
        <m:FolderShape>
          <t:BaseShape>Default</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="folder:FolderClass"/>
            <t:FieldURI FieldURI="folder:ParentFolderId"/>
          </t:AdditionalProperties>
        </m:FolderShape>
        <m:IndexedPageFolderView MaxEntriesReturned="\(pageSize)" Offset="\(offset)"
          BasePoint="Beginning"/>
        <m:ParentFolderIds><t:DistinguishedFolderId Id="\(rootDistinguishedId)">
          \(mailboxXML(authorization))
        </t:DistinguishedFolderId></m:ParentFolderIds>
      </m:FindFolder>
      """,
      authorization: authorization
    )
  }

  /// Loads one offset-based metadata page without downloading message bodies.
  func loadMessagePage(
    folder: EWSFolder,
    offset: Int,
    pageSize: Int,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage {
    let prefersSentDate = folder.role == .sent || folder.isSentHierarchy == true
    let sortField =
      folder.role == .drafts
      ? "item:LastModifiedTime"
      : (prefersSentDate ? "item:DateTimeSent" : "item:DateTimeReceived")
    let document = try await loadMessagePageDocument(
      folderId: folder.id,
      offset: offset,
      pageSize: pageSize,
      sortField: sortField,
      authorization: authorization
    )
    let page = try messagePage(
      document,
      folderId: folder.id,
      offset: offset,
      prefersSentDate: prefersSentDate
    )
    return try await addingCalendarAttachmentMetadata(
      to: page,
      authorization: authorization
    )
  }

  private func loadMessagePageDocument(
    folderId: String,
    offset: Int,
    pageSize: Int,
    sortField: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSXMLNode {
    try await request(
      """
      <m:FindItem Traversal="Shallow">
        <m:ItemShape>
          <t:BaseShape>Default</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="message:InternetMessageId"/>
            <t:FieldURI FieldURI="item:ParentFolderId"/>
            <t:FieldURI FieldURI="item:ConversationId"/>
            <t:FieldURI FieldURI="item:DateTimeCreated"/>
            <t:FieldURI FieldURI="item:DateTimeReceived"/>
            <t:FieldURI FieldURI="item:DateTimeSent"/>
            <t:FieldURI FieldURI="item:LastModifiedTime"/>
            <t:FieldURI FieldURI="item:DisplayCc"/>
            <t:FieldURI FieldURI="item:HasAttachments"/>
            <t:FieldURI FieldURI="item:ItemClass"/>
            <t:FieldURI FieldURI="message:From"/>
            <t:FieldURI FieldURI="message:Sender"/>
            <t:FieldURI FieldURI="calendar:Organizer"/>
            <t:FieldURI FieldURI="item:IsDraft"/>
            <t:FieldURI FieldURI="message:IsRead"/>
            <t:FieldURI FieldURI="message:ReplyTo"/>
            <t:FieldURI FieldURI="message:ToRecipients"/>
            <t:FieldURI FieldURI="message:CcRecipients"/>
            <t:FieldURI FieldURI="message:BccRecipients"/>
            <t:FieldURI FieldURI="item:Preview"/>
            <t:FieldURI FieldURI="item:Flag"/>
            <t:ExtendedFieldURI PropertyTag="0x300B" PropertyType="Binary"/>
            \(Self.unsubscribeHeaderPropertiesXML)
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:IndexedPageItemView MaxEntriesReturned="\(pageSize)" Offset="\(offset)"
          BasePoint="Beginning"/>
        <m:SortOrder><t:FieldOrder Order="Descending">
          <t:FieldURI FieldURI="\(sortField)"/>
        </t:FieldOrder></m:SortOrder>
        <m:ParentFolderIds><t:FolderId Id="\(xmlAttribute(folderId))"/></m:ParentFolderIds>
      </m:FindItem>
      """,
      authorization: authorization
    )
  }

  // swiftlint:disable:next function_body_length
  private func addingCalendarAttachmentMetadata(
    to page: EWSMessagePage,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSMessagePage {
    let candidates = page.messages.filter { $0.hasAttachments == true }
    guard !candidates.isEmpty else { return page }
    let itemIds = candidates.map {
      #"<t:ItemId Id="\#(xmlAttribute($0.itemId))"/>"#
    }.joined()
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape>
          <t:BaseShape>IdOnly</t:BaseShape>
          <t:AdditionalProperties><t:FieldURI FieldURI="item:Attachments"/>
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:ItemIds>\(itemIds)</m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization,
      allowsMixedResponseCodes: true
    )
    let responseCodes = document.descendants.filter { $0.localName == "ResponseCode" }
    let failure =
      responseCodes.first {
        $0.text != "NoError" && $0.text != "ErrorItemNotFound"
      }
      ?? (responseCodes.contains(where: { $0.text == "NoError" })
        ? nil : responseCodes.first(where: { $0.text != "NoError" }))
    if let failure {
      throw EWSServiceError.response(
        code: failure.text,
        message: failure.parent?.child(named: "MessageText")?.text ?? ""
      )
    }
    var invitationsByItemId: [String: CalendarInvitationDescriptor] = [:]
    for item in document.descendants where Self.isItemNode(item) {
      guard let itemId = item.child(named: "ItemId")?.attributes["Id"],
        let message = candidates.first(where: { $0.itemId == itemId }),
        let attachments = item.child(named: "Attachments")
      else { continue }
      invitationsByItemId[itemId] =
        attachments.children.lazy.compactMap {
          guard $0.localName == "FileAttachment" else { return nil }
          return try? attachmentDescriptor($0).calendarInvitation(
            providerMessageIdentity: message.stableProviderId
          )
        }.first
    }
    return EWSMessagePage(
      messages: page.messages.map { message in
        guard message.calendarInvitation == nil,
          let invitation = invitationsByItemId[message.itemId]
        else { return message }
        var updated = message
        updated.calendarInvitation = invitation
        return updated
      },
      nextOffset: page.nextOffset
    )
  }
  private func messagePage(
    _ document: EWSXMLNode,
    folderId: String,
    offset: Int,
    prefersSentDate: Bool
  ) throws -> EWSMessagePage {
    guard
      let rootFolder = document.firstDescendant(named: "RootFolder"),
      let includesLastValue = rootFolder.attributes["IncludesLastItemInRange"],
      ["true", "false"].contains(includesLastValue)
    else {
      throw EWSServiceError.invalidResponse
    }
    let includesLast = includesLastValue == "true"
    let nextOffset: Int?
    if includesLast {
      nextOffset = nil
    } else {
      guard
        let value = rootFolder.attributes["IndexedPagingOffset"].flatMap(Int.init),
        value > offset
      else {
        throw EWSServiceError.invalidResponse
      }
      nextOffset = value
    }
    let itemNodes = document.descendants.filter(Self.isItemNode)
    let items = try itemNodes.map { node in
      guard
        let message = providerMessage(
          node,
          defaultFolderId: folderId,
          prefersSentDate: prefersSentDate
        )
      else {
        throw EWSServiceError.invalidResponse
      }
      return message
    }
    return EWSMessagePage(messages: items, nextOffset: nextOffset)
  }

  /// Loads one message body directly from Exchange.
  func loadMessageBody(
    itemId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> String {
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape>
          <t:BaseShape>IdOnly</t:BaseShape>
          <t:BodyType>Text</t:BodyType>
          <t:AdditionalProperties><t:FieldURI FieldURI="item:Body"/></t:AdditionalProperties>
        </m:ItemShape>
        <m:ItemIds><t:ItemId Id="\(xmlAttribute(itemId))"/></m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization
    )
    guard
      let item = document.descendants.first(where: Self.isItemNode),
      let body = item.child(named: "Body")
    else {
      throw EWSServiceError.invalidResponse
    }
    return body.text
  }

  func loadMessageSourceData(
    itemId: String,
    maximumByteCount: Int,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> Data {
    guard maximumByteCount >= 0 else { throw MailboxMessageSourceError.exceedsSizeLimit }
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape>
          <t:BaseShape>IdOnly</t:BaseShape>
          <t:IncludeMimeContent>true</t:IncludeMimeContent>
        </m:ItemShape>
        <m:ItemIds><t:ItemId Id="\(xmlAttribute(itemId))"/></m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization,
      maximumResponseByteCount: try attachmentResponseByteLimit(
        contentByteCount: maximumByteCount
      )
    )
    guard
      let item = document.descendants.first(where: Self.isItemNode),
      let encodedContent = item.child(named: "MimeContent")?.text,
      encodedContent.utf8.allSatisfy(Self.isBase64OrWhitespace),
      let data = Data(base64Encoded: encodedContent, options: .ignoreUnknownCharacters),
      data.count <= maximumByteCount
    else { throw MailboxMessageSourceError.invalidResponse }
    try Task.checkCancellation()
    return data
  }

  func loadAttachmentDescriptors(
    itemId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSAttachmentDescriptor] {
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape>
          <t:BaseShape>IdOnly</t:BaseShape>
          <t:AdditionalProperties><t:FieldURI FieldURI="item:Attachments"/></t:AdditionalProperties>
        </m:ItemShape>
        <m:ItemIds><t:ItemId Id="\(xmlAttribute(itemId))"/></m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization
    )
    guard let item = document.descendants.first(where: Self.isItemNode) else {
      throw EWSServiceError.invalidResponse
    }
    guard let attachments = item.child(named: "Attachments") else { return [] }
    return try attachments.children.compactMap { node in
      switch node.localName {
      case "FileAttachment", "ItemAttachment":
        try attachmentDescriptor(node)
      default:
        nil
      }
    }
  }

  func loadAttachmentData(
    providerAttachmentId: String,
    expectedByteCount: Int,
    maximumByteCount: Int,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> Data {
    guard !providerAttachmentId.isEmpty, expectedByteCount >= 0, maximumByteCount >= 0,
      expectedByteCount == 0 || expectedByteCount <= maximumByteCount
    else { throw MailboxMessageAttachmentError.invalidResponse }
    let boundedContentByteCount = expectedByteCount == 0 ? maximumByteCount : expectedByteCount
    let document = try await request(
      """
      <m:GetAttachment>
        <m:AttachmentShape><t:IncludeMimeContent>false</t:IncludeMimeContent></m:AttachmentShape>
        <m:AttachmentIds><t:AttachmentId Id="\(xmlAttribute(providerAttachmentId))"/>
        </m:AttachmentIds>
      </m:GetAttachment>
      """,
      authorization: authorization,
      maximumResponseByteCount: try attachmentResponseByteLimit(
        contentByteCount: boundedContentByteCount
      )
    )
    try Task.checkCancellation()
    guard
      let attachment = document.descendants.first(where: { $0.localName == "FileAttachment" }),
      attachment.child(named: "AttachmentId")?.attributes["Id"] == providerAttachmentId,
      let encodedContent = attachment.child(named: "Content")?.text
    else { throw EWSServiceError.invalidResponse }
    guard encodedContent.utf8.allSatisfy(Self.isBase64OrWhitespace),
      let data = Data(base64Encoded: encodedContent, options: .ignoreUnknownCharacters),
      data.count <= maximumByteCount,
      data.count == expectedByteCount
    else { throw MailboxMessageAttachmentError.invalidResponse }
    try Task.checkCancellation()
    return data
  }

  func loadCalendarInvitationCandidate(
    itemId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> CalendarInvitationCandidate {
    let itemClass = try await loadCalendarInvitationItemClass(
      itemId: itemId,
      authorization: authorization
    )
    let recurrenceFields =
      itemClass.lowercased().hasPrefix("ipm.schedule.meeting.canceled")
      ? ""
      : #"<t:FieldURI FieldURI="calendar:IsRecurring"/><t:FieldURI FieldURI="calendar:CalendarItemType"/>"#
    let appointmentFields =
      itemClass.lowercased().hasPrefix("ipm.schedule.meeting.canceled")
      ? #"<t:FieldURI FieldURI="calendar:AppointmentSequenceNumber"/>"#
      : #"<t:FieldURI FieldURI="calendar:AppointmentSequenceNumber"/><t:FieldURI FieldURI="calendar:IsAllDayEvent"/>"#
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape>
          <t:BaseShape>IdOnly</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="item:ItemClass"/>
            <t:FieldURI FieldURI="item:Subject"/>
            <t:FieldURI FieldURI="calendar:UID"/>
            \(appointmentFields)
            <t:FieldURI FieldURI="calendar:Start"/>
            <t:FieldURI FieldURI="calendar:End"/>
            <t:FieldURI FieldURI="calendar:Location"/>
            <t:FieldURI FieldURI="calendar:IsCancelled"/>
            \(recurrenceFields)
            <t:FieldURI FieldURI="calendar:RecurrenceId"/>
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:ItemIds><t:ItemId Id="\(xmlAttribute(itemId))"/></m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization
    )
    guard let item = document.descendants.first(where: Self.isItemNode) else {
      throw EWSServiceError.invalidResponse
    }
    return try Self.calendarInvitationCandidate(item)
  }

  private func loadCalendarInvitationItemClass(
    itemId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> String {
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape>
          <t:BaseShape>IdOnly</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="item:ItemClass"/>
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:ItemIds><t:ItemId Id="\(xmlAttribute(itemId))"/></m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization
    )
    guard
      let item = document.descendants.first(where: Self.isItemNode),
      let itemClass = item.child(named: "ItemClass")?.text.nonEmpty
    else { throw EWSServiceError.invalidResponse }
    return itemClass
  }

  func refreshMessageIdentities(
    _ messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage] {
    let refreshed = try await refreshMessageIdentitiesAllowingMissing(
      messages,
      authorization: authorization
    )
    guard refreshed.allSatisfy({ $0 != nil }) else {
      throw EWSServiceError.response(code: "ErrorItemNotFound", message: "Item not found")
    }
    return refreshed.compactMap { $0 }
  }

  func refreshMessageIdentitiesAllowingMissing(
    _ messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSProviderMessage?] {
    guard !messages.isEmpty else { return [] }
    let itemIds = messages.map {
      #"<t:ItemId Id="\#(xmlAttribute($0.itemId))"/>"#
    }.joined()
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>
        <m:ItemIds>\(itemIds)</m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization,
      allowsMixedResponseCodes: true
    )
    let responses = document.descendants.filter { $0.localName == "GetItemResponseMessage" }
    guard responses.count == messages.count else {
      throw EWSServiceError.invalidResponse
    }
    return try zip(messages, responses).map { message, response in
      guard let responseCode = response.child(named: "ResponseCode") else {
        throw EWSServiceError.invalidResponse
      }
      if responseCode.text == "ErrorItemNotFound" { return nil }
      guard responseCode.text == "NoError" else {
        throw EWSServiceError.response(
          code: responseCode.text,
          message: response.child(named: "MessageText")?.text ?? ""
        )
      }
      guard
        let refreshedId = response.descendants.first(where: { $0.localName == "ItemId" }),
        let itemId = refreshedId.attributes["Id"],
        let changeKey = refreshedId.attributes["ChangeKey"]
      else {
        throw EWSServiceError.invalidResponse
      }
      var refreshed = message
      refreshed.itemId = itemId
      refreshed.changeKey = changeKey
      return refreshed
    }
  }

  func recoverMessageIdentity(
    _ message: EWSProviderMessage,
    folders: [EWSFolder],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSMovedItemIdentity {
    guard message.stableProviderId != message.itemId else {
      throw EWSServiceError.invalidResponse
    }
    let searchableFolders = folders.filter {
      $0.isOutbox != true && $0.isSearchFolder != true && $0.isMailFolder
    }
    guard !searchableFolders.isEmpty else { throw EWSServiceError.invalidResponse }
    let parentFolderIds = searchableFolders.map {
      #"<t:FolderId Id="\#(xmlAttribute($0.id))"/>"#
    }.joined()
    let document = try await request(
      """
      <m:FindItem Traversal="Shallow">
        <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="item:ParentFolderId"/>
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:IndexedPageItemView MaxEntriesReturned="2" Offset="0" BasePoint="Beginning"/>
        <m:Restriction><t:IsEqualTo>
          <t:ExtendedFieldURI PropertyTag="0x300B" PropertyType="Binary"/>
          <t:FieldURIOrConstant><t:Constant
            Value="\(xmlAttribute(message.stableProviderId))"/>
          </t:FieldURIOrConstant>
        </t:IsEqualTo></m:Restriction>
        <m:ParentFolderIds>\(parentFolderIds)</m:ParentFolderIds>
      </m:FindItem>
      """,
      authorization: authorization
    )
    let matches = document.descendants.filter(Self.isItemNode)
    guard !matches.isEmpty else {
      throw EWSServiceError.response(code: "ErrorItemNotFound", message: "Item not found")
    }
    guard
      matches.count == 1,
      let itemId = matches[0].child(named: "ItemId"),
      let id = itemId.attributes["Id"],
      let changeKey = itemId.attributes["ChangeKey"],
      let parentFolderId = matches[0].child(named: "ParentFolderId")?.attributes["Id"]
    else { throw EWSServiceError.invalidResponse }
    return EWSMovedItemIdentity(
      changeKey: changeKey,
      destinationFolderId: parentFolderId,
      itemId: id,
      stableProviderId: message.stableProviderId
    )
  }

  // swiftlint:disable function_body_length cyclomatic_complexity
  /// Applies one mailbox mutation after the shared pending-action queue hands it off.
  func perform(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity] {
    guard !messages.isEmpty else { return [] }
    switch action {
    case .markRead, .markUnread:
      return try await updateBoolean(
        fieldURI: "message:IsRead",
        element: "t:IsRead",
        value: action == .markRead,
        messages: messages,
        authorization: authorization
      )
    case .star, .unstar:
      return try await updateFlag(
        flagged: action == .star,
        messages: messages,
        authorization: authorization
      )
    case .archive:
      var identities: [EWSMovedItemIdentity] = []
      var didApplyAnyGroup = false
      for (sourceFolderId, sourceMessages) in Dictionary(
        grouping: messages,
        by: \.parentFolderId
      ) {
        do {
          let document = try await request(
            """
            <m:ArchiveItem>
              <m:ArchiveSourceFolderId><t:FolderId Id="\(xmlAttribute(sourceFolderId))"/>
              </m:ArchiveSourceFolderId>
              <m:ItemIds>\(itemIds(sourceMessages))</m:ItemIds>
            </m:ArchiveItem>
            """,
            authorization: authorization
          )
          didApplyAnyGroup = true
          let returnedItemIds = document.descendants.filter { $0.localName == "ItemId" }
          if returnedItemIds.count == sourceMessages.count {
            identities += try await resolveArchivedIdentities(
              sourceMessages,
              itemIds: returnedItemIds,
              authorization: authorization
            )
          } else {
            for message in sourceMessages {
              identities.append(
                try await resolveArchivedIdentity(for: message, authorization: authorization)
              )
            }
          }
        } catch {
          if didApplyAnyGroup { throw EWSAmbiguousProviderActionError() }
          throw error
        }
      }
      return identities
    case .delete, .move, .notSpam, .restore, .spam:
      let destination =
        targetFolderId.map { #"<t:FolderId Id="\#(xmlAttribute($0))"/>"# }
        ?? distinguishedDestination(action).map {
          """
          <t:DistinguishedFolderId Id="\($0)">\(mailboxXML(authorization))
          </t:DistinguishedFolderId>
          """
        }
      guard let destination else {
        throw MailboxConnectionAdapterError.providerMailboxTargetRequired
      }
      let document = try await request(
        """
        <m:MoveItem>
          <m:ToFolderId>\(destination)</m:ToFolderId>
          <m:ItemIds>\(itemIds(messages))</m:ItemIds>
        </m:MoveItem>
        """,
        authorization: authorization
      )
      let itemIds = document.descendants.filter { $0.localName == "ItemId" }
      guard itemIds.count == messages.count else {
        throw EWSServiceError.invalidResponse
      }
      return try movedIdentities(messages, itemIds: itemIds)
    }
  }
  // swiftlint:enable function_body_length cyclomatic_complexity

  /// Sends one message and saves the provider copy in Sent Items.
  func send(
    _ message: OutgoingMessage,
    authorization: DeviceLocalEWSAuthorization
  ) async throws {
    let recipients = recipientAddresses(message.recipient).map {
      "<t:Mailbox><t:EmailAddress>\(xml($0))</t:EmailAddress></t:Mailbox>"
    }.joined()
    let ccRecipients = recipientAddresses(message.ccRecipients ?? "").map {
      "<t:Mailbox><t:EmailAddress>\(xml($0))</t:EmailAddress></t:Mailbox>"
    }.joined()
    let bccRecipients = recipientAddresses(message.bccRecipients ?? "").map {
      "<t:Mailbox><t:EmailAddress>\(xml($0))</t:EmailAddress></t:Mailbox>"
    }.joined()
    let bodyType = message.htmlBody == nil ? "Text" : "HTML"
    let body = message.htmlBody ?? message.body
    var headers = ""
    if let messageId = message.rfcMessageId {
      headers += outboxIdProperty(messageId)
    }
    if let inReplyTo = message.inReplyTo {
      headers += extendedHeader(name: "In-Reply-To", value: inReplyTo)
      headers += extendedHeader(name: "References", value: inReplyTo)
    }
    let fromMailbox =
      message.fromAddress.map {
        "<t:Mailbox><t:EmailAddress>\(xml($0))</t:EmailAddress></t:Mailbox>"
      } ?? mailboxXML(authorization)
    _ = try await request(
      """
      <m:CreateItem MessageDisposition="SendAndSaveCopy">
        <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems">
          \(mailboxXML(authorization))
        </t:DistinguishedFolderId></m:SavedItemFolderId>
        <m:Items>
          <t:Message>
            <t:Subject>\(xml(message.subject))</t:Subject>
            <t:Body BodyType="\(bodyType)">\(xml(body))</t:Body>
            <t:IsReadReceiptRequested>\(message.requestsReadReceipt == true)</t:IsReadReceiptRequested>
            \(headers)
            <t:ToRecipients>\(recipients)</t:ToRecipients>
            \(ccRecipients.isEmpty ? "" : "<t:CcRecipients>\(ccRecipients)</t:CcRecipients>")
            \(bccRecipients.isEmpty ? "" : "<t:BccRecipients>\(bccRecipients)</t:BccRecipients>")
            <t:From>\(fromMailbox)</t:From>
          </t:Message>
        </m:Items>
      </m:CreateItem>
      """,
      authorization: authorization
    )
  }

  /// Finds an Outbox idempotency message identifier in Sent Items.
  func deliveryStatus(
    rfcMessageId: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> MailboxDeliveryStatus {
    let document = try await request(
      """
      <m:FindItem Traversal="Shallow">
        <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>
        <m:IndexedPageItemView MaxEntriesReturned="1" Offset="0" BasePoint="Beginning"/>
        <m:Restriction><t:IsEqualTo>
          <t:ExtendedFieldURI PropertySetId="7a86cc5b-a9c6-47f6-980b-7e684d92c4af"
            PropertyName="UnwiredOutboxId" PropertyType="String"/>
          <t:FieldURIOrConstant><t:Constant Value="\(xmlAttribute(rfcMessageId))"/>
          </t:FieldURIOrConstant>
        </t:IsEqualTo></m:Restriction>
        <m:ParentFolderIds><t:DistinguishedFolderId Id="sentitems">
          \(mailboxXML(authorization))
        </t:DistinguishedFolderId></m:ParentFolderIds>
      </m:FindItem>
      """,
      authorization: authorization
    )
    return document.descendants.contains(where: Self.isItemNode) ? .sent : .unknown
  }

  // swiftlint:disable:next function_body_length cyclomatic_complexity
  private func request(
    _ operation: String,
    authorization: DeviceLocalEWSAuthorization,
    allowsMixedResponseCodes: Bool = false,
    maximumResponseByteCount: Int? = nil
  ) async throws -> EWSXMLNode {
    var request = URLRequest(url: authorization.definition.endpoint)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    let operationName = operation.trimmingCharacters(in: .whitespacesAndNewlines)
      .dropFirst(3)
      .prefix { !$0.isWhitespace && $0 != ">" }
    request.setValue(
      "http://schemas.microsoft.com/exchange/services/2006/messages/\(operationName)",
      forHTTPHeaderField: "SOAPAction"
    )
    switch authorization.definition.authorizationMethod {
    case .oauth:
      request.setValue("Bearer \(authorization.credential)", forHTTPHeaderField: "Authorization")
    case .appPassword, .password:
      break
    }
    request.httpBody = Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
        <s:Header><t:RequestServerVersion Version="\(authorization.definition.serverVersion.requestVersion)"/>
        </s:Header><s:Body>\(operation)</s:Body>
      </s:Envelope>
      """.utf8
    )
    let delegate = EWSRequestAuthenticationDelegate(authorization: authorization)
    let dataAndResponse: (Data, URLResponse)
    if let maximumResponseByteCount {
      let boundedDelegate = EWSBoundedResponseDataDelegate(
        authenticationDelegate: delegate,
        maximumByteCount: maximumResponseByteCount
      )
      do {
        dataAndResponse = try await boundedDelegate.load(
          request,
          configuration: session.configuration
        )
      } catch {
        throw mappedEWSRequestError(
          error,
          authenticationWasRejected: delegate.authenticationWasRejected
        )
      }
    } else {
      dataAndResponse = try await data(for: request, delegate: delegate)
    }
    let (data, response) = dataAndResponse
    guard let httpResponse = response as? HTTPURLResponse else {
      throw EWSServiceError.invalidResponse
    }
    if let responseURL = httpResponse.url {
      _ = try EWSConnectionDefinition.validatedEndpoint(responseURL.absoluteString)
    }
    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
      throw EWSServiceError.authenticationRejected
    }
    guard 200..<300 ~= httpResponse.statusCode else {
      throw EWSServiceError.response(
        code: "HTTP \(httpResponse.statusCode)",
        message: "The Exchange server returned HTTP \(httpResponse.statusCode)."
      )
    }
    let document: EWSXMLNode
    do {
      document = try EWSXMLParser.parse(data)
    } catch {
      throw EWSServiceError.invalidResponse
    }
    let responseCodes = document.descendants.filter { $0.localName == "ResponseCode" }
    guard !responseCodes.isEmpty else {
      throw EWSServiceError.invalidResponse
    }
    if !allowsMixedResponseCodes,
      responseCodes.contains(where: { $0.text == "NoError" }),
      responseCodes.contains(where: { $0.text != "NoError" })
    {
      throw EWSServiceError.invalidResponse
    }
    if !allowsMixedResponseCodes,
      let failure = responseCodes.first(where: { $0.text != "NoError" })
    {
      let message = failure.parent?.child(named: "MessageText")?.text ?? ""
      throw EWSServiceError.response(code: failure.text, message: message)
    }
    return document
  }

  private func attachmentDescriptor(_ node: EWSXMLNode) throws -> EWSAttachmentDescriptor {
    guard
      let providerAttachmentId = node.child(named: "AttachmentId")?.attributes["Id"]?.nonEmpty,
      let byteCount = node.child(named: "Size")?.text.nonEmpty.flatMap(Int.init),
      byteCount >= 0
    else { throw EWSServiceError.invalidResponse }
    let kind: EWSAttachmentDescriptor.Kind
    switch node.localName {
    case "FileAttachment":
      kind =
        node.child(named: "IsInline")?.text.lowercased() == "true"
          || node.child(named: "ContentId")?.text.nonEmpty != nil
        ? .inlineImage : .file
    case "ItemAttachment":
      kind = .unsupportedItem
    default:
      kind = .unsupported
    }
    return EWSAttachmentDescriptor(
      byteCount: byteCount,
      filename: node.child(named: "Name")?.text.nonEmpty ?? "Attachment",
      kind: kind,
      mimeType: node.child(named: "ContentType")?.text.nonEmpty ?? "application/octet-stream",
      providerAttachmentId: providerAttachmentId
    )
  }

  private func attachmentResponseByteLimit(contentByteCount: Int) throws -> Int {
    let (adjustedContentByteCount, adjustedOverflow) = contentByteCount.addingReportingOverflow(2)
    guard !adjustedOverflow else { throw MailboxMessageAttachmentError.invalidResponse }
    let encodedByteCount = adjustedContentByteCount / 3 * 4
    let (lineBreakByteCount, lineBreakOverflow) =
      (encodedByteCount / 76).multipliedReportingOverflow(by: 2)
    guard !lineBreakOverflow else { throw MailboxMessageAttachmentError.invalidResponse }
    let (wrappedEncodedByteCount, wrappedOverflow) =
      encodedByteCount.addingReportingOverflow(lineBreakByteCount)
    guard !wrappedOverflow else { throw MailboxMessageAttachmentError.invalidResponse }
    let (responseByteCount, responseOverflow) =
      wrappedEncodedByteCount.addingReportingOverflow(64 * 1_024)
    guard !responseOverflow else { throw MailboxMessageAttachmentError.invalidResponse }
    return responseByteCount
  }

  private static func isBase64OrWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 9, 10, 13, 32, 43, 47, 48...57, 61, 65...90, 97...122:
      true
    default:
      false
    }
  }

  private func data(
    for request: URLRequest,
    delegate: EWSRequestAuthenticationDelegate
  ) async throws -> (Data, URLResponse) {
    do {
      return try await session.data(for: request, delegate: delegate)
    } catch {
      throw mappedEWSRequestError(
        error,
        authenticationWasRejected: delegate.authenticationWasRejected
      )
    }
  }

  private func loadFolder(
    distinguishedId: String,
    role: EWSFolderRole?,
    isArchiveHierarchy: Bool? = nil,
    isTrashHierarchy: Bool? = nil,
    isOutbox: Bool? = nil,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSFolder? {
    let document = try await request(
      """
      <m:GetFolder>
        <m:FolderShape><t:BaseShape>Default</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="folder:FolderClass"/>
            <t:FieldURI FieldURI="folder:ParentFolderId"/>
          </t:AdditionalProperties>
        </m:FolderShape>
        <m:FolderIds><t:DistinguishedFolderId Id="\(distinguishedId)">
          \(mailboxXML(authorization))
        </t:DistinguishedFolderId></m:FolderIds>
      </m:GetFolder>
      """,
      authorization: authorization
    )
    guard let node = document.descendants.first(where: Self.isFolderNode),
      let value = folder(node)
    else { return nil }
    return EWSFolder(
      changeKey: value.changeKey,
      displayName: value.displayName,
      folderClass: value.folderClass,
      id: value.id,
      isArchiveHierarchy: isArchiveHierarchy,
      isOutbox: isOutbox,
      isSearchFolder: value.isSearchFolder,
      isSentHierarchy: role == .sent,
      isTrashHierarchy: isTrashHierarchy,
      parentFolderId: value.parentFolderId,
      role: role
    )
  }

  private func folder(_ node: EWSXMLNode) -> EWSFolder? {
    guard let idNode = node.child(named: "FolderId"),
      let id = idNode.attributes["Id"]
    else { return nil }
    return EWSFolder(
      changeKey: idNode.attributes["ChangeKey"],
      displayName: node.child(named: "DisplayName")?.text.nonEmpty ?? id,
      folderClass: node.child(named: "FolderClass")?.text.nonEmpty,
      id: id,
      isSearchFolder: node.localName == "SearchFolder",
      parentFolderId: node.child(named: "ParentFolderId")?.attributes["Id"],
      role: nil
    )
  }

  private func providerMessage(
    _ node: EWSXMLNode,
    defaultFolderId: String,
    prefersSentDate: Bool
  ) -> EWSProviderMessage? {
    guard let idNode = node.child(named: "ItemId"),
      let itemId = idNode.attributes["Id"]
    else { return nil }
    let internetMessageId = node.child(named: "InternetMessageId")?.text.nonEmpty
    let searchKey = node.children.first {
      guard $0.localName == "ExtendedProperty",
        let field = $0.child(named: "ExtendedFieldURI")
      else { return false }
      return field.attributes["PropertyTag"]?.caseInsensitiveCompare("0x300B") == .orderedSame
    }?.child(named: "Value")?.text.nonEmpty
    let isDraft = node.child(named: "IsDraft")?.text == "true"
    let dateText: String? =
      (isDraft ? node.child(named: "LastModifiedTime")?.text : nil)
      ?? (prefersSentDate ? node.child(named: "DateTimeSent")?.text : nil)
      ?? node.child(named: "DateTimeReceived")?.text
      ?? node.child(named: "DateTimeSent")?.text
      ?? node.child(named: "DateTimeCreated")?.text
    let date = dateText.flatMap(Self.date)
    let parentFolderId =
      node.child(named: "ParentFolderId")?.attributes["Id"] ?? defaultFolderId
    let stableProviderId = searchKey ?? itemId
    let calendarInvitation = Self.calendarInvitationDescriptor(
      node,
      providerMessageIdentity: stableProviderId
    )
    return EWSProviderMessage(
      bccRecipients: addresses(node.child(named: "BccRecipients")),
      calendarInvitation: calendarInvitation,
      ccRecipients: addresses(node.child(named: "CcRecipients")),
      changeKey: idNode.attributes["ChangeKey"] ?? "",
      conversationId: node.child(named: "ConversationId")?.attributes["Id"],
      from: formattedAddress(node.child(named: "From")?.child(named: "Mailbox")),
      hasAttachments: node.child(named: "HasAttachments")?.text == "true",
      internetMessageHeaders: unsubscribeHeaders(node),
      internetMessageId: internetMessageId,
      isDraft: isDraft,
      isFlagged: node.child(named: "Flag")?.child(named: "FlagStatus")?.text == "Flagged",
      isRead: node.child(named: "IsRead")?.text == "true",
      itemId: itemId,
      organizer: formattedAddress(node.child(named: "Organizer")?.child(named: "Mailbox")),
      parentFolderId: parentFolderId,
      receivedAtMilliseconds: Int64((date ?? .distantPast).timeIntervalSince1970 * 1_000),
      replyTo: addresses(node.child(named: "ReplyTo")),
      sender: formattedAddress(node.child(named: "Sender")?.child(named: "Mailbox")),
      stableProviderId: stableProviderId,
      subject: node.child(named: "Subject")?.text ?? "",
      summary: node.child(named: "Preview")?.text ?? "",
      toRecipients: addresses(node.child(named: "ToRecipients"))
    )
  }

  private static func calendarInvitationDescriptor(
    _ node: EWSXMLNode,
    providerMessageIdentity: String
  ) -> CalendarInvitationDescriptor? {
    guard meetingMethod(node) != nil else { return nil }
    return CalendarInvitationDescriptor(
      byteCount: 0,
      mimeType: EWSCalendarInvitationIdentity.meetingMessageMIMEType,
      providerAttachmentId: nil,
      providerMessageIdentity: providerMessageIdentity,
      providerPartId: EWSCalendarInvitationIdentity.meetingMessagePartId
    )
  }

  private func unsubscribeHeaders(_ node: EWSXMLNode) -> [EWSInternetMessageHeader]? {
    let names = ["List-ID", "List-Unsubscribe", "List-Unsubscribe-Post"]
    let headers = node.children.compactMap { property -> EWSInternetMessageHeader? in
      guard property.localName == "ExtendedProperty",
        let field = property.child(named: "ExtendedFieldURI"),
        field.attributes["DistinguishedPropertySetId"]?
          .caseInsensitiveCompare("InternetHeaders") == .orderedSame,
        let name = field.attributes["PropertyName"],
        names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
        let value = property.child(named: "Value")?.text.nonEmpty
      else { return nil }
      return EWSInternetMessageHeader(name: name, value: value)
    }
    return headers.isEmpty ? nil : headers
  }

  private static func date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func meetingMethod(_ node: EWSXMLNode) -> CalendarInvitationMethod? {
    switch node.localName {
    case "MeetingRequest":
      return .request
    case "MeetingCancellation":
      return .cancel
    default:
      let itemClass = node.child(named: "ItemClass")?.text.lowercased() ?? ""
      if itemClass.hasPrefix("ipm.schedule.meeting.request") { return .request }
      if itemClass.hasPrefix("ipm.schedule.meeting.canceled") { return .cancel }
      return nil
    }
  }

  private static func calendarInvitationCandidate(
    _ item: EWSXMLNode
  ) throws -> CalendarInvitationCandidate {
    guard var method = meetingMethod(item),
      let uid = item.child(named: "UID")?.text.nonEmpty,
      uid.utf8.count <= 998
    else { throw CalendarInvitationParsingError.invalidInvitation }
    if item.child(named: "IsCancelled")?.text.lowercased() == "true" {
      method = .cancel
    }
    let calendarItemType = item.child(named: "CalendarItemType")?.text.lowercased()
    guard item.child(named: "IsRecurring")?.text.lowercased() != "true",
      item.child(named: "RecurrenceId")?.text.nonEmpty == nil,
      calendarItemType == nil || calendarItemType == "single"
    else { throw CalendarInvitationParsingError.unsupportedRecurrence }
    let startDate = item.child(named: "Start")?.text.nonEmpty.flatMap(Self.date)
    let endDate = item.child(named: "End")?.text.nonEmpty.flatMap(Self.date)
    if method == .request {
      guard let startDate, let endDate, endDate > startDate else {
        throw CalendarInvitationParsingError.invalidInvitation
      }
    }
    let summary = item.child(named: "Subject")?.text.nonEmpty ?? "Calendar Event"
    guard summary.utf8.count <= 8_192 else {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    let sequence =
      item.child(named: "AppointmentSequenceNumber")?.text.nonEmpty
      .flatMap(Int.init) ?? 0
    let isAllDay = item.child(named: "IsAllDayEvent")?.text.lowercased() == "true"
    return CalendarInvitationCandidate(
      endDate: endDate,
      isAllDay: isAllDay,
      location: item.child(named: "Location")?.text.nonEmpty,
      method: method,
      notes: nil,
      sequence: sequence,
      startDate: startDate,
      summary: summary,
      timeZoneIdentifier: isAllDay ? nil : "UTC",
      uid: uid
    )
  }

  // swiftlint:disable:next function_body_length
  private func resolveArchivedIdentity(
    for message: EWSProviderMessage,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSMovedItemIdentity {
    let property: String
    let value: String
    if message.stableProviderId != message.itemId {
      property = #"<t:ExtendedFieldURI PropertyTag="0x300B" PropertyType="Binary"/>"#
      value = message.stableProviderId
    } else if let internetMessageId = message.internetMessageId {
      property = #"<t:FieldURI FieldURI="message:InternetMessageId"/>"#
      value = internetMessageId
    } else {
      throw EWSServiceError.invalidResponse
    }
    let archiveFolders = try await loadFolderHierarchy(
      rootDistinguishedId: "archivemsgfolderroot",
      isArchiveHierarchy: true,
      authorization: authorization
    )
    let physicalArchiveFolders = archiveFolders.filter { $0.isSearchFolder != true }
    guard !physicalArchiveFolders.isEmpty else { throw EWSServiceError.invalidResponse }
    let parentFolderIds = physicalArchiveFolders.map {
      #"<t:FolderId Id="\#(xmlAttribute($0.id))"/>"#
    }.joined()
    let document = try await request(
      """
      <m:FindItem Traversal="Shallow">
        <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="item:ParentFolderId"/>
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:Restriction><t:IsEqualTo>
          \(property)
          <t:FieldURIOrConstant><t:Constant
            Value="\(xmlAttribute(value))"/>
          </t:FieldURIOrConstant>
        </t:IsEqualTo></m:Restriction>
        <m:ParentFolderIds>\(parentFolderIds)</m:ParentFolderIds>
      </m:FindItem>
      """,
      authorization: authorization
    )
    let itemIds = document.descendants.filter { $0.localName == "ItemId" }
    let responseParentFolderIds = document.descendants.filter {
      $0.localName == "ParentFolderId"
    }
    guard
      itemIds.count == 1,
      responseParentFolderIds.count == 1,
      let id = itemIds[0].attributes["Id"],
      let changeKey = itemIds[0].attributes["ChangeKey"],
      let destinationFolderId = responseParentFolderIds[0].attributes["Id"]
    else { throw EWSServiceError.invalidResponse }
    return EWSMovedItemIdentity(
      changeKey: changeKey,
      destinationFolderId: destinationFolderId,
      itemId: id,
      stableProviderId: message.stableProviderId
    )
  }

  private func resolveArchivedIdentities(
    _ messages: [EWSProviderMessage],
    itemIds: [EWSXMLNode],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity] {
    let requestedItemIds = try itemIds.map {
      guard let id = $0.attributes["Id"] else { throw EWSServiceError.invalidResponse }
      return #"<t:ItemId Id="\#(xmlAttribute(id))"/>"#
    }.joined()
    let document = try await request(
      """
      <m:GetItem>
        <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="item:ParentFolderId"/>
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:ItemIds>\(requestedItemIds)</m:ItemIds>
      </m:GetItem>
      """,
      authorization: authorization
    )
    let responseItemIds = document.descendants.filter { $0.localName == "ItemId" }
    let destinationFolderIds = document.descendants.filter {
      $0.localName == "ParentFolderId"
    }
    guard
      responseItemIds.count == messages.count,
      destinationFolderIds.count == messages.count
    else { throw EWSServiceError.invalidResponse }
    return try zip(zip(messages, responseItemIds), destinationFolderIds).map { pair in
      let ((message, itemId), destinationFolderId) = pair
      guard
        let id = itemId.attributes["Id"],
        let changeKey = itemId.attributes["ChangeKey"],
        let destinationFolderId = destinationFolderId.attributes["Id"]
      else { throw EWSServiceError.invalidResponse }
      return EWSMovedItemIdentity(
        changeKey: changeKey,
        destinationFolderId: destinationFolderId,
        itemId: id,
        stableProviderId: message.stableProviderId
      )
    }
  }

  private func movedIdentities(
    _ messages: [EWSProviderMessage],
    itemIds: [EWSXMLNode]
  ) throws -> [EWSMovedItemIdentity] {
    try zip(messages, itemIds).map { message, itemId in
      guard
        let id = itemId.attributes["Id"],
        let changeKey = itemId.attributes["ChangeKey"]
      else { throw EWSServiceError.invalidResponse }
      return EWSMovedItemIdentity(
        changeKey: changeKey,
        itemId: id,
        stableProviderId: message.stableProviderId
      )
    }
  }

  private func updateBoolean(
    fieldURI: String,
    element: String,
    value: Bool,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity] {
    let changes = messages.map {
      """
      <t:ItemChange><t:ItemId Id="\(xmlAttribute($0.itemId))"
        ChangeKey="\(xmlAttribute($0.changeKey))"/><t:Updates><t:SetItemField>
        <t:FieldURI FieldURI="\(fieldURI)"/><t:Message><\(element)>\(value)</\(element)>
        </t:Message></t:SetItemField></t:Updates></t:ItemChange>
      """
    }.joined()
    return try updatedIdentities(
      try await updateItems(changes, authorization: authorization),
      messages: messages
    )
  }

  private func updateFlag(
    flagged: Bool,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSMovedItemIdentity] {
    let changes = messages.map {
      if flagged {
        return """
          <t:ItemChange><t:ItemId Id="\(xmlAttribute($0.itemId))"
            ChangeKey="\(xmlAttribute($0.changeKey))"/><t:Updates><t:SetItemField>
            <t:FieldURI FieldURI="item:Flag"/><t:Message><t:Flag><t:FlagStatus>Flagged</t:FlagStatus>
            </t:Flag></t:Message></t:SetItemField></t:Updates></t:ItemChange>
          """
      }
      return """
        <t:ItemChange><t:ItemId Id="\(xmlAttribute($0.itemId))"
          ChangeKey="\(xmlAttribute($0.changeKey))"/><t:Updates><t:DeleteItemField>
          <t:FieldURI FieldURI="item:Flag"/></t:DeleteItemField></t:Updates></t:ItemChange>
        """
    }.joined()
    return try updatedIdentities(
      try await updateItems(changes, authorization: authorization),
      messages: messages
    )
  }

  private func updateItems(
    _ changes: String,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSXMLNode {
    try await request(
      """
      <m:UpdateItem ConflictResolution="AutoResolve" MessageDisposition="SaveOnly"
        SendMeetingInvitationsOrCancellations="SendToNone">
        <m:ItemChanges>\(changes)</m:ItemChanges>
      </m:UpdateItem>
      """,
      authorization: authorization
    )
  }

  private func itemIds(_ messages: [EWSProviderMessage]) -> String {
    messages.map {
      #"<t:ItemId Id="\#(xmlAttribute($0.itemId))" ChangeKey="\#(xmlAttribute($0.changeKey))"/>"#
    }.joined()
  }

  private func updatedIdentities(
    _ document: EWSXMLNode,
    messages: [EWSProviderMessage]
  ) throws -> [EWSMovedItemIdentity] {
    let itemIds = document.descendants.filter { $0.localName == "ItemId" }
    guard itemIds.count == messages.count else {
      throw EWSServiceError.invalidResponse
    }
    return try zip(messages, itemIds).map { message, itemId in
      guard
        let id = itemId.attributes["Id"],
        let changeKey = itemId.attributes["ChangeKey"]
      else {
        throw EWSServiceError.invalidResponse
      }
      return EWSMovedItemIdentity(
        changeKey: changeKey,
        itemId: id,
        stableProviderId: message.stableProviderId
      )
    }
  }

  private func mailboxXML(_ authorization: DeviceLocalEWSAuthorization) -> String {
    """
    <t:Mailbox><t:EmailAddress>\(xml(authorization.definition.emailAddress))</t:EmailAddress>
    </t:Mailbox>
    """
  }

  private func extendedHeader(name: String, value: String) -> String {
    """
    <t:ExtendedProperty><t:ExtendedFieldURI DistinguishedPropertySetId="InternetHeaders"
      PropertyName="\(xmlAttribute(name))" PropertyType="String"/>
      <t:Value>\(xml(value))</t:Value></t:ExtendedProperty>
    """
  }

  private func outboxIdProperty(_ value: String) -> String {
    """
    <t:ExtendedProperty>
      <t:ExtendedFieldURI PropertySetId="7a86cc5b-a9c6-47f6-980b-7e684d92c4af"
        PropertyName="UnwiredOutboxId" PropertyType="String"/>
      <t:Value>\(xml(value))</t:Value>
    </t:ExtendedProperty>
    """
  }

  private func addresses(_ node: EWSXMLNode?) -> [String] {
    node?.children.filter { $0.localName == "Mailbox" }.compactMap(formattedAddress) ?? []
  }

  private func formattedAddress(_ mailbox: EWSXMLNode?) -> String? {
    guard let email = mailbox?.child(named: "EmailAddress")?.text.nonEmpty else { return nil }
    guard let name = mailbox?.child(named: "Name")?.text.nonEmpty else { return email }
    let escapedName =
      name
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escapedName)\" <\(email)>"
  }

  private func serverVersion(_ document: EWSXMLNode) throws -> EWSServerVersion {
    guard let info = document.firstDescendant(named: "ServerVersionInfo"),
      info.attributes["MajorVersion"].flatMap(Int.init) == 15
    else {
      throw EWSSetupError.unsupportedServerVersion
    }
    let version = info.attributes["Version"] ?? ""
    let minor = info.attributes["MinorVersion"].flatMap(Int.init) ?? 0
    guard minor < 20 else {
      throw EWSSetupError.onPremisesEndpointRequired
    }
    if minor == 0 {
      guard
        let majorBuild = info.attributes["MajorBuildNumber"].flatMap(Int.init),
        let minorBuild = info.attributes["MinorBuildNumber"].flatMap(Int.init),
        majorBuild > 847 || (majorBuild == 847 && minorBuild >= 32)
      else {
        throw EWSSetupError.unsupportedServerVersion
      }
    }
    if version.localizedCaseInsensitiveContains("2019") { return .exchange2019 }
    if version.localizedCaseInsensitiveContains("2016") { return .exchange2016 }
    if minor >= 2 { return .exchange2019 }
    if minor == 1 { return .exchange2016 }
    return .exchange2013SP1
  }

  private func distinguishedDestination(_ action: ProviderMailAction) -> String? {
    switch action {
    case .delete: return "deleteditems"
    case .spam: return "junkemail"
    case .notSpam, .restore: return "inbox"
    default: return nil
    }
  }

  private func recipientAddresses(_ value: String) -> [String] {
    mailboxValues(in: value).compactMap { mailbox in
      let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      guard
        let opening = trimmed.lastIndex(of: "<"),
        let closing = trimmed.lastIndex(of: ">"),
        opening < closing
      else { return trimmed }
      let address = trimmed[trimmed.index(after: opening)..<closing]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return address.isEmpty ? nil : address
    }
  }

  private func mailboxValues(in value: String) -> [String] {
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
      case "<":
        angleBracketDepth += 1
      case ">":
        angleBracketDepth = max(0, angleBracketDepth - 1)
      case let delimiter
      where (delimiter == "," || delimiter == ";") && !isQuoted && angleBracketDepth == 0:
        mailboxes.append(mailbox)
        mailbox = ""
        continue
      default:
        break
      }
      mailbox.append(character)
    }
    mailboxes.append(mailbox)
    return mailboxes
  }

  private static func distinguishedFolderId(_ role: EWSFolderRole) -> String? {
    switch role {
    case .archive: return "archiveinbox"
    case .drafts: return "drafts"
    case .inbox: return "inbox"
    case .sent: return "sentitems"
    case .spam: return "junkemail"
    case .trash: return "deleteditems"
    }
  }

  private static func isFolderNode(_ node: EWSXMLNode) -> Bool {
    ["Folder", "SearchFolder"].contains(node.localName)
  }

  private static func isItemNode(_ node: EWSXMLNode) -> Bool {
    [
      "Message", "MeetingCancellation", "MeetingMessage", "MeetingRequest",
      "MeetingResponse", "PostItem",
    ].contains(node.localName)
  }

  private func xml(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private func xmlAttribute(_ value: String) -> String {
    xml(value)
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

private final class EWSXMLNode {
  let attributes: [String: String]
  var children: [EWSXMLNode] = []
  let localName: String
  weak var parent: EWSXMLNode?
  var text = ""

  init(name: String, attributes: [String: String]) {
    localName = name.split(separator: ":").last.map(String.init) ?? name
    self.attributes = Dictionary(
      attributes.map {
        ($0.key.split(separator: ":").last.map(String.init) ?? $0.key, $0.value)
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  var descendants: [EWSXMLNode] {
    var result: [EWSXMLNode] = []
    var pending = Array(children.reversed())
    while let node = pending.popLast() {
      result.append(node)
      pending.append(contentsOf: node.children.reversed())
    }
    return result
  }

  func child(named name: String) -> EWSXMLNode? {
    children.first { $0.localName == name }
  }

  func firstDescendant(named name: String) -> EWSXMLNode? {
    descendants.first { $0.localName == name }
  }
}

func shouldUseEWSPasswordCredential(
  authenticationMethod: String,
  challengeMatchesEndpoint: Bool,
  previousFailureCount: Int
) -> Bool {
  let passwordMethods = [
    NSURLAuthenticationMethodDefault,
    NSURLAuthenticationMethodHTTPBasic,
    NSURLAuthenticationMethodHTTPDigest,
    NSURLAuthenticationMethodNegotiate,
    NSURLAuthenticationMethodNTLM,
  ]
  return passwordMethods.contains(authenticationMethod)
    && challengeMatchesEndpoint
    && previousFailureCount == 0
}

func mappedEWSRequestError(
  _ error: Error,
  authenticationWasRejected: Bool
) -> Error {
  authenticationWasRejected ? EWSServiceError.authenticationRejected : error
}

private final class EWSRequestAuthenticationDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let credential: URLCredential?
  private let endpoint: URL
  private let lock = NSLock()
  private var rejectedAuthentication = false

  var authenticationWasRejected: Bool {
    lock.withLock { rejectedAuthentication }
  }

  init(authorization: DeviceLocalEWSAuthorization) {
    endpoint = authorization.definition.endpoint
    switch authorization.definition.authorizationMethod {
    case .appPassword, .password:
      credential = URLCredential(
        user: authorization.definition.username,
        password: authorization.credential,
        persistence: .none
      )
    case .oauth:
      credential = nil
    }
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let method = challenge.protectionSpace.authenticationMethod
    let protectionSpace = challenge.protectionSpace
    let endpointPort = endpoint.port ?? (endpoint.scheme?.lowercased() == "https" ? 443 : 0)
    let challengeMatchesEndpoint =
      protectionSpace.protocol?.lowercased() == endpoint.scheme?.lowercased()
      && protectionSpace.host.lowercased() == endpoint.host?.lowercased()
      && protectionSpace.port == endpointPort
    if shouldUseEWSPasswordCredential(
      authenticationMethod: method,
      challengeMatchesEndpoint: challengeMatchesEndpoint,
      previousFailureCount: challenge.previousFailureCount
    ), let credential {
      completionHandler(.useCredential, credential)
    } else if challenge.previousFailureCount > 0,
      shouldUseEWSPasswordCredential(
        authenticationMethod: method,
        challengeMatchesEndpoint: challengeMatchesEndpoint,
        previousFailureCount: 0
      ),
      credential != nil
    {
      lock.withLock {
        rejectedAuthentication = true
      }
      completionHandler(.cancelAuthenticationChallenge, nil)
    } else {
      completionHandler(.performDefaultHandling, nil)
    }
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let redirectURL = request.url,
      EWSConnectionDefinition.hasSameOrigin(redirectURL, as: endpoint)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

private final class EWSBoundedResponseDataDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let authenticationDelegate: EWSRequestAuthenticationDelegate
  private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
  private var data = Data()
  private var isCancelled = false
  private let lock = NSLock()
  private let maximumByteCount: Int
  private var response: URLResponse?
  private var session: URLSession?
  private var task: URLSessionDataTask?

  init(
    authenticationDelegate: EWSRequestAuthenticationDelegate,
    maximumByteCount: Int
  ) {
    self.authenticationDelegate = authenticationDelegate
    self.maximumByteCount = maximumByteCount
  }

  func load(
    _ request: URLRequest,
    configuration: URLSessionConfiguration
  ) async throws -> (Data, URLResponse) {
    let result: (Data, URLResponse) = try await withTaskCancellationHandler {
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
    return result
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    authenticationDelegate.urlSession(
      session,
      task: task,
      didReceive: challenge,
      completionHandler: completionHandler
    )
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    authenticationDelegate.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: request,
      completionHandler: completionHandler
    )
  }

  func urlSession(
    _: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let declaredByteCount = response.expectedContentLength
    guard declaredByteCount < 0 || declaredByteCount <= Int64(maximumByteCount) else {
      completionHandler(.cancel)
      dataTask.cancel()
      finish(.failure(MailboxMessageAttachmentError.invalidResponse))
      return
    }
    lock.withLock {
      self.response = response
      if declaredByteCount > 0 {
        data.reserveCapacity(Int(declaredByteCount))
      }
    }
    completionHandler(.allow)
  }

  func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    let exceedsLimit = lock.withLock {
      let (receivedByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
      guard !overflow, receivedByteCount <= maximumByteCount else { return true }
      data.append(chunk)
      return false
    }
    if exceedsLimit {
      dataTask.cancel()
      finish(.failure(MailboxMessageAttachmentError.invalidResponse))
    }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    let state = lock.withLock { (isCancelled, data, response) }
    if let error {
      if state.0 || (error as? URLError)?.code == .cancelled {
        finish(.failure(CancellationError()))
      } else {
        finish(.failure(error))
      }
    } else if let response = state.2 {
      finish(.success((state.1, response)))
    } else {
      finish(.failure(EWSServiceError.invalidResponse))
    }
  }

  private func cancel() {
    let task = lock.withLock {
      isCancelled = true
      return self.task
    }
    task?.cancel()
  }

  private func finish(_ result: Result<(Data, URLResponse), Error>) {
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

private final class EWSXMLParser: NSObject, XMLParserDelegate {
  private var stack: [EWSXMLNode] = []
  private var root: EWSXMLNode?

  static func parse(_ data: Data) throws -> EWSXMLNode {
    let delegate = EWSXMLParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), let root = delegate.root else {
      throw parser.parserError ?? EWSServiceError.invalidResponse
    }
    return root
  }

  func parser(
    _: XMLParser,
    didStartElement elementName: String,
    namespaceURI _: String?,
    qualifiedName _: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let node = EWSXMLNode(name: elementName, attributes: attributeDict)
    node.parent = stack.last
    stack.last?.children.append(node)
    if root == nil { root = node }
    stack.append(node)
  }

  func parser(_: XMLParser, foundCharacters string: String) {
    stack.last?.text += string
  }

  func parser(
    _: XMLParser,
    didEndElement _: String,
    namespaceURI _: String?,
    qualifiedName _: String?
  ) {
    _ = stack.popLast()
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
