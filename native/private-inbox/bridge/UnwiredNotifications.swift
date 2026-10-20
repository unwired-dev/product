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
    guard let connection else { return center.removeAllDeliveredNotifications() }
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

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let connection = info["connection"] as? String, !connection.isEmpty,
      let message = info["message"] as? String, !message.isEmpty
    else { return }
    await NotificationTaps.shared.receive(["connection": connection, "message": message])
  }
}

// Opened notifications waiting for JavaScript. Each Mac window reads its own; the key window's
// reader goes first, and with no window open a new one is opened to read it.
@MainActor final class NotificationTaps {
  static let shared = NotificationTaps()
  private var queued: [[String: String]] = []
  private var readers: [String: CheckedContinuation<[String: String]?, Never>] = [:]

  func receive(_ tap: [String: String]) {
    #if os(macOS)
      // A closed window's reader never reads again.
      for window in readers.keys where Self.window(window) == nil {
        readers.removeValue(forKey: window)?.resume(returning: nil)
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
      reader.resume(returning: tap)
    } else {
      queued.append(tap)
    }
  }

  // The next opened notification for `window`. A reloaded JavaScript context replaces the
  // window's earlier reader, which reads null.
  func next(_ window: String) async -> [String: String]? {
    if !queued.isEmpty { return queued.removeFirst() }
    readers.removeValue(forKey: window)?.resume(returning: nil)
    return await withCheckedContinuation { readers[window] = $0 }
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
    UserDefaults.standard.set(previews, forKey: Self.notificationPreviewsKey)
    Task { resolve(await Self.notificationSettings()) }
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
  // opaque connection and message identifiers.
  @objc(postNotifications:resolver:rejecter:)
  func postNotifications(
    _ notifications: [[String: Any]], resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Task {
      for notification in notifications {
        guard let id = notification["id"] as? String, !id.isEmpty,
          let title = notification["title"] as? String,
          let body = notification["body"] as? String,
          let connection = notification["connection"] as? String,
          id.hasPrefix(connection + "."),
          let message = notification["message"] as? String
        else { continue }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["connection": connection, "message": message]
        try? await UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: id, content: content, trigger: nil))
      }
      resolve([:])
    }
  }

  @objc(nextOpenedNotification:resolver:rejecter:)
  func nextOpenedNotification(
    _ window: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in resolve(await NotificationTaps.shared.next(window) ?? NSNull()) }
  }
}
