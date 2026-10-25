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
except Mail View switching, which remains deferred. It measures typing, formatting
shortcut and format bar feedback from the input to the text-storage update and
the display frame that draws it, as described below. Build the `Testing`
configuration, which
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
sample is the first composer of a relaunched process. In a new message it then
types 20 characters into the body, turns bold on at the caret with Command-B and
types 11 bold characters, then selects the last word and presses Command-B, B,
I, I, U, U twice, so each mark toggles on that word and back. It then clicks the
format bar's Bold, Bold, Italic, Italic, Underline and Underline buttons twice
over on the same word. The synthetic relay
records each provider body request in the probe evidence; the journey fails if a
cached-body sample requested one, or if priming recorded none.

A click sample runs from the mouse release, recorded by the app on the same
uptime clock, until an accessibility query finds the rendered result. A launch
sample runs from the launch request. Click and launch samples include XCUITest's event
completion and queries, about 35–45 ms each, so it is an upper bound: a sample
within budget passes, but an overrun only shows that the budget is not proven.
The app records main-queue probe delays of 100 ms or longer; the report names
stalls overlapping sample windows and in the whole session. Missing or malformed
probe evidence, including a click sample without its mouse events, fails the journey.

A key sample runs from the key press the app records to the first edit of the
focused body's text storage that begins with the expected text and the bold,
italic and underline marks of each of its characters, so a later key press
cannot hide a late result. A format bar sample runs the same way from the mouse
release the app records. Both times come from the app, so these samples exclude
XCUITest. It compares that duration to `1000 / maximumFramesPerSecond`
of the key window's display, the interval at the display's maximum supported refresh
rate. The edit notification fires before layout managers receive the change, so a
key or format bar group's `withinBudget` result describes only the text-storage update.

Next-rendered-frame feedback comes from the body's first draw after that edit. The
body's latest edit before that draw must still show the expected text and marks;
a result that a later input replaced before any draw fails the journey. A
display link records display frame starts on the same clock. The journey places
the end of that draw in the frame that started last before it, counting frames from any recorded
start at the link's frame interval, and reports `framesLate`: the frames that
started after the input and before that one. `nextRenderedFrame` holds when the
group's p95 is 0. This is a group percentile criterion; individual late samples
remain in `framesLate`. `drawnMs` runs from the input to the end of the draw.
Keep the journey window on one display, refreshing at a constant interval while
the journey types. The probe ends at draw completion; it does not observe
window-server compositing or display presentation. The probe's synchronous
key-event logging also adds work before the edit. A key press, button release
or expected edit missing from the evidence fails the journey.
The probe samples every 10 ms after its launch setup. No recorded delay means no
observed stall; it does not prove the absolute stall cap for every main-thread
task or for startup before the probe begins.

The journey writes one `PERFORMANCE` JSON line per interaction to
`xcodebuild.log` and the same lines as an XCTest attachment. Each line has the
samples, p50, p95, maximum, budget and stalls. The final line has the
query overhead, the synthetic press duration and every session stall. It
measures neither Mail View switching, keyboard or accessibility journeys, nor the
iPhone and iPad references.

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
palette's commands with Down and Up and runs Search Mail with Return, checking
focus returns to search and Settings stays closed. It then runs Account from the
palette, which opens Settings. In Privacy & Data it clicks the device's remote-content
pop-up, dismisses its AppKit menu with Escape, then chooses Never from it and checks that
the pop-up shows the choice. In Language it checks that the interface-language pop-up shows
System Default. It closes Settings with Command-W. It then opens the Gmail
message **Garden plans for spring** with the pointer and clicks each link's keyboard control.
Each link's AppKit alert sheet shows its title and full destination. Command-P stays closed
behind the sheet, and Escape and Cancel close it. The flagged link's sheet closes with Escape
and with Return, its default Cancel. The journey never opens or copies a link. Afterwards
Command-P opens the palette again. It then searches for the
Microsoft message **Quarterly planning** and opens it. The reader's **Folders** AppKit
menu closes with Escape and with a click outside, then Down and Return choose
**Projects**, which moves the message and closes its reader. This runs before Reply
because the reader toolbar ignores clicks while a reply composer is docked
([#1211](https://github.com/unwired-dev/product/issues/1211)). Before continuing, it
checks the moved-message notice and rejects refusal, unsaved, pending and unfinished
save/sync states. This is a synthetic completion proxy, not provider destination
readback. It runs Reply from the palette,
types into the reply and pastes into it. After relaunch, it checks that the
saved Draft reopens with that text. Command-N opens a second Inbox with no
selection; Command-backtick, Command-0 and Command-W then move between and close
windows while the first window keeps its Draft. Expand then moves that saved
Draft into a New Message window, removes the overlay and omits Expand there.
Unfinished recipient text keeps that window open after Command-W and cancels
Quit. Clearing it permits Command-W and the Inbox retains the Draft. Reopening
that Draft and expanding again permits Quit from the new guarded window, stopping
the app. This checks the regular editor's recipient guard
and successful save/close; failed or locked native saves and multiple guarded
windows remain deferred. Opening a message, placing the
caret in the new reply and Send still use the pointer (see
[#849](https://github.com/unwired-dev/product/issues/849)). The journey never
sends, because Send crashes the host
([#1174](https://github.com/unwired-dev/product/issues/1174)). Cut and Copy use
the desktop pasteboard. The journey restores its earlier contents only if
nothing has written to it since the journey's last Cut or Copy.

It runs XCTest's accessibility audit on the Inbox, Command Palette, Settings,
Privacy & Data, Language, the flagged link's sheet over the HTML reader, reader and composer, and prints each issue as an `ACCESSIBILITY` JSON line in
`xcodebuild.log`. `knownAccessibilityGap` names the owner of each issue the
audits still report. These are buttons and message link controls without a press action and the missing
parent/child links
([#1194](https://github.com/unwired-dev/product/issues/1194)), secondary-text
contrast ([#1195](https://github.com/unwired-dev/product/issues/1195)),
reader labels that repeat their role or differ from visible text
([#1220](https://github.com/unwired-dev/product/issues/1220)), AppKit's text Touch Bar,
and email or web addresses used as labels. The contrast gap lists
the labels it covers. Any other issue fails
the journey; remove a gap once its owner fixes it. The audits run in the host's
current appearance only. They do not replace VoiceOver,
Full Keyboard Access or the [iPhone and iPad journey](#iphone-and-ipad-keyboard-and-accessibility-journey).

### iPhone and iPad keyboard and accessibility journey

The Expo native journey for a `registration-performance` Release build drives
the same loop with hardware key presses on iPhone and iPad. Build it with
`UNWIRED_MOCK_SCENARIO=registration-performance` as in the
[mobile entry point](../mock-mail-sessions.md#mobile-entry-point), then run it
on the built app:

```sh
mise exec -- pnpm --filter @private-email/mobile test:native \
  "$PWD/artifacts/mock-mail/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMail.app"
```

Add `UNWIRED_APPEARANCE=light` to audit Light; the runner's default is Dark.

The journey signs in with Apple and connects the synthetic Microsoft mailbox.
Each Command Palette command is typed and run with Return: Account opens Settings,
Inbox leaves it, and Search Mail focuses search. It types a query into search,
then selects, cuts and pastes it back with Command-A, Command-X and Command-V,
and Return submits it. Reply from the palette opens a Draft. Typing extends its
subject, Tab moves focus to its recipients, and the body takes typing. After
relaunch, the Inbox lists the saved Draft, which reopens with both edits.

These steps still use touch on iPhone and iPad:

- Opening the palette, by the header swipe or the iPad command input. iOS
  offers no Command-P without native key commands.
- Opening a row.
- Placing the caret in the reply. Reply focuses no field, and Tab does not
  reach one from there.
- Closing the palette. A hardware Escape leaves it open.

These gaps belong to [#849](https://github.com/unwired-dev/product/issues/849).

It runs XCTest's accessibility audit on the Inbox, Mailboxes, Command Palette,
Settings, reader and composer, and prints each issue as an `ACCESSIBILITY` JSON
line in the test log, with a screenshot of each audited screen.
`knownAccessibilityGap` explains each issue the audits still report:

- the software keyboard's suggestion cells;
- an email address used as a label: a sender's, or the Apple relay address
  that names the signed-in account;
- text over the reader, also behind iPad's floating composer, that the audit
  locates no element for ([#1213](https://github.com/unwired-dev/product/issues/1213)).

Any other issue fails the journey. CI does not run this scenario; it is local
native evidence. It does not replace VoiceOver, Full Keyboard Access or the
owner's physical-device runs. On iPad, XCUITest sometimes waits 60 seconds per
step for the app to settle while the software keyboard is shown, so a run can
take an hour; the iPhone run takes about two minutes.

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
