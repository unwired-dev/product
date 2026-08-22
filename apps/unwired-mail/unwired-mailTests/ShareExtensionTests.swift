import CryptoKit
import Foundation
import Testing

@testable import unwired_mail

@MainActor
@Suite(.serialized)
struct ShareExtensionTests {
  @Test(.bug(id: 406))
  func encryptedStoreRoundTripsWithoutExposingProfileOrSharedContent() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ShareExtensionStore(
      keyProvider: TestShareExtensionKeyProvider(),
      rootDirectory: root
    )
    let catalog = catalog(isLocked: false)
    let payload = try ShareExtensionDraftBuilder().makeDraft(
      id: UUID(),
      inputs: [.text("Private shared text")],
      catalog: catalog,
      profile: try #require(catalog.startupProfile),
      identity: try #require(catalog.startupProfile?.defaultSendingIdentity)
    )

    try await store.saveCatalog(catalog)
    try await store.savePendingDraft(payload)

    #expect(try await store.loadCatalog() == catalog)
    #expect(try await store.loadPendingDrafts() == [payload])
    let storedData =
      try FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
      )?.allObjects.compactMap { $0 as? URL }
      .filter { !$0.hasDirectoryPath }
      .reduce(into: Data()) { result, file in
        result.append(try Data(contentsOf: file))
      } ?? Data()
    #expect(storedData.range(of: Data("Private shared text".utf8)) == nil)
    #expect(storedData.range(of: Data("Private Profile".utf8)) == nil)
    #expect(storedData.range(of: Data("sender@example.com".utf8)) == nil)
  }

  @Test(.bug(id: 406))
  func builderPreservesInputOrderAndSemanticAssetDisposition() throws {
    let catalog = catalog(isLocked: false)
    let payload = try ShareExtensionDraftBuilder().makeDraft(
      id: UUID(),
      inputs: [
        .text("First\nSecond"),
        .link(try #require(URL(string: "https://example.com/shared"))),
        .image(data: Data("image".utf8), filename: "image.png", mediaType: "image/png"),
        .file(data: Data("file".utf8), filename: "notes.txt", mediaType: "text/plain"),
      ],
      catalog: catalog,
      profile: try #require(catalog.startupProfile),
      identity: try #require(catalog.startupProfile?.defaultSendingIdentity),
      now: Date(timeIntervalSince1970: 123)
    )

    #expect(payload.blocks[0].runs[0].text == "First")
    #expect(payload.blocks[1].runs[0].text == "Second")
    #expect(payload.blocks[2].runs[0].link == "https://example.com/shared")
    #expect(payload.blocks[3].runs[0].inlineAssetId == payload.assets[0].id)
    #expect(payload.assets.map(\.disposition) == [.inline, .attachment])
    #expect(payload.profileId == "profile")
    #expect(payload.sendingIdentityId == "identity")
  }

  @Test(.bug(id: 406))
  func lockedStartupProfileRequiresAuthenticationBeforeIdentityIsRevealed() async throws {
    let store = TestShareExtensionStore(catalog: catalog(isLocked: true))
    let viewModel = ShareExtensionViewModel(
      inputLoader: TestShareExtensionInputLoader(inputs: [.text("Shared")]),
      makeStore: { store },
      authenticator: TestShareExtensionAuthenticator(allowsAccess: true),
      draftId: UUID()
    )

    await viewModel.load()

    #expect(viewModel.loadState == .ready)
    #expect(viewModel.selectedIdentity == nil)
    #expect(!viewModel.canSave)
    await viewModel.unlockSelectedProfile()
    #expect(viewModel.selectedIdentity?.id == "identity")
    #expect(viewModel.canSave)
  }

  @Test(.bug(id: 406))
  func savingCreatesPendingDraftAndExplicitProfileHandoff() async throws {
    let store = TestShareExtensionStore(catalog: catalog(isLocked: false))
    let draftId = UUID()
    let viewModel = ShareExtensionViewModel(
      inputLoader: TestShareExtensionInputLoader(inputs: [.text("Shared")]),
      makeStore: { store },
      authenticator: TestShareExtensionAuthenticator(allowsAccess: true),
      draftId: draftId
    )
    await viewModel.load()

    let url = try #require(await viewModel.save())

    #expect(await store.savedDrafts().map(\.id) == [draftId])
    #expect(
      MailProfileDeepLink(url: url)
        == MailProfileDeepLink(
          profileId: MailProfileId(rawValue: "profile"),
          draftId: draftId
        ))
  }

  @Test(.bug(id: 406))
  func ordinaryDraftSerializationPreservesSelectedSendingIdentity() throws {
    let draft = MailShellCompositionDraft(
      body: "Shared",
      connectionId: MailboxConnectionId(
        providerMailboxIdentity: StableProviderMailboxIdentity(
          providerId: .gmail,
          value: "sender@example.com"
        )
      ),
      recipient: "",
      replyToMessage: nil,
      sourceMessage: nil,
      subject: "",
      sendingIdentityId: SendingIdentityId(rawValue: "identity")
    )

    let decoded = try JSONDecoder().decode(
      MailShellCompositionDraft.self,
      from: JSONEncoder().encode(draft)
    )

    #expect(decoded.sendingIdentityId == SendingIdentityId(rawValue: "identity"))
  }

  @Test(.bug(id: 406))
  func importerMovesPendingPayloadIntoOrdinaryProfileDraftStorage() async throws {
    let catalog = catalog(isLocked: false)
    let payload = try ShareExtensionDraftBuilder().makeDraft(
      id: UUID(),
      inputs: [.text("Shared")],
      catalog: catalog,
      profile: try #require(catalog.startupProfile),
      identity: try #require(catalog.startupProfile?.defaultSendingIdentity)
    )
    let store = TestShareExtensionStore(catalog: catalog, drafts: [payload])
    let repository = TestShareExtensionDraftRepository()
    let importer = ShareExtensionDraftImporter(store: store, repository: repository)
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user",
      identityToken: "token",
      productAccountId: "account",
      trustedDeviceId: "device"
    )

    let imported = try await importer.importPendingDrafts(session: session)

    #expect(
      imported == [
        ShareExtensionImportedDraft(
          draftId: payload.id,
          profileId: MailProfileId(rawValue: "profile")
        )
      ])
    #expect(await store.savedDrafts().isEmpty)
    let savedDraft = try #require(await repository.savedDraft)
    #expect(savedDraft.id == payload.id)
    #expect(savedDraft.connectionId?.rawValue == "gmail:sender@example.com")
    #expect(savedDraft.sendingIdentityId?.rawValue == "identity")
    #expect(savedDraft.body == "Shared")
  }

  private func catalog(isLocked: Bool) -> ShareExtensionCatalog {
    ShareExtensionCatalog(
      productAccountId: "account",
      profiles: [
        ShareExtensionProfile(
          colorName: "blue",
          defaultSendingIdentityId: "identity",
          id: "profile",
          isLocked: isLocked,
          name: "Private Profile",
          sendingIdentities: [
            ShareExtensionSendingIdentity(
              address: "sender@example.com",
              connectionId: "gmail:sender@example.com",
              displayName: "Sender",
              id: "identity"
            )
          ],
          symbolName: "briefcase"
        )
      ],
      startupProfileId: "profile",
      updatedAtMilliseconds: 1
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "ShareExtensionTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }
}

private struct TestShareExtensionKeyProvider: ShareExtensionEncryptionKeyProviding {
  func loadOrCreateKey() throws -> SymmetricKey {
    SymmetricKey(data: Data(repeating: 0xA5, count: 32))
  }
}

@MainActor
private struct TestShareExtensionInputLoader: ShareExtensionInputLoading {
  let inputs: [ShareExtensionInput]

  func loadInputs() async throws -> [ShareExtensionInput] { inputs }
}

@MainActor
private struct TestShareExtensionAuthenticator: ShareExtensionProfileAuthenticating {
  let allowsAccess: Bool

  func authenticate(profileName: String) async throws -> Bool { allowsAccess }
}

private actor TestShareExtensionStore: ShareExtensionStoring {
  private let catalog: ShareExtensionCatalog?
  private var drafts: [ShareExtensionDraftPayload]

  init(
    catalog: ShareExtensionCatalog?,
    drafts: [ShareExtensionDraftPayload] = []
  ) {
    self.catalog = catalog
    self.drafts = drafts
  }

  func loadCatalog() async throws -> ShareExtensionCatalog? { catalog }
  func loadPendingDrafts() async throws -> [ShareExtensionDraftPayload] { drafts }

  func removePendingDraft(_ draftId: UUID) async throws {
    drafts.removeAll { $0.id == draftId }
  }

  func saveCatalog(_ catalog: ShareExtensionCatalog) async throws {}

  func savePendingDraft(_ draft: ShareExtensionDraftPayload) async throws {
    drafts.append(draft)
  }

  func savedDrafts() -> [ShareExtensionDraftPayload] { drafts }
}

private actor TestShareExtensionDraftRepository: ShareExtensionDraftRepository {
  private(set) var savedDraft: MailShellCompositionDraft?

  func save(
    _ draft: MailShellCompositionDraft,
    productAccountId: String,
    profileId: MailProfileId,
    session: ProductAccountSessionSnapshot?
  ) async throws {
    savedDraft = draft
  }
}
