import XCTest

@testable import unwired_mail

// swiftlint:disable file_length type_body_length
final class GenericMailSetupServiceTests: XCTestCase {
  func testReviewedCatalogDiscoversIMAPSMTPAndPOP3Locally() {
    let catalog = BundledMailProviderCatalog()

    let fastmail = catalog.discover(emailAddress: "reader@fastmail.com")
    let iCloud = catalog.discover(emailAddress: "reader@icloud.com")

    XCTAssertEqual(fastmail?.incomingEndpoints.map(\.mailProtocol), [.imap, .pop3])
    XCTAssertEqual(fastmail?.outgoingEndpoint.mailProtocol, .smtp)
    XCTAssertEqual(fastmail?.outgoingEndpoint.security, .implicitTLS)
    XCTAssertEqual(fastmail?.preferredAuthorizationMethod, .appPassword)
    XCTAssertEqual(iCloud?.incomingEndpoints.map(\.mailProtocol), [.imap])
    XCTAssertEqual(iCloud?.outgoingEndpoint.security, .startTLS)
    XCTAssertNil(catalog.discover(emailAddress: "reader@unknown.example"))
  }

  @MainActor
  func testDiscoveredPOP3SelectionAppliesItsOwnEndpoint() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: RecordingGenericMailAuthorizationStore(),
        verifier: RecordingGenericMailEndpointVerifier()
      )
    )
    viewModel.emailAddress = "reader@fastmail.com"

    viewModel.discover()
    viewModel.selectIncomingProtocol(.pop3)

    XCTAssertEqual(viewModel.incomingHostname, "pop.fastmail.com")
    XCTAssertEqual(viewModel.incomingPort, "995")
    XCTAssertEqual(viewModel.incomingSecurity, .implicitTLS)
  }

  @MainActor
  func testFailedDiscoveryClearsEndpointsAndMappingsFromPreviousProvider() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    viewModel.emailAddress = "reader@fastmail.com"
    viewModel.discover()
    viewModel.roleMappings[.sent] = "Sent from previous provider"

    viewModel.emailAddress = "reader@unknown.example"
    viewModel.discover()

    XCTAssertEqual(viewModel.incomingHostname, "")
    XCTAssertEqual(viewModel.incomingPort, "")
    XCTAssertEqual(viewModel.outgoingHostname, "")
    XCTAssertEqual(viewModel.outgoingPort, "")
    XCTAssertTrue(viewModel.roleMappings.isEmpty)
  }

  func testManualConfigurationVerifiesEveryEndpointBeforeSavingDeviceAuthorization()
    async throws
  {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    let definition = try await service.authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(verifier.endpoints.map(\.mailProtocol), [.imap, .smtp])
    XCTAssertEqual(definition.connectionId.rawValue, "imap-smtp:reader@example.com")
    XCTAssertEqual(store.productAccountId, ProductAccountId("product-account-001"))
    XCTAssertEqual(store.authorization?.credential, "device-only-secret")
    XCTAssertEqual(store.authorization?.definition, definition)
  }

  func testOpaqueCredentialWhitespaceIsPreservedForAuthenticationAndStorage() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    _ = try await service.authorize(
      draft: manualDraft(),
      credential: "  valid opaque password  ",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(
      verifier.credentials,
      ["  valid opaque password  ", "  valid opaque password  "]
    )
    XCTAssertEqual(store.authorization?.credential, "  valid opaque password  ")
  }

  func testTLSVersionBelow12IsRejectedBeforeAuthorizationIsPersisted() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        transportVersion: .olderThanTLS12
      )
    ]
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected a secure transport failure")
    } catch GenericMailSetupError.secureTransportRequired(.imap) {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
    XCTAssertEqual(verifier.endpoints.map(\.mailProtocol), [.imap])
  }

  func testCertificateFailureDoesNotPersistAuthorization() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.error = GenericMailSetupTestError.invalidCertificate
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected certificate validation to fail")
    } catch GenericMailSetupTestError.invalidCertificate {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testRejectedAuthenticationDoesNotPersistAuthorization() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: false,
        transportVersion: .tls12OrNewer
      )
    ]
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected authentication to fail")
    } catch GenericMailSetupError.authenticationFailed(.imap) {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testIMAPRequiresExplicitMailboxRoleMapping() async {
    let store = RecordingGenericMailAuthorizationStore()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    var draft = manualDraft()
    draft.roleMappings[.sent] = ""

    do {
      _ = try await service.authorize(
        draft: draft,
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001")
      )
      XCTFail("Expected an explicit role mapping failure")
    } catch let GenericMailSetupError.missingRoleMappings(_, missing) {
      XCTAssertEqual(missing, [.sent])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testUnambiguousIMAPSpecialUseRolesDoNotRequireManualMapping() async throws {
    let verifier = RecordingGenericMailEndpointVerifier()
    let discoveredRoles = Dictionary(
      uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { role in
        (role, "Provider \(role.displayName)")
      }
    )
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        discoveredRoleMappings: discoveredRoles,
        transportVersion: .tls12OrNewer
      )
    ]
    let service = GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: verifier
    )
    var draft = manualDraft()
    draft.roleMappings = [:]

    let definition = try await service.authorize(
      draft: draft,
      credential: "secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(definition.roleMappings, discoveredRoles)
  }

  func testPOP3UsesProductOwnedRolesWithoutPretendingToMapServerFolders() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: RecordingGenericMailEndpointVerifier()
    )
    var draft = manualDraft()
    draft.incomingEndpoint = GenericMailEndpoint(
      mailProtocol: .pop3,
      hostname: "pop.example.com",
      port: 995,
      security: .implicitTLS
    )
    draft.roleMappings = [:]

    let definition = try await service.authorize(
      draft: draft,
      credential: "secret",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(definition.connectionId.rawValue, "pop3-smtp:reader@example.com")
    XCTAssertTrue(definition.roleMappings.isEmpty)
  }

  func testOAuthCredentialUsesThePreferredXOAUTH2AuthorizationPath() async throws {
    let verifier = RecordingGenericMailEndpointVerifier()
    let service = GenericMailSetupService(
      authorizationStore: RecordingGenericMailAuthorizationStore(),
      verifier: verifier
    )
    var draft = manualDraft()
    draft.authorizationMethod = .oauth

    _ = try await service.authorize(
      draft: draft,
      credential: "oauth-access-token",
      productAccountId: ProductAccountId("product-account-001")
    )

    XCTAssertEqual(verifier.authorizationMethods, [.oauth, .oauth])
  }

  @MainActor
  func testUnknownManualSetupDoesNotAssumeOAuthSupport() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    viewModel.emailAddress = "reader@unknown.example"

    viewModel.discover()

    XCTAssertEqual(viewModel.authorizationMethod, .password)
  }

  @MainActor
  func testDiscoveringAnotherMailboxReplacesTheUsernameAndCredential() {
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true }
    )
    viewModel.emailAddress = "first@example.com"
    viewModel.username = "first@example.com"
    viewModel.credential = "first-secret"

    viewModel.emailAddress = "second@example.com"
    viewModel.discover()

    XCTAssertEqual(viewModel.username, "second@example.com")
    XCTAssertEqual(viewModel.credential, "")
  }

  @MainActor
  func testMailboxRoleInputsAppearOnlyAfterVerificationFindsAmbiguity() async {
    let verifier = RecordingGenericMailEndpointVerifier()
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: RecordingGenericMailAuthorizationStore(),
        verifier: verifier
      )
    )
    let draft = manualDraft()
    viewModel.emailAddress = draft.emailAddress
    viewModel.username = draft.username
    viewModel.incomingHostname = draft.incomingEndpoint.hostname
    viewModel.incomingPort = String(draft.incomingEndpoint.port)
    viewModel.outgoingHostname = draft.outgoingEndpoint.hostname
    viewModel.outgoingPort = String(draft.outgoingEndpoint.port)
    viewModel.credential = "secret"
    viewModel.roleMappings = [:]

    XCTAssertFalse(viewModel.showsMailboxRoles)

    await viewModel.connect()

    XCTAssertEqual(viewModel.rolesRequiringMapping, CanonicalMailboxRole.allCases)
    XCTAssertTrue(viewModel.showsMailboxRoles)
  }

  @MainActor
  func testSavedRoleMappingsAreNotReusedAfterEmailAddressChanges() async {
    let oldDefinition = GenericMailConnectionDefinition(
      authorizationMethod: .password,
      emailAddress: "old@example.com",
      incomingEndpoint: manualDraft().incomingEndpoint,
      outgoingEndpoint: manualDraft().outgoingEndpoint,
      roleMappings: manualDraft().roleMappings,
      username: "old@example.com"
    )
    let newRoles = Dictionary(
      uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { role in
        (role, "New \(role.displayName)")
      }
    )
    let store = RecordingGenericMailAuthorizationStore()
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "old-secret",
      definition: oldDefinition
    )
    let verifier = RecordingGenericMailEndpointVerifier()
    verifier.results = [
      GenericMailEndpointVerification(
        authenticated: true,
        discoveredRoleMappings: newRoles,
        transportVersion: .tls12OrNewer
      )
    ]
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        verifier: verifier
      )
    )
    viewModel.emailAddress = oldDefinition.emailAddress
    viewModel.loadSaved()

    viewModel.emailAddress = "new@example.com"
    viewModel.username = "new@example.com"
    viewModel.credential = "new-secret"
    await viewModel.connect()

    XCTAssertEqual(viewModel.connectedDefinition?.roleMappings, newRoles)
    XCTAssertFalse(viewModel.showsMailboxRoles)
  }

  func testAccountCleanupClearsEveryDeviceLocalGenericAuthorization() throws {
    let store = RecordingGenericMailAuthorizationStore()
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "secret",
      definition: GenericMailConnectionDefinition(
        authorizationMethod: .password,
        emailAddress: "reader@example.com",
        incomingEndpoint: manualDraft().incomingEndpoint,
        outgoingEndpoint: manualDraft().outgoingEndpoint,
        roleMappings: manualDraft().roleMappings,
        username: "reader@example.com"
      )
    )
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: RecordingGenericMailEndpointVerifier()
    )

    try service.clearLocalAuthorizations(productAccountId: ProductAccountId("product-account-001"))

    XCTAssertNil(store.authorization)
    XCTAssertEqual(
      store.clearedProductAccountId,
      ProductAccountId("product-account-001")
    )
  }

  func testSessionChangeDuringVerificationPreventsLateCredentialPersistence() async {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    var isSessionCurrent = true
    verifier.onVerify = { endpoint in
      if endpoint.mailProtocol == .smtp { isSessionCurrent = false }
    }
    let service = GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    )

    do {
      _ = try await service.authorize(
        draft: manualDraft(),
        credential: "secret",
        productAccountId: ProductAccountId("product-account-001"),
        isSessionCurrent: { isSessionCurrent }
      )
      XCTFail("Expected the stale session to cancel persistence")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertNil(store.authorization)
  }

  func testKeychainStoreRoundTripsAndClearsDeviceLocalAuthorization() throws {
    let store = KeychainGenericMailAuthorizationStore()
    let productAccountId = ProductAccountId("generic-mail-test-\(UUID().uuidString)")
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .appPassword,
      emailAddress: "reader@example.com",
      incomingEndpoint: manualDraft().incomingEndpoint,
      outgoingEndpoint: manualDraft().outgoingEndpoint,
      roleMappings: manualDraft().roleMappings,
      username: "reader@example.com"
    )
    let authorization = DeviceLocalGenericMailAuthorization(
      credential: "app-password",
      definition: definition
    )
    defer { try? store.clearAll(productAccountId: productAccountId) }

    try store.save(authorization, productAccountId: productAccountId)

    XCTAssertEqual(
      try store.load(
        productAccountId: productAccountId,
        emailAddress: definition.emailAddress
      ),
      authorization
    )
    try store.clearAll(productAccountId: productAccountId)
    XCTAssertNil(
      try store.load(
        productAccountId: productAccountId,
        emailAddress: definition.emailAddress
      )
    )
  }

  @MainActor
  func testSavedSetupCanBeLoadedForLaterRoleChanges() {
    let store = RecordingGenericMailAuthorizationStore()
    let definition = GenericMailConnectionDefinition(
      authorizationMethod: .appPassword,
      emailAddress: "reader@example.com",
      incomingEndpoint: manualDraft().incomingEndpoint,
      outgoingEndpoint: manualDraft().outgoingEndpoint,
      roleMappings: manualDraft().roleMappings,
      username: "reader@example.com"
    )
    store.authorization = DeviceLocalGenericMailAuthorization(
      credential: "secret",
      definition: definition
    )
    let viewModel = GenericMailSetupViewModel(
      productAccountId: ProductAccountId("product-account-001"),
      isSessionCurrent: { true },
      service: GenericMailSetupService(
        authorizationStore: store,
        verifier: RecordingGenericMailEndpointVerifier()
      )
    )
    viewModel.emailAddress = definition.emailAddress

    viewModel.loadSaved()
    viewModel.roleMappings[.sent] = "Changed Sent"

    XCTAssertEqual(viewModel.incomingHostname, definition.incomingEndpoint.hostname)
    XCTAssertEqual(viewModel.roleMappings[.sent], "Changed Sent")
    XCTAssertEqual(viewModel.credential, "")
  }

  func testSystemVerifierCompletesSTARTTLSBeforeSMTPAuthorization() async throws {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("220 ready\r\n"),
      .success("250-example\r\n250 STARTTLS\r\n"),
      .success("220 begin TLS\r\n250 injected before TLS\r\n"),
      .success("250 AUTH PLAIN\r\n"),
      .success("235 authenticated\r\n"),
    ])
    let factory = RecordingGenericMailStreamTaskFactory(stream: stream)
    let verifier = SystemGenericMailEndpointVerifier(streamTaskFactory: factory)

    _ = try await verifier.verify(
      endpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 587,
        security: .startTLS
      ),
      username: "reader@example.com",
      credential: "secret",
      authorizationMethod: .password
    )

    let secureIndex = try XCTUnwrap(stream.events.firstIndex(of: .startSecureConnection))
    let authorizationIndex = try XCTUnwrap(
      stream.events.firstIndex(where: { event in
        guard case .write(let value) = event else { return false }
        return value.hasPrefix("AUTH PLAIN")
      })
    )
    XCTAssertLessThan(secureIndex, authorizationIndex)
    XCTAssertEqual(factory.minimumTransportVersion, .tls12OrNewer)
  }

  func testSystemVerifierReturnsSMTPAuthenticationFailureWithoutWaitingForTimeout() async {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("220 ready\r\n"),
      .success("250 AUTH PLAIN\r\n"),
      .success("535 authentication rejected\r\n"),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    do {
      _ = try await verifier.verify(
        endpoint: GenericMailEndpoint(
          mailProtocol: .smtp,
          hostname: "smtp.example.com",
          port: 465,
          security: .implicitTLS
        ),
        username: "reader@example.com",
        credential: "secret",
        authorizationMethod: .password
      )
      XCTFail("Expected SMTP authentication to fail")
    } catch let error as GenericMailSetupError {
      XCTAssertEqual(error, .authenticationFailed(.smtp))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSystemVerifierBuffersFragmentedPOP3Responses() async throws {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("+"), .success("OK ready\r\n"),
      .success("+O"), .success("K user\r\n"),
      .success("+OK authenticated\r\n"),
      .success("+OK authenticated\r\n"),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    _ = try await verifier.verify(
      endpoint: GenericMailEndpoint(
        mailProtocol: .pop3,
        hostname: "pop.example.com",
        port: 110,
        security: .startTLS
      ),
      username: "reader@example.com",
      credential: "secret",
      authorizationMethod: .password
    )
  }

  func testSystemVerifierSurfacesCertificateFailureBeforeAuthorization() async {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .failure(URLError(.serverCertificateUntrusted))
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    do {
      _ = try await verifier.verify(
        endpoint: GenericMailEndpoint(
          mailProtocol: .imap,
          hostname: "imap.example.com",
          port: 993,
          security: .implicitTLS
        ),
        username: "reader@example.com",
        credential: "secret",
        authorizationMethod: .password
      )
      XCTFail("Expected system trust validation to fail")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .serverCertificateUntrusted)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertFalse(
      stream.events.contains(where: { event in
        guard case .write = event else { return false }
        return true
      })
    )
  }

  func testSystemVerifierReadsUnambiguousIMAPSpecialUseRoles() async throws {
    let stream = ScriptedGenericMailStreamTask(responses: [
      .success("* OK ready\r\n"),
      .success("a2 OK authenticated\r\n"),
      .success(
        "* LIST (\\Drafts) \"/\" \"Drafts\"\r\n"
          + "* LIST (\\Sent) \"/\" \"Sent Items\"\r\n"
          + "* LIST (\\Archive) \"/\" \"Archive\"\r\n"
          + "* LIST (\\Junk) \"/\" \"Junk\"\r\n"
          + "* LIST (\\Trash) \"/\" \"Deleted\"\r\n"
          + "a3 OK listed\r\n"
      ),
    ])
    let verifier = SystemGenericMailEndpointVerifier(
      streamTaskFactory: RecordingGenericMailStreamTaskFactory(stream: stream)
    )

    let verification = try await verifier.verify(
      endpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      username: "reader@example.com",
      credential: "secret",
      authorizationMethod: .password
    )

    XCTAssertEqual(verification.discoveredRoleMappings[.sent], "Sent Items")
    XCTAssertEqual(verification.discoveredRoleMappings[.trash], "Deleted")
  }

  func testSensitiveSetupDataStaysInsideDeviceLocalCollaborators() async throws {
    let store = RecordingGenericMailAuthorizationStore()
    let verifier = RecordingGenericMailEndpointVerifier()
    let definition = try await GenericMailSetupService(
      authorizationStore: store,
      verifier: verifier
    ).authorize(
      draft: manualDraft(),
      credential: "device-only-secret",
      productAccountId: ProductAccountId("product-account-001")
    )
    let encoded = try JSONEncoder().encode(definition)
    let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertEqual(verifier.usernames, ["reader@example.com", "reader@example.com"])
    XCTAssertEqual(verifier.credentials, ["device-only-secret", "device-only-secret"])
    XCTAssertEqual(
      verifier.endpoints.map(\.hostname),
      ["imap.example.com", "smtp.example.com"]
    )
    XCTAssertEqual(store.authorization?.definition.emailAddress, "reader@example.com")
    XCTAssertEqual(store.authorization?.credential, "device-only-secret")
    XCTAssertFalse(json.contains("product-account-001"))
    XCTAssertFalse(json.contains("identity-token"))
    XCTAssertFalse(json.contains("trusted-device"))
    XCTAssertFalse(json.contains("device-only-secret"))
  }

  private func manualDraft() -> GenericMailSetupDraft {
    GenericMailSetupDraft(
      authorizationMethod: .password,
      emailAddress: "reader@example.com",
      incomingEndpoint: GenericMailEndpoint(
        mailProtocol: .imap,
        hostname: "imap.example.com",
        port: 993,
        security: .implicitTLS
      ),
      outgoingEndpoint: GenericMailEndpoint(
        mailProtocol: .smtp,
        hostname: "smtp.example.com",
        port: 587,
        security: .startTLS
      ),
      roleMappings: Dictionary(
        uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { role in
          (role, "Server \(role.displayName)")
        }
      ),
      username: "reader@example.com"
    )
  }
}

private final class RecordingGenericMailEndpointVerifier: GenericMailEndpointVerifying {
  var authorizationMethods: [MailAuthorizationMethod] = []
  var credentials: [String] = []
  var endpoints: [GenericMailEndpoint] = []
  var error: Error?
  var onVerify: ((GenericMailEndpoint) -> Void)?
  var results: [GenericMailEndpointVerification] = []

  func verify(
    endpoint: GenericMailEndpoint,
    username: String,
    credential: String,
    authorizationMethod: MailAuthorizationMethod
  ) async throws -> GenericMailEndpointVerification {
    endpoints.append(endpoint)
    authorizationMethods.append(authorizationMethod)
    credentials.append(credential)
    usernames.append(username)
    onVerify?(endpoint)
    if let error { throw error }
    if !results.isEmpty { return results.removeFirst() }
    return GenericMailEndpointVerification(
      authenticated: true,
      transportVersion: .tls12OrNewer
    )
  }

  var usernames: [String] = []
}

private final class RecordingGenericMailAuthorizationStore: GenericMailAuthorizationPersisting {
  var authorization: DeviceLocalGenericMailAuthorization?
  var clearedProductAccountId: ProductAccountId?
  var productAccountId: ProductAccountId?

  func clearAll(productAccountId: ProductAccountId) throws {
    authorization = nil
    clearedProductAccountId = productAccountId
  }

  func load(
    productAccountId _: ProductAccountId,
    emailAddress _: String
  ) throws -> DeviceLocalGenericMailAuthorization? {
    authorization
  }

  func save(
    _ authorization: DeviceLocalGenericMailAuthorization,
    productAccountId: ProductAccountId
  ) throws {
    self.authorization = authorization
    self.productAccountId = productAccountId
  }
}

private enum GenericMailSetupTestError: Error {
  case invalidCertificate
}

private enum GenericMailStreamEvent: Equatable {
  case close
  case read
  case resume
  case startSecureConnection
  case write(String)
}

private final class ScriptedGenericMailStreamTask: GenericMailStreamTasking {
  var events: [GenericMailStreamEvent] = []
  private var responses: [Result<String, Error>]

  init(responses: [Result<String, Error>]) {
    self.responses = responses
  }

  func close() {
    events.append(.close)
  }

  func read() async throws -> String {
    events.append(.read)
    return try responses.removeFirst().get()
  }

  func resume() {
    events.append(.resume)
  }

  func startSecureConnection() {
    events.append(.startSecureConnection)
  }

  func write(_ value: String) async throws {
    events.append(.write(value))
  }
}

private final class RecordingGenericMailStreamTaskFactory: GenericMailStreamTaskCreating {
  var minimumTransportVersion: MailTransportVersion?
  private let stream: GenericMailStreamTasking

  init(stream: GenericMailStreamTasking) {
    self.stream = stream
  }

  func makeStreamTask(
    hostname _: String,
    port _: Int,
    minimumTransportVersion: MailTransportVersion
  ) -> GenericMailStreamTasking {
    self.minimumTransportVersion = minimumTransportVersion
    return stream
  }
}
