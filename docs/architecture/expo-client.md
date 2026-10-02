# Expo client: architecture notes

Reviewer-only companion to [docs/expo-client.md](../expo-client.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Stack and boundaries

- Router's explicitly accepted alpha `unstable-split-view` supplies native compact
  and regular layouts. Route parameters identify the selected message.

- React Native `StyleSheet` and framework-independent light/dark tokens in
  `packages/mail-core`. System text, accessible buttons, selection state and
  focus borders form the initial UI; there is no additional component library.

- Effect 4.0.0-rc.118 runs the shared Persistent Inbox and Registration stores,
  following the [Effect conventions](../agents/effect.md). React owns presentation
  state. Opening a message does not mutate mailbox read state.

Catalogs centralize versions; bundle checks
and native autolinking still have to establish each host's renderer boundary.

## Native E2E in CI

The original 15-minute limit interrupted a hosted run after iPhone passed but
before iPad produced a test result.
