# Deterministic Mock Mail Sessions

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/mock-mail-sessions.md).

[#595](https://github.com/unwired-dev/product/issues/595) provides test-only
synthetic identity, mail and assistance providers and external native runners.
Both hosts run the existing application runtime, views and native AES-GCM Inbox
store for the open, mark-read and relaunch journey. Opening a message leaves it
unread; marking it read commits storage; relaunch restores the committed state.
Selection is not persisted.

## Boundaries and scenarios

A Mock Mail Session accepts only a fixed scenario name. It cannot accept
credentials, mailbox addresses, Product Account IDs, URLs, network clients or
provider adapters. Its identity is a literal synthetic identity with an invalid
email domain. No provider contacts Gmail, Convex, a sign-in service or
an assistance service. There is no token or backend-authority representation.

The factory offers `open-read-relaunch`, `identity-unavailable`,
`mail-unavailable` and `assistance-unavailable`. Identity and mail failures use
the real application's unavailable-state path; assistance failure leaves mail
available. The assistance provider follows the native
[message summary](message-summaries.md#native-binding) contract: it reports the
model as available and returns a fixed synthetic summary, and the
[Draft rewrite and reply](draft-assistance.md#native-binding) fixed synthetic texts,
or, in `assistance-unavailable`, reports the model as not ready. Its translation
provider follows the [translation](message-translation.md#native-binding) contract:
it lists two synthetic target languages and returns a fixed synthetic translation,
or, in `assistance-unavailable`, reports the language as not installed. The
rendered reader tests use them for the summary and translation journeys. Identity currently has provider-contract
coverage, not a sign-in UI journey. Later feature slices extend these contracts
when their application paths exist. Native builds for every selected mock scenario
compile a synthetic assistance answer with the same fixed summary, rewrite,
reply, translation and language list instead of running Apple's model or Translation. The open, mark-read and relaunch journey also explicitly
summarizes a message through this synthetic native binding.

Native builds can select `open-read-relaunch` or `mail-unavailable` using
`UNWIRED_MOCK_SCENARIO`. Unselected bundles exclude all mock-provider code;
source-map checks enforce that boundary and reject backend sources. Unknown
scenario names fail the build. Native XCTest accepts `open-read-relaunch` and the eleven registration scenarios
described in [Google registration](google-registration.md#deterministic-evidence),
[Apple registration](apple-registration.md#deterministic-evidence),
[linked sign-in](linked-sign-in.md#deterministic-evidence) and
[sign-out and deletion](account-removal.md#deterministic-evidence).
The registration journeys use real Keychain with a fixed synthetic provider compiled only in the selected test build.
That provider also answers the [Gmail Inbox](gmail-inbox.md#deterministic-evidence)'s
requests from a synthetic mailbox of three messages over two list pages and one
label, each with a synthetic HTML or plain-text body for the reader, applying label
changes for the rest of the launch. Journeys that confirm setup with a connected
mailbox open that synchronized Inbox, open a message, star, archive and undo,
relaunch from its encrypted cache and return to the account page.
Its synthetic [Product Sync](private-product-sync.md#deterministic-evidence)
backend keeps the run's encrypted records in the same Keychain service, so new
accounts present a Recovery Key and relaunches keep their keys. Like Convex, it
admits only the device that created an account's keys; any other device waits as a
Pending Device without Gmail authorization until it is admitted. In
`registration-enrollment`, a synthetic trusted device already holds the account
keys and an encrypted mailbox. It approves the app's request with the code read
from that Keychain, standing in for a person typing it on another device.
In `registration-recovery`, the same synthetic device is lost and never approves.
The journey types the account's fixed synthetic Recovery Key instead, which the
backend checks against the account's Recovery Key verifier.
In `registration-revocation`, the new account also has a synthetic iPad. The
journey removes it, confirms the replacement Recovery Key and relaunches without
it. In `registration-revoked`, another device removes this one after its first
sign-in. The relaunch purges the account. Signing in again mints a new device
identifier, which waits for approval as a Pending Device, and the journey signs
out of that gate.
In `registration-removal`, the journey saves and confirms its Recovery Key, then
signs out and relaunches with nothing kept.
Signing in again leads to an approval request. It then deletes the account,
relaunches, and finds signing in refused as deleted.
The native runners reject builds without a supported test marker. Selection is never
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
xcodebuild build -workspace apps/mobile/ios/UnwiredMail.xcworkspace \
  -scheme UnwiredMail -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath artifacts/mock-mail/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64
mise exec -- pnpm --filter @private-email/mobile test:native \
  "$PWD/artifacts/mock-mail/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMail.app"
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
UNWIRED_SIGNING_IDENTITY='Apple Development' \
UNWIRED_MOCK_PROFILE='/absolute/path/to/mock-only.provisionprofile' \
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app"
```

The runner requires a Mac development profile covering `dev.unwired.mock.*`
or the profile's wildcard identifier. The application and Keychain identifiers
use the profile's App ID prefix, which may differ from its team ID. The runner
does not create portal resources or request provisioning updates. The disposable app and external cleanup helper
use an application identifier and Keychain access group for that exact random
run ID. They never inherit the original app's Keychain access groups. Both run in
the App Sandbox, as signed hosts do. The session's only extra entitlement is
write access to its own evidence directory, where the runner creates
`lifecycle.jsonl` for it. An ad-hoc
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
deletes every item in its exact database and registration Keychain services, including
Product Sync keys and synthetic records, and removes its Application Support
directory. The runner then removes that identity's sandbox container. Cleanup failure fails the run. If Mac cleanup fails, the signed cleanup helper
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
mise exec -- pnpm exec turbo run lint format check-types test --filter=// \
  --filter=@private-email/mobile... --filter=@private-email/macos...
```

CI runs synthetic provider/application tests and both native runner contracts
on Linux. Tool stubs prove orchestration, ownership, failure handling and cleanup;
they are not native execution. The existing Expo native CI jobs build the
selected synthetic scenario and exercise real storage on iPhone and iPad 27.
Mac execution requires the profile and a logged-in macOS 27 desktop with UI-test
permission, so it is not added to an unsigned hosted runner.

Run normal and selected exports with their matching `verify:bundle` commands.
[Private Inbox storage integration](private-inbox-storage.md#verification)
separately qualifies CryptoKit and Keychain. Native mock journeys do not qualify
real Gmail authorization or transport, assistance engines, delivery (synthetic Gmail
accepts every send), physical-device
lock behavior or approval between two real devices. Keep that evidence distinct under
[ADR 0060](adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).
No legacy tests are retired by this slice. See the
[qualification record](qualification/expo-react-native-client.md) for available
and deferred execution.
