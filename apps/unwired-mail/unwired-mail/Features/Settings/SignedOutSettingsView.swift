import SwiftUI

/// Hosts the production-safe Settings destinations available without a Product Account.
@MainActor
struct SignedOutSettingsView: View {
  let showsDismissButton: Bool
  let attentions: [SettingsAttention]

  @State private var storageViewModel: StorageDataSettingsViewModel

  init(
    showsDismissButton: Bool = true,
    attentions: [SettingsAttention] = [],
    storageViewModel: StorageDataSettingsViewModel? = nil
  ) {
    self.showsDismissButton = showsDismissButton
    self.attentions = attentions
    _storageViewModel = State(initialValue: storageViewModel ?? .deviceLocal())
  }

  var body: some View {
    AdaptiveSettingsScene(
      isSignedIn: false,
      showsDismissButton: showsDismissButton,
      attentions: attentions,
      destinationContent: { destination, request in
        switch destination {
        case .about:
          AboutSettingsView()
        case .advanced:
          AdvancedSettingsView(
            connections: [],
            productSyncHealth: .signedOut,
            status: { _ in .idle }
          )
        case .appearance:
          AppearanceSettingsView(navigationRequest: request)
        case .privacyAndData:
          if request?.route?.context == .storage {
            StorageDataSettingsView(
              session: nil,
              viewModel: storageViewModel
            )
          } else {
            PrivacyDataSettingsView(
              connections: [],
              storageViewModel: storageViewModel
            )
          }
        case .accountAndDevices, .categories, .compose, .emailAccounts, .inbox,
          .notifications, .reading, .signatures, .swipes, .templates:
          EmptyView()
        }
      }
    )
  }
}
