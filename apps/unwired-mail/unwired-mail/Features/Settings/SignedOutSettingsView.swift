import SwiftUI

/// Hosts the production-safe Settings destinations available without a Product Account.
@MainActor
struct SignedOutSettingsView: View {
  let showsDismissButton: Bool
  let attentions: [SettingsAttention]
  let usesParentCompactNavigation: Bool
  let dismissAction: (() -> Void)?

  @State private var storageViewModel: StorageDataSettingsViewModel

  init(
    showsDismissButton: Bool = true,
    attentions: [SettingsAttention] = [],
    storageViewModel: StorageDataSettingsViewModel? = nil,
    usesParentCompactNavigation: Bool = false,
    dismissAction: (() -> Void)? = nil
  ) {
    self.showsDismissButton = showsDismissButton
    self.attentions = attentions
    self.usesParentCompactNavigation = usesParentCompactNavigation
    self.dismissAction = dismissAction
    _storageViewModel = State(initialValue: storageViewModel ?? .deviceLocal())
  }

  var body: some View {
    AdaptiveSettingsScene(
      isSignedIn: false,
      showsDismissButton: showsDismissButton,
      attentions: attentions,
      usesParentCompactNavigation: usesParentCompactNavigation,
      dismissAction: dismissAction,
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
          .mailProfiles,
          .notifications, .reading, .signatures, .swipes, .templates:
          EmptyView()
        }
      }
    )
  }
}
