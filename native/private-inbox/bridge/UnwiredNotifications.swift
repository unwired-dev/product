import Foundation
import React
import UserNotifications
import os

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
  // Why a New Mail Notification was or was not shown, never its content or identifiers.
  static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.unwired.mail", category: "notifications")

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
    Self.logger.info("New mail notification presented while the application is in use")
    return [.banner, .list, .sound]
  }

  // A tap opens the message; Archive, Mark as Read, a typed reply, and Undo and Open Draft on that
  // reply's notification act through JavaScript, with no window opened.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    // A Send Reminder's tap opens its Draft through JavaScript. On the Mac it also brings an Inbox
    // window forward, or opens one after a launch that started without a window.
    if response.notification.request.identifier.hasPrefix("send-reminder.") {
      guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
      #if os(macOS)
        await NotificationTaps.shared.show()
      #endif
      guard let account = info["account"] as? String, !account.isEmpty,
        let draft = info["draft"] as? String, !draft.isEmpty
      else { return }
      await NotificationActions.shared.perform(
        ["action": "open-reminder", "account": account, "draft": draft])
      return
    }
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
      if let typed = response as? UNTextInputNotificationResponse {
        await NotificationActions.shared.perform(
          opened.merging(["action": "reply", "text": typed.userText]) { $1 })
      } else {
        await NotificationTaps.shared.receive(opened.merging(["action": "reply"]) { $1 })
      }
    case "archive", "read":
      await NotificationActions.shared.perform(
        opened.merging(["action": response.actionIdentifier]) { $1 })
    case "undo", "open-draft":
      guard let draft = info["draft"] as? String, !draft.isEmpty else { return }
      await NotificationActions.shared.perform(
        opened.merging(["action": response.actionIdentifier, "draft": draft]) { $1 })
    default:
      return
    }
  }

  static func action(
    _ id: String, _ title: String?, _ symbol: String, _ options: UNNotificationActionOptions
  ) -> UNNotificationAction {
    UNNotificationAction(
      identifier: id, title: title ?? "", options: options,
      icon: UNNotificationActionIcon(systemImageName: symbol))
  }

  // Reply, Archive and Mark as Read, in the order each platform's design lists them. Archive and
  // Mark as Read act in the background only once the device is unlocked: protected storage stays
  // closed while it is locked. Reply is a field whose placeholder names the connection's receiving
  // address, so each connection has its own category.
  static func newMail(_ titles: [String: String], connection: String, placeholder: String)
    -> UNNotificationCategory
  {
    let archive = action("archive", titles["archive"], "archivebox", .authenticationRequired)
    let read = action("read", titles["read"], "envelope.open", .authenticationRequired)
    let reply = UNTextInputNotificationAction(
      identifier: "reply", title: titles["reply"] ?? "", options: .authenticationRequired,
      icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
      textInputButtonTitle: titles["send"] ?? "", textInputPlaceholder: placeholder)
    #if os(iOS)
      let actions = [reply, archive, read]
    #else
      let actions = [archive, read, reply]
    #endif
    return UNNotificationCategory(
      identifier: "new-mail.\(connection)", actions: actions, intentIdentifiers: [])
  }

  // A typed reply's notification: Undo while it waits to send, or Open Draft once it was kept in
  // Drafts.
  static func reply(_ titles: [String: String]) -> [UNNotificationCategory] {
    [
      UNNotificationCategory(
        identifier: "reply-sending",
        actions: [action("undo", titles["undo"], "arrow.uturn.backward", .authenticationRequired)],
        intentIdentifiers: []),
      UNNotificationCategory(
        identifier: "reply-saved",
        actions: [action("open-draft", titles["openDraft"], "doc.text", .foreground)],
        intentIdentifiers: []),
    ]
  }

  // Registers `categories`, keeping those registered earlier under other identifiers: notifications
  // already shown keep their actions.
  static func register(_ categories: [UNNotificationCategory]) async {
    let center = UNUserNotificationCenter.current()
    let replaced = Set(categories.map(\.identifier))
    let kept = await center.notificationCategories().filter { !replaced.contains($0.identifier) }
    center.setNotificationCategories(kept.union(categories))
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

  #if os(macOS)
    // Brings the key window's reader, or another one, forward, or opens an Inbox window when none is
    // open; resolves the reading window.
    @discardableResult func show() -> String? {
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
      return window
    }
  #endif

  func receive(_ tap: [String: String]) {
    #if os(macOS)
      let window = show()
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
  // Sender and subject previews, the App Icon Badge, the New Mail Sound and each Mail Profile's
  // Badge and sound switch are Device-Local Preferences; previews and the badge are off, the sound
  // is the system's and every Profile's switch is on until chosen here.
  private static let notificationPreviewsKey = "dev.unwired.notification-previews"
  private static let notificationBadgeKey = "dev.unwired.notification-badge"
  private static let notificationSoundKey = "dev.unwired.notification-sound"
  private static var newMailSound: String {
    sound(UserDefaults.standard.string(forKey: notificationSoundKey))
  }
  // "none", one of the Mac's alert sounds by name, or otherwise "default".
  private static func sound(_ name: String?) -> String {
    #if os(macOS)
      if let name, !name.contains("/"), FileManager.default.fileExists(atPath: alertSound(name).path)
      {
        return name
      }
    #endif
    return name == "none" ? "none" : "default"
  }
  private static func alertSound(_ name: String) -> URL {
    URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
  }
  // A notification finds a named sound only in the app's own Library/Sounds, so the chosen Mac
  // alert sound is copied there first.
  private static func alertSound(named name: String) -> UNNotificationSound {
    #if os(macOS)
      let file = "\(name).aiff"
      if let sounds = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Sounds", isDirectory: true),
        !FileManager.default.fileExists(atPath: sounds.appendingPathComponent(file).path)
      {
        try? FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(
          at: alertSound(name), to: sounds.appendingPathComponent(file))
      }
      return UNNotificationSound(named: UNNotificationSoundName(file))
    #else
      return .default
    #endif
  }
  // The Profiles whose Badge and sound switch is off.
  private static var badgeSoundOff: [String] {
    UserDefaults.standard.stringArray(forKey: RegistrationStore.notificationProfilesOffKey) ?? []
  }

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
      "badge": UserDefaults.standard.string(forKey: notificationBadgeKey) == "inbox"
        ? "inbox" : "off",
      "sound": newMailSound,
      "badgeSoundOff": badgeSoundOff,
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
        .alert, .sound, .badge,
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
      // A Send Reminder that shows its Draft leaves, pending or delivered; JavaScript schedules
      // the generic one again.
      if !previews {
        let center = UNUserNotificationCenter.current()
        let shown = { (id: String) in id.hasPrefix("send-reminder.preview.") }
        center.removePendingNotificationRequests(
          withIdentifiers: await center.pendingNotificationRequests().map(\.identifier).filter(shown))
        center.removeDeliveredNotifications(
          withIdentifiers: await center.deliveredNotifications().map(\.request.identifier).filter(
            shown))
      }
      return await Self.notificationSettings()
    }
  }

  // What the App Icon Badge counts: "inbox" or "off".
  @objc(setNotificationBadge:resolver:rejecter:)
  func setNotificationBadge(
    _ badge: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("setNotificationBadge", resolve, reject: reject) { _ in
      UserDefaults.standard.set(
        badge == "inbox" ? "inbox" : "off", forKey: Self.notificationBadgeKey)
      return await Self.notificationSettings()
    }
  }

  // The sound a shown New Mail Notification plays: "default" (the system's), "none", or on the
  // Mac one of its alert sounds by name.
  @objc(setNotificationSound:resolver:rejecter:)
  func setNotificationSound(
    _ sound: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("setNotificationSound", resolve, reject: reject) { _ in
      UserDefaults.standard.set(Self.sound(sound), forKey: Self.notificationSoundKey)
      return await Self.notificationSettings()
    }
  }

  // Turns one of the Product Account `owner`'s Mail Profiles' Badge and sound switch on or off.
  // Runs in the registration operation gate: a choice that waited behind a purge, or behind one
  // that stopped partway, changes nothing, since another Product Account reuses the Profile ids.
  @objc(setNotificationProfile:profile:on:resolver:rejecter:)
  func setNotificationProfile(
    _ owner: String, profile: String, on: Bool, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    perform("setNotificationProfile", resolve, reject: reject) { store in
      guard let saved = try store.load(), saved.accountRemoval == nil,
        saved.product?.productAccountId == owner
      else {
        return await Self.notificationSettings()
      }
      let others = Self.badgeSoundOff.filter { $0 != profile }
      UserDefaults.standard.set(
        on || profile.isEmpty ? others : others + [profile],
        forKey: RegistrationStore.notificationProfilesOffKey)
      return await Self.notificationSettings()
    }
  }

  // Shows `count` on the application's icon; 0 removes the badge.
  @objc(setBadgeCount:resolver:rejecter:)
  func setBadgeCount(
    _ count: Double, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    Task {
      do {
        try await UNUserNotificationCenter.current().setBadgeCount(max(0, Int(count)))
        resolve(NSNull())
      } catch {
        reject("badge-unavailable", nil, nil)
      }
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
      var categories: [String: UNNotificationCategory] = [:]
      for notification in notifications {
        if let connection = notification["connection"] as? String,
          let placeholder = notification["reply"] as? String
        {
          let category = UnwiredNotifications.newMail(
            actions, connection: connection, placeholder: placeholder)
          categories[category.identifier] = category
        }
      }
      await UnwiredNotifications.register(Array(categories.values))
      let sound: UNNotificationSound? =
        switch Self.newMailSound {
        case "none": nil
        case "default": .default
        case let name: Self.alertSound(named: name)
        }
      let silent = Self.badgeSoundOff
      var skipped: [String: Int] = [:]
      var added = 0
      for notification in notifications {
        guard let id = notification["id"] as? String, !id.isEmpty,
          let title = notification["title"] as? String,
          let body = notification["body"] as? String,
          let profile = notification["profile"] as? String, !profile.isEmpty,
          let connection = notification["connection"] as? String,
          id.hasPrefix(connection + "."),
          let message = notification["message"] as? String,
          let previews = notification["previews"] as? Bool,
          let account = notification["account"] as? String,
          let epoch = notification["epoch"] as? String
        else {
          skipped["malformed", default: 0] += 1
          continue
        }
        guard !previews || UserDefaults.standard.bool(forKey: Self.notificationPreviewsKey) else {
          skipped["previews turned off", default: 0] += 1
          continue
        }
        guard Self.holds(store, account: account, connection: connection, epoch: epoch) else {
          skipped["connection no longer held", default: 0] += 1
          continue
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent.contains(profile) ? nil : sound
        content.categoryIdentifier = "new-mail.\(connection)"
        content.threadIdentifier = profile
        content.userInfo = ["account": account, "epoch": epoch, "connection": connection, "message": message]
        do {
          try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
          added += 1
        } catch {
          let error = error as NSError
          UnwiredNotifications.logger.error(
            "New mail notification not added: \(error.domain, privacy: .public) \(error.code, privacy: .public)"
          )
        }
      }
      // What the system will do with them: an alert style or Lock Screen choice can hide one.
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      UnwiredNotifications.logger.info(
        "New mail notifications added: \(added, privacy: .public), skipped: \(skipped.description, privacy: .public); authorization \(settings.authorizationStatus.rawValue, privacy: .public), alerts \(settings.alertSetting.rawValue, privacy: .public), Notification Center \(settings.notificationCenterSetting.rawValue, privacy: .public), Lock Screen \(settings.lockScreenSetting.rawValue, privacy: .public)"
      )
    }
  }

  @MainActor private static func holds(
    _ store: RegistrationStore, account: String, connection: String, epoch: String
  ) -> Bool {
    guard (try? store.mailboxAccount(connection).productAccountId) == account,
      let held = try? store.saved().connection(connection)
    else { return false }
    return (held.epoch ?? "legacy") == epoch
  }

  // A typed reply's notification, under its own identifier: `sending` offers Undo and `saved`
  // Open Draft, titled by `actions`; `failed` has no Draft and no action. Its routing data adds
  // the reply's opaque Draft identifier. Like a New Mail Notification, it skips a connection this
  // device no longer holds.
  @objc(postReplyNotification:actions:resolver:rejecter:)
  func postReplyNotification(
    _ notification: [String: Any], actions: [String: String],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("postReplyNotification", resolve, reject: reject) { store in
      guard let id = notification["id"] as? String,
        let kind = notification["kind"] as? String, ["sending", "saved", "failed"].contains(kind),
        let title = notification["title"] as? String,
        let body = notification["body"] as? String,
        let profile = notification["profile"] as? String, !profile.isEmpty,
        let connection = notification["connection"] as? String,
        id.hasPrefix(connection + "."),
        let message = notification["message"] as? String,
        let draft = notification["draft"] as? String, kind == "failed" || !draft.isEmpty,
        let previews = notification["previews"] as? Bool,
        let account = notification["account"] as? String,
        let epoch = notification["epoch"] as? String,
        !previews || UserDefaults.standard.bool(forKey: Self.notificationPreviewsKey),
        Self.holds(store, account: account, connection: connection, epoch: epoch)
      else {
        UnwiredNotifications.logger.info("Reply notification skipped")
        return
      }
      await UnwiredNotifications.register(UnwiredNotifications.reply(actions))
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.categoryIdentifier = "reply-\(kind)"
      content.threadIdentifier = profile
      content.userInfo = [
        "account": account, "epoch": epoch, "connection": connection, "message": message,
        "draft": draft,
      ]
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
  }

  @objc(withdrawNotification:resolver:rejecter:)
  func withdrawNotification(
    _ id: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    resolve(NSNull())
  }

  // Every typed reply's sending notification, which a replaced JavaScript context no longer
  // counts down or withdraws.
  @objc(withdrawSendingReplies:rejecter:)
  func withdrawSendingReplies(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    // Settles once removed, so a reply this context posts afterwards is never swept.
    performStep("withdrawSendingReplies", resolve, reject: reject) { _ in
      let center = UNUserNotificationCenter.current()
      center.removeDeliveredNotifications(
        withIdentifiers: await center.deliveredNotifications().filter {
          $0.request.content.categoryIdentifier == "reply-sending"
        }.map(\.request.identifier))
    }
  }

  // Makes this device's Send Reminder notifications, pending or delivered, exactly
  // `notifications` while `owner` holds Drafts here: every other is withdrawn first, then each one
  // still ahead is scheduled for its due instant, replacing one under its identifier. A reminder
  // offers no action and nothing that sends its Draft; its tap opens the Draft. Rejects when one could not be scheduled, so
  // JavaScript tries again. Runs in the registration operation gate, so a sign-out's withdrawal is
  // never followed by a stale schedule.
  @objc(scheduleReminderNotifications:notifications:resolver:rejecter:)
  func scheduleReminderNotifications(
    _ owner: String, notifications: [[String: Any]],
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    performStep("scheduleReminderNotifications", resolve, reject: reject) { store in
      // A storage failure rejects, so JavaScript tries again; only another account skips.
      guard try store.draftOwner().1 == owner else {
        UnwiredNotifications.logger.info("Send Reminder notifications skipped: account changed")
        return
      }
      let center = UNUserNotificationCenter.current()
      let previews = UserDefaults.standard.bool(forKey: Self.notificationPreviewsKey)
      var wanted: [(id: String, content: UNNotificationContent, due: Date)] = []
      for notification in notifications {
        guard let id = notification["id"] as? String, id.hasPrefix("send-reminder."),
          let title = notification["title"] as? String,
          let body = notification["body"] as? String,
          let profile = notification["profile"] as? String, !profile.isEmpty,
          let draft = notification["draft"] as? String, !draft.isEmpty,
          let dueAt = notification["dueAt"] as? Double,
          let shown = notification["previews"] as? Bool, !shown || previews
        else { continue }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = profile
        // Its tap opens the Draft for this account only.
        content.userInfo = ["account": owner, "draft": draft]
        wanted.append((id, content, Date(timeIntervalSince1970: dueAt / 1000)))
      }
      let kept = Set(wanted.map { $0.id })
      let stale = { (id: String) in id.hasPrefix("send-reminder.") && !kept.contains(id) }
      center.removePendingNotificationRequests(
        withIdentifiers: await center.pendingNotificationRequests().map(\.identifier).filter(stale))
      center.removeDeliveredNotifications(
        withIdentifiers: await center.deliveredNotifications().map(\.request.identifier).filter(
          stale))
      var utc = Calendar(identifier: .gregorian)
      utc.timeZone = TimeZone(identifier: "UTC")!
      let now = Date()
      var added = 0
      var failed = 0
      for (id, content, due) in wanted where due > now {
        var components = utc.dateComponents(
          [.year, .month, .day, .hour, .minute, .second], from: due)
        components.timeZone = utc.timeZone
        do {
          try await center.add(
            UNNotificationRequest(
              identifier: id, content: content,
              trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
          added += 1
        } catch {
          failed += 1
          let error = error as NSError
          UnwiredNotifications.logger.error(
            "Send Reminder notification not scheduled: \(error.domain, privacy: .public) \(error.code, privacy: .public)"
          )
        }
      }
      UnwiredNotifications.logger.info(
        "Send Reminder notifications scheduled: \(added, privacy: .public) of \(notifications.count, privacy: .public)"
      )
      if failed > 0 { throw RegistrationError.unavailable }
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
