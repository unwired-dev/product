import Foundation

// The system Attachment Preview and share sheet for one Downloaded Attachment. Quick Look shows a
// file without launching another app or running it; sharing hands only this file to the chosen
// service.
#if os(iOS)
  import QuickLook
  import UIKit

  @MainActor enum AttachmentPresenter {
    // Quick Look keeps its data source weakly.
    private static var source: PreviewSource?

    static func present(_ url: URL, share: Bool) -> Bool {
      guard let presenter = topController() else { return false }
      if share {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad shows the sheet as a popover from the reader.
        if let popover = sheet.popoverPresentationController {
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
      } else {
        let preview = QLPreviewController()
        let next = PreviewSource(url: url)
        source = next
        preview.dataSource = next
        presenter.present(preview, animated: true)
      }
      return true
    }

    private static func topController() -> UIViewController? {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      var controller = scene?.keyWindow?.rootViewController
      while let presented = controller?.presentedViewController { controller = presented }
      return controller
    }
  }

  @MainActor final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
      -> any QLPreviewItem
    { url as NSURL }
  }
#elseif os(macOS)
  import AppKit
  import Quartz

  @MainActor enum AttachmentPresenter {
    static func present(_ url: URL, share: Bool) -> Bool {
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView
      else { return false }
      if share {
        NSSharingServicePicker(items: [url]).show(
          relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
          of: view, preferredEdge: .minY)
        return true
      }
      // The Quick Look panel asks the responder chain for its controller.
      let controller: PreviewController
      if let current = window.nextResponder as? PreviewController {
        controller = current
      } else {
        controller = PreviewController()
        controller.nextResponder = window.nextResponder
        window.nextResponder = controller
      }
      controller.url = url
      guard let panel = QLPreviewPanel.shared() else { return false }
      panel.updateController()
      panel.reloadData()
      panel.makeKeyAndOrderFront(nil)
      return true
    }
  }

  final class PreviewController: NSResponder, QLPreviewPanelDataSource {
    var url: URL?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { url != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
      url.map { $0 as NSURL }
    }
  }
#endif
