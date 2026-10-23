# Native Mac client and mock Inbox

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/macos-client.md).

`apps/macos` implements [#593](https://github.com/unwired-dev/product/issues/593)
with AppKit windows and React Native macOS views. It reads the same synthetic
mailbox as Expo through `@private-email/mail-core`, with
[native encrypted read-state persistence](private-inbox-storage.md). Production
registration now creates a Convex Product Account. Production mailboxes use [Gmail synchronization](gmail-inbox.md), the
[Microsoft Inbox](microsoft-mail.md) or
[IMAP synchronization](imap-mailboxes.md#synchronization) through the native adapter;
Gmail, Microsoft and IMAP connections send.

Production launches offer [Apple](apple-registration.md) or [Google](google-registration.md)
registration; the first mailbox is chosen separately: Gmail, [Microsoft mail](microsoft-mail.md) when configured for this build, or an IMAP login. Either sign-in can later be [linked](linked-sign-in.md)
as the other sign-in method. A new account [initializes Private Sync](private-product-sync.md):
the device that wins initialization presents the Recovery Key. Another device of
that account shows a code and [waits for a Trusted Device to approve it](private-product-sync.md#approving-a-new-device), or [unlocks with the Recovery Key](private-product-sync.md#recovering-with-the-recovery-key). Configure the native client IDs and Convex deployment when generating the host.
Select an explicit Mock Mail Session to run the synthetic Inbox journeys.

## Window behavior

The `macos` catalog pins React Native macOS 0.81.9, React Native 0.81.6 and React
19.1.4 in the root workspace and lockfile. React Native Testing Library 14 uses
`test-renderer` 1.1.0, the line that matches React 19.1. Keep React and native imports out of
`mail-core`. Mac views and native adapters live in `apps/macos`.

Load the approved `fast-text-encoding@1.0.6` polyfill in the entry point before
Effect. Mac Hermes lacks `TextEncoder` and `TextDecoder`; the polyfill supplies
UTF-8 encoding only, not a general message-charset decoder.

The production bundle verification rejects the mobile renderer, Expo, React DOM and
backend code, checks the shared fixture against disk, and verifies native
autolinking. The host autolinks `@react-native-clipboard/clipboard` for Copy link
and `react-native-webview`, patched for the isolated message reader. Keep Expo
Clipboard in the mobile host; the Mac bundle excludes Expo packages.
The Mac Podfile declares only the `GoogleSignIn` pod. Private Inbox links its
reviewed Swift packages, SwiftMail and swift-log, at the revisions
[its manifest pins](imap-mailboxes.md#engine-and-dependencies). Adding any kind of
native dependency requires an explicit update to `scripts/verify-native.ts`.
The generated project currently also compiles `native/design`, the first-party
SF Symbol and Liquid Glass views shared with the iPhone/iPad host. Follow
[native component selection](agents/native-components.md): prefer provided
React Native macOS/AppKit controls and presenters over custom equivalents, and
retain a minimal native adapter only for a documented host API gap. Expo UI
availability on mobile does not establish Mac compatibility.
The Podfile check requires the mise-managed Ruby and accepts only literal pod names.

Each window has three columns: a floating Liquid Glass Mailboxes sidebar
(the window's [Profile Switcher](private-inbox-storage.md#mail-profiles),
**All inboxes**, each Mailbox Connection with its Inbox and IMAP folders, and
**Account**), the message list with its floating search and **New Message** bar,
and the reader. The **Show Sidebar** / **Hide Sidebar** button before the list title
toggles the sidebar; a window at most 900pt wide starts without it.

Each window owns its selected message. Opening another starts with no selection.
Reading leaves unread flags unchanged. Explicit read/unread actions persist and
update all windows without changing their selections.
A window's one composer overlays the reader as described in
[composing](drafts.md#composing); opening a Draft keeps the selected message
behind it, selecting another message updates that reader without closing the
Draft, and Expand takes the composer over the window's panes beneath its
command bar.

| Command                                | Behavior                                            |
| -------------------------------------- | --------------------------------------------------- |
| File > New Window, Command-N           | Open an independent Inbox                           |
| File > Close Window, Command-W         | Close the focused window                            |
| Window > Show Inbox, Command-0         | Focus the first Inbox, or create one if none remain |
| Window > Next Window, Command-backtick | Cycle through Inbox windows                         |
| Window > Inbox number                  | Focus that window                                   |
| Dock/Finder reopen                     | Focus an existing Inbox or create one               |
| Unwired Mail > Quit, Command-Q         | End the process                                     |
| Edit > Cut, Copy, Paste, Select All    | Edit the focused text field or text view            |

When the system keeps windows at quit (System Settings, Desktop & Dock, with
"Close windows when quitting an application" turned off) or after the app ends
unexpectedly, AppKit restores each Inbox window with its frame and Mail Profile.
Otherwise a launch opens one new window in the Startup Profile. The Settings
window is never restored. Native journeys launch with
`-ApplePersistenceIgnoreState YES`, so each starts from one new window; restoring a
window's Profile across a real relaunch is not yet verified natively and remains a
release check.

Closing the final window keeps the application and its runtime alive, and Gmail
synchronization continues without a window, as
[Freshness across app lifecycles](gmail-inbox.md#freshness-across-app-lifecycles)
describes. Explicit Quit stops application work; there is no separate helper.
Queued delivery is a later slice.

The View menu's Commands… item (Command-P) opens the key window's
[Command Palette](command-palette.md). Native menus use AppKit accessibility. Message buttons expose labels and selected
state, support keyboard focus, and show a focus border. React Native macOS 0.81.9 does
not expose plain nonselectable `Text` to accessibility: wrap it in an accessible view carrying
its label, or make it selectable so it becomes a native text view. Full VoiceOver and
hardware-keyboard qualification remain separate release checks.

The Edit menu has no Undo or Redo. The composer body keeps its own Command-Z and
Shift-Command-Z history.

Link confirmations move keyboard focus to their first choice and cycle Tab and
Shift-Tab within the choices; Escape dismisses the alert. Dismissal does not
explicitly restore focus to the originating link because that control is not
tracked.

The [keyboard and accessibility journey](agents/native-validation.md#mac-keyboard-and-accessibility-journey)
covers what the keyboard reaches today: Command Palette commands, Search Mail,
editing, window commands and Settings. Tab only cycles the focused text field,
so opening a message, placing the caret in a new reply and Send still need the
pointer; [#849](https://github.com/unwired-dev/product/issues/849) owns keyboard
navigation of the list, reader and composer. VoiceOver behavior remains an
accessibility qualification gap.

## Build and run

Use the [mise Node/pnpm toolchain](../README.md#local-development), Xcode 27, and
Ruby with CocoaPods and the `xcodeproj` gem. Keep the Ruby gem executables and
pnpm on `PATH` for Xcode build phases. `native:build` adds the active Ruby's gem
executable directory to `PATH`, so installed CocoaPods remains available after
a Ruby upgrade. `RUBY` selects the test runner's Ruby.

```sh
mise exec -- pnpm install --frozen-lockfile --strict-peer-dependencies
cd apps/macos
mise exec -- pnpm native:build
open ../../artifacts/macos-inbox/DerivedData/Build/Products/Release/UnwiredMail.app
```

`native:build` regenerates the ignored Xcode project, installs Pods
using the committed `Podfile.lock`, and builds arm64 with isolated DerivedData.
The Mac Podfile loads `scripts/cocoapods-paths.rb` to avoid CocoaPods' intermittent
`pathname contains null byte` failure when creating groups for pnpm-linked pods
([upstream #12798](https://github.com/CocoaPods/CocoaPods/issues/12798)). The
regression check uses real CocoaPods/Xcodeproj objects and injects the reported filesystem
failure; run `mise exec -- ruby apps/macos/scripts/cocoapods-paths.test.rb` from
the repository root. The Mac CI job also runs it against CocoaPods 1.17.0.
Remove the workaround once the upstream fix has been verified with this pnpm layout.

Local builds default to ad-hoc signing and
disable hardened runtime because ad-hoc dynamic frameworks have no Team ID. The
generated project retains hardened runtime for distribution signing.
Google and Apple sign-in, and persistence, require the
[Keychain signing setup](private-inbox-storage.md#native-wiring-and-signing).
Google's SDK reports `com.google.GIDSignIn` code `-2` when it cannot store
credentials in Keychain; ad-hoc builds report unavailable storage. Signed builds
run in the App Sandbox with outgoing network access only, so their store lives
in `~/Library/Containers/dev.unwired.mail`. Ad-hoc builds also run in the sandbox
with outgoing network access, but omit profile-required Apple sign-in, Keychain and
APNs entitlements; their registration for remote notifications fails, so they keep
the five-minute interval. Signed builds request the `com.apple.developer.aps-environment` entitlement
for [push wake routes](gmail-inbox.md#push-wake-routes), so their profile needs the
Push Notifications capability. Debug connects to Metro as a network client. The bundle ID is `dev.unwired.mail`, shared with the
iPhone/iPad host, and the version comes from `apps/macos/package.json`. Both
hosts build their icon from `native/app-icon/UnwiredMail.icon`. All
configurations target macOS 27. Release embeds `main.jsbundle`; it never falls
back to Metro. Distribution signing and App Store archives remain
unqualified.

For development, run `mise exec -- pnpm dev` from `apps/macos` to start Metro.
In another terminal in the same directory, build Debug. `native:build` loads the
root `.env.local` if it exists; exported shell variables take precedence:

```sh
mise exec -- pnpm native:build Debug
open ../../artifacts/macos-inbox/DerivedData/Build/Products/Debug/UnwiredMail.app
```

From the repository root, `mise exec -- pnpm macos` starts Metro, builds Debug and
opens the app in one Turborepo run; `mise exec -- pnpm dev:macos` starts only Metro.

For real sign-in, set `UNWIRED_SIGNING_IDENTITY="Apple Development"` and
`UNWIRED_DEVELOPMENT_TEAM="<your team ID>"` in that local file, alongside the
[Google and Convex host configuration](google-registration.md#configure-the-hosts).
Install a matching Mac development profile first. Generated development-signed
projects use automatic signing; `native:build` uses installed profiles and does not create
developer-portal resources. Automatic signing only selects Xcode-managed profiles.
For a profile created in the developer portal, also set `UNWIRED_MAC_PROFILE`
to its file path; the generated project then signs manually with that installed
profile. TestFlight ignores this local profile option and keeps automatic
provisioning. Debug uses Metro. Quit and reopen the app after a
native rebuild. Regenerate the native project and reinstall Pods after changing
native setup or dependencies.

## Verification

Run relevant [shared validation commands](../README.md#validation) once from the
root, then the Mac-specific checks:

```sh
mise exec -- pnpm --filter @private-email/macos fallow
mise exec -- pnpm --filter @private-email/macos check-types
mise exec -- pnpm --filter @private-email/macos test
mise exec -- pnpm --filter @private-email/macos build
mise exec -- pnpm --filter @private-email/macos verify:bundle
```

The [Mac CI workflow](../.github/workflows/macos.yml) runs Fallow and the production
bundle/autolinking check. The root TypeScript job runs repository lint and format, plus Mac types and
component tests. Native desktop automation currently runs locally.

Three component integration scenarios exercise independent selections, closing one
view while another remains, selecting mail after every view unmounts, and shared
read state while each window keeps its selection. They
run the real shared mock service with React Native's test renderer. They do not
prove AppKit lifecycle behavior.

The native mailbox journey uses the [isolated Mock Mail Session runner](mock-mail-sessions.md#native-mac-entry-point).
Build with `UNWIRED_MOCK_SCENARIO=open-read-relaunch` in the optimized,
packaged `Testing` configuration. The runner copies the app into a random bundle
identity; Mac Data Protection Keychain requires a development signing identity
and a profile covering `dev.unwired.mock.*`, selected using
`UNWIRED_SIGNING_IDENTITY` and `UNWIRED_MOCK_PROFILE`. Keep the identity as the
generic `Apple Development`; the automatically signed build rejects a full
certificate name. It signs an external cleanup
helper for the same isolated Keychain group. The ordinary app and its
store are preserved. Without that profile, record native execution as deferred;
component, bundle and runner contracts remain available.

The runner selects one XCTest journey: the mailbox lifecycle journey by default,
or the journey named after the app path, such as the
[language journey](localization.md#verify), the
[performance journey](agents/native-validation.md#mac-performance-journey) or the
[keyboard and accessibility journey](agents/native-validation.md#mac-keyboard-and-accessibility-journey). The lifecycle journey opens two windows, selects different messages, focuses a
window through its menu, closes both, checks continued application work, reopens
through Launch Services, reads another message, and chooses the native Quit menu.
Command-Q is checked separately through direct native UI automation because
XCTest key injection after reopening is unreliable on the qualification host.
The journey checks one process
and session throughout. It requires a logged-in macOS 27 desktop with XCTest UI
automation permission. If XCTest reports `Timed out while enabling automation mode`,
run `automationmodetool` to inspect the host's status. When enabling Automation Mode
requires administrator authentication, the host owner must complete that setup
before rerunning the journey; record the blocked run as deferred native evidence.
The runner uses its own probe project and result directory
and rejects zero-test success. XCTest terminates its launched app on failure.

Only `Testing` compiles the synthetic application-scoped work timer and JSONL
probe. The runner creates `lifecycle.jsonl` in its evidence directory, and the test supplies `UNWIRED_LIFECYCLE_PATH`;
the application never creates a test-control server or accepts reset commands.
Records contain only lifecycle event names, process/session identity, window
counts and tick counts. With that path, the probe also records each primary mouse
press and release and observed main-queue delays of 100 ms or longer, with their uptime
and duration, for the
[performance journey](agents/native-validation.md#mac-performance-journey). In
registration Mock Mail Sessions, the synthetic relay also appends the uptime of
each provider body request, with no URL or message content. Release compiles out the probe and timer. Ordinary local
OS logs contain lifecycle names and window counts, never message content.

The lifecycle JSONL is an XCTest attachment and remains in the runner's evidence directory.
Results live in `artifacts/macos-inbox/journey.*`. Capture visual evidence
separately through native UI automation; XCTest window screenshots fail on the
qualification host’s multi-display setup. Preserve native,
component and bundle evidence as distinct claims in the
[qualification record](qualification/expo-react-native-client.md). Real Gmail,
delivery, accessibility and distribution still require their own checks.
[Private storage](private-inbox-storage.md) has separate real integration checks. No legacy coverage is retired by this slice.

## Interface language

The Inbox, the welcome page and Settings' **Language** offer System default and a saved English
override, which also titles the native menus and windows. See
[interface translations](localization.md) for catalogs, adding languages, native
menu behavior, and language verification.

## Settings

Settings is one 900×720 AppKit window. The app menu's **Settings…** (Command-,),
each Inbox window's **Account** button, its Command Palette's Account command and
IMAP password repairs open it, or bring the open one forward on the destination
they name. Inbox windows keep their Drafts, mailboxes and selected messages
beside it. The window has its own Command Palette bar, whose Inbox command
brings an Inbox window forward, and it closes itself when no Inbox can open,
such as after sign-out or while storage is locked. Command-, is always enabled,
so while signed out, and in preview builds without a Product Account, the
window opens and closes again at once.

Settings' Mail Assistance switch follows the Mac's system accent. Its graphite
tint from the design remains a native-host deviation for design capture and
qualification.
