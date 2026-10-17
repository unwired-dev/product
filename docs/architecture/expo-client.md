# Expo client: architecture notes

Reviewer-only companion to [docs/expo-client.md](../expo-client.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Stack and boundaries

- Router's explicitly accepted alpha `unstable-split-view` supplies native compact
  and regular layouts. Route parameters identify the selected message. The iPhone
  registration gate owns an outer `react-native-screens` native stack, retaining
  the split-view mail shell as its first screen and pushing Settings as the second.
  UIKit's dismissal event retires that Settings request. The mail shell and composer
  keep their route and mounted state beneath the push; iPad retains the two-column
  Settings workspace over its mounted shell.

- React Native `StyleSheet` and framework-independent light/dark tokens in
  `packages/mail-core`. System text, accessible buttons, selection state and
  focus borders form the initial UI; there is no additional component library.

- Effect from the shared catalog runs the Persistent Inbox and Registration stores,
  following the [Effect conventions](../agents/effect.md). React owns presentation
  state. Opening a message does not mutate mailbox read state.

Catalogs centralize versions; bundle checks
and native autolinking still have to establish each host's renderer boundary.

The design config plugin compiles the first-party views in `native/design` into
the app target. Each host wraps the shared SF Symbol and Liquid Glass view
managers through Fabric's legacy-view interop, without adding an autolinked
dependency. Native visual, Dynamic Type and accessibility qualification remains
required; JavaScript tests and bundle checks do not establish that evidence.

## Native E2E in CI

The original 15-minute limit interrupted a hosted run after iPhone passed but
before iPad produced a test result.
