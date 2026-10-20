# Expo client and mock Inbox

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/expo-client.md).

`apps/mobile` implements [#592](https://github.com/unwired-dev/product/issues/592):
a deterministic Inbox and message detail for iPhone and iPad. The shell is a native
split view: a Mailboxes sidebar column (**All inboxes**, each Mailbox Connection with
its Inbox and IMAP folders, and **Account**), the message list with a floating
**Filter**, search and **New Message** bar, which rises above the software keyboard while its
search field is in use, and the reader. Search opens a search mode with **Close Search**
and a scope choice, and Filter narrows the Inbox
([search and filters](gmail-inbox.md#searching-saved-mail)). On iPhone the columns collapse into
one navigation stack that opens on the Inbox, with Mailboxes one Back away. It uses synthetic
messages with [native encrypted read-state persistence](private-inbox-storage.md);
production builds now offer [Apple](apple-registration.md) and [Google](google-registration.md)
Product Sign-In, each followed by a choice of Gmail, [Microsoft mail](microsoft-mail.md) when configured for this build, or an [IMAP mailbox](imap-mailboxes.md).
Production mailboxes use [Gmail synchronization](gmail-inbox.md), the
[Microsoft Inbox](microsoft-mail.md) or
[IMAP synchronization](imap-mailboxes.md#synchronization); Gmail, Microsoft and IMAP
connections send. The existing Convex backend
and Swift prototype remain available. The [native Mac host](macos-client.md) consumes the same mock mailbox.

Production launches offer [Apple](apple-registration.md) or [Google](google-registration.md)
registration; the first mailbox is chosen separately: Gmail, [Microsoft mail](microsoft-mail.md) when configured for this build, or an IMAP login. Either sign-in can later be [linked](linked-sign-in.md)
as the other sign-in method. A new account [initializes Private Sync](private-product-sync.md):
the device that wins initialization presents the Recovery Key. Another device of
that account shows a code and [waits for a Trusted Device to approve it](private-product-sync.md#approving-a-new-device), or [unlocks with the Recovery Key](private-product-sync.md#recovering-with-the-recovery-key). Configure the native client IDs and Convex deployment when generating the host.
Select an explicit Mock Mail Session to run the synthetic Inbox journeys.

## Dependencies and coding rules

- Mobile framework and test versions belong to `catalogs.mobile` in
  [`pnpm-workspace.yaml`](../pnpm-workspace.yaml). Shared tooling uses the default catalog.
- Route parameters identify the selected message.
- The message reader's Copy link action uses `expo-clipboard`, with the native
  module included in the reviewed Expo autolinking scope. Regenerate and rebuild
  development clients after adding or updating it.
- Follow [native component selection](agents/native-components.md) for controls,
  navigation and presentation. Use provided React Native and Expo components
  before custom equivalents. Compose mail content with React Native `StyleSheet`
  and framework-independent light/dark tokens in `packages/mail-core`; preserve
  accessible names, selection state and keyboard focus.
- Follow the [Effect conventions](agents/effect.md) with the catalog-pinned version.
  React owns presentation state. Opening a message does not mutate mailbox read state.
- TypeScript, the Effect patcher, Oxlint and Oxfmt versions belong to the shared catalog.
  Install runs `effect-tsgo patch --oxlint` once at the workspace root. Every
  TypeScript config includes the `@effect/language-service` plugin configuration;
  its diagnostics run once through Oxlint. The shared
  [Effect lint policy](agents/effect.md#enforcement) applies to every configuration.
- Vitest tests the shared core; Jest Expo and React Native Testing Library test
  message selection and unavailable routes. Their animation resolver uses the
  Reanimated and Worklets JavaScript implementations; native motion still needs
  device qualification. Fallow scans the root and mobile entry points separately.

One root `pnpm-workspace.yaml` and lockfile manage all packages under
[ADR 0064](adr/0064-isolate-mobile-and-macos-native-dependencies.md). Shared tooling
and Effect use the default catalog; mobile renderer, Expo and test packages use
`catalog:mobile`. The app consumes `mail-core` through `workspace:*`, so source
edits are immediately available without reinstalling. Keep React and native
imports out of that shared package. Run bundle and native autolinking checks for each host.

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
`pnpm test:tooling` from the root to check every configuration against accepted
and rejected import forms and the [boundary rules](agents/effect.md#enforcement).

### Compatibility pins

Native packages follow the selected Expo version's exact
compatibility map, rather than independently upgrading the renderer or native
peers. Keep the mobile Babel preset within the selected Expo package's declared
dependency range; [`catalogs.mobile`](../pnpm-workspace.yaml) holds both pins.
Keep React paired with the selected React Native renderer. Router's transitive
native peers (gesture handler, Reanimated and Worklets) are explicitly installed
for reproducible autolinking. `react-dom` is a development peer requirement and
must not appear in the iOS production bundle.

Keep the Effect patcher, Oxlint and `oxlint-tsgolint` on the compatible catalog
versions and update them together. TypeScript 7 is intentionally
excluded from `expo install --check` because Expo recommends TypeScript 6 while
the selected Effect tooling patches TypeScript 7. Jest remains on 29 for
`jest-expo`'s watch plugin. Testing Library's `test-renderer` is pinned to 1.2.0;
1.3 requires a newer React renderer. Node and pnpm versions belong to
[the root toolchain](../README.md#local-development).

## Install and run

From the repository root, activate the [mise toolchain](../README.md#local-development):

```sh
mise exec -- pnpm install --frozen-lockfile --strict-peer-dependencies
cd apps/mobile
mise exec -- pnpm ios --device
```

Use Xcode 27, an iOS 27 simulator runtime, and CocoaPods. `pnpm ios` generates and
builds the development client and starts Metro; subsequent JavaScript work can
use `pnpm dev`. These commands use a development build, not Expo Go. From the
repository root, `mise exec -- pnpm ios --device` and `mise exec -- pnpm dev:ios` run the same commands
through Turborepo. `pnpm ios` loads the root `.env.local` if it exists; set
`UNWIRED_DEVELOPMENT_TEAM="<your team ID>"` there so Expo signs with that team
instead of asking which keychain identity to use. The Sign in with Apple
entitlement makes even simulator builds sign.

If `apps/mobile/ios` already exists, apply the team before the next build. From
`apps/mobile`, run
`UNWIRED_DEVELOPMENT_TEAM="<your team ID>" mise exec -- pnpm native:generate`.
This command takes the team from the environment; it does not load the root
`.env.local`. `pnpm ios` reuses an existing native project and its signing team.

Native projects are generated and ignored. Regenerate with `pnpm native:generate`
after changing native dependencies or app configuration. Keep native changes in
config plugins. The design plugin compiles `native/design`, the SF Symbol and
Liquid Glass views the Mac host shares. The bundle ID is `dev.unwired.mail`, the version comes from
`apps/mobile/package.json`, and the icon is the Icon Composer document in
`native/app-icon/UnwiredMail.icon`. The app sets deployment target 27.0 and
[`enableSceneSupport: true`](https://docs.expo.dev/versions/latest/sdk/build-properties/#pluginconfigtypeios):
apps built with the iOS 27 SDK cannot launch with the old application lifecycle.
The `expo-background-task` and `expo-task-manager` plugins add the `fetch` and
`processing` background modes and the scheduler identifier for
[Gmail freshness](gmail-inbox.md#freshness-across-app-lifecycles). The app adds the
`remote-notification` mode and the `aps-environment` entitlement for
[push wake routes](gmail-inbox.md#push-wake-routes); distribution signing selects
production APNs. The private-inbox config plugin registers for remote notifications
at launch and hands token and wakes to native code. The app identifier's Push
Notifications capability must be enabled for signed builds.
Simulators report background tasks as restricted, so the app registers none there.
The app entry defines the Gmail task before Router starts, including launches
that mount no screens. A failed background-task registration logs a fixed
diagnostic and leaves foreground catch-up available.

For a packaged Release build with no running Metro server:

```sh
cd apps/mobile
mise exec -- pnpm ios --configuration Release --device
```

For automated native checks, follow the [Simulator ownership policy](agents/native-validation.md):
create fresh task-owned devices, use their UDIDs, isolate DerivedData and result
paths, and shut down/delete only those devices in a failure-safe cleanup trap.

## Validate

Run the relevant [shared validation commands](../README.md#validation) from the
root, including the pinned Fallow audit when required. The root diagnostic scan
does not substitute for that gate. Run the additional mobile checks from `apps/mobile`:

```sh
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
It then requires Expo's native autolinking result to match the allowed Expo and
React Native modules exactly. Adding a native module requires an explicit update to
`scripts/verify-native.ts`. This is bundle and autolinking evidence, not a substitute for a native build or interaction test.
The primary CI job lints and formats the whole repository from the root, and
runs types and tests for mobile, core, contracts and the retained Convex backend,
plus the Effect import-policy tests. Formatting skips `AGENTS.md` files, whose
managed blocks agent tools rewrite, and the generated Icon Composer `icon.json`.
The Mobile workflow checks Fallow, Expo compatibility and the production bundle.
Its native jobs also build the Release app once and run the iPhone and iPad
interaction journeys in parallel `Expo native E2E` jobs on pull requests ready
for review and pushes to `main`.
Legacy Swift CI and manual qualification jobs are disabled by maintainer decision.

A focused native XCTest journey is also available through the
[isolated Mock Mail Session runner](mock-mail-sessions.md). Select
`UNWIRED_MOCK_SCENARIO=open-read-relaunch` when generating the native project
before building the app. Ordinary builds are rejected by this runner. First build a simulator Release
app using isolated DerivedData (from `apps/mobile`, after native generation):

```sh
xcodebuild build -workspace ios/UnwiredMail.xcworkspace \
  -scheme UnwiredMail -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/expo-bootstrap/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
mise exec -- pnpm test:native ../../artifacts/expo-bootstrap/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMail.app
```

The runner requires Ruby with CocoaPods' `xcodeproj` gem (`RUBY` may select that
Ruby executable) and the iOS 27 runtime. It creates and cleans up its own
iPhone 18 Pro and iPad Pro 11-inch M5 simulators and keeps logs and xcresults
under `artifacts/expo-bootstrap/`. Simulator device type identifiers after the
app path limit the run to those devices; without them both devices run in turn. A testmanagerd socket/CoreSimulator disconnect
or zero-test success triggers one retry on a fresh owned device; assertion
failures fail immediately. The root `pnpm test:native-runner` command exercises
these retry and cleanup paths with stub tools (requires zsh). The native runner uses Dark appearance by default;
`UNWIRED_APPEARANCE=light` repeats the journey in Light. In Dark, the bottom-edge pixel comparison verifies that the iPhone Inbox
surface reaches the screen edge after scrolling to the list's end and after leaving the reader. In Light, the window matches the surface,
so that comparison cannot detect a surface that stops short. Both appearances verify packaged launch, scrolling the list's end clear of the floating bar, reader return, the floating search field
staying above the software keyboard, a search result under Top Results and Close Search, selecting and replacing a message, and compact
back navigation. It does not claim hardware keyboard,
VoiceOver, resize or physical-device qualification. Native E2E runs in separate jobs from the Linux bundle check; see
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
with Xcode 27.0 selected explicitly and the iOS 27.0 simulator runtime. The
native work is split into jobs that run side by side so that simulator startup,
which dominates the duration, is not paid serially:

- `Expo native build` performs a frozen root installation, generates the iOS
  project with the test-only `open-read-relaunch` scenario, installs Pods, builds
  an ad-hoc signed arm64 simulator Release app with packaged JavaScript and
  uploads it as a tar archive (`expo-native-app-<run id>`).
- `Expo native E2E (iPhone)` and `Expo native E2E (iPad)` start when the build
  finishes. Each downloads that app and passes it with one simulator device type
  to the same `test-native.zsh` runner used locally by `pnpm test:native`. These
  jobs need no JavaScript installation.
- `Expo native storage checks` runs the runner's failure-handling contract, the
  [private storage checks](private-inbox-storage.md#verification) and ordinary
  project generation with a cleared scenario, independently of the build.

No signing credentials, provider accounts or running Metro server are required.

Assertion failures fail immediately, zero selected tests never pass, and only
recognized infrastructure failures or zero-test success receive one fresh-device
retry. The build and journey jobs each have a 25-minute timeout; the interaction
step has a separate 18-minute limit for harness compilation, one simulator startup
and its journey, including the bounded infrastructure retry. The storage job has
a 34-minute timeout; its native integration step has a 26-minute limit, including
the bounded infrastructure retry and cleanup. Superseded pull-request runs are cancelled.
Logs and XCTest result bundles, including screenshots, run ownership, simulator
IDs and exit results, are uploaded with seven-day retention, including on failure,
as `expo-native-e2e-<device>-<run id>-<attempt>`,
`expo-native-build-<run id>-<attempt>` and `expo-native-checks-<run id>-<attempt>`.
Re-running a failed journey job reuses the app from the original build while that
artifact is retained.

The `Expo native E2E (iPhone)` and `Expo native E2E (iPad)` checks cover the mock
Inbox. They do not qualify the separate native Mac host or real provider
integration. Repository branch protection must select both journey checks,
`Expo native build` and `Expo native storage checks` separately if they should
block merging. A failed build skips the journey jobs, and GitHub accepts skipped
required checks, so requiring only the journeys would not enforce a successful
build.

## Interface language

The Inbox, the welcome page and Settings' **Language** offer System default and a saved English
override. See
[interface translations](localization.md) for catalogs, adding languages, native
menu behavior, and language verification.
