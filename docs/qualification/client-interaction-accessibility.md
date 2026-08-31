# Client interaction and accessibility qualification

Issue [#568](https://github.com/unwired-dev/product/issues/568) closes the client-redesign
qualification with layered evidence. UI automation is reserved for rendered platform behavior;
deterministic state and persistence contracts remain in Swift Testing.

## Coverage

| Risk | Evidence |
| --- | --- |
| iPhone compact, regular-width iPad, and Mac Catalyst Settings presentation | `SettingsAccessibilityUITests.testNativePlatformHierarchyPassesAccessibilityAuditInEveryAppearance()` runs without a layout override and asserts the platform's native compact or split hierarchy. |
| System, Light, and Dark hierarchy | The native-platform test launches each device appearance, runs the XCTest accessibility audit, and retains both a screenshot and semantic hierarchy attachment. |
| VoiceOver descriptions, traits, contrast, text clipping, and 44-point hit regions | XCTest's full accessibility audit runs for every appearance. The existing semantic assertions continue to verify unavailable Settings destinations and their explanations. |
| Dynamic Type, long localized text, and test-mode animation suppression | `testNativePlatformHierarchyRemainsUsableWithAccessibilityTextAndAnimationsDisabled()` uses the accessibility-extra-extra-extra-large category, doubled localization, and a Debug-only launch environment that disables animations. It runs focused Dynamic Type, hit-region, description, and clipping audits and retains evidence. System Reduce Motion behavior remains outside this test's qualification scope. |
| Navigation, Threads, mail actions, empty/error states, and offline-safe interaction | The Core Mail Loop and message-content scenarios exercise the visible production client and independently verify server state. The Release fixture covers 250 local Threads and main-thread responsiveness. |
| Compact and regular composer presentation | Core Mail Loop XCUITests render compact reply and regular compose destinations, audit them, and retain screenshot plus hierarchy evidence. |
| Recipients, long subjects and Drafts, Markdown, slash commands, and Compose Assistance | `MailTestBootstrapUITests.testComposeAndSendThroughVisibleClient()` exercises touch and keyboard paths with twelve recipients, accessibility Dynamic Type, a growing Draft, atomic Markdown undo, slash-command filtering/selection/scrolling, and explicit Assistance dismissal. |
| Draft switching and failure recovery | `MailCompositionDraftTests` proves autosave-before-switch, editor-session restoration, stale revision replacement, conflict recovery, and failure-blocked switching at the deterministic Swift Testing layer. |

Snapshots are evidence for the accepted semantic and visual hierarchy, not pixel-perfect golden
files. Successful local result bundles can be inspected directly; failed CI runs retain their
XCTest result bundles for 14 days through the Core Mail Loop artifact policy.

The iOS 26 audit can report anonymous `SwiftUI.AccessibilityNode` findings for system-owned scroll
edges, plus Dynamic Type false positives for the Increased Contrast label and footer. Anonymous
contrast findings remain unhandled because XCTest does not expose a signature that distinguishes
system-owned scroll edges from app-owned nodes. The suite handles only the exact known text-clipping,
Dynamic Type, and native iPad `UISearchBarTextField` signatures. Other app-owned elements still fail
normally, while the separate
accessibility-XXXL launch verifies the appearance texts' scaling and the dedicated search test
verifies the system field remains operable.

## Cross-platform run

Use fresh task-owned Simulators and exact UDIDs for iPhone and iPad. Boot each device and wait for
`bootstatus` before invoking Xcode. Replace the placeholders below only with UDIDs created and
owned by the current run.

```sh
xcodebuild test \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail-mail-test \
  -destination 'platform=iOS Simulator,id=<iphone-udid>' \
  -parallel-testing-enabled NO \
  '-only-testing:unwired-mailMailTestUITests/SettingsAccessibilityUITests'
```

```sh
xcodebuild test \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail-mail-test \
  -destination 'platform=iOS Simulator,id=<ipad-udid>' \
  -parallel-testing-enabled NO \
  '-only-testing:unwired-mailMailTestUITests/SettingsAccessibilityUITests'
```

```sh
xcodebuild test \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail-mail-test \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -parallel-testing-enabled NO \
  '-only-testing:unwired-mailMailTestUITests/SettingsAccessibilityUITests'
```

The Catalyst UI-test runner requires a configured development team. Disabling code signing can
prove compilation, but an unsigned runner cannot launch the application for XCTest.

Run the complete affected portfolio after the cross-platform UI pass:

```sh
mise exec -- zsh scripts/check-apple-lint.zsh
mise exec -- pnpm mail:test run core-mail-loop --json
```

The repository's ordinary Debug suite and Release performance fixture remain required as defined
in `AGENTS.md` and `docs/agents/testing.md`.
