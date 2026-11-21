import Foundation

// The system Attachment Preview, share sheet and, on iPhone and iPad, Save to Files picker for one
// Downloaded Attachment. Quick Look shows a file without launching another app or running it;
// sharing hands only this file to the chosen service; saving writes a copy where the person
// chooses. `ended` runs once when the system no longer needs the file, so its owner can defer
// deleting it until then, with the saved copy's location after a save.

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
    enum Action: String { case open, share, save }

    static func origin() -> PresentationOrigin {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      return PresentationOrigin(scene?.keyWindow)
    }

    static func present(
      _ url: URL, action: Action, from origin: PresentationOrigin,
      ended: @escaping @MainActor (URL?) -> Void
    ) -> Bool {
      guard let window = origin.window, !window.isHidden,
        window.windowScene?.activationState == .foregroundActive,
        let presenter = topController(in: window), !presenter.isBeingPresented,
        !presenter.isBeingDismissed, presenter.viewIfLoaded?.window === window
      else { return false }
      switch action {
      case .share:
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
          MainActor.assumeIsolated { ended(nil) }
        }
        // iPad shows the sheet as a popover from the reader.
        if let popover = sheet.popoverPresentationController {
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
      case .save:
        // The system picker saves a copy where the person chooses, handling a name already there.
        let picker = AttachmentSavePicker(forExporting: [url], asCopy: true)
        let next = SaveDestination(ended: ended)
        picker.destination = next
        picker.delegate = next
        presenter.present(picker, animated: true)
      case .open:
        let preview = AttachmentPreviewController()
        let next = PreviewSource(url: url) { ended(nil) }
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

  @MainActor final class AttachmentSavePicker: UIDocumentPickerViewController {
    var destination: SaveDestination?
  }

  // Ends with the saved copy's location, or nil when the person cancelled.
  @MainActor final class SaveDestination: NSObject, UIDocumentPickerDelegate {
    private var ended: (@MainActor (URL?) -> Void)?
    init(ended: @escaping @MainActor (URL?) -> Void) { self.ended = ended }
    private func end(_ saved: URL?) {
      let ended = self.ended
      self.ended = nil
      ended?(saved)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
    { end(urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { end(nil) }
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
    enum Action: String { case open, share, save }

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

    // The Mac has no Save to Files picker yet; it saves through its own slice of #1681.
    static func present(
      _ url: URL, action: Action, from origin: PresentationOrigin,
      ended: @escaping @MainActor (URL?) -> Void
    ) -> Bool {
      guard action != .save, let window = origin.window, window.isVisible,
        let view = window.contentView
      else { return false }
      if action == .share {
        let picker = NSSharingServicePicker(items: [url])
        let lease = ShareLease { lease in
          shares.remove(lease)
          ended(nil)
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
      // A hidden panel adopts no controller, so it is shown before the check.
      let wasVisible = panel.isVisible
      panel.makeKeyAndOrderFront(nil)
      panel.updateController()
      guard (panel.currentController as AnyObject?) === preview else {
        if !wasVisible { panel.orderOut(nil) }
        preview.show(nil, ended: nil)
        return false
      }
      preview.show(url) { ended(nil) }
      panel.reloadData()
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
