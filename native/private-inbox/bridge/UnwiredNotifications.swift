import Foundation
import React
import UserNotifications

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

// New Mail Notifications on this device: its permission and preview choice, posting, and the
// notifications a person opens. The application delegates install the delegate at launch, so a tap
// that launches the application is kept until JavaScript reads it.
@objc(UnwiredNotifications)
final class UnwiredNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
  static let shared = UnwiredNotifications()

  @MainActor @objc static func start() {
    UNUserNotificationCenter.current().delegate = shared
  }

  // Notifications already shown for a connection, or for every connection, leave Notification
  // Center when it is removed or this device signs out or is purged.
  static func withdraw(_ connection: String? = nil) {
    let center = UNUserNotificationCenter.current()
    guard let connection else {
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      return
    }
    center.getPendingNotificationRequests { pending in
      center.removePendingNotificationRequests(
        withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(connection + ".") })
    }
    center.getDeliveredNotifications { delivered in
      center.removeDeliveredNotifications(
        withIdentifiers: delivered.map(\.request.identifier).filter {
          $0.hasPrefix(connection + ".")
        })
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  // A tap or Reply opens the message; Archive and Mark as Read act without opening a window.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    guard let account = info["account"] as? String, !account.isEmpty,
      let epoch = info["epoch"] as? String, !epoch.isEmpty,
      let connection = info["connection"] as? String, !connection.isEmpty,
      let message = info["message"] as? String, !message.isEmpty
    else { return }
    let opened = ["account": account, "epoch": epoch, "connection": connection, "message": message]
    switch response.actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      await NotificationTaps.shared.receive(opened)
    case "reply":
      await NotificationTaps.shared.receive(opened.merging(["action": "reply"]) { $1 })
    case "archive", "read":
      await NotificationActions.shared.perform(
        opened.merging(["action": response.actionIdentifier]) { $1 })
    default:
      return
    }
  }

  // Reply, Archive and Mark as Read, in the order each platform's design lists them. Archive and
  // Mark as Read act in the background only once the device is unlocked: protected storage stays
  // closed while it is locked.
  static func newMail(_ titles: [String: String]) -> UNNotificationCategory {
    func action(_ id: String, _ symbol: String, _ options: UNNotificationActionOptions)
      -> UNNotificationAction
    {
      UNNotificationAction(
        identifier: id, title: titles[id] ?? "", options: options,
        icon: UNNotificationActionIcon(systemImageName: symbol))
    }
    let reply = action("reply", "arrowshape.turn.up.left", .foreground)
    let archive = action("archive", "archivebox", .authenticationRequired)
    let read = action("read", "envelope.open", .authenticationRequired)
    #if os(iOS)
      let actions = [reply, archive, read]
    #else
      let actions = [archive, read, reply]
    #endif
    return UNNotificationCategory(identifier: "new-mail", actions: actions, intentIdentifiers: [])
  }
}

// Archive and Mark as Read wait here for JavaScript, which acts with no window open. The system's
// handler finishes once JavaScript completes the action, or at the deadline.
@MainActor final class NotificationActions {
  static let shared = NotificationActions()
  private var queued: [[String: String]] = []
  private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
  private var reader: CheckedContinuation<[String: String]?, Never>?

  func perform(_ action: [String: String]) async {
    let id = UUID().uuidString
    let action = action.merging(["id": id]) { $1 }
    await withCheckedContinuation { continuation in
      waiting[id] = continuation
      if let reader {
        self.reader = nil
        reader.resume(returning: action)
      } else {
        queued.append(action)
      }
      // iOS allows about 30 seconds for a background action.
      Task {
        try? await Task.sleep(for: .seconds(25))
        self.complete(id)
      }
    }
  }

  // The next action for JavaScript. A reloaded JavaScript context replaces the earlier reader.
  func next() async -> [String: String]? {
    if !queued.isEmpty { return queued.removeFirst() }
    reader?.resume(returning: nil)
    return await withCheckedContinuation { reader = $0 }
  }

  func complete(_ id: String) {
    queued.removeAll { $0["id"] == id }
    waiting.removeValue(forKey: id)?.resume()
  }
}

// Opened notifications waiting for JavaScript. Each Mac window reads its own; the key window's
// reader goes first, and with no window open a new one is opened to read it.
@MainActor final class NotificationTaps {
  static let shared = NotificationTaps()
  private var queued: [[String: String]] = []
  private var readers: [String: (id: String, continuation: CheckedContinuation<[String: String]?, Never>)] = [:]

  func receive(_ tap: [String: String]) {
    #if os(macOS)
      // A closed window's reader never reads again.
      for window in readers.keys where Self.window(window) == nil {
        readers.removeValue(forKey: window)?.continuation.resume(returning: nil)
      }
      let key = NSApp.keyWindow?.identifier?.rawValue
      let window = readers.keys.first { "inbox-window-\($0)" == key } ?? readers.keys.sorted().first
      NSApp.activate()
      if let window {
        Self.window(window)?.makeKeyAndOrderFront(nil)
      } else if !NSApp.windows.contains(where: {
        $0.isVisible && $0.identifier?.rawValue.hasPrefix("inbox-window-") == true
      }) {
        // An open window that has not started reading yet reads the queued notification.
        NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
      }
    #else
      let window = readers.keys.first
    #endif
    if let window, let reader = readers.removeValue(forKey: window) {
      reader.continuation.resume(returning: tap)
    } else {
      queued.append(tap)
    }
  }

  // The next opened notification for `window`. A reloaded JavaScript context replaces the
  // window's earlier reader, which reads null.
  func next(_ window: String, reader: String) async -> [String: String]? {
    readers.removeValue(forKey: window)?.continuation.resume(returning: nil)
    if !queued.isEmpty { return queued.removeFirst() }
    return await withCheckedContinuation { readers[window] = (reader, $0) }
  }

  func stop(_ window: String, reader: String) {
    if readers[window]?.id == reader {
      readers.removeValue(forKey: window)?.continuation.resume(returning: nil)
    }
  }

  #if os(macOS)
    private static func window(_ id: String) -> NSWindow? {
      NSApp.windows.first { $0.identifier?.rawValue == "inbox-window-\(id)" && $0.isVisible }
    }
  #endif
}

extension UnwiredRegistration {
  // Sender and subject previews are a Device-Local Preference, off until chosen here.
  private static let notificationPreviewsKey = "dev.unwired.notification-previews"

  private static func notificationSettings() async -> [String: Any] {
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    let authorization =
      switch status {
      case .notDetermined: "undetermined"
      case .denied: "denied"
      default: "authorized"
      }
    return [
      "authorization": authorization,
      "previews": UserDefaults.standard.bool(forKey: notificationPreviewsKey),
    ]
  }

  @objc(notificationSettings:rejecter:)
  func notificationSettings(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { resolve(await Self.notificationSettings()) }
  }

  // The system asks once; a later request reports the person's answer.
  @objc(requestNotifications:rejecter:)
  func requestNotifications(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
      resolve(await Self.notificationSettings())
    }
  }

  @objc(setNotificationPreviews:resolver:rejecter:)
  func setNotificationPreviews(
    _ previews: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("setNotificationPreviews", resolve, reject: reject) { _ in
      UserDefaults.standard.set(previews, forKey: Self.notificationPreviewsKey)
      return await Self.notificationSettings()
    }
  }

  @objc(openNotificationSettings:rejecter:)
  func openNotificationSettings(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
          await UIApplication.shared.open(url)
        }
      #else
        let bundle = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(
          string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundle)")
        {
          NSWorkspace.shared.open(url)
        }
      #endif
      resolve([:])
    }
  }

  // Each notification replaces any shown under the same identifier. Its only routing data is the
  // opaque connection and message identifiers; its opaque Mail Profile groups it with the
  // Profile's others. `actions` titles Reply, Archive and Mark as Read in this device's language.
  // Posting runs in the registration operation gate, after a removal and its withdrawal, and
  // skips a connection this device no longer holds.
  @objc(postNotifications:actions:resolver:rejecter:)
  func postNotifications(
    _ notifications: [[String: Any]], actions: [String: String],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("postNotifications", resolve, reject: reject) { store in
      UNUserNotificationCenter.current().setNotificationCategories([
        UnwiredNotifications.newMail(actions)
      ])
      for notification in notifications {
        guard let id = notification["id"] as? String, !id.isEmpty,
          let title = notification["title"] as? String,
          let body = notification["body"] as? String,
          let profile = notification["profile"] as? String, !profile.isEmpty,
          let connection = notification["connection"] as? String,
          id.hasPrefix(connection + "."),
          let message = notification["message"] as? String,
          let previews = notification["previews"] as? Bool,
          !previews || UserDefaults.standard.bool(forKey: Self.notificationPreviewsKey),
          let account = notification["account"] as? String,
          let epoch = notification["epoch"] as? String,
          (try? store.mailboxAccount(connection).productAccountId) == account,
          let held = try? store.saved().connection(connection),
          (held.epoch ?? "legacy") == epoch
        else { continue }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "new-mail"
        content.threadIdentifier = profile
        content.userInfo = ["account": account, "epoch": epoch, "connection": connection, "message": message]
        try? await UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: id, content: content, trigger: nil))
      }
    }
  }

  @objc(nextOpenedNotification:reader:resolver:rejecter:)
  func nextOpenedNotification(
    _ window: String, reader: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in resolve(await NotificationTaps.shared.next(window, reader: reader) ?? NSNull()) }
  }

  @objc(stopOpenedNotifications:reader:resolver:rejecter:)
  func stopOpenedNotifications(
    _ window: String, reader: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      NotificationTaps.shared.stop(window, reader: reader)
      resolve(NSNull())
    }
  }

  @objc(nextNotificationAction:rejecter:)
  func nextNotificationAction(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in resolve(await NotificationActions.shared.next() ?? NSNull()) }
  }

  @objc(completeNotificationAction:)
  func completeNotificationAction(_ id: String) {
    Task { @MainActor in NotificationActions.shared.complete(id) }
  }

  @objc(restoreOpenedNotification:resolver:rejecter:)
  func restoreOpenedNotification(
    _ opened: [String: String], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      NotificationTaps.shared.receive(opened)
      resolve(NSNull())
    }
  }
}
