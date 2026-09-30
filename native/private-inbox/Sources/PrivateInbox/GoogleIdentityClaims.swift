import Foundation

struct GoogleIdentityClaims: Decodable {
  let iss: String
  let aud: String
  let sub: String
  let exp: Double
  let nonce: String?

  // Only called with an ID token obtained by the SDK from Google's TLS token endpoint.
  // Convex independently verifies the JWT signature and audience before account access.
  static func validate(
    _ token: String, clientID: String, subject: String, nonce: String? = nil, now: Date = Date()
  ) throws {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw RegistrationError.invalidIdentity }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let bytes = Data(base64Encoded: payload) else { throw RegistrationError.invalidIdentity }
    let claims = try JSONDecoder().decode(Self.self, from: bytes)
    guard ["https://accounts.google.com", "accounts.google.com"].contains(claims.iss),
      claims.aud == clientID, claims.sub == subject, !subject.isEmpty,
      claims.exp.isFinite, claims.exp > now.timeIntervalSince1970,
      nonce == nil || claims.nonce == nonce
    else { throw RegistrationError.invalidIdentity }
  }
}
