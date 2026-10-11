import Foundation

// The application delegates' entry points for APNs. The Mac delegate finds this class by name, so
// it needs no generated Swift header.
@objc(UnwiredPushWakes)
final class UnwiredPushWakes: NSObject {
  // A new or rotated token re-registers the routes this device holds under its credential.
  @MainActor @objc static func registerDeviceToken(_ token: Data) {
    let device = PushDevice(token: token)
    guard device != PushWakes.shared.device else { return }
    PushWakes.shared.device = device
    UnwiredRegistration.pushDeviceChanged()
  }

  // `complete` receives "synchronized", "ignored" or "failed" once JavaScript settles the wake.
  @MainActor @objc static func receiveRemoteNotification(
    _ payload: [AnyHashable: Any], complete: @escaping (String) -> Void
  ) {
    PushWakes.shared.receive(payload, complete: complete)
  }
}
