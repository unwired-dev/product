import Foundation

// The system Attachment Preview and share sheet for one Downloaded Attachment. Quick Look shows a
// file without launching another app or running it; sharing hands only this file to the chosen
// service. `ended` runs once when the system no longer needs the file, so its owner can defer
// deleting it until then.

// The window whose reader asked for the presentation, captured when the request arrives so a
// later focus change cannot move the preview or share sheet into another window.
#if os(iOS)
  import UIKit
  typealias PresentationWindow = UIWindow
#elseif os(macOS)
  import AppKit
  typealias PresentationWindow = NSWindow
#endif
@MainActor final class PresentationOrigin {
  weak var window: PresentationWindow?
  init(_ window: PresentationWindow?) { self.window = window }
}

#if os(iOS)
  import QuickLook
  import UIKit

  @MainActor enum AttachmentPresenter {
    static func origin() -> PresentationOrigin {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      return PresentationOrigin(scene?.keyWindow)
    }

    static func present(
      _ url: URL, share: Bool, from origin: PresentationOrigin,
      ended: @escaping @MainActor () -> Void
    ) -> Bool {
      guard let window = origin.window, !window.isHidden,
        window.windowScene?.activationState == .foregroundActive,
        let presenter = topController(in: window), !presenter.isBeingPresented,
        !presenter.isBeingDismissed, presenter.viewIfLoaded?.window === window
      else { return false }
      if share {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
          MainActor.assumeIsolated { ended() }
        }
        // iPad shows the sheet as a popover from the reader.
        if let popover = sheet.popoverPresentationController {
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
      } else {
        let preview = AttachmentPreviewController()
        let next = PreviewSource(url: url, ended: ended)
        preview.source = next
        preview.dataSource = next
        preview.delegate = next
        presenter.present(preview, animated: true)
      }
      return true
    }

    private static func topController(in window: UIWindow?) -> UIViewController? {
      var controller = window?.rootViewController
      while let presented = controller?.presentedViewController { controller = presented }
      return controller
    }
  }

  // Each presented controller retains its own weak data source/delegate, including stacked previews.
  @MainActor final class AttachmentPreviewController: QLPreviewController {
    var source: PreviewSource?
  }

  @MainActor final class PreviewSource: NSObject, QLPreviewControllerDataSource,
    @preconcurrency QLPreviewControllerDelegate
  {
    let url: URL
    private var ended: (@MainActor () -> Void)?
    init(url: URL, ended: @escaping @MainActor () -> Void) {
      self.url = url
      self.ended = ended
    }
    func end() {
      let ended = self.ended
      self.ended = nil
      ended?()
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
      -> any QLPreviewItem
    { url as NSURL }
    func previewControllerDidDismiss(_ controller: QLPreviewController) { end() }
  }
#elseif os(macOS)
  import AppKit
  import Quartz

  @MainActor enum AttachmentPresenter {
    // `nextResponder` does not retain, so each window's controller is owned here until the window
    // closes, when the window's original responder chain is restored.
    private static var controllers: [ObjectIdentifier: PreviewController] = [:]
    // The picker and the chosen service keep their delegates weakly.
    private static var shares: Set<ShareLease> = []

    private static func controller(for window: NSWindow) -> PreviewController {
      let key = ObjectIdentifier(window)
      if let current = controllers[key] { return current }
      let controller = PreviewController()
      controller.nextResponder = window.nextResponder
      window.nextResponder = controller
      controllers[key] = controller
      controller.closing = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { [weak window] _ in
        MainActor.assumeIsolated {
          guard let window, let owned = controllers.removeValue(forKey: key) else { return }
          if window.nextResponder === owned { window.nextResponder = owned.nextResponder }
          // The panel's data source does not retain the controller either.
          if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
            (panel.dataSource as AnyObject?) === owned
          {
            panel.dataSource = nil
            panel.orderOut(nil)
          }
          owned.show(nil, ended: nil)
          if let closing = owned.closing { NotificationCenter.default.removeObserver(closing) }
        }
      }
      return controller
    }

    static func origin() -> PresentationOrigin {
      PresentationOrigin(NSApp.keyWindow ?? NSApp.mainWindow)
    }

    static func present(
      _ url: URL, share: Bool, from origin: PresentationOrigin,
      ended: @escaping @MainActor () -> Void
    ) -> Bool {
      guard let window = origin.window, window.isVisible, let view = window.contentView
      else { return false }
      if share {
        let picker = NSSharingServicePicker(items: [url])
        let lease = ShareLease { lease in
          shares.remove(lease)
          ended()
        }
        shares.insert(lease)
        picker.delegate = lease
        picker.show(
          relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
          of: view, preferredEdge: .minY)
        return true
      }
      guard let panel = QLPreviewPanel.shared() else { return false }
      // The shared panel negotiates through the active window's responder chain.
      window.makeKeyAndOrderFront(nil)
      window.makeMain()
      let preview = controller(for: window)
      preview.show(url, ended: nil)
      panel.updateController()
      guard (panel.currentController as AnyObject?) === preview else {
        preview.show(nil, ended: nil)
        return false
      }
      preview.show(url, ended: ended)
      panel.reloadData()
      panel.makeKeyAndOrderFront(nil)
      return true
    }
  }

  // Ends when the person dismisses the picker, or when the chosen service finishes or fails.
  final class ShareLease: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private var ended: (@MainActor (ShareLease) -> Void)?
    init(ended: @escaping @MainActor (ShareLease) -> Void) { self.ended = ended }

    @MainActor private func end() {
      let ended = self.ended
      self.ended = nil
      ended?(self)
    }
    func sharingServicePicker(
      _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
      MainActor.assumeIsolated {
        if let service { service.delegate = self } else { end() }
      }
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
      MainActor.assumeIsolated { end() }
    }
    func sharingService(
      _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error
    ) {
      MainActor.assumeIsolated { end() }
    }
  }

  final class PreviewController: NSResponder, QLPreviewPanelDataSource {
    private(set) var url: URL?
    private var ended: (@MainActor () -> Void)?
    var closing: (any NSObjectProtocol)?

    // Showing another file, or nothing, ends the previous preview's lease.
    @MainActor func show(_ next: URL?, ended nextEnded: (@MainActor () -> Void)?) {
      let previous = ended
      url = next
      ended = nextEnded
      previous?()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { url != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
      panel.dataSource = nil
      MainActor.assumeIsolated { show(nil, ended: nil) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
      url.map { $0 as NSURL }
    }
  }
#endif
