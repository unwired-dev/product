import Foundation

struct IdentityTokenClaims: Decodable {
  static let google: Set = ["https://accounts.google.com", "accounts.google.com"]
  static let apple: Set = ["https://appleid.apple.com"]

  let iss: String
  let aud: String
  let sub: String
  let exp: Double
  let nonce: String?
  let email: String?

  // Only called with an ID token obtained by the platform SDK over its TLS token exchange.
  // Convex independently verifies the JWT signature and audience before account access.
  @discardableResult static func validate(
    _ token: String, issuers: Set<String>, audience: String, subject: String,
    nonce: String? = nil, now: Date = Date()
  ) throws -> Self {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw RegistrationError.invalidIdentity }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let bytes = Data(base64Encoded: payload) else { throw RegistrationError.invalidIdentity }
    let claims = try JSONDecoder().decode(Self.self, from: bytes)
    guard issuers.contains(claims.iss), claims.aud == audience, claims.sub == subject,
      !subject.isEmpty, claims.exp.isFinite, claims.exp > now.timeIntervalSince1970,
      nonce == nil || claims.nonce == nonce
    else { throw RegistrationError.invalidIdentity }
    return claims
  }
}
