# Expo and React Native platform qualification

Evidence date: 2026-09-09. Status: **dependency and JavaScript bundle checks pass;
native version-27 qualification is deferred**.

The maintainer confirmed the rewrite and authorized implementation to proceed
without native validation for now. No Mac with macOS 27 and Xcode 27 is available
to the project. Keep the version-27 deployment floors and complete the deferred
checks when suitable tooling is available. This record does not claim a working
replacement client, successful native build, or release readiness.

The deferred native work is tracked in
[GitHub issue #623](https://github.com/unwired-dev/product/issues/623). It is a
release prerequisite and does not block the approved feature-implementation tickets.

## Selected arrangement

Use [independent native host installations](../adr/0064-isolate-mobile-and-macos-native-dependencies.md):

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
storage API. Use independent lockfiles as well as independent Metro resolution;
a shared native workspace would weaken the selected boundary.

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
record results for the actual replacement hosts and exact dependency lockfiles:

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
