import SwiftUI
import UIKit

/// Hosts the SwiftUI Share Extension and coordinates explicit save/cancel completion.
final class ShareViewController: UIViewController {
  private var hostingController: UIHostingController<ShareExtensionView>?

  override func viewDidLoad() {
    super.viewDidLoad()
    let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    let viewModel = ShareExtensionViewModel(
      inputLoader: SystemShareExtensionInputLoader(extensionItems: extensionItems)
    )
    let rootView = ShareExtensionView(
      viewModel: viewModel,
      cancel: { [weak self] in self?.cancelRequest() },
      openDraft: { [weak self] url in self?.openDraft(url) }
    )
    let hostingController = UIHostingController(rootView: rootView)
    addChild(hostingController)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    hostingController.didMove(toParent: self)
    self.hostingController = hostingController
  }

  private func cancelRequest() {
    extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
  }

  private func openDraft(_ url: URL) {
    guard let extensionContext else { return }
    extensionContext.open(url) { _ in
      extensionContext.completeRequest(returningItems: nil)
    }
  }
}
