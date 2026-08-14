import SwiftUI
import UIKit
import WebKit

// swiftlint:disable file_length

enum MessageHTMLLinkPolicy {
  private static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]

  static func externalURL(_ url: URL, isUserActivated: Bool) -> URL? {
    guard isUserActivated, let scheme = url.scheme?.lowercased(),
      allowedSchemes.contains(scheme)
    else { return nil }
    return url
  }
}

enum SuspiciousLinkReason: Equatable, Sendable {
  case crossSiteRedirect
  case deceptiveCharacters
  case displayedDestinationMismatch
  case displayedSchemeMismatch
  case embeddedCredentials
  case internationalizedHost
  case numericHost

  var explanation: String {
    switch self {
    case .crossSiteRedirect:
      "The link contains a redirect target on a different website."
    case .deceptiveCharacters:
      "The destination contains invisible direction-changing characters."
    case .displayedDestinationMismatch:
      "The link text names a different destination."
    case .displayedSchemeMismatch:
      "The link text and destination use different link types or security schemes."
    case .embeddedCredentials:
      "Text before an @ sign may disguise the destination's real website."
    case .internationalizedHost:
      "The website name uses internationalized characters that can resemble other characters."
    case .numericHost:
      "The destination uses a numeric network address instead of a website name."
    }
  }
}

struct SuspiciousLinkWarning: Equatable, Sendable {
  let destination: URL
  let reasons: [SuspiciousLinkReason]

  var explanation: String {
    let reasonList = reasons.map { "• \($0.explanation)" }.joined(separator: "\n")
    return """
      \(reasonList)

      Actual destination:
      \(destination.absoluteString)

      This check runs only on this device. Proceed only if you intended to open this destination.
      """
  }
}

enum SuspiciousLinkDetector {
  private struct DisplayedDestination {
    let hasExplicitScheme: Bool
    let url: URL
  }

  private static let redirectQueryNames: Set<String> = [
    "continue", "dest", "destination", "next", "redirect", "redirect_to", "redirect_uri",
    "redirect_url", "return", "return_to", "target", "url",
  ]

  static func warning(
    for destination: URL,
    presentations: [MessageHTMLLinkPresentation] = []
  ) -> SuspiciousLinkWarning? {
    var reasons = destinationReasons(destination)
    for presentation in presentations
    where equivalent(presentation.destination, destination) {
      for reason in presentationReasons(presentation, destination: destination) {
        append(reason, to: &reasons)
      }
    }

    guard !reasons.isEmpty else { return nil }
    return SuspiciousLinkWarning(destination: destination, reasons: reasons)
  }

  private static func destinationReasons(_ destination: URL) -> [SuspiciousLinkReason] {
    var reasons: [SuspiciousLinkReason] = []
    if destination.user != nil || destination.password != nil {
      append(.embeddedCredentials, to: &reasons)
    }
    if let host = destination.host?.lowercased() {
      if RemoteMessageContentIPAddress.numericAddress(host) != nil {
        append(.numericHost, to: &reasons)
      }
      if host.unicodeScalars.contains(where: { !$0.isASCII })
        || host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") })
      {
        append(.internationalizedHost, to: &reasons)
      }
    }
    if containsDeceptiveCharacters(destination.absoluteString) {
      append(.deceptiveCharacters, to: &reasons)
    }
    if containsCrossSiteRedirect(destination) {
      append(.crossSiteRedirect, to: &reasons)
    }
    return reasons
  }

  private static func presentationReasons(
    _ presentation: MessageHTMLLinkPresentation,
    destination: URL
  ) -> [SuspiciousLinkReason] {
    guard let displayed = displayedDestination(in: presentation.displayedText) else { return [] }
    var reasons: [SuspiciousLinkReason] = []
    if displayed.hasExplicitScheme,
      displayed.url.scheme?.lowercased() != destination.scheme?.lowercased()
    {
      append(.displayedSchemeMismatch, to: &reasons)
    }
    guard normalizedHost(displayed.url.host) == normalizedHost(destination.host) else {
      append(.displayedDestinationMismatch, to: &reasons)
      return reasons
    }

    let displayedComponents = URLComponents(url: displayed.url, resolvingAgainstBaseURL: false)
    let destinationComponents = URLComponents(url: destination, resolvingAgainstBaseURL: false)
    if displayedComponents?.user != nil || displayedComponents?.password != nil {
      append(.embeddedCredentials, to: &reasons)
    }
    if displayedComponents.map({ normalizedPort($0) })
      != destinationComponents.map({ normalizedPort($0) })
    {
      append(.displayedDestinationMismatch, to: &reasons)
    }
    let displayedPath = displayedComponents?.percentEncodedPath ?? ""
    if !displayedPath.isEmpty, displayedPath != "/",
      displayedPath != destinationComponents?.percentEncodedPath
    {
      append(.displayedDestinationMismatch, to: &reasons)
    }
    if displayedComponents?.percentEncodedQuery != nil,
      displayedComponents?.percentEncodedQuery != destinationComponents?.percentEncodedQuery
    {
      append(.displayedDestinationMismatch, to: &reasons)
    }
    if displayedComponents?.percentEncodedFragment != nil,
      displayedComponents?.percentEncodedFragment != destinationComponents?.percentEncodedFragment
    {
      append(.displayedDestinationMismatch, to: &reasons)
    }
    return reasons
  }

  private static func append(
    _ reason: SuspiciousLinkReason,
    to reasons: inout [SuspiciousLinkReason]
  ) {
    if !reasons.contains(reason) { reasons.append(reason) }
  }

  private static func containsCrossSiteRedirect(_ destination: URL) -> Bool {
    guard let destinationHost = normalizedHost(destination.host),
      let queryItems = URLComponents(
        url: destination,
        resolvingAgainstBaseURL: false
      )?.queryItems
    else { return false }

    return queryItems.contains { item in
      guard redirectQueryNames.contains(item.name.lowercased()),
        let value = item.value
      else { return false }
      let redirect =
        value.hasPrefix("//") ? URL(string: "https:\(value)") : URL(string: value)
      guard let redirect,
        ["http", "https"].contains(redirect.scheme?.lowercased()),
        let redirectHost = normalizedHost(redirect.host)
      else { return false }
      return redirectHost != destinationHost
    }
  }

  private static func containsDeceptiveCharacters(_ value: String) -> Bool {
    let decoded = value.removingPercentEncoding ?? value
    return decoded.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
        true
      default:
        false
      }
    }
  }

  private static func displayedDestination(in text: String) -> DisplayedDestination? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "<>[](){}\"'"))
    if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
      let tokenPattern =
        #"(?:(?:[a-z][a-z0-9+.-]*:|//)[^\s<>\[\](){}\"']+|"#
        + #"(?<![@a-z0-9.-])(?:www\.)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+"#
        + #"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?::[0-9]+)?"#
        + #"(?:[/?:#][^\s<>\[\](){}\"']*)?)"#
      guard
        let range = text.range(
          of: tokenPattern,
          options: [.regularExpression, .caseInsensitive]
        )
      else { return nil }
      text = String(text[range])
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    }
    guard !text.isEmpty else { return nil }

    let hasExplicitScheme =
      text.range(
        of: #"^[a-z][a-z0-9+.-]*:"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil
    if hasExplicitScheme, let url = URL(string: text) {
      return DisplayedDestination(hasExplicitScheme: true, url: url)
    }

    if text.hasPrefix("//"), let url = URL(string: "https:\(text)") {
      return DisplayedDestination(hasExplicitScheme: false, url: url)
    }

    guard !text.contains("@"),
      text.range(
        of: #"^(?:www\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]+)?(?:[/?:#].*)?$"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil,
      let url = URL(string: "https://\(text)")
    else { return nil }
    return DisplayedDestination(hasExplicitScheme: false, url: url)
  }

  private static func equivalent(_ first: URL, _ second: URL) -> Bool {
    guard let firstComponents = URLComponents(url: first, resolvingAgainstBaseURL: false),
      let secondComponents = URLComponents(url: second, resolvingAgainstBaseURL: false)
    else { return first == second }
    return firstComponents.scheme?.lowercased() == secondComponents.scheme?.lowercased()
      && normalizedHost(firstComponents.host) == normalizedHost(secondComponents.host)
      && normalizedPort(firstComponents) == normalizedPort(secondComponents)
      && firstComponents.percentEncodedPath == secondComponents.percentEncodedPath
      && firstComponents.percentEncodedQuery == secondComponents.percentEncodedQuery
      && firstComponents.percentEncodedFragment == secondComponents.percentEncodedFragment
  }

  private static func normalizedHost(_ host: String?) -> String? {
    guard var host = host?.lowercased() else { return nil }
    if host.hasSuffix(".") { host.removeLast() }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
  }

  private static func normalizedPort(_ components: URLComponents) -> Int? {
    switch (components.scheme?.lowercased(), components.port) {
    case ("http", 80), ("https", 443): nil
    case (_, let port): port
    }
  }
}

private struct SuspiciousLinkOpenModifier: ViewModifier {
  let authorize: () async -> Bool
  let presentations: [MessageHTMLLinkPresentation]

  @Environment(\.openURL) private var systemOpenURL
  @State private var linkTask: Task<Void, Never>?
  @State private var warning: SuspiciousLinkWarning?

  func body(content: Content) -> some View {
    content
      .environment(
        \.openURL,
        OpenURLAction { destination in
          requestOpen(destination)
          return .handled
        }
      )
      .alert(
        "Check This Link",
        isPresented: warningIsPresented,
        presenting: warning
      ) { warning in
        Button("Cancel", role: .cancel) {
          self.warning = nil
        }
        Button("Copy Link") {
          copy(warning.destination)
        }
        Button("Proceed") {
          openAfterAuthorization(warning.destination)
        }
      } message: { warning in
        Text(warning.explanation)
      }
      .onDisappear {
        linkTask?.cancel()
        linkTask = nil
        warning = nil
      }
  }

  private var warningIsPresented: Binding<Bool> {
    Binding(
      get: { warning != nil },
      set: { isPresented in
        if !isPresented { warning = nil }
      }
    )
  }

  private func requestOpen(_ destination: URL) {
    linkTask?.cancel()
    linkTask = Task { @MainActor in
      guard await authorize(), !Task.isCancelled else { return }
      if let warning = SuspiciousLinkDetector.warning(
        for: destination,
        presentations: presentations
      ) {
        self.warning = warning
      } else {
        systemOpenURL(destination)
      }
      linkTask = nil
    }
  }

  private func copy(_ destination: URL) {
    linkTask?.cancel()
    linkTask = Task { @MainActor in
      guard await authorize(), !Task.isCancelled else { return }
      UIPasteboard.general.string = destination.absoluteString
      warning = nil
      linkTask = nil
    }
  }

  private func openAfterAuthorization(_ destination: URL) {
    warning = nil
    linkTask?.cancel()
    linkTask = Task { @MainActor in
      guard await authorize(), !Task.isCancelled else { return }
      systemOpenURL(destination)
      linkTask = nil
    }
  }
}

extension View {
  func handlingSuspiciousLinks(
    presentations: [MessageHTMLLinkPresentation],
    authorize: @escaping () async -> Bool
  ) -> some View {
    modifier(
      SuspiciousLinkOpenModifier(
        authorize: authorize,
        presentations: presentations
      ))
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
      palette = Palette(foreground: "#fff", link: "#75adff")
    case (.dark, false):
      palette = Palette(foreground: "#f2f2f7", link: "#6ea8ff")
    case (.light, true):
      palette = Palette(foreground: "#000", link: "#0058d1")
    case (.light, false):
      palette = Palette(foreground: "#1c1c1e", link: "#0066cc")
    }

    let typefaceRule =
      style.typeface.htmlFontFamilyOverride.map {
        "body, body * { font-family: \($0) !important; }"
      } ?? ""

    return """
      :root { color-scheme: \(style.colorScheme == .dark ? "dark" : "light"); }
      html {
        background: transparent;
        color: \(palette.foreground);
        -webkit-text-size-adjust: \(style.readingTextSize.cssPercentage);
      }
      body {
        background: transparent;
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
  let onResetRemoteContent: () -> Void
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
    connectionId: MailboxConnectionId?,
    html: SanitizedMessageHTML,
    onRenderingFailure: @escaping () -> Void,
    onResetRemoteContent: @escaping () -> Void = {},
    loadRemoteContent:
      @escaping (SanitizedMessageHTML) async throws
      -> RemoteMessageContentLoadResult = {
        try await RemoteMessageContentLoader().load($0)
      }
  ) {
    self.connectionId = connectionId
    self.html = html
    self.onRenderingFailure = onRenderingFailure
    self.onResetRemoteContent = onResetRemoteContent
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
      onResetRemoteContent()
      remoteContent.apply(
        policy: remoteContentPolicy,
        hasRemoteImages: !html.remoteImageReferences.isEmpty
      )
    }
    .onChange(of: html) {
      onResetRemoteContent()
      remoteContent.apply(
        policy: remoteContentPolicy,
        hasRemoteImages: !html.remoteImageReferences.isEmpty
      )
    }
    .onDisappear {
      onResetRemoteContent()
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
