import Foundation

// The application delegates' entry points for APNs. The Mac delegate finds this class by name, so
// it needs no generated Swift header.
@objc(UnwiredPushWakes)
final class UnwiredPushWakes: NSObject {
  // Registration with the relay waits for the next verified Inbox, under the device's credential.
  @MainActor @objc static func registerDeviceToken(_ token: Data) {
    PushWakes.shared.device = PushDevice(token: token)
  }

  // `complete` receives "synchronized", "ignored" or "failed" once JavaScript settles the wake.
  @MainActor @objc static func receiveRemoteNotification(
    _ payload: [AnyHashable: Any], complete: @escaping (String) -> Void
  ) {
    PushWakes.shared.receive(payload, complete: complete)
  }
}
