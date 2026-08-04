import Foundation
import Security

struct BundledMailProviderCatalog: GenericMailEndpointDiscovering {
  func discover(emailAddress: String) -> GenericMailDiscoveryResult? {
    guard let domain = normalizedDomain(emailAddress) else { return nil }

    switch domain {
    case "icloud.com", "mac.com", "me.com":
      return GenericMailDiscoveryResult(
        incomingEndpoints: [
          GenericMailEndpoint(
            mailProtocol: .imap,
            hostname: "imap.mail.me.com",
            port: 993,
            security: .implicitTLS
          )
        ],
        outgoingEndpoint: GenericMailEndpoint(
          mailProtocol: .smtp,
          hostname: "smtp.mail.me.com",
          port: 587,
          security: .startTLS
        ),
        preferredAuthorizationMethod: .appPassword,
        sourceName: "Reviewed iCloud Mail settings"
      )
    case "fastmail.com", "fastmail.fm":
      return GenericMailDiscoveryResult(
        incomingEndpoints: [
          GenericMailEndpoint(
            mailProtocol: .imap,
            hostname: "imap.fastmail.com",
            port: 993,
            security: .implicitTLS
          ),
          GenericMailEndpoint(
            mailProtocol: .pop3,
            hostname: "pop.fastmail.com",
            port: 995,
            security: .implicitTLS
          ),
        ],
        outgoingEndpoint: GenericMailEndpoint(
          mailProtocol: .smtp,
          hostname: "smtp.fastmail.com",
          port: 465,
          security: .implicitTLS
        ),
        preferredAuthorizationMethod: .appPassword,
        sourceName: "Reviewed Fastmail settings"
      )
    default:
      return nil
    }
  }

  private func normalizedDomain(_ emailAddress: String) -> String? {
    let components =
      emailAddress
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(separator: "@", omittingEmptySubsequences: false)
    guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
      return nil
    }
    return String(components[1])
  }
}

struct KeychainGenericMailAuthorizationStore: GenericMailAuthorizationPersisting {
  private let service = "private-email.generic-mail-authorization"

  func clearAll(productAccountId: ProductAccountId) throws {
    try KeychainStore.delete(service: service, account: productAccountId.rawValue)
  }

  func connectionIds(productAccountId: ProductAccountId) throws -> [MailboxConnectionId] {
    try loadAll(productAccountId: productAccountId).values
      .map(\.definition.connectionId)
      .sorted { $0.rawValue < $1.rawValue }
  }

  func load(
    productAccountId: ProductAccountId,
    emailAddress: String
  ) throws -> DeviceLocalGenericMailAuthorization? {
    let matchingAuthorizations = try loadAll(productAccountId: productAccountId).values
      .filter { $0.definition.emailAddress.lowercased() == emailAddress.lowercased() }
      .sorted { $0.definition.connectionId.rawValue < $1.definition.connectionId.rawValue }
    guard matchingAuthorizations.count < 2 else {
      throw GenericMailSetupError.ambiguousSavedSetup
    }
    return matchingAuthorizations.first
  }

  func load(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws -> DeviceLocalGenericMailAuthorization? {
    try loadAll(productAccountId: productAccountId).values.first {
      $0.definition.connectionId == connectionId
    }
  }

  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: ProductAccountId
  ) throws {
    var authorizations = try loadAll(productAccountId: productAccountId)
    authorizations = authorizations.filter {
      $0.value.definition.connectionId != authorization.definition.connectionId
    }
    authorizations[authorization.definition.connectionId.rawValue] = authorization
    try saveAll(authorizations, productAccountId: productAccountId)
  }

  func remove(
    productAccountId: ProductAccountId,
    connectionId: MailboxConnectionId
  ) throws {
    var authorizations = try loadAll(productAccountId: productAccountId)
    authorizations = authorizations.filter { $0.value.definition.connectionId != connectionId }
    try saveAll(authorizations, productAccountId: productAccountId)
  }

  private func loadAll(
    productAccountId: ProductAccountId
  ) throws -> [String: DeviceLocalGenericMailAuthorization] {
    guard
      let json = try KeychainStore.readString(service: service, account: productAccountId.rawValue),
      let data = json.data(using: .utf8)
    else { return [:] }
    return try JSONDecoder().decode(
      [String: DeviceLocalGenericMailAuthorization].self,
      from: data
    )
  }

  private func saveAll(
    _ authorizations: [String: DeviceLocalGenericMailAuthorization],
    productAccountId: ProductAccountId
  ) throws {
    guard !authorizations.isEmpty else {
      try clearAll(productAccountId: productAccountId)
      return
    }
    let data = try JSONEncoder().encode(authorizations)
    guard let json = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.unexpectedData
    }
    try KeychainStore.writeString(
      json,
      service: service,
      account: productAccountId.rawValue,
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    )
  }
}
