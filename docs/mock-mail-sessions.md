# Deterministic Mock Mail Sessions

[#595](https://github.com/unwired-dev/product/issues/595) provides test-only
synthetic identity, mail and assistance providers and external native runners.
Both hosts run the existing application runtime, views and native AES-GCM Inbox
store for the open, mark-read and relaunch journey. Opening a message leaves it
unread; marking it read commits storage; relaunch restores the committed state.
Selection is not persisted.

## Boundaries and scenarios

`createMockMailSession` accepts only a fixed scenario name. It cannot accept
credentials, mailbox addresses, Product Account IDs, URLs, network clients or
provider adapters. Its identity is a literal synthetic identity with an invalid
email domain. Mail comes from the existing synthetic Inbox fixture. Assistance
returns a fixed summary. No provider contacts Gmail, Convex, a sign-in service or
an assistance service. There is no token or backend-authority representation.

The factory offers `open-read-relaunch`, `identity-unavailable`,
`mail-unavailable` and `assistance-unavailable`. Identity and mail failures use
the real application's unavailable-state path; assistance failure leaves mail
available. Identity and assistance currently have provider-contract coverage,
not sign-in or assistance UI journeys. Later feature slices extend these
contracts when their application paths exist.

Native builds can select `open-read-relaunch` or `mail-unavailable` using
`UNWIRED_MOCK_SCENARIO`. Metro resolves the normal seed module to the selected
test module at build time. Unselected bundles exclude all mock-provider code;
source-map checks enforce that boundary and reject backend sources. Unknown
scenario names fail the build. Native XCTest currently requires
`open-read-relaunch`; failure scenarios run in deterministic application tests.
The native runners reject builds without that test marker. Selection is never
an app route, URL scheme, runtime setting, control server or reset operation.

## Mobile entry point

Use the pinned root toolchain and the native prerequisites in
[Expo setup](expo-client.md#install-and-run). Set the selection when generating
native projects; it is retained as an Xcode build setting for packaged bundles.
Use task-owned DerivedData and at least 6 GiB free space:

```sh
UNWIRED_MOCK_SCENARIO=open-read-relaunch mise exec -- pnpm --filter @private-email/mobile native:generate --no-install
cd apps/mobile/ios
pod install
cd ../../..
xcodebuild build -workspace apps/mobile/ios/UnwiredMailPreview.xcworkspace \
  -scheme UnwiredMailPreview -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath artifacts/mock-mail/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64
mise exec -- pnpm --filter @private-email/mobile test:native \
  "$PWD/artifacts/mock-mail/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMailPreview.app"
```

The runner copies the marked app, assigns a random `dev.unwired.mock.<run>`
bundle identifier and ad-hoc signs the copy. The original app is unchanged.
It creates fresh iPhone and iPad 27 simulators with independent containers and
Keychains. A new invocation is a reset and replay using another namespace and
fresh devices. Relaunch within the journey preserves its encrypted store.

## Native Mac entry point

Build the `Testing` configuration; Release excludes the lifecycle probe and
mock marker. Follow [Mac setup](macos-client.md#build-and-run):

```sh
UNWIRED_MOCK_SCENARIO=open-read-relaunch \
mise exec -- pnpm --filter @private-email/macos native:build Testing
UNWIRED_SIGNING_IDENTITY='Apple Development: <configured identity>' \
UNWIRED_MOCK_PROFILE='/absolute/path/to/mock-only.provisionprofile' \
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app"
```

The runner requires a Mac development profile covering `dev.unwired.mock.*`
or the profile's wildcard identifier. The application and Keychain identifiers
use the profile's App ID prefix, which may differ from its team ID. The runner
does not create portal resources or request provisioning updates. The disposable app and external cleanup helper
use an application identifier and Keychain access group for that exact random
run ID. They never inherit the original app's Keychain access groups. An ad-hoc
Mac app cannot access the Data Protection Keychain and is insufficient evidence.
If this profile is unavailable, native Mac E2E remains deferred before release;
compilation, bundles, deterministic application tests and runner contracts still
run. Signing credentials are build prerequisites, never synthetic provider inputs.

The journey also preserves existing multi-window, last-window-close, reopen and
Quit coverage. The original desktop app and its data remain untouched.

## Ownership, evidence and cleanup

Each invocation records `ownership.json` before copying the app. It records the
scenario, host, exact generated app path and bundle identifier, with no credentials
or message content. Mobile also records owned simulator UDIDs in `devices.txt`.
`result.json` records the exit code. XCTest logs and xcresults contain the
visible journey. Mobile includes screenshot attachments; Mac includes lifecycle
attachments. Results live under
`artifacts/expo-bootstrap/native-*` or `artifacts/macos-inbox/journey.*`.

Exit, failure and interrupt traps delete only run-owned app copies, probes and
simulators. The Mac helper requires the recovery argument to match its own
bundle identity before touching another process or storage. It terminates only
that generated identity,
deletes its exact database Keychain item and removes its Application Support
directory. Cleanup failure fails the run. If Mac cleanup fails, the signed cleanup helper
is retained with the ownership record for retry. Evidence remains for diagnosis.
No system can guarantee trap execution after SIGKILL or power loss; retained
ownership records identify resources for explicit recovery. Never use global
simulator deletion or shared mailbox reset.

Zero selected tests is failure. Mobile retries recognized Simulator infrastructure
failures or zero-test success once on a fresh owned device. Assertion failures
never receive an infrastructure retry. Mac fails immediately on XCTest failure
or missing journey results.

## Verification and limits

```sh
mise exec -- pnpm test:native-runner
mise exec -- pnpm exec turbo run lint format check-types test \
  --filter=@private-email/mobile... --filter=@private-email/macos...
```

CI runs synthetic provider/application tests and both native runner contracts
on Linux. Tool stubs prove orchestration, ownership, failure handling and cleanup;
they are not native execution. The existing Expo native E2E CI job builds the
selected synthetic scenario and exercises real storage on iPhone and iPad 27.
Mac execution requires the profile and a logged-in macOS 27 desktop with UI-test
permission, so it is not added to an unsigned hosted runner.

Run normal and selected exports with their matching `verify:bundle` commands.
[Private Inbox storage integration](private-inbox-storage.md#verification)
separately qualifies CryptoKit and Keychain. Native mock journeys do not qualify
real Gmail authorization or transport, assistance engines, delivery, physical-device
lock behavior or account enrollment. Keep that evidence distinct under
[ADR 0060](adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).
No legacy tests are retired by this slice. See the
[qualification record](qualification/expo-react-native-client.md) for available
and deferred execution.
