# Native validation

This guide covers resource ownership for the Expo client and native
React Native macOS host. Commands and toolchain requirements live in
[Expo setup and validation](../expo-client.md#validate); remaining release
checks are listed [below](#required-release-checks). The implementer records dated
results and limitations in [platform qualification](../qualification/expo-react-native-client.md)
in the PR that produced the evidence.
The replacement targets iOS, iPadOS, and macOS 27 or newer.

## Own the resources used by the check

- Give each task a single-writer ledger. Record long-running processes with
  `scripts/owned-process record <ledger> <pid>` while the parent is running;
  stop them and their descendants with `scripts/owned-process stop <ledger>`.
  A failed stop keeps the ledger for recovery. Never stop builds, Simulators or
  test runners by name or relative path on this shared host.
- Both native runners record host load (`host-load.txt`: load averages,
  `xcodebuild` processes, booted Simulators) before and after each journey.
  Before attributing a timing or idle-wait failure to the host, compare it with
  a passing baseline and reproduce it without your own concurrent native work.
  Before a rerun, check `uptime` and wait while the 1-minute load is above 100,
  whether from other tasks or your own builds: journeys failed at loads of
  117–380. Run your own journeys one at a time.
- The Mac runner holds a per-user lock for its whole XCUITest run; another Mac
  journey waits for it and logs how long. An event-synthesis timeout during a
  concurrent desktop UI automation run is contention, not a product failure:
  rerun the journey alone before reporting it.
- Run `scripts/pre-handoff.sh` without a concurrent native build, journey or
  other heavy local job.

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
- Capture screens from the shell that already holds Screen Recording, by window
  id (`screencapture -l <id> <path.png>`). A task-built probe or bundle that captures
  itself raises a permission prompt that a locked desktop cannot dismiss.
  Check that the desktop is unlocked before UI probes; defer XCUITest and
  active-window checks while locked. After a probe, inspect on-screen windows
  for permission dialogs it caused before reporting cleanup complete.

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
keep the app interactive while it waits.

The current references are:

- iPhone: the owner's physical iPhone 17 Pro Max on iOS 27.
- iPad: the owner's physical iPad Pro 13-inch with Apple M4 (`iPad16,5`).
- Mac: a Mac mini with Apple M4 and 16 GB memory (`Mac16,10`) on macOS 27.

Record each device's exact chip, RAM, storage capacity, OS version and build
with its first baseline, and the exact OS version and build for every run.
Establish separate iPhone 17 Pro Max, iPad and Mac baselines; every unmeasured
baseline remains required before release. Results apply only to the tested
configurations. Nomination does not establish a passing baseline. Hosted-runner
speed does not relax a device budget. Record the device, fixture, build, command
and measurement evidence; these targets do not claim a passing measurement. The
[reference device history](../native-journeys.md#reference-device-history)
records how each device was nominated.

## Journey catalog

The native E2E journey catalog lives in [Native journeys](../native-journeys.md).
When a change adds or alters a journey, update its entry there.

## Report what the evidence proves

A production Hermes export verifies the JavaScript bundle. A native build proves
compilation and packaging. Interaction tests prove only the journeys exercised.
None substitutes for real provider, credential, encrypted-storage, accessibility
or physical-device qualification.

Record the target, toolchain, command, result and any unavailable check. For a
patched probe, stop if setup or patching fails and log a marker from the patched
code to prove which variant ran. Check each capture against its label before
citing it. Available native checks should run when relevant. Deferred checks
stay required before release.

For changes to the mail shell or its native navigation containers, exercise the
signed-in path on each affected host. On mobile, use a registration Mock Mail
Session such as `registration-apple`: verify the Inbox list and reader after
setup and relaunch, open Settings and return with the prior mail state retained,
and rotate with a reader open. Keep keyboard and presentation checks when those
interactions are affected. A preview Inbox run qualifies only the path it uses;
record unavailable signed-in native checks as deferred.

A navigation, size-class or shared-journey change runs on every affected device
class and orientation. Where one is unavailable, check each journey action
against that class and record the run as deferred. Before deferring a check for
lack of an entry point, try a cold deep link and a scenario fixture, and record
the capability that is still missing.

CI runs only the `open-read-relaunch` native journey, so a change to the
registration flow, the native bridge or journey files builds and runs the
affected `registration-*` scenarios locally, or records them as unavailable.
Verify the capture session reaches each changed screen and state with
representative content, and extend the fixture when it does not. Copied native
sources follow the regeneration and binary checks in
[Expo setup](../expo-client.md#install-and-run); these prove build input, not
interaction. Rich-reader rendering and CSS changes are measured first through
WKWebView, never Chrome: render the sanitizer's output at the device width in
Light and Dark from a `scratchpad/` probe, and defer gesture and device-chrome
checks when simulator automation is unavailable.

When the journey that reaches a changed state fails later at a tracked,
pre-existing point, place the new step before that point and report the new
assertions' result with the failing line and its issue. Confirm stop-on-first-failure
is enabled and the failure matches the tracked point before treating earlier
assertions as passed; keep the overall run's failure visible.
Before adding an accessibility audit, inventory every window and state it will
cover; reuse an already-audited surrounding state where possible.
Before rerunning a failed native, visual or accessibility check, record
the environment facts its baseline assumes (appearance, display layout, locale,
host load, windows open during an audit) and compare them. When a native CI
failure does not reproduce locally, compare CI's pinned Xcode and runtime with
the host's, then download and unpack CI's `expo-native-app-<run>` tar artifact
and run it locally to separate the build from the test toolchain. If it stays
unexplained, follow the [diagnostic-push exception](pull-request-babysitting.md#implementer-pr-delivery).

## Required release checks

Before completing native host qualification in
[#623](https://github.com/unwired-dev/product/issues/623), record evidence for the
actual source revision and exact root lockfile:

- Build and launch both native graphs at the version-27 floors with packaged
  JavaScript, Hermes and the selected native modules, without Metro. Run the
  deterministic visible persistence journey on iPhone, iPad and native Mac;
  zero selected tests is failure. Include compact/regular mobile layouts,
  keyboard interaction, process termination and restored state after relaunch.
- On iPad, check expanded-to-floating composer collapse and compact-to-regular
  layout transitions with the software keyboard open and the editor kept mounted.
  Verify avoidance padding clears while editor state is preserved. These composer
  transition checks remain deferred until native evidence is recorded.
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
