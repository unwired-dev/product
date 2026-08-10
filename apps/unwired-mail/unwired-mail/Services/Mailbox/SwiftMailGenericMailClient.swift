import Foundation

struct SwiftMailGenericMailConnectionVerifier: GenericMailConnectionVerifying {
  private let engine: any MailEngine

  init(engine: any MailEngine = ExperimentalSwiftMailEngine()) {
    self.engine = engine
  }

  func verify(
    definition: GenericMailConnectionDefinition,
    credential: String
  ) async throws -> GenericMailConnectionVerification {
    do {
      let connection = try await engine.connect(
        configuration: try SwiftMailGenericMailBridge.configuration(
          definition: definition,
          credential: credential
        ),
        logger: SilentMailEngineLogger()
      )
      do {
        guard
          connection.snapshot.minimumTLSVersions[.imap].map({ $0 >= .tls12 }) == true
        else {
          throw GenericMailSetupError.secureTransportRequired(.imap)
        }
        guard
          connection.snapshot.minimumTLSVersions[.smtp].map({ $0 >= .tls12 }) == true
        else {
          throw GenericMailSetupError.secureTransportRequired(.smtp)
        }
        let verification = Self.verification(connection.snapshot)
        await connection.session.close()
        return verification
      } catch {
        await connection.session.close()
        throw error
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch MailEngineError.cancelled {
      throw CancellationError()
    } catch MailEngineError.authenticationRejected {
      throw GenericMailSetupError.authenticationFailed(.imap)
    } catch MailEngineError.certificateRejected,
      MailEngineError.serverIdentityMismatch,
      MailEngineError.startTLSRejected,
      MailEngineError.tlsVersionUnsupported
    {
      throw GenericMailSetupError.secureTransportRequired(.imap)
    } catch let error as GenericMailSetupError {
      throw error
    } catch {
      throw GenericMailSetupError.invalidEndpoint(.imap)
    }
  }

  private static func verification(
    _ snapshot: MailEngineConnectionSnapshot
  ) -> GenericMailConnectionVerification {
    let mailboxes = snapshot.mailboxes.filter(\.isSelectable)
    var discoveredRoleMappings: [CanonicalMailboxRole: String] = [:]
    for (role, specialUse) in SwiftMailGenericMailBridge.roles {
      let candidates = Set(
        mailboxes.compactMap { mailbox in
          mailbox.specialUses.contains(specialUse) ? mailbox.identity.rawValue : nil
        }
      )
      if candidates.count == 1 {
        discoveredRoleMappings[role] = candidates.first
      }
    }
    return GenericMailConnectionVerification(
      discoveredRoleMappings: discoveredRoleMappings,
      mailboxes: mailboxes.map {
        GenericMailServerMailbox(
          canonicalName: $0.identity.rawValue,
          displayName: SwiftMailGenericMailBridge.displayName(for: $0.identity.rawValue)
        )
      }
    )
  }
}

struct SwiftMailInitialMailboxLoader: IMAPInitialMailboxLoading {
  private let engine: any MailEngine

  init(engine: any MailEngine = ExperimentalSwiftMailEngine()) {
    self.engine = engine
  }

  func loadInitialMailbox(
    authorization: DeviceLocalGenericMailAuthorization,
    limit: Int
  ) async throws -> [IMAPInitialMailboxPage] {
    guard authorization.definition.incomingEndpoint.mailProtocol == .imap else {
      throw MailboxConnectionAdapterError.unsupportedProvider
    }
    guard (1...IMAPMessageMetadataService.initialPageSize).contains(limit) else {
      throw IMAPMailboxError.invalidProviderResponse
    }

    do {
      let connection = try await engine.connect(
        configuration: try SwiftMailGenericMailBridge.configuration(
          definition: authorization.definition,
          credential: authorization.credential
        ),
        logger: SilentMailEngineLogger()
      )
      do {
        let pages = try await loadPages(
          snapshot: connection.snapshot,
          session: connection.session,
          connectionId: authorization.definition.connectionId,
          limit: limit
        )
        await connection.session.close()
        return pages
      } catch {
        await connection.session.close()
        throw error
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch MailEngineError.cancelled {
      throw CancellationError()
    } catch MailEngineError.authenticationRejected {
      throw MailboxConnectionAdapterError.authorizationRequired
    } catch MailEngineError.operationUnsupported {
      throw MailboxConnectionAdapterError.unsupportedProvider
    } catch let error as MailboxConnectionAdapterError {
      throw error
    } catch let error as IMAPMailboxError {
      throw error
    } catch {
      throw IMAPMailboxError.invalidProviderResponse
    }
  }

  private func loadPages(
    snapshot: MailEngineConnectionSnapshot,
    session: any MailEngineSession,
    connectionId: MailboxConnectionId,
    limit: Int
  ) async throws -> [IMAPInitialMailboxPage] {
    let mailboxes = snapshot.mailboxes.filter(\.isSelectable).sorted {
      $0.identity.rawValue.localizedCaseInsensitiveCompare($1.identity.rawValue)
        == .orderedAscending
    }
    var result: [IMAPInitialMailboxPage] = []
    for mailbox in mailboxes {
      try Task.checkCancellation()
      let page = try await session.loadMetadataPage(
        mailbox: mailbox.identity,
        beforeUID: nil,
        limit: limit
      )
      guard
        page.messages.allSatisfy({ message in
          message.identity.connectionID == connectionId.rawValue
            && message.identity.mailbox == mailbox.identity
            && message.identity.uidValidity == page.uidValidity
        })
      else { throw IMAPMailboxError.invalidProviderResponse }
      result.append(
        IMAPInitialMailboxPage(
          descriptor: IMAPMailboxDescriptor(
            displayName: SwiftMailGenericMailBridge.displayName(for: mailbox.identity.rawValue),
            name: mailbox.identity.rawValue
          ),
          page: IMAPMetadataPage(
            messages: page.messages.map(Self.providerMessage),
            nextOlderUID: page.nextOlderUID,
            uidValidity: page.uidValidity
          )
        )
      )
    }
    return result
  }

  private static func providerMessage(
    _ metadata: MailEngineMessageMetadata
  ) -> IMAPProviderMessage {
    IMAPProviderMessage(
      cc: metadata.carbonCopyRecipients.nilIfEmpty?.joined(separator: ", "),
      flags: metadata.flags.sorted(),
      from: metadata.from,
      inReplyTo: metadata.inReplyTo,
      internalDateMilliseconds: Int64(metadata.internalDate.timeIntervalSince1970 * 1_000),
      mailbox: metadata.identity.mailbox.rawValue,
      providerThreadId: nil,
      references: metadata.references,
      replyTo: metadata.replyTo,
      rfcMessageId: metadata.rfcMessageID,
      snippet: "",
      subject: metadata.subject ?? "",
      to: metadata.recipients.nilIfEmpty?.joined(separator: ", "),
      uid: metadata.identity.uid,
      uidValidity: metadata.identity.uidValidity
    )
  }
}

private enum SwiftMailGenericMailBridge {
  static let roles: [(CanonicalMailboxRole, MailEngineSpecialUse)] = [
    (.archive, .archive),
    (.drafts, .drafts),
    (.sent, .sent),
    (.spam, .spam),
    (.trash, .trash),
  ]

  static func configuration(
    definition: GenericMailConnectionDefinition,
    credential: String
  ) throws -> MailEngineConfiguration {
    guard definition.incomingEndpoint.mailProtocol == .imap,
      definition.outgoingEndpoint.mailProtocol == .smtp
    else { throw MailboxConnectionAdapterError.unsupportedProvider }
    let authorization: MailEngineAuthorization =
      switch definition.authorizationMethod {
      case .oauth:
        .xoauth2(username: definition.username, accessToken: credential)
      case .appPassword, .password:
        .password(username: definition.username, password: credential)
      }
    return MailEngineConfiguration(
      authorization: authorization,
      connectionID: definition.connectionId.rawValue,
      imapEndpoint: endpoint(definition.incomingEndpoint),
      minimumTLSVersion: .tls12,
      smtpEndpoint: endpoint(definition.outgoingEndpoint)
    )
  }

  static func displayName(for canonicalName: String) -> String {
    var result = ""
    var index = canonicalName.startIndex
    while index < canonicalName.endIndex {
      guard canonicalName[index] == "&" else {
        result.append(canonicalName[index])
        index = canonicalName.index(after: index)
        continue
      }
      guard let end = canonicalName[index...].firstIndex(of: "-") else {
        result.append(contentsOf: canonicalName[index...])
        break
      }
      let encodedStart = canonicalName.index(after: index)
      let encoded = String(canonicalName[encodedStart..<end])
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
          result.append(contentsOf: canonicalName[index...end])
        }
      }
      index = canonicalName.index(after: end)
    }
    return result
  }

  private static func endpoint(_ endpoint: GenericMailEndpoint) -> MailEngineEndpoint {
    MailEngineEndpoint(
      hostname: endpoint.hostname,
      port: endpoint.port,
      transportMode: endpoint.security == .implicitTLS ? .implicitTLS : .startTLS
    )
  }
}

private struct SilentMailEngineLogger: MailEngineLogging {
  func record(_: MailEngineDiagnosticEvent) {}

  func recordProtocolTrace(_: Data) {}
}

extension Collection {
  fileprivate var nilIfEmpty: Self? { isEmpty ? nil : self }
}
