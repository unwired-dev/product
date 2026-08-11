import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
final class UnsubscribeSuggestionTests {
  @Test
  func testParserPrefersOneClickThenMailtoAndWebAcrossRepeatedFoldedHeaders() throws {
    let suggestion = try requireValue(
      UnsubscribeSuggestionParser.suggestion(
        headers: [
          ("List-ID", "Product News <News.Example.COM>"),
          (
            "List-Unsubscribe",
            "<mailto:leave@example.com?subject=remove&body=unsubscribe>,\r\n <https://lists.example.com/leave>"
          ),
          ("list-unsubscribe", "<https://backup.example.com/leave>"),
          ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click"),
        ]
      )
    )

    #expect(suggestion.mailingListIdentity.rawValue == "list-id:news.example.com")
    #expect(suggestion.mailingListIdentity.opaqueDismissalIdentifier.count == 64)
    #expect(
      suggestion.actions == [
        .oneClick(try requireValue(URL(string: "https://lists.example.com/leave"))),
        .mailto(
          UnsubscribeMailtoMessage(
            body: "unsubscribe",
            recipient: "leave@example.com",
            subject: "remove"
          )
        ),
        .web(try requireValue(URL(string: "https://lists.example.com/leave"))),
      ]
    )
  }

  @Test
  func testParserRejectsUnsafeTargetsAndDerivesFallbackIdentity() throws {
    #expect(
      UnsubscribeSuggestionParser.suggestion(
        headers: [
          ("List-ID", "list.example.com"),
          ("List-Unsubscribe", "<http://example.com/leave>"),
        ]
      ) == nil
    )
    #expect(
      UnsubscribeSuggestionParser.suggestion(
        headers: [
          ("List-ID", "list.example.com"),
          ("List-Unsubscribe", "<https://user:secret@example.com/leave>"),
        ]
      ) == nil
    )

    let fallback = try requireValue(
      UnsubscribeSuggestionParser.suggestion(
        headers: [
          ("List-Unsubscribe", "<mailto:leave@example.com>")
        ]
      )
    )
    #expect(fallback.mailingListIdentity.rawValue == "mailto:leave@example.com")
    #expect(
      fallback.actions == [
        .mailto(UnsubscribeMailtoMessage(body: "", recipient: "leave@example.com", subject: ""))
      ]
    )
  }

  @Test
  func testCardPriorityIsEventThenUnsubscribeThenContact() {
    #expect(
      ProactiveMessageCard.highestPriority(
        hasEvent: true,
        hasUnsubscribe: true,
        hasContact: true
      ) == .event
    )
    #expect(
      ProactiveMessageCard.highestPriority(
        hasEvent: false,
        hasUnsubscribe: true,
        hasContact: true
      ) == .unsubscribe
    )
    #expect(
      ProactiveMessageCard.highestPriority(
        hasEvent: false,
        hasUnsubscribe: false,
        hasContact: true
      ) == .contact
    )
  }

  @Test
  func testOneClickRequestPinsEveryPublicRedirectAndSendsOnlyStandardsBody() async throws {
    let address = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34")
    )
    var requests: [URLRequest] = []
    var hosts: [String] = []
    var transferCount = 0
    var times: [TimeInterval] = [100, 101, 102, 103, 104]
    let service = UnsubscribeRequestService(
      resolver: { _ in [address] },
      transfer: { request, connectedAddress, host, _ in
        #expect(connectedAddress == address)
        requests.append(request)
        hosts.append(host)
        transferCount += 1
        if transferCount == 1 {
          return RemoteMessageContentPinnedHTTPResponse(
            body: Data(),
            headerFields: ["Location": "https://redirect.example.com/confirmed"],
            statusCode: 307
          )
        }
        return RemoteMessageContentPinnedHTTPResponse(
          body: Data("ok".utf8),
          headerFields: [:],
          statusCode: 204
        )
      },
      monotonicTime: { times.removeFirst() }
    )

    try await service.sendOneClick(
      to: try requireValue(URL(string: "https://lists.example.com/leave"))
    )

    #expect(hosts == ["lists.example.com", "redirect.example.com"])
    #expect(requests.map(\.httpMethod) == ["POST", "POST"])
    #expect(
      requests.allSatisfy {
        $0.httpBody == Data("List-Unsubscribe=One-Click".utf8)
          && $0.value(forHTTPHeaderField: "Content-Type")
            == "application/x-www-form-urlencoded"
          && $0.value(forHTTPHeaderField: "Authorization") == nil
          && $0.value(forHTTPHeaderField: "Cookie") == nil
          && $0.value(forHTTPHeaderField: "Referer") == nil
      }
    )
    #expect(requests.map(\.timeoutInterval) == [29, 28])
  }

  @Test
  func testOneClickRequestBlocksMixedDNSAndReportsDispatchedFailureAsUncertain() async throws {
    let publicAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("93.184.216.34")
    )
    let privateAddress = try requireValue(
      RemoteMessageContentIPAddress.numericAddress("127.0.0.1")
    )
    let blocked = UnsubscribeRequestService(
      resolver: { _ in [publicAddress, privateAddress] },
      transfer: { _, _, _, _ in
        Issue.record("Unsafe mixed DNS answers must be rejected before dispatch")
        throw URLError(.cannotConnectToHost)
      }
    )
    await #expect(throws: UnsubscribeRequestError.blockedDestination) {
      try await blocked.sendOneClick(
        to: try requireValue(URL(string: "https://lists.example.com/leave"))
      )
    }

    let uncertain = UnsubscribeRequestService(
      resolver: { _ in [publicAddress] },
      transfer: { _, _, _, _ in throw URLError(.networkConnectionLost) }
    )
    await #expect(throws: UnsubscribeRequestError.outcomeUncertain) {
      try await uncertain.sendOneClick(
        to: try requireValue(URL(string: "https://lists.example.com/leave"))
      )
    }
  }

  @Test
  func testPinnedSerializerPreservesPostBodyWithoutPrivateHeaders() throws {
    var request = URLRequest(
      url: try requireValue(URL(string: "https://lists.example.com/leave"))
    )
    request.httpMethod = "POST"
    request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
    request.setValue("private", forHTTPHeaderField: "Cookie")
    request.setValue("Bearer private", forHTTPHeaderField: "Authorization")
    let data = try RemoteMessageContentPinnedHTTPSClient.serializedRequest(
      request,
      tlsServerName: "lists.example.com"
    )
    let text = try requireValue(String(data: data, encoding: .utf8))

    #expect(text.hasPrefix("POST /leave HTTP/1.1\r\n"))
    #expect(text.contains("\r\nContent-Length: 26\r\n"))
    #expect(text.hasSuffix("\r\n\r\nList-Unsubscribe=One-Click"))
    #expect(!text.localizedCaseInsensitiveContains("cookie"))
    #expect(!text.localizedCaseInsensitiveContains("authorization"))
  }

  @MainActor
  @Test
  func testPreferenceStoreSuppressesForFourteenDaysAndPersistsOfflineChanges() throws {
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "identity-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let stateStore = InMemoryFeatureSuggestionStateStore()
    let sync = RecordingFeatureSuggestionPreferenceSync()
    let store = FeatureSuggestionPreferenceStore(
      session: session,
      syncService: sync,
      localStateStore: stateStore,
      automaticallySynchronizes: false
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let identifier = "opaque-list-001"

    store.dismiss(identifier, feature: .unsubscribe, now: now)
    #expect(!store.isVisible(.unsubscribe, dismissalIdentifier: identifier, now: now))
    #expect(
      !store.isVisible(
        .unsubscribe,
        dismissalIdentifier: identifier,
        now: now.addingTimeInterval(14 * 24 * 60 * 60 - 1)
      )
    )
    #expect(
      store.isVisible(
        .unsubscribe,
        dismissalIdentifier: identifier,
        now: now.addingTimeInterval(14 * 24 * 60 * 60)
      )
    )
    store.setEnabled(false, feature: .unsubscribe)
    #expect(!store.preferences.isEnabled(.unsubscribe))
    #expect(store.hasPendingChanges)

    let restored = FeatureSuggestionPreferenceStore(
      session: session,
      syncService: sync,
      localStateStore: stateStore,
      automaticallySynchronizes: false
    )
    #expect(!restored.preferences.isEnabled(.unsubscribe))
    #expect(restored.hasPendingChanges)
  }
}

extension UnsubscribeSuggestionTests {
  @MainActor
  @Test
  func testPreferenceStoreMergesPendingDismissalThroughEncryptedSyncBoundary() async {
    let session = ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-001",
      identityToken: "identity-token",
      productAccountId: "product-account-001",
      trustedDeviceId: "trusted-device-001"
    )
    let sync = RecordingFeatureSuggestionPreferenceSync()
    let store = FeatureSuggestionPreferenceStore(
      session: session,
      syncService: sync,
      localStateStore: InMemoryFeatureSuggestionStateStore(),
      automaticallySynchronizes: false
    )
    store.dismiss(
      "opaque-list-001",
      feature: .unsubscribe,
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    await store.synchronize()

    #expect(!store.hasPendingChanges)
    #expect(store.errorMessage == nil)
    #expect(await sync.appliedMutationCount() == 1)
  }
}

private final class InMemoryFeatureSuggestionStateStore: FeatureSuggestionLocalStatePersisting {
  private var states: [String: FeatureSuggestionPreferenceLocalState] = [:]

  func clear(productAccountId: String) throws {
    states[productAccountId] = nil
  }

  func load(productAccountId: String) throws -> FeatureSuggestionPreferenceLocalState? {
    states[productAccountId]
  }

  func save(
    _ state: FeatureSuggestionPreferenceLocalState,
    productAccountId: String
  ) throws {
    states[productAccountId] = state
  }
}

private actor RecordingFeatureSuggestionPreferenceSync: FeatureSuggestionPreferenceSyncing {
  private var applied: [FeatureSuggestionPreferenceMutation] = []
  private var preferences = FeatureSuggestionPreferences.defaults

  func apply(
    _ mutations: [FeatureSuggestionPreferenceMutation],
    session _: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences {
    applied.append(contentsOf: mutations)
    preferences = preferences.applying(mutations)
    return preferences
  }

  func loadPreferences(
    session _: ProductAccountSessionSnapshot
  ) async throws -> FeatureSuggestionPreferences? {
    preferences
  }

  func appliedMutationCount() -> Int {
    applied.count
  }
}
