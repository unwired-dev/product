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

  static func applyPrivacySettings(to webView: WKWebView) {
    webView.allowsLinkPreview = false
  }
}

enum MessageHTMLLayout {
  static let maximumHeight: CGFloat = 20_000

  static func height(for contentSize: CGSize) -> CGFloat {
    min(max(contentSize.height, 1), maximumHeight)
  }

  static func isInternallyScrollable(
    for contentSize: CGSize,
    within viewportSize: CGSize
  ) -> Bool {
    contentSize.height > maximumHeight || contentSize.width > viewportSize.width
  }
}

enum MessageHTMLNavigationFailure {
  static func shouldTriggerFallback(for error: Error) -> Bool {
    let error = error as NSError
    let isURLCancellation =
      error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    let isWebKitPolicyCancellation = error.domain == "WebKitErrorDomain" && error.code == 102
    return !isURLCancellation && !isWebKitPolicyCancellation
  }
}

struct MessageHTMLStyle: Equatable {
  enum ColorScheme: Equatable {
    case dark
    case light
  }

  let colorScheme: ColorScheme
  let increasedContrast: Bool
  let readingTextSize: ReadingTextSize
  let typeface: MessageBodyTypeface
}

enum MessageHTMLDocument {
  private struct Palette {
    let background: String
    let foreground: String
    let link: String
  }

  static func styled(
    _ html: SanitizedMessageHTML,
    style: MessageHTMLStyle
  ) -> String {
    html.documentHTML.replacingOccurrences(
      of: "</head>",
      with: "<style>\(stylesheet(for: style))</style></head>"
    )
  }

  private static func stylesheet(for style: MessageHTMLStyle) -> String {
    let palette: Palette
    switch (style.colorScheme, style.increasedContrast) {
    case (.dark, true):
      palette = Palette(background: "#000", foreground: "#fff", link: "#75adff")
    case (.dark, false):
      palette = Palette(background: "#000", foreground: "#f2f2f7", link: "#6ea8ff")
    case (.light, true):
      palette = Palette(background: "#fff", foreground: "#000", link: "#0058d1")
    case (.light, false):
      palette = Palette(background: "#fff", foreground: "#1c1c1e", link: "#0066cc")
    }

    let typefaceRule =
      style.typeface.htmlFontFamilyOverride.map {
        "body, body * { font-family: \($0) !important; }"
      } ?? ""

    return """
      :root { color-scheme: \(style.colorScheme == .dark ? "dark" : "light"); }
      html {
        background: \(palette.background);
        color: \(palette.foreground);
        -webkit-text-size-adjust: \(style.readingTextSize.cssPercentage);
      }
      body {
        background: \(palette.background);
        color: \(palette.foreground);
      }
      \(typefaceRule)
      a { color: \(palette.link); }
      """
  }
}

struct MessageHTMLView: View {
  let connectionId: MailboxConnectionId?
  let html: SanitizedMessageHTML
  let onRenderingFailure: () -> Void
  private let loadRemoteContent:
    (SanitizedMessageHTML) async throws -> RemoteMessageContentLoadResult

  @Environment(AppearancePreferences.self) private var appearancePreferences: AppearancePreferences?
  @Environment(MessageContentPreferences.self) private var messageContentPreferences:
    MessageContentPreferences?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.openURL) private var openURL
  @State private var contentHeight: CGFloat = 1
  @State private var remoteContent = RemoteMessageContentPresentation()

  init(
    connectionId: MailboxConnectionId? = nil,
    html: SanitizedMessageHTML,
    onRenderingFailure: @escaping () -> Void,
    loadRemoteContent:
      @escaping (SanitizedMessageHTML) async throws
      -> RemoteMessageContentLoadResult = {
        try await RemoteMessageContentLoader().load($0)
      }
  ) {
    self.connectionId = connectionId
    self.html = html
    self.onRenderingFailure = onRenderingFailure
    self.loadRemoteContent = loadRemoteContent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !displayedHTML.remoteImageReferences.isEmpty {
        RemoteMessageContentNotice(
          policy: remoteContentPolicy,
          requestLoad: remoteContent.requestLoad,
          state: remoteContent.state
        )
      }
      MessageHTMLWebView(
        contentHeight: $contentHeight,
        documentHTML: MessageHTMLDocument.styled(
          displayedHTML,
          style: MessageHTMLStyle(
            colorScheme: colorScheme == .dark ? .dark : .light,
            increasedContrast: appearancePreferences?.increasedContrast == true
              || colorSchemeContrast == .increased,
            readingTextSize: appearancePreferences?.readingTextSize ?? .standard,
            typeface: appearancePreferences?.messageBodyTypeface ?? .senderFormatting
          )
        ),
        onOpenURL: { openURL($0) },
        onRenderingFailure: onRenderingFailure
      )
      .frame(maxWidth: .infinity, minHeight: 1, idealHeight: contentHeight)
      .frame(height: contentHeight)
    }
    .task(id: remoteContent.loadRequest) {
      await remoteContent.load(originalHTML: html, using: loadRemoteContent)
    }
    .task(id: remoteContentPolicy) {
      remoteContent.apply(
        policy: remoteContentPolicy,
        hasRemoteImages: !html.remoteImageReferences.isEmpty
      )
    }
    .onChange(of: html) {
      remoteContent.apply(
        policy: remoteContentPolicy,
        hasRemoteImages: !html.remoteImageReferences.isEmpty
      )
    }
    .onDisappear {
      remoteContent.reset()
    }
  }

  private var displayedHTML: SanitizedMessageHTML {
    remoteContent.displayedHTML(originalHTML: html)
  }

  private var remoteContentPolicy: RemoteContentLoadPolicy {
    messageContentPreferences?.remoteContentPolicy(for: connectionId) ?? .ask
  }

}

struct MessageHTMLWebView: UIViewRepresentable {
  @Binding var contentHeight: CGFloat
  let documentHTML: String
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
    MessageHTMLWebViewConfiguration.applyPrivacySettings(to: webView)
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
    guard context.coordinator.loadedDocument != documentHTML else { return }

    context.coordinator.loadedDocument = documentHTML
    context.coordinator.isLoadingDocument = true
    webView.loadHTMLString(documentHTML, baseURL: nil)
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
    private var viewportObservation: NSKeyValueObservation?

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
        self?.updateLayout(for: scrollView)
      }
      viewportObservation = webView.observe(
        \.bounds,
        options: [.new]
      ) { [weak self] webView, _ in
        self?.updateLayout(for: webView.scrollView)
      }
    }

    func stopObservingContentSize() {
      contentSizeObservation = nil
      viewportObservation = nil
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
      updateLayout(for: webView.scrollView)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation?,
      withError error: Error
    ) {
      if MessageHTMLNavigationFailure.shouldTriggerFallback(for: error) {
        renderingDidFail()
      }
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation?,
      withError error: Error
    ) {
      if MessageHTMLNavigationFailure.shouldTriggerFallback(for: error) {
        renderingDidFail()
      }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      renderingDidFail()
    }

    private func renderingDidFail() {
      isLoadingDocument = false
      onRenderingFailure()
    }

    private func updateLayout(for scrollView: UIScrollView) {
      scrollView.isScrollEnabled = MessageHTMLLayout.isInternallyScrollable(
        for: scrollView.contentSize,
        within: scrollView.bounds.size
      )
      let height = MessageHTMLLayout.height(for: scrollView.contentSize)
      DispatchQueue.main.async { [weak self] in
        self?.onHeightChange(height)
      }
    }
  }
}
