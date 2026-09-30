# Expo client and mock Inbox

`apps/mobile` implements [#592](https://github.com/unwired-dev/product/issues/592):
a deterministic Inbox and message detail for iPhone and iPad. It uses synthetic
messages with [native encrypted read-state persistence](private-inbox-storage.md);
production builds now use [Google Product Sign-In and Gmail consent](google-registration.md).
Mailbox synchronization and sending are later slices. The existing Convex backend
and Swift prototype remain available. The [native Mac host](macos-client.md) consumes the same mock mailbox.

Production launches now use [Google registration and separate Gmail consent](google-registration.md).
Configure the native client ID and Convex deployment when generating the host.
Select an explicit Mock Mail Session to run the synthetic Inbox journeys.

## Stack and boundaries

- Expo 57.0.26, React Native 0.86.3, React 19.2.3, and Expo Router 57.0.24.
- Router's explicitly accepted alpha `unstable-split-view` supplies native compact
  and regular layouts. Route parameters identify the selected message.
- React Native `StyleSheet` and framework-independent light/dark tokens in
  `packages/mail-core`. System text, accessible buttons, selection state and
  focus borders form the initial UI; there is no additional component library.
- Effect 4.0.0-rc.118 owns the mock mailbox service and application effects.
  React owns presentation state. An application-scoped `ManagedRuntime` owns
  persistent Inbox operations; opening a message does not mutate mailbox read state.
- TypeScript 7.0.2, `@effect/tsgo` 0.46.1, Oxlint 1.85.0 and Oxfmt 0.71.0.
  Install runs `effect-tsgo patch --oxlint` once at the workspace root. Every
  TypeScript config includes the `@effect/language-service` plugin configuration;
  its diagnostics run once through Oxlint. Effect correctness rules apply
  throughout; recommended rules apply to the mobile app and shared mailbox implementation.
- Vitest tests the shared core; Jest Expo and React Native Testing Library test
  message selection and unavailable routes. Fallow scans the root and mobile entry points separately.

One root `pnpm-workspace.yaml` and lockfile manage all packages under
[ADR 0064](adr/0064-isolate-mobile-and-macos-native-dependencies.md). Shared tooling
and Effect use the default catalog; mobile renderer, Expo and test packages use
`catalog:mobile`. The app consumes `mail-core` through `workspace:*`, so source
edits are immediately available without reinstalling. Keep React and native
imports out of that shared package. Catalogs centralize versions; bundle checks
and native autolinking still have to establish each host's renderer boundary.

### Effect setup and imports

Effect is also a root development dependency, making `node_modules/effect/AGENTS.md`
and `node_modules/effect/src` available to agents. Read the installed guide before
writing Effect code, as directed by the upstream
[Effect setup skill](https://github.com/Effect-TS/skills/blob/main/skills/effect-ts/SKILL.md).
The skill was applied once for setup, without installing it into the repository.

Use namespace imports from Effect module subpaths:

```ts
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
```

All host and root Oxlint configurations enforce `effect-imports/namespace-imports` for
`effect/*` and `@effect/*`. Named, default, side-effect and root `effect` barrel
imports fail lint, including named type imports. Namespace type imports are
allowed. The TypeScript Effect plugin also suggests namespace imports for the
installed Effect packages; Oxlint is the enforcement layer. Run
`pnpm test:tooling` from the root to check both configurations against accepted
and rejected import forms.

### Compatibility pins

Dependencies were refreshed on 2026-09-29. Native packages follow Expo 57's exact
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
mise exec -- pnpm install --frozen-lockfile --strict-peer-dependencies
cd apps/mobile
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

For automated native checks, follow the [Simulator ownership policy](agents/native-validation.md):
create fresh task-owned devices, use their UDIDs, isolate DerivedData and result
paths, and shut down/delete only those devices in a failure-safe cleanup trap.

## Validate

All workspace checks, including the locally retained legacy harness, run from the root:

```sh
mise exec -- pnpm turbo run lint format check-types test
mise exec -- pnpm fallow
mise exec -- pnpm test:tooling
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
The primary CI job runs lint, formatting, types and tests for mobile, core,
contracts and the retained Convex backend, plus the Effect import-policy tests.
The Mobile workflow checks Fallow, Expo compatibility and the production bundle.
Its `Expo native E2E` job also builds the Release app and runs the iPhone/iPad
interaction journey on pull requests ready for review and pushes to `main`.
Legacy Swift CI and manual qualification jobs are disabled by maintainer decision.

A focused native XCTest journey is also available through the
[isolated Mock Mail Session runner](mock-mail-sessions.md). Select
`UNWIRED_MOCK_SCENARIO=open-read-relaunch` when generating the native project
before building the app. Ordinary preview builds are rejected by this runner. First build a simulator Release
app using isolated DerivedData (from `apps/mobile`, after native generation):

```sh
xcodebuild build -workspace ios/UnwiredMailPreview.xcworkspace \
  -scheme UnwiredMailPreview -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/expo-bootstrap/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
mise exec -- pnpm test:native ../../artifacts/expo-bootstrap/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMailPreview.app
```

The runner requires Ruby with CocoaPods' `xcodeproj` gem (`RUBY` may select that
Ruby executable) and the iOS 27 runtime. It creates and cleans up its own
iPhone 18 Pro and iPad Pro 11-inch M5 simulators and keeps logs and xcresults
under `artifacts/expo-bootstrap/`. A testmanagerd socket/CoreSimulator disconnect
or zero-test success triggers one retry on a fresh owned device; assertion
failures fail immediately. The root `pnpm test:native-runner` command exercises
these retry and cleanup paths with stub tools (requires zsh). It verifies packaged launch, selecting and
replacing a message, and compact back navigation. It does not claim keyboard,
VoiceOver, resize or physical-device qualification. Native E2E runs in a separate job from the Linux bundle check; see
[recorded evidence](qualification/expo-react-native-client.md).

The three component tests cover selecting a message, replacing the selected
message and rejecting an unknown identifier. The shared service tests cover
lookup failure and the invariant that opening a message leaves read state alone.
Read-state changes and storage recovery have additional shared and component
coverage. The [private storage checks](private-inbox-storage.md#verification)
exercise real encryption and credentials separately. Real provider, authentication,
delivery and production observability belong to their approved follow-up slices.

### Native E2E in CI

The [Mobile workflow](../.github/workflows/mobile.yml) uses GitHub's arm64
[`xcode-27` image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
with Xcode 27.0 selected explicitly and the iOS 27.0 simulator runtime. It performs
a frozen root installation, generates the iOS project, installs Pods, builds an
ad-hoc signed arm64 simulator Release app with packaged JavaScript, and passes that
app to the same `pnpm test:native` runner used locally. No signing credentials,
provider accounts or running Metro server are required.

The job verifies the runner's failure handling before native execution. Assertion
failures fail immediately, zero selected tests never pass, and only recognized
infrastructure failures or zero-test success receive one fresh-device retry.
Its 45-minute timeout includes installation and the native build; the interaction
step has a separate 25-minute limit for harness compilation, two sequential
simulator startups and both journeys, including the bounded infrastructure retry.
The original 15-minute limit interrupted a hosted run after iPhone passed but
before iPad produced a test result. Superseded pull-request runs are cancelled.
Build logs and XCTest result bundles, including screenshots, are uploaded as
`expo-native-e2e-<run id>-<attempt>` with seven-day retention, including on failure. The job selects the test-only `open-read-relaunch` scenario
and uploads run ownership, simulator IDs and exit results as well.

The `Expo native E2E` check covers the mock Inbox on iPhone and iPad. It does not
qualify the separate native Mac host or real provider integration. Repository
branch protection must select this check separately if it should block merging.
