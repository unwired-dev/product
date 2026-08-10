import CoreFoundation
import Foundation

// swiftlint:disable file_length type_body_length

struct SystemIMAPMailboxClient: IMAPMailboxClient {
  private let streamTaskFactory: GenericMailStreamTaskCreating

  init(
    streamTaskFactory: GenericMailStreamTaskCreating = URLSessionGenericMailStreamTaskFactory()
  ) {
    self.streamTaskFactory = streamTaskFactory
  }

  func listMailboxes(
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> [IMAPMailboxDescriptor] {
    try await withSession(authorization: authorization) { session in
      let response = try await session.command(#"LIST "" "*""#)
      return try IMAPResponseParser.mailboxes(response)
    }
  }

  func loadMetadataPage(
    mailbox: IMAPMailboxDescriptor,
    beforeUID: Int64?,
    limit: Int,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> IMAPMetadataPage {
    try await withSession(authorization: authorization) { session in
      let capabilityResponse = try await session.command("CAPABILITY")
      let supportsObjectId = IMAPResponseParser.capabilities(capabilityResponse)
        .contains("OBJECTID")
      let selectResponse = try await session.command("SELECT \(Self.quoted(mailbox.name))")
      let uidValidity = try IMAPResponseParser.uidValidity(selectResponse)
      guard beforeUID != 1 else {
        return IMAPMetadataPage(messages: [], nextOlderUID: nil, uidValidity: uidValidity)
      }
      let searchCommand = beforeUID.map { "UID SEARCH UID 1:\($0 - 1)" } ?? "UID SEARCH ALL"
      let searchResponse = try await session.command(searchCommand)
      let eligibleUIDs = IMAPResponseParser.uids(searchResponse).sorted()
      let selectedUIDs = Array(eligibleUIDs.suffix(max(0, limit)))
      let nextOlderUID =
        eligibleUIDs.count > selectedUIDs.count
        ? selectedUIDs.first
        : nil
      guard !selectedUIDs.isEmpty else {
        return IMAPMetadataPage(
          messages: [],
          nextOlderUID: nil,
          uidValidity: uidValidity
        )
      }
      let sequence = selectedUIDs.map(String.init).joined(separator: ",")
      let objectIdFields = supportsObjectId ? " EMAILID THREADID" : ""
      let fetchResponse = try await session.command(
        "UID FETCH \(sequence) (UID FLAGS INTERNALDATE\(objectIdFields) BODYSTRUCTURE "
          + "BODY.PEEK[HEADER.FIELDS (CC FROM IN-REPLY-TO MESSAGE-ID REFERENCES "
          + "REPLY-TO SUBJECT TO)])"
      )
      return IMAPMetadataPage(
        messages: try IMAPResponseParser.messages(
          fetchResponse,
          mailbox: mailbox.name,
          uidValidity: uidValidity
        ),
        nextOlderUID: nextOlderUID,
        uidValidity: uidValidity
      )
    }
  }

  func loadTextBody(
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> String {
    try await loadMessageBody(message: message, authorization: authorization).text
  }

  func loadMessageBody(
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> MailboxMessageBody {
    try await withSession(authorization: authorization) { session in
      let selectResponse = try await session.command("SELECT \(Self.quoted(message.mailbox))")
      guard try IMAPResponseParser.uidValidity(selectResponse) == message.uidValidity else {
        throw IMAPMailboxError.invalidProviderResponse
      }
      let structureResponse = try await session.command(
        "UID FETCH \(message.uid) (BODYSTRUCTURE)"
      )
      let structure = try IMAPResponseParser.bodyStructure(structureResponse)
      guard let part = structure.preferredTextPart else {
        throw IMAPMailboxError.unsupportedBody
      }
      let bodyResponse = try await session.commandData(
        "UID FETCH \(message.uid) (BODY.PEEK[\(part.section)])"
      )
      let encodedBody = try IMAPResponseParser.literalData(bodyResponse)
      let decodedBody = try IMAPBodyDecoder.decode(
        encodedBody,
        charset: part.charset,
        transferEncoding: part.transferEncoding
      )
      let text =
        part.mimeSubtype == "HTML"
        ? IMAPBodyDecoder.plainText(fromHTML: decodedBody)
        : decodedBody
      return MailboxMessageBody(text: text, attachments: structure.attachments)
    }
  }

  func loadMessageAttachment(
    _ attachment: MailboxMessageAttachment,
    message: IMAPProviderMessage,
    authorization: DeviceLocalGenericMailAuthorization
  ) async throws -> Data {
    do {
      return try await withSession(authorization: authorization) { session in
        let selectResponse = try await session.command("SELECT \(Self.quoted(message.mailbox))")
        guard try IMAPResponseParser.uidValidity(selectResponse) == message.uidValidity else {
          throw MailboxMessageAttachmentError.invalidResponse
        }
        let structureResponse = try await session.command(
          "UID FETCH \(message.uid) (BODYSTRUCTURE)"
        )
        let structure = try IMAPResponseParser.bodyStructure(structureResponse)
        guard let part = structure.attachmentPart(matching: attachment),
          attachment.byteCount >= 0,
          attachment.byteCount <= MailboxMessageAttachmentPolicy.maximumByteCount
        else { throw MailboxMessageAttachmentError.invalidResponse }
        let maximumRequestedByteCount = min(
          MailboxMessageAttachmentPolicy.maximumByteCount + 1,
          attachment.byteCount + 1
        )
        let bodyResponse = try await session.commandData(
          "UID FETCH \(message.uid) (BODY.PEEK[\(part.section)]<0.\(maximumRequestedByteCount)>)",
          maximumLiteralByteCount: maximumRequestedByteCount
        )
        let encodedData = try IMAPResponseParser.literalData(bodyResponse)
        let data = try IMAPBodyDecoder.decodeData(
          encodedData,
          transferEncoding: part.transferEncoding
        )
        guard data.count <= MailboxMessageAttachmentPolicy.maximumByteCount,
          attachment.byteCount == 0 || data.count <= attachment.byteCount
        else { throw MailboxMessageAttachmentError.invalidResponse }
        return data
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MailboxMessageAttachmentError {
      throw error
    } catch {
      throw MailboxMessageAttachmentError.invalidResponse
    }
  }

  private func withSession<T>(
    authorization: DeviceLocalGenericMailAuthorization,
    operation: (IMAPWireSession) async throws -> T
  ) async throws -> T {
    let definition = authorization.definition
    let endpoint = definition.incomingEndpoint
    guard endpoint.mailProtocol == .imap else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    let task = streamTaskFactory.makeStreamTask(
      hostname: endpoint.hostname,
      port: endpoint.port,
      minimumTransportVersion: .tls12OrNewer
    )
    task.resume()
    let session = IMAPWireSession(
      authorizationMethod: definition.authorizationMethod,
      credential: authorization.credential,
      endpoint: endpoint,
      task: task,
      username: definition.username
    )
    return try await withTaskCancellationHandler {
      defer { task.close() }
      try await session.open()
      return try await operation(session)
    } onCancel: {
      task.close()
    }
  }

  private static func quoted(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }
}

private final class IMAPWireSession {
  private let authorizationMethod: MailAuthorizationMethod
  private let credential: String
  private let endpoint: GenericMailEndpoint
  private let task: GenericMailStreamTasking
  private let username: String
  private var nextTagNumber = 1
  private var unreadResponse = Data()

  init(
    authorizationMethod: MailAuthorizationMethod,
    credential: String,
    endpoint: GenericMailEndpoint,
    task: GenericMailStreamTasking,
    username: String
  ) {
    self.authorizationMethod = authorizationMethod
    self.credential = credential
    self.endpoint = endpoint
    self.task = task
    self.username = username
  }

  func open() async throws {
    guard ![username, credential].contains(where: { $0.contains("\r") || $0.contains("\n") })
    else {
      throw GenericMailSetupError.authenticationFailed(.imap)
    }
    if endpoint.security == .implicitTLS {
      task.startSecureConnection()
    }
    guard try await readLine().uppercased().contains("* OK") else {
      throw GenericMailSetupError.authenticationFailed(.imap)
    }
    if endpoint.security == .startTLS {
      _ = try await command("STARTTLS")
      unreadResponse.removeAll()
      task.startSecureConnection()
    }
    if authorizationMethod == .oauth {
      let payload = Data(
        "user=\(username)\u{1}auth=Bearer \(credential)\u{1}\u{1}".utf8
      ).base64EncodedString()
      _ = try await command("AUTHENTICATE XOAUTH2 \(payload)", respondsToContinuation: true)
    } else {
      _ = try await command(
        "LOGIN \(Self.quoted(username)) \(Self.quoted(credential))"
      )
    }
  }

  func command(
    _ command: String,
    respondsToContinuation: Bool = false
  ) async throws -> String {
    try Task.checkCancellation()
    let tag = "A\(nextTagNumber)"
    nextTagNumber += 1
    try await task.write("\(tag) \(command)\r\n")
    let response = try await readTaggedResponse(
      tag: tag,
      respondsToContinuation: respondsToContinuation
    )
    guard IMAPResponseParser.taggedResponseIsOK(response, tag: tag) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    return response
  }

  func commandData(
    _ command: String,
    respondsToContinuation: Bool = false,
    maximumLiteralByteCount: Int? = nil
  ) async throws -> Data {
    try Task.checkCancellation()
    let tag = "A\(nextTagNumber)"
    nextTagNumber += 1
    try await task.write("\(tag) \(command)\r\n")
    let response = try await readTaggedResponseData(
      tag: tag,
      respondsToContinuation: respondsToContinuation,
      maximumLiteralByteCount: maximumLiteralByteCount
    )
    return response
  }

  private func readTaggedResponse(
    tag: String,
    respondsToContinuation: Bool
  ) async throws -> String {
    var response = ""
    while true {
      try Task.checkCancellation()
      let line = try await readLine()
      response += line
      if respondsToContinuation, line.hasPrefix("+") {
        try await task.write("\r\n")
      }
      let uppercase = line.uppercased()
      if uppercase.hasPrefix("\(tag.uppercased()) OK ")
        || uppercase == "\(tag.uppercased()) OK\r\n"
        || uppercase.hasPrefix("\(tag.uppercased()) NO ")
        || uppercase.hasPrefix("\(tag.uppercased()) BAD ")
      {
        return response
      }
    }
  }

  private func readTaggedResponseData(
    tag: String,
    respondsToContinuation: Bool,
    maximumLiteralByteCount: Int?
  ) async throws -> Data {
    var response = Data()
    while true {
      try Task.checkCancellation()
      let lineData = try await readLineData()
      response.append(lineData)
      if let literalLength = Self.trailingLiteralLength(lineData) {
        if let maximumLiteralByteCount, literalLength > maximumLiteralByteCount {
          throw MailboxMessageAttachmentError.invalidResponse
        }
        response.append(try await readData(count: literalLength))
        continue
      }
      if respondsToContinuation, lineData.first == 43 {
        try await task.write("\r\n")
      }
      let tagPrefix = Data("\(tag) ".utf8)
      guard lineData.starts(with: tagPrefix) else { continue }
      guard let line = String(data: lineData, encoding: .utf8) else {
        throw IMAPMailboxError.invalidProviderResponse
      }
      let uppercase = line.uppercased()
      if uppercase.hasPrefix("\(tag.uppercased()) OK ")
        || uppercase == "\(tag.uppercased()) OK\r\n"
      {
        return response
      }
      if uppercase.hasPrefix("\(tag.uppercased()) NO ")
        || uppercase.hasPrefix("\(tag.uppercased()) BAD ")
      {
        throw IMAPMailboxError.invalidProviderResponse
      }
    }
  }

  private func readLine() async throws -> String {
    let data = try await readLineData()
    guard let line = String(data: data, encoding: .utf8) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    return line
  }

  private func readLineData() async throws -> Data {
    let delimiter = Data([13, 10])
    while unreadResponse.range(of: delimiter) == nil {
      unreadResponse.append(try await task.readData())
    }
    guard let range = unreadResponse.range(of: delimiter) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    let line = Data(unreadResponse[..<range.upperBound])
    unreadResponse.removeSubrange(..<range.upperBound)
    return line
  }

  private func readData(count: Int) async throws -> Data {
    while unreadResponse.count < count {
      unreadResponse.append(try await task.readData())
    }
    let data = Data(unreadResponse.prefix(count))
    unreadResponse.removeFirst(count)
    return data
  }

  private static func trailingLiteralLength(_ line: Data) -> Int? {
    let bytes = [UInt8](line)
    guard bytes.suffix(3).elementsEqual([125, 13, 10]),
      let markerStart = bytes.dropLast(3).lastIndex(of: 123)
    else { return nil }
    return Int(
      String(
        bytes: bytes[(markerStart + 1)..<(bytes.count - 3)],
        encoding: .utf8
      ) ?? "")
  }

  private static func quoted(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }
}

private enum IMAPResponseParser {
  static func capabilities(_ response: String) -> Set<String> {
    Set(
      response.components(separatedBy: "\r\n").flatMap { line -> [String] in
        guard line.uppercased().hasPrefix("* CAPABILITY ") else { return [] }
        return line.split(whereSeparator: \.isWhitespace).dropFirst(2).map {
          $0.uppercased()
        }
      }
    )
  }

  static func taggedResponseIsOK(_ response: String, tag: String) -> Bool {
    response.components(separatedBy: "\r\n").contains {
      $0.uppercased().hasPrefix("\(tag.uppercased()) OK")
    }
  }

  static func mailboxes(_ response: String) throws -> [IMAPMailboxDescriptor] {
    var mailboxes: [IMAPMailboxDescriptor] = []
    for line in response.components(separatedBy: "\r\n")
    where line.uppercased().hasPrefix("* LIST ") {
      guard let flagsStart = line.firstIndex(of: "("),
        let flagsEnd = line[flagsStart...].firstIndex(of: ")")
      else { continue }
      let flags = line[line.index(after: flagsStart)..<flagsEnd].uppercased()
      guard !flags.contains("\\NOSELECT") else { continue }
      let remaining = line[line.index(after: flagsEnd)...]
      guard
        let (_, afterDelimiter) = token(in: remaining),
        let (mailboxName, _) = token(in: afterDelimiter)
      else { throw IMAPMailboxError.invalidProviderResponse }
      mailboxes.append(
        IMAPMailboxDescriptor(
          displayName: decodeModifiedUTF7(mailboxName),
          name: mailboxName
        )
      )
    }
    return Array(Set(mailboxes))
  }

  static func uidValidity(_ response: String) throws -> Int64 {
    guard
      let match = firstCapture(
        pattern: #"\[UIDVALIDITY\s+([0-9]+)\]"#,
        in: response,
        options: [.caseInsensitive]
      ),
      let value = Int64(match)
    else { throw IMAPMailboxError.invalidProviderResponse }
    return value
  }

  static func uids(_ response: String) -> [Int64] {
    response.components(separatedBy: "\r\n").flatMap { line -> [Int64] in
      guard line.uppercased().hasPrefix("* SEARCH") else { return [] }
      return line.split(separator: " ").dropFirst(2).compactMap { Int64($0) }
    }
  }

  static func messages(
    _ response: String,
    mailbox: String,
    uidValidity: Int64
  ) throws -> [IMAPProviderMessage] {
    let expression = try NSRegularExpression(
      pattern: #"(?m)^\* [0-9]+ FETCH \("#,
      options: [.caseInsensitive]
    )
    let responseRange = NSRange(response.startIndex..., in: response)
    let matches = expression.matches(in: response, range: responseRange)
    return try matches.enumerated().compactMap { index, match in
      guard let start = Range(match.range, in: response)?.lowerBound else { return nil }
      let end: String.Index
      if index + 1 < matches.count,
        let next = Range(matches[index + 1].range, in: response)?.lowerBound
      {
        end = next
      } else if let tagged = response.range(
        of: #"(?m)^A[0-9]+ (?:OK|NO|BAD)"#,
        options: [.regularExpression, .caseInsensitive],
        range: start..<response.endIndex
      ) {
        end = tagged.lowerBound
      } else {
        end = response.endIndex
      }
      return try message(
        String(response[start..<end]),
        mailbox: mailbox,
        uidValidity: uidValidity
      )
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func bodyStructure(_ response: String) throws -> IMAPBodyStructure {
    guard let marker = response.range(of: "BODYSTRUCTURE", options: .caseInsensitive) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    let suffix = response[marker.upperBound...]
    guard let start = suffix.firstIndex(of: "(") else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    var depth = 0
    var quoted = false
    var escaped = false
    var end: String.Index?
    for index in suffix.indices where index >= start {
      let character = suffix[index]
      if escaped {
        escaped = false
        continue
      }
      if quoted, character == "\\" {
        escaped = true
        continue
      }
      if character == "\"" {
        quoted.toggle()
        continue
      }
      guard !quoted else { continue }
      if character == "(" { depth += 1 }
      if character == ")" {
        depth -= 1
        if depth == 0 {
          end = suffix.index(after: index)
          break
        }
      }
    }
    guard let end else { throw IMAPMailboxError.invalidProviderResponse }
    var parser = IMAPSExpressionParser(String(suffix[start..<end]))
    return IMAPBodyStructure(root: try parser.parse())
  }

  static func literalData(_ response: Data) throws -> Data {
    let bytes = [UInt8](response)
    guard
      let markerEnd = bytes.indices.first(where: { index in
        index >= 2 && bytes[index - 2] == 125 && bytes[index - 1] == 13 && bytes[index] == 10
      })
    else { throw IMAPMailboxError.invalidProviderResponse }
    guard
      let markerStart = bytes[..<(markerEnd - 2)].lastIndex(of: 123),
      let literalLength = Int(
        String(
          bytes: bytes[(markerStart + 1)..<(markerEnd - 2)],
          encoding: .utf8
        ) ?? "")
    else { throw IMAPMailboxError.invalidProviderResponse }
    let literalStart = markerEnd + 1
    guard bytes.count >= literalStart + literalLength else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    return Data(bytes[literalStart..<(literalStart + literalLength)])
  }

  private static func message(
    _ block: String,
    mailbox: String,
    uidValidity: Int64
  ) throws -> IMAPProviderMessage {
    guard
      let uidText = firstCapture(pattern: #"\bUID\s+([0-9]+)"#, in: block),
      let uid = Int64(uidText),
      let internalDateText = firstCapture(
        pattern: #"\bINTERNALDATE\s+"([^"]+)""#,
        in: block,
        options: [.caseInsensitive]
      )
    else { throw IMAPMailboxError.invalidProviderResponse }
    let flagsText =
      firstCapture(
        pattern: #"\bFLAGS\s+\(([^)]*)\)"#,
        in: block,
        options: [.caseInsensitive]
      ) ?? ""
    let headers = try headerFields(in: block)
    return IMAPProviderMessage(
      categoryId: nil,
      cc: headers["cc"],
      flags: flagsText.split(whereSeparator: \.isWhitespace).map(String.init),
      from: headers["from"],
      hasAttachments: (try? bodyStructure(block).hasAttachments) ?? false,
      inReplyTo: headers["in-reply-to"],
      internalDateMilliseconds: try internalDateMilliseconds(internalDateText),
      mailbox: mailbox,
      providerEmailId: objectId(named: "EMAILID", in: block),
      providerThreadId: objectId(named: "THREADID", in: block),
      references: messageIds(in: headers["references"]),
      replyTo: headers["reply-to"],
      rfcMessageId: headers["message-id"],
      snippet: "",
      subject: headers["subject"] ?? "",
      to: headers["to"],
      uid: uid,
      uidValidity: uidValidity
    )
  }

  private static func objectId(named name: String, in block: String) -> String? {
    guard
      let value = firstCapture(
        pattern: #"\b\#(name)\s+\(([^)]*)\)"#,
        in: block,
        options: [.caseInsensitive]
      )?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.caseInsensitiveCompare("NIL") != .orderedSame
    else { return nil }
    return value
  }

  private static func headerFields(in block: String) throws -> [String: String] {
    let expression = try NSRegularExpression(pattern: #"\{([0-9]+)\}\r\n"#)
    let range = NSRange(block.startIndex..., in: block)
    guard
      let match = expression.firstMatch(in: block, range: range),
      let lengthRange = Range(match.range(at: 1), in: block),
      let length = Int(block[lengthRange]),
      let markerRange = Range(match.range, in: block)
    else { return [:] }
    let data = Data(block[markerRange.upperBound...].utf8)
    guard data.count >= length,
      let headerText = String(data: data.prefix(length), encoding: .utf8)
        ?? String(data: data.prefix(length), encoding: .isoLatin1)
    else { throw IMAPMailboxError.invalidProviderResponse }
    let unfolded = headerText.replacingOccurrences(
      of: #"\r\n[ \t]+"#,
      with: " ",
      options: .regularExpression
    )
    var headers: [String: String] = [:]
    for line in unfolded.components(separatedBy: "\r\n") {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let name = line[..<separator].lowercased()
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let existing = headers[name], !existing.isEmpty {
        headers[name] = "\(existing), \(value)"
      } else {
        headers[name] = value
      }
    }
    return headers
  }

  private static func internalDateMilliseconds(_ value: String) throws -> Int64 {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
    guard let date = formatter.date(from: value) else {
      throw IMAPMailboxError.invalidProviderResponse
    }
    return Int64(date.timeIntervalSince1970 * 1_000)
  }

  private static func messageIds(in value: String?) -> [String] {
    guard let value,
      let expression = try? NSRegularExpression(pattern: #"<[^<>[:space:]]+>"#)
    else { return [] }
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap {
      Range($0.range, in: value).map { String(value[$0]) }
    }
  }

  private static func firstCapture(
    pattern: String,
    in value: String,
    options: NSRegularExpression.Options = []
  ) -> String? {
    guard
      let expression = try? NSRegularExpression(pattern: pattern, options: options),
      let match = expression.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }

  private static func token(
    in value: Substring
  ) -> (value: String, remainder: Substring)? {
    let trimmed = value.drop(while: \.isWhitespace)
    guard let first = trimmed.first else { return nil }
    guard first == "\"" else {
      let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
      return (String(trimmed[..<end]), trimmed[end...])
    }
    var result = ""
    var escaped = false
    var index = trimmed.index(after: trimmed.startIndex)
    while index < trimmed.endIndex {
      let character = trimmed[index]
      if escaped {
        result.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        return (result, trimmed[trimmed.index(after: index)...])
      } else {
        result.append(character)
      }
      index = trimmed.index(after: index)
    }
    return nil
  }

  private static func decodeModifiedUTF7(_ value: String) -> String {
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
      guard value[index] == "&" else {
        result.append(value[index])
        index = value.index(after: index)
        continue
      }
      guard let end = value[index...].firstIndex(of: "-") else {
        result.append(contentsOf: value[index...])
        break
      }
      let encodedStart = value.index(after: index)
      let encoded = String(value[encodedStart..<end])
      if encoded.isEmpty {
        result.append("&")
      } else {
        var base64 = encoded.replacingOccurrences(of: ",", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        if let data = Data(base64Encoded: base64),
          let decoded = String(data: data, encoding: .utf16BigEndian)
        {
          result.append(decoded)
        } else {
          result.append(contentsOf: value[index...end])
        }
      }
      index = value.index(after: end)
    }
    return result
  }
}

private enum IMAPSExpression: Equatable {
  case atom(String)
  case list([IMAPSExpression])
  case null

  var stringValue: String? {
    switch self {
    case .atom(let value):
      return value
    case .list, .null:
      return nil
    }
  }
}

private struct IMAPSExpressionParser {
  private let characters: [Character]
  private var index = 0

  init(_ value: String) {
    characters = Array(value)
  }

  mutating func parse() throws -> IMAPSExpression {
    skipWhitespace()
    guard index < characters.count else { throw IMAPMailboxError.invalidProviderResponse }
    if characters[index] == "(" {
      index += 1
      var values: [IMAPSExpression] = []
      while true {
        skipWhitespace()
        guard index < characters.count else {
          throw IMAPMailboxError.invalidProviderResponse
        }
        if characters[index] == ")" {
          index += 1
          return .list(values)
        }
        values.append(try parse())
      }
    }
    if characters[index] == "\"" {
      return .atom(try parseQuoted())
    }
    let atom = parseAtom()
    return atom.uppercased() == "NIL" ? .null : .atom(atom)
  }

  private mutating func parseQuoted() throws -> String {
    index += 1
    var value = ""
    var escaped = false
    while index < characters.count {
      let character = characters[index]
      index += 1
      if escaped {
        value.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        return value
      } else {
        value.append(character)
      }
    }
    throw IMAPMailboxError.invalidProviderResponse
  }

  private mutating func parseAtom() -> String {
    let start = index
    while index < characters.count,
      !characters[index].isWhitespace,
      characters[index] != "(",
      characters[index] != ")"
    {
      index += 1
    }
    return String(characters[start..<index])
  }

  private mutating func skipWhitespace() {
    while index < characters.count, characters[index].isWhitespace {
      index += 1
    }
  }
}

private struct IMAPTextPart {
  let charset: String?
  let mimeSubtype: String
  let section: String
  let transferEncoding: String?
}

private struct IMAPAttachmentPart {
  let attachment: MailboxMessageAttachment
  let section: String
  let transferEncoding: String?
}

private struct IMAPBodyStructure {
  private static let attachmentIdentifierPrefix = "imap-body-part:"

  let root: IMAPSExpression

  var hasAttachments: Bool {
    !attachments.isEmpty
  }

  var attachments: [MailboxMessageAttachment] {
    attachmentParts(in: root, path: []).map(\.attachment)
  }

  var preferredTextPart: IMAPTextPart? {
    let parts = textParts(in: root, path: [])
    return parts.first { $0.mimeSubtype == "PLAIN" }
      ?? parts.first { $0.mimeSubtype == "HTML" }
  }

  func attachmentPart(matching attachment: MailboxMessageAttachment) -> IMAPAttachmentPart? {
    attachmentParts(in: root, path: []).first { $0.attachment == attachment }
  }

  private func textParts(
    in expression: IMAPSExpression,
    path: [Int]
  ) -> [IMAPTextPart] {
    guard case .list(let values) = expression, !values.isEmpty else { return [] }
    if case .list = values[0] {
      var parts: [IMAPTextPart] = []
      for (index, value) in values.enumerated() {
        guard case .list = value else { break }
        parts += textParts(in: value, path: path + [index + 1])
      }
      return parts
    }
    guard values.count > 5,
      values[0].stringValue?.uppercased() == "TEXT",
      let subtype = values[1].stringValue?.uppercased(),
      subtype == "PLAIN" || subtype == "HTML",
      !isAttachment(values)
    else { return [] }
    let section = (path.isEmpty ? [1] : path).map(String.init).joined(separator: ".")
    return [
      IMAPTextPart(
        charset: parameter(named: "CHARSET", in: values[safe: 2]),
        mimeSubtype: subtype,
        section: section,
        transferEncoding: values[safe: 5]?.stringValue
      )
    ]
  }

  private func isAttachment(_ values: [IMAPSExpression]) -> Bool {
    let disposition = disposition(in: values)
    let filename = disposition.filename ?? parameter(named: "NAME", in: values[safe: 2])
    let contentID = values[safe: 3]?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let isInlineContentID =
      values.first?.stringValue?.uppercased() == "IMAGE"
      && contentID?.isEmpty == false
      && disposition.name != "ATTACHMENT"
    return !isInlineContentID && (disposition.name == "ATTACHMENT" || filename != nil)
  }

  private func attachmentParts(
    in expression: IMAPSExpression,
    path: [Int]
  ) -> [IMAPAttachmentPart] {
    guard case .list(let values) = expression, !values.isEmpty else { return [] }
    if case .list = values[0] {
      var parts: [IMAPAttachmentPart] = []
      for (index, value) in values.enumerated() {
        guard case .list = value else { break }
        parts += attachmentParts(in: value, path: path + [index + 1])
      }
      return parts
    }
    guard values.count > 6,
      isAttachment(values),
      let mediaType = values[0].stringValue?.lowercased(),
      let mediaSubtype = values[1].stringValue?.lowercased(),
      let byteCount = Int(values[6].stringValue ?? ""),
      byteCount >= 0
    else { return [] }
    let disposition = disposition(in: values)
    let filename =
      disposition.filename ?? parameter(named: "NAME", in: values[safe: 2]) ?? "Attachment"
    let section = (path.isEmpty ? [1] : path).map(String.init).joined(separator: ".")
    return [
      IMAPAttachmentPart(
        attachment: MailboxMessageAttachment(
          byteCount: byteCount,
          filename: filename,
          id: Self.attachmentIdentifierPrefix + section,
          mimeType: "\(mediaType)/\(mediaSubtype)"
        ),
        section: section,
        transferEncoding: values[safe: 5]?.stringValue
      )
    ]
  }

  private func disposition(
    in values: [IMAPSExpression]
  ) -> (name: String?, filename: String?) {
    for value in values.dropFirst(6) {
      guard case .list(let dispositionValues) = value,
        let name = dispositionValues.first?.stringValue?.uppercased(),
        name == "ATTACHMENT" || name == "INLINE"
      else { continue }
      return (
        name,
        parameter(named: "FILENAME", in: dispositionValues[safe: 1])
      )
    }
    return (nil, nil)
  }

  private func parameter(
    named name: String,
    in expression: IMAPSExpression?
  ) -> String? {
    guard case .list(let values) = expression else { return nil }
    var index = 0
    while index + 1 < values.count {
      if values[index].stringValue?.uppercased() == name {
        return values[index + 1].stringValue
      }
      index += 2
    }
    return nil
  }
}

extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private enum IMAPBodyDecoder {
  static func decode(
    _ data: Data,
    charset: String?,
    transferEncoding: String?
  ) throws -> String {
    let decodedData = try decodeData(data, transferEncoding: transferEncoding)
    let encoding = stringEncoding(for: charset) ?? .utf8
    guard
      let value = String(data: decodedData, encoding: encoding)
        ?? String(data: decodedData, encoding: .utf8)
        ?? String(data: decodedData, encoding: .isoLatin1)
    else { throw IMAPMailboxError.unsupportedBody }
    return value
  }

  static func decodeData(
    _ data: Data,
    transferEncoding: String?
  ) throws -> Data {
    switch transferEncoding?.uppercased() {
    case "BASE64":
      let compact = data.filter { !$0.isASCIIWhitespace }
      guard let value = Data(base64Encoded: compact) else {
        throw IMAPMailboxError.unsupportedBody
      }
      return value
    case "QUOTED-PRINTABLE":
      return quotedPrintableDecoded(data)
    default:
      return data
    }
  }

  static func plainText(fromHTML value: String) -> String {
    let withoutNonVisibleBlocks = value.replacingOccurrences(
      of: "<(?:script|style)\\b[^>]*>[\\s\\S]*?</(?:script|style)\\s*>",
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    let withLineBreaks = withoutNonVisibleBlocks.replacingOccurrences(
      of: "<(?:br\\b[^>]*|/p|/div|/li|/h[1-6]|/tr|/?t[dh])\\s*>",
      with: "\n",
      options: [.regularExpression, .caseInsensitive]
    )
    let withoutTags = withLineBreaks.replacingOccurrences(
      of: "<[^>]+>",
      with: "",
      options: .regularExpression
    )
    return
      withoutTags
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
  }

  private static func stringEncoding(for charset: String?) -> String.Encoding? {
    guard let charset else { return nil }
    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
    guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
    )
  }

  private static func quotedPrintableDecoded(_ data: Data) -> Data {
    let bytes = [UInt8](data)
    var result: [UInt8] = []
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 61 else {
        result.append(bytes[index])
        index += 1
        continue
      }
      if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
        index += 3
        continue
      }
      if index + 2 < bytes.count,
        let high = hexadecimalValue(bytes[index + 1]),
        let low = hexadecimalValue(bytes[index + 2])
      {
        result.append(high * 16 + low)
        index += 3
        continue
      }
      result.append(bytes[index])
      index += 1
    }
    return Data(result)
  }

  private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57:
      return byte - 48
    case 65...70:
      return byte - 55
    case 97...102:
      return byte - 87
    default:
      return nil
    }
  }
}

extension UInt8 {
  fileprivate var isASCIIWhitespace: Bool {
    self == 9 || self == 10 || self == 13 || self == 32
  }
}
