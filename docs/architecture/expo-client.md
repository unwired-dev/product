# Expo client: architecture notes

Reviewer-only companion to [docs/expo-client.md](../expo-client.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Stack and boundaries

- iPad retains Router's explicitly accepted alpha `unstable-split-view` for
  native compact and regular layouts. Route parameters identify the selected
  message. On iPhone, `MailNavigation` uses `react-native-screens` with retained
  Mailboxes and Inbox screens, then one keyed native screen per routed reader
  descriptor.
  Native dismissal invokes that destination's existing Back action to reconcile
  route history. Compose prevents native dismissal and delegates the attempted
  Back to its guarded Close action before removing its screen.
  The iPhone registration gate contains that mail stack as the real root of a
  second native stack, with Settings above it. Settings retains its destination
  list below its detail in a nested native stack; its Back button and completed
  native pop both clear the destination. iPad retains the two-column Settings
  workspace over its mounted split-view shell.
  Explicit Open Inbox publishes an ephemeral Product-Account-scoped reveal request
  through the Account context. A leaf below the current Profile consumes it and
  selects the retained list or active detail without rendering the split owner;
  the installed split view recreates its Slot wrapper when rendered. Native Back
  only dismisses Settings, and leaving the connected account retires the request.

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
