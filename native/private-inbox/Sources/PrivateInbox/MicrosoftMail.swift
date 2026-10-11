import CryptoKit
import Foundation

// A Microsoft authorization for reading mail through Graph. The account it names is known only
// once Graph verifies it.
struct MicrosoftMailIdentity {
  // The archived tokens, which only this device's Keychain record keeps.
  let credential: Data
  let accessToken: String
  let scopes: Set<String>
}

@MainActor protocol MicrosoftMailProvider {
  // An interactive authorization; `hint` suggests the account a connection already names.
  func signIn(hint: String?) async throws -> MicrosoftMailIdentity
  // The authorization with a current access token; Microsoft refusing it is gmailUnavailable.
  func refresh(_ credential: Data) async throws -> MicrosoftMailIdentity
  // The account and its mail through Graph; no Outlook mailbox or a refusal is gmailUnavailable.
  func verify(_ identity: MicrosoftMailIdentity) async throws -> GmailRegistrationReceipt
  // One Graph read; HTTP failures are returned, not thrown.
  func graph(_ identity: MicrosoftMailIdentity, url: URL) async throws -> (Int, Data)
}

// The tokens a Microsoft Mailbox Connection keeps as its credential.
struct MicrosoftTokens: Codable {
  let accessToken: String
  let refreshToken: String
  let expiresAt: Date
  let scopes: [String]

  var identity: MicrosoftMailIdentity {
    get throws {
      MicrosoftMailIdentity(
        credential: try JSONEncoder().encode(self), accessToken: accessToken,
        scopes: Set(scopes))
    }
  }
}

// The Microsoft identity platform's authorization code flow with PKCE for a public client, and
// Graph's account and mailbox checks. Presenting the web session is the host's.
@MainActor final class GraphMailProvider: MicrosoftMailProvider {
  // Reading mail only; organizing and sending ask for more when they are offered.
  static let scopes = "offline_access User.Read Mail.Read"
  static let authority = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0")!
  static let graph = "https://graph.microsoft.com/v1.0"

  let clientID: String
  let callbackScheme: String
  // Presents the authorization page and resolves the callback URL; cancelling throws cancelled.
  let authenticate: @MainActor (URL, String) async throws -> URL
  let session: URLSession
  let now: () -> Date

  init(
    clientID: String, callbackScheme: String,
    authenticate: @escaping @MainActor (URL, String) async throws -> URL,
    session: URLSession = URLSession(configuration: .ephemeral),
    now: @escaping () -> Date = Date.init
  ) {
    self.clientID = clientID
    self.callbackScheme = callbackScheme
    self.authenticate = authenticate
    self.session = session
    self.now = now
  }

  var redirectURI: String { callbackScheme + "://auth" }

  func signIn(hint: String?) async throws -> MicrosoftMailIdentity {
    let verifier = Self.randomToken()
    let state = Self.randomToken()
    var components = URLComponents(
      url: Self.authority.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_mode", value: "query"),
      URLQueryItem(name: "scope", value: Self.scopes),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      hint.map { URLQueryItem(name: "login_hint", value: $0) }
        ?? URLQueryItem(name: "prompt", value: "select_account"),
    ]
    guard let url = components.url else { throw RegistrationError.unavailable }
    let callback = try await authenticate(url, callbackScheme)
    let code = try Self.authorizationCode(callback, state: state, callbackScheme: callbackScheme)
    return try await exchange([
      "client_id": clientID, "grant_type": "authorization_code", "code": code,
      "redirect_uri": redirectURI, "code_verifier": verifier, "scope": Self.scopes,
    ]).identity
  }

  func refresh(_ credential: Data) async throws -> MicrosoftMailIdentity {
    let tokens = try JSONDecoder().decode(MicrosoftTokens.self, from: credential)
    // A token valid for a few more minutes serves this request without asking Microsoft.
    if tokens.expiresAt.timeIntervalSince(now()) > 300 { return try tokens.identity }
    return try await exchange(
      [
        "client_id": clientID, "grant_type": "refresh_token",
        "refresh_token": tokens.refreshToken, "scope": Self.scopes,
      ], previous: tokens
    ).identity
  }

  func verify(_ identity: MicrosoftMailIdentity) async throws -> GmailRegistrationReceipt {
    struct Account: Decodable {
      let id: String
      let mail: String?
      let userPrincipalName: String?
    }
    let account = try JSONDecoder().decode(
      Account.self,
      from: try await verified(identity, Self.graph + "/me?$select=id,mail,userPrincipalName"))
    // An account without Exchange Online, or a tenant refusing Graph mail, has no Inbox here.
    _ = try await verified(identity, Self.graph + "/me/mailFolders/inbox?$select=id")
    let address = [account.mail, account.userPrincipalName].compactMap { $0 }.first {
      $0.contains("@")
    }
    guard !account.id.isEmpty, let address else { throw RegistrationError.gmailUnavailable }
    return GmailRegistrationReceipt(
      subject: account.id, address: address, provider: .microsoftGraph)
  }

  func graph(_ identity: MicrosoftMailIdentity, url: URL) async throws -> (Int, Data) {
    try await GmailTransport.send(
      token: identity.accessToken, url: url, body: nil, session: session,
      headers: ["Prefer": #"IdType="ImmutableId", odata.maxpagesize=50"#])
  }

  // A Graph read during verification: a refusal or missing mailbox is gmailUnavailable; a busy
  // or unreachable service is a transient failure.
  private func verified(_ identity: MicrosoftMailIdentity, _ value: String) async throws -> Data {
    guard let url = URL(string: value) else { throw RegistrationError.unavailable }
    let (status, data): (Int, Data)
    do {
      (status, data) = try await graph(identity, url: url)
    } catch is GmailRequestInterrupted {
      throw RegistrationError.unavailable
    }
    if status == 429 || status >= 500 { throw URLError(.cannotConnectToHost) }
    guard status == 200 else { throw RegistrationError.gmailUnavailable }
    return data
  }

  // The token endpoint's answer. Microsoft refusing the grant needs authorization again; any
  // other failure can be retried.
  private func exchange(_ form: [String: String], previous: MicrosoftTokens? = nil) async throws
    -> MicrosoftTokens
  {
    // Token forms contain credentials too: bound their replies and refuse every redirect.
    let (status, data): (Int, Data)
    do {
      (status, data) = try await GmailTransport.send(
        token: nil, url: Self.authority.appendingPathComponent("token"),
        body: Data(Self.form(form).utf8), session: session, limit: 1024 * 1024,
        contentType: "application/x-www-form-urlencoded")
    } catch is GmailRequestInterrupted {
      throw URLError(.cannotConnectToHost)
    }
    struct Reply: Decodable {
      let accessToken: String?
      let refreshToken: String?
      let expiresIn: Double?
      let scope: String?
      let error: String?
      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresIn = "expires_in", scope, error
      }
    }
    let reply = try? JSONDecoder().decode(Reply.self, from: data)
    if reply?.error == "invalid_grant" || reply?.error == "interaction_required" {
      throw RegistrationError.gmailUnavailable
    }
    if status == 429 || status >= 500 { throw URLError(.cannotConnectToHost) }
    guard status == 200, let reply, let access = reply.accessToken, !access.isEmpty,
      let refresh = reply.refreshToken ?? previous?.refreshToken, let expires = reply.expiresIn
    else { throw RegistrationError.unavailable }
    return MicrosoftTokens(
      accessToken: access, refreshToken: refresh,
      expiresAt: now().addingTimeInterval(expires),
      scopes: reply.scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes
        ?? [])
  }

  // The code from the authorization callback for this request. A refused or cancelled consent is
  // declined; a tenant or account Microsoft does not admit is gmailUnavailable.
  static func authorizationCode(_ callback: URL, state: String, callbackScheme: String) throws -> String {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value = { (name: String) in items.first { $0.name == name }?.value }
    guard callback.scheme == callbackScheme, callback.host == "auth", callback.path.isEmpty,
      callback.port == nil, callback.user == nil, callback.password == nil, callback.fragment == nil,
      items.filter({ $0.name == "state" }).count == 1, value("state") == state
    else { throw RegistrationError.unavailable }
    if let error = value("error") {
      switch error {
      case "access_denied": throw RegistrationError.declined
      case "invalid_request", "server_error", "temporarily_unavailable":
        throw RegistrationError.unavailable
      default: throw RegistrationError.gmailUnavailable
      }
    }
    guard items.filter({ $0.name == "code" }).count == 1, let code = value("code"), !code.isEmpty else {
      throw RegistrationError.unavailable
    }
    return code
  }

  static func form(_ fields: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.sorted { $0.key < $1.key }.map {
      $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }.joined(separator: "&")
  }

  static func randomToken() -> String {
    base64URL(Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }))
  }

  static func challenge(_ verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
