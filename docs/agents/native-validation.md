# Native validation

This guide covers resource ownership for the Expo client and native
React Native macOS host. Commands and toolchain requirements live in
[Expo setup and validation](../expo-client.md#validate); remaining release
checks are listed [below](#required-release-checks). Reviewers retain dated results
and limitations in [platform qualification](../qualification/expo-react-native-client.md).
The replacement targets iOS, iPadOS, and macOS 27 or newer.

## Own the resources used by the check

- Before a full native validation matrix, require at least 6 GiB available on
  the data volume. Reclaim only artifacts owned by the current task; otherwise
  report the capacity blocker.
- Create a fresh Simulator for each automated run, record its UDID, boot it, and
  wait for `xcrun simctl bootstatus <udid> -b`. Select it with
  `-destination 'platform=iOS Simulator,id=<udid>'`. Do not use another task's
  device or select a shared Simulator by name.
- Use task-owned DerivedData, result bundles and temporary directories. Arrange
  cleanup on success, failure, cancellation and timeout. Shut down and delete
  only owned devices; preserve the logs and results needed for the handoff.
- Treat a missing `testmanagerd` socket, CoreSimulator service disconnect or an
  unexpected success with zero selected tests as infrastructure failure. Retry
  once on a fresh owned device. An assertion failure is a test failure; normal
  service connection logs do not justify a retry.
- For the Expo Inbox journeys, run `pnpm test:native` from `apps/mobile`
  after the documented build prerequisites. The runner owns its Simulator
  lifecycle and result paths. The [Mac runner](../macos-client.md#verification)
  owns its probe project and results; run it against a task-built app on a
  logged-in macOS desktop.

Follow the [execution-environment policy](testing.md#execution-environment) for
sandbox restrictions and the separate PR babysitter validation boundary.

## Performance qualification

The existing local-mail budgets remain release requirements. Measure a Release
build with a warm encrypted cache on the reference iPhone 17 Pro Max, at least two
connections with 50 initially available messages each, completed backfill and
cached-body samples. Use the current launch-provider scope rather than a
historical Gmail-only fixture.

Also build and label 250 local Threads in the Unified Inbox aggregation fixture,
adapted to the current launch-provider scope. Its p95 must remain below 200 ms,
with no main-thread stall of 100 ms or longer.

| Interaction                                                         | Budget                       |
| ------------------------------------------------------------------- | ---------------------------- |
| App-launch entry to first rendered sidebar and initial message list | p95 at most 1 second         |
| Cached mailbox or Mail View switch, cached body and warm composer   | p95 at most 200 ms           |
| Empty composer                                                      | p95 at most 300 ms           |
| Typing and formatting feedback                                      | Next rendered frame          |
| Main-thread stall                                                   | No stall of 100 ms or longer |

Measure cached switches and body/composer opening from user selection to
rendered interactive content. Measure provider/network latency separately and
keep the app interactive while it waits. The iPhone reference is the owner's
physical iPhone 17 Pro Max on iOS 27, nominated in
[#1106](https://github.com/unwired-dev/product/issues/1106) on 2026-10-21. Record
its exact chip, RAM, storage capacity, OS version and build with the first
baseline. Qualification uses the available physical iPhone, iPad and Mac;
standard non-Pro iPhone access is not required. Results apply only to the tested
configurations and do not qualify untested hardware. This qualification scope
does not change product hardware support. The Mac reference is a Mac
mini with Apple M4 and 16 GB memory (`Mac16,10`) on macOS 27. The iPad reference is the
owner's physical iPad Pro 13-inch with Apple M4 (`iPad16,5`), nominated in
[#1105](https://github.com/unwired-dev/product/issues/1105) on 2026-10-21. At
nomination it runs iPadOS 27.0.1 (24A446). Its RAM and storage capacity were not
exposed by the host tooling; record those with its first baseline, and record
the exact OS version and build for every run. Establish separate iPhone 17 Pro
Max, iPad and Mac baselines; every unmeasured baseline remains required before
release. Evidence from the former iPhone 17 reference does not qualify its
replacement. Nomination does not establish a passing baseline. Hosted-runner speed does not
relax a device budget. Record the device, fixture, build, command and measurement
evidence; these targets do not claim a passing measurement. The reviewer verifies
the decision history in [ADR 0018](../adr/0018-local-mail-performance-budget.md).

### Mac performance journey

On the Mac, the `testWarmCachePerformance` journey measures the budgets above
except Mail View switching and typing and formatting feedback, which remain
deferred. Build the `Testing` configuration, which
is Release-optimized with packaged JavaScript plus the test-only probes, with
`UNWIRED_MOCK_SCENARIO=registration-performance`, then run it with the
[Mac runner](../mock-mail-sessions.md#native-mac-entry-point):

```sh
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testWarmCachePerformance
```

The journey signs in with Apple and connects the synthetic Microsoft and Gmail
mailboxes, 126 and 128 Inbox Threads. It opens five messages of each once so
their bodies are cached, then measures 10 relaunches until the unified Inbox
lists, 21 switches between both Inboxes and All inboxes, 10 body openings per
mailbox and 10 openings each of an empty composer and a saved Draft. Closing a
composer currently crashes the Mac host
([#1174](https://github.com/unwired-dev/product/issues/1174)), so each composer
sample is the first composer of a relaunched process. The synthetic relay
records each provider body request in the probe evidence; the journey fails if a
cached-body sample requested one, or if priming recorded none.

A click sample runs from the mouse release, recorded by the app on the same
uptime clock, until an accessibility query finds the rendered result. A launch
sample runs from the launch request. Every sample includes XCUITest's event
completion and queries, about 35–45 ms each, so it is an upper bound: a sample
within budget passes, but an overrun only shows that the budget is not proven.
The app records main-queue probe delays of 100 ms or longer; the report names
stalls overlapping sample windows and in the whole session. Missing or malformed
probe evidence, including a click sample without its mouse events, fails the journey.
The probe samples every 10 ms after its launch setup. No recorded delay means no
observed stall; it does not prove the absolute stall cap for every main-thread
task or for startup before the probe begins.

The journey writes one `PERFORMANCE` JSON line per interaction to
`xcodebuild.log` and the same lines as an XCTest attachment. Each line has the
samples, p50, p95, maximum, budget and stalls. The final line has the
query overhead, the synthetic press duration and every session stall. It
measures neither Mail View switching, typing nor formatting feedback, keyboard or
accessibility journeys, nor the iPhone and iPad references.

### Mac keyboard and accessibility journey

The `testKeyboardAndAccessibility` journey uses the same `registration-performance`
`Testing` build and sign-in as the performance journey:

```sh
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testKeyboardAndAccessibility
```

By keyboard, it runs Search Mail from the Command Palette and types a query. It
then cuts and pastes that query through the Edit menu. It closes the palette with
Escape and checks that focus returns to the search field. It moves through the
palette's commands with Down and Up and runs Account with Return, which opens
Settings, then closes Settings with Command-W. It runs Reply from the palette,
types into the reply and pastes into it. After relaunch, it checks that the
saved Draft reopens with that text. Command-N opens a second Inbox with no
selection; Command-backtick, Command-0 and Command-W then move between and close
windows while the first window keeps its Draft. Opening a message, placing the
caret in the new reply and Send still use the pointer (see
[#849](https://github.com/unwired-dev/product/issues/849)). The journey never
sends, because Send crashes the host
([#1174](https://github.com/unwired-dev/product/issues/1174)). Cut and Copy use
the desktop pasteboard, so the journey restores its earlier contents.

It runs XCTest's accessibility audit on the Inbox, Command Palette, Settings,
reader and composer, and prints each issue as an `ACCESSIBILITY` JSON line in
`xcodebuild.log`. `knownAccessibilityGap` names the owner of each issue the
audits still report. These are buttons without a press action and the missing
parent/child links
([#1194](https://github.com/unwired-dev/product/issues/1194)), secondary-text
contrast ([#1195](https://github.com/unwired-dev/product/issues/1195)), choose-one
options without a role ([#1196](https://github.com/unwired-dev/product/issues/1196)),
AppKit's text Touch Bar and email addresses used as labels. The contrast gap lists
the labels it covers. Any other issue fails
the journey; remove a gap once its owner fixes it. The audits run in the host's
current appearance only. They do not replace VoiceOver,
Full Keyboard Access or iPhone and iPad keyboard qualification.

## Report what the evidence proves

A production Hermes export verifies the JavaScript bundle. A native build proves
compilation and packaging. Interaction tests prove only the journeys exercised.
None substitutes for real provider, credential, encrypted-storage, accessibility
or physical-device qualification.

Record the target, toolchain, command, result and any unavailable check. Available
native checks should run when relevant; the earlier tooling exception permits
implementation to continue without unavailable version-27 evidence, but does
not waive release qualification or turn deferred checks into passing results.

For changes to the mail shell or its native navigation containers, exercise the
signed-in path on each affected host. On mobile, use a registration Mock Mail
Session such as `registration-apple`: verify the Inbox list and reader after
setup and relaunch, open Settings and return with the prior mail state retained,
and rotate with a reader open. Keep keyboard and presentation checks when those
interactions are affected. A preview Inbox run qualifies only the path it uses;
record unavailable signed-in native checks as deferred.

## Required release checks

Before completing native host qualification in
[#623](https://github.com/unwired-dev/product/issues/623), record evidence for the
actual source revision and exact root lockfile:

- Build and launch both native graphs at the version-27 floors with packaged
  JavaScript, Hermes and the selected native modules, without Metro. Run the
  deterministic visible persistence journey on iPhone, iPad and native Mac;
  zero selected tests is failure. Include compact/regular mobile layouts,
  keyboard interaction, process termination and restored state after relaunch.
- Exercise Mac menus, shortcuts, independent window selection, last-window close,
  Dock/Finder reopen and explicit Quit against AppKit. Verify application-scoped
  work continues without a window and stops on Quit. Use the actual accessibility
  tree; component tests and a successful native build do not qualify this behavior.
- Run the [real storage integration](../private-inbox-storage.md#verification)
  separately from mocked provider journeys. Prove encrypted contents, refusal
  without the native-held key, device-local Keychain policy and credential removal
  across relaunch. Retain separate physical-device lock/unlock and backup/restore
  checks; simulated protected-data availability does not establish them.
- Record toolchain versions, lockfile hash, commands, signing/entitlements,
  resource ownership and artifact paths. Use the nominated physical iPhone 17 Pro
  Max, iPad and Mac for [performance qualification](#performance-qualification).
  Separate measured baselines on all three remain required before release.

Keep #623 incomplete while its required native evidence is unavailable. Feature
implementation may continue under the existing deferral. Before release, also
qualify hardware-keyboard and VoiceOver behavior, physical-device AI availability
([assistance qualification](../assistance-qualification.md)),
and separate iPhone/iPad and Mac App Store archives and TestFlight artifacts under
the [distribution procedure](../testflight.md). Mock journeys do not establish
real provider authentication or transport; retain the owning feature guides'
protected integration checks. Do not retire legacy coverage to substitute for a
missing replacement check.
