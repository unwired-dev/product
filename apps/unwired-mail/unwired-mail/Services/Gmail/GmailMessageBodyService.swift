import CoreFoundation
import Foundation

// swiftlint:disable file_length

struct GmailMessageBody: Equatable {
  let text: String
}

protocol GmailMessageBodyCaching {
  func clearMessageBodies(productAccountId: String) throws

  func loadMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws -> ProductSyncEncryptedPayload?

  func removeMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId: String,
    stableProviderMessageId: String
  ) throws
}

protocol GmailMessageReading {
  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws

  func loadMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody

  func removeCachedMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws
}

struct FileGmailMessageBodyCache: GmailMessageBodyCaching {
  private let fileManager: FileManager
  private let rootDirectory: URL

  init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
    self.fileManager = fileManager
    self.rootDirectory =
      rootDirectory
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("UnwiredMail/GmailBodyCache", isDirectory: true)
  }

  func clearMessageBodies(productAccountId: String) throws {
    guard fileManager.fileExists(atPath: rootDirectory.path) else {
      return
    }
    let prefix = "\(gmailSafeFileComponent(productAccountId))-"
    for fileURL in try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil
    ) where fileURL.lastPathComponent.hasPrefix(prefix) {
      try fileManager.removeItem(at: fileURL)
    }
  }

  func loadMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws -> ProductSyncEncryptedPayload? {
    let fileURL = fileURL(
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }
    return try JSONDecoder().decode(
      ProductSyncEncryptedPayload.self,
      from: Data(contentsOf: fileURL)
    )
  }

  func removeMessageBody(
    productAccountId: String,
    stableProviderMessageId: String
  ) throws {
    let fileURL = fileURL(
      productAccountId: productAccountId,
      stableProviderMessageId: stableProviderMessageId
    )
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return
    }
    try fileManager.removeItem(at: fileURL)
  }

  func saveMessageBody(
    _ payload: ProductSyncEncryptedPayload,
    productAccountId: String,
    stableProviderMessageId: String
  ) throws {
    try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(payload).write(
      to: fileURL(
        productAccountId: productAccountId,
        stableProviderMessageId: stableProviderMessageId
      ),
      options: [.atomic]
    )
  }

  private func fileURL(productAccountId: String, stableProviderMessageId: String) -> URL {
    rootDirectory.appendingPathComponent(
      "\(gmailSafeFileComponent(productAccountId))-\(gmailSafeFileComponent(stableProviderMessageId)).json"
    )
  }
}

enum GmailMessageBodyError: LocalizedError, Equatable {
  case gmailRequestFailed
  case missingLocalGmailTokens
  case missingMessageBody
  case missingOAuthClientId
  case refreshTokenRejected

  var errorDescription: String? {
    switch self {
    case .gmailRequestFailed:
      return "Gmail message body could not be loaded."
    case .missingLocalGmailTokens:
      return "Gmail is connected on the backend, but this device has no local Gmail tokens."
    case .missingMessageBody:
      return "Gmail did not return a readable message body."
    case .missingOAuthClientId:
      return "Gmail OAuth client id is not configured."
    case .refreshTokenRejected:
      return "Gmail did not refresh local mail access for this account."
    }
  }
}

struct GmailMessageBodyService: GmailMessageReading {
  private let cache: GmailMessageBodyCaching
  private let gmailBaseURL: URL
  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let oauthClientId: String?
  private let session: URLSession
  private let tokenStore: GmailProviderTokenPersisting
  private let tokenRefreshURL: URL
  private let tokenInfoURL: URL

  init(
    gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1")!,
    cache: GmailMessageBodyCaching = FileGmailMessageBodyCache(),
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    oauthClientId: String? =
      ProcessInfo.processInfo.environment["GMAIL_OAUTH_CLIENT_ID"]
      ?? DotEnvFile.value(for: "GMAIL_OAUTH_CLIENT_ID")
      ?? GmailOAuthClientIdConfiguration.bundledValue(),
    session: URLSession = .shared,
    tokenStore: GmailProviderTokenPersisting = KeychainGmailProviderTokenStore(),
    tokenRefreshURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
    tokenInfoURL: URL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!
  ) {
    self.cache = cache
    self.gmailBaseURL = gmailBaseURL
    self.keyMaterialStore = keyMaterialStore
    self.oauthClientId = oauthClientId
    self.session = session
    self.tokenStore = tokenStore
    self.tokenRefreshURL = tokenRefreshURL
    self.tokenInfoURL = tokenInfoURL
  }

  func loadMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) async throws -> GmailMessageBody {
    let material = try requiredKeyMaterial(productAccountId: session.productAccountId)
    let cached: ProductSyncEncryptedPayload?
    do {
      cached = try cache.loadMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
    } catch {
      try? cache.removeMessageBody(
        productAccountId: session.productAccountId,
        stableProviderMessageId: message.stableProviderMessageId
      )
      cached = nil
    }
    if let cached {
      do {
        let decrypted = try material.decryptPayload(
          cached, associatedData: associatedData(for: message))
        guard let text = String(bytes: decrypted, encoding: .utf8) else {
          throw GmailMessageBodyError.missingMessageBody
        }
        return GmailMessageBody(text: text)
      } catch {
        try? cache.removeMessageBody(
          productAccountId: session.productAccountId,
          stableProviderMessageId: message.stableProviderMessageId
        )
      }
    }

    guard let tokens = try tokenStore.load(productAccountId: session.productAccountId) else {
      throw GmailMessageBodyError.missingLocalGmailTokens
    }
    let refreshedTokens = try await refreshedTokens(
      tokens, productAccountId: session.productAccountId)
    try await validateRefreshedToken(
      refreshedTokens.accessToken,
      providerAccountIdentifier: message.providerAccountIdentifier
    )
    let body = try await fetchMessageBody(
      message: message, accessToken: refreshedTokens.accessToken)
    try? cache.saveMessageBody(
      material.encryptPayload(Data(body.text.utf8), associatedData: associatedData(for: message)),
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
    return body
  }

  func removeCachedMessageBody(
    message: GmailMessageMetadata,
    session: ProductAccountSessionSnapshot
  ) throws {
    try cache.removeMessageBody(
      productAccountId: session.productAccountId,
      stableProviderMessageId: message.stableProviderMessageId
    )
  }

  func clearCachedMessageBodies(session: ProductAccountSessionSnapshot) throws {
    try cache.clearMessageBodies(productAccountId: session.productAccountId)
  }

  private func fetchMessageBody(
    message: GmailMessageMetadata,
    accessToken: String
  ) async throws -> GmailMessageBody {
    var components = URLComponents(
      url: gmailBaseURL.appendingPathComponent("users/me/messages/\(message.providerMessageId)"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "format", value: "full")]
    guard let url = components?.url else {
      throw GmailMessageBodyError.gmailRequestFailed
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw GmailMessageBodyError.gmailRequestFailed
    }

    let responseBody = try JSONDecoder().decode(GmailMessageBodyResponse.self, from: data)
    guard let bodyPart = responseBody.payload.preferredBodyPart else {
      throw GmailMessageBodyError.missingMessageBody
    }
    let encodedBody = try await encodedBodyData(
      bodyPart: bodyPart,
      message: message,
      accessToken: accessToken
    )
    guard let data = Data(gmailBase64URLEncoded: encodedBody),
      let decodedText = String(data: data, encoding: bodyPart.textEncoding)
    else {
      throw GmailMessageBodyError.missingMessageBody
    }
    let text = bodyPart.mimeType == "text/html" ? htmlText(decodedText) : decodedText
    return GmailMessageBody(text: text)
  }

  private func refreshedTokens(
    _ tokens: GmailProviderTokens,
    productAccountId: String
  ) async throws -> GmailProviderTokens {
    guard let oauthClientId, !oauthClientId.isEmpty else {
      throw GmailMessageBodyError.missingOAuthClientId
    }
    var request = URLRequest(url: tokenRefreshURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncodedBody([
      "client_id": oauthClientId,
      "grant_type": "refresh_token",
      "refresh_token": tokens.refreshToken,
    ])
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let responseBody = try? JSONDecoder().decode(GmailMessageBodyTokenResponse.self, from: data),
      !responseBody.accessToken.isEmpty
    else {
      throw GmailMessageBodyError.refreshTokenRejected
    }
    let refreshedTokens = GmailProviderTokens(
      accessToken: responseBody.accessToken,
      refreshToken: tokens.refreshToken
    )
    try tokenStore.save(refreshedTokens, productAccountId: productAccountId)
    return refreshedTokens
  }

  private func formURLEncodedBody(_ fields: [String: String]) -> Data {
    fields.map { "\(formURLEncode($0.key))=\(formURLEncode($0.value))" }
      .joined(separator: "&").data(using: .utf8) ?? Data()
  }

  private func formURLEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private func validateRefreshedToken(
    _ accessToken: String,
    providerAccountIdentifier: String
  ) async throws {
    var components = URLComponents(url: tokenInfoURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
    guard let url = components?.url else { throw GmailMessageBodyError.gmailRequestFailed }
    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let tokenInfo = try? JSONDecoder().decode(GmailMessageBodyTokenInfo.self, from: data),
      tokenInfo.sub == providerAccountIdentifier
    else { throw GmailMessageBodyError.gmailRequestFailed }
  }

  private func encodedBodyData(
    bodyPart: GmailMessageBodyPart,
    message: GmailMessageMetadata,
    accessToken: String
  ) async throws -> String {
    if let data = bodyPart.body?.data {
      return data
    }
    guard let attachmentId = bodyPart.body?.attachmentId else {
      throw GmailMessageBodyError.missingMessageBody
    }
    var request = URLRequest(
      url: gmailBaseURL.appendingPathComponent(
        "users/me/messages/\(message.providerMessageId)/attachments/\(attachmentId)"
      )
    )
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let attachment = try? JSONDecoder().decode(GmailMessageBodyAttachment.self, from: data),
      let encodedBody = attachment.data
    else {
      throw GmailMessageBodyError.gmailRequestFailed
    }
    return encodedBody
  }

  private func requiredKeyMaterial(productAccountId: String) throws -> ProductSyncKeyMaterial {
    guard let material = try keyMaterialStore.load(productAccountId: productAccountId) else {
      throw ProductSyncKeyMaterialStoreError.recoveryRequired
    }
    return material
  }

  private func associatedData(for message: GmailMessageMetadata) -> Data {
    Data("gmail-body-cache:\(message.stableProviderMessageId)".utf8)
  }

  private func htmlText(_ value: String) -> String {
    let withoutNonVisibleBlocks = value.replacingOccurrences(
      of: "<(?:script|style)\\b[^>]*>[\\s\\S]*?</(?:script|style)\\s*>",
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    let withLineBreaks = withoutNonVisibleBlocks.replacingOccurrences(
      of: "<(?:br\\s*/?|/p|/div|/li|/h[1-6]|/tr|/?t[dh])\\s*>",
      with: "\n",
      options: [.regularExpression, .caseInsensitive]
    )
    let withoutTags = withLineBreaks.replacingOccurrences(
      of: "<[^>]+>", with: "", options: .regularExpression)
    return
      withoutTags
      .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
  }
}

private struct GmailMessageBodyResponse: Decodable {
  let payload: GmailMessageBodyPart
}

private struct GmailMessageBodyPart: Decodable {
  let body: GmailMessageBodyData?
  let filename: String?
  let headers: [GmailMessageBodyHeader]?
  let mimeType: String?
  let parts: [GmailMessageBodyPart]?

  var preferredBodyPart: GmailMessageBodyPart? {
    if !isAttachment, mimeType == "text/plain", hasNonEmptyBodyData {
      return self
    }
    if let plainTextPart = parts?.lazy.compactMap(\.preferredNonEmptyPlainTextPart).first {
      return plainTextPart
    }
    if !isAttachment, mimeType == "text/html", hasNonEmptyBodyData {
      return self
    }
    if let htmlPart = parts?.lazy.compactMap(\.preferredNonEmptyHTMLPart).first {
      return htmlPart
    }
    if !isAttachment, mimeType == "text/plain", hasBodyData {
      return self
    }
    if let plainTextPart = parts?.lazy.compactMap(\.preferredPlainTextPart).first {
      return plainTextPart
    }
    if !isAttachment, mimeType == "text/html", hasBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredHTMLPart).first
  }

  private var preferredNonEmptyPlainTextPart: GmailMessageBodyPart? {
    if !isAttachment, mimeType == "text/plain", hasNonEmptyBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredNonEmptyPlainTextPart).first
  }

  private var preferredPlainTextPart: GmailMessageBodyPart? {
    if !isAttachment, mimeType == "text/plain", hasBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredPlainTextPart).first
  }

  private var preferredHTMLPart: GmailMessageBodyPart? {
    if !isAttachment, mimeType == "text/html", hasBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredHTMLPart).first
  }

  private var preferredNonEmptyHTMLPart: GmailMessageBodyPart? {
    if !isAttachment, mimeType == "text/html", hasNonEmptyBodyData {
      return self
    }
    return parts?.lazy.compactMap(\.preferredNonEmptyHTMLPart).first
  }

  var textEncoding: String.Encoding {
    guard
      let contentType = headers?.first(where: {
        $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
      })?.value,
      let charset = contentType.split(separator: ";").first(where: {
        $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("charset=")
      })?.split(separator: "=", maxSplits: 1).last,
      CFStringConvertIANACharSetNameToEncoding(
        charset.trimmingCharacters(
          in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) as CFString
      ) != kCFStringEncodingInvalidId
    else {
      return .utf8
    }
    let encoding = CFStringConvertIANACharSetNameToEncoding(
      charset.trimmingCharacters(
        in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) as CFString
    )
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
  }

  private var isAttachment: Bool {
    guard filename?.isEmpty != false else { return true }
    return headers?.contains {
      $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame
        && $0.value.lowercased().contains("attachment")
    } == true
  }

  private var hasBodyData: Bool {
    body?.attachmentId != nil || body?.data != nil
  }

  private var hasNonEmptyBodyData: Bool {
    body?.attachmentId != nil || body?.data?.isEmpty == false
  }
}

private struct GmailMessageBodyData: Decodable {
  let attachmentId: String?
  let data: String?
}

private struct GmailMessageBodyHeader: Decodable {
  let name: String
  let value: String
}

private struct GmailMessageBodyAttachment: Decodable {
  let data: String?
}

private struct GmailMessageBodyTokenResponse: Decodable {
  let accessToken: String

  enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

private struct GmailMessageBodyTokenInfo: Decodable { let sub: String? }

extension Data {
  fileprivate init?(gmailBase64URLEncoded value: String) {
    var base64 =
      value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    self.init(base64Encoded: base64)
  }
}
