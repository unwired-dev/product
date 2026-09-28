# Validate the current Swift client

These commands and resource-ownership rules apply to the existing SwiftUI and
Mac Catalyst implementation. Legacy Swift CI and manual provider qualification
jobs were disabled at the maintainer's request on 2026-09-28. These local commands
remain available until [cutover #627](https://github.com/unwired-dev/product/issues/627).
The Expo and native React Native Mac hosts need their own commands. Their version-27
qualification is tracked by [#623](https://github.com/unwired-dev/product/issues/623).

Run commands from the repository root.

The current project targets iOS and macOS 26 and uses the Xcode 26 toolchain
with an iPhone 17 simulator runtime. The named destinations and cache paths in
the CI examples below belong to hosted runners. For local automation, substitute
the fresh owned Simulator UDID and task-owned build/result paths required below.

## Host validation for trusted work

For developer-requested work and scheduled or automated tasks operating on a trusted checkout,
retry required validation on the host when the Codex sandbox prevents an OS capability that the
check is designed to exercise. This includes loopback listeners used by `pnpm test`, SwiftPM and
CoreSimulator services used by Apple tests, and `mise exec -- pnpm mail:test ...`. A sandbox
failure is not sufficient evidence that one of these checks is unavailable: use the available
host-execution or approval mechanism for the exact validation command before reporting it as
blocked.

Keep host access command-scoped. Run only the intended non-destructive validation command, use the
repository's pinned toolchain, avoid unrelated network or filesystem access, and report that the
check ran outside the sandbox. Do not weaken, skip, or rewrite tests merely to make them compatible
with the sandbox. This exception never applies to the PR babysitter workflow,
including trusted-base validation. Its isolated local-validation and remote-CI
fallback policy remains authoritative.

Local trusted automation that uses CoreSimulator must isolate its Apple resources:

- Before a full Apple validation matrix, verify the data volume has at least 6 GiB available. If
  it does not, remove only caches and run directories owned by the current task, or stop and
  report the capacity blocker. Never delete another task's Simulator, DerivedData, temporary
  directory, or Mail Test Harness ownership record.
- Create a fresh Simulator for the task using the required device type and runtime, record its
  UDID, boot it, and wait for `xcrun simctl bootstatus <udid> -b` before invoking Xcode. Pass
  `-destination 'platform=iOS Simulator,id=<udid>'`; do not select an unowned pre-existing device
  by name. Hosted CI may continue using the documented named destination on its fresh runner.
- Give the task its own DerivedData and result-bundle paths. Use a `trap` or equivalent `finally`
  cleanup so the owned Simulator is shut down and deleted and owned temporary build directories
  are removed on success, failure, cancellation, and timeout.
- Treat a missing `testmanagerd` socket, a CoreSimulator service disconnect, or an unexpected
  successful result with zero selected tests as infrastructure failure. Discard the owned
  Simulator and retry once with a newly created device before attributing the failure to code.
- Prefer the Mail Test Harness command for Core Mail Loop validation because it already owns its
  servers, ports, run directory, certificate, and Simulator lifecycle. Do not replace its owned
  Simulator with a shared device.

## Apple commands

The iOS, iPadOS, and macOS app must provide formatter, linter, and test commands.

- Format and lint: `zsh scripts/check-apple-lint.zsh`

Write Apple unit tests with Swift Testing: `import Testing`, `@Suite`, `@Test`, `#expect`, and `#require`. Do not add XCTest-based unit tests. Use XCTest only for test targets that require XCTest-specific APIs, such as UI automation, and document the reason in that target.

SwiftLint is managed by mise and runs in strict mode so warnings fail validation. Run `mise trust .mise.toml` and `mise install` first, or use `mise exec -- zsh scripts/check-apple-lint.zsh` when mise is not activated. Apple `swift-format` may come from Xcode via `xcrun`.

If Apple tooling is unavailable in the current environment, state that clearly in the final handoff.

## CI expectations

The replacement checks live in `.github/workflows/ci.yml` and `mobile.yml`.
One strict, frozen root install supplies all packages. The TypeScript job checks
mobile, shared core/contracts and the retained Convex backend, plus the Effect
import-policy regression tests. Fallow scans root and mobile entry points;
mobile CI also checks Expo compatibility and the production Hermes bundle.
The root Fallow scan excludes the legacy mail harness.

Legacy Swift Debug, Release-performance and Core Mail Loop jobs, their nightly
schedule, and manual Swift provider-qualification jobs are disabled by maintainer
decision. Their test sources are retained for local investigation. The legacy
mail harness tests are also excluded from the primary CI task selection.

Native Expo Release builds and iPhone/iPad journeys have local evidence; they are
not yet automated in hosted CI. See [Expo validation](../expo-client.md#validate).
The remaining platform qualification is required before release.

### Historical Swift CI commands

These commands are retained for manual investigation. Apply the task-owned
Simulator and path substitutions above. The Debug pass builds once, disables
parallel testing, and excludes the Release-only fixture and both mixed-connection
scenarios, which run immediately afterward in a fresh test process:

```sh
xcodebuild build-for-testing \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath '.xcode-cache/unwired-mail/DerivedData' \
  -clonedSourcePackagesDirPath '.xcode-cache/unwired-mail/SourcePackages' \
  -parallel-testing-enabled NO
```

```sh
xcodebuild test-without-building \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath '.xcode-cache/unwired-mail/DerivedData' \
  -clonedSourcePackagesDirPath '.xcode-cache/unwired-mail/SourcePackages' \
  -parallel-testing-enabled NO \
  '-skip-testing:unwired-mailTests/MailboxConnectionAdapterTests/testGmailFirstReleaseMixedConnectionScenario()' \
  '-skip-testing:unwired-mailTests/MailboxConnectionAdapterTests/testProviderRolloutMixedConnectionScenario()' \
  '-skip-testing:unwired-mailTests/MailboxConnectionAdapterTests/testGmailFirstReleaseCachedPresentationMeetsPerformanceBudgets()'
```

```sh
xcodebuild test-without-building \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath '.xcode-cache/unwired-mail/DerivedData' \
  -clonedSourcePackagesDirPath '.xcode-cache/unwired-mail/SourcePackages' \
  -parallel-testing-enabled NO \
  '-only-testing:unwired-mailTests/MailboxConnectionAdapterTests/testGmailFirstReleaseMixedConnectionScenario()' \
  '-only-testing:unwired-mailTests/MailboxConnectionAdapterTests/testProviderRolloutMixedConnectionScenario()'
```

The Release pass builds and then runs only that fixture with testability, the `TESTING` and
`CI_PERFORMANCE_BUDGET` compilation conditions, the active simulator architecture, and serial
testing:

```sh
xcodebuild build-for-testing \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -configuration Release \
  ENABLE_TESTABILITY=YES \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='TESTING CI_PERFORMANCE_BUDGET' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath '.xcode-cache/unwired-mail/DerivedData' \
  -clonedSourcePackagesDirPath '.xcode-cache/unwired-mail/SourcePackages' \
  -parallel-testing-enabled NO
```

```sh
xcodebuild test-without-building \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -configuration Release \
  ENABLE_TESTABILITY=YES \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='TESTING CI_PERFORMANCE_BUDGET' \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath '.xcode-cache/unwired-mail/DerivedData' \
  -clonedSourcePackagesDirPath '.xcode-cache/unwired-mail/SourcePackages' \
  -parallel-testing-enabled NO \
  '-only-testing:unwired-mailTests/MailboxConnectionAdapterTests/testGmailFirstReleaseCachedPresentationMeetsPerformanceBudgets()'
```
