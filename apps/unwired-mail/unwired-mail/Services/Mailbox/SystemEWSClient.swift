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
}

/// Sends mailbox-targeted SOAP requests directly to an on-premises Exchange server.
///
/// Example:
/// ```swift
/// let account = try await SystemEWSClient().verify(authorization)
/// ```
struct SystemEWSClient: EWSClient {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  /// Verifies mailbox identity and the supported on-premises server version.
  func verify(_ authorization: DeviceLocalEWSAuthorization) async throws -> EWSAccount {
    let document = try await request(
      """
      <m:ResolveNames ReturnFullContactData="false" SearchScope="ActiveDirectory">
        <m:UnresolvedEntry>\(xml(authorization.definition.emailAddress))</m:UnresolvedEntry>
      </m:ResolveNames>
      """,
      authorization: authorization
    )
    let mailbox = document.firstDescendant(named: "Mailbox")
    let primaryEmail =
      mailbox?.child(named: "EmailAddress")?.text.nonEmpty
      ?? authorization.definition.emailAddress
    let displayName = mailbox?.child(named: "Name")?.text.nonEmpty ?? primaryEmail
    guard
      try await loadFolder(
        distinguishedId: "inbox",
        role: .inbox,
        authorization: authorization
      ) != nil
    else {
      throw EWSSetupError.invalidMailboxIdentity
    }
    return EWSAccount(
      displayName: displayName,
      primaryEmailAddress: primaryEmail,
      serverVersion: try serverVersion(document)
    )
  }

  /// Loads provider folders and resolves Exchange distinguished folder roles.
  func loadFolders(
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> [EWSFolder] {
    let pageSize = 100
    var offset = 0
    var folders: [EWSFolder] = []
    while true {
      let document = try await loadFolderPage(
        offset: offset,
        pageSize: pageSize,
        authorization: authorization
      )
      folders += document.descendants.filter(Self.isFolderNode).compactMap(folder)
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
    for role in EWSFolderRole.allCases {
      guard let distinguished = Self.distinguishedFolderId(role) else { continue }
      let resolved: EWSFolder?
      do {
        resolved = try await loadFolder(
          distinguishedId: distinguished,
          role: role,
          authorization: authorization
        )
      } catch EWSServiceError.response(let code, _)
        where ["ErrorFolderNotFound", "ErrorMailboxStoreUnavailable"].contains(code)
      {
        continue
      }
      guard let resolved else { continue }
      if let index = folders.firstIndex(where: { $0.id == resolved.id }) {
        folders[index] = EWSFolder(
          changeKey: folders[index].changeKey,
          displayName: folders[index].displayName,
          id: folders[index].id,
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

  private func loadFolderPage(
    offset: Int,
    pageSize: Int,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSXMLNode {
    try await request(
      """
      <m:FindFolder Traversal="Deep">
        <m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape>
        <m:IndexedPageFolderView MaxEntriesReturned="\(pageSize)" Offset="\(offset)"
          BasePoint="Beginning"/>
        <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot">
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
    let document = try await request(
      """
      <m:FindItem Traversal="Shallow">
        <m:ItemShape>
          <t:BaseShape>Default</t:BaseShape>
          <t:AdditionalProperties>
            <t:FieldURI FieldURI="message:InternetMessageId"/>
            <t:FieldURI FieldURI="item:ParentFolderId"/>
            <t:FieldURI FieldURI="item:ConversationId"/>
            <t:FieldURI FieldURI="item:DateTimeReceived"/>
            <t:FieldURI FieldURI="item:DisplayCc"/>
            <t:FieldURI FieldURI="message:From"/>
            <t:FieldURI FieldURI="item:IsDraft"/>
            <t:FieldURI FieldURI="message:IsRead"/>
            <t:FieldURI FieldURI="message:ReplyTo"/>
            <t:FieldURI FieldURI="message:ToRecipients"/>
            <t:FieldURI FieldURI="message:CcRecipients"/>
            <t:FieldURI FieldURI="message:BccRecipients"/>
            <t:FieldURI FieldURI="item:Preview"/>
            <t:FieldURI FieldURI="item:Flag"/>
            <t:ExtendedFieldURI PropertyTag="0x300B" PropertyType="Binary"/>
          </t:AdditionalProperties>
        </m:ItemShape>
        <m:IndexedPageItemView MaxEntriesReturned="\(pageSize)" Offset="\(offset)"
          BasePoint="Beginning"/>
        <m:SortOrder><t:FieldOrder Order="Descending">
          <t:FieldURI FieldURI="item:DateTimeReceived"/>
        </t:FieldOrder></m:SortOrder>
        <m:ParentFolderIds><t:FolderId Id="\(xmlAttribute(folder.id))"/></m:ParentFolderIds>
      </m:FindItem>
      """,
      authorization: authorization
    )
    let rootFolder = document.firstDescendant(named: "RootFolder")
    let includesLast = rootFolder?.attributes["IncludesLastItemInRange"] == "true"
    let nextOffset =
      includesLast ? nil : rootFolder?.attributes["IndexedPagingOffset"].flatMap(Int.init)
    let items = document.descendants.filter(Self.isItemNode).compactMap {
      providerMessage($0, defaultFolderId: folder.id)
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
    guard let body = document.firstDescendant(named: "Body") else {
      throw EWSServiceError.invalidResponse
    }
    return body.text
  }

  /// Applies one mailbox mutation after the shared pending-action queue hands it off.
  func perform(
    _ action: ProviderMailAction,
    targetFolderId: String?,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws {
    guard !messages.isEmpty else { return }
    switch action {
    case .markRead, .markUnread:
      try await updateBoolean(
        fieldURI: "message:IsRead",
        element: "t:IsRead",
        value: action == .markRead,
        messages: messages,
        authorization: authorization
      )
    case .star, .unstar:
      try await updateFlag(
        flagged: action == .star,
        messages: messages,
        authorization: authorization
      )
    case .delete:
      _ = try await request(
        """
        <m:DeleteItem DeleteType="MoveToDeletedItems" SendMeetingCancellations="SendToNone">
          <m:ItemIds>\(itemIds(messages))</m:ItemIds>
        </m:DeleteItem>
        """,
        authorization: authorization
      )
    case .archive, .move, .notSpam, .restore, .spam:
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
      _ = try await request(
        """
        <m:MoveItem>
          <m:ToFolderId>\(destination)</m:ToFolderId>
          <m:ItemIds>\(itemIds(messages))</m:ItemIds>
        </m:MoveItem>
        """,
        authorization: authorization
      )
    }
  }

  /// Sends one message and saves the provider copy in Sent Items.
  func send(
    _ message: OutgoingMessage,
    authorization: DeviceLocalEWSAuthorization
  ) async throws {
    var headers = ""
    if let messageId = message.rfcMessageId {
      headers += extendedHeader(name: "Message-ID", value: messageId)
    }
    if let inReplyTo = message.inReplyTo {
      headers += extendedHeader(name: "In-Reply-To", value: inReplyTo)
      headers += extendedHeader(name: "References", value: inReplyTo)
    }
    _ = try await request(
      """
      <m:CreateItem MessageDisposition="SendAndSaveCopy">
        <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems">
          \(mailboxXML(authorization))
        </t:DistinguishedFolderId></m:SavedItemFolderId>
        <m:Items>
          <t:Message>
            <t:Subject>\(xml(message.subject))</t:Subject>
            <t:Body BodyType="Text">\(xml(message.body))</t:Body>
            \(headers)
            <t:ToRecipients><t:Mailbox><t:EmailAddress>\(xml(message.recipient))</t:EmailAddress>
            </t:Mailbox></t:ToRecipients>
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
        <m:Restriction><t:IsEqualTo>
          <t:FieldURI FieldURI="message:InternetMessageId"/>
          <t:FieldURIOrConstant><t:Constant Value="\(xmlAttribute(rfcMessageId))"/>
          </t:FieldURIOrConstant>
        </t:IsEqualTo></m:Restriction>
        <m:IndexedPageItemView MaxEntriesReturned="1" Offset="0" BasePoint="Beginning"/>
        <m:ParentFolderIds><t:DistinguishedFolderId Id="sentitems">
          \(mailboxXML(authorization))
        </t:DistinguishedFolderId></m:ParentFolderIds>
      </m:FindItem>
      """,
      authorization: authorization
    )
    return document.descendants.contains(where: Self.isItemNode) ? .sent : .unknown
  }

  // swiftlint:disable:next function_body_length
  private func request(
    _ operation: String,
    authorization: DeviceLocalEWSAuthorization
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
      let value = Data(
        "\(authorization.definition.username):\(authorization.credential)".utf8
      ).base64EncodedString()
      request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
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
    let (data, response) = try await session.data(for: request, delegate: delegate)
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
        message: String(bytes: data, encoding: .utf8) ?? ""
      )
    }
    let document: EWSXMLNode
    do {
      document = try EWSXMLParser.parse(data)
    } catch {
      throw EWSServiceError.invalidResponse
    }
    if let failure = document.descendants.first(where: {
      $0.localName == "ResponseCode" && $0.text != "NoError"
    }) {
      let message = failure.parent?.child(named: "MessageText")?.text ?? ""
      throw EWSServiceError.response(code: failure.text, message: message)
    }
    return document
  }

  private func loadFolder(
    distinguishedId: String,
    role: EWSFolderRole,
    authorization: DeviceLocalEWSAuthorization
  ) async throws -> EWSFolder? {
    let document = try await request(
      """
      <m:GetFolder>
        <m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape>
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
      id: value.id,
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
      id: id,
      role: nil
    )
  }

  private func providerMessage(
    _ node: EWSXMLNode,
    defaultFolderId: String
  ) -> EWSProviderMessage? {
    guard let idNode = node.child(named: "ItemId"),
      let itemId = idNode.attributes["Id"]
    else { return nil }
    let internetMessageId = node.child(named: "InternetMessageId")?.text.nonEmpty
    let searchKey = node.children.first(where: { $0.localName == "ExtendedProperty" })?
      .child(named: "Value")?.text.nonEmpty
    let dateText: String? = node.child(named: "DateTimeReceived")?.text
    let date = dateText.flatMap { ISO8601DateFormatter().date(from: $0) }
    let parentFolderId =
      node.child(named: "ParentFolderId")?.attributes["Id"] ?? defaultFolderId
    return EWSProviderMessage(
      bccRecipients: addresses(node.child(named: "BccRecipients")),
      ccRecipients: addresses(node.child(named: "CcRecipients")),
      changeKey: idNode.attributes["ChangeKey"] ?? "",
      conversationId: node.child(named: "ConversationId")?.attributes["Id"],
      from: formattedAddress(node.child(named: "From")?.child(named: "Mailbox")),
      internetMessageId: internetMessageId,
      isDraft: node.child(named: "IsDraft")?.text == "true",
      isFlagged: node.child(named: "Flag")?.child(named: "FlagStatus")?.text == "Flagged",
      isRead: node.child(named: "IsRead")?.text == "true",
      itemId: itemId,
      parentFolderId: parentFolderId,
      receivedAtMilliseconds: Int64((date ?? .distantPast).timeIntervalSince1970 * 1_000),
      replyTo: addresses(node.child(named: "ReplyTo")),
      stableProviderId: searchKey ?? internetMessageId ?? itemId,
      subject: node.child(named: "Subject")?.text ?? "",
      summary: node.child(named: "Preview")?.text ?? "",
      toRecipients: addresses(node.child(named: "ToRecipients"))
    )
  }

  private func updateBoolean(
    fieldURI: String,
    element: String,
    value: Bool,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws {
    let changes = messages.map {
      """
      <t:ItemChange><t:ItemId Id="\(xmlAttribute($0.itemId))"
        ChangeKey="\(xmlAttribute($0.changeKey))"/><t:Updates><t:SetItemField>
        <t:FieldURI FieldURI="\(fieldURI)"/><t:Message><\(element)>\(value)</\(element)>
        </t:Message></t:SetItemField></t:Updates></t:ItemChange>
      """
    }.joined()
    _ = try await updateItems(changes, authorization: authorization)
  }

  private func updateFlag(
    flagged: Bool,
    messages: [EWSProviderMessage],
    authorization: DeviceLocalEWSAuthorization
  ) async throws {
    let status = flagged ? "Flagged" : "NotFlagged"
    let changes = messages.map {
      """
      <t:ItemChange><t:ItemId Id="\(xmlAttribute($0.itemId))"
        ChangeKey="\(xmlAttribute($0.changeKey))"/><t:Updates><t:SetItemField>
        <t:FieldURI FieldURI="item:Flag"/><t:Message><t:Flag><t:FlagStatus>\(status)</t:FlagStatus>
        </t:Flag></t:Message></t:SetItemField></t:Updates></t:ItemChange>
      """
    }.joined()
    _ = try await updateItems(changes, authorization: authorization)
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

  private func addresses(_ node: EWSXMLNode?) -> [String] {
    node?.children.filter { $0.localName == "Mailbox" }.compactMap(formattedAddress) ?? []
  }

  private func formattedAddress(_ mailbox: EWSXMLNode?) -> String? {
    guard let email = mailbox?.child(named: "EmailAddress")?.text.nonEmpty else { return nil }
    guard let name = mailbox?.child(named: "Name")?.text.nonEmpty else { return email }
    return "\(name) <\(email)>"
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
    if version.localizedCaseInsensitiveContains("2019") { return .exchange2019 }
    if version.localizedCaseInsensitiveContains("2016") { return .exchange2016 }
    if minor >= 2 { return .exchange2019 }
    if minor == 1 { return .exchange2016 }
    return .exchange2013SP1
  }

  private func distinguishedDestination(_ action: ProviderMailAction) -> String? {
    switch action {
    case .archive: return "archiveinbox"
    case .spam: return "junkemail"
    case .notSpam, .restore: return "inbox"
    default: return nil
    }
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
      uniqueKeysWithValues: attributes.map {
        ($0.key.split(separator: ":").last.map(String.init) ?? $0.key, $0.value)
      }
    )
  }

  var descendants: [EWSXMLNode] {
    children + children.flatMap(\.descendants)
  }

  func child(named name: String) -> EWSXMLNode? {
    children.first { $0.localName == name }
  }

  func firstDescendant(named name: String) -> EWSXMLNode? {
    descendants.first { $0.localName == name }
  }
}

private final class EWSRequestAuthenticationDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let credential: URLCredential?
  private let endpoint: URL

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
    let passwordMethods = [
      NSURLAuthenticationMethodDefault,
      NSURLAuthenticationMethodHTTPBasic,
      NSURLAuthenticationMethodHTTPDigest,
      NSURLAuthenticationMethodNegotiate,
      NSURLAuthenticationMethodNTLM,
    ]
    let protectionSpace = challenge.protectionSpace
    let challengeOrigin =
      "\(protectionSpace.protocol ?? "https")://\(protectionSpace.host):\(protectionSpace.port)"
    let challengeURL = URL(string: challengeOrigin)
    if passwordMethods.contains(method),
      challengeURL.map({
        EWSConnectionDefinition.hasSameOrigin($0, as: endpoint)
      }) == true,
      let credential
    {
      completionHandler(.useCredential, credential)
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
    stack[stack.count - 1].text =
      stack[stack.count - 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
    stack.removeLast()
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
