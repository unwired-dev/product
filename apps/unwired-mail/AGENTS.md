# Maintain the current Swift client

This directory contains the existing SwiftUI and Mac Catalyst prototype. These
instructions apply while it remains in use. The Expo and native React Native Mac
replacement follows [the root guide](../../AGENTS.md) and ADR 0059 through 0064.
Do not carry this SwiftUI architecture or its mail engines into the replacement.
Remove this guide when [cutover #627](https://github.com/unwired-dev/product/issues/627)
removes the prototype.

## Implementation

- Inspect the Xcode project's actual deployment targets and guard newer APIs.
  The replacement's version-27 floor does not change this project's targets.
- Use modern Swift concurrency and preserve strict actor isolation. Keep
  UI-owned observable state on the main actor, with explicit ownership.
- Follow existing feature boundaries and inject dependencies at native
  presentation boundaries. Preserve account and Mailbox Connection isolation.
- Prefer modern SwiftUI and Foundation APIs, semantic controls, adaptive layout,
  accessible names, and Dynamic Type. Verify platform-specific presentation on
  the actual target; Catalyst evidence does not qualify native React Native Mac.
- Keep secrets out of source control and retain device-local credential storage.
  Ask before adding third-party production dependencies unless already authorized.

## Skills and verification

Resolve relevant installed skills through the session catalogue. For SwiftUI
changes, use both `swiftui-design-principles` and `swiftui-pro`. Add concurrency,
API design, architecture, testing, background execution, or App Intents guidance
when that concern is part of the change. Use Liquid Glass guidance when changing
those APIs.

Use Swift Testing for unit and integration tests. Reserve XCTest for features
that require its APIs, such as UI automation. Follow the root
[test-admission policy](../../docs/agents/testing.md), including meaningful E2E
coverage; UI tests are not limited to cases where unit tests are impossible.

Follow [the Apple validation guide](../../docs/agents/apple-validation.md) for
strict formatting/linting, affected tests, Release performance, CI parity, and
owned Simulator/DerivedData cleanup. Report unavailable checks explicitly.
