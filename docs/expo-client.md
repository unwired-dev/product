# Expo mock Inbox

`apps/mobile` implements [#592](https://github.com/unwired-dev/product/issues/592):
a deterministic Inbox and message detail for iPhone and iPad. It uses synthetic
in-memory messages; it has no sign-in, provider connection, persistence, sending,
or Convex client integration. The existing Convex backend and Swift prototype
remain available. Native Mac is a separate implementation ticket.

## Stack and boundaries

- Expo 57.0.25, React Native 0.86.3, React 19.2.3, and Expo Router 57.0.23.
- Router's explicitly accepted alpha `unstable-split-view` supplies native compact
  and regular layouts. Route parameters identify the selected message.
- React Native `StyleSheet` and framework-independent light/dark tokens in
  `packages/mail-core`. System text, accessible buttons, selection state and
  focus borders form the initial UI; there is no additional component library.
- Effect 4.0.0-rc.118 owns the mock mailbox service and application effects.
  React owns presentation state. A mounted provider owns and disposes its
  `ManagedRuntime`; opening a message does not mutate mailbox read state.
- TypeScript 7.0.2, `@effect/tsgo` 0.46.1, Oxlint 1.85.0 and Oxfmt 0.71.0.
  Install runs `effect-tsgo patch --oxlint` in both dependency roots. Every
  TypeScript config includes the `@effect/language-service` plugin configuration;
  its diagnostics run once through Oxlint. Effect correctness rules apply
  throughout; recommended rules also apply to the shared mailbox implementation.
- Vitest tests the shared core; Jest Expo and React Native Testing Library test
  message selection and unavailable routes. Fallow scans each installation.

Mobile has its own package manifest, `pnpm-workspace.yaml`, `node_modules`, and
lockfile under [ADR 0064](adr/0064-isolate-mobile-and-macos-native-dependencies.md).
It consumes `mail-core` with a local `file:` dependency. Keep React and native
imports out of that shared package. After changing shared source, rerun the
mobile install to refresh pnpm's installed copy before testing or bundling.

### Compatibility pins

Dependencies were refreshed on 2026-09-28. Native packages follow Expo 57's exact
compatibility map, rather than independently upgrading the renderer or native
peers. Keep React 19.2.3 paired with React Native 0.86.3. Router's transitive
native peers (gesture handler, Reanimated and Worklets) are explicitly installed
for reproducible autolinking. `react-dom` is a development peer requirement and
must not appear in the iOS production bundle.

Oxlint 1.85.0 is the newest version supported by this Effect patcher; update
`@effect/tsgo`, Oxlint and `oxlint-tsgolint` together. TypeScript 7 is intentionally
excluded from `expo install --check` because Expo recommends TypeScript 6 while
the selected Effect tooling patches TypeScript 7. Jest remains on 29 for
`jest-expo`'s watch plugin. Testing Library's `test-renderer` is pinned to 1.2.0;
1.3 requires a newer React renderer. Node stays on the project's Node 24 line,
and pnpm remains exactly 11.5.2.

## Install and run

From the repository root, activate the [mise toolchain](../README.md#local-development):

```sh
mise exec -- pnpm install --frozen-lockfile
cd apps/mobile
mise exec -- pnpm install --frozen-lockfile --strict-peer-dependencies
mise exec -- pnpm ios --device
```

Use Xcode 27, an iOS 27 simulator runtime, and CocoaPods. `pnpm ios` generates and
builds the development client and starts Metro; subsequent JavaScript work can
use `pnpm dev`. These commands use a development build, not Expo Go.

Native projects are generated and ignored. Regenerate with `pnpm native:generate`
after changing native dependencies or app configuration. Keep native changes in
config plugins. The app sets deployment target 27.0 and
[`enableSceneSupport: true`](https://docs.expo.dev/versions/latest/sdk/build-properties/#pluginconfigtypeios):
apps built with the iOS 27 SDK cannot launch with the old application lifecycle.

For a packaged Release build with no running Metro server:

```sh
cd apps/mobile
mise exec -- pnpm ios --configuration Release --device
```

For automated native checks, follow the [Simulator ownership policy](agents/apple-validation.md):
create fresh task-owned devices, use their UDIDs, isolate DerivedData and result
paths, and shut down/delete only those devices in a failure-safe cleanup trap.

## Validate

Shared code and backend checks run from the repository root:

```sh
mise exec -- pnpm turbo run lint format check-types test
mise exec -- pnpm fallow
```

Run mobile checks from `apps/mobile`:

```sh
mise exec -- pnpm lint
mise exec -- pnpm format
mise exec -- pnpm check-types
mise exec -- pnpm test
mise exec -- pnpm fallow
mise exec -- pnpm exec expo install --check
mise exec -- pnpm build
mise exec -- pnpm verify:bundle
```

`build` exports production Hermes bytecode and source maps. `verify:bundle`
checks the mobile React/native versions, shared mailbox source, Effect and native
split view, and rejects the Mac renderer graph, React DOM and backend sources.
This is bundle evidence, not a substitute for a native build or interaction test.
The Mobile CI workflow runs these checks independently of the existing Swift CI.

A focused native XCTest journey is also available. First build a simulator Release
app using isolated DerivedData (from `apps/mobile`, after native generation):

```sh
xcodebuild build -workspace ios/UnwiredMailPreview.xcworkspace \
  -scheme UnwiredMailPreview -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/expo-bootstrap/DerivedData CODE_SIGNING_ALLOWED=NO
pnpm test:native ../../artifacts/expo-bootstrap/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMailPreview.app
```

The runner requires Ruby with CocoaPods' `xcodeproj` gem (`RUBY` may select that
Ruby executable), `rg`, and the iOS 27 runtime. It creates and cleans up its own
iPhone 18 Pro and iPad Pro 11-inch M5 simulators and keeps logs and xcresults
under `artifacts/expo-bootstrap/`. It verifies packaged launch, selecting and
replacing a message, and compact back navigation. It does not claim keyboard,
VoiceOver, resize or physical-device qualification. Native CI remains separate
from the Linux bundle job; see [recorded evidence](qualification/expo-react-native-client.md).

The three component tests cover selecting a message, replacing the selected
message and rejecting an unknown identifier. The shared service tests cover
lookup failure and the invariant that opening a message leaves read state alone.
Real provider, encrypted persistence, authentication, delivery, production
observability and device automation belong to their approved follow-up slices.
