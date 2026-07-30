import Foundation
import SwiftUI

enum AppearanceTheme: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: Self { self }

  var title: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

enum ReadingTextSize: String, CaseIterable, Identifiable {
  case small
  case standard
  case large
  case extraLarge

  var id: Self { self }

  var title: String {
    switch self {
    case .small:
      return "Smaller"
    case .standard:
      return "Default"
    case .large:
      return "Larger"
    case .extraLarge:
      return "Largest"
    }
  }

  var scale: CGFloat {
    switch self {
    case .small:
      return 0.875
    case .standard:
      return 1
    case .large:
      return 1.125
    case .extraLarge:
      return 1.25
    }
  }

  var cssPercentage: String {
    switch self {
    case .small:
      return "87.5%"
    case .standard:
      return "100%"
    case .large:
      return "112.5%"
    case .extraLarge:
      return "125%"
    }
  }
}

enum MessageBodyTypeface: String, CaseIterable, Identifiable {
  case senderFormatting
  case systemSerif
  case systemSansSerif

  var id: Self { self }

  var title: String {
    switch self {
    case .senderFormatting:
      return "Sender Formatting"
    case .systemSerif:
      return "System Serif"
    case .systemSansSerif:
      return "System Sans Serif"
    }
  }

  var fontDesign: Font.Design {
    switch self {
    case .systemSerif:
      return .serif
    case .senderFormatting, .systemSansSerif:
      return .default
    }
  }

  var htmlFontFamilyOverride: String? {
    switch self {
    case .senderFormatting:
      return nil
    case .systemSerif:
      return "ui-serif, Georgia, serif"
    case .systemSansSerif:
      return "-apple-system, BlinkMacSystemFont, sans-serif"
    }
  }
}

@MainActor
@Observable
final class AppearancePreferences {
  enum StorageKey: String {
    case increasedContrast = "appearance.increasedContrast"
    case messageBodyTypeface = "appearance.messageBodyTypeface"
    case readingTextSize = "appearance.readingTextSize"
    case theme = "appearance.theme"
  }

  var theme: AppearanceTheme {
    didSet { defaults.set(theme.rawValue, forKey: StorageKey.theme.rawValue) }
  }

  var readingTextSize: ReadingTextSize {
    didSet {
      defaults.set(readingTextSize.rawValue, forKey: StorageKey.readingTextSize.rawValue)
    }
  }

  var messageBodyTypeface: MessageBodyTypeface {
    didSet {
      defaults.set(
        messageBodyTypeface.rawValue,
        forKey: StorageKey.messageBodyTypeface.rawValue
      )
    }
  }

  var increasedContrast: Bool {
    didSet {
      defaults.set(increasedContrast, forKey: StorageKey.increasedContrast.rawValue)
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    theme =
      defaults.string(forKey: StorageKey.theme.rawValue)
      .flatMap(AppearanceTheme.init(rawValue:))
      ?? .system
    readingTextSize =
      defaults.string(forKey: StorageKey.readingTextSize.rawValue)
      .flatMap(ReadingTextSize.init(rawValue:))
      ?? .standard
    messageBodyTypeface =
      defaults.string(forKey: StorageKey.messageBodyTypeface.rawValue)
      .flatMap(MessageBodyTypeface.init(rawValue:))
      ?? .senderFormatting
    increasedContrast = defaults.bool(forKey: StorageKey.increasedContrast.rawValue)
  }
}

struct DeviceAppearanceModifier: ViewModifier {
  let preferences: AppearancePreferences

  func body(content: Content) -> some View {
    content
      .preferredColorScheme(preferences.theme.colorScheme)
      .contrast(preferences.increasedContrast ? 1.2 : 1)
  }
}

extension View {
  func deviceAppearance(_ preferences: AppearancePreferences) -> some View {
    modifier(DeviceAppearanceModifier(preferences: preferences))
  }
}

struct AppearanceSettingsView: View {
  @Environment(AppearancePreferences.self) private var preferences

  var navigationRequest: SettingsRouteRequest?

  @State private var highlightTask: Task<Void, Never>?
  @State private var highlightedControl: AppearanceSettingsControl?

  init(navigationRequest: SettingsRouteRequest? = nil) {
    self.navigationRequest = navigationRequest
  }

  var body: some View {
    @Bindable var preferences = preferences

    ScrollViewReader { proxy in
      Form {
        Section("Preview") {
          AppearancePreview(
            messageBodyTypeface: preferences.messageBodyTypeface,
            readingTextSize: preferences.readingTextSize
          )
        }

        Section("Theme") {
          Picker("Theme", selection: $preferences.theme) {
            ForEach(AppearanceTheme.allCases) { theme in
              Text(theme.title).tag(theme)
            }
          }
          .pickerStyle(.segmented)
          .id(AppearanceSettingsControl.theme)
          .settingsHighlight(highlightedControl == .theme)
        }

        Section("Reading") {
          Picker("Reading Text Size", selection: $preferences.readingTextSize) {
            ForEach(ReadingTextSize.allCases) { size in
              Text(size.title).tag(size)
            }
          }
          .id(AppearanceSettingsControl.readingTextSize)
          .settingsHighlight(highlightedControl == .readingTextSize)

          Picker("Message Body", selection: $preferences.messageBodyTypeface) {
            ForEach(MessageBodyTypeface.allCases) { typeface in
              Text(typeface.title).tag(typeface)
            }
          }
          .id(AppearanceSettingsControl.messageBody)
          .settingsHighlight(highlightedControl == .messageBody)
        }

        Section {
          Toggle("Increased Contrast", isOn: $preferences.increasedContrast)
            .id(AppearanceSettingsControl.increasedContrast)
            .settingsHighlight(highlightedControl == .increasedContrast)
        } footer: {
          Text("Adds contrast beyond the current system setting on this device.")
        }
      }
      .onChange(of: navigationRequest?.id, initial: true) { _, _ in
        applyNavigation(navigationRequest?.route, proxy: proxy)
      }
    }
    .onDisappear {
      highlightTask?.cancel()
    }
  }

  private func applyNavigation(
    _ route: SettingsRoute?,
    proxy: ScrollViewProxy
  ) {
    guard case .appearance(let control) = route?.context else { return }

    withAnimation {
      proxy.scrollTo(control, anchor: .center)
      highlightedControl = control
    }
    highlightTask?.cancel()
    highlightTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      withAnimation {
        highlightedControl = nil
      }
    }
  }
}

private struct AppearancePreview: View {
  let messageBodyTypeface: MessageBodyTypeface
  let readingTextSize: ReadingTextSize

  @ScaledMetric(relativeTo: .body) private var bodyPointSize = 17

  var body: some View {
    VStack(spacing: 0) {
      messageListPreview
      Divider()
      readerPreview
    }
    .background(.background)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.separator, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Live message list and reader preview")
  }

  private var messageListPreview: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(.blue)
        .frame(width: 34, height: 34)
        .overlay {
          Text("A")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
        }
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text("Avery")
            .font(.headline)
          Spacer()
          Text("10:42")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Weekend plans")
          .font(.subheadline.weight(.medium))
        Text("The trail opens early on Saturday.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(14)
  }

  private var readerPreview: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Weekend plans")
        .font(.headline)
      Text("Hi — the trail opens early on Saturday. Shall we meet at the north entrance?")
        .font(
          .system(
            size: bodyPointSize * readingTextSize.scale,
            design: messageBodyTypeface.fontDesign
          )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
  }
}
