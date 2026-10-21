# Expo client: architecture notes

Reviewer-only companion to [docs/expo-client.md](../expo-client.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Stack and boundaries

Apply the [native component selection policy](../agents/native-components.md)
to new UI and migrations. The custom views and navigation wiring described below
record the current implementation, not requirements to retain them.

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
the app target. Both hosts wrap the shared SF Symbol view manager through
Fabric's legacy-view interop. Mobile Liquid Glass uses `expo-glass-effect`;
the Mac retains its AppKit glass view manager without importing Expo. Native
visual, Dynamic Type and accessibility qualification remains required;
JavaScript tests and bundle checks do not establish that evidence.

The pinned `expo-glass-effect@57.0.4` patch keeps its internal effect/content views
from claiming empty-space hits. React Native can then apply `pointerEvents` to
the enclosing Expo view, so the reader's `box-none` toolbar padding reaches the
menu dismissal beneath while control children stay inside interactive glass.
Remove the patch when the supported upstream version preserves that hit-testing
contract. A JavaScript component mock cannot validate this native behavior.

## Native E2E in CI

The original 15-minute limit interrupted a hosted run after iPhone passed but
before iPad produced a test result.
