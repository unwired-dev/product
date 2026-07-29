import SwiftUI
import WebKit

enum MessageHTMLLinkPolicy {
  private static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]

  static func externalURL(_ url: URL, isUserActivated: Bool) -> URL? {
    guard isUserActivated, let scheme = url.scheme?.lowercased(),
      allowedSchemes.contains(scheme)
    else { return nil }
    return url
  }
}

enum MessageHTMLWebViewConfiguration {
  static func make() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    return configuration
  }
}

enum MessageHTMLLayout {
  static func height(for contentSize: CGSize) -> CGFloat {
    max(contentSize.height, 1)
  }
}

struct MessageHTMLView: View {
  let html: SanitizedMessageHTML
  let onRenderingFailure: () -> Void

  @Environment(\.openURL) private var openURL
  @State private var contentHeight: CGFloat = 1

  var body: some View {
    MessageHTMLWebView(
      contentHeight: $contentHeight,
      html: html,
      onOpenURL: { openURL($0) },
      onRenderingFailure: onRenderingFailure
    )
    .frame(maxWidth: .infinity, minHeight: 1, idealHeight: contentHeight)
    .frame(height: contentHeight)
  }
}

private struct MessageHTMLWebView: UIViewRepresentable {
  @Binding var contentHeight: CGFloat
  let html: SanitizedMessageHTML
  let onOpenURL: (URL) -> Void
  let onRenderingFailure: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onHeightChange: { contentHeight = $0 },
      onOpenURL: onOpenURL,
      onRenderingFailure: onRenderingFailure
    )
  }

  func makeUIView(context: Context) -> WKWebView {
    let webView = WKWebView(
      frame: .zero,
      configuration: MessageHTMLWebViewConfiguration.make()
    )
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.navigationDelegate = context.coordinator
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    context.coordinator.observeContentSize(of: webView)
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    context.coordinator.onHeightChange = { contentHeight = $0 }
    context.coordinator.onOpenURL = onOpenURL
    context.coordinator.onRenderingFailure = onRenderingFailure
    guard context.coordinator.loadedDocument != html.documentHTML else { return }

    context.coordinator.loadedDocument = html.documentHTML
    context.coordinator.isLoadingDocument = true
    webView.loadHTMLString(html.documentHTML, baseURL: nil)
  }

  static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.stopObservingContentSize()
    webView.navigationDelegate = nil
    webView.stopLoading()
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var isLoadingDocument = false
    var loadedDocument: String?
    var onHeightChange: (CGFloat) -> Void
    var onOpenURL: (URL) -> Void
    var onRenderingFailure: () -> Void
    private var contentSizeObservation: NSKeyValueObservation?

    init(
      onHeightChange: @escaping (CGFloat) -> Void,
      onOpenURL: @escaping (URL) -> Void,
      onRenderingFailure: @escaping () -> Void
    ) {
      self.onHeightChange = onHeightChange
      self.onOpenURL = onOpenURL
      self.onRenderingFailure = onRenderingFailure
    }

    func observeContentSize(of webView: WKWebView) {
      contentSizeObservation = webView.scrollView.observe(
        \.contentSize,
        options: [.initial, .new]
      ) { [weak self] scrollView, _ in
        self?.onHeightChange(MessageHTMLLayout.height(for: scrollView.contentSize))
      }
    }

    func stopObservingContentSize() {
      contentSizeObservation = nil
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      let isInitialDocument =
        isLoadingDocument && navigationAction.navigationType == .other
        && (navigationAction.request.url == nil
          || navigationAction.request.url?.absoluteString == "about:blank")
      guard !isInitialDocument else {
        decisionHandler(.allow)
        return
      }

      if let url = navigationAction.request.url,
        let externalURL = MessageHTMLLinkPolicy.externalURL(
          url,
          isUserActivated: navigationAction.navigationType == .linkActivated
        )
      {
        onOpenURL(externalURL)
      }
      decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      isLoadingDocument = false
      onHeightChange(MessageHTMLLayout.height(for: webView.scrollView.contentSize))
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation?,
      withError error: Error
    ) {
      renderingDidFail()
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation?,
      withError error: Error
    ) {
      renderingDidFail()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      renderingDidFail()
    }

    private func renderingDidFail() {
      isLoadingDocument = false
      onRenderingFailure()
    }
  }
}
