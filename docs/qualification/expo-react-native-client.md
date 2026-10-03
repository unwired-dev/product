# Expo and React Native platform qualification

Evidence updated: 2026-10-03. Status: **Expo bootstrap builds and launches on
iOS/iPadOS 27 and the native Mac mock Inbox builds and launches on macOS 27;
full replacement qualification remains incomplete**.

The [mobile bootstrap](../expo-client.md) now uses Expo 57.0.25, React Native
0.86.3 and React 19.2.3 with Effect 4.0.0-rc.118. Xcode 27 and the iOS 27 runtime
are available on the development host. The maintainer's earlier native-validation
deferral still applies to unavailable release checks. Mac host evidence follows.

## Trusted-device enrollment evidence, 2026-10-03

[#600](https://github.com/unwired-dev/product/issues/600) adds
[trusted-device approval](../private-product-sync.md#approving-a-new-device).

Implementation evidence before review:

- Eighteen app-hosted tests passed on a fresh owned iOS 27 Simulator with real
  Keychain and CryptoKit. The new journey uses two separate Keychain installations,
  real HPKE and encrypted mailbox records with a controlled backend. It covers
  rejection and renewal, adoption of the existing ring without a Recovery Key,
  descriptors before Gmail consent and unchanged account material.
- The `registration-enrollment` Release simulator build compiled the real bridge,
  and the packaged journey passed on fresh iPhone 18 Pro and iPad Pro 11-inch
  iOS 27 Simulators. A synthetic trusted device reads the code from the run's
  Keychain in place of a person entering it on a second installation. This is
  deterministic mock evidence, not approval between two real devices.
- Workspace lint, format, types and tests, tooling and native-runner contracts
  passed. Evidence remains local under `artifacts/private-inbox/integration.IdWb9M`
  and `artifacts/expo-bootstrap/native-1Xn2g0`.

Review changed the Enrollment Code from 75 bits to 275 bits of entropy to meet
HPKE's PSK requirement, made expiry checks uncached server operations and added
collection-time approver/epoch fencing. Regression tests first reproduced four
invalid-collection cases and cross-account leakage in the shared mock transport,
then passed after fixes. Native checksum tests now alter the check digit so their
negative cases cannot randomly retain a valid checksum.

The review's native interaction rerun could not create a Simulator because the
session denied CoreSimulator service and log access. Earlier native results do
not qualify the corrected code length or bridge endpoint type; those interaction
checks remain required. Review verification:

- All 24 root workspace lint, format, type and test tasks passed. Convex has
  236 passing tests, mail-core 29, mobile 14 and Mac 12. Existing contracts and
  legacy harness coverage also passed and remains intact.
- Both normal production JavaScript builds and renderer/bundle boundary checks
  passed, as did Fallow's changed-code gate, all nine tooling tests, Swift
  formatting and affected documentation links.
- The two crypto-only SwiftPM tests passed with real CryptoKit on macOS. The
  Swift library and synthetic native backend type-checked against the iOS 27
  Simulator SDK. This establishes
  the corrected code format and cryptographic bindings, not Keychain behavior.
- Native-runner contracts passed 19 of 20 tests. The remaining cleanup-helper
  test could not create its disposable directory under the host Application
  Support folder in this session, so the full command did not pass.
- Selected native project generation and CocoaPods installation passed using a
  task-local `CP_CACHE_DIR`. The packaged build stopped before compilation when
  Xcode could not recognize the workspace in this restricted session, alongside
  CoreSimulator and file-event service failures. No corrected packaged build or
  native interaction pass is claimed.
- Additional strict SwiftLint on the four affected core/bridge/test files still
  reports five violations also present in the starting commit: the older seal's
  parameter count, bridge file/store size and two older Data-to-String conversions.
  This is separate from the passing maintained workspace lint lane.

Review logs and the unavailable packaged-build result are retained locally in
`artifacts/private-inbox/enrollment-review.EONAFv`. Task-owned probes, compiler and
CocoaPods caches were removed after verification.

Real Convex/JWT and protected Gmail two-device qualification, signed Mac
Keychain/E2E without matching disposable-app profiles, and physical-device checks
remain deferred before release. No legacy coverage is retired by this slice.

## Private Product Sync evidence, 2026-10-01

[#599](https://github.com/unwired-dev/product/issues/599) adds
[Product Sync initialization and the Recovery Key](../private-product-sync.md)
on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed, including
  221 Convex tests. Fallow audit passed on the changed files. Convex covers single
  initialization, idempotent retry, refusal for already initialized accounts, and
  epoch and device-proof enforcement. Shared and rendered host tests cover Recovery
  Key confirmation, mismatch, remount and the enrollment-needed state.
- Seventeen app-hosted native tests passed on an owned iOS 27 Simulator with real
  Keychain and CryptoKit. They cover nonce freshness and tamper, account,
  identifier, schema and epoch rejection. They also cover recovery and enrollment
  envelope binding, one-time initialization, the encrypted descriptor round trip
  and relaunch without new keys. Interrupted publication and the losing device's
  enrollment state are covered too, as are a receipt without Product Sync state and
  an Apple relaunch. That relaunch shows the last decrypted mailbox list and saves a
  new mailbox only after signing in again. Convex and the providers are controlled
  boundaries here.
- The `registration-declined` and `registration-link` packaged journeys passed on
  fresh iPhone 18 Pro and iPad Pro 11-inch M5 iOS 27 Simulators from Release
  simulator builds. The Google journey keeps the same Recovery Key across relaunch
  and confirms it. After another relaunch it reads back the decrypted mailbox list.
- Paginated native record reads compile in CI's packaged build; no local journey
  exercises more than 100 records.
- The Mac `Testing` build with `registration-declined` compiled and passed its
  bundle check with ad-hoc signing. The cleanup helper type-checks. Native runner
  contracts (20 tests) passed.

Native Mac E2E, real Convex Product Sync and providers, and the deployment's JWT
gateway remain deferred. So do signed Mac Keychain behavior and physical devices.
The [protected qualification path](../private-product-sync.md#protected-real-qualification)
has not run. No installed Mac profile covers the disposable `dev.unwired.mock.*`
IDs. Uncommitted local evidence stays on the development host in the git-ignored
`artifacts/expo-bootstrap/native-VdNwBS`, `artifacts/expo-bootstrap/native-5QUCAH` and
`artifacts/private-inbox/integration.nBHQeR` directories.

## Linked sign-in evidence, 2026-10-01

[#598](https://github.com/unwired-dev/product/issues/598) adds
[explicit Google and Apple linking](../linked-sign-in.md) on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed, as did
  Fallow audit on the changed files. Convex integration covers alternate sign-in
  from a second installation and same-email non-linking. It also covers owned
  identities, superseded tickets and stale tokens on either side. Expired,
  wrong-provider and wrong-device tickets are rejected, a lost completion can be
  retried and deletion tombstones both identities. Shared and rendered host tests
  cover linking from account settings, remount and link failures.
- Eleven app-hosted native tests passed on an owned iOS 27 Simulator with real
  Keychain. Two new scenarios cover interactive reverification, no hint for the
  linked identity, cancellation and alternate sign-in on another installation.
  They also cover recovery after Apple revocation, owned identities, stale
  sessions and unlinked switches. Apple, Google and the backend are controlled
  boundaries here.
- The `registration-link` packaged journey passed on fresh iPhone 18 Pro and
  iPad Pro 11-inch M5 iOS 27 Simulators. It uses a Release simulator build and
  relaunches with both sign-in methods.
- The Mac `Testing` build with `registration-link` compiled and passed its bundle
  check with ad-hoc signing. Normal mobile and Mac bundle checks and native runner
  contracts (20 tests) passed.

Real Apple and Google linking, the deployment's JWT gateway, signed Mac
Keychain/UI and physical devices remain deferred. The
[protected qualification path](../linked-sign-in.md#protected-real-qualification)
has not run either. No installed Mac profile covers the disposable
`dev.unwired.mock.*` IDs. Local evidence is in
`artifacts/expo-bootstrap/native-Ak0yAc` and
`artifacts/private-inbox/integration.dmkGTV`.

## Apple registration evidence, 2026-09-30

[#597](https://github.com/unwired-dev/product/issues/597) adds
[Sign in with Apple continuing into Gmail authorization](../apple-registration.md)
on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed. Shared
  application tests run every Gmail consent failure after Apple sign-in and
  cover Apple cancellation. Rendered host tests cover the Apple-specific copy,
  the relay contact address and a Gmail-derived connected address. Convex
  integration keeps same-relay-address Apple and Google identities in separate
  Product Accounts without storing the address.
- Nine app-hosted native tests passed on an owned iOS 27 Simulator with real
  Keychain. New scenarios cover Apple cancellation and Gmail decline/connection.
  They confirm no Google hint or identity is derived from the Apple account. They
  also cover cross-provider rejection, contact-address retention, revoked-credential
  recovery, interrupted registration and Apple-issuer claim checks. Apple, Google
  and Convex are controlled boundaries here, not live evidence.
- The `registration-apple` packaged journey passed on fresh iPhone 18 Pro and
  iPad Pro 11-inch M5 iOS 27 Simulators. It uses a Release simulator build carrying
  the Sign in with Apple entitlement, with pending setup and connected relaunch.
  The Google `registration-declined` journey passed again on both devices.
- The Mac `Testing` build with `registration-apple` compiled, bundled and
  passed its bundle check with ad-hoc signing. Native runner contracts (20 tests),
  Effect import-policy checks and Fallow on changed files passed.

Real Sign in with Apple, signed Mac Keychain/UI and physical devices remain
deferred, as does the [protected qualification path](../apple-registration.md#protected-real-qualification).
No installed Mac profile covers the disposable `dev.unwired.mock.*` IDs, and none
of the installed profiles was checked for the Sign in with Apple capability.
Local evidence is in `artifacts/expo-bootstrap/native-hT8jlu` (Apple),
`artifacts/expo-bootstrap/native-iCWlM6` (Google) and
`artifacts/private-inbox/integration.s7Okrv`.

## Google registration evidence, 2026-09-30

[#596](https://github.com/unwired-dev/product/issues/596) adds
[Google Product Sign-In and separate Gmail authorization](../google-registration.md)
with the approved GoogleSignIn 10.0.0 native SDK on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed. Existing
  backend and Inbox coverage remains. New application and rendered-host tests
  cover pending setup, retry and mailbox reselection; Convex integration proves
  same-address Google and Apple identities stay separate without creating a
  mailbox connection or Product Sync key material.
- Seven app-hosted native tests passed on an owned iOS 27 Simulator against real
  Keychain, CryptoKit and filesystem operations. Added scenarios cover callback
  nonce/audience/subject/issuer/expiry rejection, missing Gmail grants, unavailable
  Gmail, interrupted registration, offline account retention, independent mailbox
  selection and preservation of existing Inbox ciphertext. Google authorization
  and Convex are controlled boundaries in these tests, not live OAuth evidence.
- Normal and selected registration JavaScript exports passed both host bundle
  checks. Root and host Fallow scans reported zero unused-code findings. Native
  runner contracts, Effect import-policy checks, Swift formatting and strict
  SwiftLint passed.
- Normal and selected Expo simulator Release and Mac packaged Testing builds
  passed with GoogleSignIn.
  Selected registration builds include a fixed native mock provider; normal builds
  exclude it. Release Mac configuration cannot inherit the Testing scenario marker.
- The native registration journey passed on fresh iPhone 18 Pro and iPad Pro
  11-inch M5 iOS 27 Simulators. It retains pending setup across process relaunch,
  authorizes a different synthetic mailbox and restores the connected status.

The native provider and backend substitutes above are distinct from the protected
[real OAuth qualification path](../google-registration.md#protected-real-oauth-qualification).
That path, signed Mac Keychain/UI checks, physical-device behavior and distribution
qualification remain deferred before release. No installed Mac provisioning
profile matches the disposable test app identifiers; no developer-portal resources
were created.

Local evidence is retained in `artifacts/mock-mail-registration`,
`artifacts/expo-bootstrap/native-0GNjv1` and
`artifacts/private-inbox/integration.0aqXIK`. A final mobile rerun failed during
Simulator installation before tests began; the retry on fresh owned devices
passed on both iPhone and iPad. Mac project regeneration required CocoaPods reintegration;
an initial pnpm-launched pod installation failed with a null-path error, and a
standalone installation succeeded. Failed attempts remain diagnostic evidence.
Hosted CI completion is separate from these local checks.

## Isolated Mock Mail Session evidence, 2026-09-30

[#595](https://github.com/unwired-dev/product/issues/595) adds
[external deterministic session runners](../mock-mail-sessions.md). On the local
Xcode 27.0/macOS 27.0.1 host:

- Mobile Release compilation passed. The same synthetic open, mark-read and
  relaunch journey passed on fresh iPhone 18 Pro and iPad Pro 11-inch M5 iOS 27
  simulators. Both used the real application runtime, presentation and native
  encrypted store. Exit evidence was zero, and the run-owned app copy,
  DerivedData and simulators were removed.
- Four separate app-hosted native storage tests passed against real CryptoKit,
  filesystem and Keychain, covering relaunch, unavailable keys, corrupt
  ciphertext, protected-data recovery, credential removal and competing writes.
- Mac packaged `Testing` compilation passed. Native E2E preflight failed closed
  because no configured profile covers disposable `dev.unwired.mock.*` IDs.
  This journey and its signed external Keychain cleanup remain deferred before
  release. An ad-hoc build does not establish Data Protection Keychain evidence.
- Shared synthetic-provider/application tests, both host component suites,
  retained backend tests, lint, format and types passed. Both external runner
  contracts passed with tool stubs. Those contracts prove orchestration and
  cleanup behavior, not Mac native execution.
- Normal and selected production JavaScript exports passed the host bundle
  checks. Normal exports exclude mock providers. Root and host Fallow checks
  report zero unused-code/dependency issues; health diagnostics remain
  advisory.

Local results are retained under `artifacts/mock-mail-595`,
`artifacts/expo-bootstrap/native-TAgsiX`, and
`artifacts/private-inbox/integration.wElIBS`. The first mobile run exposed an
invalid test query after navigation; after moving that assertion before
navigation, both native journeys passed. That failed run remains available as
diagnostic evidence. No real Gmail, sign-in, assistance engine, delivery or
physical-device qualification is claimed. Hosted CI results are separate from
this local evidence.

## Native Mac mock Inbox evidence — 2026-09-29

The [Mac host](../macos-client.md) adds AppKit windows around the shared synthetic
Inbox. The amended root-workspace boundary now includes a `macos` catalog with
React Native macOS 0.81.9, React Native 0.81.6 and React 19.1.4.

- Frozen strict-peer installation succeeds with both host graphs installed.
- All 20 workspace lint, format, type and test tasks pass for Mac, mobile,
  shared core/contracts and Convex. Two Mac component integration scenarios
  exercise independent selection, view closure and remounting against the real
  mock mailbox service. Three Effect import-policy checks pass.
- Both production bundle inventories pass. Mac autolinking finds no extra native
  modules and resolves the pinned Mac fork. Mobile autolinking resolves React
  Native 0.86.3 and its seven native modules, with no Mac dependency.
- Native `Testing` and `Release` arm64 builds succeed on macOS 27.0 (26A428) with
  Xcode 27.0 (27A266a), local ad-hoc signing and hardened runtime disabled for
  local dynamic-framework loading. Distribution signing is unqualified.
- The approved, pinned `fast-text-encoding@1.0.6` supplies the UTF-8 APIs missing
  from Mac Hermes before Effect loads. Packaged native launch renders the shared
  Inbox without Metro.
- The native XCTest journey passes on the packaged Testing app and exercises
  independent selection, menu focus, Command-N and
  Command-W, closing all windows, continued synthetic work, Launch Services
  reopen, reading another message and menu Quit in one process/session.
  Direct native UI automation also verifies Command-Q; XCTest keyboard injection
  after reopening did not reliably deliver that shortcut.
- The Release executable contains none of the Testing probe environment key,
  work-counter or session-property symbols.

The local XCTest runner uses an optimized, packaged Testing app, with a synthetic
application-scoped timer and content-free lifecycle records. Those records are
compiled out of Release. Bundle output and successful compilation do not prove
window lifetime, synchronization, delivery or real provider integration. No
legacy coverage is removed.

## Mobile bootstrap evidence — 2026-09-28

- Strict peer dependency installation passes with one root workspace and lockfile,
  shared catalog and named `mobile` catalog. Shared source uses `workspace:*`.
- Root workspace lint, formatting, TypeScript and tests pass after dependency
  updates. Mobile lint, formatting, TypeScript and three component tests pass;
  the shared Effect service has three passing contract tests.
- A deliberately discarded Effect value fails Oxlint with
  `effecttsgo/floating-effect`, confirming the patched compiler integration.
- Effect is available at the root for its installed agent guide and source.
  Both Oxlint configurations reject non-namespace Effect imports; the regression
  fixtures cover named, default, barrel, side-effect and type imports.
- The production Hermes export includes the mobile renderer, native Router split
  view, Effect and the current shared source. The verifier rejects stale shared
  source, other renderer versions, the Mac graph and backend imports.
- An arm64 Release simulator build succeeds with Xcode 27. Packaged launch
  without Metro succeeds on task-owned iPhone 18 Pro and iPad Pro 11-inch M5
  simulators running iOS 27.0 (24A434).
- One native XCTest journey passes on each device: open Maya's message, return
  through the native back button on iPhone, select Oliver, and confirm that the
  previous sender is no longer displayed. iPad shows the columns side by side.
  `pnpm test:native` retains this journey with owned-device cleanup and rejects
  zero-test success. It consumes an already-built simulator app.
  The Release build and both journeys were repeated after workspace consolidation.
- The first native launch exposed the iOS 27 scene-lifecycle requirement. The
  Expo build-properties plugin now generates scene support. The first iPad
  screenshot exposed an overlapping sidebar; explicit tiled split behavior
  and the detail pane's left safe-area inset correct it. The native journey
  checks that message text starts beyond the sidebar.

Hardware-keyboard activation, VoiceOver, resizable iPad windows, physical-device
behavior, persistence, credentials, native Mac, signing and App Store archives
are not established by this bootstrap. Keep those checks in the release gate.
The mock Inbox is in-memory; opening mail does not mark it read.

## Native E2E automation

The [Mobile workflow](../../.github/workflows/mobile.yml) now defines an
`Expo native E2E` job for ready pull requests and pushes to `main`. It builds the
packaged Release app on the `xcode-27` arm64 image, runs the existing iPhone/iPad
journey, and uploads build logs and XCTest results. The runner rejects zero-test
success and avoids retrying assertion failures even when infrastructure messages
are also present. This workflow definition does not establish a passing hosted
run; record that evidence after the updated workflow executes.

## Earlier dependency probe — 2026-09-09

The sections below preserve the original probe, package pins and machine state.
At that time no Mac with macOS 27 and Xcode 27 was available, and the maintainer
authorized implementation with native checks deferred. Those probe results are
historical and are not evidence for the current native app.

The deferred native work is tracked in
[GitHub issue #623](https://github.com/unwired-dev/product/issues/623). It is a
release prerequisite and does not block the approved feature-implementation tickets.

## Historical selected arrangement

The original probe used [independent native host installations](../adr/0064-isolate-mobile-and-macos-native-dependencies.md):

| Host        | Expo    | React Native | React Native macOS | React  |
| ----------- | ------- | ------------ | ------------------ | ------ |
| iPhone/iPad | 57.0.21 | 0.86.3       | None               | 19.2.3 |
| Mac         | None    | 0.81.6       | 0.81.9             | 19.1.4 |

The Expo pins came from the exact package's `bundledNativeModules.json`, rather
than the moving documentation alias. React Native macOS's exact package metadata
requires React Native 0.81.6 and React `^19.1.4`. Sources:
[Expo 57.0.21 metadata](https://registry.npmjs.org/expo/57.0.21),
[React Native macOS 0.81.9 metadata](https://registry.npmjs.org/react-native-macos/0.81.9),
[macOS setup guidance](https://microsoft.github.io/react-native-macos/docs/getting-started),
and [Expo's duplicate-native-package constraints](https://docs.expo.dev/guides/monorepos/#duplicate-native-packages-within-monorepos).

Two structural candidates were reviewed: one shared older renderer line, and
separate supported host installations. The parent and independent cross-judge
selected the latter. The cross-judge scored them 8/10 and 9/10 across host fit,
dependency evidence, isolation, implementation cost, and falsifiable verification.
Retain the other candidate's explicit renderer inventory and observable Mac
close-versus-Quit checks. Do not adopt its Expo version override or speculative
storage API. That decision originally required independent lockfiles and Metro
resolution. The 2026-09-28 amendment replaces the lockfile boundary with named
catalogs and verified per-host resolution.

## Executed checks

The disposable probe used sibling `mobile`, `macos`, and `shared` directories.
Both hosts declared `packageManager: pnpm@11.5.2` and their own
`pnpm-workspace.yaml` containing `packages: []`. Each consumed the same local
`@private-email/platform-probe-core` package through `file:../shared`. All probe
packages were development-only; no production dependencies or existing workspace
lockfiles were changed.

The shared package had no dependencies. Its fixed synthetic fixture contained
two messages, one unread, and a pure unread-count function. Both entry points
rendered the fixture identifier and count using their own React Native `Text`.
This is a shared-source bundling probe, not a mail journey or provider test.

The mobile entry used Expo's `registerRootComponent`. The Mac entry used
`AppRegistry.registerComponent`; its resolver mapped `react-native` and
`react-native/*` imports to `react-native-macos`. The Mac probe pinned
`@react-native/babel-preset` and `@react-native/metro-config` to 0.81.6 and Metro
to 0.83.8, with the `macos` platform selected explicitly.

| Check                                                                                                     | Result                                                 |
| --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Install each host with `pnpm install --ignore-scripts --strict-peer-dependencies`                         | Both passed; install scripts deliberately did not run. |
| Mobile `expo install --check`                                                                             | Passed: dependencies are up to date.                   |
| Mobile iOS JavaScript export                                                                              | Passed.                                                |
| Mac Metro JavaScript bundle                                                                               | Passed.                                                |
| Both source maps contain the exact current shared TypeScript source                                       | Passed; identical shared-source SHA-256.               |
| Each source map uses its intended React package and contains no source from the other host's native graph | Passed for the probe entry points.                     |
| Native app build, launch, Hermes execution, or UI automation                                              | Not run; deferred.                                     |

Commands were run through the repository's mise-managed Node 24.16.0 and
pnpm 11.5.2. From each disposable host directory:

```sh
mise exec -- pnpm install --ignore-scripts --strict-peer-dependencies
```

From the mobile directory:

```sh
CI=1 EXPO_NO_TELEMETRY=1 mise exec -- pnpm exec expo install --check
CI=1 EXPO_NO_TELEMETRY=1 mise exec -- pnpm exec expo export \
  --platform ios --output-dir dist --no-bytecode --no-minify \
  --source-maps --max-workers 2
```

The Mac runner used Metro's `loadConfig` and `runBuild` with:

```js
{
  entry: './index.ts',
  platform: 'macos',
  dev: false,
  minify: false,
  out: './dist/macos.jsbundle',
  sourceMap: true,
  sourceMapUrl: 'macos.jsbundle.map',
}
```

The initial Mac invocation reached bundle output but failed because `dist` did
not exist. Creating that output directory and rerunning passed. This was a probe
runner correction, not a package compatibility failure.

The exports were production-mode JavaScript without minification or Hermes
bytecode, inspected through their source maps. They were not native Release
archives. These hashes identify this disposable run; transitive dependency and
bundler changes can produce different output:

| Artifact          |     Bytes | SHA-256                                                            |
| ----------------- | --------: | ------------------------------------------------------------------ |
| Shared `index.ts` |         — | `5e28ae26dfc7ccd8b592f76908b5a68cadf464caa19eb803f357c12b31b80aea` |
| Mobile JavaScript | 2,100,704 | `10224f77372e9009e25a10642a2a1b9326ea5845a6eea4c4168a8deee0f65144` |
| Mac JavaScript    | 2,347,888 | `46403a725c2202fac0fc5715fb539f419fd50948333741252fe5d1863d7abe1e` |

The mobile map contained 587 sources and React 19.2.3. The Mac map contained 499
sources and React 19.1.4. Neither map included the other host's framework graph.
Future app entry points and native modules must preserve this isolation; a
successful minimal bundle does not establish that every future dependency will.

## Deferred native evidence

The inspected machine runs macOS 26.6.2, Xcode 26.6 (17F113), and SDKs through
26.5. Installed iOS simulators reach 26.5; there is no version-27 runtime.
CocoaPods was not installed. No simulator, native project, native module, app
archive, or database reset was created by this probe.

Continue implementation under the maintainer's explicit deferral. Before release,
record results for the actual replacement hosts and exact root dependency lockfile:

1. Build and launch iPhone/iPad and native Mac apps with deployment targets at 27,
   packaged JavaScript, and the selected native modules. Exercise Hermes and native
   autolinking; do not substitute an active Metro server for packaged launch.
2. Run the same deterministic visible mail journey on iPhone and iPad at compact
   and regular widths, including keyboard interaction and persistence after
   process termination and relaunch.
3. On Mac, verify menus, keyboard shortcuts, independently routed windows,
   reopening a window after all windows close, continued application-scoped work
   with no windows, and cessation of that work on explicit Quit.
4. Prove device-local Keychain accessibility, credential removal across relaunch,
   encrypted database contents, and inability to open private data without its
   native-held key. Synthetic in-memory storage cannot supply this evidence.
5. Run desktop UI automation against the actual AppKit accessibility tree. Treat
   zero selected tests as missing evidence. Use task-owned simulators and build
   directories for mobile checks under the repository's ownership policy.
6. Produce separate mobile and Mac App Store archives and TestFlight artifacts;
   verify signing, entitlements, sandbox behavior, and physical-device AI
   availability separately from JavaScript bundling.

No legacy tests have been retired by this dependency probe. Retire tests with
the implementation they protect, preserving or replacing the named risks in
[the testing policy](../agents/testing.md) and
[the mock-mode decision](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).

## Private Inbox persistence, 2026-09-29

[#594](https://github.com/unwired-dev/product/issues/594) implements
[native encrypted fixture storage](../private-inbox-storage.md) for Expo and Mac.
Verification used Xcode 27.0, Swift 6.4, the iOS 27.0 Simulator runtime, Node
24.16.0 and pnpm 11.5.2.

Passed:

- Lint, formatting, types and tests for mobile, Mac, mail-core, contracts and
  Convex through `pnpm turbo run lint format check-types test` with those package
  filters. Focused tests were rerun after the final test-only edits.
- Both production bundles and renderer/native-boundary checks, Expo dependency
  compatibility, root and host Fallow scans, Effect import-policy tests and the
  existing native runner failure-handling suite. Fallow reported no unused-code
  findings; advisory health findings remain separate from its exit status.
- Swift formatting and strict SwiftLint for the new native store, bridge and
  integration tests; Ruby and zsh syntax checks; affected local documentation links.
- Ad-hoc signed Expo simulator Release build and the native iPhone 18 Pro and
  iPad Pro 11-inch M5 journeys. Both explicitly mark a fixture read, terminate
  the app, relaunch its packaged binary, and observe the restored read state.
  Local evidence: `artifacts/expo-bootstrap/native-pEBIF3/`.
- Three app-hosted Swift Testing integration scenarios on an owned iOS 27
  Simulator, using real Keychain, CryptoKit and filesystem operations. These
  prove encrypted persistence, no fixture plaintext in the encrypted file,
  rejection without the correct key, preservation of missing-key/corrupt data,
  synthetic credential use and deletion, database-key isolation, and competing
  native updates. Local evidence: `artifacts/private-inbox/integration.8tcd1d/`.
- Mac `Testing` build, including the shared native store and bridge, with ad-hoc
  signing and packaged JavaScript. This proves compilation and packaging only.

Deferred:

- Signed Mac Keychain integration and native read-state relaunch checks. The
  local Unwired development certificate is available, but matching Mac App
  Development provisioning profiles are absent for
  `dev.unwired.mail.macos.preview` and `dev.unwired.storage-probe.StorageHost`.
  Xcode rejected both signed builds before tests could run. Ad-hoc signing and
  a plain SwiftPM test executable do not qualify Data Protection Keychain access.
  The Mac checks remain required before release; the signing setup is documented
  in the storage guide. No developer-portal resources were created.
- Physical-device lock/unlock, backup/restore and distribution-signing behavior.
  Simulator tests do not prove these policies on a shipped app.

Mock Mail Session tests prove application behavior through a substituted native
boundary. They are distinct from the real storage tests and the packaged-app
journeys above. This slice retires no legacy coverage.
