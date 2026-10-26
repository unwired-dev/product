import Foundation

// Microsoft own-mailbox access, including native-only preparation and attachment uploads.
extension RegistrationStore {
  // Only reads of the signed-in person's own mail reach a Microsoft credential: its folders, their
  // own folders, messages and delta rounds, its messages, their search and attachments. The path is checked
  // decoded, so an encoded separator cannot add a segment.
  static func graphURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme == "https", url.host == "graph.microsoft.com",
      url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
      url.path.range(
        of: #"^/v1\.0/me/(mail[Ff]olders((/[\w=-]+|\('[\w=-]+'\))(/messages(/delta|/[\w=-]+)?|/childFolders)?)?|messages(/[\w=-]+(/attachments(/[\w=-]+)?)?)?)$"#,
        options: .regularExpression) != nil
    else { throw RegistrationError.unavailable }
    return url
  }

  // One Graph read for a Microsoft connection.
  func graph(url value: String, connection id: String, address: String, generation expected: String)
    async throws -> [String: Any]
  {
    try await graphCall(
      url: Self.graphURL(value), method: "GET", body: nil, connection: id, address: address,
      generation: expected)
  }

  // The one Microsoft write: one message's read state, or its move to a well-known folder or a
  // folder ID. This file writes the request, so only identifiers and the read state cross from
  // TypeScript.
  func graphModify(
    message: String, read: Bool?, folder: String?, connection: String, address: String,
    generation: String
  ) async throws -> [String: Any] {
    func valid(_ value: String) -> Bool {
      value.range(of: #"^[\w=-]{1,512}$"#, options: .regularExpression) != nil
    }
    guard valid(message), (read == nil) != (folder == nil), folder.map(valid) ?? true,
      let url = URL(
        string: "https://graph.microsoft.com/v1.0/me/messages/\(message)"
          + (folder == nil ? "" : "/move"))
    else { throw RegistrationError.unavailable }
    let body: [String: Any] = folder.map { ["destinationId": $0] } ?? ["isRead": read ?? false]
    return try await graphCall(
      url: url, method: folder == nil ? "PATCH" : "POST",
      body: try JSONSerialization.data(withJSONObject: body), connection: connection,
      address: address, generation: generation)
  }

  // Graph's sendMail takes the whole message base64 encoded in one request of at most 4 MB.
  static let graphMessageLimit = 3_000_000
  // Graph attaches a file of at least 3 MB only through an upload session, and a smaller one in one
  // request. Each uploaded range stays under the 4 MB request size, in multiples of 320 KiB.
  static let graphUploadMinimum = 3_000_000
  static let graphUploadRange = 12 * 320 * 1024
  static let graphMessages = "https://graph.microsoft.com/v1.0/me/messages"

  // The one Microsoft send: the message as MIME through Graph's sendMail, which files its copy in
  // Sent Items. Any failure once the request starts may follow Microsoft accepting the message:
  // deliveryUnknown.
  func graphSend(segments: [Any], connection: String, address: String, generation: String)
    async throws -> [String: Any]
  {
    let owner = try mailboxAccount(connection).productAccountId
    let message = try await outgoingMessage(
      segments: segments, owner: owner, limit: Self.graphMessageLimit)
    guard let url = URL(string: "https://graph.microsoft.com/v1.0/me/sendMail") else {
      throw RegistrationError.unavailable
    }
    return try await graphCall(
      url: url, method: "POST", body: message.base64EncodedData(), contentType: "text/plain",
      connection: connection, address: address, generation: generation, sending: true)
  }

  // Sends the Outlook draft graphPrepare kept, which Graph then files in Sent Items. Any failure once
  // the request starts may follow Microsoft accepting the message: deliveryUnknown.
  func graphSendDraft(draft: String, connection: String, address: String, generation: String)
    async throws -> [String: Any]
  {
    guard Self.graphID(draft), let url = URL(string: "\(Self.graphMessages)/\(draft)/send") else {
      throw RegistrationError.unavailable
    }
    return try await graphCall(
      url: url, method: "POST", body: Data(), connection: connection, address: address,
      generation: generation, sending: true)
  }

  private static func graphID(_ value: String) -> Bool {
    value.range(of: #"^[\w=-]{1,512}$"#, options: .regularExpression) != nil
  }

  // Cleanup intent stays in the encrypted Draft document until this complete search succeeds.
  // Requery after deletion rather than advancing an offset through a changing Drafts folder.
  func graphDiscard(messageId: String, connection: String, address: String, generation: String)
    async throws -> [String: Any]
  {
    guard messageId.range(of: #"^[\w.-]{1,200}@[\w.-]{1,200}$"#, options: .regularExpression) != nil else {
      throw RegistrationError.unavailable
    }
    var search = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/drafts/messages")
    search?.queryItems = [
      URLQueryItem(name: "$filter", value: "internetMessageId eq '<\(messageId)>'"),
      URLQueryItem(name: "$select", value: "id"),
    ]
    guard let url = search?.url else { throw RegistrationError.unavailable }
    for _ in 0..<200 {
      let reply = try await graphCall(url: url, method: "GET", body: nil, connection: connection,
        address: address, generation: generation)
      guard reply["status"] as? Int == 200 else { return reply }
      guard let body = reply["body"] as? String,
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
        let found = json["value"] as? [[String: Any]] else { throw RegistrationError.unavailable }
      if found.isEmpty {
        // An empty continuation is not proof that all matching drafts were removed.
        guard json["@odata.nextLink"] == nil else { throw RegistrationError.unavailable }
        return ["status": 204, "body": ""]
      }
      for each in found {
        guard let id = each["id"] as? String, Self.graphID(id),
          let target = URL(string: "\(Self.graphMessages)/\(id)") else { throw RegistrationError.unavailable }
        let removed = try await graphCall(url: target, method: "DELETE", body: Data(),
          connection: connection, address: address, generation: generation)
        guard let status = removed["status"] as? Int, status == 204 || status == 404 else { return removed }
      }
    }
    throw RegistrationError.unavailable
  }

  // Keeps a message too large for sendMail as an Outlook draft. The drafts an interrupted attempt
  // left under the same Message-ID were never sent and are deleted first. Then the MIME without
  // files is saved, and each named Draft Asset's verified bytes are attached here, so they never
  // cross the bridge. Returns the draft once every file is attached, or the first refused
  // request's answer after deleting the new draft. Nothing here sends, so every failure can be
  // tried again.
  func graphPrepare(
    segments: [Any], messageId: String, files: [Any], connection: String, address: String,
    generation: String
  ) async throws -> [String: Any] {
    let owner = try mailboxAccount(connection).productAccountId
    struct File {
      let id: String
      let digest: String
      let item: [String: Any]
    }
    func matches(_ value: Any?, _ pattern: String) -> String? {
      (value as? String).flatMap {
        $0.range(of: pattern, options: .regularExpression) == nil ? nil : $0
      }
    }
    let attached = try files.map { value in
      let file = value as? [String: Any]
      let asset = file?["asset"] as? [String: Any]
      let contentId = file?["contentId"]
      guard let id = matches(asset?["id"], "^[0-9a-z]{8,64}$"),
        let digest = matches(asset?["digest"], "^[0-9a-f]{64}$"),
        let name = file?["name"] as? String,
        let type = matches(file?["type"], #"^[\w.+-]+/[\w.+-]+$"#),
        contentId == nil || matches(contentId, #"^[\x21-\x7E]{1,255}$"#) != nil
      else { throw RegistrationError.unavailable }
      var item: [String: Any] = ["name": name, "contentType": type, "isInline": contentId != nil]
      item["contentId"] = contentId
      return File(id: id, digest: digest, item: item)
    }
    let message = try await outgoingMessage(
      segments: segments, owner: owner, limit: Self.graphMessageLimit)
    func call(_ url: URL?, _ method: String, _ body: Data?, _ type: String = "application/json")
      async throws -> (Int, [String: Any])
    {
      guard let url else { throw RegistrationError.unavailable }
      let reply = try await graphCall(
        url: url, method: method, body: body, contentType: type, connection: connection,
        address: address, generation: generation)
      return (reply["status"] as? Int ?? 0, reply)
    }
    func json(_ reply: [String: Any]) -> [String: Any]? {
      (reply["body"] as? String).flatMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    }
    let discarded = try await graphDiscard(messageId: messageId, connection: connection,
      address: address, generation: generation)
    guard discarded["status"] as? Int == 204 else { return discarded }
    let (status, created) = try await call(
      URL(string: Self.graphMessages), "POST", message.base64EncodedData(), "text/plain")
    guard status == 201, let draft = json(created)?["id"] as? String, Self.graphID(draft) else {
      return created
    }
    let attachments = "\(Self.graphMessages)/\(draft)/attachments"
    // Attaches one file; returns Graph's answer when it refuses.
    func attach(_ file: File, _ bytes: Data) async throws -> [String: Any]? {
      var item = file.item
      if bytes.count < Self.graphUploadMinimum {
        item["@odata.type"] = "#microsoft.graph.fileAttachment"
        item["contentBytes"] = bytes.base64EncodedString()
        let (status, reply) = try await call(
          URL(string: attachments), "POST",
          try JSONSerialization.data(withJSONObject: item, options: .withoutEscapingSlashes))
        return status == 201 ? nil : reply
      }
      item["attachmentType"] = "file"
      item["size"] = bytes.count
      let (status, reply) = try await call(
        URL(string: attachments + "/createUploadSession"), "POST",
        try JSONSerialization.data(withJSONObject: ["AttachmentItem": item]))
      guard status == 201 else { return reply }
      // The session's URL carries its own authorization, so the Graph token never reaches it.
      guard let value = json(reply)?["uploadUrl"] as? String, let url = URL(string: value),
        url.scheme == "https", url.user == nil, url.password == nil, let host = url.host,
        host.hasSuffix(".office.com") || host.hasSuffix(".office365.com")
      else { throw RegistrationError.unavailable }
      var start = 0
      while start < bytes.count {
        try Task.checkCancellation()
        let product = try mailboxAccount(connection)
        try await requireTrustedDevice(product)
        let current = try mailboxAccount(connection)
        guard current.productAccountId == owner, verifiedMailboxes.contains(connection),
          mailboxGeneration(connection).uuidString == generation else {
          throw PrivateInboxError.mailboxInvalidated
        }
        let end = min(start + Self.graphUploadRange, bytes.count)
        let (status, data): (Int, Data)
        do {
          (status, data) = try await microsoftProvider().upload(
            url: url, body: bytes.subdata(in: start..<end),
            range: "bytes \(start)-\(end - 1)/\(bytes.count)")
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw RegistrationError.unavailable
        }
        guard (200..<300).contains(status) else {
          return ["status": status, "body": String(decoding: data, as: UTF8.self)]
        }
        // Only the final 201 confirms the attachment; an upload still in progress cannot be sent.
        guard status == (end == bytes.count ? 201 : 200) else {
          throw RegistrationError.unavailable
        }
        start = end
      }
      return nil
    }
    // Best effort: a draft left behind is replaced by the next attempt.
    func discard() async {
      _ = try? await call(URL(string: "\(Self.graphMessages)/\(draft)"), "DELETE", Data())
    }
    do {
      for file in attached {
        let bytes: Data
        do {
          bytes = try await draftAssetBytes(owner: owner, id: file.id, digest: file.digest)
        } catch PrivateInboxError.invalidStore {
          // Bytes that no longer verify against their digest are not sent either.
          throw PrivateInboxError.attachmentMissing
        }
        if let refused = try await attach(file, bytes) {
          await discard()
          return refused
        }
      }
    } catch {
      await discard()
      throw error
    }
    return ["status": 201, "body": #"{"id":"\#(draft)"}"#]
  }

  // One Graph request for a Microsoft connection, fenced like a Gmail request: work from before a
  // removal or another verification is stale, and a refused grant asks for authorization again.
  // While `sending`, a failure once the request starts is deliveryUnknown, and Graph's answer is
  // returned whatever changed meanwhile, as the message may already be sent.
  private func graphCall(
    url: URL, method: String, body: Data?, contentType: String = "application/json",
    connection id: String, address: String, generation expected: String, sending: Bool = false
  ) async throws -> [String: Any] {
    let generation = mailboxGeneration(id)
    guard generation.uuidString == expected else { throw PrivateInboxError.mailboxInvalidated }
    _ = try mailboxAccount(id)
    guard verifiedMailboxes.contains(id) else { throw RegistrationError.unavailable }
    let (credential, mailbox) = try connectedMailbox(id)
    guard mailbox.mailProvider == .microsoftGraph else { throw RegistrationError.unavailable }
    guard mailbox.address == address else { throw PrivateInboxError.mailboxInvalidated }
    func current() -> Bool {
      generation == mailboxGeneration(id) && verifiedMailboxes.contains(id)
        && (try? connectedMailbox(id))?.1.account == mailbox.account
    }
    // A write requires current device trust; the offline cache preflight cannot authorize it.
    if body != nil {
      let product = try mailboxAccount(id)
      try await requireTrustedDevice(product)
      guard current() else { throw PrivateInboxError.mailboxInvalidated }
    }
    let microsoft = try microsoftProvider()
    let identity: MicrosoftMailIdentity
    do {
      identity = try await microsoft.refresh(credential)
    } catch is CancellationError {
      throw CancellationError()
    } catch RegistrationError.gmailUnavailable {
      throw RegistrationError.gmailUnavailable
    } catch {
      throw RegistrationError.unavailable
    }
    try Task.checkCancellation()
    guard current() else { throw PrivateInboxError.mailboxInvalidated }
    // Keep renewed tokens unless the connection changed while they were renewed.
    if identity.credential != credential, var latest = try load(),
      latest.connection(id)?.credential == credential
    {
      latest.update(id) { $0.credential = identity.credential }
      try save(latest)
    }
    let status: Int
    let data: Data
    if sending {
      let product = try mailboxAccount(id)
      try await requireTrustedDevice(product)
      _ = try mailboxAccount(id)
      guard current() else { throw PrivateInboxError.mailboxInvalidated }
      guard deliveryAllowed() else { throw RegistrationError.unavailable }
    }
    do {
      (status, data) = try await microsoft.graph(
        identity, url: url, method: method, body: body, contentType: contentType)
    } catch RegistrationError.unavailable where sending {
      // It never left this device, so it is safe to try again.
      throw RegistrationError.unavailable
    } catch where sending {
      throw PrivateInboxError.deliveryUnknown
    } catch is GmailRequestInterrupted {
      throw RegistrationError.unavailable
    }
    guard sending || current() else { throw PrivateInboxError.mailboxInvalidated }
    return ["status": status, "body": String(decoding: data, as: UTF8.self)]
  }
}
