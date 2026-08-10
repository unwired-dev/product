import Foundation

#if DEBUG || MAIL_TEST_BOOTSTRAP
  enum MailTestBootstrapError: LocalizedError, Equatable {
    case invalidConfiguration(String)

    var errorDescription: String? {
      switch self {
      case .invalidConfiguration(let field):
        return
          "Mail Test Bootstrap requires a valid \(field). Run `mise exec -- pnpm mail:test doctor` and retry."
      }
    }
  }

  struct MailTestBootstrapConfiguration: Equatable {
    static let enabledKey = "MAIL_TEST_BOOTSTRAP"
    static let emailAddress = "inbox@synthetic.invalid"
    static let password = "synthetic-test-password"

    let host: String
    let imapsPort: Int
    let runId: String
    let smtpsPort: Int

    static func load(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MailTestBootstrapConfiguration? {
      guard environment[enabledKey] == "1" else { return nil }
      let host = try requiredValue("MAIL_TEST_HOST", environment: environment)
      guard host == "127.0.0.1" || host == "localhost" else {
        throw MailTestBootstrapError.invalidConfiguration("loopback mail endpoint")
      }
      let runId = try requiredValue("MAIL_TEST_RUN_ID", environment: environment)
      guard UUID(uuidString: runId) != nil else {
        throw MailTestBootstrapError.invalidConfiguration("run identifier")
      }
      return MailTestBootstrapConfiguration(
        host: host,
        imapsPort: try port("MAIL_TEST_IMAPS_PORT", environment: environment),
        runId: runId,
        smtpsPort: try port("MAIL_TEST_SMTPS_PORT", environment: environment)
      )
    }

    private static func requiredValue(
      _ key: String,
      environment: [String: String]
    ) throws -> String {
      guard let value = environment[key], !value.isEmpty else {
        throw MailTestBootstrapError.invalidConfiguration(key)
      }
      return value
    }

    private static func port(
      _ key: String,
      environment: [String: String]
    ) throws -> Int {
      let value = try requiredValue(key, environment: environment)
      guard let port = Int(value), (1...65_535).contains(port) else {
        throw MailTestBootstrapError.invalidConfiguration(key)
      }
      return port
    }
  }

  enum MailTestBootstrapKeyMaterial {
    static func prepare(
      productAccountId: String,
      store: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore()
    ) throws {
      _ = try store.ensureMaterial(
        productAccountId: productAccountId,
        allowCreation: true
      )
    }
  }
#endif

#if MAIL_TEST_BOOTSTRAP
  #if !DEBUG
    #error("MAIL_TEST_BOOTSTRAP may only be compiled into a Debug build.")
  #endif

  @MainActor
  final class MailTestBootstrapRuntime {
    let genericMailSetupService: GenericMailSetupService
    let mailboxConnection: IMAPMailboxConnectionAdapter
    let session: ProductAccountSession

    init(
      configuration: MailTestBootstrapConfiguration,
      messageContentPreferences: MessageContentPreferences
    ) throws {
      let definition = Self.connectionDefinition(configuration: configuration)
      let snapshot = ProductAccountSessionSnapshot(
        appleUserIdentifier: "mail-test-\(configuration.runId)",
        identityToken: "mail-test-local-token",
        productAccountId: "mail-test-\(configuration.runId)",
        trustedDeviceId: "mail-test-device-\(configuration.runId)"
      )
      try MailTestBootstrapKeyMaterial.prepare(
        productAccountId: snapshot.productAccountId
      )
      let definitionSyncService = MailTestDefinitionSyncService(
        definition: definition
      )
      let authorizationStore = KeychainGenericMailAuthorizationStore()
      try authorizationStore.save(
        DeviceLocalGenericMailAuthorization(
          authorizationGeneration: 0,
          credential: MailTestBootstrapConfiguration.password,
          definition: definition
        ),
        productAccountId: ProductAccountId(snapshot.productAccountId)
      )
      genericMailSetupService = GenericMailSetupService(
        authorizationStore: authorizationStore,
        definitionSyncService: definitionSyncService
      )
      mailboxConnection = IMAPMailboxConnectionAdapter(
        authorizationStore: authorizationStore,
        definitionSyncService: definitionSyncService
      )
      let session = ProductAccountSession(
        appleSignInService: SignInWithAppleService(),
        messageContentPreferences: messageContentPreferences
      )
      session.activateMailTestBootstrap(snapshot)
      self.session = session
    }

    private static func connectionDefinition(
      configuration: MailTestBootstrapConfiguration
    ) -> GenericMailConnectionDefinition {
      GenericMailConnectionDefinition(
        authorizationMethod: .password,
        emailAddress: MailTestBootstrapConfiguration.emailAddress,
        incomingEndpoint: GenericMailEndpoint(
          mailProtocol: .imap,
          hostname: configuration.host,
          port: configuration.imapsPort,
          security: .implicitTLS
        ),
        outgoingEndpoint: GenericMailEndpoint(
          mailProtocol: .smtp,
          hostname: configuration.host,
          port: configuration.smtpsPort,
          security: .implicitTLS
        ),
        roleMappings: [
          .archive: "Archive",
          .drafts: "Drafts",
          .sent: "Sent",
          .spam: "Spam",
          .trash: "Trash",
        ],
        username: MailTestBootstrapConfiguration.emailAddress
      )
    }
  }

  private final class MailTestDefinitionSyncService:
    MailboxConnectionDefinitionSyncing
  {
    private let snapshot: MailboxConnectionSyncSnapshot

    init(definition: GenericMailConnectionDefinition) {
      let synchronizedDefinition = definition.synchronizedDefinition(
        authorizationGeneration: 0,
        connectedAt: 1
      )
      snapshot = MailboxConnectionSyncSnapshot(
        connections: [synchronizedDefinition],
        defaultSendingConnectionId: synchronizedDefinition.id,
        removedConnectionIds: [],
        updatedAt: 1
      )
    }

    func loadSnapshot(
      session _: ProductAccountSessionSnapshot
    ) async throws -> MailboxConnectionSyncSnapshot {
      snapshot
    }

    func reconcileConnections(
      _: [MailboxConnectionDefinition],
      session _: ProductAccountSessionSnapshot
    ) async throws -> MailboxConnectionSyncSnapshot {
      snapshot
    }

    func removeConnection(
      _: MailboxConnectionId,
      session _: ProductAccountSessionSnapshot
    ) async throws -> MailboxConnectionSyncSnapshot {
      throw MailboxConnectionAdapterError.unsupportedCapability
    }

    func recreateDefinition(
      _: MailboxConnectionDefinition,
      after _: MailboxConnectionRemovalObservation?,
      session _: ProductAccountSessionSnapshot
    ) async throws -> MailboxConnectionSyncSnapshot {
      throw MailboxConnectionAdapterError.unsupportedCapability
    }

    func saveConnection(
      _: MailboxConnection,
      session _: ProductAccountSessionSnapshot
    ) async throws -> MailboxConnectionSyncSnapshot {
      throw MailboxConnectionAdapterError.unsupportedCapability
    }

    func saveDefinition(
      _: MailboxConnectionDefinition,
      session _: ProductAccountSessionSnapshot
    ) async throws -> MailboxConnectionSyncSnapshot {
      throw MailboxConnectionAdapterError.unsupportedCapability
    }

    func setDefaultSendingConnection(
      _: MailboxConnectionId?,
      session _: ProductAccountSessionSnapshot
    ) async throws -> MailboxConnectionSyncSnapshot {
      throw MailboxConnectionAdapterError.unsupportedCapability
    }
  }
#endif
