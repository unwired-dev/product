import Foundation

#if canImport(UIKit)
  import UIKit
#endif

enum SwipeGesturePlatform: CaseIterable, Sendable {
  case iPadTouch
  case iPhoneTouch
  case macOSTrackpad

  static var current: Self {
    #if targetEnvironment(macCatalyst) || os(macOS)
      return .macOSTrackpad
    #elseif canImport(UIKit)
      return UIDevice.current.userInterfaceIdiom == .pad ? .iPadTouch : .iPhoneTouch
    #else
      return .macOSTrackpad
    #endif
  }
}

enum SwipeActionExecution: Equatable, Sendable {
  case pin
  case provider(ProviderMailAction)
}

struct ResolvedSwipeAction: Equatable, Identifiable, Sendable {
  let configuredAction: SwipeAction
  let execution: SwipeActionExecution
  let systemImage: String
  let title: String

  var id: SwipeAction { configuredAction }
}

struct SwipeActionContext: Sendable {
  let messages: [MailboxMessageMetadata]
  let pinTargetMessageId: StableProviderMessageIdentity
  let pinnedMessageIds: Set<StableProviderMessageIdentity>
  let providerActions: Set<ProviderMailAction>
}

enum SwipeActionResolver {
  static func resolve(
    configuredActions: [SwipeAction],
    context: SwipeActionContext,
    platform: SwipeGesturePlatform
  ) -> [ResolvedSwipeAction] {
    guard !context.messages.isEmpty else { return [] }
    switch platform {
    case .iPadTouch, .iPhoneTouch, .macOSTrackpad:
      return configuredActions.compactMap {
        resolve($0, context: context)
      }
    }
  }

  static func allowsFullSwipe(
    preferences: SwipePreferences,
    edge: SwipeEdge,
    resolvedActions: [ResolvedSwipeAction]
  ) -> Bool {
    guard preferences.allowsFullSwipe,
      let configuredOutermost = preferences.actions(for: edge).first,
      let resolvedOutermost = resolvedActions.first
    else { return false }
    return configuredOutermost == resolvedOutermost.configuredAction
  }

  // swiftlint:disable:next function_body_length
  private static func resolve(
    _ action: SwipeAction,
    context: SwipeActionContext
  ) -> ResolvedSwipeAction? {
    switch action {
    case .archive:
      return resolvedProviderAction(
        configuredAction: action,
        providerAction: .archive,
        title: "Archive",
        systemImage: "archivebox",
        availableActions: context.providerActions
      )
    case .move:
      return resolvedProviderAction(
        configuredAction: action,
        providerAction: .move,
        title: "Move",
        systemImage: "folder",
        availableActions: context.providerActions
      )
    case .pinUnpin:
      let shouldUnpin = context.pinnedMessageIds.contains(context.pinTargetMessageId)
      return ResolvedSwipeAction(
        configuredAction: action,
        execution: .pin,
        systemImage: shouldUnpin ? "pin.slash" : "pin",
        title: shouldUnpin ? "Unpin" : "Pin"
      )
    case .readUnread:
      let providerAction: ProviderMailAction =
        context.messages.contains {
          $0.providerStateIds?.contains("UNREAD") == true
        } ? .markRead : .markUnread
      return resolvedProviderAction(
        configuredAction: action,
        providerAction: providerAction,
        title: providerAction == .markRead ? "Read" : "Unread",
        systemImage: providerAction == .markRead ? "envelope.open" : "envelope.badge",
        availableActions: context.providerActions
      )
    case .spamNotSpam:
      let providerAction: ProviderMailAction =
        context.messages.allSatisfy { $0.belongs(to: .spam) }
        ? .notSpam : .spam
      return resolvedProviderAction(
        configuredAction: action,
        providerAction: providerAction,
        title: providerAction == .notSpam ? "Not Spam" : "Spam",
        systemImage: providerAction == .notSpam ? "checkmark.shield" : "exclamationmark.shield",
        availableActions: context.providerActions
      )
    case .trash:
      return resolvedProviderAction(
        configuredAction: action,
        providerAction: .delete,
        title: "Trash",
        systemImage: "trash",
        availableActions: context.providerActions
      )
    }
  }

  private static func resolvedProviderAction(
    configuredAction: SwipeAction,
    providerAction: ProviderMailAction,
    title: String,
    systemImage: String,
    availableActions: Set<ProviderMailAction>
  ) -> ResolvedSwipeAction? {
    guard availableActions.contains(providerAction) else { return nil }
    return ResolvedSwipeAction(
      configuredAction: configuredAction,
      execution: .provider(providerAction),
      systemImage: systemImage,
      title: title
    )
  }
}
